import ChessfenKit
import Foundation
import SwiftUI
import Testing

@testable import Chessfen

/// The import sheet, photographed.
///
/// Serialized and on the main actor for the same reason the game screen tests are: there is
/// one screen, and two of these rendering at once would be photographing the wrong window.
@MainActor
@Suite(.serialized, .speaking(.chinese))
struct ImportScreenScreenshots {
    /// A two-chapter study in the shape lichess exports, with chapters named like the ones a
    /// person has actually named. Kept here rather than shared with the kit's tests, because
    /// this bundle cannot see the kit's test fixtures — and two chapters is all a sheet needs
    /// to have something to say.
    private static let study = """
    [Event "Wood Pecker 1-47"]
    [Site "https://lichess.org/study/HgiqcIqW/0fg3fROm"]
    [Date "2021.??.??"]
    [Round "1"]
    [White "Sunfmin"]
    [Black "Stockfish 14"]
    [Result "*"]
    [ChapterName "第一题"]
    [StudyName "Wood Pecker 1-47"]
    [ChapterMode "normal"]

    1. e4 e5 2. Nf3 *

    [Event "Wood Pecker 1-47"]
    [Site "https://lichess.org/study/HgiqcIqW/0fg3fROm"]
    [Date "2021.??.??"]
    [Round "2"]
    [Result "*"]
    [ChapterName "第二题"]
    [StudyName "Wood Pecker 1-47"]
    [ChapterMode "normal"]

    1. d4 d5 2. c4 *
    """

    /// A library in a fresh temporary folder, so an import can be written and checked without
    /// touching the real Games folder — the seam `GameFolder.init(url:)` exists for.
    private func library(in tempDir: URL) -> GameLibrary {
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return GameLibrary(folder: GameFolder(url: tempDir))
    }

    private func tempDir() -> URL {
        URL(filePath: NSTemporaryDirectory())
            .appending(path: "chessfen-screens-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// The empty sheet: where the link goes, where the collection is asked for, the one button.
    @Test("the idle sheet asks for a link and a collection")
    func idleSheet() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rendered = await ScreenImage.write("import-sheet-idle") {
            ImportSheet().environment(library(in: tempDir))
        }

        #expect(rendered.says("导入棋局"))
        #expect(rendered.says("链接"), "and the two doors, with the link one open")
        #expect(rendered.says("最近对局"))
        #expect(rendered.says("贴一个链接"), "what a link is, before one is asked for")
        #expect(rendered.says("PGN 链接"))
        #expect(!rendered.says("lichess 用户名"), "the other door's field is not on this one")
        #expect(rendered.says("获取棋谱"))
        #expect(rendered.says("导入到作品集"))
        #expect(rendered.says("作品集名字"))
    }

    /// The sheet after the download: the study names itself, its chapters, and its collection.
    @Test("a downloaded study names itself, its chapters, and its collection")
    func readySheet() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let session = ImportSession(
            fetcher: ScriptedFetcher([
                "https://lichess.org/study/HgiqcIqW.pgn": .success(Self.study)
            ])
        )
        await session.run("https://lichess.org/study/HgiqcIqW.pgn")

        let rendered = await ScreenImage.write("import-sheet-ready") {
            ImportSheet(session: session).environment(library(in: tempDir))
        }

        #expect(rendered.says("「Wood Pecker 1-47」· 2 局"))
        #expect(rendered.says("第一题"))
        #expect(rendered.says("第二题"))
        #expect(rendered.says("导入 2 局"))
        // The suggested collection lands in the field the way a suggestion should: on its own,
        // not typed by a person — once in the summary, once as the field's value.
        #expect(rendered.count(of: "Wood Pecker 1-47") >= 2, "the field holds the suggestion too")
    }

    /// The sheet after importing: the report, the way out, and the files really on disk.
    @Test("after importing, the sheet reports what landed and the files are real games")
    func doneSheet() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let library = self.library(in: tempDir)
        let session = ImportSession(
            fetcher: ScriptedFetcher([
                "https://lichess.org/study/HgiqcIqW.pgn": .success(Self.study)
            ])
        )
        await session.run("https://lichess.org/study/HgiqcIqW.pgn")
        _ = session.apply(into: "Wood Pecker", library: library)

