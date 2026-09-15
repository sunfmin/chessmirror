@testable import ChessfenKit
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
        session.requestHint()
        let before = try #require(session.hintScore)
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
        if drop >= 10 {
            #expect(refused != nil, "Phone game move \(index / 2 + 1) costs \(drop), but passed")
            #expect(session.game.plies.count == position.plies.count)
        }
    }
}
