import ChessmirrorKit
import ChessmirrorKitTesting
import Foundation
import Testing

/// Contract: 门 — which door the sheet opens on, whose name is in the field, what the button
/// says it will do, when a name is remembered, and what the sheet says about what came down
/// (CONTEXT.md, docs/adr/0045). Every answer here was a screenshot away while it was the sheet's.
@MainActor
@Suite(.speaking(.chinese)) struct ImportDoorsTests {
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

    private func memory(remembering names: [String] = [], on site: PGNImport.Site = .lichess) -> ImportMemory {
        let memory = PlayerSettings(store: InMemorySettings()).imports
        for name in names.reversed() { memory.remember(name, on: site) }
        return memory
    }

    private func shelf() throws -> (GameLibrary, MistakeIndex, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let library = GameLibrary(folder: GameFolder(url: folder))
        let book = MistakeIndex(log: PracticeLog(url: folder.appending(path: "practice.jsonl")))
        return (library, book, folder)
    }

    /// The door as it opens for somebody who has fetched before: the last account in the field,
    /// the others a chip away, and the button saying what it is about to do with them.
    @Test("a remembered account is in the field, and the button says whose games it will fetch")
    func rememberedAccount() {
        let memory = memory(remembering: ["sunfmin", "DrNykterstein"])
        memory.count = 20
        let doors = ImportDoors(memory: memory)
        #expect(doors.door == .lichess)
        #expect(doors.text == "sunfmin", "the account that fetched last, already in the field")
        #expect(doors.remembered == ["sunfmin", "DrNykterstein"], "and the other one, a tap away")
        #expect(doors.count == 20)
        #expect(doors.fetchLabel == "拉 sunfmin 最近 20 局")
        #expect(doors.account == "sunfmin")
    }

    /// The door and the count used last are the ones the sheet opens on next time.
    @Test("the door and the count are remembered")
    func theDoorAndCountAreRemembered() {
        let memory = memory()
        let doors = ImportDoors(memory: memory)
        doors.open(.chessCom)
        doors.ask(for: 50)
        let reopened = ImportDoors(memory: memory)
        #expect(reopened.door == .chessCom)
        #expect(reopened.count == 50)
        #expect(ImportDoors(memory: memory, initialDoor: .link).door == .link, "unless another is asked for")
    }

    /// A fetch that works moves the name to the front of memory; one that fails remembers
    /// nothing, because a misspelling is not an account.
    @Test("fetching moves the account to the front of what is remembered, and only when it fetched")
    func fetchingRemembers() async throws {
        let memory = memory(remembering: ["DrNykterstein", "sunfmin"])
        let url = try #require(PGNImport.recentGamesURL(user: "sunfmin", count: 10))
        let session = ImportSession(fetcher: ScriptedFetcher([url.absoluteString: .success(Self.myGames)]))
        let doors = ImportDoors(session: session, memory: memory)

        doors.pick("sunfmin")
        #expect(doors.fetchLabel == "拉 sunfmin 最近 10 局")
        await doors.fetch()
        guard case .ready = session.phase else {
            Issue.record("expected the games, got \(session.phase)")
            return
        }
        #expect(memory.names[.lichess] == ["sunfmin", "DrNykterstein"], "the one that fetched, first")

        doors.text = "nobody-here"
        await doors.fetch()
        #expect(memory.names[.lichess] == ["sunfmin", "DrNykterstein"], "a name that failed is not kept")
    }

    /// chess.com's answer to a name it does not have: the message says the name as typed, the
    /// field is at fault, and the way forward is the fetch with a corrected name.
    @Test("a name chess.com does not know is said back as typed, against its field")
    func chessComUnknownName() async throws {
        let memory = memory(remembering: ["SunFmn"], on: .chessCom)
        let archives = try #require(PGNImport.chessComArchivesURL(user: "SunFmn"))
        let session = ImportSession(fetcher: ScriptedFetcher([
            archives.absoluteString: .failure(.unknownPlayer(.chessCom, "sunfmn"))
        ]))
        let doors = ImportDoors(session: session, memory: memory, initialDoor: .chessCom)
        #expect(doors.door.prompt == "chess.com 用户名")
        await doors.fetch()
        guard case .failed(let error) = session.phase else {
            Issue.record("expected a failure, got \(session.phase)")
            return
        }
        #expect(error.alert.title.contains("chess.com 上没有 SunFmn"), "the site and the name, as typed")
        #expect(doors.isInputAtFault)
        #expect(doors.retryLabel == "拉 SunFmn 最近 10 局", "not a bare 重试")
    }

    /// A game that is not there is about the link; a network that is not there is not.
    @Test("a missing game is the link's fault, and a dead network is not")
    func missingGame() async throws {
        let link = "https://lichess.org/hf3Zpe5R/black"
        let session = ImportSession(fetcher: ScriptedFetcher([
            "https://lichess.org/game/export/hf3Zpe5R?evals=true&clocks=false": .failure(.missingGame)
        ]))
        let doors = ImportDoors(session: session, memory: memory(), initialInput: link)
        #expect(doors.door == .link)
        await doors.fetch()
        #expect(doors.isInputAtFault)
        #expect(doors.retryLabel == "获取棋谱")

        let offline = ImportDoors(
            session: ImportSession(fetcher: ScriptedFetcher([:])), memory: memory(), initialInput: link
        )
        await offline.fetch()
        #expect(!offline.isInputAtFault)
        #expect(offline.retryLabel == "重试")
    }

    /// A 国象联盟 share link opens its own door, asks for no count, and reads its game without
    /// the network.
    @Test("a 国象联盟 share link opens its own door with the game already read")
    func chesseaseDoor() async throws {
        let quiet = ScriptedFetcher([:])
        let doors = ImportDoors(
            session: ImportSession(fetcher: quiet), memory: memory(), initialInput: chesseaseShareLink
        )
        #expect(doors.door == .chessease)
        #expect(!doors.door.asksForPlayer, "no count: a share link is one game")
        #expect(doors.fetchLabel == "读这局棋")
        #expect(doors.account == nil)
        await doors.fetch()
        guard case .ready(let plan) = doors.session.phase else {
            Issue.record("expected the game, got \(doors.session.phase)")
            return
        }
        #expect(plan.chapters.count == 1)
        #expect(quiet.askedURLs.isEmpty, "nothing was asked of the network")
    }

    /// 「再来」 keeps a player's name and empties a link; clearing empties either.
    @Test("again keeps a name and empties a link")
    func againKeepsANameAndEmptiesALink() {
        let doors = ImportDoors(memory: memory(remembering: ["sunfmin"]))
        doors.again()
        #expect(doors.text == "sunfmin")
        doors.open(.link)
        doors.text = "https://lichess.org/study/abc"
        doors.again()
        #expect(doors.text.isEmpty)
        doors.open(.lichess)
        #expect(doors.text == "sunfmin", "each door keeps its own text")
        doors.clear()
        #expect(!doors.canFetch)
        #expect(doors.fetchLabel == "获取棋谱")
    }

    /// What came down, as the sheet says it — the count, the press, what the press did — and a
    /// row per game as the account would tell it.
    @Test("the sheet reads the plan against the library, before and after 入库")
    func theSheetReadsThePlan() async throws {
        let (library, book, folder) = try shelf()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try #require(PGNImport.recentGamesURL(user: "sunfmin", count: 10))
        let session = ImportSession(fetcher: ScriptedFetcher([url.absoluteString: .success(Self.myGames)]))
        let doors = ImportDoors(session: session, memory: memory(remembering: ["sunfmin"]))
        await doors.fetch()
        guard case .ready(let plan) = session.phase else {
            Issue.record("expected the games, got \(session.phase)")
            return
        }

        let before = doors.reading(plan, in: library, wrongByGame: book.wrongByGame, hasEngine: false)
        #expect(before.summary == "2 局")
        #expect(before.tapHint.contains("sunfmin"))
        #expect(before.apply == "入库 2 局")
        #expect(before.applied == nil)

        let row = doors.row(plan.chapters[0], in: library, wrongByGame: book.wrongByGame)
        #expect(row.side == .white)
        #expect(row.title == "DrNykterstein", "the opponent, from the account's side")
        #expect(row.verdict != nil)
        #expect(row.spoken.hasPrefix(PieceColour.white.label))

        session.apply(into: library, as: doors.account)
        let after = doors.reading(plan, in: library, wrongByGame: book.wrongByGame, hasEngine: false)
        #expect(after.apply == nil, "nothing left to add")
        #expect(after.applied == localized("import.done", plural: 2))

        // The same games again: nothing new lands, and the sheet says so rather than 0 局.
        await doors.fetch()
        session.apply(into: library, as: doors.account)
        guard case .ready(let again) = session.phase else { return }
        #expect(doors.reading(again, in: library, wrongByGame: book.wrongByGame, hasEngine: true).applied
                == localized("import.applied.none"))
    }
}
