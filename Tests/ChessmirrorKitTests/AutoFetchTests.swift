import ChessmirrorKitTesting
import Foundation
import Testing

@testable import ChessmirrorKit

/// 自动拉局 (CONTEXT.md, docs/adr/0045): the 本人账号's new games, once a day and on a press,
/// carried on from where the last pull reached. Driven through a scripted network and a real
/// library in a temporary folder, so what is checked is what lands on disk.
@MainActor
@Suite(.speaking(.chinese))
struct AutoFetchTests {
    /// A clock the test moves, in a calendar that does not depend on where the test runs.
    final class Clock {
        var now: Date
        init(_ text: String) { now = Clock.utc(text) }
        static func utc(_ text: String) -> Date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy.MM.dd HH:mm:ss"
            return formatter.date(from: text)!
        }
    }

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// One lichess game as the user endpoint writes it.
    static func lichess(_ id: String, _ white: String, _ black: String, at start: String) -> String {
        let parts = start.split(separator: " ")
        return """
            [Event "Rated Blitz game"]
            [Site "https://lichess.org/\(id)"]
            [White "\(white)"]
            [Black "\(black)"]
            [Result "1-0"]
            [UTCDate "\(parts[0])"]
            [UTCTime "\(parts[1])"]

            1. e4 e5 2. Nf3 Nc6 1-0
            """
    }

    static func games(_ games: String...) -> String { games.joined(separator: "\n\n") }

    struct World {
        let library: GameLibrary
        let memory: ImportMemory
        let directory: URL
    }

    func world() throws -> World {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "chessmirror-autofetch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return World(
            library: GameLibrary(folder: GameFolder(url: directory)),
            memory: PlayerSettings(store: InMemorySettings()).imports,
            directory: directory
        )
    }

    @Test("the first pull takes the remembered count, writes the account's games, and marks where it reached")
    func theFirstPull() async throws {
        let world = try world()
        defer { try? FileManager.default.removeItem(at: world.directory) }
        world.memory.remember("SunFmin", on: .lichess)
        world.memory.count = 10
        let first = try #require(PGNImport.recentGamesURL(user: "SunFmin", count: 10))
        let fetcher = ScriptedFetcher([
            first.absoluteString: .success(Self.games(
                Self.lichess("newgame1", "Hikaru", "sunfmin", at: "2026.09.28 20:00:00"),
                Self.lichess("oldgame1", "sunfmin", "penguin", at: "2026.09.27 09:00:00")
            ))
        ])
        let clock = Clock("2026.09.29 08:02:00")
        let pull = AutoFetch(memory: world.memory, fetcher: fetcher, now: { clock.now }, calendar: Self.utc)

        #expect(pull.isDue, "nothing has been pulled yet")
        await pull.pullIfDue(into: world.library, reviewingWith: nil)

        #expect(pull.phase == .pulled(added: 2))
        #expect(fetcher.askedURLs == [first], "no since on the first pull, and the sheet's count")
        world.library.reload()
        #expect(world.library.entries.count == 2)
        #expect(world.library.entries.allSatisfy { $0.origin == .imported })
        #expect(
            world.library.entries.first?.pgn?.tag(PGN.Tags.site) == "https://lichess.org/newgame1",
            "the newest game is written last, so it is on top"
        )
        let newest = try #require(world.library.entries.first?.pgn)
        #expect(newest.trackedSide == .black, "the account's side is kept: sunfmin had Black")
        #expect(world.memory.reached("sunfmin", on: .lichess) == Clock.utc("2026.09.28 20:00:00"))
        #expect(!pull.isDue, "today is done")
        #expect(pull.reading == .init(text: "今天 8:02 拉过，新增 2 局", isAlarm: false))

        // Again the same day: nothing is asked.
        await pull.pullIfDue(into: world.library, reviewingWith: nil)
        #expect(fetcher.askedURLs.count == 1)
    }

    @Test("the next day carries on from where it reached, and a deleted game stays deleted")
    func theNextDayCarriesOn() async throws {
        let world = try world()
        defer { try? FileManager.default.removeItem(at: world.directory) }
        world.memory.remember("sunfmin", on: .lichess)
        let reached = Clock.utc("2026.09.28 20:00:00")
        world.memory.reach(reached, for: "sunfmin", on: .lichess)
        world.memory.pulled(at: Clock.utc("2026.09.28 21:00:00"))
        let since = try #require(
            PGNImport.recentGamesURL(user: "sunfmin", count: AutoFetch.cap, since: reached)
        )
        #expect(since.query?.contains("max=50") == true)
        #expect(since.query?.contains("since=1790625601000") == true, "a second after, in milliseconds")
        // The site includes the game it reached as well — as if its clock had it a second later.
        let fetcher = ScriptedFetcher([
            since.absoluteString: .success(Self.games(
                Self.lichess("today001", "sunfmin", "Hikaru", at: "2026.09.29 07:30:00"),
                Self.lichess("newgame1", "Hikaru", "sunfmin", at: "2026.09.28 20:00:00")
            ))
        ])
        let clock = Clock("2026.09.29 08:00:00")
        let pull = AutoFetch(memory: world.memory, fetcher: fetcher, now: { clock.now }, calendar: Self.utc)

        #expect(pull.isDue, "yesterday's pull does not count for today")
        #expect(pull.reading?.text == "昨天 21:00 拉过")
        await pull.pullIfDue(into: world.library, reviewingWith: nil)

        #expect(pull.phase == .pulled(added: 1), "the game it had already reached is not written again")
        world.library.reload()
        #expect(world.library.entries.map { $0.pgn?.tag(PGN.Tags.site) } == ["https://lichess.org/today001"])
        #expect(world.memory.reached("sunfmin", on: .lichess) == Clock.utc("2026.09.29 07:30:00"))

        // The press, later the same day, when nothing new has been played.
        let after = try #require(PGNImport.recentGamesURL(
            user: "sunfmin", count: AutoFetch.cap, since: Clock.utc("2026.09.29 07:30:00")
        ))
        let quiet = AutoFetch(
            memory: world.memory, fetcher: ScriptedFetcher([after.absoluteString: .success("")]),
            now: { clock.now }, calendar: Self.utc
        )
        await quiet.pull(into: world.library, reviewingWith: nil)
        #expect(quiet.phase == .pulled(added: 0), "nothing new is not a failure")
        #expect(quiet.reading?.text == "今天 8:00 拉过，没有新棋")
    }

    @Test("a pull writes at most fifty games from one account")
    func aPullIsCapped() async throws {
        let world = try world()
        defer { try? FileManager.default.removeItem(at: world.directory) }
        world.memory.remember("sunfmin", on: .lichess)
        let reached = Clock.utc("2026.09.01 00:00:00")
        world.memory.reach(reached, for: "sunfmin", on: .lichess)
        let url = try #require(PGNImport.recentGamesURL(user: "sunfmin", count: 50, since: reached))
        // Fifty-five games, newest first, one an hour after the point reached.
        let many = (1...55).reversed().map { hour in
            Self.lichess(
                String(format: "gm%06d", hour), "sunfmin", "rival",
                at: String(format: "2026.09.%02d %02d:00:00", 2 + hour / 24, hour % 24)
            )
        }.joined(separator: "\n\n")
        let pull = AutoFetch(
            memory: world.memory, fetcher: ScriptedFetcher([url.absoluteString: .success(many)]),
            now: { Clock.utc("2026.09.05 12:00:00") }, calendar: Self.utc
        )
        await pull.pull(into: world.library, reviewingWith: nil)
        #expect(pull.phase == .pulled(added: 50))
        world.library.reload()
        #expect(world.library.entries.count == 50)
    }

    @Test("chess.com carries on from the month it reached and never asks for an older one")
    func chessComCarriesOn() async throws {
        let world = try world()
        defer { try? FileManager.default.removeItem(at: world.directory) }
        world.memory.remember("sunfmin", on: .chessCom)
        world.memory.reach(Clock.utc("2026.09.10 10:00:00"), for: "sunfmin", on: .chessCom)
        let september = """
            [Event "Live Chess"]
            [White "sunfmin"]
            [Black "old"]
            [Result "1-0"]
            [UTCDate "2026.09.10"]
            [UTCTime "10:00:00"]
            [Link "https://www.chess.com/game/live/200000001"]

            1. e4 e5 1-0

            [Event "Live Chess"]
            [White "rival"]
            [Black "sunfmin"]
            [Result "0-1"]
            [UTCDate "2026.09.28"]
            [UTCTime "18:00:00"]
            [Link "https://www.chess.com/game/live/200000002"]

            1. d4 d5 0-1
            """
        let fetcher = ScriptedFetcher([
            "https://api.chess.com/pub/player/sunfmin/games/archives": .success(
                #"{"archives":["https://api.chess.com/pub/player/sunfmin/games/2026/08","https://api.chess.com/pub/player/sunfmin/games/2026/09"]}"#
            ),
            "https://api.chess.com/pub/player/sunfmin/games/2026/09/pgn": .success(september),
        ])
        let pull = AutoFetch(
            memory: world.memory, fetcher: fetcher,
            now: { Clock.utc("2026.09.29 08:00:00") }, calendar: Self.utc
        )
        await pull.pull(into: world.library, reviewingWith: nil)

        #expect(pull.phase == .pulled(added: 1))
        #expect(
            !fetcher.askedURLs.contains { $0.absoluteString.contains("2026/08") },
            "August is before the point reached"
        )
        world.library.reload()
        #expect(world.library.entries.first?.pgn?.trackedSide == .black)
    }

    @Test("a failure is said in the alarm colour, and the day is asked again")
    func aFailureIsAskedAgain() async throws {
        let world = try world()
        defer { try? FileManager.default.removeItem(at: world.directory) }
        world.memory.remember("SunFmn", on: .chessCom)
        world.memory.remember("sunfmin", on: .lichess)
        let lichess = try #require(PGNImport.recentGamesURL(user: "sunfmin", count: 10))
        let pull = AutoFetch(
            memory: world.memory,
            fetcher: ScriptedFetcher([
                lichess.absoluteString: .success(
                    Self.lichess("today001", "sunfmin", "Hikaru", at: "2026.09.29 07:30:00")
                ),
                "https://api.chess.com/pub/player/sunfmn/games/archives":
                    .failure(.unknownPlayer(.chessCom, "sunfmn")),
            ]),
            now: { Clock.utc("2026.09.29 08:00:00") }, calendar: Self.utc
        )
        await pull.pullIfDue(into: world.library, reviewingWith: nil)

        #expect(pull.phase == .failed(.chessCom, .unknownPlayer(.chessCom, "SunFmn")), "the name as typed")
        #expect(pull.reading == .init(text: "chess.com 上没有 SunFmn", isAlarm: true))
        world.library.reload()
        #expect(world.library.entries.count == 1, "the other account's games still came in")
        #expect(pull.isDue, "a day that failed is asked again")
    }

    @Test("with no 本人账号 nothing is asked, and the line says how to get one")
    func noAccount() async throws {
        let world = try world()
        defer { try? FileManager.default.removeItem(at: world.directory) }
        let fetcher = ScriptedFetcher()
        let pull = AutoFetch(memory: world.memory, fetcher: fetcher, calendar: Self.utc)
        await pull.pullIfDue(into: world.library, reviewingWith: nil)
        #expect(fetcher.askedURLs.isEmpty)
        #expect(pull.phase == .idle)
        #expect(pull.reading?.text == localized("autoFetch.noAccount"))
        #expect(pull.accounts.isEmpty)
    }

    @Test("where a pull reached travels with the settings, and never moves back")
    func whereItReachedTravels() {
        let store = InMemorySettings()
        let memory = PlayerSettings(store: store).imports
        memory.reach(Clock.utc("2026.09.28 20:00:00"), for: "SunFmin", on: .lichess)
        memory.reach(Clock.utc("2026.09.01 20:00:00"), for: "sunfmin", on: .lichess)
        memory.pulled(at: Clock.utc("2026.09.29 08:00:00"))
        let elsewhere = PlayerSettings(store: store).imports
        #expect(elsewhere.reached("sunfmin", on: .lichess) == Clock.utc("2026.09.28 20:00:00"))
        #expect(elsewhere.reached("sunfmin", on: .chessCom) == nil, "per site")
        #expect(elsewhere.lastPull == Clock.utc("2026.09.29 08:00:00"))
    }
}
