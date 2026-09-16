@testable import ChessmirrorKit
import Foundation
import Testing

/// Contract: actual Stockfish intercepts g4; solving, revealing, and skipping each restore
/// White's retry. A disk PGN round-trip contains g4 once without the temporary mating move.
enum PunishmentExit: CaseIterable { case solve, reveal, skip }

@MainActor
@Test(arguments: PunishmentExit.allCases)
func realPunishmentReturnsToRetryAndPersistsOnlyTheOriginalAttempt(exit: PunishmentExit) async throws {
    let engine = try EngineService(
        bigNetURL: Nets.big, smallNetURL: Nets.small,
        configuration: .init(threads: 2, hashMegabytes: 32, multiPV: 1)
    )
    let game = try #require(Game(startFEN: PGN.standardStartFEN,
                                uciMoves: ["f2f3", "e7e5"]))
    let session = GameSession.fresh(game, engine: engine)
    defer { session.suspend() }
    session.setIntercept(10)
    session.findsPunishment = true
    session.play(try #require(game.state.move(matching: "g2g4")))
    await session.waitForJudgement()
    let exercise = try #require(session.activePunishment)
    // A refusal leaves the moves alone; what it writes down is the 试招 itself (docs/adr/0037).
    #expect(session.game.uciMoves == game.uciMoves)
    #expect(session.board != game)
    #expect(session.board.uciMoves == ["f2f3", "e7e5", "g2g4"])
    #expect(session.board.state.sideToMove == .black)

    switch exit {
    case .solve: session.play(try #require(session.board.state.move(matching: "d8h4")))
    case .reveal: exercise.reveal()
    case .skip: exercise.skip()
    }
    await exercise.waitForJudgement()
    #expect(exercise.isFinished)
    if exit == .reveal {
        #expect(exercise.revealedMove == "Qh4#")
    } else {
        #expect(exercise.revealedMove == nil)
    }
    #expect(session.activePunishment == nil)
    // The board is back where the move was refused, with the moves as they were; what differs
    // from the game as it started is the 试招 written into it there (docs/adr/0037).
    #expect(session.board.uciMoves == game.uciMoves)
    #expect(session.board.state == game.state)
    #expect(session.board.state.sideToMove == .white)

    session.setIntercept(nil)
    session.play(try #require(game.state.move(matching: "e2e4")))
    await session.waitForJudgement()
    #expect(session.game != game)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("punishment.pgn")
    try session.pgn.text.write(to: url, atomically: true, encoding: .utf8)
    let read = try PGN(parsing: String(contentsOf: url, encoding: .utf8))
    #expect(read.game.uciMoves == ["f2f3", "e7e5", "e2e4"])
    let attempts = read.game.plies.flatMap(\.tried)
    #expect(attempts.count == 1)
    #expect(attempts.first?.san == "g4")
    let book = MistakeBook.derive(from: [GameLibrary.Entry(url: url, pgn: read, modified: Date())])
    #expect(book.mistakes.count == 1)
    #expect(book.mistakes.first?.encounters.count == 1)
}

@MainActor
@Test func punishmentToleranceIsTwoPercentagePoints() async throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    var after = game
    let applied = after.apply(uci: "d2d4")
    #expect(applied)
    for (cp, accepted) in [(21, true), (23, false)] {
        let engine = ScriptedEngine([Analysis(depth: 20, lines: [
            Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
        ])], byPosition: [after.state.fen: Analysis(depth: 20, lines: [
            Line(score: .centipawns(-cp), uciMoves: ["e7e5"], san: ["e5"])
        ])])
        let exercise = Punishment(position: game, engine: engine)
        exercise.submit(try #require(game.state.move(matching: "d2d4")))

        await exercise.waitForJudgement()
        #expect(!exercise.isJudging)
        #expect(exercise.isFinished == accepted)
        #expect(engine.budgets == [PositionSearches.budget, PositionSearches.budget])
    }
}

@MainActor
@Test func punishmentWithoutLegalReplyFinishesImmediately() throws {
    let game = try #require(Game(startFEN: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"))
    let exercise = Punishment(position: game, engine: ScriptedEngine([]))
    #expect(game.state.legalMoves.isEmpty)
    #expect(exercise.isFinished)
    #expect(!exercise.isJudging)
}

@MainActor
@Test func sessionPunishmentRestoresGameAndRecordsOnlyTheOriginalAttempt() async throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let afterD4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["d2d4"]))
    let afterReply = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["d2d4", "e7e5"]))
    let engine = ScriptedEngine([Analysis(depth: 20, lines: [
        Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"]),
        Line(score: .centipawns(-300), uciMoves: ["d2d4"], san: ["d4"])
    ])], byPosition: [
        afterD4.state.fen: Analysis(depth: 12, lines: [.init(score: .centipawns(-300), uciMoves: ["e7e5"], san: ["e5"])]),
        afterReply.state.fen: Analysis(depth: 12, lines: [.init(score: .centipawns(-300), uciMoves: ["e2e4"], san: ["e4"])])
    ])
    let session = GameSession.fresh(game, engine: engine)
    defer { session.suspend() }
    #expect(!session.findsPunishment)
    session.findsPunishment = true
    session.setIntercept(10)
    session.play(try #require(game.state.move(matching: "d2d4")))

    await session.waitForJudgement()
    let exercise = try #require(session.activePunishment)
    #expect(session.game.uciMoves == game.uciMoves)
    #expect(session.board.uciMoves == ["d2d4"])
    #expect(session.board.state.sideToMove == .black)
    session.restart(withSideToMove: .black)
    session.setIntercept(nil)
    session.setController(.engine, for: .white)
    #expect(session.game.uciMoves == game.uciMoves)
    #expect(session.lines.intercept == 10)
    #expect(session.controller(for: .white) == .hand)
    #expect(!session.canPlayBestMove)
    session.play(try #require(session.board.state.move(matching: "e7e5")))
    await exercise.waitForJudgement()
    #expect(exercise.isFinished)
    #expect(session.activePunishment == nil)
    // The board is back where the move was refused, with the moves as they were; what differs
    // from the game as it started is the 试招 written into it there (docs/adr/0037).
    #expect(session.board.uciMoves == game.uciMoves)
    #expect(session.board.state == game.state)
    #expect(session.board.state.sideToMove == .white)
    session.play(try #require(game.state.move(matching: "e2e4")))
    await session.waitForJudgement()
    let read = try PGN(parsing: session.pgn.text)
    try #require(read.game.uciMoves == ["e2e4"])
    #expect(read.game.plies[0].tried.count == 1)
    let book = MistakeBook.derive(from: [GameLibrary.Entry(
        url: URL(filePath: "/games/punishment.pgn"), pgn: read, modified: Date()
    )])
    #expect(book.mistakes.first?.encounters.count == 1)
}

@MainActor
@Test func punishmentAcceptsEquivalentRepliesAndNeverAdvancesItsPosition() async throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let engine = ScriptedEngine([Analysis(depth: 20, lines: [
        Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
    ])])
    for uci in ["e2e4", "d2d4"] {
        let exercise = Punishment(position: game, engine: engine)
        exercise.submit(try #require(game.state.move(matching: uci)))

        await exercise.waitForJudgement()
        #expect(!exercise.isJudging)
        #expect(exercise.isFinished)
        #expect(exercise.position == game)
        #expect(exercise.revealedMove == nil)
    }
    let revealed = Punishment(position: game, engine: engine)
    revealed.reveal()

    await revealed.waitForJudgement()
    #expect(revealed.isFinished)
    #expect(revealed.revealedMove == "e4")
    #expect(revealed.position == game)
    let skipped = Punishment(position: game, engine: engine)
    skipped.skip()
    #expect(skipped.isFinished)
    #expect(skipped.position == game)
}

@MainActor
@Test func punishmentIncorrectReplyAllowsAnotherAttemptWithoutRevealing() async throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    var bad = game
    let applied = bad.apply(uci: "f2f3")
    #expect(applied)
    let engine = ScriptedEngine([Analysis(depth: 20, lines: [
        Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
    ])], byPosition: [bad.state.fen: Analysis(depth: 20, lines: [
        Line(score: .centipawns(-100), uciMoves: ["e7e5"], san: ["e5"])
    ])])
    let exercise = Punishment(position: game, engine: engine)
    exercise.submit(try #require(game.state.move(matching: "f2f3")))

    await exercise.waitForJudgement()
    #expect(!exercise.isJudging)
    #expect(!exercise.isFinished)
    #expect(exercise.wasIncorrect)
    #expect(exercise.revealedMove == nil)
    #expect(exercise.position == game)
    exercise.submit(try #require(game.state.move(matching: "e2e4")))
    await exercise.waitForJudgement()
    #expect(exercise.isFinished)
}
