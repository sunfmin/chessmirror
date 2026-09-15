import Foundation

/// A temporary reply exercise. The parent game is never passed by reference or written here.
@Observable @MainActor public final class Punishment {
    public let position: Game
    public private(set) var isJudging = false
    public private(set) var isFinished = false
    public private(set) var wasIncorrect = false
    public private(set) var revealedMove: String?
    /// Two percentage points at the interception depth allow equivalent replies without requiring PV identity.
    public static let tolerance = 2.0
    private let engine: any Engine
    private var task: Task<Void, Never>?
    func waitForJudgement() async { await task?.value }

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
            let before = await score(position)
            guard !Task.isCancelled else { return }
            let result = await score(after)
            guard !Task.isCancelled else { return }
            isJudging = false
            guard let drop = MoveQuality.drop(move: position.state.sideToMove, before: before, after: result)
            else { return }
            isFinished = drop <= Self.tolerance
            wasIncorrect = !isFinished
        }
    }

    private func score(_ game: Game) async -> Score? {
        if game.state.outcome == .checkmate {
            return .mate(in: game.state.sideToMove == .white ? -1 : 1)
        }
        if game.state.outcome.isDraw { return .centipawns(0) }
        var result: Score?
        for await snapshot in engine.analyse(game, budget: .depth(GameSession.interceptDepth), lines: 1) {
            guard !Task.isCancelled else { return nil }
            if snapshot.depth == GameSession.interceptDepth, !snapshot.isPartial { result = snapshot.best?.score }
        }
        return result
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
            var answer: String?
            for await snapshot in engine.analyse(position, budget: .depth(GameSession.interceptDepth), lines: 1) {
                guard !Task.isCancelled else { return }
                if snapshot.depth >= GameSession.interceptDepth, !snapshot.isPartial { answer = snapshot.best?.san.first }
            }
            guard !Task.isCancelled else { return }
            revealedMove = answer
            isJudging = false
            isFinished = true
        }
    }
}
