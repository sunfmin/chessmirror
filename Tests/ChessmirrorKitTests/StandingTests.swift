@testable import ChessmirrorKit
import Foundation
import Testing
import ChessmirrorKitTesting

/// Contract: what the strip under the board says is one sentence chosen by one priority, and the
/// session chooses it from facts it already holds (`Standing`). Every voice is reachable here
/// with a scripted engine and no screen, and the number under the bar and the curve read one
/// ladder: the move just measured, then 正着's own judgement, then the Review's.

private func analysis(_ cp: Int, _ uci: String, _ san: String) -> Analysis {
    Analysis(depth: 20, lines: [.init(score: .centipawns(cp), uciMoves: [uci], san: [san])])
}

@MainActor
@Test func aFinishedGameOutranksEverything() throws {
    let mated = try #require(
        Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3", "e7e5", "g2g4", "d8h4"])
    )
    let session = GameSession.fresh(mated)
    defer { session.suspend() }
    #expect(session.standing == .finished("\(mated.turn) 0-1"))
}

@MainActor
@Test func aMoveIsSaidToBeWeighedWhileItIs() throws {
    let start = try #require(Game(startFEN: PGN.standardStartFEN))
    // An endless search: the move goes on the board and stays under judgement.
    let engine = ScriptedEngine([analysis(0, "e2e4", "e4")], isEndless: true)
    let session = GameSession.fresh(start, engine: engine)
    defer { session.suspend() }
    session.noSlips(at: 5)
    session.play(try #require(start.state.move(matching: "e2e4")))
    #expect(session.isWeighing)
    #expect(session.standing == .weighing)
}

@MainActor
@Test func aRefusalOutranksTheChangeTheLastMoveMade() async throws {
    let start = try #require(Game(startFEN: PGN.standardStartFEN))
    let afterE4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
    let afterF6 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "f7f6"]))
    // The engine wants d4; e4 is a move of the player's own, weighed from both positions.
    let engine = ScriptedEngine([], byPosition: [
        start.state.fen: analysis(0, "d2d4", "d4"),
        afterE4.state.fen: analysis(10, "e7e5", "e5"),
        afterF6.state.fen: analysis(300, "d1h5", "Qh5+"),
    ])
    let session = GameSession.fresh(start, engine: engine)
    defer { session.suspend() }
    session.noSlips(at: 5)
    await session.waitForPreparedInterception()

    session.play(try #require(start.state.move(matching: "e2e4")))
    await session.settled()
    guard case .change(let value) = session.standing else {
        Issue.record("a move that stood is said as the change it made, got \(session.standing)")
        return
    }
    #expect(value > 0, "e4 improved White's chances")
    #expect(Standing.changeLabel(value).hasPrefix("+"))

    session.play(try #require(afterE4.state.move(matching: "f7f6")))
    await session.settled()
    #expect(session.moveChange != nil, "the badge for e4 is still there underneath")
    guard case .refused(let refusal) = session.standing else {
        Issue.record("the refusal is what the strip says, got \(session.standing)")
        return
    }
    #expect(refusal.san == "f6")
}

/// The session badges the move itself: a move lands, and the change it made is there without any
/// screen asking for it — read from the player's own side, in tenths.
@MainActor
@Test func theChangeIsReadFromThePlayersSideWithoutBeingAskedFor() async throws {
    let start = try #require(Game(startFEN: PGN.standardStartFEN))
    let afterE4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
    let engine = ScriptedEngine([], byPosition: [
        start.state.fen: analysis(0, "d2d4", "d4"),
        afterE4.state.fen: analysis(133, "e7e5", "e5"),
    ])
    // Two hands, with Black facing the player: the bottom side supplies the perspective.
    let session = GameSession.fresh(start, engine: engine)
    defer { session.suspend() }
    session.orientation = .blackAtBottom
    session.play(try #require(start.state.move(matching: "e2e4")))
    #expect(session.game.uciMoves == ["e2e4"])
    await session.settled()

    // White's gain is the player's loss, in tenths.
    let expected = ((Score.centipawns(133).winPercent - 50) * -10).rounded() / 10
    #expect(session.standing == .change(expected))
    #expect(Standing.changeLabel(expected) == String(format: "%+.1f%%", expected))
    #expect(session.feedbackScore == .centipawns(133))
}

/// 最佳 is a fact about which move it was, not a number that rounded to zero: the engine's own
/// first choice is said as the word, whatever a second search of the position it made would have
/// said — because no second search is made (`Weighing`).
@MainActor
@Test func theEnginesOwnChoiceIsSaidAsBest() async throws {
    let start = try #require(Game(startFEN: PGN.standardStartFEN))
    let afterE4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
    let engine = ScriptedEngine([], byPosition: [
        start.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(30), uciMoves: ["e2e4", "e7e5"], san: ["e4", "e5"]),
            .init(score: .centipawns(20), uciMoves: ["d2d4"], san: ["d4"]),
        ]),
        // What a second search would say, tens of centipawns away, as one is entitled to be.
        afterE4.state.fen: analysis(-40, "e7e5", "e5"),
    ])
    let session = GameSession.fresh(start, engine: engine)
    defer { session.suspend() }
    session.noSlips(at: 5)
    await session.waitForPreparedInterception()

    session.play(try #require(start.state.move(matching: "e2e4")))
    await session.settled()
    #expect(session.standing == .best)
    #expect(session.game.plies.count == 1, "and 正着 never takes the engine's own move back")
    let judgement = try #require(session.game.plies[0].judgement)
    #expect(judgement.drop == 0)
    #expect(judgement.score == .centipawns(30), "the Score of its own Line, from the one search")
    #expect(judgement.stoodUnderNoSlips)

    // The second-best move is weighed from the same search too: its own Line's Score.
    let again = GameSession.fresh(start, engine: engine)
    defer { again.suspend() }
    again.noSlips(at: 5)
    await again.waitForPreparedInterception()
    again.play(try #require(start.state.move(matching: "d2d4")))
    await again.settled()
    let expected = ((Score.centipawns(30).winPercent - Score.centipawns(20).winPercent) * -10).rounded() / 10
    #expect(again.standing == .change(expected))
}

@Test func theChangeLabelNeverSaysMinusZero() {
    #expect(Standing.changeLabel(0) == "+0.0%")
    #expect(Standing.changeLabel(-0.0) == "+0.0%")
    #expect(Standing.changeLabel(1.2) == "+1.2%")
    #expect(Standing.changeLabel(-23) == "-23.0%")
}

/// The engine's assessment of the position is never one of the voices (docs/adr/0040): a card
/// that asked for an Analysis has one, and the strip still says nothing about it.
@MainActor
@Test func withNothingToReportTheStripIsQuietWhateverTheEngineThinks() async throws {
    let start = try #require(Game(startFEN: PGN.standardStartFEN))
    let engine = ScriptedEngine([analysis(38, "e2e4", "e4")])
    let session = GameSession.fresh(start, engine: engine)
    defer { session.suspend() }
    #expect(session.standing == .quiet)
    session.adviseForCard()
    await session.waitForPreparedInterception()
    #expect(session.analysis?.best?.score == .centipawns(38), "the card has its answer")
    #expect(session.standing == .quiet, "and the strip does not repeat it")
}

@MainActor
@Test func theCurveReadsTheJudgementBeforeTheReview() throws {
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
    game.applyReview([.centipawns(40), .centipawns(20)], startEvaluation: .centipawns(0), depth: 16)
    game.setJudgement(.init(drop: 1, score: .centipawns(35), depth: 20), atPly: 0)
    let session = GameSession.fresh(game)
    defer { session.suspend() }
    session.jumpToLatest()

    #expect(session.historyScore(atPly: 0) == .centipawns(0))
    #expect(session.historyScore(atPly: 1) == .centipawns(35), "正着's own number outranks the Review's")
    #expect(session.historyScore(atPly: 2) == .centipawns(20))
    #expect(session.feedbackScore == .centipawns(20), "with no live search the bar reads the same ladder")
    #expect(session.historyScore(atPly: 3) == nil)
}
