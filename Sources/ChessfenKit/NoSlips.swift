import Foundation

extension Game {
    /// 正着数 and 连正, read out of one game (CONTEXT.md).
    ///
    /// **Read, never counted on the side.** A move that stood under 正着 is one carrying a
    /// judgement with the 拦截线 it stood under (`Ply.Judgement.intercept`), and a 试招 is written
    /// where it happened (docs/adr/0037) — so a reopened game shows the same figures as when it
    /// was left, and a session that kept its own tally was one more place for it to be wrong.
    public struct NoSlips: Hashable, Sendable {
        /// 正着数: the player's own moves that stood while 正着 was on. Moves played with 正着
        /// off are not counted, and moves against a human count all the same.
        public let distance: Int
        /// 连正: the run of the player's moves that stood since the last 试招. Only a 试招 ends
        /// it; switching 正着 off pauses it.
        public let run: Int
        /// The game's longest 连正.
        public let longestRun: Int

        public init(distance: Int, run: Int, longestRun: Int) {
            self.distance = distance
            self.run = run
            self.longestRun = longestRun
        }

        public static let none = NoSlips(distance: 0, run: 0, longestRun: 0)
    }

    /// The 正着 figures of this game for the sides in `mine`, which are the sides the player
    /// moved: a game where the engine had Black is a game where Black's moves stood for Stockfish.
    public func noSlips(by mine: Set<PieceColour>) -> NoSlips {
        var distance = 0
        var run = 0
        var longest = 0
        // A refusal still waiting at a position is a 试招 there as surely as one a move has
        // absorbed; it is only written somewhere else (docs/adr/0037).
        let refusedAt = Set(pendingTried.filter { !$0.tries.isEmpty }.map(\.ply))
        for (index, ply) in plies.enumerated() where mine.contains(mover(ofPly: index + 1)) {
            if refusedAt.contains(index) || !ply.tried.isEmpty { run = 0 }
            guard ply.judgement?.stoodUnderNoSlips == true else { continue }
            distance += 1
            run += 1
            longest = max(longest, run)
        }
        if refusedAt.contains(plies.count), mine.contains(mover(ofPly: plies.count + 1)) {
            run = 0
        }
        return NoSlips(distance: distance, run: run, longestRun: longest)
    }
}
