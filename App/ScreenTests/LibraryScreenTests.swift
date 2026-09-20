import ChessmirrorKit
import Foundation
import SwiftUI
import Testing

@testable import Chessmirror
import ChessmirrorKitTesting

/// The first screen, photographed: the ways a board gets into this app.
///
/// Serialized and on the main actor for the same reason the game screen tests are — there is one
/// screen, and two of these rendering at once would be photographing the wrong window.
@MainActor
@Suite(.serialized, .speaking(.chinese))
struct LibraryScreenScreenshots {
    @Test func savedMistakeShowsFeedback() async throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = library(in: directory)
        let index = MistakeIndex(log: PracticeLog(url: directory.appending(path: "p.jsonl")))
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
        game.applyReview([.centipawns(-400)], startEvaluation: .centipawns(0), depth: 20)
        let pgn = PGN(game: game, tags: [PGN.Tag("White", Controller.hand.playerName)])
        let message = localized("book.recorded", 1)
        let rendered = await ScreenImage.write("mistake-recorded", interact: { window in
            #expect(ScreenImage.activate(localized("library.fromStart"), in: window))
            await ScreenImage.settle()
            #expect(ScreenImage.words(in: window).contains { $0.contains(localized("noSlips.name")) })
            #expect(!ScreenImage.words(in: window).contains(message))
            #expect(library.write(pgn, to: directory.appending(path: "game.pgn")))
            await ScreenImage.settle()
            #expect(index.book.mistakes.count == 1)
            #expect(ScreenImage.words(in: window).contains { $0.contains(message) })
        }) {
            LibraryScreen()
                .environment(EngineHost(ScriptedEngine([])))
                .environment(library)
                .environment(index)
                .environment(LanguageSetting.shared)
        }
        #expect(rendered.says(message))
    }
    /// What practice leaves behind is a game, and there are ten of them a day: they go in a drawer
    /// of their own so the list a person came here to read is still the one on top (docs/adr/0047).
    @Test("the games a drill left behind are folded away behind one row")
    func practiceGamesAreFoldedAway() async throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = library(in: directory)
        let index = MistakeIndex(log: PracticeLog(url: directory.appending(path: "p.jsonl")))

        let played = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
        #expect(library.write(
            PGN(
                game: played, seats: [.white: .hand, .black: .engine], origin: .fresh,
                lines: JudgementLines(noSlips: true),
                carrying: [PGN.Tag(GameLibrary.nameTag, "周二那盘")]
            ),
            to: directory.appending(path: "played.pgn")
        ))
        for (number, name) in ["练习甲", "练习乙", "练习丙"].enumerated() {
            let position = try #require(Game(
                startFEN: "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 0 1"
            ))
            #expect(library.write(
                PGN(
                    game: position, seats: [.black: .hand, .white: .engine],
                    origin: .practised, lines: JudgementLines(noSlips: true),
                    carrying: [PGN.Tag(GameLibrary.nameTag, name)]
                ),
                to: directory.appending(path: "drill-\(number).pgn")
            ))
        }

        let rendered = await ScreenImage.write("library-practice-drawer", interact: { window in
            let shut = ScreenImage.words(in: window)
            #expect(shut.contains { $0.contains("周二那盘") }, "the game they played is on the list")
            #expect(!shut.contains { $0.contains("练习甲") }, "and the day's drills are not")
            #expect(ScreenImage.activate(localized("library.practice"), in: window))
            await ScreenImage.settle()
            #expect(ScreenImage.words(in: window).contains { $0.contains("练习甲") })
        }) {
            LibraryScreen()
                .environment(EngineHost(ScriptedEngine([])))
                .environment(library)
                .environment(index)
                .environment(LanguageSetting.shared)
        }

        #expect(rendered.says(localized("library.practice")))
        #expect(rendered.says("周二那盘"))
    }

    /// A library in a fresh temporary folder, so nothing here touches the real Games folder.
    private func library(in tempDir: URL) -> GameLibrary {
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return GameLibrary(folder: GameFolder(url: tempDir))
    }

    private func tempDir() -> URL {
        URL(filePath: NSTemporaryDirectory())
            .appending(path: "chessmirror-library-\(UUID().uuidString)", directoryHint: .isDirectory)
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

        #expect(rendered.says("拍棋盘"), "the camera is still there, one tap away")
        #expect(rendered.says("从开局摆起"))
        #expect(rendered.says("导入棋局"))
        #expect(rendered.says("走出第一步，这局就会记在这里"), "an empty library says so")
    }

    /// What the app is for goes first: 把关 and 日课, and a line under the name that says it.
    /// The three ways of handing it a picture are 进料 — how a position gets in, not what
    /// anybody opened the app to do — so they come after.
    @Test("the first screen leads with 开始把关 and 日课, and the ways in come after")
    func theScreenLeadsWithWhatItIsFor() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rendered = await ScreenImage.write("library-leads") {
            LibraryScreen()
                .environment(EngineHost(ScriptedEngine([])))
                .environment(library(in: tempDir))
                .environment(MistakeIndex(log: PracticeLog(url: tempDir.appending(path: "p.jsonl"))))
                .environment(LanguageSetting.shared)
        }

        #expect(rendered.says("把下错的招变成重练的题"), "the subtitle says what the app is for")
        let noSlips = try #require(rendered.words.firstIndex { $0.contains("开始把关") })
        let daily = try #require(rendered.words.firstIndex { $0.contains("日课") })
        let camera = try #require(rendered.words.firstIndex { $0.contains("拍棋盘") })
        let fromStart = try #require(rendered.words.firstIndex { $0.contains("从开局摆起") })
        let importing = try #require(rendered.words.firstIndex { $0.contains("导入棋局") })
        #expect(noSlips < daily, "把关 first, 日课 second")
        #expect(daily < camera, "and both before the ways in")
        #expect(camera < fromStart)
        #expect(fromStart < importing)
    }

    /// 日课 with something due says how much, at the top of the screen.
    @Test("日课 with a question due says how many are left")
    func dailyDueSaysHowMany() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let library = library(in: tempDir)
        let index = try bookOfOne(library: library, in: tempDir)
        #expect(index.daily.remaining == 1)

        let rendered = await ScreenImage.write("library-daily-due") {
            LibraryScreen()
                .environment(EngineHost(ScriptedEngine([])))
                .environment(library)
                .environment(index)
                .environment(LanguageSetting.shared)
        }

        #expect(rendered.says(localized("daily.left", plural: 1)))
        let daily = try #require(rendered.words.firstIndex { $0.contains("日课") })
        let camera = try #require(rendered.words.firstIndex { $0.contains("拍棋盘") })
        #expect(daily < camera)
    }

    /// Done is a state the screen shows, not a row it removes: a door that disappears once it is
    /// done is a door nobody learns is there.
    @Test("日课 with nothing left still stands on the screen, saying it is done")
    func dailyDoneStaysOnTheScreen() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let library = library(in: tempDir)
        let log = PracticeLog(url: tempDir.appending(path: "p.jsonl"))
        let index = try bookOfOne(library: library, in: tempDir, log: log)
        let question = try #require(index.book.mistakes.first)
        log.append(
            .drilled(
                PracticeLog.Attempt(
                    position: question.position, seconds: 5, passed: true, played: "Nf3",
                    cost: 0, hints: 0, source: .daily
                )
            )
        )
        index.update(from: library.entries)
        #expect(index.daily.remaining == 0)
        #expect(!index.book.isEmpty)

        let rendered = await ScreenImage.write("library-daily-done") {
            LibraryScreen()
                .environment(EngineHost(ScriptedEngine([])))
                .environment(library)
                .environment(index)
                .environment(LanguageSetting.shared)
        }

        #expect(rendered.says(localized("daily")), "the door is still there")
        #expect(rendered.says(localized("daily.done")))
        #expect(!rendered.says(localized("daily.none")), "the book is not empty, so it is done")
    }

    /// The smallest phone this app runs on, and the largest type anybody can set. Both doors and
    /// all three ways in still say their names: a screen that leads with two things has to lead
    /// with them on a 320-point screen too.
    @Test(arguments: [DynamicTypeSize.large, .accessibility5])
    func theSmallPhoneSaysEverything(_ type: DynamicTypeSize) async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let library = library(in: tempDir)
        let index = try bookOfOne(library: library, in: tempDir)

        let rendered = await ScreenImage.write(
            "library-small-\(type == .large ? "type" : "biggest")",
            size: CGSize(width: 320, height: 568)
        ) {
            LibraryScreen()
                .environment(EngineHost(ScriptedEngine([])))
                .environment(library)
                .environment(index)
                .environment(LanguageSetting.shared)
                .dynamicTypeSize(type)
        }

        #expect(rendered.says("开始把关"))
        #expect(rendered.says("日课"))
        #expect(rendered.says("拍棋盘"))
        #expect(rendered.says("从开局摆起"))
        #expect(rendered.says("导入棋局"))
        #expect(rendered.says("错题本"))
    }

    /// A library holding one game with one 错题 in it, and the index that found it.
    private func bookOfOne(
        library: GameLibrary, in tempDir: URL, log: PracticeLog? = nil
    ) throws -> MistakeIndex {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
        game.applyReview([.centipawns(-400)], startEvaluation: .centipawns(0), depth: 20)
        let pgn = PGN(game: game, tags: [PGN.Tag("White", Controller.hand.playerName)])
        #expect(library.write(pgn, to: tempDir.appending(path: "mistake.pgn")))
        let index = MistakeIndex(log: log ?? PracticeLog(url: tempDir.appending(path: "p.jsonl")))
        index.update(from: library.entries)
        #expect(index.book.mistakes.count == 1)
        return index
    }

    /// The 连正榜 above the games (docs/adr/0038): a row per rung that has been stood at, each
    /// with its longest 连正.
    @Test("the ladder shows a row per rung, with its longest run")
    func theLadderAboveTheGames() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let library = library(in: tempDir)
        let stood = Game.Ply.Judgement(drop: 1, score: .centipawns(20), depth: 20, intercept: 5)
        let italian = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6", "d2d4"]
        // One game climbing from 1400 to 1800 with a 试招 before 4. c3, one played at 满力.
        var climb = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: italian))
        for ply in [0, 2, 4, 6, 8] { climb.setJudgement(stood, atPly: ply) }
        for ply in [1, 3] { climb.setStrength(.elo(1400), atPly: ply) }
        for ply in [5, 7] { climb.setStrength(.elo(1800), atPly: ply) }
        climb.setTried([.init(san: "Nh3", drop: 12)], atPly: 6)
        var full = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: italian))
        for ply in [0, 2, 4] { full.setJudgement(stood, atPly: ply) }
        for ply in [1, 3, 5, 7] { full.setStrength(.full, atPly: ply) }
        let tags = [
            PGN.Tag("White", Controller.hand.playerName),
            PGN.Tag("Black", Controller.engine.playerName),
        ]
        #expect(library.write(PGN(game: climb, tags: tags), to: tempDir.appending(path: "climb.pgn")))
        #expect(library.write(PGN(game: full, tags: tags), to: tempDir.appending(path: "full.pgn")))
        let index = MistakeIndex(log: PracticeLog(url: tempDir.appending(path: "p.jsonl")))
        index.update(from: library.entries)
        #expect(index.ladder.rows.map(\.strength) == [.elo(1400), .elo(1800), .full])

        let rendered = await ScreenImage.write("library-ladder") {
            LibraryScreen()
                .environment(EngineHost(ScriptedEngine([])))
                .environment(library)
                .environment(index)
                .environment(LanguageSetting.shared)
        }

        #expect(rendered.says("连正榜"))
        #expect(rendered.says("1400"))
        #expect(rendered.says("1800"))
        #expect(rendered.says("满力"))
        #expect(rendered.says("最长连正 2"), "1800's run, ended by the 试招")
        #expect(rendered.says("最长连正 3"), "满力's three, unbroken")
        #expect(!rendered.says("正着数"))
        #expect(!rendered.says("共 3 步"), "no count of everything that stood")
    }

    /// A best is the way to the game it was made in: pressing it opens that game.
    @Test("pressing a best on the ladder opens the game it was made in")
    func aBestOpensItsGame() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let library = library(in: tempDir)
        let stood = Game.Ply.Judgement(drop: 1, score: .centipawns(20), depth: 20, intercept: 5)
        var game = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4"])
        )
        for ply in [0, 2, 4] { game.setJudgement(stood, atPly: ply) }
        for ply in [1, 3] { game.setStrength(.elo(2200), atPly: ply) }
        let pgn = PGN(
            game: game,
            tags: [
                PGN.Tag("White", Controller.hand.playerName),
                PGN.Tag("Black", Controller.engine.playerName),
            ]
        )
        #expect(library.write(pgn, to: tempDir.appending(path: "climb.pgn")))
        let index = MistakeIndex(log: PracticeLog(url: tempDir.appending(path: "p.jsonl")))
        index.update(from: library.entries)

        let rendered = await ScreenImage.write("library-ladder-opened", interact: { window in
            #expect(ScreenImage.activate("最长连正 3", in: window))
            await ScreenImage.settle()
            let words = ScreenImage.words(in: window)
            #expect(words.contains { $0.contains("Stockfish 18 · 2200") }, "the game, at its rung")
            #expect(words.contains { $0.contains("连正 3") }, "with its run of three")
        }) {
            LibraryScreen()
                .environment(EngineHost(ScriptedEngine([])))
                .environment(library)
                .environment(index)
                .environment(LanguageSetting.shared)
        }
        #expect(rendered.says("Bc4"), "the record of the game that was opened")
    }

    /// Nothing has stood at any rung: no ladder, and nothing saying there is none — the games
    /// are what this screen is about.
    @Test("a library with nothing stood shows no ladder")
    func noLadderBeforeAnythingStood() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let library = library(in: tempDir)
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
        let tags = [
            PGN.Tag("White", Controller.hand.playerName),
            PGN.Tag("Black", Controller.engine.playerName),
        ]
        #expect(library.write(PGN(game: game, tags: tags), to: tempDir.appending(path: "one.pgn")))
        let index = MistakeIndex(log: PracticeLog(url: tempDir.appending(path: "p.jsonl")))
        index.update(from: library.entries)

        let rendered = await ScreenImage.write("library-no-ladder") {
            LibraryScreen()
                .environment(EngineHost(ScriptedEngine([])))
                .environment(library)
                .environment(index)
                .environment(LanguageSetting.shared)
        }
        #expect(index.ladder.isEmpty)
        #expect(!rendered.says("连正榜"))
    }

    /// The two standing lines, where a person can move them (docs/adr/0027). The third is
    /// 正着's and belongs to a game, so it is not on this sheet.
    @Test("the settings sheet offers the record and drill lines, defaulting to 10 and 10")
    func theLinesAreOnTheSettingsSheet() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        #expect(JudgementSetting.shared.lines.record == 10)
        #expect(JudgementSetting.shared.lines.enqueue == 10)
        #expect(!JudgementSetting.shared.lines.noSlips, "把关 is not a standing setting")

        let rendered = await ScreenImage.write("about-lines") {
            AboutScreen()
                .environment(EngineHost(ScriptedEngine([])))
                .environment(library(in: tempDir))
        }

        #expect(rendered.says("判决线"))
        #expect(rendered.says("记下来"))
        #expect(rendered.says("进练习"))
        #expect(rendered.says("10%"), "and the two defaults, on the one scale")
        #expect(rendered.count(of: "10%") >= 2, "both lines read 10%")
    }

    /// The 搜索预算, where a person can set it (CONTEXT.md): time, depth, and which end stops
    /// the search, defaulting to ten seconds or depth twenty, whichever comes first.
    @Test("the settings sheet offers the search budget, defaulting to 10 s / depth 20, either")
    func theSearchBudgetIsOnTheSettingsSheet() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        #expect(SearchSetting.shared.limit == .standard)
        #expect(PositionSearches.limit == .standard, "and the kit runs on it")

        let rendered = await ScreenImage.write("about-search") {
            AboutScreen()
                .environment(EngineHost(ScriptedEngine([])))
                .environment(library(in: tempDir))
        }

        #expect(rendered.says("引擎搜索"))
        #expect(rendered.says("时间"))
        #expect(rendered.says("10 秒"))
        #expect(rendered.says("深度"))
        #expect(rendered.says("20 层"))
        #expect(rendered.says("以哪个为准"))
        #expect(rendered.says("先到为准"))
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
            .appending(path: "chessmirror-book-\(UUID().uuidString)", directoryHint: .isDirectory)
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
        let pixels = try #require(ScreenImage.Pixels(of: rendered.url))
        #expect(pixels.fullWidthBoardRows > pixels.width / 2)
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

