import ChessmirrorKit
import Foundation
import SwiftUI
import Testing

@testable import Chessmirror
import ChessmirrorKitTesting

/// A save that did not land, on the game screen (docs/adr/0054): the line at the foot says so
/// for as long as it is true, and goes when a save lands.
@MainActor
@Suite(.serialized, .drawing(in: .chinese))
struct UnsavedScreenshots {
    private func refusing(_ directory: URL, _ refuses: Bool) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: refuses ? 0o555 : 0o755], ofItemAtPath: directory.path
        )
    }

    @Test("a refused save is said at the foot of the game screen, and gone once one lands")
    func aRefusedSaveIsShown() async throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "chessmirror-unsaved-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? refusing(directory, false)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = GameLibrary(folder: GameFolder(url: directory))
        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        let session = GameSession.fresh(start, library: library)
        try refusing(directory, true)
        session.play(try #require(session.game.state.move(matching: "e2e4")))
        #expect(session.saveFailed)

        let unsaved = localized("game.unsaved")
        _ = await ScreenImage.write("game-unsaved", interact: { window in
            #expect(ScreenImage.words(in: window).contains { $0.contains(unsaved) })
            try? refusing(directory, false)
            if let move = session.game.state.move(matching: "e7e5") { session.play(move) }
            await ScreenImage.settle()
            #expect(!session.saveFailed)
            #expect(
                !ScreenImage.words(in: window).contains { $0.contains(unsaved) },
                "the save landed, and the line is gone"
            )
        }) {
            NavigationStack {
                GameScreen(session: session, path: .constant([]))
            }
            .environment(EngineHost(ScriptedEngine([])))
            .environment(library)
            .environment(CollectionShelf(library: library))
        }
    }

    @Test("the line sits on the screen, inside the safe area")
    func theLineIsOnTheScreen() async throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "chessmirror-unsaved-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? refusing(directory, false)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = GameLibrary(folder: GameFolder(url: directory))
        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        let session = GameSession.fresh(start, library: library)
        try refusing(directory, true)
        session.play(try #require(session.game.state.move(matching: "e2e4")))

        let rendered = await ScreenImage.write("game-unsaved-line") {
            NavigationStack {
                GameScreen(session: session, path: .constant([]))
            }
            .environment(EngineHost(ScriptedEngine([])))
            .environment(library)
            .environment(CollectionShelf(library: library))
        }
        let frames = rendered.frames(of: localized("game.unsaved"))
        #expect(frames.count == 1, "said once: \(rendered.words)")
        for frame in frames {
            #expect(rendered.safeArea.contains(frame), "\(frame) is outside \(rendered.safeArea)")
        }
    }
}
