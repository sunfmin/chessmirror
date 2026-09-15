import ChessfenKit
import Testing

private let start = PGN.standardStartFEN

private func square(_ name: String) throws -> Square {
    try #require(Square(name))
}

// ------------------------------------------------------------------- control

@Test("the starting position's control map is symmetric and knows the busy squares")
func startingControlMap() throws {
    let control = try #require(Rules.control(startFEN: start))

    // d2 and e2 are the most defended squares on the board: king, queen, bishop and knight
    // between them. If this is 3 or 5, the map is counting something wrong.
    #expect(control.attackers(of: try square("d2"), by: .white) == 4)
    #expect(control.attackers(of: try square("e2"), by: .white) == 4)
    #expect(control.attackers(of: try square("d7"), by: .black) == 4)

    // A piece does not attack the square it stands on: nothing covers a1 or h1.
    #expect(control.attackers(of: try square("a1"), by: .white) == 0)
    #expect(control.attackers(of: try square("h8"), by: .black) == 0)

    // Both armies are two ranks from the middle, so no side controls the centre yet.
    for name in ["d4", "e4", "d5", "e5"] {
        let middle = try square(name)
        #expect(control.attackers(of: middle, by: .white) == 0)
        #expect(control.attackers(of: middle, by: .black) == 0)
        #expect(control.holder(of: middle) == nil)
    }

    // Every square either side covers is covered by that side alone at move one.
    #expect(control.holder(of: try square("d3")) == .white)
    #expect(control.holder(of: try square("d6")) == .black)
}

@Test("control follows the moves, not just the starting FEN")
func controlFollowsMoves() throws {
    let after = try #require(Rules.control(startFEN: start, moves: ["e2e4"]))
    // The pawn on e4 now covers d5 and f5, which nothing did a move ago.
    #expect(after.attackers(of: try square("d5"), by: .white) == 1)
    #expect(after.attackers(of: try square("f5"), by: .white) == 1)
    // And e2, which it left, has lost the pawn's own body from the count on e3.
    #expect(after.holder(of: try square("d5")) == .white)
}

@Test("a pinned defender still counts as a defender")
func pinnedDefenderStillDefends() throws {
    // White knight on d2 is pinned by the black rook on d8 against the king on d1. It still
    // covers f3. Taking on f3 is answered by the recapture, and the pin is never cashed —
    // which is why the map counts geometry rather than trying to be clever.
    let control = try #require(Rules.control(startFEN: "3rk3/8/8/8/8/5p2/3N4/3K4 w - - 0 1"))
    #expect(control.attackers(of: try square("f3"), by: .white) == 1)
    // And the pawn standing on f3 does not defend itself, so the square is white's — which
    // is the whole reason a hanging piece is findable from this map at all.
    #expect(control.attackers(of: try square("f3"), by: .black) == 0)
    #expect(control.holder(of: try square("f3")) == .white)
}

@Test("the squares two maps disagree about are what a move changed")
func controlDifferenceNamesWhatChanged() throws {
    let before = try #require(Rules.control(startFEN: start))
    let after = try #require(Rules.control(startFEN: start, moves: ["e2e4"]))
    let changed = after.squaresDiffering(from: before)

    // The pawn's new diagonals changed hands; the centre it walked past did not.
    #expect(changed.contains(try square("d5")))
    #expect(changed.contains(try square("f5")))
    #expect(!changed.contains(try square("a6")))
    // e2 stops being covered by the pawn that left it, but the king and queen still do,
    // so who holds it does not change — a count is not a holder.
    #expect(!changed.contains(try square("e2")))
}

@Test("a control map is refused for a FEN that does not validate")
func controlRefusesRubbish() {
    #expect(Rules.control(startFEN: "not a fen") == nil)
    // Two white kings: the kind of FEN that makes Stockfish's own code undefined.
    #expect(Rules.control(startFEN: "4k3/8/8/8/8/8/8/3KK3 w - - 0 1") == nil)
    #expect(Rules.control(startFEN: start, moves: ["e2e5"]) == nil)
}

