import Foundation

/// Live consumers share one search per position, ending at ten seconds or depth twenty.
/// A view leaving detaches its listener, not the shared work. Finished results survive
/// navigation and, on device, relaunch, including results below depth twenty.
public actor PositionSearches {
    /// The Depth a position search stops at, whichever end of the budget arrives first. Named
    /// because it is the depth every live answer is worth — judgement, the finder, the engine's
    /// own move and a move a thumb asked for are all this one search — and a caller standing in
    /// for a finished one has no business restating it.
    public static let depth = 20
    public static let budget: SearchBudget = .timeOrDepth(.seconds(10), depth)
    private struct Entry {
        var latest: Analysis?
        var finished = false
        var listeners: [UUID: AsyncStream<Analysis>.Continuation] = [:]
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

    public nonisolated func analyse(_ game: Game, using engine: any Engine) -> AsyncStream<Analysis> {
        let id = UUID()
        return AsyncStream { continuation in
            let registration = Task { await self.subscribe(game, engine: engine, id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task {
                    await registration.value
                    await self.detach(id, from: Self.key(game))
                }
            }
        }
    }

    private func subscribe(_ game: Game, engine: any Engine, id: UUID,
                           continuation: AsyncStream<Analysis>.Continuation) {
        let key = Self.key(game)
        if var entry = entries[key] {
            if let latest = entry.latest { continuation.yield(latest) }
            if entry.finished { continuation.finish() }
            else {
                entry.listeners[id] = continuation
                entries[key] = entry
            }
            return
        }
        entries[key] = Entry(listeners: [id: continuation])
        let previous = tail
        tail = Task {
            await previous?.value
            guard entries[key]?.listeners.isEmpty == false, !engine.isPaused else {
                // No search started, so there is no result to cache.
                let listeners = entries.removeValue(forKey: key)?.listeners ?? [:]
                for listener in listeners.values { listener.finish() }
                return
            }
            // Two lines cover tactics too; never launch a wider second pass.
            for await snapshot in engine.analyse(game, budget: Self.budget, lines: 2) {
                if !snapshot.isPartial, snapshot.best != nil {
                    entries[key]?.latest = snapshot
                    let listeners = entries[key]?.listeners ?? [:]
                    for listener in listeners.values { listener.yield(snapshot) }
                }
            }
            finish(key)
        }
    }

    private func detach(_ id: UUID, from key: String) { entries[key]?.listeners[id] = nil }

    private func finish(_ key: String) {
        guard var entry = entries[key] else { return }
        entry.finished = true
        let listeners = entry.listeners
        entry.listeners.removeAll()
        entries[key] = entry
        for listener in listeners.values { listener.finish() }
        if let storage {
            let saved = entries.filter { $0.value.finished }.compactMapValues(\.latest)
            if let data = try? JSONEncoder().encode(saved) {
                try? FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: storage, options: .atomic)
            }
        }
    }
}

extension Engine {
    public func analysePosition(_ game: Game) -> AsyncStream<Analysis> {
        positionSearches.analyse(game, using: self)
    }

    public func positionResult(_ game: Game) async -> Analysis? {
        var last: Analysis?
        for await snapshot in analysePosition(game) {
            guard !Task.isCancelled else { return nil }
            last = snapshot
        }
        return Task.isCancelled ? nil : last
    }
}
