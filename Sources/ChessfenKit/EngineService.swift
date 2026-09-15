import CStockfish
import Foundation
import Synchronization

/// The one Stockfish in the app, behind a serial queue.
///
/// Why one, and why a queue rather than an actor (docs/adr/0009): Stockfish keeps a
/// transposition table and a thread pool that are expensive to build and that a second
/// instance would compete with for cores. Its own threads do the searching, so the calls
/// here are either instant or *blocking* — `cf_engine_wait` waits for a search to wind up —
/// and blocking calls have no business on Swift's cooperative pool. A dedicated serial
/// queue gives both properties at once: one search at a time, and no thread starvation.
///
/// The C callbacks arrive on Stockfish's threads. They are handed straight to a mutex and
/// an `AsyncStream` continuation, both of which are safe to touch from anywhere, and they
/// never call back into the engine.
public final class EngineService: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Cores to search on. Two are left for the UI and the OS, because a phone that has
        /// stopped answering taps is not a better chess app.
        public var threads: Int
        public var hashMegabytes: Int
        /// How many Lines an Analysis reports.
        public var multiPV: Int

        public init(threads: Int? = nil, hashMegabytes: Int = 256, multiPV: Int = 3) {
            self.threads = threads ?? Self.threadsForThisMachine
            self.hashMegabytes = hashMegabytes
            self.multiPV = multiPV
        }

        /// Two cores fewer than the machine has, capped — and the cap is the point.
        ///
        /// A search thread is not free in memory either: each carries its own history tables,
        /// `continuationHistory[2][2]` alone being 8 MiB, so the thread count multiplies the
        /// engine's footprint as much as it divides its thinking time.
        ///
        /// Under the Simulator `activeProcessorCount` is the *Mac's*, so a 14-core machine
        /// would start twelve search threads — three times what the phone the code is being
        /// written for will use — on the same machine as Xcode. Two is enough to tell whether
        /// the app works, which is all the Simulator is for. A device is at or under the
        /// other cap already, so nothing about how the app plays in someone's hands changes.
        static var threadsForThisMachine: Int {
            let spare = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
            #if targetEnvironment(simulator)
                return min(spare, 2)
            #else
                return min(spare, 6)
            #endif
        }
    }

    public enum StartupFailure: Error, Hashable, Sendable {
        /// A weights file was not where it was said to be.
        case networkMissing
        /// Present, but too small to be a net — a truncated download, most likely.
        case networkTooSmall
        case allocationFailed
        case unknown
    }

    private let handle: EngineHandle
    private let queue = DispatchQueue(label: "com.sunfmin.chessfen.engine")
    private let sink = Mutex(Sink())

    /// A `CfEngine *` that may cross a queue boundary. Unchecked rather than hopeful: the
    /// pointer is created once, freed once, and every call through it is made on the serial
    /// queue below — which is the invariant that earns the annotation.
    private struct EngineHandle: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    /// What the running search reports to.
    ///
    /// `generation` is what makes superseding safe. A stream that has gone away asks the
    /// engine to stop, and it must not stop whatever search has started since — so it says
    /// which search it meant.
    private struct Sink {
        var generation: UInt64 = 0
        var onInfo: (@Sendable (CfSearchInfo) -> Void)?
        var onFinish: (@Sendable () -> Void)?
    }

    private let generations = Atomic<UInt64>(0)

    /// Which kinds of search a paused engine lets past, as a pure value — the pause rule
    /// with a seam under it, so it can be asked directly instead of being reached through a
    /// running search. A standing Analysis is refused (the screen asks again on the way
    /// back), and a bounded search is admitted to the waiting room: it holds at the gate and
    /// runs on the way back (docs/adr/0009).
    enum SearchGate {
        static func admits(_ budget: SearchBudget) -> Bool {
            switch budget {
            case .untilStopped: return false
            case .time, .depth, .nodes: return true
            }
        }
    }

    /// Whether searching is allowed at all, and who is waiting for it to be.
    ///
    /// The app pauses the engine whenever it is not in front of the user, and the gate lives
    /// here rather than in the screens because a screen can forget and this cannot: every way
    /// into a search passes it. What a search that wants to start while paused does depends on
    /// what kind of search it is, and that distinction is drawn by `SearchGate`, applied in
    /// `analyse` and in the bounded callers below.
    private struct Gate {
        var isPaused = false
        /// Keyed so a cancelled caller can take its own continuation back out.
        var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let gate = Mutex(Gate())

    /// The MultiPV the engine is set to right now, so a search can tell when the option
    /// needs changing. Touched only on the serial queue (and once, by `init`).
    private var multiPV: Int

    public init(
        bigNetURL: URL, smallNetURL: URL, configuration: Configuration = Configuration()
    ) throws {
        cf_global_init()
        var status = CF_ENGINE_OK
        let created = bigNetURL.withUnsafeFileSystemRepresentation { big in
            smallNetURL.withUnsafeFileSystemRepresentation { small in
                cf_engine_create(big, small, &status)
            }
        }
        guard let created else { throw StartupFailure(status) }
        handle = EngineHandle(pointer: created)
        // Changing these takes effect on the next search; Stockfish rebuilds its thread pool
        // and table as the options are set, so they are set here and nowhere else.
        multiPV = max(1, configuration.multiPV)
        setOption("Threads", "\(max(1, configuration.threads))")
        setOption("Hash", "\(max(1, configuration.hashMegabytes))")
        setOption("MultiPV", "\(multiPV)")
    }

    deinit {
        cf_engine_destroy(handle.pointer)
    }

    @discardableResult
    private func setOption(_ name: String, _ value: String) -> Bool {
        cf_engine_set_option(handle.pointer, name, value)
    }

    // ----------------------------------------------------------------- paused

    public var isPaused: Bool { gate.withLock { $0.isPaused } }

    /// Stops searching, and holds anything that wants to search.
    ///
    /// Stopping is not abandoning: the running search still reports the best move it had
    /// reached, so the screen on the way out does not go blank and the Score already written
    /// against the current ply stands.
    public func pause() {
        let wasRunning = gate.withLock { gate -> Bool in
            let changed = !gate.isPaused
            gate.isPaused = true
            return changed
        }
        guard wasRunning else { return }
        cf_engine_stop(handle.pointer)
    }

    /// Lets searching happen again, and releases everything the gate was holding.
    public func resume() {
        let released = gate.withLock { gate -> [CheckedContinuation<Void, Never>] in
            gate.isPaused = false
            let waiting = Array(gate.waiting.values)
            gate.waiting.removeAll()
            return waiting
        }
        for continuation in released { continuation.resume() }
    }

    /// Holds until searching is allowed, or until the calling Task is cancelled.
    ///
    /// The mutex is what makes cancellation safe rather than a hang: `onCancel` can run before
    /// the continuation has been stored, so the stored-check and the cancelled-check are both
    /// taken under the lock and whichever gets there first wins.
    private func waitWhilePaused() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let allowed = gate.withLock { gate -> Bool in
                    guard gate.isPaused, !Task.isCancelled else { return true }
                    gate.waiting[id] = continuation
                    return false
                }
                if allowed { continuation.resume() }
            }
        } onCancel: {
            let held = gate.withLock { $0.waiting.removeValue(forKey: id) }
            held?.resume()
        }
    }

    // -------------------------------------------------------------- analysis

    /// Deepening Analysis of the Game's current Position, one snapshot per Depth.
    ///
    /// The stream ends when the search stops — because the budget ran out, or because the
    /// consuming task went away. Ending the loop *is* the way to end an unbounded Analysis:
    /// the stream's termination handler stops the engine, so a screen that is dismissed takes
    /// its search with it, and there is no other stop to call.
    ///
    /// There is one engine, so there is one search. Asking for another supersedes the first:
    /// the running search is stopped, waited for, and its stream finished before this one
    /// installs itself, all in that order on the serial queue. Callers therefore cannot
    /// interleave two searches however hard they try, and no stream is ever left hanging.
    public func analyse(
        _ game: Game, budget: SearchBudget = .untilStopped, lines: Int = 3
    ) -> AsyncStream<Analysis> {
        let startFEN = game.startFEN
        let moves = game.uciMoves
        let state = game.state
        let perspective = state.sideToMove
        let generation = generations.wrappingAdd(1, ordering: .relaxed).newValue

        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.stopSearch(generation)
            }

            queue.async { [self] in
                // Wind up whatever was running before touching the sink: `wait` is the
                // guarantee that no more of the old search's callbacks are in flight, so
                // the old and new streams cannot be crossed.
                cf_engine_stop(handle.pointer)
                cf_engine_wait(handle.pointer)

                // The previous search has fully stopped, so an option change here cannot race
                // one. MultiPV is the one option the app varies per search — everything else is
                // set once at init because changing it rebuilds the thread pool — and Stockfish
                // applies it to the search this go starts.
                if lines != multiPV {
                    cf_engine_set_option(handle.pointer, "MultiPV", "\(max(1, lines))")
                    multiPV = lines
                }

                // Accumulates the MultiPV lines of one Depth, then emits them together.
                let group = Mutex(DepthGroup(state: state, perspective: perspective))
                let emit: @Sendable () -> Void = {
                    let ready: Analysis? = group.withLock { $0.take() }
                    if let ready { continuation.yield(ready) }
                }

                let superseded = sink.withLock { current -> Sink in
                    let previous = current
                    current = Sink(
                        generation: generation,
                        onInfo: { info in
                            let flush = group.withLock { $0.absorb(info) }
                            if flush { emit() }
                        },
                        onFinish: {
                            emit()
                            continuation.finish()
                        }
                    )
                    return previous
                }
                superseded.onFinish?()

                // The pause rule, applied at the one way in. A standing Analysis belongs to a
                // screen someone is looking at, so a paused engine does not start one — the
                // screen asks again on the way back. A bounded search is a job whose answer is
                // being waited on, and those hold at the gate instead (`review`, `evaluate`)
                // rather than coming back empty — which is why only the unbounded case is
                // refused here.
                let refused = isPaused && !SearchGate.admits(budget)
                let started = refused ? false : withCStrings(moves) { pointers in
                    var limits = budget.cLimits
                    return cf_engine_go(
                        handle.pointer, startFEN, pointers,
                        Int32(moves.count), &limits,
                        Unmanaged.passUnretained(self).toOpaque(),
                        { context, info in
                            guard let context, let info else { return }
                            let service = Unmanaged<EngineService>
                                .fromOpaque(context).takeUnretainedValue()
                            service.sink.withLock { $0.onInfo }?(info.pointee)
                        },
                        { context, _, _ in
                            guard let context else { return }
                            let service = Unmanaged<EngineService>
                                .fromOpaque(context).takeUnretainedValue()
                            service.sink.withLock { $0.onFinish }?()
                        }
                    )
                }
                // An unusable position starts nothing, and says so by ending the stream
                // rather than leaving the caller waiting for a snapshot that never comes.
                if !started {
                    sink.withLock { current in
                        if current.generation == generation { current = Sink() }
                    }
                    continuation.finish()
                }
            }
        }
    }

    /// Stops the search this generation started, and only that one.
    private func stopSearch(_ generation: UInt64) {
        let isCurrent = sink.withLock { $0.generation == generation }
        guard isCurrent else { return }
        cf_engine_stop(handle.pointer)
    }

    /// The Score of a Game's current Position at one Depth, and nothing else — the
    /// baseline a Review needs for its first move, which has no ply before it to compare
    /// against.
    public func evaluate(_ game: Game, budget: SearchBudget) async -> Score? {
        await waitWhilePaused()
        guard !Task.isCancelled else { return nil }
        var last: Analysis?
        for await analysis in analyse(game, budget: budget, lines: 1) { last = analysis }
        return last?.best?.score
    }

    /// Re-scores every Position of a finished Game at one uniform Depth.
    ///
    /// Uniform is the whole point (see Review in CONTEXT.md): the Scores an Analysis
    /// happened to reach depend on how long each position was looked at, so they cannot be
    /// compared with each other. These can. The returned array has one entry per ply,
    /// each being the Score *after* that ply.
    ///
    /// Each ply comes back with the Line its search produced as well as its Score. The Line is
    /// free here and expensive anywhere else: this is the one pass that visits every position of
    /// a Game, and a board asking for a continuation later would be starting a Stint
    /// (docs/adr/0020, 0021).
    ///
    /// `onPly` reports each result as it lands, because a Review of a long game is a wait
    /// worth showing progress through rather than a spinner. It is called from the engine's
    /// queue, so anything it touches must be ready for that.
    public func review(
        _ game: Game, depth: Int, onPly: (@Sendable (Int, ReviewedPly) -> Void)? = nil
    ) async -> [ReviewedPly] {
        guard !game.plies.isEmpty else { return [] }
        var reviewed: [ReviewedPly] = []
        for ply in 1...game.plies.count {
            guard let position = game.rewound(to: ply) else {
                reviewed.append(ReviewedPly(score: nil))
                onPly?(ply - 1, ReviewedPly(score: nil))
                continue
            }
            // A Review holds where it stands while the app is away, and a ply the app left in
            // the middle of is done again rather than kept.
            //
            // Both halves matter, and neither used to happen. Pausing stops the running search,
            // so a ply interrupted by it reports whatever Depth it had got to; and the loop
            // would then start the next ply regardless, so every remaining one came back
            // shallow too. A Review whose Scores are not all at one Depth cannot be compared
            // against itself, which is the only thing it is for.
            var best: Analysis?
            repeat {
                await waitWhilePaused()
                if Task.isCancelled { break }
                best = nil
                // One line: a Review reads the best Score only, and every extra line is
                // twice the wait per ply of a walk that visits every ply of a long game.
                for await analysis in analyse(position, budget: .depth(depth), lines: 1) { best = analysis }
            } while isPaused && !Task.isCancelled
            let result = ReviewedPly(
                score: best?.best?.score,
                line: Array((best?.best?.san ?? []).prefix(Game.Ply.lineLimit))
            )
            reviewed.append(result)
            onPly?(ply - 1, result)
            if Task.isCancelled { break }
        }
        return reviewed
    }

    /// Forgets the transposition table and history. The honest thing to do before a Review,
    /// so an earlier Analysis of the same position cannot make one ply look deeper than the
    /// uniform Depth asked for.
    public func clear() async {
        await withCheckedContinuation { continuation in
            queue.async { [handle] in
                cf_engine_clear(handle.pointer)
                continuation.resume()
            }
        }
    }
}

