import ChessfenKit
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
    let book = MistakeBook.derive(from: [entry])
    let mistake = try #require(book.mistakes.first)
    #expect(book.mistakes.count == 1)
    #expect(mistake.encounters.count == 2)
    #expect(Set(mistake.encounters.map(\.id)).count == 2)
    #expect(mistake.encounters.allSatisfy { $0.cost == 19.99 })
    #expect(mistake.encounters.allSatisfy { !JudgementLines.standard.enqueues($0.cost) })
    #expect(MistakeBook.derive(from: [entry]).mistakes == book.mistakes)
}

@Test func malformedTriedCommentsDoNotCreateEncounters() throws {
    let read = try PGN(parsing: """
        1. e4 {[%tried f3 +20%] [%tried f3 -NaN%] [%tried f3 -101%]
        [%tried f3 -oops20%] [%tried f3 -20% extra] [%tried f3 -20%]} *
        """)
    #expect(read.game.plies[0].tried == [.init(san: "f3", drop: 20)])
}
