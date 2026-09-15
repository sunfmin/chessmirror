import ChessfenKit
import Foundation
import Testing

/// A two-chapter study in the shape lichess exports: one PGN, `[ChapterName]` and `[StudyName]`
/// on every chapter. The second chapter has no `White`/`Black` — real chapters often do not,
/// and the name chain has to work without them.
private let twoChapterStudy = """
[Event "Wood Pecker 1-47"]
[Site "https://lichess.org/study/HgiqcIqW/0fg3fROm"]
[Date "2021.??.??"]
[Round "1"]
[White "Sunfmin"]
[Black "Stockfish 14"]
[Result "*"]
[ChapterName "1"]
[StudyName "Wood Pecker 1-47"]
[ChapterMode "normal"]

1. e4 e5 2. Nf3 *

[Event "Wood Pecker 1-47"]
[Site "https://lichess.org/study/HgiqcIqW/0fg3fROm"]
[Date "2021.??.??"]
[Round "2"]
[Result "*"]
[ChapterName "2"]
[StudyName "Wood Pecker 1-47"]
[ChapterMode "normal"]

1. d4 d5 2. c4 *
"""

/// One game's worth of tags, for building fixtures that need a known shape.
private func chapter(_ name: String, movetext: String = "1. e4 *") -> String {
    """
    [Event "Something"]
    [Site "Somewhere"]
    [Date "2026.08.12"]
    [Round "-"]
    [White "A"]
    [Black "B"]
    [Result "*"]
    [ChapterName "\(name)"]

    \(movetext)
    """
}

// ------------------------------------------------------------------- URLs

@Test("a lichess study page maps to itself and its study-level .pgn export")
func lichessStudyGetsAPGNVariant() {
    let candidates = PGNImport.candidateURLs(for: "lichess.org/study/HgiqcIqW")
    #expect(
        candidates?.map(\.absoluteString)
            == [
                "https://lichess.org/study/HgiqcIqW",
                "https://lichess.org/study/HgiqcIqW.pgn",
            ]
    )
}

@Test("a chapter page and a fragment still name the study, not the chapter")
func chapterURLsFallThroughToTheWholeStudy() {
    let candidates = PGNImport.candidateURLs(
        for: "https://lichess.org/study/HgiqcIqW/0fg3fROm#12"
    )
    #expect(
        candidates?.map(\.absoluteString)
            == [
                "https://lichess.org/study/HgiqcIqW/0fg3fROm#12",
                "https://lichess.org/study/HgiqcIqW.pgn",
            ]
    )
}

@Test("a URL that is already the export is tried as it stands")
func alreadyAPGNStaysOneCandidate() {
    #expect(
        PGNImport.candidateURLs(for: "https://lichess.org/study/HgiqcIqW.pgn")?.map(\.absoluteString)
            == ["https://lichess.org/study/HgiqcIqW.pgn"]
    )
}

@Test("a non-lichess PGN link is fetched as given")
func otherSitesPassThrough() {
    #expect(
        PGNImport.candidateURLs(for: "https://example.com/games/game.pgn")?.map(\.absoluteString)
            == ["https://example.com/games/game.pgn"]
    )
}

@Test("anything that is not a link is refused up front")
func notALinkIsNil() {
    #expect(PGNImport.candidateURLs(for: "") == nil)
    #expect(PGNImport.candidateURLs(for: "not a link") == nil)
    #expect(PGNImport.candidateURLs(for: "file:///etc/passwd") == nil)
}

// --------------------------------------------------------------- splitting

@Test("a multi-game PGN splits into one parseable block per chapter")
func studySplitsPerChapter() throws {
    let blocks = PGNImport.split(twoChapterStudy)
    #expect(blocks.count == 2)
    for block in blocks {
        let pgn = try PGN(parsing: block)
        #expect(pgn.tag("ChapterName") != nil)
    }
}