// ------------------------------------------------------------------ plumbing

/// Collects the MultiPV lines belonging to one Depth, and turns Stockfish's raw info frames
/// into something a player can read.
///
/// The conversion used to be spread across the caller, which built a `Line` per frame and
/// handed it in. Now the group owns it: it knows the position and whose move it is, and a
/// frame in becomes an Analysis out — the White-relative flip and the mate conversion happen
/// here and nowhere else, so the whole conversion is testable without an engine behind it.
struct DepthGroup {
    private let state: GameState
    private let perspective: PieceColour
    private var depth = 0
    private var selectiveDepth = 0
    private var nodes: UInt64 = 0
    private var nodesPerSecond: UInt64 = 0
    private var timeMilliseconds: UInt64 = 0
    private var hashFull = 0
    private var isPartial = false
    private var lines: [Int: Line] = [:]

    init(state: GameState, perspective: PieceColour) {
        self.state = state
        self.perspective = perspective
    }

    /// Absorbs one info frame; returns true when the *previous* Depth is complete and should
    /// be emitted before this one is filled in.
    mutating func absorb(_ info: CfSearchInfo) -> Bool {
        // Stockfish walks multipv 1...N within a Depth, so index 1 opens a new group.
        let opensGroup = Int(info.multiPvIndex) <= 1 && !lines.isEmpty
        if opensGroup { pending = snapshot() }
        if opensGroup || Int(info.depth) != depth {
            if !opensGroup, !lines.isEmpty { pending = snapshot() }
            lines.removeAll()
            isPartial = false
        }
        depth = Int(info.depth)
        selectiveDepth = max(selectiveDepth, Int(info.selectiveDepth))
        nodes = info.nodes
        nodesPerSecond = info.nodesPerSecond
        timeMilliseconds = info.timeMs
        hashFull = Int(info.hashFull)
        if info.isBound { isPartial = true }
        lines[Int(info.multiPvIndex)] = Line(info, in: state, perspective: perspective)
        return pending != nil
    }

