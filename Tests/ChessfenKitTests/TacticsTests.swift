@testable import ChessfenKit
import Foundation
import Testing
import ChessfenKitTesting

@Suite(.speaking(.chinese)) struct TacticsTests {
    /// White queen on d1, black rook hanging on d5.
    private static let hangingRook = "4k3/8/8/3r4/8/8/8/3QK3 w - - 0 1"
    /// White knight on c4 can jump to d6 and fork the king and the queen on b7.
    private static let knightFork = "4k3/1q6/8/8/2N5/8/8/4K3 w - - 0 1"

    private func game(_ fen: String) throws -> Game {
        try #require(Game(startFEN: fen))
    }

    private func analysis(_ lines: [(Score, String, String, [String])]) -> Analysis {
        Analysis(
            depth: PositionSearches.depth,
            lines: lines.map {
                Line(score: $0.0, uciMoves: [$0.1], san: [$0.2] + $0.3)
            }
        )
    }

    @Test("a winning capture of a hanging rook is a Tactic the rules can name")
    func hangingRookIsACapture() throws {
        let game = try game(Self.hangingRook)
        let shot = try #require(Tactic.proposed(in: game))
        #expect(shot.move.uci == "d1d5")
        #expect(shot.san.contains("xd5"))
        #expect(shot.intent == .claim(.take, try #require(Square("d5"))))
        #expect(shot.sentence.contains("没人守的车"))
    }

    @Test("a knight that checks the king and hangs the queen is a double attack")
    func knightForksKingAndQueen() throws {
        let game = try game(Self.knightFork)
        let shot = try #require(Tactic.proposed(in: game))
        #expect(shot.move.uci == "c4d6")
        #expect(shot.sentence.contains("同时打了"))
        #expect(shot.sentence.contains("王"))
        #expect(shot.sentence.contains("后"))
    }

    @Test("the starting position has no Tactic")
    func quietStartHasNone() throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        #expect(Tactic.proposed(in: game) == nil)
    }

    @Test("the engine agreeing with the rules keeps the shot")
    func engineAgreesKeepsTheShot() throws {
        let game = try game(Self.hangingRook)
        let confirmed = try #require(
            Tactic.confirmed(
                in: game,
                analysis: analysis([
                    (.centipawns(500), "d1d5", "Qxd5", []),
                    (.centipawns(20), "d1d2", "Qd2", []),
                ])
            )
        )
        #expect(confirmed.move.uci == "d1d5")
        #expect(confirmed.sentence.contains("没人守的车"))
        #expect(confirmed.line.first == "Qxd5")
    }

    @Test("the engine refusing the rules' shot drops it")
    func engineRefusesDropsTheShot() throws {
        let game = try game(Self.hangingRook)
        #expect(
            Tactic.confirmed(
                in: game,
                analysis: analysis([
                    (.centipawns(10), "e1d2", "Kd2", []),
                    (.centipawns(0), "e1f2", "Kf2", []),
                ])
            ) == nil
        )
    }

    @Test("a unique engine line the rules did not name still counts")
    func uniqueEngineLineCounts() throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        #expect(Tactic.proposed(in: game) == nil)
        let confirmed = try #require(
            Tactic.confirmed(
                in: game,
                analysis: analysis([
                    (.centipawns(300), "e2e4", "e4", ["e5", "Nf3"]),
                    (.centipawns(20), "d2d4", "d4", []),
                ])
            )
        )
        #expect(confirmed.move.uci == "e2e4")
        #expect(confirmed.san == "e4")
        #expect(!confirmed.sentence.isEmpty)
    }

    @Test("a quiet preference of twenty centipawns is not a Tactic")
    func quietPreferenceIsNotATactic() throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        #expect(
            Tactic.confirmed(
                in: game,
                analysis: analysis([
                    (.centipawns(32), "e2e4", "e4", []),
                    (.centipawns(20), "d2d4", "d4", []),
                ])
            ) == nil
        )
    }
}

