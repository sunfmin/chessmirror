import Foundation

/// Live consumers share one search per position, ending at ten seconds or depth twenty.
/// A view leaving detaches its listener, not the shared work. Finished results survive
/// navigation and, on device, relaunch, including results below depth twenty.
///
/// **The store keeps the deepest result it knows** (docs/adr/0041). A 复判 asks for a position
/// deeper — `deeper`, depth 28 within a minute — and when that finishes it replaces the everyday
/// entry, so the badge, the finder and the next 细判 there read the deeper answer without
/// searching. A deeper search nobody is waiting for any more is cancelled and writes nothing:
/// what it reached is in the engine's hash table, not in here, and the next ask continues from it.
public actor PositionSearches {
    /// The Depth a position search stops at, whichever end of the budget arrives first. Named
    /// because it is the depth every live answer is worth — judgement, the finder, the engine's
    /// own move and a move a thumb asked for are all this one search — and a caller standing in
    /// for a finished one has no business restating it.
    public static let depth = 20
    public static let budget: SearchBudget = .timeOrDepth(.seconds(10), depth)
    /// What a 复判 takes both ends of a 试招 to: the same deeper level for each, and a minute at
    /// most for each, so the search stays bounded and the pause gate treats it like any other.
    public static let deeperDepth = 28
    public static let deeper: SearchBudget = .timeOrDepth(.seconds(60), deeperDepth)

    private struct Listener {
        let continuation: AsyncStream<Analysis>.Continuation
        /// Whether this reader is satisfied only by `deeperDepth`, or by any finished search.
        let wantsDeeper: Bool
    }

    private struct Entry {
        /// The deepest analysis this store has committed to for the position.
        var latest: Analysis?
        /// Whether a search of the position has run to its end, at any depth.
        var finished = false
        /// The search in flight, if one is.
        var running: SearchBudget?
        var search: Task<Void, Never>?
        var listeners: [UUID: Listener] = [:]

        var isDeepEnough: Bool { finished && (latest?.depth ?? 0) >= PositionSearches.deeperDepth }
        var hasDeeperListener: Bool { listeners.values.contains(where: \.wantsDeeper) }
    }

    private var entries: [String: Entry] = [:]
    private var tail: Task<Void, Never>?
    private let storage: URL?

    public init(storage: URL? = nil) {
        self.storage = storage
        if let storage, let data = try? Data(contentsOf: storage),
           let saved = try? JSONDecoder().decode([String: Analysis].self, from: data) {
            entries = saved.mapValues { Entry(latest: $0, finished: true) }
        }
    }

    /// Clocks and reversible history matter to draws; visual placement alone is unsafe.
    nonisolated static func key(_ game: Game) -> String {
        let fields = game.state.fen.split(separator: " ")
        let fen = fields.prefix(5).joined(separator: " ")
        let reversible = Int(fields[4]) ?? 0
        let history = (max(0, game.plies.count - reversible)..<game.plies.count).compactMap {
            game.rewound(to: $0)?.state.fen.split(separator: " ").prefix(4).joined(separator: " ")
        }.sorted().joined(separator: "|")
        return fen + "|" + history
    }

    /// The position's analysis as it arrives, ending when a search of the position has: at the
    /// everyday `budget`, or — asked with `deeper` — not before the position is known at
    /// `deeperDepth` or a deeper search has run out of its minute.
    public nonisolated func analyse(
        _ game: Game, using engine: any Engine, budget: SearchBudget = PositionSearches.budget
    ) -> AsyncStream<Analysis> {
        let id = UUID()
        let wantsDeeper = budget == Self.deeper
        return AsyncStream { continuation in
            let registration = Task {
                await self.subscribe(game, engine: engine, id: id, wantsDeeper: wantsDeeper, continuation: continuation)
            }
            continuation.onTermination = { _ in
                Task {
                    await registration.value
                    await self.detach(id, from: Self.key(game))
                }
            }
        }
    }

    private func subscribe(_ game: Game, engine: any Engine, id: UUID, wantsDeeper: Bool,
                           continuation: AsyncStream<Analysis>.Continuation) {
        let key = Self.key(game)
        var entry = entries[key] ?? Entry()
        if let latest = entry.latest { continuation.yield(latest) }
        if wantsDeeper ? entry.isDeepEnough : entry.finished {
            continuation.finish()
            return
        }
        entry.listeners[id] = Listener(continuation: continuation, wantsDeeper: wantsDeeper)
        entries[key] = entry
        guard entry.running == nil else { return }
        // The everyday search first, always: a position nobody has looked at is answered at the
        // depth every other live answer is worth before anyone goes deeper, so a reader that
        // wants only that is not made to wait a minute for it.
        start(key, game: game, engine: engine, budget: entry.finished ? Self.deeper : Self.budget)
    }

    private func start(_ key: String, game: Game, engine: any Engine, budget: SearchBudget) {
        entries[key]?.running = budget
        let previous = tail
        let search = Task {
            await previous?.value
            guard !Task.isCancelled, entries[key]?.listeners.isEmpty == false, !engine.isPaused else {
                abandon(key)
                return
            }
            var reached: Analysis?
            // Two lines cover tactics too; never launch a wider second pass.
            for await snapshot in engine.analyse(game, budget: budget, lines: 2) {
                if Task.isCancelled { break }
                guard !snapshot.isPartial, snapshot.best != nil else { continue }
                reached = snapshot
                // An everyday search commits as it climbs, as it always has. A deeper one commits
                // only when it finishes: cancelled, it leaves the entry as it was.
                if budget != Self.deeper { entries[key]?.latest = snapshot }
                for listener in entries[key]?.listeners.values ?? [:].values {
                    listener.continuation.yield(snapshot)
                }
            }
            finish(key, game: game, engine: engine, budget: budget, reached: reached, cancelled: Task.isCancelled)
        }
        entries[key]?.search = search
        tail = search
    }

    /// No search started, so there is nothing new to keep: the readers are let go, and an entry
    /// that never held a result is dropped.
    private func abandon(_ key: String) {
        guard var entry = entries[key] else { return }
        let listeners = entry.listeners
        entry.listeners.removeAll()
        entry.running = nil
        entry.search = nil
        entries[key] = entry.finished ? entry : nil
        for listener in listeners.values { listener.continuation.finish() }
    }

    private func detach(_ id: UUID, from key: String) {
        guard var entry = entries[key] else { return }
        entry.listeners[id] = nil
        entries[key] = entry
        // A deeper search is for whoever asked for it. With nobody left waiting it is stopped,
        // where the everyday search runs on: that one is the position's answer for everybody.
        if entry.running == Self.deeper, !entry.hasDeeperListener { entry.search?.cancel() }
    }

    private func finish(
        _ key: String, game: Game, engine: any Engine, budget: SearchBudget,
        reached: Analysis?, cancelled: Bool
    ) {
        guard var entry = entries[key] else { return }
        entry.running = nil
        entry.search = nil
        if !cancelled {
            if budget == Self.deeper, let reached, reached.depth >= (entry.latest?.depth ?? 0) {
                entry.latest = reached
            }
            entry.finished = true
        }
        // An everyday search ending is the end for everyday readers; the ones that asked for
        // more keep listening, and the deeper search starts for them. A deeper search ending —
        // at depth, out of time, or cancelled — is the end for everyone still here.
        let staying = !cancelled && budget != Self.deeper
        let leaving = entry.listeners.filter { !staying || !$0.value.wantsDeeper }
        for id in leaving.keys { entry.listeners[id] = nil }
        entries[key] = entry
        for listener in leaving.values { listener.continuation.finish() }
        if !cancelled, let storage {
            let saved = entries.filter { $0.value.finished }.compactMapValues(\.latest)
            if let data = try? JSONEncoder().encode(saved) {
                try? FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: storage, options: .atomic)
            }
        }
        if staying, entry.hasDeeperListener {
            start(key, game: game, engine: engine, budget: Self.deeper)
        }
    }
}

extension Engine {
    public func analysePosition(
        _ game: Game, budget: SearchBudget = PositionSearches.budget
    ) -> AsyncStream<Analysis> {
        positionSearches.analyse(game, using: self, budget: budget)
    }

    public func positionResult(
        _ game: Game, budget: SearchBudget = PositionSearches.budget
    ) async -> Analysis? {
        var last: Analysis?
        for await snapshot in analysePosition(game, budget: budget) {
            guard !Task.isCancelled else { return nil }
            last = snapshot
        }
        return Task.isCancelled ? nil : last
    }
}
