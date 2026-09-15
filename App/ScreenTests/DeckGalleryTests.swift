import ChessfenKit
import SwiftUI
import Testing

@testable import Chessfen

/// The deck under the board, one card per picture (docs/adr/0024).
///
/// Five cards, five PNGs, each with something real on it — a purpose, a mate with its arrows, a
/// shot, a walked line, a question with its verbs. The other suite photographs the
/// *screen* in the states a game passes through; this one photographs the *cards*, side by side
/// and comparable, which is what anybody redesigning them has to be able to lay out on a table.
///
/// So the assertions here are deliberately thin: each says only that the card it named is the card
/// that drew and that the thing it exists to show is on it. The pictures are the point.
@MainActor
@Suite(.serialized, .speaking(.chinese))
struct DeckGallery {
    private static let italian = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6"]
    /// White drops the knight on e5 and Black recaptures — a position with something hanging in
    /// it, which is what the 要害 card is about.
    private static let givenAway = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "f3e5", "c6e5"]

    private static let searching = [
        Analysis(
            depth: 26,
            selectiveDepth: 34,
            lines: [
                Line(
                    score: .centipawns(38),
                    uciMoves: ["d2d4", "e5d4", "c3d4", "c5b6", "e4e5", "d7d5"],
                    san: ["d4", "exd4", "cxd4", "Bb6", "e5", "d5"]
                ),
                Line(
                    score: .centipawns(21),
                    uciMoves: ["e1g1", "d7d6", "d2d4", "c5b6", "h2h3", "e8g8"],
                    san: ["O-O", "d6", "d4", "Bb6", "h3", "O-O"]
                ),
                Line(
                    score: .centipawns(9),
                    uciMoves: ["d2d3", "d7d6", "e1g1", "a7a6"],
                    san: ["d3", "d6", "O-O", "a6"]
                ),
            ],
            nodes: 63_400_000,
            nodesPerSecond: 2_480_000,
            timeMilliseconds: 25_600
        )
    ]

    private static func opinion(
        _ score: Score, best: (uci: String, san: String)? = nil, then: [String] = []
    ) -> Analysis {
        Analysis(
            depth: 14,
            selectiveDepth: 18,
            lines: [
                Line(
                    score: score,
                    uciMoves: best.map { [$0.uci] } ?? [],
                    san: best.map { [$0.san] + then } ?? []
                )
            ],
            nodes: 4_000_000,
            nodesPerSecond: 2_000_000,
            timeMilliseconds: 2_000
        )
    }

    private func hop() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func screen(
        _ session: GameSession, engine: any Engine, opening: GameScreen.Card
    ) -> some View {
        NavigationStack {
            GameScreen(session: session, path: .constant([]), opening: opening)
        }
        .environment(EngineHost(engine))
        .environment(GameLibrary())
    }

    // ------------------------------------------------------------------ 1 · 要害

    @Test("1 · 要害 — what this move is for")
    func key() async throws {
        let (session, engine) = try await layered()
        session.commitGuess()
        await hop()

        let rendered = await ScreenImage.write("deck-01-key") {
            screen(session, engine: engine, opening: .key)
        }
        #expect(rendered.says("要害"))
        #expect(!session.viewedContinuation.isEmpty, "the reveal paid for the line this reads")
    }

    // ------------------------------------------------------------------ 2 · 杀招

    @Test("2 · 杀招 — the news, with the line numbered on the board")
    func mate() async throws {
        // Morphy's opera game before 16.Qb8+: White mates in two and Black's reply is forced.
        let game = try #require(Game(startFEN: "4kb1r/p2n1ppp/4q3/4p1B1/4P3/1Q6/PPP2PPP/2KR4 w - - 0 1"))
        let engine = ScriptedEngine(
            [],
            byPosition: [
                game.state.fen: Analysis(
                    depth: 10,
                    lines: [
                        Line(
                            score: .mate(in: 2),
                            uciMoves: ["b3b8", "d7b8", "d1d8"],
                            san: ["Qb8+", "Nxb8", "Rd8#"]
                        )
                    ]
                )
            ]
        )
        let session = GameSession.fresh(game, controllers: [.white: .hand, .black: .engine])
        session.attach(engine: engine, library: nil)
        await hop()

        let rendered = await ScreenImage.write("deck-02-mate") {
            screen(session, engine: engine, opening: .mate)
        }
        #expect(rendered.says("你有 2 步杀"))
        #expect(rendered.says("Rd8#"))
    }

    // ------------------------------------------------------------------ 2 · 战术

    @Test("2 · 战术 — one shot, named in the verbs a player declares in")
    func tactics() async throws {
        let game = try #require(Game(startFEN: "4k3/8/8/3r4/8/8/8/3QK3 w - - 0 1"))
        let engine = ScriptedEngine(
            [],
            byPosition: [
                game.state.fen: Analysis(
                    depth: 10,
                    lines: [
                        Line(score: .centipawns(500), uciMoves: ["d1d5"], san: ["Qxd5"]),
                        Line(score: .centipawns(20), uciMoves: ["e1d2"], san: ["Kd2"]),
                    ]
                )
            ]
        )
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)

        let rendered = await ScreenImage.write("deck-02-tactics") {
            screen(session, engine: engine, opening: .tactics)
        }
        await hop()
        #expect(rendered.says("战术"))
    }

    // ------------------------------------------------------------------ 3 · 战术 is above

    // ------------------------------------------------------------------ 4 · 五步

    @Test("4 · 五步 — two of four plies walked, and where the whole line arrives")
    func walk() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let engine = ScriptedEngine(Self.searching, isEndless: true)
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        session.applyReview(
            game.plies.indices.map { ply in
                ReviewedPly(
                    score: .centipawns(20),
                    line: ply == 5 ? ["Nxe5", "Nxe5", "d4", "Bd6"] : []
                )
            },
            startEvaluation: nil,
            depth: 18
        )
        session.jump(toPly: 6)
        session.startWalk()
        session.stepWalk(by: 2)

        let rendered = await ScreenImage.write("deck-04-walk") {
            screen(session, engine: engine, opening: .walk)
        }
        #expect(rendered.says("五步"))
        #expect(rendered.says("第 2/4 步"))
    }

    /// 五步计划 lives under 五步, because the two are one card about looking five moves ahead: the
    /// five the engine would play, drawn on the board, and five of your own with one reason over
    /// the whole of them (docs/adr/0022, 0024).
    ///
    /// It was a card of its own and went with the ten when the deck was cut to five — the session
    /// kept all of it and nothing on the phone could reach it, which is a feature that goes missing
    /// without a single test going red. This is the test that says it is reachable.
    @Test("4 · 五步 — 五步计划 is the entry under the engine's line")
    func walkCarriesThePlan() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let engine = ScriptedEngine(Self.searching, isEndless: true)
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        session.applyReview(
            game.plies.indices.map { ply in
                ReviewedPly(
                    score: .centipawns(20),
                    line: ply == 5 ? ["Nxe5", "Nxe5", "d4", "Bd6"] : []
                )
            },
            startEvaluation: nil,
            depth: 18
        )
        session.jump(toPly: 6)

        let rendered = await ScreenImage.write("deck-04-walk-plan") {
            screen(session, engine: engine, opening: .walk)
        }
        #expect(rendered.says("回到开头"), "the engine's Line is still the card's first half")
        #expect(rendered.says("在棋盘上走五步，说一个理由，让引擎判对错。"))
        #expect(rendered.says("开始写"))

        // The press starts it and the walk stands down: one board, one hypothesis.
        session.startPlan()
        await hop()
        let drafting = await ScreenImage.write("deck-04-walk-plan-drafting") {
            screen(session, engine: engine, opening: .walk)
        }
        #expect(session.planDraft != nil)
        #expect(session.walk == nil, "a plan being written owns the board")
        #expect(drafting.says("在棋盘上随便走。走一步，下面就重算一次后面五步。"))

        // A move of your own, one reason over the line, and 交卷 — all of it read back off the card.
        session.playInPlan(try #require(session.board.state.move(matching: "d2d4")))
        session.choose(.attack)
        session.aim(at: try #require(Square("c5")))
        session.commitPlan()
        await hop()
        let judged = await ScreenImage.write("deck-04-walk-plan-judged") {
            screen(session, engine: engine, opening: .walk)
        }
        #expect(session.planDraft == nil)
        #expect(!session.game.plans(atPly: 6).isEmpty, "交卷 wrote the line into the record")
        #expect(judged.says("这条线进了棋谱，是这一步的一个变着。"))
        #expect(judged.says("说对了"), "and the one reason it was all for is judged")
        #expect(judged.says("第 1 步 d4 的时候成立"), "with the step that made the claim true named")
    }

    // ------------------------------------------------------------------ 5 · 练习

    @Test("5 · 练习 — the question, answered, with all three moves side by side")
    func drill() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let asked = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: Array(Self.italian.prefix(6)))
        )
        let guessed = try #require(
            Game(
                startFEN: PGN.standardStartFEN,
                uciMoves: Array(Self.italian.prefix(6)) + ["d2d4"]
            )
        )
        let played = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: Array(Self.italian.prefix(7)))
        )
        let engine = ScriptedEngine(
            Self.searching,
            isEndless: true,
            byPosition: [
                asked.state.fen: Self.opinion(
                    .centipawns(45), best: ("e1g1", "O-O"), then: ["d6", "d4"]
                ),
                guessed.state.fen: Self.opinion(.centipawns(20)),
                played.state.fen: Self.opinion(.centipawns(38)),
            ]
        )
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        session.jump(toPly: 6)
        session.offer(try #require(session.viewed.state.move(matching: "d2d4")))
        session.choose(.attack)
        session.aim(at: try #require(Square("c5")))
        session.commitGuess()
        await hop()

        let rendered = await ScreenImage.write("deck-05-drill") {
            screen(session, engine: engine, opening: .drill)
        }
        #expect(rendered.says("练习"))
        #expect(rendered.says("d4"))
    }

    /// The position right after White threw the knight away, with a Guess on the board that is not
    /// the recapture — the setup both the rings and the ranked squares are for.
    private func layered() async throws -> (GameSession, ScriptedEngine) {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.givenAway))
        let asked = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: Array(Self.givenAway.prefix(7)))
        )
        let guessed = try #require(
            Game(
                startFEN: PGN.standardStartFEN,
                uciMoves: Array(Self.givenAway.prefix(7)) + ["d8g5"]
            )
        )
        let engine = ScriptedEngine(
            Self.searching,
            isEndless: true,
            byPosition: [
                asked.state.fen: Self.opinion(.centipawns(30), best: ("d2d3", "d3")),
                guessed.state.fen: Self.opinion(
                    .centipawns(25), best: ("e5f3", "Nf3"), then: ["Qf6", "d3", "d6"]
                ),
            ]
        )
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        session.jump(toPly: 7)
        session.offer(try #require(session.viewed.state.move(matching: "d8g5")))
        session.choose(.attack)
        session.aim(at: try #require(Square("e5")))
        return (session, engine)
    }
}
