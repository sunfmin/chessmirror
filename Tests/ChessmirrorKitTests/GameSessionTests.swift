import ChessmirrorKit
import ChessmirrorKitTesting
import Foundation
import Testing

/// What a saved record opens facing: the player's own side when the file names it, and the side
/// about to move otherwise.

/// An engine that says nothing. Enough for `opened` to hand the other side over to one.
private func silentEngine() -> ScriptedEngine { ScriptedEngine([]) }

@MainActor @Test("a saved record opens facing the side to move")
func savedRecordFacesSideToMove() throws {
    // Black to move at the start: the board must turn around for it.
    let blackToMove = try #require(
        Game(startFEN: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1")
    )
    let entry = GameLibrary.Entry(
        url: URL(filePath: "/games/chessmirror-black-to-move.pgn"),
        pgn: PGN(game: blackToMove, tags: [PGN.Tag(GameOrigin.tagName, GameOrigin.recognised.rawValue)]),
        modified: Date(timeIntervalSince1970: 1_786_000_000)
    )
    #expect(try #require(GameSession.opened(entry).session).orientation == .blackAtBottom)

    // And the usual case: a game that began with White to move opens white at the bottom.
    let standard = try #require(Game(startFEN: PGN.standardStartFEN))
    let standardEntry = GameLibrary.Entry(
        url: URL(filePath: "/games/chessmirror-standard.pgn"),
        pgn: PGN(game: standard, tags: []),
        modified: Date(timeIntervalSince1970: 1_786_000_100)
    )
    #expect(try #require(GameSession.opened(standardEntry).session).orientation == .whiteAtBottom)
}

@MainActor @Test("a record that knows whose game it is opens from that chair")
func trackedRecordFacesItsPlayer() throws {
    // An import where the person holding the phone had Black: White moves first, but the board
    // turns round for them, exactly as it did on lichess.
    var asBlack = PGN(
        game: try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"])),
        tags: [
            PGN.Tag("White", "Someone"), PGN.Tag("Black", "Me"),
            PGN.Tag(GameOrigin.tagName, GameOrigin.imported.tagValue),
        ]
    )
    asBlack.track(.black)
    let entry = GameLibrary.Entry(
        url: URL(filePath: "/games/chessmirror-as-black.pgn"), pgn: asBlack,
        modified: Date(timeIntervalSince1970: 1_786_000_200)
    )
    #expect(try #require(GameSession.opened(entry).session).orientation == .blackAtBottom)

    // The same game with nobody tracked names two other people: it reads from White's side,
    // where the play begins.
    asBlack.track(nil)
    let untracked = GameLibrary.Entry(
        url: URL(filePath: "/games/chessmirror-theirs.pgn"), pgn: asBlack,
        modified: Date(timeIntervalSince1970: 1_786_000_300)
    )
    #expect(try #require(GameSession.opened(untracked).session).orientation == .whiteAtBottom)
}

@MainActor @Test("handing the first move over turns the board round with it")
func restartTurnsTheBoard() throws {
    let standard = try #require(Game(startFEN: PGN.standardStartFEN))
    let session = GameSession.fresh(standard)

    #expect(session.canStart(withSideToMove: .black))
    session.restart(withSideToMove: .black)
    #expect(session.startingSideToMove == .black)
    #expect(session.orientation == .blackAtBottom)

    session.restart(withSideToMove: .white)
    #expect(session.orientation == .whiteAtBottom)
}

@MainActor @Test("a record opens in practice, the side to move in hand and the engine answering")
func recordOpensWithEngineOpponent() throws {
    let standard = try #require(Game(startFEN: PGN.standardStartFEN))
    let entry = GameLibrary.Entry(
        url: URL(filePath: "/games/chessmirror-engine-opponent.pgn"),
        pgn: PGN(game: standard, tags: []),
        modified: Date(timeIntervalSince1970: 1_786_000_400)
    )

    // White moves first: the person's side, with the engine on the answer and no advice shown.
    let session = try #require(GameSession.opened(entry, engine: silentEngine()).session)
    #expect(session.controller(for: .white) == .hand)
    #expect(session.controller(for: .black) == .engine)

    // Black moves first: the engine waits on White instead.
    let blackFirstGame = try #require(
        Game(startFEN: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1")
    )
    let blackFirst = try #require(GameSession.opened(
        GameLibrary.Entry(
            url: URL(filePath: "/games/chessmirror-engine-opponent-black.pgn"),
            pgn: PGN(game: blackFirstGame, tags: []),
            modified: Date(timeIntervalSince1970: 1_786_000_500)
        ),
        engine: silentEngine()
    ).session)
    #expect(blackFirst.controller(for: .black) == .hand)
    #expect(blackFirst.controller(for: .white) == .engine)

    // The default is the record's own state, not something the engine's presence decides: a
    // record opened before the engine has finished loading answers the moment it has.
    let beforeEngineArrives = try #require(GameSession.opened(entry).session)
    #expect(beforeEngineArrives.controller(for: .white) == .hand)
    #expect(beforeEngineArrives.controller(for: .black) == .engine)
}

