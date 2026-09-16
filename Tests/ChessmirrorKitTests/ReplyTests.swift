@testable import ChessmirrorKit
import Testing

/// Contract: a 应招 is the 试招 and the moves that answer it, walked from the position the move
/// was refused in — numbered and coloured so the chips on the screen and the arrows on the board
/// cannot disagree about what the line is (docs/adr/0034).
@MainActor
@Suite struct ReplyTests {
    private func opening() throws -> Game {
        try #require(Game(startFEN: PGN.standardStartFEN))
    }

    @Test func theTriedMoveLeadsAndTheOpponentsAnswerFollows() throws {
        let position = try opening()
        let tried = Game.Ply.Tried(san: "f3", drop: 20, line: ["e5", "g4"])
        #expect(Reply.moves(of: tried) == ["f3", "e5", "g4"])

        let arrows = Reply.arrows(in: position, playing: Reply.moves(of: tried))
        #expect(arrows.map(\.step) == [1, 2, 3])
        #expect(arrows.map { "\($0.move.from)\($0.move.to)" } == ["f2f3", "e7e5", "g2g4"])
        // The move that was wrong is the player's; everything that answers it is not. Counted
        // from whoever played the 试招, so a game between two people still draws two colours.
        #expect(arrows.map(\.isYours) == [true, false, true])
        #expect(arrows.allSatisfy { !$0.isPlayed })
    }

    /// The player can be Black, and then the 试招 is the first move of the line all the same.
    @Test func whoseColourIsCountedFromTheMoveThatWasRefused() throws {
        let position = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
        let tried = Game.Ply.Tried(san: "e5", drop: 20, line: ["Nf3", "Nc6"])
        let arrows = Reply.arrows(in: position, playing: Reply.moves(of: tried))
        #expect(arrows.map(\.isYours) == [true, false, true])
    }

    @Test func aLineThatWillNotReplayStopsWhereItBreaks() throws {
        let position = try opening()
        let tried = Game.Ply.Tried(san: "f3", drop: 20, line: ["e5", "Qh4", "Nc6"])
        let arrows = Reply.arrows(in: position, playing: Reply.moves(of: tried))
        #expect(arrows.count == 2, "a move that is not legal there is where the drawing stops")
    }

    @Test func aReplyIsKeptOnlyAsLongAsABoardCanShowIt() {
        let tried = Game.Ply.Tried(san: "f3", drop: 20, line: (1...20).map { "m\($0)" })
        #expect(tried.line.count == Reply.limit)
        #expect(Reply.moves(of: tried).count == MateNews.arrowLimit)
    }

    @Test func aMoveTakenBackBeforeRepliesWereKeptHasNone() {
        let tried = Game.Ply.Tried(san: "f3", drop: 20)
        #expect(tried.line.isEmpty)
        #expect(Reply.moves(of: tried) == ["f3"])
    }
}
