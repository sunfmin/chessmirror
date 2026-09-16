import Foundation

/// 细判 of one move: what the app's own engine, at its own depth, says the move cost
/// (CONTEXT.md, docs/adr/0027).
///
/// **One act, wherever a move is weighed.** 正着 refusing a move as it lands, a drill judging an
/// attempt, the 惩罚 exercise checking a reply, the badge after a move stands, and a legacy game
/// being filled in all ask the same question of the same two searches, and each of them used to
/// run the searches itself, settle checkmate and draw by hand, and pick the depth and the 应招 out
/// of the second search on its own. Six copies of the same dozen lines, and the bugs that kept
/// coming back — a judgement that was never finished letting a move stand, a checkmate nobody had
/// listed, a depth recorded from the wrong search — all lived in those copies rather than in the
/// one pure function they shared.
///
/// Two shared bounded position searches (`PositionSearches`): the position the move was played
/// from, and the position it made. A position with an outcome is not searched — a checkmate is a
/// mate in one against the side to move, and a draw is level — because the engine has nothing to
/// add to a game that is over.
public struct Weighing: Hashable, Sendable {
    /// Who played the move, which is whose side the 掉幅 is read from.
    public let mover: PieceColour
    /// Everything the search knew about the position the move was played from: the best move
    /// and the lines beneath it. Kept whole rather than reduced to its Score, because the hint
    /// ladder, a move asked of the engine, and a drill's 「该走」 all read their answers off it.
    public let before: Analysis
    /// The Score of the position the move made.
    public let after: Score
    /// The Depth the second search reached, or the first search's when the position the move
    /// made was settled by its outcome. The depth a judgement is worth.
    public let depth: Int
    /// The 应招 the move earned: the Line the second search produced, in SAN, the opponent's move
    /// first, cut to what a board can carry (docs/adr/0034). Empty when the position the move
    /// made was already over, because there is nothing left to answer.
    public let reply: [String]
    /// 掉幅: percentage points of win probability the move gave away, from the mover's own side.
    /// Negative for a move that improved on what the engine had.
    public let drop: Double
    /// The move weighed, in UCI. Nil for a Weighing made without one, which cannot be 最佳.
    public let move: String?

    /// Nil when the search of the position played from had no line in it, which is a position
    /// nobody has looked at rather than a move that cost nothing (`MoveQuality.drop`).
    public init?(
        mover: PieceColour, before: Analysis, after: Score, depth: Int, reply: [String] = [],
        move: String? = nil
    ) {
        guard let drop = MoveQuality.drop(move: mover, before: before.best?.score, after: after) else {
            return nil
        }
        self.mover = mover
        self.before = before
        self.after = after
        self.depth = depth
        self.reply = Array(reply.prefix(Reply.limit))
        self.drop = drop
        self.move = move
    }

    /// 最佳: the move is the engine's own first choice from the position it was played from. Read
    /// off the search that judged it, so it is exact rather than a number that rounded to zero.
    public var isBest: Bool {
        move != nil && move == before.bestMove
    }

    /// The Score of the position the move was played from. Never missing: a Weighing is only
    /// made once the first search has said something.
    public var scoreBefore: Score { before.best?.score ?? after }

    /// What gets written onto the move if it is allowed to stand.
    public var judgement: Game.Ply.Judgement {
        .init(drop: drop, score: after, depth: depth)
    }
}

extension GameState {
    /// The Score a finished position has without anybody searching it: a checkmate is a mate in
    /// one against the side to move, and a draw is level. Nil for a position still being played,
    /// which is the only kind worth asking an engine about.
    public var outcomeScore: Score? {
        if outcome == .checkmate { return .mate(in: sideToMove == .white ? -1 : 1) }
        if outcome.isDraw { return .centipawns(0) }
        return nil
    }
}

extension Engine {
    /// Weighs the move that took `position` to `played`: the 细判 of one move, at the budget every
    /// live position search gets.
    ///
    /// Nil when the search was cancelled, or when the engine had nothing to say about the
    /// position the move was played from — paused, say. Nil is 「nobody looked」, and a caller
    /// must not read it as a move that cost nothing; the thing to do with it is to put the move
    /// back and say nothing.
    ///
    /// `progress` hears every snapshot of both searches as it arrives, for a strip that shows
    /// the engine working. On the main actor because everything that weighs a move is — a
    /// session, a drill, an exercise — and a progress strip is a piece of screen.
    @MainActor
    public func weigh(
        _ played: Game, from position: Game, progress: (Analysis) -> Void = { _ in }
    ) async -> Weighing? {
        // Join even when an interim answer exists: the shared search may still be deepening,
        // and the snapshot that ends the stream is the one the judgement is made from.
        var before: Analysis?
        for await snapshot in analysePosition(position) {
            guard !Task.isCancelled else { return nil }
            progress(snapshot)
            before = snapshot
        }
        guard !Task.isCancelled, let before else { return nil }
        let move = played.plies.last?.uci
        var after = played.state.outcomeScore
        var depth = before.depth
        var reply: [String] = []
        // A move the first search already has a Line for is judged from that Line: the Score,
        // the depth and the 应招 all come from the one search, which is the only way the two ends
        // of a 掉幅 are ever at one depth (docs/adr/0016). The engine's own first choice therefore
        // costs exactly nothing — a second search of the position it made would be a deeper look
        // at the same subtree, and the tens of centipawns the two disagree by read as a mistake
        // the engine made against itself, more than a 拦截线 apart in a sharp position.
        if after == nil, let move, let line = before.lines.first(where: { $0.bestMove == move }) {
            after = line.score
            reply = Array(line.san.dropFirst())
        }
        if after == nil {
            for await snapshot in analysePosition(played) {
                guard !Task.isCancelled else { return nil }
                progress(snapshot)
                after = snapshot.best?.score
                reply = snapshot.best?.san ?? []
                depth = snapshot.depth
            }
        }
        guard !Task.isCancelled, let after else { return nil }
        return Weighing(
            mover: position.state.sideToMove, before: before, after: after, depth: depth,
            reply: reply, move: move
        )
    }
}
