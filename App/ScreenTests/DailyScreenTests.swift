import ChessmirrorKit
import Foundation
import SwiftUI
import Testing

@testable import Chessmirror
import ChessmirrorKitTesting

/// 日课 on the first screen: how much is left today, and the one verb it offers
/// (docs/adr/0030, docs/adr/0032).
@MainActor
@Suite(.serialized, .drawing(in: .chinese))
struct DailyScreenshots {
    private func tempDir() -> URL {
        URL(filePath: NSTemporaryDirectory())
            .appending(path: "chessmirror-daily-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// Two games that blunder the same position, 31% each — over the 入列线, so the schedule is
    /// allowed to ask about it.
    private func library(in tempDir: URL) throws -> GameLibrary {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for (name, ucis) in [
            ("monday", ["e2e4", "e7e5", "g1f3", "d8h4"]),
            ("tuesday", ["g1f3", "e7e5", "e2e4", "d8h4"]),
        ] {
            var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ucis))
            game.applyReview(
                [20, 20, 20, 420].map { Score.centipawns($0) },
                startEvaluation: .centipawns(20), depth: 16
            )
            let pgn = PGN(
                game: game,
                tags: [
                    PGN.Tag("White", Controller.hand.playerName),
                    PGN.Tag("Black", Controller.hand.playerName),
                ]
            )
            try pgn.text.write(
                to: tempDir.appending(path: "\(name).pgn"), atomically: true, encoding: .utf8
            )
        }
        return GameLibrary(folder: GameFolder(url: tempDir))
    }

    private func screen(_ library: GameLibrary, _ index: MistakeIndex) -> some View {
        LibraryScreen()
            .environment(EngineHost(ScriptedEngine([])))
            .environment(library).environment(CollectionShelf(library: library))
            .environment(index)
    }

    @Test("the first screen says how much of today is left, and empties when it is done")
    func theDayCountsDownAndEmpties() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let library = try library(in: tempDir)
        let log = PracticeLog(url: tempDir.appending(path: "practice.jsonl"))
        let index = MistakeIndex(log: log)
        index.update(from: library.entries)
        #expect(index.daily.remaining == 1, "one position, fallen for twice")

        let waiting = await ScreenImage.write("library-daily") { screen(library, index) }
        #expect(waiting.says("日课"))
        #expect(waiting.says("还剩 1 道"))

        // Practised, and passed. The day is a function of the log, so this is the whole of what
        // "finishing it" means (docs/adr/0029).
        let position = try #require(index.daily.next?.position)
        log.append(
            .drilled(
                PracticeLog.Attempt(
                    position: position, seconds: 9, passed: true, played: "Nc6", cost: 1,
                    hints: 0, source: .daily
                )
            )
        )
        index.refresh()
        #expect(index.daily.isEmpty)

        let done = await ScreenImage.write("library-daily-done") { screen(library, index) }
        #expect(done.says("今天的练完了"))
        #expect(!done.says("还剩"))
    }

    /// The feature the player will ask for and cannot be given (docs/adr/0032). A guard rail
    /// rather than a discovery: it fails the day somebody adds the control.
    @Test("there is no way to choose what to practise")
    func thereIsNothingToPickFrom() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let library = try library(in: tempDir)
        let index = MistakeIndex(log: PracticeLog(url: tempDir.appending(path: "p.jsonl")))
        index.update(from: library.entries)

        let home = await ScreenImage.write("library-no-picker") { screen(library, index) }
        let book = await ScreenImage.write("book-no-picker") {
            NavigationStack { BookScreen(path: .constant([])) }
                .environment(library).environment(CollectionShelf(library: library))
                .environment(index)
                .environment(EngineHost(ScriptedEngine([])))
        }
        for shard in ["筛选", "排序", "主题", "只练", "标签", "分类"] {
            #expect(!home.says(shard), "the first screen offers \(shard)")
            #expect(!book.says(shard), "the 错题本 offers \(shard)")
        }
    }
}
