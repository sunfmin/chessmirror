import ChessfenKit
import Testing

/// Replays `moves` through a tracker the way a board view does, one position at a time.
private func track(_ moves: [String], from startFEN: String = PGN.standardStartFEN) throws
    -> (game: Game, tracked: TrackedPlacement)
{
    var game = try #require(Game(startFEN: startFEN))
    var tracked = TrackedPlacement(try #require(BoardRenderer.placement(game.state.fen)))
    for uci in moves {
        let played = game.apply(uci: uci)
        #expect(played, "\(uci) is not legal in \(game.state.fen)")
        tracked.update(
            to: try #require(BoardRenderer.placement(game.state.fen)),
            moved: MoveSquares(uci: uci)
        )
    }
    return (game, tracked)
}

@Test("the tracked placement always agrees with the position")
func trackingAgreesWithTheFEN() throws {
    let (game, tracked) = try track([
        "e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "g8f6", "e1g1", "f8e7", "d2d4", "e5d4",
    ])
    #expect(tracked.placement == BoardRenderer.placement(game.state.fen))
    // Ten moves, one of them a capture: exd4.
    #expect(tracked.items.count == 31)
}

@Test("a piece keeps its identity as it moves")
func identitySurvivesAMove() throws {
    var tracked = TrackedPlacement(
        try #require(BoardRenderer.placement(PGN.standardStartFEN))
    )
    let e2 = try #require(Square("e2"))
    let e4 = try #require(Square("e4"))
    let pawn = try #require(tracked.items.first { $0.square == e2 })

    var game = try #require(Game(startFEN: PGN.standardStartFEN))
    let playedE2e4 = game.apply(uci: "e2e4")
    #expect(playedE2e4)
    tracked.update(
        to: try #require(BoardRenderer.placement(game.state.fen)),
        moved: MoveSquares(uci: "e2e4")
    )

    let moved = try #require(tracked.items.first { $0.square == e4 })
    #expect(moved.id == pawn.id, "the pawn that moved should be the same pawn")
    #expect(tracked.items.count == 32)
}

@Test("castling moves the rook with the king, keeping both")
func castlingMovesTwoPieces() throws {
    var tracked = TrackedPlacement(
        try #require(BoardRenderer.placement(PGN.standardStartFEN))
    )
    let king = try #require(tracked.items.first { $0.square == Square("e1") })
    let rook = try #require(tracked.items.first { $0.square == Square("h1") })

    let (game, _) = try track(["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5"])
    var replay = game
    let playedE1g1 = replay.apply(uci: "e1g1")
    #expect(playedE1g1)

    // Track the same sequence, then castle.
    let (_, before) = try track(["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5"])
    tracked = before
    tracked.update(
        to: try #require(BoardRenderer.placement(replay.state.fen)),
        moved: MoveSquares(uci: "e1g1")
    )

    let kingNow = try #require(tracked.items.first { $0.square == Square("g1") })
    let rookNow = try #require(tracked.items.first { $0.square == Square("f1") })
    #expect(kingNow.id == king.id)
    #expect(rookNow.id == rook.id, "the rook should slide, not appear")
    #expect(tracked.placement == BoardRenderer.placement(replay.state.fen))
}

@Test("a promoting pawn arrives as a queen without changing hands")
func promotionKeepsTheIdentity() throws {
    var game = try #require(Game(startFEN: "4k3/P7/8/8/8/8/8/4K3 w - - 0 1"))
    var tracked = TrackedPlacement(try #require(BoardRenderer.placement(game.state.fen)))
    let pawn = try #require(tracked.items.first { $0.square == Square("a7") })

    let playedA7a8q = game.apply(uci: "a7a8q")
    #expect(playedA7a8q)
    tracked.update(
        to: try #require(BoardRenderer.placement(game.state.fen)),
        moved: MoveSquares(uci: "a7a8q")
    )

    let queen = try #require(tracked.items.first { $0.square == Square("a8") })
    #expect(queen.id == pawn.id)
    #expect(queen.piece == Piece(colour: .white, kind: .queen))
}

@Test("a captured piece is dropped and the capturer keeps its identity")
func captureRemovesExactlyOnePiece() throws {
    let (_, before) = try track(["e2e4", "d7d5"])
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "d7d5"]))
    let capturer = try #require(before.items.first { $0.square == Square("e4") })

    var tracked = before
    let playedE4d5 = game.apply(uci: "e4d5")
    #expect(playedE4d5)
    tracked.update(
        to: try #require(BoardRenderer.placement(game.state.fen)),
        moved: MoveSquares(uci: "e4d5")
    )

    #expect(tracked.items.count == 31)
    let arrived = try #require(tracked.items.first { $0.square == Square("d5") })
    #expect(arrived.id == capturer.id)
}

