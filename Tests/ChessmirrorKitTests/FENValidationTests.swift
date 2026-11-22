import CStockfish
import ChessmirrorKit
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

// ------------------------------------------------------------- sf_19's own refusals

/// One FEN for each refusal sf_19's `Position::set` can give (position.cpp), and the issue the
/// validator names it by first. sf_19 refusing one through its UCI loop is `info string CRITICAL
/// ERROR` and `exit(1)`, and the engine lives in the app's process (chessmirror#15), so every one
/// of these has to stop at the validator.
let sf19Refusals: [(String, FENIssue)] = [
    // "Invalid number of squares to skip" ("0") and "Invalid piece"
    ("4k3/8/8/8/8/8/8/04K3 w - - 0 1", .badPieceCharacter),
    ("4k3/8/8/8/8/8/8/4K2X w - - 0 1", .badPieceCharacter),
    // "Invalid file reached", and ending a rank before its eighth file
    ("4k3/8/8/8/8/8/8/4K4 w - - 0 1", .badRankWidth),
    ("4k3/7/8/8/8/8/8/4K3 w - - 0 1", .badRankWidth),
    // "Invalid rank reached" and "cursor not at end"
    ("4k3/8/8/8/8/8/8/8/4K3 w - - 0 1", .badRankCount),
    ("4k3/8/8/8/8/8/4K3 w - - 0 1", .badRankCount),
    // "More than 32 pieces on the board": a side with seventeen
    ("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR/ w KQkq - 0 1", .badRankCount),
    ("4k3/8/8/QQQQ4/QQQQQQQQ/PPPPPPPP/8/4K3 w - - 0 1", .tooManyPieces),
    // "Pawns on the first or eighth rank"
    ("4k3/8/8/8/8/8/8/P3K3 w - - 0 1", .pawnOnBackRank),
    // "Incorrect number of kings"
    ("8/8/8/8/8/8/8/4K3 w - - 0 1", .missingKing),
    ("4k3/8/8/8/8/8/8/K3K3 w - - 0 1", .extraKing),
    // "has more than 8 pawns"
    ("4k3/8/8/8/8/PPPPPPPP/P7/4K3 w - - 0 1", .tooManyPawns),
    // "Too many pieces": more promoted pieces than pawns gone — new in sf_19
    ("4k3/8/8/8/8/PPPPPPPP/8/QQ2K3 w - - 0 1", .tooManyPieces),
    ("4k3/pppppppp/8/8/8/8/8/nnn1K3 b - - 0 1", .tooManyPieces),
    // "Unexpected end of stream" and "Invalid side to move"
    ("4k3/8/8/8/8/8/8/4K3", .malformed),
    ("4k3/8/8/8/8/8/8/4K3 w", .malformed),
    ("4k3/8/8/8/8/8/8/4K3 x - - 0 1", .badSideToMove),
    // "Expected whitespace after side to move"
    ("4k3/8/8/8/8/8/8/4K3 wb - - 0 1", .badSideToMove),
    // "Maximum of 4 castling rights" — new in sf_19 — and "Expected castling rights"
    ("r3k2r/8/8/8/8/8/8/R3K2R w KQkqK - 0 1", .badCastling),
    ("r3k2r/8/8/8/8/8/8/R3K2R w KX - 0 1", .badCastling),
    // "Invalid en-passant square"
    ("4k3/8/8/8/8/8/8/4K3 w - e4 0 1", .badEnPassant),
    ("4k3/8/8/8/8/8/8/4K3 w - i6 0 1", .badEnPassant),
    // "Rule50 counter out of range" and "Game ply out of range" — the second new in sf_19
    ("4k3/8/8/8/8/8/8/4K3 w - - -1 1", .badClock),
    ("4k3/8/8/8/8/8/8/4K3 w - - 40000 1", .badClock),
    ("4k3/8/8/8/8/8/8/4K3 w - - 0 100001", .badClock),
    ("4k3/8/8/8/8/8/8/4K3 w - - 0 -3", .badClock),
    // "King can be captured"
    ("4k3/8/8/8/8/8/8/4K2r b - - 0 1", .sideNotToMoveInCheck),
    ("8/8/8/3kK3/8/8/8/8 w - - 0 1", .sideNotToMoveInCheck),
]

@Test("every FEN sf_19 refuses is refused by the validator first", arguments: sf19Refusals)
func sf19RefusalsStopAtTheValidator(fen: String, expected: FENIssue) {
    #expect(cf_stockfish_refuses_fen(fen), "the table is of inputs sf_19 really refuses")
    #expect(Rules.validate(fen: fen).issue == expected)
}

/// sf_19 reads a FEN a character at a time, so a second space between two fields is read as the
/// next field — an en passant square of " ", refused — where a person and the validator see the
/// same position. The bridge hands Stockfish one space per field, so such a FEN is a position.
@Test("a FEN with spaces to spare is a position, handed over with one space per field")
func extraSpacesAreNotARefusal() {
    let spaced = "  4k3/8/8/8/8/8/8/4K3   w  -  -  0  1 "
    #expect(cf_stockfish_refuses_fen(spaced), "sf_19 would refuse it as typed")
    #expect(Rules.validate(fen: spaced).isUsable)
    #expect(Rules.perft(fen: spaced, depth: 1) == 5, "Kd1 Kd2 Ke2 Kf2 Kf1")
}