@Test("chapters are found without a blank line between them")
func splitsWithoutBlankLines() throws {
    let text = """
        [Event "A"]
        [ChapterName "1"]

        1. e4 *
        [Event "A"]
        [ChapterName "2"]

        1. d4 *
        """
    let blocks = PGNImport.split(text)
    #expect(blocks.count == 2)
    #expect(try PGN(parsing: blocks[0]).tag("ChapterName") == "1")
    #expect(try PGN(parsing: blocks[1]).tag("ChapterName") == "2")
}

@Test("a chapter with no moves is still its own game")
func emptyChapterStillSplits() throws {
    let text = """
        [Event "A"]
        [ChapterName "1"]

        [Event "A"]
        [ChapterName "2"]

        1. d4 *
        """
    let blocks = PGNImport.split(text)
    #expect(blocks.count == 2)
    let empty = try PGN(parsing: blocks[0])
    #expect(empty.game.plies.isEmpty)
    #expect(empty.tag("ChapterName") == "1")
    #expect(try PGN(parsing: blocks[1]).tag("ChapterName") == "2")
}

@Test("a bracket line inside a comment or a variation never starts a new game")
func commentBracketsDoNotSplit() throws {
    let text = """
        [Event "A"]

        1. e4 {a comment
        [that starts a line with a bracket]
        it ends} e5 2. Nf3 (2. Nc3
        [%cal Gb1c3]
        2... Nc6) 2... Nc6 *
        """
    let blocks = PGNImport.split(text)
    #expect(blocks.count == 1, "the [ lines sit at depth one; they are content, not tags")
    let pgn = try PGN(parsing: blocks[0])
    #expect(pgn.game.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6"])
}

@Test("trailing newlines and whitespace-only text split into nothing")
func blankTextSplitsIntoNothing() {
    #expect(PGNImport.split("") == [])
    #expect(PGNImport.split("\n\n  \n") == [])
}

// ---------------------------------------------------------------- reading

@Test("chapters parse with their names, and the study names the collection")
func chaptersReadNames() {
    let (chapters, unreadable) = PGNImport.chapters(in: twoChapterStudy)
    #expect(chapters.map(\.name) == ["1", "2"])
    #expect(chapters.map(\.id) == [1, 2])
    #expect(unreadable == 0)
    #expect(PGNImport.suggestedCollection(for: chapters[0].pgn) == "Wood Pecker 1-47")
}

@Test("a chapter that will not parse is counted, not fatal")
func unreadableChaptersAreCounted() throws {
    // The first chapter's first move is illegal — no piece can go to e5 from the start —
    // so it cannot parse; the second is a fine game and must come through anyway.
    let text = chapter("broken", movetext: "1. e5 *") + "\n" + chapter("fine")
    let (chapters, unreadable) = PGNImport.chapters(in: text)
    #expect(chapters.map(\.name) == ["fine"])
    #expect(unreadable == 1)
}

// ------------------------------------------------------------------ naming

@Test(
    "the chapter name chain runs ChapterName, Event, players, Date, then position",
    .speaking(.chinese)
)
func nameFallbackChain() throws {
    func pgn(
        chapterName: String? = nil, event: String = "?", white: String = "?",
        black: String = "?", date: String? = nil
    ) -> PGN {
        var tags: [PGN.Tag] = [
            PGN.Tag("Event", event), PGN.Tag("White", white), PGN.Tag("Black", black)
        ]
        if let chapterName { tags.append(PGN.Tag("ChapterName", chapterName)) }
        if let date { tags.append(PGN.Tag("Date", date)) }
        return PGN(game: Game(startFEN: PGN.standardStartFEN)!, tags: tags)
    }

    #expect(
        PGNImport.name(for: pgn(chapterName: "第一题"), chapter: 7) == "第一题",
        "ChapterName is the name for exactly this game"
    )
    #expect(
        PGNImport.name(for: pgn(event: "Wood Pecker"), chapter: 7) == "Wood Pecker",
        "Event names the set the game belongs to"
    )
    #expect(
        PGNImport.name(for: pgn(white: "卡尔森", black: "丁立人"), chapter: 7)
            == "卡尔森 对 丁立人"
    )
    #expect(
        PGNImport.name(for: pgn(date: "2021.03.05"), chapter: 7) == "2021.03.05",
        "with no players named, the date is what the game is"
    )
    #expect(
        PGNImport.name(for: pgn(), chapter: 7) == "第 7 章",
        "and with nothing at all, its place in the study is the one true name"
    )
}

