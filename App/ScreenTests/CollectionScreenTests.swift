import ChessmirrorKit
import Foundation
import SwiftUI
import Testing

@testable import Chessmirror
import ChessmirrorKitTesting

/// 收藏集 on the screen: the rows on 首页, a set opened, and the heart over the board
/// (docs/adr/0051).
@MainActor
@Suite(.serialized, .drawing(in: .chinese))
struct CollectionScreenshots {
    private func tempDir() throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "chessmirror-sets-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6?? — reviewed, both sides by hand: Qxf7 is mate, and that is
    /// a 杀招 for White.
    private func scholar(in directory: URL) throws -> GameLibrary {
        var game = try #require(Game(
            startFEN: PGN.standardStartFEN,
            uciMoves: ["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6"]
        ))
        game.applyReview(
            Array(repeating: Score.centipawns(30), count: 5) + [.mate(in: 1)],
            startEvaluation: .centipawns(20), depth: 16
        )
        let pgn = PGN(
            game: game,
            tags: [
                PGN.Tag("White", Controller.hand.playerName),
                PGN.Tag("Black", Controller.hand.playerName),
                PGN.Tag(GameLibrary.nameTag, "周三那盘"),
            ]
        )
        try pgn.text.write(to: directory.appending(path: "scholar.pgn"), atomically: true, encoding: .utf8)
        return GameLibrary(folder: GameFolder(url: directory))
    }

    @Test("首页 lists 杀招 once the games have one, and 喜爱 always, saying how to fill it")
    func theFirstScreenListsTheSets() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try scholar(in: directory)
        let index = MistakeIndex(log: PracticeLog(url: directory.appending(path: "p.jsonl")))
        index.update(from: library.entries)
        let shelf = CollectionShelf(library: library)

        let rendered = await ScreenImage.write("collections-first-screen") {
            LibraryScreen()
                .environment(EngineHost(ScriptedEngine([])))
                .environment(library)
                .environment(shelf)
                .environment(index)
        }
        #expect(rendered.says(localized("screen.mate")))
        #expect(rendered.says(localized("collection.items", plural: 1)))
        #expect(!rendered.says(localized("screen.tactics")), "an empty 自动集 takes no row")
        #expect(rendered.says(localized("collection.favourites")))
        #expect(rendered.says(localized("collection.favouritesEmpty")))
    }

    @Test("a 杀招 opened shows the position from the side with the shot, and whose chance it was")
    func aFoundSetOpens() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try scholar(in: directory)
        let index = MistakeIndex(log: PracticeLog(url: directory.appending(path: "p.jsonl")))
        index.update(from: library.entries)

        let rendered = await ScreenImage.write("collection-mate") {
            NavigationStack {
                CollectionScreen(kind: .found(.mate), path: .constant([]))
            }
            .environment(EngineHost(ScriptedEngine([])))
            .environment(library)
            .environment(CollectionShelf(library: library))
            .environment(index)
        }
        #expect(rendered.says(localized("collection.whiteToMove")))
        #expect(rendered.says(localized("collection.yours")))
        #expect(rendered.says(localized("collection.from", "周三那盘", 4)))
        #expect(!rendered.says("练这一组"), "no block practice (docs/adr/0032)")
    }

    @Test("the heart keeps the position in 喜爱 and says so; a full heart opens the sets")
    func theHeartKeepsAPosition() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = GameLibrary(folder: GameFolder(url: directory))
        let shelf = CollectionShelf(library: library)
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
        let session = GameSession.fresh(game, controllers: [.white: .hand, .black: .hand])
        let position = try #require(PositionKey(fen: session.viewed.state.fen))

        let rendered = await ScreenImage.write("collection-heart", interact: { window in
            #expect(!shelf.isKept(position))
            #expect(ScreenImage.activate(localized("collection.heart"), in: window))
            await ScreenImage.settle()
            #expect(shelf.names(holding: position) == [PlayerCollection.favouritesName])
            #expect(ScreenImage.words(in: window).contains {
                $0.contains(localized("collection.kept", localized("collection.favourites")))
            })
        }) {
            NavigationStack {
                GameScreen(session: session, path: .constant([]))
            }
            .environment(EngineHost(ScriptedEngine([])))
            .environment(library)
            .environment(shelf)
        }
        #expect(rendered.says(localized("collection.change")))
        // What was kept is a file in the set's folder, a PGN a chess program can open.
        let file = shelf.directory.appending(path: "\(PlayerCollection.favouritesName).pgn")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("[FEN \"\(position.text) 0 1\"]"))
        #expect(library.entries.isEmpty, "a set is not a game")
    }

    @Test("喜爱 opened lists what the heart kept, with the game it came from")
    func favouritesOpens() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try scholar(in: directory)
        let shelf = CollectionShelf(library: library)
        let game = try #require(library.entries.first?.pgn?.game.rewound(to: 4))
        let position = try #require(PositionKey(fen: game.state.fen))
        #expect(shelf.add(position, to: PlayerCollection.favouritesName,
                          game: library.entries.first?.url, ply: 4))
        #expect(shelf.create("意大利开局"))

        let rendered = await ScreenImage.write("collection-favourites") {
            NavigationStack {
                CollectionScreen(kind: .favourites, path: .constant([]))
            }
            .environment(EngineHost(ScriptedEngine([])))
            .environment(library)
            .environment(shelf)
            .environment(MistakeIndex(log: PracticeLog(url: directory.appending(path: "p.jsonl"))))
        }
        #expect(rendered.says(localized("collection.whiteToMove")))
        #expect(rendered.says(localized("collection.from", "周三那盘", 3)))
        #expect(!rendered.says(localized("collection.yours")), "whose chance is a 自动集's question")
    }

    @Test("the sets open over the board, ticked where the position is, with a way to make one")
    func theChooserTicksTheSets() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = GameLibrary(folder: GameFolder(url: directory))
        let shelf = CollectionShelf(library: library)
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["d2d4"]))
        let session = GameSession.fresh(game, controllers: [.white: .hand, .black: .hand])
        let position = try #require(PositionKey(fen: session.viewed.state.fen))
        #expect(shelf.create("后翼弃兵"))
        #expect(shelf.add(position, to: "后翼弃兵"))

        let rendered = await ScreenImage.write("collection-chooser", interact: { window in
            // A tap on 喜爱 puts the position there too: several sets at once is allowed.
            #expect(ScreenImage.activate(localized("collection.favourites"), in: window))
            await ScreenImage.settle()
        }) {
            CollectionChooser(session: session).environment(shelf)
        }
        #expect(rendered.says(localized("collection.choose")))
        #expect(rendered.says("后翼弃兵"))
        #expect(rendered.says(localized("collection.new")))
        #expect(shelf.names(holding: position) == [PlayerCollection.favouritesName, "后翼弃兵"])
    }
}
