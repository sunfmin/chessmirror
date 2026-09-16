@testable import ChessmirrorKit
import Foundation
import Testing

/// Contract: one walk lays out every position the player moved at, with everything that happened
/// there, and the game's own list of 错招 and the 错题本's Encounters are two gates over it — they
/// see the same positions and differ only in what they let through (docs/adr/0016, 0036, 0037).
@Suite struct StopsTests {
    /// A saved game with the player on White and the engine on Black.
    private func entry(_ game: Game) -> GameLibrary.Entry {
        GameLibrary.Entry(
            url: URL(filePath: "/games/stops.pgn"),
            pgn: PGN(game: game, tags: [
                PGN.Tag("White", Controller.hand.playerName),
                PGN.Tag("Black", Controller.engine.playerName),
            ]),
            modified: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    private func key(_ game: Game, atPly ply: Int) -> PositionKey? {
        game.rewound(to: ply).flatMap { PositionKey(fen: $0.state.fen) }
    }

    @Test func onlyThePositionsThePlayerMovedAtAreStops() throws {
        let game = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3"])
        )
        let stops = game.stops(by: [.white])
        #expect(stops.map(\.ply) == [1, 3])
        #expect(stops.map(\.move?.san) == ["e4", "Nf3"])
        #expect(stops[0].position == PositionKey(fen: PGN.standardStartFEN))
        #expect(stops[1].position == key(game, atPly: 2))
        #expect(stops.allSatisfy { $0.tried.isEmpty && $0.wanted == nil })
        #expect(game.stops(by: [.black]).map(\.ply) == [2])
        #expect(game.stops(by: []).isEmpty, "a game the engine played against itself has no stops")
    }

    @Test func aRefusalWaitingAtTheEndIsAStopWithoutAMove() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
        // f3 was refused and e4 stood; g4 was refused where the game stops, and nothing stood.
        game.setTried([.init(san: "f3", drop: 25)], atPly: 0)
        game.recordTried(.init(san: "g4", drop: 30), atPly: 2)
        let stops = game.stops(by: [.white])
        #expect(stops.map(\.ply) == [1, 3])
        #expect(stops[0].tried.map(\.san) == ["f3"])
        #expect(stops[0].move?.san == "e4")
        #expect(stops[1].tried.map(\.san) == ["g4"])
        #expect(stops[1].move == nil)
        #expect(stops[1].position == key(game, atPly: 2))
        #expect(game.stops(by: [.black]).map(\.ply) == [2], "the refusal at the end was White's, not Black's")
    }

    /// The gates: 正着's own judgement of a move that stood is a 错招 in the game's own list, and
    /// not an Encounter in the book, which compares across games and takes only a Review's number.
    @Test func theTwoReadersSeeTheSameStopsThroughDifferentGates() throws {
        var game = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3", "e7e5", "g2g4"])
        )
        game.setTried([.init(san: "h4", drop: 25)], atPly: 2)
        game.setJudgement(.init(drop: 40, score: .mate(in: -1), depth: 20), atPly: 2)

        let slips = game.slips(by: [.white], lines: .standard)
        let encounters = MistakeBook.encounters(in: entry(game))
        #expect(slips.map(\.ply) == [3])
        #expect(slips[0].wrong.map(\.san) == ["g4", "h4"], "worst first: what stood, what was refused")
        #expect(encounters.map(\.1.played) == ["h4"], "the book waits for a Review on the move that stood")
        #expect(encounters.map(\.0) == [slips[0].position])
        #expect(encounters.map(\.1.ply) == [3])

        game.applyReview(
            [.centipawns(-50), .centipawns(-60), .mate(in: -1)],
            startEvaluation: .centipawns(0), depth: 16
        )
        let reviewed = MistakeBook.encounters(in: entry(game))
        #expect(reviewed.map(\.1.played) == ["h4", "g4"], "and with a Review the move that stood is in the book too")
        #expect(Set(reviewed.map(\.0)).count == game.slips(by: [.white], lines: .standard).count,
                "the library's count of a game's positions is the game's own count")
    }

    @Test func anEncounterKnowsWhereToOpenTheGame() {
        let url = URL(filePath: "/games/one.pgn")
        let stood = Encounter(
            game: url, ply: 7, when: .now, played: "g4", wanted: nil, cost: 40, origin: .recognised
        )
        #expect(stood.arrivalPly == 7, "after the move, with the blunder on the board")
        let refused = Encounter(
            game: url, ply: 7, when: .now, played: "h4", wanted: nil, cost: 25, origin: .recognised,
            attempt: 0
        )
        #expect(refused.arrivalPly == 6, "a move taken back never stood: open where it was played from")
    }
}