@Test("a whole study of unknown players falls to the date rather than one shared name")
func unknownPlayersAreNotAName() throws {
    let pgn = PGN(
        game: Game(startFEN: PGN.standardStartFEN)!,
        tags: [PGN.Tag("Event", "?"), PGN.Tag("Date", "2026.01.02")]
    )
    #expect(PGNImport.name(for: pgn, chapter: 1) == "2026.01.02")
}

// ------------------------------------------------------------------- dedup

@Test("chapters a game already stands in for are skipped, inside and against the plan")
func dedupSkipsByName() {
    func chapter(_ name: String) -> PGNImport.ImportChapter {
        PGNImport.ImportChapter(
            id: 0, name: name,
            pgn: PGN(game: Game(startFEN: PGN.standardStartFEN)!, tags: [PGN.Tag("ChapterName", name)])
        )
    }

    let (kept, skipped) = PGNImport.toWrite(
        [chapter("1"), chapter("2")], avoiding: ["1"]
    )
    #expect(kept.map(\.name) == ["2"])
    #expect(skipped == 1)

    // Two chapters with one name cannot become two files that read identically.
    let (deduped, skippedTwins) = PGNImport.toWrite(
        [chapter("1"), chapter("1"), chapter("2")], avoiding: []
    )
    #expect(deduped.map(\.name) == ["1", "2"])
    #expect(skippedTwins == 1)
}

// ----------------------------------------------------------------- session

@MainActor
@Test("candidates are tried in order, and an HTML page falls through to the .pgn")
func sessionWalksCandidatesInOrder() async {
    let fetcher = ScriptedFetcher([
        "https://lichess.org/study/HgiqcIqW": .success("<!DOCTYPE html><html>a page</html>"),
        "https://lichess.org/study/HgiqcIqW.pgn": .success(twoChapterStudy),
    ])
    let session = ImportSession(fetcher: fetcher)
    await session.run("lichess.org/study/HgiqcIqW")

    #expect(
        fetcher.askedURLs.map(\.absoluteString)
            == [
                "https://lichess.org/study/HgiqcIqW",
                "https://lichess.org/study/HgiqcIqW.pgn",
            ],
        "the page itself first, its export second"
    )
    guard case .ready(let plan) = session.phase else {
        Issue.record("expected a ready plan, got \(session.phase)")
        return
    }
    #expect(plan.chapters.count == 2)
    #expect(plan.suggestedCollection == "Wood Pecker 1-47")
}

@MainActor
@Test("a lichess 403 reads as the study not being public")
func privateStudyIsNamed() async {
    let fetcher = ScriptedFetcher([
        "https://lichess.org/study/3g1TDUO0": .failure(.privateStudy),
        "https://lichess.org/study/3g1TDUO0.pgn": .failure(.privateStudy),
    ])
    let session = ImportSession(fetcher: fetcher)
    await session.run("https://lichess.org/study/3g1TDUO0")

    #expect(session.phase == .failed(.privateStudy))
}

@MainActor
@Test("when every candidate fails the last failure is the one shown")
func lastFailureWins() async {
    let fetcher = ScriptedFetcher([
        "https://example.com/game.pgn": .failure(.network("离线了"))
    ])
    let session = ImportSession(fetcher: fetcher)
    await session.run("https://example.com/game.pgn")

    #expect(session.phase == .failed(.network("离线了")))
}

@MainActor
@Test("a PGN with no readable game is not an empty success")
func noReadableGamesIsAFailure() async {
    let fetcher = ScriptedFetcher([
        "https://example.com/game.pgn": .success(chapter("broken", movetext: "1. e5 *"))
    ])
    let session = ImportSession(fetcher: fetcher)
    await session.run("https://example.com/game.pgn")

    #expect(session.phase == .failed(.noReadableGames))
}

