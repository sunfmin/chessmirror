@testable import ChessmirrorKit
import Foundation
import Testing

// Regression contract: replay the real phone game's critical white move through the real
// interception gate. A move that costs >=10 points must be refused.
// No library is attached: the phone/iCloud PGN is never written.
//
// What the move costs is read from the session's own search, not from a second one. The session
// judges from the engine's plain search of both positions, at depth twenty unless ten seconds come
// first, through the same `MoveQuality.drop`. A second depth-twenty search of the two positions
// gave the same 掉幅 to a hundredth (13.60 against the session's 13.62, 19. Kxh3) and was most of
// this test's time: 9–18s of 20–33s alone, measured 2026-11-21.
@MainActor
@Test func phoneGameInterceptionDiagnosis() async throws {
        try await Quietly.alone {
    let pgn = try PGN(parsing: """
    [Result "0-1"]
    1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. d3 Nf6 5. Bg5 h6 6. Bh4 d6 7. O-O a6 8. c3 Ba7
    9. Nbd2 g5 10. Bg3 Qe7 11. h3 Rg8 12. b4 g4 13. hxg4 Bxg4 14. Re1 Nh5 15. Bh2
    Bh3 16. g3 Nxg3 17. Bxg3 Rxg3+ 18. Kh2 Rg6 19. Kxh3 Qd7+ 20. Kh2 Qg4 21. Rg1
    Qh5+ 22. Nh4 Qxh4# 0-1
    """)
    let engine = try EngineService(bigNetURL: Nets.big, smallNetURL: Nets.small,
                                   configuration: .init(threads: 2, hashMegabytes: 32, multiPV: 1))
    let index = 36
    let position = try #require(Game(startFEN: PGN.standardStartFEN,
                                    uciMoves: Array(pgn.game.uciMoves.prefix(index))))
    let session = GameSession.fresh(position, engine: engine)
    session.noSlips(at: 10)
    await session.waitForPreparedInterception()
    let move = try #require(position.state.move(matching: pgn.game.plies[index].uci))
    session.play(move)
    await session.settled()
    let refused = session.refused
    session.suspend()
    let san = pgn.game.plies[index].san
    if let refused {
        print("Phone regression: \(index / 2 + 1). \(san) refused, drop=\(refused.drop) depth=\(String(describing: refused.depth))")
        #expect(refused.san == san, "the move that was refused came back")
        #expect(refused.drop >= 10, "a refusal under a line of ten must have cost ten")
        #expect(session.game.plies.count == position.plies.count)
    } else {
        // What is a failure — the bug this test was written for — is a move that stands with
        // no judgement at all: 正着 switched on, the position searched, and nothing written
        // down or said. A passing move has to have been weighed, and weighed as a pass.
        let judged = try #require(
            session.game.plies.last?.judgement,
            "a move that stands under 正着 must have been weighed"
        )
        print("Phone regression: \(index / 2 + 1). \(san) stood, drop=\(judged.drop) depth=\(judged.depth)")
        #expect(judged.drop < 10, "the session passed a move its own search calls a mistake")
        // On a loaded machine ten seconds can come before depth twenty, and a shallower search can
        // read the move a point or two kinder, near the line: then "it stood" is not by itself a
        // failure. At depth twenty it is: the real phone position must still demonstrate a
        // mistake, or this test no longer exercises a refusal.
        #expect(judged.depth < PositionSearches.depth,
                "at depth \(judged.depth) the real phone position must still demonstrate a mistake")
    }

        }}
