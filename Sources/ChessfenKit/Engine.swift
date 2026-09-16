import Foundation

/// How long a search is allowed to think, and what ends it.
///
/// A free type rather than something nested in `EngineService`, because it is the vocabulary of
/// the *interface* and not of one adapter: `PositionSearches.budget` is what every live search is
/// given and has no business naming a Stockfish wrapper to say what a budget means, and a fake
/// engine should be able to record what it was asked for without importing the real one's
/// namespace.
public enum SearchBudget: Hashable, Sendable {
    /// Deepen until told to stop. What an Analysis in front of the player uses.
    case untilStopped
    /// Think for this long and stop.
    case time(Duration)
    /// Stop when either limit is reached, without starting another search.
    case timeOrDepth(Duration, Int)
    case depth(Int)
    case nodes(UInt64)

    /// Whether this search is one that runs until somebody stops it, which is the distinction the
    /// pause gate turns on: an unbounded search belongs to a screen someone is looking at and is
    /// refused while the app is away, where a bounded one is held and run on the way back
    /// (docs/adr/0009).
    public var isUnbounded: Bool { self == .untilStopped }
}

/// The engine, as the app asks for it.
///
/// There is still exactly one engine and it is still `EngineService` (docs/adr/0009); this
/// changes nothing about that. It exists so a screen or a session can be *put* into a state
/// instead of having to be played into one: a test hands it an engine that reports a fixed
/// Analysis, and everything above the seam — `retune`, `record`, the Score written against a
/// ply, every view — is the real code. The alternative is to reach those states by loading
/// 112 MiB of weights and waiting on a search whose numbers are different every run.
///
/// It lives here, beside `EngineService`, rather than in the app: an interface belongs on the
/// side of the seam that both adapters can reach, and the tests that most need a substitute are
/// the package's own.
///
/// The whole of what the app asks of an engine, and no more: a search of a position, the shared
/// store those searches are joined through, and the pause gate for the app leaving the front.
/// `evaluate`, `review` and `clear` used to be requirements too, and nothing asked them of an
/// `any Engine` — only the real service, directly, in its own tests — so every fake carried
/// three stubs for a seam nothing crossed. A fake now implements one search and a gate.
public protocol Engine: AnyObject, Sendable {
    var positionSearches: PositionSearches { get }
    var isPaused: Bool { get }
    /// `lines` is how many candidate Lines each snapshot carries. A search whose only
    /// product is a move needs one; advice shown to a player wants the three the panel
    /// has room for. Each extra line roughly doubles the time to a given Depth, so the
    /// number is asked per search rather than set once.
    ///
    /// `strength` is the 棋力 the search is bound to, and it is asked per search for the same
    /// reason: only the opponent's own move is ever bound, and every other search — 细判, a hint,
    /// a card, the finder — is at 满力 whatever the game is being played at (docs/adr/0038).
    func analyse(
        _ game: Game, budget: SearchBudget, lines: Int, strength: Strength
    ) -> AsyncStream<Analysis>
    /// A background position yields to foreground searches and resumes after interruption.
    /// The real service has its own; a fake gets the walk below for free.
    func analyseInBackground(_ game: Game, depth: Int) async -> Analysis?
    func pause()
    func resume()
}

extension Engine {
    /// A search at 满力, which is every search but the opponent's own move.
    public func analyse(_ game: Game, budget: SearchBudget, lines: Int) -> AsyncStream<Analysis> {
        analyse(game, budget: budget, lines: lines, strength: .full)
    }

    public func analyseInBackground(_ game: Game, depth: Int) async -> Analysis? {
        var result: Analysis?
        for await snapshot in analyse(game, budget: .depth(depth), lines: 1) {
            guard !Task.isCancelled else { return nil }
            if snapshot.depth == depth, !snapshot.isPartial { result = snapshot }
        }
        return result
    }
}

extension EngineService: Engine {}