@MainActor @Test("from the opening, Black is the engine")
func aFreshOpeningFacesAnEngineOpponent() throws {
    let standard = try #require(Game(startFEN: PGN.standardStartFEN))
    let session = GameSession.playing(standard, engine: silentEngine())
    #expect(session.controller(for: .white) == .hand)
    #expect(session.controller(for: .black) == .engine)
}

/// Contract: a game opened at a mistake is *walked* to it rather than cut to it — the moves land
/// one after another, and the board is nobody's while they do.
@MainActor
@Test func walkingToAMistakePlaysTheMovesItPasses() async throws {
    let game = try #require(
        Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5"])
    )
    let session = GameSession.fresh(game, engine: silentEngine())
    defer { session.suspend() }
    // Where a reopened record stands: the beginning. A game being played stands at its end, and
    // there is nothing to walk to from there.
    session.jump(toPly: 0)

    session.walkOnArrival(toPly: 6)
    #expect(session.cursor == 0, "asking for the walk does not jump there")

    let walk = Task { await session.walkToArrival(step: .milliseconds(220)) }
    try? await Task.sleep(for: .milliseconds(320))
    #expect(session.isWalkingRecord)
    #expect(session.cursor > 0 && session.cursor < 6, "the moves are played, not skipped")
    #expect(!session.isHandTurn, "and the board is not the player's while it moves")

    await walk.value
    #expect(session.cursor == 6, "the walk stops where the mistake is")
    #expect(!session.isWalkingRecord)
    #expect(session.isHandTurn, "then the board is handed back")
}

// ------------------------------------------------------------------ the seats a file wrote

/// A directory of its own, so a test that writes a game is not reading another's.
@MainActor private func temporaryLibrary() throws -> (library: GameLibrary, directory: URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (GameLibrary(folder: GameFolder(url: directory)), directory)
}

/// One game the player had Black in, against the engine, with a 试招 of theirs in it.
@MainActor private func gamePlayedAsBlack() throws -> PGN {
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
    game.recordTried(Game.Ply.Tried(san: "Qh4", drop: 30, line: []), atPly: 1)
    return PGN(
        game: game, seats: [.white: .engine, .black: .hand], origin: .recognised,
        lines: JudgementLines(noSlips: true)
    )
}

/// Contract: the roster is the seating plan, and opening a record does not touch the file.
///
/// A game the player had Black in — the engine on White, which is what a photographed position
/// with White to move comes to — used to reopen with the seats swapped: the person was handed the
/// engine's colour, the engine was handed theirs, and the save that came with the swap rewrote the
/// roster. The 错题本 counts a game's mistakes over the colours the roster names (docs/adr/0028),
/// so the game's 错题 changed owner and left the book.
@MainActor @Test("a reopened record keeps the seats the file wrote")
func aReopenedRecordKeepsItsSeats() throws {
    let (library, directory) = try temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "chessmirror-as-black.pgn")
    library.write(try gamePlayedAsBlack(), to: url)

    let before = try String(contentsOf: url, encoding: .utf8)
    let entry = GameLibrary.Entry(url: url, pgn: try PGN(parsing: before), modified: Date())
    #expect(MistakeBook.derive(from: [entry]).mistakes.count == 1, "the 试招 is a 错题 of the player's")

    let session = try #require(
        GameSession.opened(entry, engine: silentEngine(), library: library).session
    )
    #expect(session.controller(for: .black) == .hand, "Black was theirs and stays theirs")
    #expect(session.controller(for: .white) == .engine)
    #expect(session.mine == [.black])

    let after = try String(contentsOf: url, encoding: .utf8)
    #expect(after == before, "opening a record writes nothing")
    let reread = GameLibrary.Entry(url: url, pgn: try PGN(parsing: after), modified: Date())
    #expect(
        MistakeBook.derive(from: [reread]).mistakes.count == 1,
        "and the game's 错题 are still the player's after it has been opened"
    )
}

/// An import knows whose game it is from its own tag rather than from the roster, and the seat
/// follows that: the reader plays their own side, and the opponent's moves are already written.
@MainActor @Test("an import tracked as Black is read from Black's chair")
func anImportTrackedAsBlackSitsAsBlack() throws {
    var imported = PGN(
        game: try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"])),
        tags: [
            PGN.Tag("White", "Someone"), PGN.Tag("Black", "Me"),
            PGN.Tag(GameOrigin.tagName, GameOrigin.imported.tagValue),
        ]
    )
    imported.track(.black)
    let session = try #require(GameSession.opened(
        GameLibrary.Entry(
            url: URL(filePath: "/games/chessmirror-import-as-black.pgn"), pgn: imported,
            modified: Date(timeIntervalSince1970: 1_786_000_600)
        ),
        engine: silentEngine()
    ).session)
    #expect(session.controller(for: .black) == .hand)
    #expect(session.controller(for: .white) == .engine)
    #expect(session.orientation == .blackAtBottom)
}
