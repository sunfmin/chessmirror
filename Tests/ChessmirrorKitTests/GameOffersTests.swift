@testable import ChessmirrorKit
import Foundation
import Testing
import ChessmirrorKitTesting

/// Contract: what the game screen offers is what the session will do. Each press the screen can
/// grey out has one answer, asked of the session, and the mutator behind the press refuses on the
/// same answer — so a live button is never a press that does nothing, and a greyed one is never
/// a press that would have worked.

private func opening(_ uciMoves: [String] = []) throws -> Game {
    try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: uciMoves))
}

private func analysis(_ cp: Int, _ uci: String, _ san: String) -> Analysis {
    Analysis(depth: 20, lines: [Line(score: .centipawns(cp), uciMoves: [uci], san: [san])])
}

/// A session whose board is spoken for: 把关 is weighing d4 and the answer never comes.
@MainActor
private func weighing(_ uciMoves: [String] = []) async throws -> GameSession {
    let game = try opening(uciMoves)
    let engine = ScriptedEngine([], isEndless: true, byPosition: [game.state.fen: analysis(0, "g1f3", "Nf3")])
    let session = GameSession.fresh(game, engine: engine)
    session.noSlips(at: 10)
    await session.waitForPreparedInterception()
    session.play(try #require(game.state.move(matching: "d2d4")))
    #expect(session.isOccupied)
    return session
}

@MainActor
@Suite struct GameOffersTests {
    /// 撤销 is offered when it would take a move off: at the latest move of a game that has one,
    /// and not while a move is being weighed. The menu used to spell only the first two, and
    /// stayed live over a weighing that `undo()` refused.
    @Test("撤销 is offered exactly when it takes a move off")
    func undoIsOfferedWhenItWorks() async throws {
        #expect(!GameSession.fresh(try opening()).canUndo, "nothing to take off")

        let played = GameSession.fresh(try opening(["e2e4", "e7e5"]))
        #expect(played.canUndo)
        played.step(by: -1)
        #expect(!played.canUndo, "not from anywhere but the latest move")
        played.jump(toPly: 2)
        played.undo()
        #expect(played.game.uciMoves == ["e2e4"])

        let occupied = try await weighing(["e2e4", "e7e5"])
        defer { occupied.suspend() }
        let before = occupied.game
        #expect(!occupied.canUndo, "not under a judgement")
        occupied.undo()
        #expect(occupied.game == before, "and pressing anyway does nothing")
    }

    /// A seat is handed over only when the board is not spoken for, and the engine's only once
    /// there is an engine to sit in it.
    @Test("a seat is offered when it can be taken")
    func aSeatIsOfferedWhenItCanBeTaken() async throws {
        let session = GameSession.fresh(try opening())
        #expect(session.canSeat(.hand))
        #expect(!session.canSeat(.engine), "no engine yet")
        session.attach(engine: ScriptedEngine([analysis(0, "e2e4", "e4")]), library: nil)
        #expect(session.canSeat(.engine))
        session.suspend()

        let occupied = try await weighing()
        defer { occupied.suspend() }
        #expect(!occupied.canSeat(.hand))
        #expect(!occupied.canSeat(.engine))
        occupied.setController(.engine, for: .black)
        #expect(occupied.controller(for: .black) == .hand)
    }

    /// 把关 turns on only with an engine to do the stopping, and does not move at all under a
    /// judgement.
    @Test("the 把关 switch is offered when it can move")
    func theNoSlipsSwitchIsOfferedWhenItCanMove() async throws {
        let bare = GameSession.fresh(try opening())
        #expect(!bare.canSwitchNoSlips, "off, and nothing to turn it on with")

        let engined = GameSession.fresh(
            try opening(), engine: ScriptedEngine([analysis(0, "e2e4", "e4")], isEndless: true)
        )
        defer { engined.suspend() }
        #expect(engined.canSwitchNoSlips)

        let occupied = try await weighing()
        defer { occupied.suspend() }
        #expect(occupied.isNoSlipsOn)
        #expect(!occupied.canSwitchNoSlips, "not under the judgement it is making")
    }

    /// A wrong move on the strip cannot be asked about while a 惩罚 exercise has the board.
    @Test("a wrong move is not read out under an exercise")
    func aWrongMoveIsNotReadUnderAnExercise() async throws {
        let game = try opening(["f2f3", "e7e5"])
        let afterG4 = try opening(["f2f3", "e7e5", "g2g4"])
        let engine = ScriptedEngine([], byPosition: [
            game.state.fen: analysis(-20, "d2d4", "d4"),
            afterG4.state.fen: Analysis(depth: 20, lines: [
                Line(score: .mate(in: -1), uciMoves: ["d8h4"], san: ["Qh4#"])
            ]),
        ])
        let session = GameSession.fresh(game, engine: engine)
        defer { session.suspend() }
        session.noSlips(at: 10)
        session.findsPunishment = true
        await session.waitForPreparedInterception()
        #expect(session.canReadReply)

        session.play(try #require(game.state.move(matching: "g2g4")))
        await session.settled()
        #expect(session.activePunishment != nil)
        #expect(!session.canReadReply)
        session.readReply(at: 0)
        #expect(session.replyReading == nil, "and asking anyway reads nothing")
    }

    /// A corrected position goes back into the game it came from only when nothing has been
    /// played there and the board is not spoken for — the answer the editor's button reads to say
    /// 「用这个」 rather than 「开始对局」.
    @Test("a correction goes back only where nothing is played")
    func aCorrectionGoesBackOnlyWhereNothingIsPlayed() async throws {
        let corrected = try #require(Game(startFEN: "4k3/8/8/8/8/8/8/4K2R w K - 0 1"))

        let untouched = GameSession.fresh(try opening())
        #expect(untouched.canReplaceStart)
        #expect(untouched.replaceStart(with: corrected))
        #expect(untouched.game.startFEN == corrected.startFEN)

        let played = GameSession.fresh(try opening(["e2e4"]))
        #expect(!played.canReplaceStart)
        #expect(!played.replaceStart(with: corrected))

        let occupied = try await weighing()
        defer { occupied.suspend() }
        #expect(!occupied.canReplaceStart)
        #expect(!occupied.replaceStart(with: corrected))
    }

    /// A search that has reported nothing says so in words; a depth is a figure.
    @Test("a depth of nought is not a report")
    func aDepthOfNoughtIsNotAReport() {
        Speech.speaking(.chinese) {
            #expect(Depth.label(0) == "正在计算")
            #expect(Depth.label(18) == "深度 18")
        }
    }

    /// The row under an import's record: the offer, the count while it runs, what it found.
    @Test("the review row says where the Review has got")
    func theReviewRowSaysWhereTheReviewHasGot() {
        Speech.speaking(.chinese) {
            let running = GameSession.ReviewRow.running(.init(judged: 1, total: 5))
            #expect(running.text == "正在分析 · 1/5 个局面")
            #expect(running.action == nil, "no second press while one runs")
            #expect(GameSession.ReviewRow.running(.init(judged: 0, total: 0)).text == "排队分析")

            let offered = GameSession.ReviewRow.offered(failed: false, canStart: true)
            #expect(offered.text == "这一局还没分析过，哪里走错了还不知道")
            #expect(offered.action == "分析这一局")
            #expect(GameSession.ReviewRow.offered(failed: false, canStart: false).action == "等引擎准备好")
            #expect(GameSession.ReviewRow.offered(failed: true, canStart: true).text == "分析没能完成，再试一次")

            #expect(GameSession.ReviewRow.done(slips: 2).text == "分析完了 · 本局 2 处错题，已加入错题本")
            #expect(GameSession.ReviewRow.done(slips: 0).text == "分析完了 · 这一局没有错题")
            #expect(GameSession.ReviewRow.done(slips: 0).action == nil)
        }
        #expect(GameSession.fresh(Game(startFEN: PGN.standardStartFEN)!).reviewRow == nil,
                "a game played here has nothing to review")
    }
}
