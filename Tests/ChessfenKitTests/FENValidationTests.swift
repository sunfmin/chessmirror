import ChessfenKit
import Testing

@Test("a normal position is usable")
func startingPositionIsUsable() {
    let verdict = Rules.validate(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
    #expect(verdict.isUsable)
}

@Test("a position with no king is refused")
func missingKingIsRefused() {
    let verdict = Rules.validate(fen: "8/8/8/8/8/8/8/8 w - - 0 1")
    #expect(verdict.issue == .missingKing)
    #expect(verdict.colour == .white)
}

@Test("two kings of one colour are refused, and both are pointed at")
func extraKingIsRefused() {
    let verdict = Rules.validate(fen: "4k3/8/8/8/8/8/8/K3K3 w - - 0 1")
    #expect(verdict.issue == .extraKing)
    #expect(verdict.colour == .white)
    #expect(Set(verdict.squares.map(\.description)) == ["a1", "e1"])
}

@Test("a pawn on the back rank is refused and located")
func pawnOnBackRankIsRefused() {
    let verdict = Rules.validate(fen: "4k3/8/8/8/8/8/8/P3K3 w - - 0 1")
    #expect(verdict.issue == .pawnOnBackRank)
    #expect(verdict.squares.map(\.description) == ["a1"])
}

/// The one that would otherwise read off the end of the board inside Stockfish's own
/// castling parser, which scans the home rank for a rook in a loop with no lower bound.
@Test("a castling right with no rook to support it is refused")
func castlingWithoutRookIsRefused() {
    let verdict = Rules.validate(fen: "4k3/8/8/8/8/8/8/4K3 w KQkq - 0 1")
    #expect(verdict.issue == .castlingWithoutRook)
}

@Test("a castling right with the king off its home square is refused")
func castlingWithoutKingAtHomeIsRefused() {
    let verdict = Rules.validate(fen: "4k2r/8/8/8/8/8/8/R2K4 w Qk - 0 1")
    #expect(verdict.issue == .castlingWithoutKing)
    #expect(verdict.colour == .white)
    #expect(verdict.squares.map(\.description) == ["d1"])
}

@Test("the side not to move may not already be in check")
func sideNotToMoveInCheckIsRefused() {
    let verdict = Rules.validate(fen: "4k3/8/8/8/8/8/8/4K2r b - - 0 1")
    #expect(verdict.issue == .sideNotToMoveInCheck)
    #expect(verdict.colour == .white)
    #expect(verdict.squares.map(\.description) == ["e1"])
}

@Test("adjacent kings fall out of the same rule")
func adjacentKingsAreRefused() {
    let verdict = Rules.validate(fen: "8/8/8/3kK3/8/8/8/8 w - - 0 1")
    #expect(verdict.issue == .sideNotToMoveInCheck)
    #expect(verdict.colour == .black)
}

@Test("nine pawns are refused")
func tooManyPawnsIsRefused() {
    let verdict = Rules.validate(fen: "4k3/8/8/8/8/PPPPPPPP/P7/4K3 w - - 0 1")
    #expect(verdict.issue == .tooManyPawns)
    #expect(verdict.colour == .white)
}

@Test(
    "structurally broken placement fields are refused",
    arguments: [
        ("4k3/8/8/8/8/8/8/4K4 w - - 0 1", FENIssue.badRankWidth),
        ("4k3/8/8/8/8/8/4K3 w - - 0 1", FENIssue.badRankCount),
        ("4k3/8/8/8/8/8/8/4K2X w - - 0 1", FENIssue.badPieceCharacter),
        ("4k3/8/8/8/8/8/8/4K3", FENIssue.malformed),
        ("4k3/8/8/8/8/8/8/4K3 x - - 0 1", FENIssue.badSideToMove),
        ("4k3/8/8/8/8/8/8/4K3 w - e4 0 1", FENIssue.badEnPassant),
        ("4k3/8/8/8/8/8/8/4K3 w - - 200 1", FENIssue.badClock),
    ]
)
func brokenFensAreRefused(fen: String, expected: FENIssue) {
    #expect(Rules.validate(fen: fen).issue == expected)
}

@Test("an en passant square on the rank the mover could capture into is accepted")
func plausibleEnPassantIsAccepted() {
    #expect(Rules.validate(fen: "4k3/8/8/8/4p3/8/8/4K3 w - e3 0 1").isUsable == false)
    #expect(Rules.validate(fen: "4k3/8/8/4p3/8/8/8/4K3 w - e6 0 1").isUsable)
}
