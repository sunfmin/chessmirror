import Foundation

/// How long a search is allowed to think, and what ends it.
///
/// A free type rather than something nested in `EngineService`, because it is the vocabulary of
/// the *interface* and not of one adapter: `ThinkingTime` and `MirroredTime` are clocks and have
/// no business naming a Stockfish wrapper to say what a clock means, and a fake engine should be
/// able to record what it was asked for without importing the real one's namespace.
public enum SearchBudget: Hashable, Sendable {
    /// Deepen until told to stop. What an Analysis in front of the player uses.
    case untilStopped
    /// Mirrored Time: think for about as long as the player took.
    case time(Duration)
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
/// The whole of what the app asks of an engine, and no more: analysis for the game screen,
/// evaluate/review for the Review, and the pause gate for the app leaving the front.
public protocol Engine: AnyObject, Sendable {
    var isPaused: Bool { get }
    /// `lines` is how many candidate Lines each snapshot carries. A search whose only
    /// product is a move needs one; advice shown to a player wants the three the panel
    /// has room for. Each extra line roughly doubles the time to a given Depth, so the
    /// number is asked per search rather than set once.
    func analyse(_ game: Game, budget: SearchBudget, lines: Int) -> AsyncStream<Analysis>
    func pause()
    func resume()
    func clear() async
    func evaluate(_ game: Game, budget: SearchBudget) async -> Score?
    /// One `ReviewedPly` per ply: the Score after that ply, and the Line the same search
    /// produced. The Line is picked up here because this is the only search that visits every
    /// position of a Game, and fetching it later would cost a Stint (docs/adr/0020, 0021).
    func review(
        _ game: Game, depth: Int, onPly: (@Sendable (Int, ReviewedPly) -> Void)?
    ) async -> [ReviewedPly]
}

extension EngineService: Engine {}