@Test("taking a piece that is tracked before the capturer still moves the capturer")
func captureOfAnEarlierPieceMovesTheRightOne() throws {
    // Rook takes rook down the h-file. The captured rook is tracked before the capturer —
    // pieces are tracked in board order — so removing it shifts the capturer along, and an
    // index found before the removal points past the end of the list. On a phone that is a
    // crash rather than a glitch, which is what this position is here to keep out.
    var game = try #require(Game(startFEN: "4k2r/8/8/8/8/8/8/4K2R b - - 0 1"))
    var tracked = TrackedPlacement(try #require(BoardRenderer.placement(game.state.fen)))
    let capturer = try #require(tracked.items.first { $0.square == Square("h8") })

    let playedH8h1 = game.apply(uci: "h8h1")
    #expect(playedH8h1)
    tracked.update(
        to: try #require(BoardRenderer.placement(game.state.fen)),
        moved: MoveSquares(uci: "h8h1")
    )

    #expect(tracked.placement == BoardRenderer.placement(game.state.fen))
    #expect(tracked.items.count == 3)
    let arrived = try #require(tracked.items.first { $0.square == Square("h1") })
    #expect(arrived.id == capturer.id, "the rook should slide down the file, not appear")
    #expect(arrived.piece == Piece(colour: .black, kind: .rook))
}

@Test("en passant takes the pawn that is not on the destination square")
func enPassantRemovesTheRightPawn() throws {
    var game = try #require(
        Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "a7a6", "e4e5", "d7d5"])
    )
    var tracked = TrackedPlacement(try #require(BoardRenderer.placement(game.state.fen)))
    let playedE5d6 = game.apply(uci: "e5d6")
    #expect(playedE5d6)
    tracked.update(
        to: try #require(BoardRenderer.placement(game.state.fen)),
        moved: MoveSquares(uci: "e5d6")
    )

    #expect(tracked.placement == BoardRenderer.placement(game.state.fen))
    #expect(tracked.items.count == 31)
    #expect(tracked.items.allSatisfy { $0.square != Square("d5") })
}

@Test("stepping backwards animates rather than flickering")
func rewindingReusesPieces() throws {
    let (game, forward) = try track(["e2e4", "e7e5", "g1f3", "b8c6"])
    let previous = try #require(game.rewound(to: 3))

    var tracked = forward
    // No move to go on: this is a jump, which is what a review's slider does.
    tracked.update(to: try #require(BoardRenderer.placement(previous.state.fen)))

    #expect(tracked.placement == BoardRenderer.placement(previous.state.fen))
    #expect(tracked.items.count == 32)
    // The knight went back to b8 rather than being replaced by a new one.
    let knight = try #require(tracked.items.first { $0.square == Square("b8") })
    let before = try #require(forward.items.first { $0.square == Square("c6") })
    #expect(knight.id == before.id)
}

@Test("an edited square is replaced rather than mistaken for a move")
func editingCreatesAndRemoves() throws {
    var draft = try #require(PositionDraft(fen: PGN.standardStartFEN))
    var tracked = TrackedPlacement(draft.pieces)
    let count = tracked.items.count

    draft.setPiece(nil, at: try #require(Square("d2")))
    tracked.update(to: draft.pieces)
    #expect(tracked.items.count == count - 1)

    draft.setPiece(Piece(colour: .black, kind: .queen), at: try #require(Square("d4")))
    tracked.update(to: draft.pieces)
    #expect(tracked.items.count == count)
    #expect(tracked.placement == draft.pieces)
}

@Test("the two squares of a move are read off its UCI")
func moveSquaresParse() throws {
    let move = try #require(MoveSquares(uci: "e7e8q"))
    #expect(move.from == Square("e7"))
    #expect(move.to == Square("e8"))
    #expect(move.squares.count == 2)
    #expect(MoveSquares(uci: "e2") == nil)
    #expect(MoveSquares(uci: "") == nil)
}
