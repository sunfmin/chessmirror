import ChessmirrorKit
import Foundation
import Testing

@MainActor
@Test func reviewingARelaxedMoveDoesNotCountItTwice() throws {
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
    game.setTried([.init(san: "e4", drop: 15, notFound: true)], hints: 3, atPly: 0)
    game.applyReview([.centipawns(-180)], startEvaluation: .centipawns(0), depth: 16)
    let pgn = try PGN(parsing: PGN(game: game, tags: [.init("White", Controller.hand.playerName)]).text)
    let book = MistakeBook.derive(from: [GameLibrary.Entry(
        url: URL(filePath: "/games/reviewed-relaxation.pgn"), pgn: pgn, modified: Date()
    )])
    let mistake = try #require(book.mistakes.first)
    #expect(mistake.encounters.count == 1)
    #expect(mistake.encounters[0].notFound)
}

/// Contract: annotate a real game → write PGN → reopen → derive the book.
/// Preserve exact threshold decisions and repeated attempts, without adding game moves.
/// Missing or corrupt files fail through throws; no pipeline stage is optional.
@MainActor
@Test func triedMovesSurviveDiskAndBookRebuild() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("game.pgn")
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
    let before = PGN(game: game).text
    let attempts: [Game.Ply.Tried] = [
        .init(san: "f3", drop: 19.99), .init(san: "f3", drop: 19.99),
        .init(san: "a3", drop: 9.99),
    ]
    game.setTried(attempts, hints: 2, atPly: 0)
    let written = PGN(game: game, tags: [.init("White", Controller.hand.playerName)])
    #expect(written.text != before)
    #expect(written.text.contains("[%hint 2]"))
    try written.text.write(to: url, atomically: true, encoding: .utf8)
    let reopened = try PGN(parsing: String(contentsOf: url, encoding: .utf8))
    #expect(reopened.game.uciMoves == ["e2e4"])
    #expect(reopened.game.plies[0].tried == attempts)
    #expect(reopened.game.plies[0].hints == 2)
    let entry = GameLibrary.Entry(url: url, pgn: reopened, modified: Date())
    // Read against the older, wider pair of lines, because what this is holding is the *threshold*
    // decision: 19.99 is over a 10% 记录线 and 9.99 is not, whatever the pair a phone ships with.
    let lines = JudgementLines(record: 10, enqueue: 20)
    let book = MistakeBook.derive(from: [entry], lines: lines)
    let mistake = try #require(book.mistakes.first)
    #expect(book.mistakes.count == 1)
    #expect(mistake.encounters.count == 2)
    #expect(Set(mistake.encounters.map(\.id)).count == 2)
    #expect(mistake.encounters.allSatisfy { $0.cost == 19.99 })
    #expect(
        mistake.encounters.allSatisfy { !lines.enqueues($0.cost) },
        "under a 20% 入列线 this is written down without being owed"
    )
    #expect(MistakeBook.derive(from: [entry], lines: lines).mistakes == book.mistakes)
}

@Test func malformedTriedCommentsDoNotCreateEncounters() throws {
    let read = try PGN(parsing: """
        1. e4 {[%tried f3 +20%] [%tried f3 -NaN%] [%tried f3 -101%]
        [%tried f3 -oops20%] [%tried f3 -20% extra] [%tried f3 -20%]} *
        """)
    #expect(read.game.plies[0].tried == [.init(san: "f3", drop: 20)])
}

/// Contract: the 应招 a 试招 earned rides inside the same `[%tried]` token and comes back with
/// it, so a reply can never be paired with the wrong move or lost on its own (docs/adr/0034).
@MainActor
@Test func theReplyIsWrittenBesideTheMoveItAnswers() throws {
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
    let attempts: [Game.Ply.Tried] = [
        .init(san: "f3", drop: 19.99, line: ["d5", "exd5", "Qxd5"]),
        .init(san: "a3", drop: 9.99, notFound: true, line: ["c5"]),
        .init(san: "h4", drop: 4.0),
    ]
    game.setTried(attempts, atPly: 0)
    let text = PGN(game: game).text
    #expect(text.contains("[%tried f3 -19.99% | d5 exd5 Qxd5]"))
    #expect(text.contains("[%tried a3 -9.99% notfound | c5]"))
    #expect(text.contains("[%tried h4 -4.0%]"))
    let read = try PGN(parsing: text)
    #expect(read.game.uciMoves == ["e2e4"])
    #expect(read.game.plies[0].tried == attempts)
}

/// A bar with nothing after it is a file written before there was an answer, or one whose
/// answer was empty. Either way it is a 试招 with no 应招, not a malformed token.
@Test func anEmptyReplyIsTheSameAsNoReply() throws {
    let bare = try PGN(parsing: "1. e4 {[%tried f3 -20% |]} *")
    #expect(bare.game.plies[0].tried == [.init(san: "f3", drop: 20)])
    let spaced = try PGN(parsing: "1. e4 {[%tried f3 -20% | ]} *")
    #expect(spaced.game.plies[0].tried == [.init(san: "f3", drop: 20)])
}

/// Contract: a 试招 carries the Depth its 掉幅 was worked out at, and the file keeps it after the
/// flag — `[%tried a3 -9.99% notfound 28 | c5]` — so a number a 复判 took deeper can be told from
/// an everyday one (docs/adr/0041). A move written before depths were kept has none, and none is
/// invented for it on the way back in.
@MainActor
@Test func theDepthRidesAfterTheFlagAndAnOlderFileHasNone() throws {
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
    let attempts: [Game.Ply.Tried] = [
        .init(san: "f3", drop: 19.99, depth: 28, line: ["d5", "exd5"]),
        .init(san: "a3", drop: 9.99, notFound: true, depth: 17, line: ["c5"]),
        .init(san: "h4", drop: 4.0),
    ]
    game.setTried(attempts, atPly: 0)
    game.setPendingTried([.init(san: "Nf3", drop: 12.5, depth: 20)], atPly: 2)
    let text = PGN(game: game).text
    #expect(text.contains("[%tried f3 -19.99% 28 | d5 exd5]"))
    #expect(text.contains("[%tried a3 -9.99% notfound 17 | c5]"))
    #expect(text.contains("[%tried h4 -4.0%]"))
    #expect(text.contains("[%pending 2 Nf3 -12.5% 20]"))
    let read = try PGN(parsing: text)
    #expect(read.game.plies[0].tried == attempts)
    #expect(read.game.pendingTries(atPly: 2) == [.init(san: "Nf3", drop: 12.5, depth: 20)])

    let older = try PGN(parsing: "1. e4 {[%tried f3 -20% notfound | d5]} *")
    #expect(older.game.plies[0].tried == [.init(san: "f3", drop: 20, notFound: true, line: ["d5"])])
    #expect(older.game.plies[0].tried[0].depth == nil)
    #expect(Game.Ply.Tried(san: "f3", drop: 20) != Game.Ply.Tried(san: "f3", drop: 20, depth: 20))

    // Out of order, twice, or nonsense after the cost is a token nobody wrote.
    let bad = try PGN(parsing: "1. e4 {[%tried f3 -20% 28 notfound] [%tried f3 -20% 28 30] [%tried f3 -20% 0] [%tried f3 -20% 28]} *")
    #expect(bad.game.plies[0].tried == [.init(san: "f3", drop: 20, depth: 28)])
}
