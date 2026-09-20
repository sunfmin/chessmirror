@testable import ChessmirrorKit
import Foundation
import Testing
import ChessmirrorKitTesting

/// Contract: a session says what happened on the board and nothing about what it sounds like.
/// What a game *sounded like* is asserted here as the events it emitted, in order, with nothing
/// global swapped out to hear them.

private func opening(_ uciMoves: [String] = []) throws -> Game {
    try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: uciMoves))
}

private func analysis(_ cp: Int, _ uci: String, _ san: String) -> Analysis {
    Analysis(depth: 20, lines: [Line(score: .centipawns(cp), uciMoves: [uci], san: [san])])
}

@MainActor
private func listening(to session: GameSession) -> () -> [GameSession.Event] {
    final class Heard { var events: [GameSession.Event] = [] }
    let heard = Heard()
    session.onEvent = { heard.events.append($0) }
    return { heard.events }
}

/// A hand move with nobody to weigh it lands, once.
@MainActor
@Test func aHandMoveThatStandsLandsOnce() throws {
    let game = try opening()
    let session = GameSession.fresh(game)
    let heard = listening(to: session)
    let e4 = try #require(game.state.move(matching: "e2e4"))

    session.play(e4)

    #expect(heard() == [.landed(e4, outcome: .ongoing)])
}

/// A move 把关 refuses is heard landing — it went on the board — and then being refused.
@MainActor
@Test func aRefusedMoveLandsAndIsThenRefused() async throws {
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
    await session.waitForPreparedInterception()
    let heard = listening(to: session)
    let g4 = try #require(game.state.move(matching: "g2g4"))

    session.play(g4)
    await session.settled()

    #expect(heard() == [.landed(g4, outcome: .ongoing), .refused])
    #expect(session.game.uciMoves == ["f2f3", "e7e5"], "and the move is off the board")
}

/// A move played over another lands, and then the line is heard forking.
@MainActor
@Test func aMovePlayedOverAnotherForks() throws {
    let game = try opening(["e2e4", "e7e5"])
    let session = GameSession.fresh(game)
    session.jump(toPly: 0)
    let heard = listening(to: session)
    let d4 = try #require(session.viewed.state.move(matching: "d2d4"))

    session.play(d4)

    #expect(heard() == [.landed(d4, outcome: .ongoing), .forked])
}

/// Replaying the move that is standing there is not a fork.
@MainActor
@Test func replayingTheStandingMoveDoesNotFork() throws {
    let game = try opening(["e2e4", "e7e5"])
    let session = GameSession.fresh(game)
    session.jump(toPly: 0)
    let heard = listening(to: session)
    let e4 = try #require(session.viewed.state.move(matching: "e2e4"))

    session.play(e4)

    #expect(heard() == [.landed(e4, outcome: .ongoing)])
}

/// The engine's own move lands like any other.
@MainActor
@Test func theEnginesOwnMoveLands() async throws {
    let game = try opening()
    let engine = ScriptedEngine([analysis(20, "e7e5", "e5")])
    let session = GameSession.fresh(game, controllers: [.white: .hand, .black: .engine], engine: engine)
    defer { session.suspend() }
    let heard = listening(to: session)
    let e4 = try #require(game.state.move(matching: "e2e4"))

    session.play(e4)
    await session.settled()
    await session.waitForPreparedInterception()

    let landed = heard().compactMap { event -> String? in
        if case .landed(let move, _) = event { move.uci } else { nil }
    }
    #expect(landed == ["e2e4", "e7e5"])
    #expect(!heard().contains(.refused))
}

/// Going back and playing the move on the record gets the reply that is on the record, stepped
/// to rather than played: no search, no 分支, and not a second landing.
@MainActor
@Test func aReplyOffTheRecordIsAStep() throws {
    let game = try opening(["e2e4", "e7e5", "g1f3"])
    let session = GameSession.fresh(game, controllers: [.white: .hand, .black: .engine])
    session.jump(toPly: 0)
    let heard = listening(to: session)
    let e4 = try #require(session.viewed.state.move(matching: "e2e4"))

    session.play(e4)

    #expect(heard() == [.landed(e4, outcome: .ongoing), .stepped])
    #expect(session.cursor == 2, "the eye is past the reply that was already written down")
}

/// Browsing and taking a move off are steps; a session nobody listens to says nothing at all.
@MainActor
@Test func browsingAndUndoAreSteps() throws {
    let game = try opening(["e2e4", "e7e5"])
    let session = GameSession.fresh(game)
    let heard = listening(to: session)

    session.step(by: -1)
    session.jumpToStart()
    session.jump(toPly: 2)
    session.undo()

    #expect(heard() == [.stepped, .stepped, .stepped, .stepped])
    session.onEvent = nil
    session.step(by: -1)
    #expect(heard().count == 4)
}

/// Checkmate is what the landing did to the game, carried on the event.
@MainActor
@Test func aMatingMoveCarriesItsOutcome() throws {
    let game = try opening(["f2f3", "e7e5", "g2g4"])
    let session = GameSession.fresh(game)
    let heard = listening(to: session)
    let mate = try #require(game.state.move(matching: "d8h4"))

    session.play(mate)

    #expect(heard() == [.landed(mate, outcome: .checkmate)])
}
