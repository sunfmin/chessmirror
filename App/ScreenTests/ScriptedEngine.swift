import ChessfenKit
import Synchronization

/// An engine that reports what it was told to report.
///
/// ScreenTests' copy of the fake the kit tests drive sessions with — a second
/// test bundle cannot import the first, so the one file has two homes that must
/// stay in step. The kit's is at Tests/ChessfenKitTests/ScriptedEngine.swift.
///
/// The seam is the search and nothing above it (see `Engine`): a screen driven by this one runs
/// the real `retune`, the real `record`, the real Score written against the real ply — what is
/// faked is only the one thing in the app that cannot be asked twice for the same answer.
final class ScriptedEngine: Engine {
    /// The snapshots every search reports, in order, deepest last — a real search deepens, and a
    /// screen that redraws on each snapshot should be made to do it.
    private let snapshots: [Analysis]
    /// Whether the search ever finishes. A search that ends is a search that has answered, which
    /// is what an engine holding a Controller does; leaving it open is what being thought *about*
    /// looks like.
    private let isEndless: Bool
    private let paused = Mutex(false)
    /// Every search that has been asked for, and the clock it was given.
    ///
    /// How many there have been matters because the real engine answers a second request by
    /// throwing the first one away, which looks the same from a screen and not at all the same
    /// from a phone. What each was given matters because time is the only dial the app has: a
    /// budget is the whole of how hard the engine was asked to play (docs/adr/0009).
    private let asked = Mutex<[SearchBudget]>([])
    private let askedLines = Mutex<[Int]>([])

    /// Every search asked for so far, in order, each with the clock it was given.
    var budgets: [SearchBudget] { asked.withLock { $0 } }

    /// The candidate-line count each of those searches was asked for.
    var lines: [Int] { askedLines.withLock { $0 } }

    var searchCount: Int { budgets.count }

    /// An opinion per position, keyed by FEN, for the searches that are *about* particular
    /// positions rather than about deepening: a study asks three questions of three positions and
    /// has to get three answers.
    private let byPosition: [String: Analysis]

    init(
        _ snapshots: [Analysis], isEndless: Bool = false, byPosition: [String: Analysis] = [:]
    ) {
        self.snapshots = snapshots
        self.isEndless = isEndless
        self.byPosition = byPosition
    }

    var isPaused: Bool { paused.withLock { $0 } }
    func pause() { paused.withLock { $0 = true } }
    func resume() { paused.withLock { $0 = false } }
    func clear() async {}

    func analyse(_ game: Game, budget: SearchBudget, lines: Int) -> AsyncStream<Analysis> {
        asked.withLock { $0.append(budget) }
        askedLines.withLock { $0.append(lines) }
        let scripted = byPosition[game.state.fen].map { [$0] } ?? snapshots
        let isEndless = byPosition[game.state.fen] == nil && self.isEndless
        return AsyncStream { continuation in
            for snapshot in scripted { continuation.yield(snapshot) }
            // An endless search never finishes on its own: it ends when the stream goes away,
            // which is the one way the real engine ends one too.
            if !isEndless { continuation.finish() }
        }
    }

    func evaluate(_ game: Game, budget: SearchBudget) async -> Score? {
        byPosition[game.state.fen]?.best?.score ?? snapshots.last?.best?.score
    }

    /// One result per ply, walked down the script so a curve has something to be a curve about.
    /// The scripted Line rides along with the Score, because that is what the real pass does now
    /// and a screen reading one must be able to be handed one (docs/adr/0021).
    func review(
        _ game: Game, depth: Int, onPly: (@Sendable (Int, ReviewedPly) -> Void)?
    ) async -> [ReviewedPly] {
        game.plies.indices.map { ply in
            let best = snapshots[min(ply, snapshots.count - 1)].best
            let result = ReviewedPly(
                score: best?.score, line: Array((best?.san ?? []).prefix(Game.Ply.lineLimit))
            )
            onPly?(ply, result)
            return result
        }
    }
}
