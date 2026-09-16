@testable import ChessfenKit
import Testing

/// Contract: a Game lays its own moves out the way a scoresheet is ruled — one row per move
/// number, White's half then Black's — and names any Ply's place in that ruling, including the
/// place the next move will take. The numbering hangs off where the Game began, which for a
/// Game read off a picture is rarely move one with White to move.
@Suite struct ScoresheetTests {
    @Test func aGameFromTheStartIsRuledFromMoveOne() throws {
        let game = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3"])
        )
        let rows = game.scoresheet
        #expect(rows.map(\.number) == [1, 2])
        #expect(rows[0].white == .init(ply: 1, san: "e4"))
        #expect(rows[0].black == .init(ply: 2, san: "e5"))
        #expect(rows[1].white == .init(ply: 3, san: "Nf3"))
        #expect(rows[1].black == nil, "Black has not answered yet")
        #expect(game.moveLabel(ofPly: 1) == "1.")
        #expect(game.moveLabel(ofPly: 2) == "1…")
        #expect(game.moveLabel(ofPly: 4) == "2…", "the place the next move will take")
    }

    /// A Game recognised from a picture began where the picture was taken: here at move twelve
    /// with Black to move, so the first row has no White half and the numbering starts at twelve.
    @Test func aGameBegunMidRowLeavesTheWhiteHalfEmpty() throws {
        let midGame = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 12"
        let game = try #require(Game(startFEN: midGame, uciMoves: ["e7e5", "g1f3", "b8c6"]))
        let rows = game.scoresheet
        #expect(rows.map(\.number) == [12, 13])
        #expect(rows[0].white == nil)
        #expect(rows[0].black == .init(ply: 1, san: "e5"))
        #expect(rows[1].white == .init(ply: 2, san: "Nf3"))
        #expect(rows[1].black == .init(ply: 3, san: "Nc6"))
        #expect(game.moveLabel(ofPly: 1) == "12…")
        #expect(game.moveLabel(ofPly: 2) == "13.")
        #expect(game.moveLabel(ofPly: 4) == "14.")
    }

    @Test func everyHalfIsTheCursorThatPutsItOnTheBoard() throws {
        let game = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["d2d4", "d7d5", "c2c4", "e7e6", "b1c3"])
        )
        let halves = game.scoresheet.flatMap { [$0.white, $0.black] }.compactMap { $0 }
        #expect(halves.map(\.ply) == [1, 2, 3, 4, 5])
        #expect(halves.map(\.san) == ["d4", "d5", "c4", "e6", "Nc3"])
        for half in halves {
            #expect(game.rewound(to: half.ply)?.plies.last?.san == half.san)
        }
    }

    @Test func aGameWithNoMovesHasAnEmptySheet() throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        #expect(game.scoresheet.isEmpty)
        #expect(game.moveLabel(ofPly: 1) == "1.")
    }
}
