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
                .environment(LanguageSetting.shared)
        }

        #expect(rendered.says("拍棋盘"), "the camera is still there, and still first")
        #expect(rendered.says("从开局摆起"))
        #expect(rendered.says("导入棋局"))
        #expect(rendered.says("走出第一步，这局就会记在这里"), "an empty library says so")
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