// ------------------------------------------------------------ exchange value

@Test("taking a hanging pawn wins material")
func takingAHangingPieceWins() throws {
    let value = Rules.exchangeValue(
        startFEN: "4k3/8/8/3p4/4P3/8/8/4K3 w - - 0 1", uci: "e4d5"
    )
    #expect(value == .winning)
}

@Test("taking a defended pawn with a pawn is level")
func evenTradeIsLevel() throws {
    let value = Rules.exchangeValue(
        startFEN: "4k3/8/2p5/3p4/4P3/8/8/4K3 w - - 0 1", uci: "e4d5"
    )
    #expect(value == .level)
}

@Test("taking a defended pawn with a queen loses material")
func losingCaptureIsLosing() throws {
    let value = Rules.exchangeValue(
        startFEN: "4k3/8/2p5/3p4/8/8/8/3QK3 w - - 0 1", uci: "d1d5"
    )
    #expect(value == .losing)
}

@Test("a quiet move onto a square a pawn covers loses the piece")
func walkingIntoACaptureIsLosing() throws {
    // Nothing is taken by the move itself; the exchange happens to the piece that arrives.
    // This is the answer that makes 躲 and 占 checkable, and the one that catches a giveaway.
    let value = Rules.exchangeValue(
        startFEN: "4k3/8/2p5/8/8/8/8/3QK3 w - - 0 1", uci: "d1d5"
    )
    #expect(value == .losing)
}

@Test("a quiet move nobody can answer is level")
func safeQuietMoveIsLevel() throws {
    let value = Rules.exchangeValue(
        startFEN: "4k3/8/8/8/8/8/8/3QK3 w - - 0 1", uci: "d1d5"
    )
    #expect(value == .level)
}

@Test("castling is level rather than an exchange")
func castlingIsLevel() throws {
    let value = Rules.exchangeValue(
        startFEN: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", uci: "e1g1"
    )
    #expect(value == .level)
}

@Test("an exchange value is refused for a move that is not legal here")
func exchangeRefusesIllegalMoves() {
    #expect(Rules.exchangeValue(startFEN: start, uci: "e2e5") == nil)
    #expect(Rules.exchangeValue(startFEN: start, uci: "nonsense") == nil)
    #expect(Rules.exchangeValue(startFEN: "not a fen", uci: "e2e4") == nil)
}

// ------------------------------------------------------------ the board's two layers

@Test("a hanging piece is one attacked more often than it is defended, either colour's")
func loosePiecesAreFound() throws {
    // A black rook on e5 with nothing behind it, and a white knight on d4 the black rook covers.
    let game = try #require(Game(startFEN: "4k3/8/8/4r3/3N4/8/8/4QK2 w - - 0 1"))
    let loose = try #require(game.loosePieces)

    #expect(loose.contains(try square("e5")), "the rook is looked at by the queen and defended by nobody")
    #expect(!loose.contains(try square("d4")), "the knight is not attacked at all")
    // Kings are never in this list: a king attacked is a check, which the board says in red.
    #expect(!loose.contains(try square("e8")))
    #expect(!loose.contains(try square("f1")))
}

@Test("a defended piece is not loose, and stops being loose when it is defended")
func defendingTakesAPieceOffTheList() throws {
    let hanging = try #require(Game(startFEN: "4k3/8/8/4r3/8/8/8/4QK2 w - - 0 1"))
    #expect(try #require(hanging.loosePieces).contains(try square("e5")))

    // The same rook with a pawn behind it: attacked once, defended once, and not loose.
    let held = try #require(Game(startFEN: "4k3/8/3p4/4r3/8/8/8/4QK2 w - - 0 1"))
    #expect(!(try #require(held.loosePieces)).contains(try square("e5")))
}

