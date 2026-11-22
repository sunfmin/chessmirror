import ChessmirrorKit
import Foundation
import Testing

/// The engine has one name, and it is the vendored Stockfish's own (chessmirror#15): the bar, the
/// about screen, the PGN roster and the store text all say what is linked in, and a game saved
/// under an earlier engine keeps the name it was saved with.
@Suite("The engine's name")
struct EngineNameTests {
    @Test("the name is the vendored Stockfish's, and the roster writes it")
    func theNameIsStockfishs() {
        #expect(EngineService.name == "Stockfish 19")
        #expect(Controller.engine.playerName == EngineService.name)
        #expect(Strength.full.engineName == EngineService.name)
    }

    /// The store text cannot read the name from the source, so it is held to it here.
    @Test("the store's descriptions name the engine that is linked in")
    func theStoreTextNamesTheEngine() throws {
        let metadata = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fastlane/metadata")
        let languages = try FileManager.default.contentsOfDirectory(atPath: metadata.path)
        var read = 0
        for language in languages {
            let file = metadata.appending(path: "\(language)/description.txt")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            read += 1
            let named = text.matches(of: /Stockfish \d+/).map { String($0.output) }
            #expect(!named.isEmpty && named.allSatisfy { $0 == EngineService.name }, "\(language): \(named)")
        }
        #expect(read >= 2)
    }

    @Test("a game saved under Stockfish 18 keeps that name when it is saved again")
    func aSavedGameKeepsItsEnginesName() throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
        let seats: [PieceColour: Controller] = [.white: .hand, .black: .engine]
        let resaved = PGN(
            game: game, seats: seats, origin: .fresh, lines: .standard,
            carrying: [PGN.Tag("White", "手动"), PGN.Tag("Black", "Stockfish 18")]
        )
        #expect(resaved.playerName(.black) == "Stockfish 18")
        #expect(Controller.isEngine("Stockfish 18"))

        let fresh = PGN(game: game, seats: seats, origin: .fresh, lines: .standard)
        #expect(fresh.playerName(.black) == EngineService.name)
        // A seat handed from a person to the engine is the engine now, whatever the file said.
        let handedOver = PGN(
            game: game, seats: seats, origin: .fresh, lines: .standard,
            carrying: [PGN.Tag("White", "手动"), PGN.Tag("Black", "手动")]
        )
        #expect(handedOver.playerName(.black) == EngineService.name)
        // And an engine seat handed to a person is a person's.
        let takenBack = PGN(
            game: game, seats: [.white: .hand, .black: .hand], origin: .fresh, lines: .standard,
            carrying: [PGN.Tag("White", "手动"), PGN.Tag("Black", "Stockfish 18")]
        )
        #expect(takenBack.playerName(.black) == Controller.hand.playerName)
    }
}
