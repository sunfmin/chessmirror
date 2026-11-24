import ChessmirrorKit
import Testing

/// A drawn game names the rule that drew it where the turn would be (`Game.turn`), so each draw
/// has to say its own rule.
@Test(
    "a drawn game says which rule drew it",
    arguments: [
        ("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1", [String](), "Stalemate"),
        ("8/8/8/4k3/8/8/8/4K1R1 w - - 100 60", [], "Draw by the fifty-move rule"),
        ("8/8/8/4k3/8/8/8/4K3 w - - 0 1", [], "Draw — not enough material"),
        (
            PGN.standardStartFEN,
            ["g1f3", "g8f6", "f3g1", "f6g8", "g1f3", "g8f6", "f3g1", "f6g8"],
            "Draw by threefold repetition"
        ),
    ]
)
func aDrawSaysItsRule(fen: String, moves: [String], said: String) throws {
    let game = try #require(Game(startFEN: fen, uciMoves: moves))
    Speech.speaking(.english) {
        #expect(game.state.outcome.isDraw)
        #expect(game.turn == said)
        #expect(game.state.outcome.label == said)
    }
}

@Test("a game in play and a mated game are said as such")
func playAndMateAreSaid() {
    Speech.speaking(.english) {
        #expect(Outcome.ongoing.label == "In progress")
        #expect(Outcome.checkmate.label == "Checkmate")
    }
    Speech.speaking(.chinese) {
        #expect(Outcome.ongoing.label != "In progress", "said in the language the app speaks")
    }
}

/// The confirm-position screen shows the refusal's label under the board, so each refusal has to
/// name its own fix: two that read the same would send the player to the wrong square.
@Test("every refusal of a position names its own fix")
func everyRefusalNamesItsOwnFix() {
    let issues: [FENIssue] = [
        .malformed, .badPieceCharacter, .badRankWidth, .badRankCount, .tooManyPieces,
        .tooManyPawns, .missingKing, .extraKing, .pawnOnBackRank, .badSideToMove, .badCastling,
        .castlingWithoutRook, .castlingWithoutKing, .badEnPassant, .badClock,
        .sideNotToMoveInCheck,
    ]
    Speech.speaking(.english) {
        let said = issues.map(\.label)
        #expect(Set(said).count == issues.count, "two refusals read the same: \(said)")
        #expect(said.allSatisfy { !$0.hasPrefix("fen.") }, "a refusal fell back to its key: \(said)")
        #expect(FENIssue.missingKing.label == "A king is missing — each side needs one")
        #expect(FENIssue.badClock.label == "The move count is wrong")
        #expect(
            Rules.validate(fen: "4k3/8/8/8/8/8/8/P3K3 w - - 0 1").issue?.label
                == "A pawn cannot stand on the first or the eighth rank"
        )
    }
}