@Test("what a move changed is the squares whose holder it changed")
func theLastMoveIsWhatChanged() throws {
    let game = try #require(
        Game(startFEN: "4k3/8/8/8/8/8/8/R3K3 w - - 0 1", uciMoves: ["a1a5"])
    )
    let changed = try #require(game.squaresLastMoveChanged)

    // The rook left the first rank and took the fifth: both are in, and squares it never saw
    // are not.
    #expect(changed.contains(try square("d5")))
    #expect(changed.contains(try square("h5")))
    #expect(changed.contains(try square("c1")))
    #expect(!changed.contains(try square("h8")))
    #expect(!changed.contains(try square("e4")))
    // It is *who holds* a square that has to change, not how many attackers it has: d1 lost the
    // rook and kept the king, so it was White's before and is White's still.
    #expect(!changed.contains(try square("d1")))
}

@Test("a game with no moves has nothing to say about what a move changed")
func nothingChangedInAPositionNobodyMovedIn() throws {
    let fresh = try #require(Game(startFEN: start))
    #expect(fresh.squaresLastMoveChanged == nil, "a refusal, not an empty set")
    #expect(fresh.lastMoveControlChange == nil, "and the same refusal, told apart or not")
    #expect(fresh.loosePieces?.isEmpty == true, "and nothing hangs in the starting position")
}

/// The same squares, told apart by which way they went — because a move's gains and its costs
/// drawn in one colour are a scattering of squares nobody can read.
@Test("what a move changed is split into what it took a grip on and what it let go")
func theLastMoveIsSplitIntoGainsAndCosts() throws {
    let game = try #require(
        Game(startFEN: "4k3/8/8/8/8/8/8/R3K3 w - - 0 1", uciMoves: ["a1a5"])
    )
    let change = try #require(game.lastMoveControlChange)

    #expect(change.mover == .white, "the side not to move now is the side that just moved")
    // The fifth rank is what the rook took.
    #expect(change.gained.contains(try square("d5")))
    #expect(change.gained.contains(try square("h5")))
    #expect(!change.lost.contains(try square("d5")))
    // The first rank is what it let go of, and that is the half the old single set could not say.
    #expect(change.lost.contains(try square("c1")))
    #expect(!change.gained.contains(try square("c1")))
    // Every changed square is in exactly one of the two, and the two together are the old set.
    let changed = try #require(game.squaresLastMoveChanged)
    #expect(change.gained.union(change.lost) == changed)
    #expect(change.gained.isDisjoint(with: change.lost))
    #expect(change.count == changed.count)
    #expect(!change.isEmpty)
}

/// A square let go of in the middle of the board is a matter of taste; one let go of beside your
/// own king is where the attack comes in. So the layer counts those separately.
@Test("squares let go of next to the mover's own king are counted apart")
func lettingGoBesideYourOwnKing() throws {
    // The queen on d8 covers e8 and the squares round the king; walking her out to g5 lets go of
    // them, and the king is still standing there.
    let game = try #require(
        Game(startFEN: "3qk3/8/8/8/8/8/8/4K3 b - - 0 1", uciMoves: ["d8g5"])
    )
    let change = try #require(game.lastMoveControlChange)

    #expect(change.mover == .black)
    #expect(!change.nearKing.isEmpty, "the queen walked away from her own king")
    #expect(
        change.nearKing.isSubset(of: change.lost),
        "it is a subset, so a screen can name it without counting anything twice"
    )
    #expect(change.nearKing.allSatisfy { $0.rank >= 6 }, "and all of it is up beside the king")
    #expect(change.gained.isDisjoint(with: change.nearKing))
}

/// Black's move is read in Black's favour: the same board, the other point of view.
@Test("the split is from the point of view of whoever played the move")
func theSplitFollowsTheMover() throws {
    let game = try #require(
        Game(startFEN: "r3k3/8/8/8/8/8/8/4K3 b - - 0 1", uciMoves: ["a8a4"])
    )
    let change = try #require(game.lastMoveControlChange)

    #expect(change.mover == .black)
    #expect(change.gained.contains(try square("d4")), "the rank the rook took")
    #expect(change.lost.contains(try square("c8")), "the rank it left")
}