@MainActor
@Test("input that is not a link fails before anything is fetched")
func notALinkFailsFast() async {
    let fetcher = ScriptedFetcher()
    let session = ImportSession(fetcher: fetcher)
    await session.run("not a link")

    #expect(session.phase == .failed(.notALink))
    #expect(fetcher.askedURLs.isEmpty)
}

// ------------------------------------------------------------------ apply

@MainActor
@Test("applying a plan writes one tagged file per chapter into the collection")
func applyWritesTaggedFiles() async throws {
    let tempDir = URL(filePath: NSTemporaryDirectory())
        .appending(path: "chessfen-import-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let library = GameLibrary(folder: GameFolder(url: tempDir))
    let session = ImportSession(
        fetcher: ScriptedFetcher([
            "https://lichess.org/study/HgiqcIqW.pgn": .success(twoChapterStudy)
        ])
    )
    await session.run("https://lichess.org/study/HgiqcIqW.pgn")

    let outcome = try #require(session.apply(into: "Wood Pecker", library: library))
    #expect(outcome.imported == 2)
    #expect(outcome.skipped == 0)
    #expect(outcome.unreadable == 0)

    library.reload()
    #expect(library.entries.count == 2)
    #expect(Set(library.entries.compactMap(\.name)) == ["1", "2"])
    for entry in library.entries {
        #expect(entry.collection == "Wood Pecker")
        #expect(entry.origin == .imported)
    }
}

@MainActor
@Test("importing the same study again skips every chapter already standing there")
func reimportSkipsByName() async throws {
    let tempDir = URL(filePath: NSTemporaryDirectory())
        .appending(path: "chessfen-import-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let library = GameLibrary(folder: GameFolder(url: tempDir))
    let first = ImportSession(
        fetcher: ScriptedFetcher([
            "https://lichess.org/study/HgiqcIqW.pgn": .success(twoChapterStudy)
        ])
    )
    await first.run("https://lichess.org/study/HgiqcIqW.pgn")
    _ = try #require(first.apply(into: "Wood Pecker", library: library))

    // The same study, the same door, again — and the names are what identify the games.
    let again = ImportSession(
        fetcher: ScriptedFetcher([
            "https://lichess.org/study/HgiqcIqW.pgn": .success(twoChapterStudy)
        ])
    )
    await again.run("https://lichess.org/study/HgiqcIqW.pgn")
    let outcome = try #require(again.apply(into: "Wood Pecker", library: library))
    #expect(outcome.imported == 0)
    #expect(outcome.skipped == 2)

    library.reload()
    #expect(library.entries.count == 2, "no doubles, no files added")
}

// ------------------------------------------------------------ imported games

@Test("the imported origin round-trips through the Source tag", .speaking(.chinese))
func importedOriginReadsBack() throws {
    let entry = GameLibrary.Entry(
        url: URL(filePath: "/games/x.pgn"),
        pgn: PGN(
            game: Game(startFEN: PGN.standardStartFEN)!,
            tags: [PGN.Tag(GameOrigin.tagName, GameOrigin.imported.tagValue)]
        ),
        modified: Date()
    )
    #expect(entry.origin == .imported)
    #expect(entry.origin.label == "导入")
    #expect(entry.origin.symbol == "link")

    let untagged = GameLibrary.Entry(
        url: URL(filePath: "/games/y.pgn"),
        pgn: PGN(game: Game(startFEN: PGN.standardStartFEN)!),
        modified: Date()
    )
    #expect(untagged.origin == .fresh)
}

@MainActor
@Test("an imported game played on stays in its collection")
func importedGameKeepsItsCollection() throws {
    let entry = GameLibrary.Entry(
        url: URL(filePath: "/games/x.pgn"),
        pgn: PGN(
            game: Game(startFEN: PGN.standardStartFEN)!,
            tags: [
                PGN.Tag("Event", "Wood Pecker"),
                PGN.Tag(GameOrigin.tagName, GameOrigin.imported.tagValue),
            ]
        ),
        modified: Date()
    )
    let session = try #require(GameSession.opened(entry))
    #expect(session.origin == .imported)

    let move = try #require(session.viewed.state.legalMoves.first)
    session.play(move)
    #expect(session.pgn.tag("Event") == "Wood Pecker", "a played-on game must not leave its set")
    #expect(session.pgn.tag(GameOrigin.tagName) == "imported")
}

// -------------------------------------------------------------- lichess games

/// One game as lichess exports it: the tags it writes, the `Site` that is the game's own URL,
/// and evals in the shape it writes them — braces with spaces inside, and a bare `0.2`.
private let oneLichessGame = """
    [Event "Rated Blitz game"]
    [Site "https://lichess.org/hf3Zpe5R"]
    [Date "2026.08.30"]
    [White "sunfmin"]
    [Black "DrNykterstein"]
    [Result "0-1"]
    [UTCDate "2026.08.30"]
    [UTCTime "21:14:03"]
    [WhiteElo "1520"]
    [BlackElo "2890"]
    [TimeControl "300+0"]
    [ECO "C50"]
    [Opening "Italian Game"]
    [Termination "Normal"]

    1. e4 { [%eval 0.24] } e5 { [%eval 0.31] } 2. Nf3 { [%eval 0.22] } Nc6 { [%eval 0.25] } 3. Bc4 { [%eval 0.18] } Nf6 { [%eval 0.2] } 0-1
    """

/// Two of somebody's games, as the user endpoint hands them over: newest first, one broken.
private let twoLichessGames = """
    [Event "Rated Blitz game"]
    [Site "https://lichess.org/hf3Zpe5R"]
    [White "sunfmin"]
    [Black "DrNykterstein"]
    [Result "0-1"]
    [UTCDate "2026.08.30"]
    [UTCTime "21:14:03"]

    1. e4 e5 2. Nf3 Nc6 0-1

    [Event "Rated Blitz game"]
    [Site "https://lichess.org/QQQQwwww"]
    [White "sunfmin"]
    [Black "penguingm1"]
    [Result "1-0"]
    [UTCDate "2026.08.29"]
    [UTCTime "09:02:11"]

    1. d4 d5 2. Nc3 Nf6 1-0
    """

private let exportOfOneGame =
    "https://lichess.org/game/export/hf3Zpe5R?evals=true&clocks=false"

@Test("a link to one game maps to its export, with or without a colour on the end")
func gameLinkMapsToItsExport() throws {
    let plain = try #require(PGNImport.candidateURLs(for: "https://lichess.org/hf3Zpe5R"))
    #expect(plain.map(\.absoluteString) == [exportOfOneGame])

    // The link a person copies out of the browser while watching it back as Black.
    let coloured = try #require(PGNImport.candidateURLs(for: "https://lichess.org/hf3Zpe5R/black"))
    #expect(coloured.map(\.absoluteString) == [exportOfOneGame])

    // A player's own link carries four more characters of private token; the game is the first
    // eight, which is what the export answers to.
    let mine = try #require(PGNImport.candidateURLs(for: "lichess.org/hf3Zpe5RabCd/white"))
    #expect(mine.map(\.absoluteString) == [exportOfOneGame])
}

@Test("the site's own pages are not read as game ids")
func sitePagesAreNotGames() throws {
    for page in ["https://lichess.org/training", "https://lichess.org/analysis"] {
        let candidates = try #require(PGNImport.candidateURLs(for: page))
        #expect(candidates.map(\.absoluteString) == [page], "\(page) is a page, not a game")
    }
    // Wrong shape rather than a reserved word: a name, and a path too deep to be a game.
    for page in ["https://lichess.org/@/sunfmin", "https://lichess.org/hf3Zpe5R/black/x"] {
        let candidates = try #require(PGNImport.candidateURLs(for: page))
        #expect(candidates.count == 1)
        #expect(!candidates[0].absoluteString.contains("/game/export/"))
    }
}

@MainActor
@Test("one game link imports that game, named by who played it and when", .speaking(.chinese))
func oneGameImports() async throws {
    let session = ImportSession(
        fetcher: ScriptedFetcher([exportOfOneGame: .success(oneLichessGame)])
    )
    await session.run("https://lichess.org/hf3Zpe5R/black")

    guard case .ready(let plan) = session.phase else {
        Issue.record("expected a plan, got \(session.phase)")
        return
    }
    #expect(plan.chapters.count == 1)
    #expect(plan.unreadable == 0)
    #expect(
        plan.chapters[0].name == "sunfmin 对 DrNykterstein · 2026.08.30 21:14",
        "not 「Rated Blitz game」, which every game of the day is called"
    )
    #expect(plan.chapters[0].identity == "lichess:hf3Zpe5R", "and the game's own URL identifies it")
    #expect(plan.chapters[0].pgn.game.plies.count == 6)
}

@Test("evaluations that came with a game stay the other site's numbers")
func importedEvalsAreNotOurs() throws {
    let pgn = try PGN(parsing: oneLichessGame)

    #expect(!pgn.game.isReviewed, "no [ReviewDepth], so nothing here may be called a mistake")
    #expect(pgn.game.reviewScore(atPly: 1) == nil)
    #expect(pgn.game.plies[0].evaluation == nil, "this app has not looked at this game")
    #expect(
        pgn.game.plies[0].importedEvaluation == .centipawns(24),
        "lichess's number, in lichess's shape: braces with spaces in them"
    )
    #expect(pgn.game.plies[5].importedEvaluation == .centipawns(20), "and a bare 0.2 is 20")
    #expect(pgn.game.criticality() == nil, "so no move in it can be ranked")
}

