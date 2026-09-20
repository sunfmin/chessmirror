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
}
