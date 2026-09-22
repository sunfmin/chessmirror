import ChessmirrorKit
import ChessmirrorKitTesting
import Foundation
import Testing

/// Contract: every way into a game starts under the opener's engine, library, rung and lines —
/// a photograph, a corrected photograph, a new game and a game off the shelf alike — and a game
/// asked for by its file is found in the library and walked to the move it was asked for at.
@MainActor
@Suite struct GameOpenerTests {
    private static let start = Game(startFEN: PGN.standardStartFEN)!
    private let rung = Strength.elo(1600)
    private let lines = JudgementLines(noSlips: false, record: 15, enqueue: 25)

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("every way in takes the opener's rung and lines")
    func everyWayInTakesTheOpenersRungAndLines() throws {
        let opener = GameOpener(engine: nil, library: nil, strength: rung, lines: lines)
        let sessions = [
            opener.play(Self.start),
            opener.recognised(Self.start, orientation: .blackAtBottom, picture: nil, shaky: []),
            opener.corrected(
                Self.start, controllers: [.white: .hand, .black: .hand], orientation: .whiteAtBottom,
                origin: .recognised, picture: nil, shaky: []
            ),
        ]
        for session in sessions {
            #expect(session.strength == rung)
            #expect(session.lines == lines)
        }
        #expect(sessions[0].controller(for: .black) == .engine, "a new game seats the engine opposite")
        #expect(sessions[1].orientation == .blackAtBottom)
    }

    @Test("a new game can be opened under 把关, and nothing else about the lines moves")
    func aNewGameCanBeOpenedUnderNoSlips() {
        let opener = GameOpener(engine: nil, library: nil, strength: rung, lines: lines)
        let guarded = opener.play(Self.start, noSlips: true)
        #expect(guarded.isNoSlipsOn)
        #expect(guarded.lines.record == 15)
        #expect(!opener.play(Self.start).isNoSlipsOn)
    }

    @Test("the player's settings are what an opener made from them opens under")
    func theSettingsAreWhatItOpensUnder() {
        let settings = PlayerSettings(store: InMemorySettings())
        settings.strength = rung
        settings.record = 15
        settings.enqueue = 25
        let session = GameOpener(engine: nil, library: nil, settings: settings).play(Self.start)
        #expect(session.strength == rung)
        #expect(session.lines == lines)
    }

    /// A game on the shelf, asked for by its file: found, opened under the opener, and — when a
    /// ply is given — set to walk there rather than cut there.
    @Test("a game asked for by its file is found and walked to the move")
    func aGameAskedForByItsFileIsFound() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = GameLibrary(folder: GameFolder(url: directory))
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6"]))
        let url = directory.appending(path: "chessmirror-2026-09-21-120000.pgn")
        #expect(library.write(PGN(game: game, tags: []), to: url))
        #expect(library.entry(at: url) != nil)

        let opener = GameOpener(engine: nil, library: library, strength: rung, lines: lines)
        let session = try #require(opener.open(url, walkingTo: 3).session)
        #expect(session.url == url)
        #expect(session.strength == rung)
        #expect(session.game.uciMoves == game.uciMoves)
        session.jump(toPly: 0)
        await session.walkToArrival(step: .zero)
        #expect(session.cursor == 3, "walked to the move it was asked for at")

        #expect(opener.open(directory.appending(path: "not-here.pgn")).session == nil)
        #expect(GameOpener(engine: nil, library: nil).open(url).session == nil, "no library, no shelf")
    }

    /// A game still on its way from iCloud is a named refusal, not a nil every caller had to
    /// remember is not a failure (docs/adr/0012).
    @Test("a game that has not arrived is a named refusal")
    func aGameThatHasNotArrivedIsANamedRefusal() throws {
        let entry = GameLibrary.Entry(
            url: URL(filePath: "/games/on-its-way.pgn"),
            pgn: nil,
            modified: Date(timeIntervalSince1970: 1_786_000_000),
            isDownloading: true
        )
        guard case .notArrived = GameSession.opened(entry) else {
            Issue.record("a file still on the way is refused by name, not opened empty")
            return
        }
        #expect(GameSession.opened(entry).session == nil)
    }
}
