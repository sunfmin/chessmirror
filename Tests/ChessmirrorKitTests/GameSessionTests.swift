import ChessmirrorKit
import Foundation
import Testing

/// What a saved record opens facing: the side about to move, whoever that is.

/// An engine that says nothing. Enough for `opened` to hand the other side over to one.
private final class SilentEngine: Engine, @unchecked Sendable {
    let positionSearches = PositionSearches()
    var isPaused = false
    func analyse(
        _ game: Game, budget: SearchBudget, lines: Int, strength: Strength
    ) -> AsyncStream<Analysis> {
        AsyncStream { _ in }
    }
    func pause() {}
    func resume() {}
    func clear() async {}
    func evaluate(_ game: Game, budget: SearchBudget) async -> Score? { nil }
    func review(
        _ game: Game, depth: Int, onPly: (@Sendable (Int, ReviewedPly) -> Void)?
    ) async -> [ReviewedPly] { [] }
}

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
    #expect(try #require(GameSession.opened(entry)).orientation == .blackAtBottom)

    // And the usual case: a game that began with White to move opens white at the bottom.
    let standard = try #require(Game(startFEN: PGN.standardStartFEN))
    let standardEntry = GameLibrary.Entry(
        url: URL(filePath: "/games/chessmirror-standard.pgn"),
        pgn: PGN(game: standard, tags: []),
        modified: Date(timeIntervalSince1970: 1_786_000_100)
    )
    #expect(try #require(GameSession.opened(standardEntry)).orientation == .whiteAtBottom)
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
    let session = try #require(GameSession.opened(entry, engine: SilentEngine()))
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
        engine: SilentEngine()
    ))
    #expect(blackFirst.controller(for: .black) == .hand)
    #expect(blackFirst.controller(for: .white) == .engine)

    // The default is the record's own state, not something the engine's presence decides: a
    // record opened before the engine has finished loading answers the moment it has.
    let beforeEngineArrives = try #require(GameSession.opened(entry))
    #expect(beforeEngineArrives.controller(for: .white) == .hand)
    #expect(beforeEngineArrives.controller(for: .black) == .engine)
}

@MainActor @Test("from the opening, Black is the engine")
func aFreshOpeningFacesAnEngineOpponent() throws {
    let standard = try #require(Game(startFEN: PGN.standardStartFEN))
    let session = GameSession.playing(standard, engine: SilentEngine())
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
    let session = GameSession.fresh(game, engine: SilentEngine())
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
