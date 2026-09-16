import Foundation

extension Game {
    /// One of the player's own moves as 正着 reads it: whether it stood, whether a 试招 came
    /// before it, and the 棋力 it was played against (CONTEXT.md: 连正, 正着榜).
    ///
    /// The one walk under both readers of 正着. The row under the board counts these into a 连正
    /// and the 正着榜 credits them to rungs; each keeps its own sum, and what a move *is*
    /// — stood or not, after a slip or not — is decided here and nowhere else. It was decided in
    /// both, and the two had already begun to disagree about a refusal waiting at the end.
    public struct OwnMove: Hashable, Sendable {
        /// Counting from one. One past the last move for the place a refusal is waiting at.
        public let ply: Int
        /// Whether the move stood under 正着: judged, with the 拦截线 it stood under. A move
        /// measured with 正着 off did not stand under anything.
        public let stood: Bool
        /// Whether a 试招 was refused at the position this move was played from — the one thing
        /// that ends a 连正.
        public let afterSlip: Bool
        /// The 棋力 the engine was on when the move was played, nil against a human.
        public let strength: Strength?

        public init(ply: Int, stood: Bool, afterSlip: Bool, strength: Strength?) {
            self.ply = ply
            self.stood = stood
            self.afterSlip = afterSlip
            self.strength = strength
        }
    }

    /// The player's own moves in order, for the sides in `mine` — the sides the player moved: a
    /// game where the engine had Black is a game where Black's moves stood for Stockfish.
    ///
    /// A refusal still waiting at the end of the game, with no move played there yet, is a 试招 as
    /// surely as one a move has absorbed; it is only written somewhere else (docs/adr/0037). It is
    /// listed as the move that will be played there — the Ply one past the last — standing for
    /// nothing, so that a run reads as broken while the player is still stopped at it.
    public func ownMoves(by mine: Set<PieceColour>) -> [OwnMove] {
        let refusedAt = Set(pendingTried.filter { !$0.tries.isEmpty }.map(\.ply))
        var moves: [OwnMove] = []
        for (index, ply) in plies.enumerated() where mine.contains(mover(ofPly: index + 1)) {
            moves.append(OwnMove(
                ply: index + 1,
                stood: ply.judgement?.stoodUnderNoSlips == true,
                afterSlip: refusedAt.contains(index) || !ply.tried.isEmpty,
                strength: strength(ofPly: index + 1)
            ))
        }
        if refusedAt.contains(plies.count), mine.contains(mover(ofPly: plies.count + 1)) {
            moves.append(OwnMove(ply: plies.count + 1, stood: false, afterSlip: true, strength: nil))
        }
        return moves
    }

    /// 连正, read out of one game (CONTEXT.md).
    ///
    /// **Read, never counted on the side.** A move that stood under 正着 is one carrying a
    /// judgement with the 拦截线 it stood under (`Ply.Judgement.intercept`), and a 试招 is written
    /// where it happened (docs/adr/0037) — so a reopened game shows the same figures as when it
    /// was left, and a session that kept its own tally was one more place for it to be wrong.
    ///
    /// Only the run. A count of every move that stood (正着数, retired) was the length of the game
    /// whenever 正着 was on, which is a number the record already shows.
    public struct NoSlips: Hashable, Sendable {
        /// 连正: the run of the player's moves that stood since the last 试招. Only a 试招 ends
        /// it; switching 正着 off pauses it.
        public let run: Int
        /// The game's longest 连正.
        public let longestRun: Int

        public init(run: Int, longestRun: Int) {
            self.run = run
            self.longestRun = longestRun
        }

        public static let none = NoSlips(run: 0, longestRun: 0)
    }

    /// The 正着 figures of this game for the sides in `mine`.
    public func noSlips(by mine: Set<PieceColour>) -> NoSlips {
        var run = 0
        var longest = 0
        for move in ownMoves(by: mine) {
            if move.afterSlip { run = 0 }
            guard move.stood else { continue }
            run += 1
            longest = max(longest, run)
        }
        return NoSlips(run: run, longestRun: longest)
    }
}
