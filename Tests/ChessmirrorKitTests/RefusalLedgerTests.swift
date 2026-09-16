@testable import ChessmirrorKit
import Foundation
import Testing
import ChessmirrorKitTesting

/// Contract: a refusal has one home, the Game, from the moment it happens (docs/adr/0037). The
/// session reads it there at the cursor, a move that stands takes it from there, and a position
/// that leaves the game takes its refusals with it. Nothing here is a copy that could disagree.

private func tried(_ san: String, _ drop: Double = 20) -> Game.Ply.Tried {
    Game.Ply.Tried(san: san, drop: drop, line: ["e5"])
}

@Test func refusalsAtOnePositionAreWrittenDownInTheOrderTheyHappened() throws {
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
    game.recordTried(tried("Bc4"), atPly: 2)
    game.recordTried(tried("Qh5", 30), atPly: 2)
    #expect(game.pendingTries(atPly: 2).map(\.san) == ["Bc4", "Qh5"])
    #expect(game.pendingTries(atPly: 0).isEmpty)
    #expect(game.pendingTried.map(\.ply) == [2])
}

@Test func theMoveThatStandsTakesTheRefusalsMadeWhereItWasPlayedFrom() throws {
    var game = try #require(Game(startFEN: PGN.standardStartFEN))
    game.recordTried(tried("f3"), atPly: 0)
    game.recordTried(tried("g4", 40), atPly: 0)
    let played = game.apply(uci: "e2e4")
    #expect(played)

    game.absorbPendingTried(atPly: 0)

    #expect(game.plies[0].tried.map(\.san) == ["f3", "g4"])
    #expect(game.pendingTried.isEmpty)
    // And the file says the same: the refusals ride on the move, and nothing is pending.
    let read = try PGN(parsing: PGN(game: game).text).game
    #expect(read.plies[0].tried.map(\.san) == ["f3", "g4"])
    #expect(read.pendingTried.isEmpty)
}

@Test func aMoveWithNothingToTakeLeavesWhatItAlreadyCarried() throws {
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
    game.setTried([tried("f3")], hints: 1, atPly: 0)
    game.absorbPendingTried(atPly: 0)
    #expect(game.plies[0].tried.map(\.san) == ["f3"])
    #expect(game.plies[0].hints == 1)
}

@Test func replacingALineDropsTheRefusalsAtPositionsThatAreGone() throws {
    var game = try #require(
        Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6"])
    )
    game.recordTried(tried("Bc4"), atPly: 1)
    game.recordTried(tried("Qh5"), atPly: 3)

    // Carrying on down the line that is there is not a new move, so nothing is lost.
    let carriedOn = game.play(try #require(game.rewound(to: 1)?.state.move(matching: "e7e5")), atPly: 1)
    #expect(carriedOn)
    #expect(game.pendingTried.map(\.ply) == [1, 3])

    // Playing something else from Ply 1 replaces what followed: the position at Ply 3 no longer
    // exists, and the refusal at Ply 1 stays for the new move to take.
    let replaced = game.play(try #require(game.rewound(to: 1)?.state.move(matching: "d7d5")), atPly: 1)
    #expect(replaced)
    #expect(game.uciMoves == ["e2e4", "d7d5"])
    #expect(game.pendingTried.map(\.ply) == [1])
}

@Test func undoingAMoveDropsTheRefusalsPastTheEnd() throws {
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
    game.recordTried(tried("Bc4"), atPly: 2)
    game.recordTried(tried("d4"), atPly: 1)
    let undone = game.undo()
    #expect(undone)
    #expect(game.pendingTried.map(\.ply) == [1])
}

/// The session has no copy: what it shows at the cursor is what the Game holds at the cursor,
/// and browsing away and back changes nothing about it.
@MainActor
@Test func theSessionShowsTheRefusalsTheGameHoldsAtTheCursor() async throws {
    let played = try #require(
        Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6"])
    )
    let twoPliesIn = try #require(played.rewound(to: 2))
    let afterBad = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "f1c4"]))
    let engine = ScriptedEngine([], byPosition: [
        twoPliesIn.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(0), uciMoves: ["g1f3"], san: ["Nf3"])
        ]),
        afterBad.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(-400), uciMoves: ["g8f6"], san: ["Nf6"])
        ]),
    ])
    let session = GameSession.fresh(played, engine: engine)
    defer { session.suspend() }
    session.setIntercept(JudgementLines.defaultIntercept)
    session.jump(toPly: 2)
    await session.waitForPreparedInterception()
    session.play(try #require(twoPliesIn.state.move(matching: "f1c4")))
    await session.waitForJudgement()

    #expect(session.visibleAttempts.map(\.san) == ["Bc4"])
    #expect(session.visibleAttempts == session.game.pendingTries(atPly: 2))
    #expect(session.refusedPosition == session.viewed)

    session.jumpToStart()
    #expect(session.visibleAttempts.isEmpty)
    #expect(session.pendingAttempts.isEmpty)
    session.jump(toPly: 2)
    #expect(session.visibleAttempts.map(\.san) == ["Bc4"])
    #expect(session.refusedPosition == session.viewed)
    // The one that stands at Ply 3 has taken nothing: the refusal is still pending at 2.
    session.jump(toPly: 3)
    #expect(session.visibleAttempts.isEmpty)
}

/// Two refusals at one position, then a move that stands: the move carries both, in the order
/// they happened, and the Game has nothing pending.
@MainActor
@Test func aMoveThatStandsTakesEveryRefusalMadeBeforeIt() async throws {
    let start = try #require(Game(startFEN: PGN.standardStartFEN))
    let afterF3 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3"]))
    let afterG4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["g2g4"]))
    let afterE4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
    let engine = ScriptedEngine([], byPosition: [
        start.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])]),
        afterF3.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(-300), uciMoves: ["e7e5"], san: ["e5"])]),
        afterG4.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(-500), uciMoves: ["e7e5"], san: ["e5"])]),
        afterE4.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(0), uciMoves: ["e7e5"], san: ["e5"])]),
    ])
    let session = GameSession.fresh(start, engine: engine)
    defer { session.suspend() }
    session.setIntercept(5)
    await session.waitForPreparedInterception()
    for uci in ["f2f3", "g2g4"] {
        session.play(try #require(start.state.move(matching: uci)))
        await session.waitForJudgement()
    }
    #expect(session.game.pendingTries(atPly: 0).map(\.san) == ["f3", "g4"])
    #expect(session.visibleAttempts.map(\.san) == ["f3", "g4"])

    session.play(try #require(start.state.move(matching: "e2e4")))
    await session.waitForJudgement()

    #expect(session.game.uciMoves == ["e2e4"])
    #expect(session.game.plies[0].tried.map(\.san) == ["f3", "g4"])
    #expect(session.game.pendingTried.isEmpty)
    #expect(session.visibleAttempts.map(\.san) == ["f3", "g4"])
}
