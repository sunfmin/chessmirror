import ChessmirrorKit
import ChessmirrorKitTesting
import Foundation
import SwiftUI
import Testing

@testable import Chessmirror

/// The import sheet, photographed.
///
/// Serialized and on the main actor for the same reason the game screen tests are: there is
/// one screen, and two of these rendering at once would be photographing the wrong window.
@MainActor
@Suite(.serialized, .speaking(.chinese))
struct ImportScreenScreenshots {
    @Test(arguments: [PieceColour.white, .black])
    func openingAGameRequiresChoosingTheTrackedSide(side: PieceColour) async throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = library(in: directory)
        let session = ImportSession(fetcher: ScriptedFetcher([
            "https://lichess.org/study/HgiqcIqW.pgn": .success(Self.study)
        ]))
        await session.run("https://lichess.org/study/HgiqcIqW.pgn")
        var opened: GameLibrary.Entry?
        _ = await ScreenImage.write("import-select-\(side == .white ? "white" : "black")", interact: { window in
            #expect(ScreenImage.activate("第一题", in: window))
            await ScreenImage.settle()
            #expect(opened == nil, "opening the side chooser must not import the game")
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil)) ?? []
            #expect(!files.contains { $0.pathExtension == "pgn" })
            #expect(ScreenImage.words(in: window).contains(localized("import.trackSide")))
            let player = side == .white ? "Sunfmin" : "Stockfish 14"
            #expect(ScreenImage.activate("\(side.label) · \(player)", in: window))
            await ScreenImage.settle()
        }) {
            ImportSheet(session: session, memory: memory(), initialDoor: .link, onOpen: { opened = $0 }).environment(library).environment(book(in: directory))
        }
        let entry = try #require(opened)
        let pgn = try PGN(parsing: String(contentsOf: entry.url, encoding: .utf8))
        #expect(pgn.handColours == [side])
        #expect(pgn.tag("White") == "Sunfmin")
        #expect(pgn.tag("Black") == "Stockfish 14")
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "pgn" }
        #expect(files.count == 1, "the other chapter must not be imported")
    }

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

    /// The 错题本 the sheet reads a chapter's status against, over a log of its own so nothing
    /// here touches the player's real one.
    private func book(in tempDir: URL) -> MistakeIndex {
        MistakeIndex(log: PracticeLog(url: tempDir.appending(path: "practice.jsonl")))
    }

    private func tempDir() -> URL {
        URL(filePath: NSTemporaryDirectory())
            .appending(path: "chessmirror-screens-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// The empty sheet: where the link goes, and the one button.
    @Test("the idle sheet asks for a link")
    func idleSheet() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rendered = await ScreenImage.write("import-sheet-idle") {
            ImportSheet(memory: memory(), initialDoor: .link)
                .environment(library(in: tempDir)).environment(book(in: tempDir))
        }

        #expect(rendered.says("导入棋局"))
        #expect(rendered.says("链接"), "and the four doors, with the link one open")
        #expect(rendered.says("lichess"))
        #expect(rendered.says("chess.com"))
        #expect(rendered.says("国象联盟"))
        #expect(rendered.says("贴一个链接"), "what a link is, before one is asked for")
        #expect(rendered.says("PGN 链接"))
        #expect(!rendered.says("lichess 用户名"), "the other door's field is not on this one")
        #expect(rendered.says("获取棋谱"))
        #expect(!rendered.says("作品集"), "nowhere to file anything into any more")
    }

    /// The sheet after the download: how many games came down, and what they are called.
    @Test("a downloaded study counts its games and names them")
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
            ImportSheet(session: session, memory: memory(), initialDoor: .link).environment(library(in: tempDir)).environment(book(in: tempDir))
        }

        #expect(rendered.says("2 局"))
        #expect(rendered.says("第一题"))
        #expect(rendered.says("第二题"))
        #expect(rendered.says("没导入"))
        #expect(rendered.says("入库 2 局"), "one press for the lot")
        // The study's own name is not said at all: it named a collection, and there is no
        // collection to name any more (docs/adr/0028). The chapters are what land.
        #expect(rendered.count(of: "Wood Pecker 1-47") == 0)
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
        _ = session.apply(into: library)

        let rendered = await ScreenImage.write("import-sheet-done") {
            ImportSheet(session: session, memory: memory(), initialDoor: .link).environment(library).environment(book(in: tempDir))
        }

        #expect(rendered.says("导入了 2 局"), "no engine yet, so written and not analysed")
        #expect(rendered.says("第一题") && rendered.says("第二题"), "the list stays")
        #expect(rendered.count(of: "还没分析") == 2)
        #expect(!rendered.says("入库 2 局"), "nothing left to add")
        #expect(rendered.says("再导入一个"))
        #expect(rendered.says("完成"))

        // And the library really has them: one file per chapter, each marked as somebody else's.
        let files = try FileManager.default
            .contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pgn" }
        #expect(files.count == 2)
        for file in files {
            let pgn = try PGN(parsing: String(contentsOf: file, encoding: .utf8) ?? "")
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
            ImportSheet(session: session, memory: memory(remembering: ["sunfmin"]), initialDoor: .lichess)
                .environment(library(in: tempDir))
                .environment(book(in: tempDir))
        }

        #expect(rendered.says("2 局"), "how many came down")
        #expect(rendered.says("sunfmin 这一方的错题记进错题本"), "what opening one does, said up front")
        #expect(rendered.says("白方 · DrNykterstein · 负 · 2026.08.30 21:14"), "their colour, the opponent, how it went, when")
        #expect(rendered.says("黑方 · penguingm1 · 负 · 2026.08.29 09:02"), "two games, two rows")
        #expect(!rendered.says("sunfmin 对 DrNykterstein"), "the account is not named on its own rows")
        #expect(rendered.says("没导入"))
        #expect(rendered.says("入库 2 局"))
        #expect(rendered.says("填 lichess 用户名"), "the door that fetched them is the open one")
        #expect(rendered.says("拉几局"))
    }

    /// Through a player's door, opening a game records that account's side — no question asked,
    /// because the answer is the name in the field.
    @Test("opening a game from an account's door tracks that account's side without asking")
    func openingFromAnAccountTracksIt() async throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = library(in: directory)
        let url = try #require(PGNImport.recentGamesURL(user: "sunfmin", count: 10))
        let session = ImportSession(
            fetcher: ScriptedFetcher([url.absoluteString: .success(Self.myGames)])
        )
        await session.recent(of: "sunfmin", count: 10)
        var opened: GameLibrary.Entry?
        _ = await ScreenImage.write("import-door-lichess-open", interact: { window in
            #expect(ScreenImage.activate("黑方 · penguingm1 · 负 · 2026.08.29 09:02", in: window))
            await ScreenImage.settle()
            #expect(!ScreenImage.words(in: window).contains(localized("import.trackSide")), "nothing to ask")
        }) {
            ImportSheet(session: session, memory: memory(remembering: ["sunfmin"]), initialDoor: .lichess, onOpen: { opened = $0 })
                .environment(library).environment(book(in: directory))
        }
        let entry = try #require(opened)
        let pgn = try PGN(parsing: String(contentsOf: entry.url, encoding: .utf8))
        #expect(pgn.handColours == [.black], "sunfmin had Black in that game")
        #expect(pgn.tag("White") == "penguingm1")
    }

    /// 入库 with an engine: every game written tracks the account's side, goes straight into the
    /// review chain, and the list stays — each row saying where its game has got to.
    @Test("入库 writes the lot, queues each for analysis, and the rows report as it runs")
    func applyAllAndWatch() async throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = library(in: directory)
        let book = book(in: directory)
        let url = try #require(PGNImport.recentGamesURL(user: "sunfmin", count: 10))
        let session = ImportSession(
            fetcher: ScriptedFetcher([url.absoluteString: .success(Self.myGames)])
        )
        await session.recent(of: "sunfmin", count: 10)
        guard case .ready(let plan) = session.phase else {
            Issue.record("expected a plan, got \(session.phase)")
            return
        }
        // One verdict per position of both games. In the first, sunfmin (White) hangs the
        // game with Nf3; in the second nothing costs anything. The first game's second position
        // is held open, so the chain stands at 1 of 4 on it with the second game waiting.
        var byPosition: [String: Analysis] = [:]
        for (chapter, scores) in zip(plan.chapters, [[20, 20, 20, -400], [20, 20, 20, 20]]) {
            for (ply, score) in scores.enumerated() {
                let fen = try #require(chapter.pgn.game.rewound(to: ply)).state.fen
                byPosition[fen] = Analysis(
                    depth: 16, lines: [Line(score: .centipawns(score), uciMoves: ["a2a3"], san: ["a3"])]
                )
            }
        }
        let held = try #require(plan.chapters[0].pgn.game.rewound(to: 1)).state.fen
        let gate = AsyncStream<Analysis>.makeStream()
        let engine = ScriptedEngine([], byPosition: byPosition, controlled: { position, budget in
            position.state.fen == held && budget == .depth(ImportReview.depth) ? gate.stream : nil
        })

        let running = await ScreenImage.write("import-list-analysing", interact: { window in
            #expect(ScreenImage.activate("入库 2 局", in: window))
            let deadline = ContinuousClock.now + .seconds(5)
            while !library.reviewing.values.contains(where: { $0.judged == 1 }), ContinuousClock.now < deadline {
                await Task.yield()
            }
            await ScreenImage.settle()
        }) {
            ImportSheet(session: session, memory: memory(remembering: ["sunfmin"]), engine: engine)
                .environment(library).environment(book)
        }
        #expect(running.says("入库了 2 局，正在逐局分析。"))
        #expect(running.says("分析中 1/4"), "the first game, one position settled of four")
        #expect(running.says("排队分析"), "the second, waiting its turn")
        #expect(!running.says("入库 2 局"), "nothing left to add")

        // Let the held position through; both games land, and the rows say what was found.
        gate.continuation.yield(try #require(byPosition[held]))
        gate.continuation.finish()
        let deadline = ContinuousClock.now + .seconds(10)
        while !library.reviewing.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        #expect(library.reviewing.isEmpty)
        book.update(from: library.entries)

        let landed = await ScreenImage.write("import-list-analysed") {
            ImportSheet(session: session, memory: memory(remembering: ["sunfmin"]), engine: engine)
                .environment(library).environment(book)
        }
        #expect(landed.says("入库了 2 局，都分析完了。"), "and the report says so, not that it is still running")
        #expect(landed.says("已入库 1 道题"), "White's Nf3 cost, and White is sunfmin")
        #expect(landed.says("已入库 0 道题"), "the other game, tracked as Black, had nothing wrong")
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.pathExtension == "pgn" {
            let pgn = try PGN(parsing: String(contentsOf: file, encoding: .utf8))
            #expect(pgn.game.isReviewed)
            #expect(pgn.handColours == [pgn.tag("White") == "sunfmin" ? .white : .black], "tracked as the account's side")
        }
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
            ImportSheet(session: session, memory: memory(), initialInput: "https://lichess.org/hf3Zpe5R/black")
                .environment(library(in: tempDir)).environment(book(in: tempDir))
        }

        #expect(rendered.says("找不到这局棋"))
        #expect(rendered.says("链接可能不对"), "and both of the things it could be")
        #expect(rendered.says("获取棋谱"), "the way forward is a corrected link, so the fetch stays, not a bare 重试")
        #expect(!rendered.says("重试"))
    }

    /// A memory of its own for each test, in a suite nobody's phone reads, and the cloud kept
    /// out of it — so what one test remembers is not in the next test's field.
    private func memory(remembering names: [String] = [], on site: PGNImport.Site = .lichess) -> ImportMemory {
        let suite = "chessmirror-screens-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let memory = ImportMemory(defaults: defaults, travels: false)
        for name in names.reversed() { memory.remember(name, on: site) }
        return memory
    }

    /// The door as it opens for somebody who has fetched before: the last account in the field,
    /// the others a chip away, and the button saying what it is about to do with them.
    @Test("a remembered account is in the field, and the button says whose games it will fetch")
    func rememberedAccount() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let memory = memory(remembering: ["sunfmin", "DrNykterstein"])
        memory.count = 20

        let rendered = await ScreenImage.write("import-door-lichess-remembered") {
            ImportSheet(memory: memory)
                .environment(library(in: tempDir)).environment(book(in: tempDir))
        }

        #expect(rendered.says("sunfmin"), "the account that fetched last, already in the field")
        #expect(rendered.says("用过的"))
        #expect(rendered.says("DrNykterstein"), "and the other one, a tap away")
        #expect(rendered.says("拉 sunfmin 最近 20 局"), "the button names the account and the count remembered")
        #expect(!rendered.says("获取棋谱"))
    }

    /// A fetch that works moves the name to the front of memory, so the next opening starts
    /// from it. Driven through the chips: the other account is picked, its games are fetched.
    @Test("fetching moves the account to the front of what is remembered")
    func fetchingRemembers() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let memory = memory(remembering: ["DrNykterstein", "sunfmin"])
        #expect(memory.latest(on: .lichess) == "DrNykterstein")
        let url = try #require(PGNImport.recentGamesURL(user: "sunfmin", count: 10))
        let session = ImportSession(
            fetcher: ScriptedFetcher([url.absoluteString: .success(Self.myGames)])
        )

        _ = await ScreenImage.write("import-door-lichess-fetched", interact: { window in
            #expect(ScreenImage.activate("sunfmin", in: window), "the other account's chip")
            await ScreenImage.settle()
            #expect(ScreenImage.activate("拉 sunfmin 最近 10 局", in: window))
            await ScreenImage.settle()
        }) {
            ImportSheet(session: session, memory: memory)
                .environment(library(in: tempDir)).environment(book(in: tempDir))
        }

        #expect(memory.names[.lichess] == ["sunfmin", "DrNykterstein"], "the one that fetched, first")
        guard case .ready = session.phase else {
            Issue.record("expected the games, got \(session.phase)")
            return
        }
    }

    /// The chess.com door, with the site's answer to a name it does not have: the message says
    /// the name as it was typed, the field it came from is marked, and the button offers the
    /// fetch again rather than a bare retry.
    @Test("a name chess.com does not know is said back as typed, against its field")
    func chessComUnknownName() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let memory = memory(remembering: ["SunFmn"], on: .chessCom)
        let archives = try #require(PGNImport.chessComArchivesURL(user: "SunFmn"))
        let session = ImportSession(fetcher: ScriptedFetcher([
            archives.absoluteString: .failure(.unknownPlayer(.chessCom, "sunfmn"))
        ]))
        await session.recent(of: "SunFmn", count: 10, on: .chessCom)

        let rendered = await ScreenImage.write("import-door-chesscom-unknown") {
            ImportSheet(session: session, memory: memory, initialDoor: .chessCom)
                .environment(library(in: tempDir)).environment(book(in: tempDir))
        }

        #expect(rendered.says("chess.com 上没有 SunFmn"), "the site and the name, as typed")
        #expect(rendered.says("拼写要对"))
        #expect(rendered.says("拉 SunFmn 最近 10 局"), "the way forward is the fetch with a corrected name")
        #expect(!rendered.says("重试"))
        #expect(rendered.says("填 chess.com 用户名"))
    }

    /// The 国象联盟 door: a share link, and the game it carries, read without a download.
    @Test("a 国象联盟 share link opens its own door with the game already read")
    func chesseaseDoor() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let quiet = ScriptedFetcher([:])
        let session = ImportSession(fetcher: quiet)

        let idle = await ScreenImage.write("import-door-chessease") {
            ImportSheet(session: session, memory: memory(), initialDoor: .chessease)
                .environment(library(in: tempDir)).environment(book(in: tempDir))
        }
        #expect(idle.says("国象联盟分享链接"))
        #expect(idle.says("点「分享」"), "how to get one, before one is asked for")
        #expect(idle.says("读这局棋"))
        #expect(!idle.says("拉几局"), "no count: a share link is one game")

        await session.run(Self.chesseaseShareLink)
        let ready = await ScreenImage.write("import-door-chessease-ready") {
            ImportSheet(session: session, memory: memory(), initialInput: Self.chesseaseShareLink)
                .environment(library(in: tempDir)).environment(book(in: tempDir))
        }
        #expect(ready.says("1 局"))
        #expect(ready.says("国象联盟 快棋"))
        #expect(quiet.askedURLs.isEmpty, "nothing was asked of the network")
    }

    /// The four doors on the narrowest phone still sold, in one row.
    @Test("the four doors fit a small phone")
    func doorsOnASmallPhone() async throws {
        let tempDir = tempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let rendered = await ScreenImage.write("import-doors-small-phone", size: CGSize(width: 375, height: 667)) {
            ImportSheet(memory: memory(remembering: ["sunfmin"]), initialDoor: .chessCom)
                .environment(library(in: tempDir)).environment(book(in: tempDir))
        }
        #expect(rendered.says("lichess") && rendered.says("chess.com") && rendered.says("国象联盟") && rendered.says("链接"))
    }

    /// A 国象联盟 share link, the way the site's own viewer expects to read it (the kit's tests
    /// hold the same one).
    private static let chesseaseShareLink =
        "https://app.chessease.net/pgn/#G-YAAJwFdmN1cVGSZ7WdDBdbPv1N8sd_rCZ2cSB7excYTj1ZCeFBkij2ZATWTXA1CIxLTFte-t1FkQZAFUVaYIvGOLKB2_ATb6HuoBEdJw74EE_Yhdvu29gwnvfXQyRItxgbXHqyqGHpPzcnb1cKxLDwEL-6AzyQuUf-7DxLaEiaviabnNZoLYqJOi2qbZoJKktpkzQQGOATWSqpMUJjg-SuLg"
}
