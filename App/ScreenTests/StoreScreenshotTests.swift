import ChessmirrorKit
import ChessmirrorKitTesting
import SwiftUI
import Testing
import UIKit

@testable import Chessmirror

/// The pictures on the App Store page, drawn by the app rather than taken by hand.
///
/// They come out at the size of whatever simulator the run is on, which is how the store wants
/// them: once on a 6.9-inch iPhone and once on a 13-inch iPad (docs/appstore.md has the two
/// commands). Each is written as `store-<store language>-<iphone|ipad>-<n>-<what>.png`, and
/// `fastlane store_screenshots` sorts them into the store's languages by that name.
@MainActor
@Suite(.serialized)
struct StoreScreenshotTests {
    @Test("the store's pictures, in Chinese", .drawing(in: .chinese))
    func chinese() async throws { try await shoot(store: "zh-Hans", gameName: "周三那盘") }

    @Test("the store's pictures, in English", .drawing(in: .english))
    func english() async throws { try await shoot(store: "en-US", gameName: "Wednesday's game") }

    private func shoot(store language: String, gameName: String) async throws {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let name = { (shot: String) in "store-\(language)-\(device)-\(shot)" }

        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "chessmirror-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 首页, with a game in the library that has left a 错题 and a 杀招 behind it:
        // 1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6?? and Qxf7 is mate.
        var scholar = try #require(Game(
            startFEN: PGN.standardStartFEN,
            uciMoves: ["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6"]
        ))
        scholar.applyReview(
            Array(repeating: Score.centipawns(30), count: 5) + [.mate(in: 1)],
            startEvaluation: .centipawns(20), depth: 16
        )
        let pgn = PGN(
            game: scholar,
            tags: [
                PGN.Tag("White", Controller.hand.playerName),
                PGN.Tag("Black", Controller.hand.playerName),
                PGN.Tag(GameLibrary.nameTag, gameName),
            ]
        )
        try pgn.text.write(to: directory.appending(path: "scholar.pgn"), atomically: true, encoding: .utf8)
        let library = GameLibrary(folder: GameFolder(url: directory))
        let index = MistakeIndex(log: PracticeLog(url: directory.appending(path: "p.jsonl")))
        index.update(from: library.entries)
        let home = await ScreenImage.write(name("1-home")) {
            LibraryScreen(autoFetch: .quiet)
                .environment(EngineHost(ScriptedEngine([])))
                .environment(library)
                .environment(CollectionShelf(library: library))
                .environment(index)
        }
        #expect(home.says(localized("screen.mate")))

        // A game against the engine: the Italian, eight plies in, White to move.
        let italian = try #require(Game(
            startFEN: PGN.standardStartFEN,
            uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6"]
        ))
        for (shot, style) in [("2-game", UIUserInterfaceStyle.light), ("3-game-dark", .dark)] {
            let session = GameSession.fresh(italian, controllers: [.white: .hand, .black: .engine])
            defer { session.suspend() }
            let engine = ScriptedEngine(
                [GameScreenScreenshots.opinion(.centipawns(24), best: ("d2d4", "d4"))], isEndless: true
            )
            let game = await ScreenImage.write(name(shot), style: style) {
                NavigationStack {
                    GameScreen(session: session, path: .constant([]))
                }
                .environment(EngineHost(engine))
                .environment(GameLibrary()).environment(CollectionShelf(library: GameLibrary()))
            }
            #expect(game.says(PieceColour.white.label))
        }
    }
}
