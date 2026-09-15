import ChessfenKit
import Foundation
import SwiftUI
import Testing

@testable import Chessfen

/// The first screen, photographed: the ways a board gets into this app.
///
/// Serialized and on the main actor for the same reason the game screen tests are — there is one
/// screen, and two of these rendering at once would be photographing the wrong window.
@MainActor
@Suite(.serialized, .speaking(.chinese))
struct LibraryScreenScreenshots {
    /// A library in a fresh temporary folder, so nothing here touches the real Games folder.
    private func library(in tempDir: URL) -> GameLibrary {
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return GameLibrary(folder: GameFolder(url: tempDir))
    }

    private func tempDir() -> URL {
        URL(filePath: NSTemporaryDirectory())
            .appending(path: "chessfen-library-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// An empty library. What it has to show is every door a picture can come through — the
    /// screenshot doors first, because a screenshot of a lichess review is the main way in
    /// (docs/adr/0033).
    @Test("the first screen offers the album, the clipboard and the files beside the camera")
    func emptyLibrary() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rendered = await ScreenImage.write("library-empty") {
            LibraryScreen()
                .environment(EngineHost(ScriptedEngine([])))
                .environment(library(in: tempDir))
                .environment(MistakeIndex(log: PracticeLog(url: tempDir.appending(path: "p.jsonl"))))
                .environment(LanguageSetting.shared)
        }

        #expect(rendered.says("拍棋盘"), "the camera is still there, and still first")
        #expect(rendered.says("从开局摆起"))
        #expect(rendered.says("导入棋局"))
        #expect(rendered.says("走出第一步，这局就会记在这里"), "an empty library says so")
    }

    /// The two standing lines, where a person can move them (docs/adr/0027). The third is
    /// 耕棋's and belongs to a game, so it is not on this sheet.
    @Test("the settings sheet offers the record and drill lines, defaulting to 10 and 20")
    func theLinesAreOnTheSettingsSheet() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        #expect(JudgementSetting.shared.lines.record == 10)
        #expect(JudgementSetting.shared.lines.enqueue == 20)
        #expect(JudgementSetting.shared.lines.intercept == nil, "耕棋 is not a standing setting")

        let rendered = await ScreenImage.write("about-lines") {
            AboutScreen()
                .environment(EngineHost(ScriptedEngine([])))
                .environment(library(in: tempDir))
        }

        #expect(rendered.says("判决线"))
        #expect(rendered.says("记下来"))
        #expect(rendered.says("进练习"))
        #expect(rendered.says("10%"), "and the two defaults, on the one scale")
        #expect(rendered.says("20%"))
    }

    /// The doors behind the chevron. They are a Menu, so nothing but the chevron is on the
    /// screen until it is opened — which is why the labels are checked here rather than in the
    /// picture above.
    @Test("the album is one of the ways in, and it is named for what it is")
    func theAlbumDoorIsNamed() {
        Speech.speaking(.chinese) {
            #expect(localized("library.fromAlbum") == "从相册选")
            #expect(localized("library.paste") == "粘贴截图")
            #expect(localized("library.fromFiles") == "从文件选")
        }
    }
}

/// The 错题本, photographed: one position, two occasions, and the sentence only that identity can
/// produce (docs/adr/0028).
@MainActor
@Suite(.serialized, .speaking(.chinese))
struct BookScreenshots {
    private func tempDir() -> URL {
        URL(filePath: NSTemporaryDirectory())
            .appending(path: "chessfen-book-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// Two games on disk that reach the same position by different move orders, and throw it
    /// away there both times. Written as files rather than handed over as values, because what
    /// this screen has to prove is that the book comes off the library the app actually lists.
    private func library(in tempDir: URL) throws -> GameLibrary {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // 1. e4 e5 2. Nf3, and 1. Nf3 e5 2. e4 — the same position, and Black hangs the queen
        // out to h4 in both.
        let roads = [
            ("monday", ["e2e4", "e7e5", "g1f3", "d8h4"]),
            ("tuesday", ["g1f3", "e7e5", "e2e4", "d8h4"]),
        ]
        for (name, ucis) in roads {
            var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ucis))
            game.applyReview(
                [20, 20, 20, 420].map { Score.centipawns($0) },
                startEvaluation: .centipawns(20),
                depth: 16
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

    @Test("the book shows one position, said as a count and the moves that were played")
    func theBookMergesTwoRoadsIntoOneItem() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let library = try library(in: tempDir)
        #expect(library.entries.count == 2)

        let index = MistakeIndex(
            log: PracticeLog(url: tempDir.appending(path: "practice.jsonl"))
        )
        index.update(from: library.entries)
        #expect(index.book.mistakes.count == 1, "two roads, one position, one 错题")

        // In a stack, because the title is part of what this screen says and a bare view has
        // no bar to put it in.
        let rendered = await ScreenImage.write("book-list") {
            NavigationStack {
                BookScreen(path: .constant([]))
            }
            .environment(library)
            .environment(index)
            .environment(EngineHost(ScriptedEngine([])))
        }

        #expect(rendered.says("错题本"))
        #expect(rendered.says("这个局面你栽过 2 次"), "the sentence no other identity can produce")
        #expect(rendered.says("2 次走 Qh4"), "and what was played there, counted")
        #expect(!rendered.says("还没有错题"))
    }

    @Test("an opened 错题 lists its occasions and offers to strike it off")
    func oneOpenedShowsItsHistory() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let library = try library(in: tempDir)
        let index = MistakeIndex(
            log: PracticeLog(url: tempDir.appending(path: "practice.jsonl"))
        )
        index.update(from: library.entries)
        let mistake = try #require(index.book.mistakes.first)

        let rendered = await ScreenImage.write("book-entry") {
            NavigationStack {
                BookEntryScreen(mistake: mistake, path: .constant([]))
            }
            .environment(library)
            .environment(index)
            .environment(EngineHost(ScriptedEngine([])))
        }

        #expect(rendered.says("遭遇"))
        #expect(rendered.count(of: "你走了") == 2, "both occasions, not one merged line")
        #expect(rendered.says("Qh4"))
        #expect(rendered.says("从本子里删掉"), "and no reason is asked for")
    }

    @Test("an empty book says what puts something in it")
    func anEmptyBookSaysSo() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let rendered = await ScreenImage.write("book-empty") {
            NavigationStack {
                BookScreen(path: .constant([]))
            }
            .environment(GameLibrary(folder: GameFolder(url: tempDir)))
            .environment(MistakeIndex(log: PracticeLog(url: tempDir.appending(path: "p.jsonl"))))
            .environment(EngineHost(ScriptedEngine([])))
        }

        #expect(rendered.says("还没有错题"))
    }
}
