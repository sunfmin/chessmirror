import ChessfenKit
import Foundation
import Testing

@Suite struct MateNewsTests {
    /// Morphy–Duke of Brunswick & Count Isouard, Paris 1858, before 16.Qb8+. White mates in two:
    /// 16.Qb8+ Nxb8 17.Rd8#, and Black's reply is the only legal move on the board — which is what
    /// makes it the right position to hold this code to.
    private static let opera = "4kb1r/p2n1ppp/4q3/4p1B1/4P3/1Q6/PPP2PPP/2KR4 w - - 0 1"
    /// The same game one ply on, after 16.Qb8+: Black to move, and being mated in one.
    private static let operaAfterCheck = "1Q2kb1r/p2n1ppp/4q3/4p1B1/4P3/8/PPP2PPP/2KR4 b - - 0 1"

    private func game(_ fen: String) throws -> Game {
        try #require(Game(startFEN: fen))
    }

    private func mateAnalysis(
        _ score: Score, _ line: [(uci: String, san: String)]
    ) -> Analysis {
        Analysis(
            depth: 20,
            lines: [
                Line(score: score, uciMoves: line.map(\.uci), san: line.map(\.san))
            ]
        )
    }

    private static let mateInTwo: [(uci: String, san: String)] = [
        ("b3b8", "Qb8+"), ("d7b8", "Nxb8"), ("d1d8", "Rd8#"),
    ]

    @Test("a mate for the side to move is read out as the player's own")
    func ourMateIsOurs() throws {
        let news = try #require(
            MateNews.read(
                mateAnalysis(.mate(in: 2), Self.mateInTwo),
                in: try game(Self.opera),
                hands: [.white]
            )
        )
        #expect(news.moves == 2)
        #expect(news.mater == .white)
        #expect(news.isOurs)
        #expect(news.head == "你有 2 步杀")
        #expect(news.reachesMate)
        // Counted, not asserted: Black really does have one legal move after Qb8+.
        #expect(news.replies == 1)
        #expect(news.forcedReplies == 1)
        #expect(news.sentence == "你起手 Qb8+，对方只有一个应手，Rd8# 将死。")
    }

    @Test("the same number with the other sign is the opponent's mate, in the player's own voice")
    func theirMateIsTheirs() throws {
        // The player is Black; White is the one mating. One position, one number, one code path.
        let news = try #require(
            MateNews.read(
                mateAnalysis(.mate(in: 2), Self.mateInTwo),
                in: try game(Self.opera),
                hands: [.black]
            )
        )
        #expect(news.mater == .white)
        #expect(!news.isOurs)
        #expect(news.head == "对方 2 步杀")
        #expect(news.sentence == "对方起手 Qb8+，你只有一个应手，Rd8# 将死。")
    }

    @Test("being mated opens with your own move, and the sentence says so")
    func beingMatedNamesTheBestTry() throws {
        // Black to move and lost: the line starts with Black's best try, not with White's plan.
        let news = try #require(
            MateNews.read(
                mateAnalysis(
                    .mate(in: 1), [("d7b8", "Nxb8"), ("d1d8", "Rd8#")]
                ),
                in: try game(Self.operaAfterCheck),
                hands: [.black]
            )
        )
        #expect(news.moves == 1)
        #expect(news.mater == .white)
        #expect(!news.isOurs)
        #expect(news.head == "对方 1 步杀")
        #expect(news.sentence.hasPrefix("你怎么走都躲不掉"))
        #expect(news.sentence.contains("引擎给的最好一手是 Nxb8"))
        #expect(news.sentence.hasSuffix("Rd8# 将死。"))
    }

    @Test("the arrows are numbered in order, the mating side's in the player's own colour")
    func arrowsAlternateAndAreNumbered() throws {
        let news = try #require(
            MateNews.read(
                mateAnalysis(.mate(in: 2), Self.mateInTwo),
                in: try game(Self.opera),
                hands: [.white]
            )
        )
        #expect(news.arrows.map(\.step) == [1, 2, 3])
        #expect(news.arrows.map(\.isYours) == [true, false, true])
        #expect(news.arrows.first?.move == MoveSquares(uci: "b3b8"))
        #expect(news.arrows.last?.move == MoveSquares(uci: "d1d8"))
        #expect(news.isFullyDrawn)
        #expect(news.arrows.allSatisfy { !$0.isPlayed })
    }

    @Test("a line longer than a board can carry is drawn as far as it can be, and says so")
    func longLinesAreCapped() throws {
        let line = [
            ("b3b8", "Qb8+"), ("d7b8", "Nxb8"), ("d1d8", "Rd8#"),
            ("b3b8", "Qb8+"), ("d7b8", "Nxb8"), ("d1d8", "Rd8+"), ("e8d8", "Kxd8"),
        ]
        let news = try #require(
            MateNews.read(
                mateAnalysis(.mate(in: 4), line), in: try game(Self.opera), hands: [.white]
            )
        )
        #expect(news.arrows.count == MateNews.arrowLimit)
        #expect(!news.isFullyDrawn)
        #expect(news.san.count == 7, "the rows keep the whole line even when the board cannot")
    }

    @Test("with nobody playing by hand, neither side is called yours")
    func engineAgainstItselfNamesColours() throws {
        let news = try #require(
            MateNews.read(
                mateAnalysis(.mate(in: 2), Self.mateInTwo), in: try game(Self.opera), hands: []
            )
        )
        #expect(!news.isOurs)
        #expect(news.head == "白方 2 步杀")
        #expect(news.sentence.hasPrefix("白方起手 Qb8+"))
        #expect(news.sentence.contains("黑方只有一个应手"))
        // The mating side still gets the near colour, or a line drawn on the board is one colour.
        #expect(news.arrows.map(\.isYours) == [true, false, true])
    }

    @Test("a mate Score whose line stops short is still news, and says what is missing")
    func aTruncatedLineSaysSo() throws {
        let news = try #require(
            MateNews.read(
                mateAnalysis(.mate(in: 3), [("b3b8", "Qb8+")]),
                in: try game(Self.opera),
                hands: [.white]
            )
        )
        #expect(!news.reachesMate)
        #expect(news.sentence.contains("没给到将死那一步"))
    }

    @Test("a Score that is not a mate is not news")
    func centipawnsAreNotNews() throws {
        #expect(
            MateNews.read(
                Analysis(depth: 20, lines: [Line(score: .centipawns(900), uciMoves: ["b3b8"], san: ["Qb8+"])]),
                in: try game(Self.opera),
                hands: [.white]
            ) == nil
        )
    }
}

