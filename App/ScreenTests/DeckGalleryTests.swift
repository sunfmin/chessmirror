import ChessfenKit
import SwiftUI
import Testing

@testable import Chessfen

/// The deck under the board, one card per picture (docs/adr/0025).
///
/// Two cards, two PNGs, each with something real on it — a mate with its line numbered on the
/// board, and a shot the engine found. The other suite photographs the *screen* in the states a
/// game passes through; this one photographs the *cards*, side by side and comparable, which is
/// what anybody redesigning them has to be able to lay out on a table.
///
/// So the assertions here are deliberately thin: each says only that the card it named is the card
/// that drew and that the thing it exists to show is on it. The pictures are the point.
@MainActor
@Suite(.serialized, .speaking(.chinese))
struct DeckGallery {
    @Test(arguments: [320, 440]) func faceToFaceRotatesOnlyTheTopPlayersPieces(_ width: Int) async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let session = GameSession.fresh(game)
        let engine = ScriptedEngine([])
        defer { session.suspend() }
        let rendered = await ScreenImage.write("face-to-face-\(width)", size: CGSize(width: width, height: 850), interact: { window in
            #expect(!session.isFaceToFace)
            #expect(ScreenImage.activate(localized("board.faceToFace"), in: window))
            await ScreenImage.settle()
            #expect(session.isFaceToFace)
            #expect(session.game == game)
            #expect(session.controller(for: .white) == .hand)
            #expect(session.controller(for: .black) == .hand)
            let normal = BoardView(pieces: [:], isFaceToFace: session.isFaceToFace)
            #expect(normal.pieceRotation(for: .black) == 180)
            #expect(normal.pieceRotation(for: .white) == 0)
            let flipped = BoardView(pieces: [:], orientation: .blackAtBottom, isFaceToFace: true)
            #expect(flipped.pieceRotation(for: .white) == 180)
            #expect(flipped.pieceRotation(for: .black) == 0)
        }) { screen(session, engine: engine, opening: .tactics) }
        #expect(rendered.says(localized("board.faceToFace")))
        #expect(!rendered.says("1. e4"))
        let pixels = try #require(ScreenImage.Pixels(of: rendered.url))
        #expect(pixels.fullWidthBoardRows > pixels.width / 2)
    }
    @Test(arguments: [-133, 133]) func signedChangeAndCurveShareTheLastPosition(_ score: Int) async throws {
        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
        let engine = ScriptedEngine([], byPosition: [
            start.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])]),
            game.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(score), uciMoves: [], san: [])])
        ])
        let session = GameSession.fresh(game, engine: engine)
        session.showPositionFeedback()
        await session.measureLatestMoveChange()
        defer { session.suspend() }
        let value = String(format: "%+.1f%%", Score.centipawns(score).winPercent - 50)
        let rendered = await ScreenImage.write("standing-change-\(score)", size: CGSize(width: 320, height: 850)) {
            screen(session, engine: engine, opening: .tactics)
        }
        #expect(rendered.says(localized("standing.change", value)))
        #expect(rendered.says(localized("record.curve")))
        #expect(session.historyScore(atPly: game.plies.count) == .centipawns(score))
        #expect(session.feedbackScore == .centipawns(score))
    }
    @Test(arguments: [320, 393]) func standingKeepsLabelsAboveTheFullWidthBar(_ width: Int) async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let engine = ScriptedEngine([Analysis(depth: 20, lines: [
            Line(score: .centipawns(35), uciMoves: ["e2e4"], san: ["e4"])
        ])])
        let session = GameSession.fresh(game, engine: engine)
        session.setIntercept(5)
        defer { session.suspend() }
        let rendered = await ScreenImage.write("standing-layout-\(width)",
            size: CGSize(width: width, height: 850)) {
            screen(session, engine: engine, opening: .tactics)
        }
        #expect(rendered.says(localized("till.name")))
        #expect(rendered.says(localized("game.depth", 20)))
        #expect(rendered.says(localized("standing.bar")))
        #expect(GameScreen.boardSide(in: CGSize(width: width, height: 600)) == CGFloat(width))
    }
    @Test func standingTillingLabelTogglesWithoutOpeningSettings() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let engine = ScriptedEngine([Analysis(depth: 20, lines: [
            Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
        ])])
        let session = GameSession.fresh(game, engine: engine)
        defer { session.suspend() }
        session.setIntercept(7)
        let rendered = await ScreenImage.write("tilling-toggle-off", interact: { window in
            let before = ScreenImage.words(in: window)
            #expect(!before.contains(localized("till.intercept")))
            #expect(ScreenImage.activate(localized("till.name"), in: window))
            await ScreenImage.settle()
            #expect(!session.isTilling)
            #expect(ScreenImage.words(in: window) != before)
            #expect(ScreenImage.words(in: window).contains { $0.contains(localized("standing.bar")) })
            #expect(ScreenImage.activate(localized("till.name"), in: window))
            await ScreenImage.settle()
            #expect(session.lines.intercept == 7)
            #expect(ScreenImage.activate(localized("till.name"), in: window))
            await ScreenImage.settle()
            #expect(!session.isTilling)
        }) {
            screen(session, engine: engine, opening: .tactics)
        }
        #expect(rendered.says(localized("till.name")))
        #expect(rendered.says(localized("till.off")))
        #expect(!rendered.says(localized("screen.opinion")))
        #expect(!rendered.says("练习"))
        #expect(session.game == game)
    }
    @Test(arguments: [false, true]) func playerSettingsExpandInPlace(_ engineOpponent: Bool) async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let engine = ScriptedEngine([Analysis(depth: 20, lines: [
            Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
        ])])
        let session = GameSession.fresh(game,
            controllers: [.white: .hand, .black: engineOpponent ? .engine : .hand], engine: engine)
        defer { session.suspend() }
        session.setIntercept(JudgementLines.defaultIntercept)
        let rendered = await ScreenImage.write(engineOpponent ? "game-settings-inline-engine" : "game-settings-inline", interact: { window in
            let before = ScreenImage.words(in: window)
            #expect(!before.contains(localized("till.intercept")))
            #expect(ScreenImage.activate(localized("game.settings.expand", PieceColour.black.label), in: window))
            await ScreenImage.settle()
            let after = ScreenImage.words(in: window)
            #expect(after != before)
            #expect(after.contains(localized("till.intercept")))
            #expect(window.rootViewController?.presentedViewController == nil)
            if engineOpponent {
                #expect(after.contains(localized("search.limit")))
                #expect(!after.contains(ThinkingTime.fixed(seconds: 3).label))
            }
            #expect(ScreenImage.activate(localized("punish.toggle"), in: window))
            await ScreenImage.settle()
            #expect(session.findsPunishment)
            #expect(ScreenImage.activate(localized("punish.toggle"), in: window))
            await ScreenImage.settle()
            #expect(!session.findsPunishment)
            #expect(ScreenImage.activate(localized("till.name"), in: window))
            await ScreenImage.settle()
            #expect(!session.isTilling)
            #expect(ScreenImage.activate(localized("till.name"), in: window))
            await ScreenImage.settle()
            #expect(session.lines.intercept == 5)
            #expect(ScreenImage.activate(localized("game.settings.collapse", PieceColour.black.label), in: window))
            await ScreenImage.settle()
            #expect(!ScreenImage.words(in: window).contains(localized("till.intercept")))
            #expect(ScreenImage.activate(localized("game.settings.expand", PieceColour.black.label), in: window))
        }) {
            screen(session, engine: engine, opening: .tactics)
        }
        #expect(rendered.says(localized("till.intercept")))
        #expect(rendered.says(localized("game.settings.collapse", PieceColour.black.label)))
        #expect(GameScreen.boardSide(in: CGSize(width: 440, height: 600)) == 440)
    }

    @Test func tillingShowsOnlyCompactReturnedAttempts() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let afterD4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["d2d4"]))
        let engine = ScriptedEngine([Analysis(depth: 20, lines: [
            Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"]),
            Line(score: .centipawns(-300), uciMoves: ["d2d4"], san: ["d4"])
        ])], byPosition: [afterD4.state.fen: Analysis(depth: 12, lines: [
            Line(score: .centipawns(-300), uciMoves: ["d7d5"], san: ["d5"])
        ])])
        let session = GameSession.fresh(game, engine: engine)
        defer { session.suspend() }
        session.setIntercept(JudgementLines.defaultIntercept)
        await hop()
        session.play(try #require(game.state.move(matching: "d2d4")))
        await hop()
        try #require(session.refused != nil)
        session.play(try #require(game.state.move(matching: "e2e4")))
        await hop()
        try #require(session.game.plies.count == 1)
        let rendered = await ScreenImage.write("tilling-cost-history") {
            screen(session, engine: engine, opening: .tactics)
        }
        #expect(rendered.says(localized("till.returned")))
        #expect(rendered.says("d4"))
        #expect(!rendered.says("1. d4"))
        #expect(!rendered.says("1. e4"))
        #expect(rendered.says("−25.1%"))
        #expect(!rendered.says("−0.0%"))
        #expect(rendered.says(localized("standing.change", "+0.0%")))
        #expect(rendered.says(localized("standing.bar")))
        #expect(!rendered.says("提示 1"))
        #expect(!rendered.says("提示 2"))
    }

    /// Contract: a 已退回 move can be asked what it was asking for. Pressing it puts the 应招 on
    /// the row and on the board, and pressing it again puts both away (docs/adr/0034).
    @Test func pressingAReturnedMoveShowsTheReplyItEarned() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let afterD4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["d2d4"]))
        let engine = ScriptedEngine([Analysis(depth: 20, lines: [
            Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"]),
            Line(score: .centipawns(-300), uciMoves: ["d2d4"], san: ["d4"])
        ])], byPosition: [afterD4.state.fen: Analysis(depth: 20, lines: [
            Line(score: .centipawns(-300), uciMoves: ["d7d5", "g1f3"], san: ["d5", "Nf3"])
        ])])
        let session = GameSession.fresh(game, engine: engine)
        defer { session.suspend() }
        session.setIntercept(JudgementLines.defaultIntercept)
        await hop()
        session.play(try #require(game.state.move(matching: "d2d4")))
        await hop()
        try #require(session.refused != nil)
        session.play(try #require(game.state.move(matching: "e2e4")))
        await hop()
        try #require(session.visibleAttempts.first?.line == ["d5", "Nf3"])
        let rendered = await ScreenImage.write("tilling-returned-reply", interact: { window in
            let before = ScreenImage.words(in: window)
            #expect(!before.contains { $0.contains("Nf3") }, "the answer waits to be asked for")
            #expect(!before.contains { $0.contains(localized("tried.reply")) })
            #expect(ScreenImage.activate("d4", in: window), "the returned move must be pressable")
            await ScreenImage.settle()
            let after = ScreenImage.words(in: window)
            #expect(after.contains { $0.contains(localized("tried.reply")) })
            #expect(after.contains { $0.contains("d5") })
            #expect(after.contains { $0.contains("Nf3") })
            #expect(ScreenImage.activate("d4", in: window))
            await ScreenImage.settle()
            #expect(!ScreenImage.words(in: window).contains { $0.contains("Nf3") })
            // Pressed a third time, so the picture is of the answer rather than of the question.
            #expect(ScreenImage.activate("d4", in: window))
            await ScreenImage.settle()
            #expect(ScreenImage.words(in: window).contains { $0.contains("Nf3") })
        }) {
            screen(session, engine: engine, opening: .tactics)
        }
        #expect(rendered.says(localized("tried.reply")))
        #expect(rendered.says("Nf3"))
        #expect(rendered.says("d5"))
        #expect(rendered.says(localized("till.returned")))
        #expect(session.game.uciMoves == ["e2e4"])
        #expect(session.visibleAttempts.first?.line == ["d5", "Nf3"])
    }
    @Test func viewingAMateRequiresAnExplicitPressAndResetsAfterMoving() async throws {
        let game = try #require(Game(startFEN:
            "4kb1r/p2n1ppp/4q3/4p1B1/4P3/1Q6/PPP2PPP/2KR4 w - - 0 1"))
        let engine = ScriptedEngine([Analysis(depth: 10, lines: [
            Line(score: .mate(in: 2), uciMoves: ["b3b8", "d7b8", "d1d8"],
                 san: ["Qb8+", "Nxb8", "Rd8#"])
        ])])
        let session = GameSession.fresh(game, engine: engine)
        let move = try #require(game.state.legalMoves.first { $0.uci == "b3b8" })
        defer { session.suspend() }
        let rendered = await ScreenImage.write("mate-after-moving", interact: { window in
            let before = ScreenImage.words(in: window)
            #expect(!before.contains { $0.contains("Rd8#") })
            #expect(ScreenImage.activate(localized("discovery.view"), in: window),
                    "the rendered View button must accept a real accessibility action")
            await ScreenImage.settle()
            let after = ScreenImage.words(in: window)
            #expect(after != before)
            #expect(after.contains { $0.contains("Rd8#") }, "View must reveal the actual line")
            #expect(ScreenImage.activate(localized("discovery.view"), in: window))
            await ScreenImage.settle()
            #expect(!ScreenImage.words(in: window).contains { $0.contains("Rd8#") },
                    "pressing an expanded finding must collapse its answer")
            #expect(ScreenImage.activate(localized("discovery.view"), in: window))
            await ScreenImage.settle()
            #expect(ScreenImage.words(in: window).contains { $0.contains("Rd8#") })
            session.play(move)
            await ScreenImage.settle()
        }) {
            screen(session, engine: engine, opening: .mate)
        }
        #expect(session.game.uciMoves == ["b3b8"])
        #expect(!rendered.says("Rd8#"), "new positions require a new explicit reveal")
    }
    @Test(.speaking(.chinese)) func tillingChinese() async throws { try await localizedTilling() }
    @Test(.speaking(.english)) func tillingEnglish() async throws { try await localizedTilling() }
    @Test(.speaking(.japanese)) func tillingJapanese() async throws { try await localizedTilling() }
    @Test(.speaking(.korean)) func tillingKorean() async throws { try await localizedTilling() }
    @Test(.speaking(.french)) func tillingFrench() async throws { try await localizedTilling() }
    @Test(.speaking(.german)) func tillingGerman() async throws { try await localizedTilling() }
    @Test(.speaking(.spanish)) func tillingSpanish() async throws { try await localizedTilling() }
    @Test(.speaking(.portuguese)) func tillingPortuguese() async throws { try await localizedTilling() }

    private func localizedTilling() async throws {
        let language = Speech.language
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let engine = ScriptedEngine([Analysis(depth: 20, lines: [
            Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
        ])])
        let session = GameSession.fresh(game, engine: engine)
        defer { session.suspend() }
        session.setIntercept(10)
        let rendered = await ScreenImage.write("tilling-\(language.rawValue)") {
            screen(session, engine: engine, opening: .tactics)
        }
        #expect(rendered.says(localized("till.name")))
        #expect(rendered.says(localized("game.depth", 20)))
        #expect(!rendered.says("e4"), "the prepared answer must stay hidden")

        let mateGame = try #require(Game(startFEN:
            "4kb1r/p2n1ppp/4q3/4p1B1/4P3/1Q6/PPP2PPP/2KR4 w - - 0 1"))
        let mateEngine = ScriptedEngine([Analysis(depth: 10, lines: [
            Line(score: .mate(in: 2), uciMoves: ["b3b8", "d7b8", "d1d8"],
                 san: ["Qb8+", "Nxb8", "Rd8#"])
        ])])
        let mateSession = GameSession.fresh(mateGame, engine: mateEngine)
        defer { mateSession.suspend() }
        let mate = await ScreenImage.write("mate-\(language.rawValue)") {
            screen(mateSession, engine: mateEngine, opening: .mate)
        }
        let news = try #require(mateSession.mateNews)
        #expect(mate.says(localized("discovery.mateFound")))
        #expect(mate.says(localized("discovery.view")))
        #expect(!mate.says(news.sentence))
        #expect(!mate.says("Rd8#"))
        if language != .chinese { #expect(!mate.says("你有 2 步杀")) }

        let tacticGame = try #require(Game(startFEN: "4k3/8/8/3r4/8/8/8/3QK3 w - - 0 1"))
        let tacticEngine = ScriptedEngine([Analysis(depth: 10, lines: [
            Line(score: .centipawns(500), uciMoves: ["d1d5"], san: ["Qxd5"]),
            Line(score: .centipawns(20), uciMoves: ["e1d2"], san: ["Kd2"])
        ])])
        let tacticSession = GameSession.fresh(tacticGame, engine: tacticEngine)
        defer { tacticSession.suspend() }
        tacticSession.setFindingTactics(true)
        let tactic = await ScreenImage.write("tactics-\(language.rawValue)") {
            screen(tacticSession, engine: tacticEngine, opening: .tactics)
        }
        let shot = try #require(tacticSession.tactic)
        #expect(tactic.says(localized("discovery.tacticFound")))
        #expect(!tactic.says(shot.sentence))
        #expect(!tactic.says("Qxd5"))
        if language != .chinese { #expect(!tactic.says("这一步有没有一记赢子的")) }
    }

    @Test func tillingStartsWithoutAnalysisAnswers() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let engine = ScriptedEngine([Analysis(depth: 20, lines: [
            Line(score: .centipawns(500), uciMoves: ["e2e4"], san: ["e4"])
        ])])
        let session = GameSession.fresh(game, engine: engine)
        session.setIntercept(10)
        let rendered = await ScreenImage.write("tilling-no-hints") {
            screen(session, engine: engine, opening: .tactics)
        }
        #expect(rendered.says("耕棋"))
        #expect(!rendered.says("提示 1"))
        #expect(!rendered.says("提示 2"))
        #expect(rendered.says(localized("game.depth", 20)))
        #expect(rendered.says(localized("standing.bar")))
        #expect(rendered.says("+5.00"))
        #expect(!rendered.says("这一步有没有一记赢子的"))
        #expect(!rendered.says("揭示答案"))
    }

    @Test func punishmentShowsPromptAndExplicitExits() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let afterD4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["d2d4"]))
        let engine = ScriptedEngine([Analysis(depth: 20, lines: [
            Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"]),
            Line(score: .centipawns(-300), uciMoves: ["d2d4"], san: ["d4"])
        ])], byPosition: [afterD4.state.fen: Analysis(depth: 12, lines: [
            Line(score: .centipawns(-300), uciMoves: ["d7d5"], san: ["d5"])
        ])])
        let session = GameSession.fresh(game, engine: engine)
        defer { session.suspend() }
        session.setIntercept(10)
        session.findsPunishment = true
        session.play(try #require(game.state.move(matching: "d2d4")))
        await hop()
        try #require(session.activePunishment != nil)
        let rendered = await ScreenImage.write("tilling-opponent-reply") {
            screen(session, engine: engine, opening: .tactics)
        }
        #expect(rendered.says("替对手走一步"))
        #expect(rendered.says("揭示答案"))
        #expect(rendered.says("跳过"))
        #expect(!rendered.says("提示 1"))
        #expect(rendered.says("\(PieceColour.black.label) · \(localized("game.toPlay"))"))
        #expect(!rendered.says("\(PieceColour.white.label) · \(localized("game.toPlay"))"))
        #expect(session.game == game)
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

    // ------------------------------------------------------------------ 1 · 杀招

    @Test("1 · 杀招 — the news, with the line numbered on the board")
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

        let rendered = await ScreenImage.write("deck-01-mate") {
            screen(session, engine: engine, opening: .mate)
        }
        #expect(rendered.says(localized("discovery.mateFound")))
        #expect(rendered.says(localized("discovery.view")))
        #expect(!rendered.says("你有 2 步杀"))
        #expect(!rendered.says("Rd8#"))
    }

    // ------------------------------------------------------------------ 2 · 战术

    @Test("2 · 战术 — one shot the engine found")
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
}