@Test("a username and a count make one URL, and a slip is clamped rather than refused")
func recentGamesURL() throws {
    let ten = try #require(PGNImport.recentGamesURL(user: "sunfmin", count: 10))
    #expect(ten.absoluteString.hasPrefix("https://lichess.org/api/games/user/sunfmin?max=10"))
    #expect(ten.absoluteString.contains("sort=dateDesc"), "recent means newest first")

    #expect(
        PGNImport.recentGamesURL(user: "@sunfmin", count: 5)?.path == "/api/games/user/sunfmin",
        "the @ people type in front of a handle is not part of it"
    )
    #expect(
        PGNImport.recentGamesURL(user: "sunfmin", count: 9_999)?.query?
            .contains("max=\(PGNImport.maxRecentGames)") == true
    )
    #expect(PGNImport.recentGamesURL(user: "sunfmin", count: 0)?.query?.contains("max=1") == true)

    for notAName in ["", "  ", "two names", "https://lichess.org/@/sunfmin", "a/b"] {
        #expect(PGNImport.recentGamesURL(user: notAName, count: 5) == nil, "\(notAName)")
    }
}

@MainActor
@Test("a username and a count land that many recent games in one collection", .speaking(.chinese))
func recentGamesImport() async throws {
    let url = try #require(PGNImport.recentGamesURL(user: "sunfmin", count: 2))
    let session = ImportSession(
        fetcher: ScriptedFetcher([url.absoluteString: .success(twoLichessGames)])
    )
    await session.recent(of: "sunfmin", count: 2)

    guard case .ready(let plan) = session.phase else {
        Issue.record("expected a plan, got \(session.phase)")
        return
    }
    #expect(plan.chapters.count == 2)
    #expect(plan.suggestedCollection == "sunfmin 的对局", "these games have no study to be named after")
    #expect(plan.chapters.map(\.identity) == ["lichess:hf3Zpe5R", "lichess:QQQQwwww"])
    #expect(plan.chapters[0].name.contains("DrNykterstein"))
    #expect(plan.chapters[1].name.contains("penguingm1"), "two games, two names")
}

