import ChessfenKit
import Foundation
import Testing

@Suite struct TacticsTests {
    /// White queen on d1, black rook hanging on d5.
    private static let hangingRook = "4k3/8/8/3r4/8/8/8/3QK3 w - - 0 1"
    /// White knight on c4 can jump to d6 and fork the king and the queen on b7.
    private static let knightFork = "4k3/1q6/8/8/2N5/8/8/4K3 w - - 0 1"

    private func game(_ fen: String) throws -> Game {
        try #require(Game(startFEN: fen))
    }

    private func analysis(_ lines: [(Score, String, String, [String])]) -> Analysis {
        Analysis(
            depth: Tactic.probeDepth,
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
                    (.centipawns(220), "e2e4", "e4", ["e5", "Nf3"]),
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

@MainActor @Suite struct TacticsSessionTests {
    private func hop() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func opening() throws -> Game {
        try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6"]))
    }

    @Test("with the finder off, practice still starts no search")
    func finderOffStartsNothing() async throws {
        let engine = ScriptedEngine(
            [Analysis(depth: 10, lines: [Line(score: .centipawns(20), uciMoves: ["e2e4"], san: ["e4"])])]
        )
        let session = GameSession.fresh(try #require(Game(startFEN: PGN.standardStartFEN)))
        session.attach(engine: engine, library: nil)
        #expect(session.isPractising)
        #expect(!session.isFindingTactics)

        session.play(try #require(session.viewed.state.move(matching: "e2e4")))
        await hop()
        #expect(engine.searchCount == 0, "practice with the finder off asks nothing")
        #expect(session.tactic == nil)
    }

    @Test("turning the finder on probes the latest position at depth 10, two lines")
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

        #expect(engine.budgets == [.depth(Tactic.probeDepth)])
        #expect(engine.lines == [2])
        #expect(session.tactic == nil, "a twelve-centipawn gap is not a Tactic")
        #expect(session.tacticPrompt == "这一步没有战术")
    }

    /// The rule this test used to assert has been turned round (docs/adr/0024): the finder is a
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
        #expect(engine.budgets.last == .depth(Tactic.probeDepth))
        #expect(session.tacticPrompt == "这一步没有战术", "and it answers about that position")
        // Nothing was played: the engine only moves from the latest position.
        #expect(session.game.plies.count == 4)
    }

    /// Jumping the record and opening 杀招 is the asking. The probe is bounded; when it
    /// ends, 正在算 must end with it. A leftover task would keep the card spinning, and a
    /// later swipe onto 要害 would think the engine was still busy and never spend its Stint.
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
                    depth: 10,
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
        // What the screen does on arriving at 杀招: the finder, then the card's own Stint.
        session.setFindingTactics(true)
        session.adviseForCard()
        await hop()

        #expect(session.isPractising)
        #expect(!session.isSearching, "the probe has finished; 正在算 must not stay on")
        #expect(!session.isProbingTactics)

        session.adviseForCard()
        await hop()
        #expect(
            engine.budgets.last == .untilStopped,
            "要害 can still spend a Stint once the probe has put the engine down"
        )
    }
}