        let rendered = await ScreenImage.write("import-sheet-done") {
            ImportSheet(session: session).environment(library)
        }

        #expect(rendered.says("导入 2 局到「Wood Pecker」"))
        #expect(rendered.says("再导入一个"))
        #expect(rendered.says("完成"))

        // And the library really has them: one file per chapter, tagged into the collection.
        let files = try FileManager.default
            .contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pgn" }
        #expect(files.count == 2)
        for file in files {
            let pgn = try PGN(parsing: String(contentsOf: file, encoding: .utf8) ?? "")
            #expect(pgn.tag("Event") == "Wood Pecker")
            #expect(pgn.tag(GameOrigin.tagName) == GameOrigin.imported.tagValue)
        }
    }

    /// Two of somebody's own games, in the shape the user endpoint hands them over.
    private static let myGames = """
    [Event "Rated Blitz game"]
    [Site "https://lichess.org/hf3Zpe5R"]
    [White "sunfmin"]
    [Black "DrNykterstein"]
    [Result "0-1"]
    [UTCDate "2026.08.30"]
    [UTCTime "21:14:03"]

    1. e4 { [%eval 0.24] } e5 { [%eval 0.31] } 2. Nf3 0-1

    [Event "Rated Blitz game"]
    [Site "https://lichess.org/QQQQwwww"]
    [White "penguingm1"]
    [Black "sunfmin"]
    [Result "1-0"]
    [UTCDate "2026.08.29"]
    [UTCTime "09:02:11"]

    1. d4 d5 2. c4 1-0
    """

    /// The other door: a username and a count, and what comes back through it.
    @Test("the other door asks for a username and how many games")
    func recentGamesDoor() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = try #require(PGNImport.recentGamesURL(user: "sunfmin", count: 10))
        let session = ImportSession(
            fetcher: ScriptedFetcher([url.absoluteString: .success(Self.myGames)])
        )
        await session.recent(of: "sunfmin", count: 10)

        let rendered = await ScreenImage.write("import-sheet-recent") {
            ImportSheet(session: session, initialDoor: .player, initialPlayer: "sunfmin")
                .environment(library(in: tempDir))
        }

        #expect(rendered.says("「sunfmin 的对局」· 2 局"), "named after the player, not the event")
        #expect(rendered.says("sunfmin 对 DrNykterstein · 2026.08.30 21:14"))
        #expect(rendered.says("penguingm1 对 sunfmin · 2026.08.29 09:02"), "two games, two names")
        #expect(rendered.says("导入 2 局"))
        #expect(rendered.says("填一个 lichess 用户名"), "the door that fetched them is the open one")
        #expect(rendered.says("拉几局"))
    }

    /// A game that is not there says so, in its own words.
    @Test("an unavailable game is named as unavailable")
    func missingGame() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let session = ImportSession(
            fetcher: ScriptedFetcher([
                "https://lichess.org/game/export/hf3Zpe5R?evals=true&clocks=false":
                    .failure(.missingGame)
            ])
        )
        await session.run("https://lichess.org/hf3Zpe5R/black")

        let rendered = await ScreenImage.write("import-sheet-missing") {
            ImportSheet(session: session).environment(library(in: tempDir))
        }

        #expect(rendered.says("找不到这局棋"))
        #expect(rendered.says("链接可能不对"), "and both of the things it could be")
        #expect(rendered.says("重试"))
    }

    /// Inside a collection the same sheet is pinned to it: the door says where games land.
    @Test("a collection's + opens an import pinned to that collection")
    func collectionImport() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let library = self.library(in: tempDir)

        let screen = await ScreenImage.write("collection-import") {
            NavigationStack {
                CollectionScreen(name: "Wood Pecker", path: .constant([]))
            }
            .environment(EngineHost(ScriptedEngine([])))
            .environment(library)
        }
        #expect(screen.says("导入棋局"), "the + is labelled for what it does")
        #expect(screen.says("这个作品集空了"), "an empty collection says so")

        let sheet = await ScreenImage.write("import-sheet-pinned") {
            ImportSheet(targetCollection: "Wood Pecker").environment(library)
        }
        #expect(sheet.says("导入到「Wood Pecker」"))
        #expect(!sheet.says("作品集名字"), "no asking for a collection the door already named")
    }
}
