import ChessmirrorKit
import Foundation
import Testing

/// Contract: the folder has two adapters and both of them work (docs/adr/0012).
///
/// `GameFolder(url:isCloud:)` is a seam, and it had one adapter: every test took the default and
/// ran the plain path, so the coordinated half — the one every save on a real phone goes through
/// — could only be exercised by a person with an iCloud account and a second device. The folder
/// is iCloud's or it is not; a temporary directory declared as iCloud's runs the same
/// `NSFileCoordinator` conversation the phone does, which is what is being held here.
@MainActor @Suite struct GameFolderTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pgn() throws -> PGN {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
        return PGN(
            game: game, seats: [.white: .hand, .black: .engine], origin: .fresh,
            lines: JudgementLines(noSlips: true)
        )
    }

    @Test("a coordinated write lands, reads back and is removable")
    func theCoordinatedPathWorks() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = GameFolder(url: directory, isCloud: true)
        let url = directory.appending(path: "game.pgn")

        #expect(folder.write(Data("[Event \"Chessmirror\"]\n\n*".utf8), to: url))
        #expect(folder.isHere(url), "a file on this device is here whatever the folder is")
        let text = folder.read(at: url) { try? String(contentsOf: $0, encoding: .utf8) }
        #expect(text?.contains("Chessmirror") == true)

        folder.remove(url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("both adapters read back what the other wrote")
    func theTwoAdaptersAgree() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plain = GameFolder(url: directory)
        let coordinated = GameFolder(url: directory, isCloud: true)
        let url = directory.appending(path: "shared.pgn")

        #expect(plain.write(Data("one".utf8), to: url))
        #expect(coordinated.read(at: url) { try? String(contentsOf: $0, encoding: .utf8) } == "one")
        #expect(coordinated.write(Data("two".utf8), to: url))
        #expect(plain.read(at: url) { try? String(contentsOf: $0, encoding: .utf8) } == "two")
    }

    @Test("a library on the cloud folder saves a game and lists it")
    func theLibrarySavesThroughTheCoordinator() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = GameLibrary(folder: GameFolder(url: directory, isCloud: true))
        let url = library.newURL()

        // The cloud branch answers "taken", not "written": the bytes land on a detached task.
        #expect(library.write(try pgn(), to: url))
        await library.written()

        #expect(FileManager.default.fileExists(atPath: url.path))
        let row = try #require(library.entries.first { $0.url == url })
        #expect(row.pgn?.game.uciMoves == ["e2e4", "e7e5"], "and the row holds the game it saved")
        #expect(!row.isDownloading)

        // Listing the folder again finds the same one game, read back off the disk.
        library.reload()
        #expect(library.entries.filter { $0.url == url }.count == 1,
                "the file saved and the file listed are one row, not two keys for one game")
    }

    @Test("a kept photograph lands on disk, never over another, and never as a game")
    func keptPhotographs() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = GameLibrary(folder: GameFolder(url: directory))
        let photo = RGBImage(
            width: 8, height: 6, pixels: (0..<(8 * 6 * 3)).map { UInt8($0 % 256) }
        )

        // Kept within the same second, they share a stamp: each still gets a file of its own.
        let urls = try (0..<3).map { _ in try #require(library.keepPhotograph(photo)) }
        #expect(Set(urls).count == 3, "no photograph overwrites another")
        for url in urls {
            #expect(url.lastPathComponent.hasPrefix("chessmirror-photo-"))
            #expect(url.pathExtension == "png")
            let back = try #require(RGBImage(contentsOf: url), "it reads back as the picture")
            #expect(back.width == 8 && back.height == 6)
            #expect(back.pixels == photo.pixels)
        }

        library.reload()
        #expect(library.entries.isEmpty, "a photograph is not a game in the list")
    }

    // ---------------------------------------------------------------- connecting

    /// An iCloud account that can be signed into mid-test.
    private final class Account: @unchecked Sendable {
        private let lock = NSLock()
        private var _container: URL?
        var container: URL? {
            get { lock.withLock { _container } }
            set { lock.withLock { _container = newValue } }
        }
    }

    @Test("with no iCloud, connecting leaves the library where it was")
    func noAccountStaysLocal() async throws {
        let local = try directory()
        defer { try? FileManager.default.removeItem(at: local) }
        try Data("game".utf8).write(to: local.appending(path: "a.pgn"))
        // The real lookup, not a stand-in: a test process carries no iCloud entitlement, so it
        // has no container whatever account the machine is signed into.
        try #require(GameFolder.ubiquityContainer() == nil, "a test must never reach a real iCloud")
        let folder = GameFolder(url: local)

        #expect(await folder.connect() == false)
        #expect(folder.url == local)
        #expect(!folder.isCloud)
        #expect(FileManager.default.fileExists(atPath: local.appending(path: "a.pgn").path))
    }

    @Test("connecting moves every local file into iCloud's Documents, overwriting nothing")
    func connectMovesTheGamesUp() async throws {
        let local = try directory()
        let container = try directory()
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(at: container)
        }
        let documents = container.appending(path: "Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        // The same game already up there from another device, and one taken twice over.
        try Data("theirs".utf8).write(to: documents.appending(path: "a.pgn"))
        try Data("theirs".utf8).write(to: documents.appending(path: "b.pgn"))
        try Data("theirs too".utf8).write(to: documents.appending(path: "b-2.pgn"))
        try Data("mine a".utf8).write(to: local.appending(path: "a.pgn"))
        try Data("photo".utf8).write(to: local.appending(path: "a.jpg"))
        try Data("mine b".utf8).write(to: local.appending(path: "b.pgn"))
        try Data("new".utf8).write(to: local.appending(path: "c.pgn"))

        let folder = GameFolder(url: local, container: { container })
        #expect(await folder.connect())
        #expect(folder.url.standardizedFileURL == documents.standardizedFileURL)
        #expect(folder.isCloud)

        func text(_ name: String) -> String? {
            try? String(contentsOf: documents.appending(path: name), encoding: .utf8)
        }
        #expect(text("a.pgn") == "theirs", "a name taken in iCloud is not overwritten")
        #expect(text("a-2.pgn") == "mine a", "the local copy lands beside it")
        #expect(text("a.jpg") == "photo", "the photograph goes up with its game")
        #expect(text("b.pgn") == "theirs")
        #expect(text("b-2.pgn") == "theirs too")
        #expect(text("b-3.pgn") == "mine b", "the suffix counts past every name taken")
        #expect(text("c.pgn") == "new")
        let left = try FileManager.default.contentsOfDirectory(atPath: local.path)
        #expect(left.isEmpty, "nothing is left behind locally")

        #expect(await folder.connect() == false, "a second call on the same folder changes nothing")
        #expect(text("a-3.pgn") == nil, "and moves nothing again")
    }

    @Test("signing into iCloud after launch switches the folder over")
    func signingInLaterConnects() async throws {
        let local = try directory()
        let container = try directory()
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(at: container)
        }
        let account = Account()
        let folder = GameFolder(url: local, container: { account.container })
        #expect(await folder.connect() == false)

        account.container = container
        NotificationCenter.default.post(name: .NSUbiquityIdentityDidChange, object: nil)
        // Yielding, not sleeping: the reconnect is a main-queue observer and a detached task,
        // done in a few milliseconds; the deadline is only there so a regression fails.
        let deadline = ContinuousClock.now + .seconds(5)
        while !folder.isCloud, ContinuousClock.now < deadline { await Task.yield() }

        #expect(folder.isCloud, "the account notification is what notices the sign-in")
        #expect(folder.url.lastPathComponent == "Documents")
    }
}