@MainActor
@Test("a game already in the collection is skipped, so importing twice adds nothing")
func reimportingGamesAddsNothing() async throws {
    let tempDir = URL(filePath: NSTemporaryDirectory())
        .appending(path: "chessfen-games-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let library = GameLibrary(folder: GameFolder(url: tempDir))
    let url = try #require(PGNImport.recentGamesURL(user: "sunfmin", count: 2))
    func run() async -> ImportSession {
        let session = ImportSession(
            fetcher: ScriptedFetcher([url.absoluteString: .success(twoLichessGames)])
        )
        await session.recent(of: "sunfmin", count: 2)
        return session
    }

    let first = try #require(await run().apply(into: "上周", library: library))
    #expect(first.imported == 2)

    // The same two games again — and renamed in between, because the identity is the game's own
    // URL and not what anybody has since called it.
    library.reload()
    let renamed = try #require(library.entries.first)
    library.rename(renamed, to: "那局漏着")

    let again = try #require(await run().apply(into: "上周", library: library))
    #expect(again.imported == 0)
    #expect(again.skipped == 2)

    library.reload()
    #expect(library.entries.count == 2, "no doubles, no files added")
}

@MainActor
@Test("a game in the batch that will not parse is counted and skipped, never fatal")
func oneBrokenGameIsNotFatal() async throws {
    let broken = twoLichessGames + "\n\n[Event \"Rated Blitz game\"]\n\n1. e4 e5 2. Qz9 1-0\n"
    let url = try #require(PGNImport.recentGamesURL(user: "sunfmin", count: 3))
    let session = ImportSession(
        fetcher: ScriptedFetcher([url.absoluteString: .success(broken)])
    )
    await session.recent(of: "sunfmin", count: 3)

    guard case .ready(let plan) = session.phase else {
        Issue.record("expected a plan, got \(session.phase)")
        return
    }
    #expect(plan.chapters.count == 2)
    #expect(plan.unreadable == 1, "counted, and the report says so")
}

@Test("an HTTP status becomes the failure that names what happened", .speaking(.chinese))
func statusesAreNamed() throws {
    let game = try #require(URL(string: exportOfOneGame))
    let study = try #require(URL(string: "https://lichess.org/study/HgiqcIqW.pgn"))
    let user = try #require(PGNImport.recentGamesURL(user: "nobody", count: 5))
    let elsewhere = try #require(URL(string: "https://example.com/game.pgn"))

    #expect(PGNImport.Error.from(status: 404, url: game) == .missingGame)
    #expect(PGNImport.Error.from(status: 403, url: game) == .privateGame)
    #expect(PGNImport.Error.from(status: 403, url: study) == .privateStudy)
    #expect(PGNImport.Error.from(status: 404, url: user) == .unknownPlayer)
    #expect(PGNImport.Error.from(status: 500, url: game) == .http(500))
    #expect(
        PGNImport.Error.from(status: 403, url: elsewhere) == .http(403),
        "only lichess's statuses mean lichess's things"
    )

    // Each one says what happened, in its own words.
    #expect(PGNImport.Error.missingGame.alert.title.contains("找不到"))
    #expect(PGNImport.Error.privateGame.alert.message.contains("不对外"))
    #expect(PGNImport.Error.unknownPlayer.alert.title.contains("用户"))
}

@MainActor
@Test("an unavailable game is an honest error, and a bad username never reaches the network")
func honestFailures() async throws {
    let fetcher = ScriptedFetcher([exportOfOneGame: .failure(.missingGame)])
    let session = ImportSession(fetcher: fetcher)
    await session.run("https://lichess.org/hf3Zpe5R")
    #expect(session.phase == .failed(.missingGame))

    let quiet = ScriptedFetcher([:])
    let refused = ImportSession(fetcher: quiet)
    await refused.recent(of: "not a username", count: 5)
    #expect(refused.phase == .failed(.notAPlayer))
    #expect(quiet.askedURLs.isEmpty, "nothing was asked of the network")
}