    private var pending: Analysis?

    /// The completed Depth, if one is waiting; otherwise whatever has been collected.
    mutating func take() -> Analysis? {
        if let ready = pending {
            pending = nil
            return ready
        }
        guard !lines.isEmpty else { return nil }
        return snapshot()
    }

    private func snapshot() -> Analysis {
        Analysis(
            depth: depth,
            selectiveDepth: selectiveDepth,
            lines: lines.sorted { $0.key < $1.key }.map(\.value),
            nodes: nodes,
            nodesPerSecond: nodesPerSecond,
            timeMilliseconds: timeMilliseconds,
            hashFull: hashFull,
            isPartial: isPartial
        )
    }
}

extension Line {
    /// One reported variation, turned into something a player can read.
    ///
    /// This is where the White-relative rule is enforced: Stockfish scores from the point of
    /// view of whoever is to move at the root, so a black-to-move position comes back with
    /// its sign inverted, and the flip happens here and nowhere else.
    init(_ info: CfSearchInfo, in state: GameState, perspective: PieceColour) {
        let sign = perspective == .white ? 1 : -1
        if info.isMate {
            // Stockfish counts plies, positive meaning the side to move delivers it.
            let plies = Int(info.matePlies)
            let moves = plies > 0 ? (plies + 1) / 2 : plies / 2
            score = .mate(in: sign * moves)
        } else {
            score = .centipawns(sign * Int(info.centipawns))
        }

        let text = withUnsafeBytes(of: info.pv) { bytes in
            String(decoding: Array(bytes.prefix { $0 != 0 }), as: UTF8.self)
        }
        uciMoves = text.split(separator: " ").map(String.init)

        // SAN needs the position each move is played from, so the line is replayed.
        var walked = Game(startFEN: state.fen)
        var written: [String] = []
        for move in uciMoves {
            guard var game = walked, game.apply(uci: move), let last = game.plies.last else {
                break
            }
            written.append(last.san)
            walked = game
        }
        san = written
    }
}

extension SearchBudget {
    var cLimits: CfSearchLimits {
        var limits = CfSearchLimits(movetimeMs: 0, depth: 0, nodes: 0)
        switch self {
        case .untilStopped:
            break
        case .time(let duration):
            let milliseconds =
                duration.components.seconds * 1000
                + duration.components.attoseconds / 1_000_000_000_000_000
            limits.movetimeMs = Int32(clamping: milliseconds)
        case .depth(let depth):
            limits.depth = Int32(clamping: depth)
        case .nodes(let nodes):
            limits.nodes = nodes
        }
        return limits
    }
}

extension EngineService.StartupFailure {
    init(_ status: CfEngineStatus) {
        switch status {
        case CF_ENGINE_NET_MISSING: self = .networkMissing
        case CF_ENGINE_NET_TOO_SMALL: self = .networkTooSmall
        case CF_ENGINE_ALLOC_FAILED: self = .allocationFailed
        default: self = .unknown
        }
    }
}
