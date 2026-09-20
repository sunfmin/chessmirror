import Foundation

/// A temporary reply exercise. The parent game is never passed by reference or written here.
@Observable @MainActor public final class Punishment {
    public let position: Game
    public private(set) var isJudging = false
    public private(set) var isFinished = false {
        didSet { if isFinished, !oldValue { onFinish?() } }
    }
    /// Told once, when the exercise finishes — answered, revealed or skipped. How the session
    /// that put it on the board hears that the board is the game's again.
    @ObservationIgnored var onFinish: (@MainActor () -> Void)?
    public private(set) var wasIncorrect = false
    public private(set) var revealedMove: String?
    /// Two percentage points at the interception depth allow equivalent replies without requiring PV identity.
    public static let tolerance = 2.0
    private let engine: any Engine
    private var task: Task<Void, Never>?
    /// Waits until the reply has been checked: what a session's `settled` folds in.
    public func settled() async { await task?.value }

    public init(position: Game, engine: any Engine) {
        self.position = position
        self.engine = engine
        isFinished = position.state.legalMoves.isEmpty
    }

    public func submit(_ move: Move) {
        guard !isFinished, !isJudging else { return }
        var after = position
        guard after.apply(move) else { return }
        isJudging = true
        wasIncorrect = false
        task = Task { [weak self] in
            guard let self else { return }
            // The reply is weighed exactly as the move it answers was (`Weighing`): the same two
            // searches, the same scale, and nil for a search that said nothing.
            let weighed = await engine.weigh(after, from: position)
            guard !Task.isCancelled else { return }
            isJudging = false
            guard let weighed else { return }
            isFinished = weighed.drop <= Self.tolerance
            wasIncorrect = !isFinished
        }
    }

    public func skip() {
        task?.cancel()
        task = nil
        isJudging = false
        isFinished = true
    }

    public func reveal() {
        guard !isFinished else { return }
        task?.cancel()
        isJudging = true
        task = Task { [weak self] in
            guard let self else { return }
            let answer = await engine.positionResult(position)?.best?.san.first
            guard !Task.isCancelled else { return }
            revealedMove = answer
            isJudging = false
            isFinished = true
        }
    }
}
