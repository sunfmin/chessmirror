@testable import ChessmirrorKit
import Foundation
import Testing

/// Contract: whose moves are the player's is one question with one answer, read off the record.
/// The row under the board asks the session, the 连正榜 and the 错题本 ask the file, and the two
/// used to be answered differently — the seats right now against the roster at the last save, and
/// for an imported game the seat the reader happened to open it from against the side the import
/// tracked. Now the session reads the file it would write, so they cannot disagree.
@Suite("Mine")
@MainActor
struct MineTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An imported game the player was Black in opens from Black's chair (docs/adr/0047 era:
    /// the roster is the seating plan) and counts Black's moves as the player's, on the row as on
    /// the ladder — whichever seat it is read from, which is what the tag is for.
    @Test func anImportedGameCountsTheTrackedSideWhateverSeatItIsReadFrom() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = GameLibrary(folder: GameFolder(url: folder))
        var game = try #require(Game(
            startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6"]
        ))
        game.setJudgement(.init(drop: 1, score: .centipawns(0), depth: 20, intercept: 5), atPly: 1)
        game.setJudgement(.init(drop: 1, score: .centipawns(0), depth: 20, intercept: 5), atPly: 3)
        let chapter = PGNImport.ImportChapter(
            id: 1, name: "As Black",
            pgn: PGN(game: game, tags: [.init("White", "Someone"), .init("Black", "Me")])
        )
        let entry = try #require(ImportSession().open(chapter, into: library, tracking: .black))
        let session = try #require(GameSession.opened(entry, library: library))
        defer { session.suspend() }

        #expect(session.controller(for: .black) == .hand, "the side the import tracked is theirs")
        #expect(session.controller(for: .white) == .engine)
        #expect(session.mine == [.black], "and the player's side is the one the import tracked")
        #expect(session.noSlips == game.noSlips(by: [.black]))
        #expect(session.noSlips.longestRun == 2)
        #expect(session.mine == (try PGN(parsing: session.pgn.text)).handColours)
    }

    /// Swapping seats mid-game changes whose moves are counted, and the file says so at once:
    /// the row under the board and the ladder read from the library agree after the swap.
    @Test func aSeatSwapIsWrittenAndBothReadersFollowIt() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = GameLibrary(folder: GameFolder(url: folder))
        var game = try #require(Game(
            startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6"]
        ))
        for ply in 0..<4 {
            game.setJudgement(.init(drop: 1, score: .centipawns(0), depth: 20, intercept: 5), atPly: ply)
        }
        game.setStrength(.elo(1400), atPly: 1)
        game.setStrength(.elo(1400), atPly: 3)
        let session = GameSession.fresh(game, controllers: [.white: .hand, .black: .engine], library: library)
        defer { session.suspend() }
        session.save()
        #expect(session.mine == [.white])

        session.setController(.engine, for: .white)
        session.setController(.hand, for: .black)
        #expect(session.mine == [.black])

        let entry = try #require(library.entries.first)
        let file = try #require(entry.pgn)
        #expect(file.handColours == [.black], "the swap was written")
        #expect(Ladder.credits(in: entry) == Ladder.credits(in: session.game, by: session.mine))
        #expect(session.noSlips == file.game.noSlips(by: file.handColours))
    }
}
