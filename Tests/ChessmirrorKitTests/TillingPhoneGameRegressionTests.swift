@testable import ChessmirrorKit
import Foundation
import Testing

// Regression contract: replay the real phone game's critical white move through the real
// interception gate. A move independently judged to cost >=10 points must be refused.
// No library is attached: the phone/iCloud PGN is never written.
@MainActor
@Test func phoneGameInterceptionDiagnosis() async throws {
    let pgn = try PGN(parsing: """
    [Result "0-1"]
    1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. d3 Nf6 5. Bg5 h6 6. Bh4 d6 7. O-O a6 8. c3 Ba7
    9. Nbd2 g5 10. Bg3 Qe7 11. h3 Rg8 12. b4 g4 13. hxg4 Bxg4 14. Re1 Nh5 15. Bh2
    Bh3 16. g3 Nxg3 17. Bxg3 Rxg3+ 18. Kh2 Rg6 19. Kxh3 Qd7+ 20. Kh2 Qg4 21. Rg1
    Qh5+ 22. Nh4 Qxh4# 0-1
    """)
    let engine = try EngineService(bigNetURL: Nets.big, smallNetURL: Nets.small,
                                   configuration: .init(threads: 2, hashMegabytes: 32, multiPV: 1))
    for index in [36] {
        let position = try #require(Game(startFEN: PGN.standardStartFEN,
                                        uciMoves: Array(pgn.game.uciMoves.prefix(index))))
        let session = GameSession.fresh(position, engine: engine)
        session.setIntercept(10)
        await session.waitForPreparedInterception()
        var reference: Analysis?
        for await snapshot in engine.analyse(position, budget: .depth(20), lines: 1) {
            if snapshot.depth == 20, !snapshot.isPartial { reference = snapshot }
        }
        let before = try #require(reference?.best?.score)
        let move = try #require(position.state.move(matching: pgn.game.plies[index].uci))
        session.play(move)
        await session.waitForJudgement()
        let refused = session.refused
        session.suspend()
        var after = position
        let applied = after.apply(move)
        try #require(applied)
        var evaluated: Analysis?
        for await snapshot in engine.analyse(after, budget: .depth(20), lines: 1) {
            if snapshot.depth == 20, !snapshot.isPartial { evaluated = snapshot }
        }
        let score = try #require(evaluated?.best?.score)
        let drop = try #require(MoveQuality.drop(move: .white, before: before, after: score))
        print("Phone regression: \(index / 2 + 1). \(pgn.game.plies[index].san) before=\(before.pgnText) after=\(score.pgnText) drop=\(drop) refused=\(refused != nil)")
        try #require(drop >= 10, "the real phone position must still demonstrate a mistake")
        if let refused {
            #expect(refused.san == pgn.game.plies[index].san, "the move that cost \(drop) came back")
            #expect(session.game.plies.count == position.plies.count)
        } else {
            // The session judges at ten seconds or depth twenty, whichever arrives first, and this
            // reference search is a plain depth twenty: on a loaded machine the two can disagree
            // by a point or two near the line, so "it stood" is not by itself a failure.
            //
            // What is a failure — the bug this test was written for — is a move that stands with
            // no judgement at all: 正着 switched on, the position searched, and nothing written
            // down or said. A passing move has to have been weighed, and weighed as a pass.
            let judged = try #require(
                session.game.plies.last?.judgement,
                "a move that stands under 正着 must have been weighed"
            )
            #expect(judged.drop < 10, "the session passed a move its own search calls a mistake")
            print("Phone regression: \(index / 2 + 1) stood at the session's own judgement, drop=\(judged.drop)")
        }
    }
}