@MainActor @Suite struct MateNewsSessionTests {
    private static let opera = "4kb1r/p2n1ppp/4q3/4p1B1/4P3/1Q6/PPP2PPP/2KR4 w - - 0 1"

    private func hop() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func mateInTwo(_ fen: String) -> [String: Analysis] {
        [
            fen: Analysis(
                depth: Tactic.probeDepth,
                lines: [
                    Line(
                        score: .mate(in: 2),
                        uciMoves: ["b3b8", "d7b8", "d1d8"],
                        san: ["Qb8+", "Nxb8", "Rd8#"]
                    )
                ]
            )
        ]
    }

    @Test("practice with the finder off says nothing, because nothing has been searched")
    func silentWithoutASearch() async throws {
        let game = try #require(Game(startFEN: Self.opera))
        let engine = ScriptedEngine([], byPosition: mateInTwo(game.state.fen))
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        await hop()

        #expect(session.isPractising)
        #expect(engine.searchCount == 0)
        #expect(session.mateNews == nil, "a mate nobody has looked for is not news")
    }

    @Test("the finder's probe is enough: practice keeps its silence about Scores and still says 杀")
    func theProbeCarriesTheNews() async throws {
        let game = try #require(Game(startFEN: Self.opera))
        let engine = ScriptedEngine([], byPosition: mateInTwo(game.state.fen))
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        session.setFindingTactics(true)
        await hop()

        let news = try #require(session.mateNews)
        #expect(news.moves == 2)
        #expect(news.head == "你有 2 步杀")
        #expect(news.arrows.count == 3)
        // The whole point of reading it off the probe: no Score reached the screen.
        #expect(session.isPractising)
        #expect(session.analysis == nil)
    }

    @Test("the switch going off takes the news with it")
    func theFinderOffIsSilent() async throws {
        let game = try #require(Game(startFEN: Self.opera))
        let engine = ScriptedEngine([], byPosition: mateInTwo(game.state.fen))
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        session.setFindingTactics(true)
        await hop()
        #expect(session.mateNews != nil)

        session.setFindingTactics(false)
        await hop()
        #expect(session.mateNews == nil)
    }

    /// The gate this test used to hold has been lifted (docs/adr/0024): a mate on a Ply somebody
    /// walked back to is the same fact about the same board, and 考一遍 is a card of its own that
    /// you have to leave to go and look.
    @Test("a past Ply gets the news too, because the news is about the board on screen")
    func aPastPlyIsNewsToo() async throws {
        let played = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6"])
        )
        let earlier = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"])
        )
        let engine = ScriptedEngine(
            [],
            byPosition: [
                played.state.fen: Analysis(
                    depth: Tactic.probeDepth,
                    lines: [Line(score: .mate(in: 3), uciMoves: ["f1c4"], san: ["Bc4"])]
                ),
                earlier.state.fen: Analysis(
                    depth: Tactic.probeDepth,
                    lines: [Line(score: .mate(in: 4), uciMoves: ["g1f3"], san: ["Nf3"])]
                ),
            ]
        )
        let session = GameSession.fresh(played)
        session.attach(engine: engine, library: nil)
        session.setFindingTactics(true)
        await hop()
        #expect(session.mateNews?.moves == 3)

        session.jump(toPly: 2)
        await hop()
        let news = try #require(session.mateNews, "the position on screen is the one it is about")
        #expect(news.moves == 4)
        #expect(news.head == "你有 4 步杀", "read out for the side the player holds, as ever")
    }
}
