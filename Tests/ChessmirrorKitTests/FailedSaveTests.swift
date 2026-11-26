import ChessmirrorKit
import Foundation
import Testing

/// Contract: a save that does not land is a state of the session, until one lands
/// (docs/adr/0054).
///
/// `save()` used to drop `write`'s answer, and an iCloud write that failed on its detached task
/// returned without a trace: a game the player believed was kept could be lost with nothing on
/// the screen. A folder made read-only refuses the write on both of the folder's adapters.
@MainActor @Suite struct FailedSaveTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func refusing(_ directory: URL, _ refuses: Bool) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: refuses ? 0o555 : 0o755], ofItemAtPath: directory.path
        )
    }

    private func play(_ uci: String, on session: GameSession) throws {
        session.play(try #require(session.game.state.move(matching: uci)))
    }

    @Test("a refused save is reported, and the next one that lands clears it", arguments: [false, true])
    func aRefusedSaveIsReported(isCloud: Bool) async throws {
        let directory = try directory()
        defer {
            try? refusing(directory, false)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = GameLibrary(folder: GameFolder(url: directory, isCloud: isCloud))
        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        let session = GameSession.fresh(start, library: library)
        defer { session.suspend() }

        try play("e2e4", on: session)
        await library.written()
        #expect(!session.saveFailed, "a save that lands is not reported")

        try refusing(directory, true)
        try play("e7e5", on: session)
        await library.written()
        #expect(session.saveFailed, "the folder refused the save, and the session says so")

        try refusing(directory, false)
        try play("g1f3", on: session)
        await library.written()
        #expect(!session.saveFailed, "the next save landed, and the report is gone")
        let url = try #require(session.url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("Nf3"), "and what landed is the newest state")
    }
}