@MainActor @Suite(.speaking(.chinese)) struct TacticsSessionTests {
    private func hop() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func opening() throws -> Game {
        try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6"]))
    }

    @Test("with the finder off, a move is weighed and no shot is looked for")
    func finderOffLooksForNothing() async throws {
        let engine = ScriptedEngine(
            [Analysis(depth: 10, lines: [Line(score: .centipawns(20), uciMoves: ["e2e4"], san: ["e4"])])]
        )
        let session = GameSession.fresh(try #require(Game(startFEN: PGN.standardStartFEN)))
        session.attach(engine: engine, library: nil)
        #expect(!session.isFindingTactics)

        session.play(try #require(session.viewed.state.move(matching: "e2e4")))
        await session.waitForJudgement()
        await hop()
        // The searches that ran are the shared position searches every move is weighed by
        // (docs/adr/0039, 0040); the finder asked for none of its own.
        #expect(engine.budgets.allSatisfy { $0 == PositionSearches.budget })
        #expect(!session.isProbingTactics)
        #expect(session.tactic == nil)
    }

    @Test("turning the finder on searches the position on screen once, sharing the bounded result")
    func finderOnProbesTheLatest() async throws {
        let game = try opening()
        let engine = ScriptedEngine(
            [],
            byPosition: [
                game.state.fen: Analysis(
                    depth: 10,
                    lines: [
                        Line(score: .centipawns(30), uciMoves: ["f1c4"], san: ["Bc4"]),
                        Line(score: .centipawns(24), uciMoves: ["d2d4"], san: ["d4"]),
                    ]
                )
            ]
        )
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        session.setFindingTactics(true)
        await hop()

        // The position on screen is searched once, shared by the finder, the badge and the
        // board; the badge's weighing of the last move also searches the position before it.
        #expect(engine.positions.filter { $0 == game.state.fen }.count == 1)
        #expect(engine.budgets.allSatisfy { $0 == PositionSearches.budget })
        #expect(engine.lines.allSatisfy { $0 == 2 }, "two lines: the shot, and the move it has to beat")
        #expect(session.tactic == nil, "a twelve-centipawn gap is not a Tactic")
        #expect(session.tacticPrompt == "这一步没有战术")
    }

    /// The rule this test used to assert has been turned round (docs/adr/0025): the finder is a
    /// card of its own, and swiping onto that card is the asking — wherever the eye is standing.
    @Test("browsing back and asking again probes the position being looked at")
    func aPastPlyIsProbedToo() async throws {
        let game = try opening()
        let past = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"])
        )
        let engine = ScriptedEngine(
            [],
            byPosition: [
                game.state.fen: Analysis(
                    depth: 10,
                    lines: [
                        Line(score: .centipawns(30), uciMoves: ["f1c4"], san: ["Bc4"]),
                        Line(score: .centipawns(24), uciMoves: ["d2d4"], san: ["d4"]),
                    ]
                ),
                past.state.fen: Analysis(
                    depth: 10,
                    lines: [
                        Line(score: .centipawns(28), uciMoves: ["g1f3"], san: ["Nf3"]),
                        Line(score: .centipawns(20), uciMoves: ["f1c4"], san: ["Bc4"]),
                    ]
                ),
            ]
        )
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        session.setFindingTactics(true)
        await hop()
        let probed = engine.searchCount

        session.jump(toPly: 2)
        await hop()
        #expect(engine.searchCount == probed + 1, "one bounded probe, on the position on screen")
        #expect(engine.budgets.last == PositionSearches.budget)
        #expect(session.tacticPrompt == "这一步没有战术", "and it answers about that position")
        // Nothing was played: the engine only moves from the latest position.
        #expect(session.game.plies.count == 4)
    }

    /// Jumping the record and opening 杀招 is the asking. The search is the shared bounded one,
    /// so when it ends 正在算 must end with it: a leftover task would keep the card spinning, and
    /// a later swipe onto 要害 would think the engine was still busy.
    @Test("a finished probe at a past ply is not still searching")
    func aFinishedProbeAtAPastPlyIsNotStillSearching() async throws {
        let game = try opening()
        let past = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"])
        )
        let engine = ScriptedEngine(
            [],
            byPosition: [
                past.state.fen: Analysis(
                    depth: PositionSearches.depth,
                    lines: [
                        Line(score: .centipawns(28), uciMoves: ["g1f3"], san: ["Nf3"]),
                        Line(score: .centipawns(20), uciMoves: ["f1c4"], san: ["Bc4"]),
                    ]
                )
            ]
        )
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        session.jump(toPly: 2)
        // What the screen does on arriving at 杀招: the finder, then the card's own look.
        session.setFindingTactics(true)
        await hop()

        #expect(!session.isSearching, "the shared search has finished; 正在算 must not stay on")
        #expect(!session.isProbingTactics)

        // 要害 then reads the same result. One search per position is the whole point of the
        // table, so asking for the card's answer must not buy a second one.
        let searches = engine.searchCount
        session.adviseForCard()
        await hop()
        #expect(engine.searchCount == searches, "要害 reads the result the probe paid for")
        #expect(session.analysis != nil, "and it reads it: the card has its Line")
        #expect(session.isAdviceSpent, "with nothing left to wait for")
    }
}
