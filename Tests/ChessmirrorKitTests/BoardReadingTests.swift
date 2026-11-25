import ChessmirrorKit
import Foundation
import Testing

/// Contract: 盘面读数 (`GameSession.boardReading`) is the board the game screen draws — the
/// pieces of the position being looked at, the move just played, the squares in check, and
/// the one line on it: a 应招 being read, else the card in front of the player (docs/adr/0025).
@MainActor
@Suite struct BoardReadingTests {
    private func square(_ name: String) throws -> Square { try #require(Square(name)) }

    @Test func theBoardIsThePositionBeingLookedAt() throws {
        let game = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3", "e7e5", "g2g4", "d8h4"])
        )
        let session = GameSession.fresh(game)
        defer { session.suspend() }
        session.jumpToLatest()

        var board = session.boardReading
        #expect(board.pieces.count == 32)
        #expect(board.pieces[try square("h4")] == Piece(colour: .black, kind: .queen))
        #expect(board.pieces[try square("d8")] == nil, "the queen has left her square")
        #expect(board.lastMove == MoveSquares(from: try square("d8"), to: try square("h4")))
        #expect(board.checks == [try square("h4"), try square("e1")], "the checker and the king")
        #expect(board.plan.isEmpty, "no 应招 is being read and no card is open")

        session.step(by: -1)
        board = session.boardReading
        #expect(board.pieces[try square("d8")] == Piece(colour: .black, kind: .queen))
        #expect(board.pieces[try square("h4")] == nil)
        #expect(board.lastMove == MoveSquares(from: try square("g2"), to: try square("g4")))
        #expect(board.checks.isEmpty)
    }

    @Test func aReplyBeingReadIsTheLineOnTheBoard() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3", "e7e5"]))
        game.recordTried(.init(san: "g4", drop: 40, line: ["Qh4"]), atPly: 2)
        let session = GameSession.fresh(game)
        defer { session.suspend() }
        session.jumpToLatest()
        #expect(session.boardReading.plan.isEmpty)

        session.readReply(at: 0)
        let reading = try #require(session.replyReading)
        #expect(session.boardReading.plan == reading.arrows)
        #expect(session.boardReading.plan.map { "\($0.move.from)\($0.move.to)" } == ["g2g4", "d8h4"])
        #expect(
            session.boardReading.pieces[try square("g2")] == Piece(colour: .white, kind: .pawn),
            "the line is drawn over the board, not played on it"
        )

        session.readReply(at: 0)
        #expect(session.boardReading.plan.isEmpty, "putting the 应招 away takes its line off")
    }
}
