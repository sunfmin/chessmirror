@testable import ChessfenKit
import Foundation
import Testing

/// Contract: the session is doing one thing at a time, and says which. What the player's hands
/// have to wait for, whether the record may be browsed, and whose clock it is are all read off
/// that one answer — so a mutator and the button that fires it cannot disagree about it.

private func opening(_ uciMoves: [String] = []) throws -> Game {
    try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: uciMoves))
}

private func analysis(_ cp: Int, _ uci: String, _ san: String) -> Analysis {
    Analysis(depth: 20, lines: [Line(score: .centipawns(cp), uciMoves: [uci], san: [san])])
}

@MainActor
@Test func aGameWithNothingInFlightIsBeingRead() throws {
    let game = try opening(["e2e4"])
    let session = GameSession.fresh(game)
    defer { session.suspend() }

    #expect(session.phase == .reading)
    #expect(!session.isOccupied)
    #expect(session.canBrowse)
    #expect(session.isOnClock(.black))
    #expect(!session.isOnClock(.white))
    #expect(session.isHandTurn)

    session.jumpToStart()
    #expect(session.isOnClock(.white), "the clock follows the position being looked at")
    #expect(session.isHandTurn, "and the past is where a move is taken back")
}

/// The one position nobody is on the clock in: the game is over.
@MainActor
@Test func nobodyIsOnTheClockOfAFinishedGame() throws {
    let game = try opening(["f2f3", "e7e5", "g2g4", "d8h4"])
    let session = GameSession.fresh(game)
    defer { session.suspend() }

    #expect(session.phase == .reading)
    #expect(!session.isOnClock(.white))
    #expect(!session.isOnClock(.black))
    #expect(!session.isHandTurn)
    #expect(!session.canPlayBestMove)
}

/// While 正着 weighs a move the board is occupied: nobody is on the clock, nothing may be
/// browsed, and the dials that would change what the judgement means are refused.
@MainActor
@Test func weighingOccupiesTheBoard() async throws {
    let game = try opening()
    // The opening has an answer; the position after d4 never gets one, so the weighing stands.
    let engine = ScriptedEngine([], isEndless: true, byPosition: [game.state.fen: analysis(0, "e2e4", "e4")])
    let session = GameSession.fresh(game, engine: engine)
    defer { session.suspend() }
    session.setIntercept(10)
    await session.waitForPreparedInterception()

    session.play(try #require(game.state.move(matching: "d2d4")))

    #expect(session.phase == .weighing)
    #expect(session.isOccupied)
    #expect(!session.canBrowse)
    #expect(!session.isOnClock(.white))
    #expect(!session.isOnClock(.black), "the move is played, and whether it stands is the question")
    #expect(!session.isHandTurn)
    #expect(!session.canPlayBestMove)

    session.jumpToStart()
    #expect(session.cursor == 1, "the record is not browsed while a move is weighed")
    session.setIntercept(30)
    #expect(session.lines.intercept == 10, "nor is the 拦截线 moved under the judgement")
    session.setController(.engine, for: .black)
    #expect(session.controller(for: .black) == .hand, "nor a seat handed over")
}

/// The engine walking its own move is not an occupation: the record may be browsed, which is
/// how the game is paused, and the engine's side is the one on the clock.
@MainActor
@Test func theEnginesOwnMoveIsThinkingAndLeavesTheRecordOpen() async throws {
    let game = try opening()
    let engine = ScriptedEngine([analysis(20, "e7e5", "e5")], isEndless: true)
    let session = GameSession.fresh(game, controllers: [.white: .hand, .black: .engine], engine: engine)
    defer { session.suspend() }

    session.play(try #require(game.state.move(matching: "e2e4")))
    await Task.yield()

    #expect(session.phase == .thinking(.own))
    #expect(!session.isOccupied)
    #expect(session.canBrowse)
    #expect(session.isOnClock(.black))
    #expect(!session.isHandTurn)
    #expect(session.isEngineTurn)
    #expect(!session.canPlayBestMove, "the engine is already walking this move")

    session.jumpToStart()
    #expect(session.cursor == 0)
    #expect(session.phase == .reading, "browsing away is how a self-playing game pauses")
}

/// A move somebody is holding the button for is thinking too, and the record is a different
/// thought from the engine's own: the hand's side stays on the clock.
@MainActor
@Test func anAskedMoveIsThinkingForTheHand() async throws {
    let game = try opening()
    let engine = ScriptedEngine([analysis(20, "e2e4", "e4")], isEndless: true)
    let session = GameSession.fresh(game, engine: engine)
    defer { session.suspend() }

    session.beginAskedMove()
    await Task.yield()

    #expect(session.phase == .thinking(.asked))
    #expect(!session.isOccupied)
    #expect(session.isOnClock(.white))
    #expect(session.canPlayBestMove, "the button is still under the thumb holding it")
}

/// The walk to a mistake is a phase of its own: the board is nobody's while the moves land,
/// and it is handed back where the walk stops.
@MainActor
@Test func walkingTheRecordIsAPhaseOfItsOwn() async throws {
    let game = try opening(["e2e4", "e7e5", "g1f3", "b8c6"])
    let session = GameSession.fresh(game)
    defer { session.suspend() }
    session.jump(toPly: 0)

    let walk = Task { await session.walk(toPly: 4, step: .milliseconds(200)) }
    try? await Task.sleep(for: .milliseconds(300))

    #expect(session.phase == .walking)
    #expect(!session.isOccupied, "a walk is not a judgement; the lines may still be moved")
    #expect(!session.canBrowse, "but the record is already on its way somewhere")
    #expect(!session.isHandTurn)
    let cursorMidWalk = session.cursor
    session.jumpToStart()
    #expect(session.cursor == cursorMidWalk, "a jump does not cut across a walk")

    await walk.value
    #expect(session.phase == .reading)
    #expect(session.cursor == 4)
    #expect(session.isHandTurn)
}

/// A 惩罚 exercise occupies the board with a position of its own, and the clock is that
/// position's: Black's, in the mate White just walked past.
@MainActor
@Test func anExerciseOccupiesTheBoardOnItsOwnClock() async throws {
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
    session.setIntercept(10)
    session.findsPunishment = true
    await session.waitForPreparedInterception()

    session.play(try #require(game.state.move(matching: "g2g4")))
    await session.waitForJudgement()
    let exercise = try #require(session.activePunishment)

    #expect(session.phase == .exercising)
    #expect(session.isOccupied)
    #expect(!session.canBrowse)
    #expect(session.isOnClock(.black), "the exercise's board has Black to move")
    #expect(!session.isOnClock(.white))
    #expect(session.isHandTurn, "and the hand is Black's for it")
    #expect(!session.canPlayBestMove)
    session.setIntercept(nil)
    #expect(session.isTilling, "正着 is not switched off under an exercise")

    exercise.skip()
    await exercise.waitForJudgement()
    #expect(session.phase == .reading)
    #expect(session.isOnClock(.white), "the board is White's again, where the move was refused")
}
