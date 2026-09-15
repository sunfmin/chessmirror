import ChessfenKit
import Foundation
import Testing

/// What a saved record opens facing: the side about to move, whoever that is.

/// An engine that says nothing. Enough for `opened` to hand the other side over to one.
private final class SilentEngine: Engine, @unchecked Sendable {
    var isPaused = false
    func analyse(_ game: Game, budget: SearchBudget, lines: Int) -> AsyncStream<Analysis> {
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
        url: URL(filePath: "/games/chessfen-black-to-move.pgn"),
        pgn: PGN(game: blackToMove, tags: [PGN.Tag(GameOrigin.tagName, GameOrigin.recognised.rawValue)]),
        modified: Date(timeIntervalSince1970: 1_786_000_000)
    )
    #expect(try #require(GameSession.opened(entry)).orientation == .blackAtBottom)

    // And the usual case: a game that began with White to move opens white at the bottom.
    let standard = try #require(Game(startFEN: PGN.standardStartFEN))
    let standardEntry = GameLibrary.Entry(
        url: URL(filePath: "/games/chessfen-standard.pgn"),
        pgn: PGN(game: standard, tags: []),
        modified: Date(timeIntervalSince1970: 1_786_000_100)
    )
    #expect(try #require(GameSession.opened(standardEntry)).orientation == .whiteAtBottom)
}

@MainActor @Test("上一局 and 下一局 face the game they open, not the one before")
func seriesNavigationFacesEachRecord() throws {
    let standard = try #require(Game(startFEN: PGN.standardStartFEN))
    let whiteFirst = GameLibrary.Entry(
        url: URL(filePath: "/games/chessfen-white-first.pgn"),
        pgn: PGN(game: standard, tags: []),
        modified: Date(timeIntervalSince1970: 1_786_000_200)
    )
    let blackFirst = GameLibrary.Entry(
        url: URL(filePath: "/games/chessfen-black-first.pgn"),
        pgn: PGN(
            game: try #require(Game(startFEN: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1")),
            tags: []
        ),
        modified: Date(timeIntervalSince1970: 1_786_000_300)
    )

    let session = try #require(GameSession.opened(whiteFirst))
    #expect(session.orientation == .whiteAtBottom)
    // A turn around the board is a fact about the game being opened, not a way of working
    // that carries over from the one before.
    #expect(try #require(session.next(blackFirst)).orientation == .blackAtBottom)
    #expect(try #require(session.next(whiteFirst)).orientation == .whiteAtBottom)
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
        url: URL(filePath: "/games/chessfen-engine-opponent.pgn"),
        pgn: PGN(game: standard, tags: []),
        modified: Date(timeIntervalSince1970: 1_786_000_400)
    )

    // White moves first: the person's side, with the engine on the answer and no advice shown.
    let session = try #require(GameSession.opened(entry, engine: SilentEngine()))
    #expect(session.controller(for: .white) == .hand)
    #expect(session.controller(for: .black) == .engine)
    #expect(session.isPractising)
    #expect(session.thinkingTime == .fixed(seconds: 1), "a brisk answer, one second a move")

    // Black moves first: the engine waits on White instead.
    let blackFirstGame = try #require(
        Game(startFEN: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1")
    )
    let blackFirst = try #require(GameSession.opened(
        GameLibrary.Entry(
            url: URL(filePath: "/games/chessfen-engine-opponent-black.pgn"),
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
    #expect(beforeEngineArrives.isPractising)
}

@MainActor @Test("from the opening, Black is the engine, one second a move")
func aFreshOpeningFacesAnEngineOpponent() throws {
    let standard = try #require(Game(startFEN: PGN.standardStartFEN))
    let session = GameSession.playing(standard, engine: SilentEngine())
    #expect(session.controller(for: .white) == .hand)
    #expect(session.controller(for: .black) == .engine)
    #expect(session.thinkingTime == .fixed(seconds: 1))
    #expect(session.isPractising)
}

// ------------------------------------------------------------------- the one switch

/// Every door into a Game opens with the engine silent (docs/adr/0015). An answer on screen is an
/// answer the eye cannot decline to read, so it is not enough for practice to be *available*: it
/// has to be where a Game starts, whichever way the Game got here.
@MainActor @Test("every way into a Game starts with the engine's opinion off")
func everyGameStartsSilent() throws {
    let standard = try #require(Game(startFEN: PGN.standardStartFEN))
    let read = try #require(
        Game(startFEN: "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/2P2N2/PP1P1PPP/RNBQK2R w KQkq - 0 5")
    )

    #expect(GameSession.fresh(standard).isPractising)
    #expect(GameSession.recognised(read, shaky: [Square("c6")!]).isPractising)
    #expect(
        GameSession.corrected(
            read,
            controllers: [.white: .hand, .black: .engine],
            orientation: .whiteAtBottom,
            origin: .recognised,
            picture: nil,
            shaky: [],
            engine: nil,
            library: nil
        ).isPractising
    )

    let entry = GameLibrary.Entry(
        url: URL(filePath: "/games/chessfen-silent-1.pgn"),
        pgn: PGN(game: standard, tags: []),
        modified: Date(timeIntervalSince1970: 1_786_000_600)
    )
    #expect(try #require(GameSession.opened(entry)).isPractising)
}

/// And it is never found where it was left. Who plays which colour and the engine's clock are ways
/// of working, set up once for a set of fifty; the engine's opinion is the one thing standing
/// between a player and the answer, so the next position asks the question again.
@MainActor @Test("the next game in a collection does not inherit the engine's opinion")
func theSwitchDoesNotTravel() throws {
    let standard = try #require(Game(startFEN: PGN.standardStartFEN))
    let first = try #require(GameSession.opened(
        GameLibrary.Entry(
            url: URL(filePath: "/games/chessfen-silent-2.pgn"),
            pgn: PGN(game: standard, tags: []),
            modified: Date(timeIntervalSince1970: 1_786_000_700)
        )
    ))
    first.setPractising(false)
    first.setThinkingTime(.fixed(seconds: 5))
    first.setController(.engine, for: .white)
    #expect(!first.isPractising)

    let second = try #require(first.next(
        GameLibrary.Entry(
            url: URL(filePath: "/games/chessfen-silent-3.pgn"),
            pgn: PGN(game: standard, tags: []),
            modified: Date(timeIntervalSince1970: 1_786_000_800)
        )
    ))

    #expect(second.isPractising, "the answer is not waiting for you in the next position")
    // The ways of working still carry, which is the distinction being drawn.
    #expect(second.thinkingTime == .fixed(seconds: 5))
    #expect(second.controller(for: .white) == .engine)
}
