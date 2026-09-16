import ChessfenKit
import Testing

@Test("a draft round trips the FEN it was read from")
func draftRoundTrips() throws {
    for fen in [
        PGN.standardStartFEN,
        "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 4 3",
        "8/8/8/4k3/8/8/4K3/8 b - - 12 40",
        "rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3",
    ] {
        let draft = try #require(PositionDraft(fen: fen))
        #expect(draft.fen == fen)
        #expect(draft.isPlayable)
    }
}

@Test("a draft is editable while it is illegal, and says so")
func anIllegalDraftIsStillADraft() throws {
    var draft = try #require(PositionDraft(fen: PGN.standardStartFEN))
    // Lift both kings: no legal position, but an editable one — this is precisely the
    // state a player passes through while fixing a misread board.
    draft.setPiece(nil, at: try #require(Square("e1")))
    draft.setPiece(nil, at: try #require(Square("e8")))
    #expect(!draft.isPlayable)
    #expect(draft.verdict.issue == .missingKing)
    #expect(draft.game == nil)

    draft.setPiece(Piece(colour: .white, kind: .king), at: try #require(Square("e1")))
    draft.setPiece(Piece(colour: .black, kind: .king), at: try #require(Square("e8")))
    #expect(draft.isPlayable)
}

@Test("a misread board reads as a draft even though it is refused as a game")
func anIllegalFENReadsAsADraftButNotAGame() throws {
    // What a misread king looks like coming back from Recognition: a bishop standing where
    // White's king is. Sixty-three squares are right and the position is still illegal — which
    // is the case Recognition has to hand to the editor, not throw away as "no board in this
    // picture" (docs/adr/0011). The routing rests on these two lines disagreeing, so they are
    // pinned here: the draft opens, the Game does not.
    let misread = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQBBNR w KQkq - 0 1"
    let draft = try #require(
        PositionDraft(fen: misread), "the editor has to be able to open a misread board"
    )
    #expect(draft.verdict.issue == .missingKing)
    #expect(Game(startFEN: misread) == nil, "an illegal position must never reach the engine")

    // And it is one tap from playable, which is why the editor is the right place to land.
    var fixed = draft
    fixed.setPiece(Piece(colour: .white, kind: .king), at: try #require(Square("e1")))
    #expect(fixed.game != nil)
}

@Test("lifting a king takes its castling rights with it")
func castlingFollowsTheKing() throws {
    var draft = try #require(PositionDraft(fen: PGN.standardStartFEN))
    #expect(draft.castling == ["K", "Q", "k", "q"])

    draft.setPiece(nil, at: try #require(Square("e1")))
    #expect(draft.castling == ["k", "q"], "White cannot castle without a king on e1")

    // And putting it back does not silently hand the rights back: they were removed
    // because the placement stopped supporting them, and granting is a separate act.
    draft.setPiece(Piece(colour: .white, kind: .king), at: try #require(Square("e1")))
    #expect(draft.castling == ["k", "q"])
    draft.grantCastlingFromHomeSquares()
    #expect(draft.castling == ["K", "Q", "k", "q"])
}

@Test("a rook leaving a corner takes only its own right")
func castlingFollowsEachRook() throws {
    var draft = try #require(PositionDraft(fen: PGN.standardStartFEN))
    draft.setPiece(nil, at: try #require(Square("h1")))
    #expect(draft.castling == ["Q", "k", "q"])
    #expect(draft.possibleCastling == ["Q", "k", "q"])
    #expect(draft.isPlayable)
}

@Test("en passant is offered only where a pawn could have just stepped through")
func enPassantSquaresAreThePossibleOnes() throws {
    // Black has just played d7-d5, so d6 is the only candidate for White to move.
    let afterDoubleStep = try #require(
        PositionDraft(fen: "rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq - 0 3")
    )
    #expect(afterDoubleStep.possibleEnPassantSquares.map(\.description) == ["d6"])

    // The start position has nobody who has stepped anywhere.
    let start = try #require(PositionDraft(fen: PGN.standardStartFEN))
    #expect(start.possibleEnPassantSquares.isEmpty)
}

@Test("an en passant square that stops making sense is dropped")
func impossibleEnPassantIsDropped() throws {
    var draft = try #require(
        PositionDraft(fen: "rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3")
    )
    #expect(draft.enPassant?.description == "d6")

    // Take away the pawn that did the stepping and the claim is unsupportable.
    draft.setPiece(nil, at: try #require(Square("d5")))
    #expect(draft.enPassant == nil)
    #expect(draft.isPlayable)
}

@Test("only the placement field is required to read a draft")
func aBarePlacementIsEnough() throws {
    let draft = try #require(PositionDraft(fen: "4k3/8/8/8/8/8/8/4K3"))
    #expect(draft.sideToMove == .white)
    #expect(draft.castling.isEmpty)
    #expect(draft.fen == "4k3/8/8/8/8/8/8/4K3 w - - 0 1")
    #expect(draft.isPlayable)
}

@Test("nonsense is refused rather than half read")
func nonsenseIsRefused() {
    #expect(PositionDraft(fen: "") == nil)
    #expect(PositionDraft(fen: "not a fen at all") == nil)
}

@Test("a move is graded from the point of view of whoever played it")
func moveQualityIsRelativeToTheMover() {
    // Level, then two and a half pawns down: 23 points of win probability, a mistake.
    #expect(
        MoveQuality.of(move: .white, before: .centipawns(20), after: .centipawns(-250))
            == .mistake
    )
    // The same drop is Black's *gain*, so it is not Black's mistake.
    #expect(
        MoveQuality.of(move: .black, before: .centipawns(20), after: .centipawns(-250))
            == .fine
    )
    #expect(
        MoveQuality.of(move: .black, before: .centipawns(-250), after: .centipawns(20))
            == .mistake
    )
    #expect(
        MoveQuality.of(move: .white, before: .centipawns(0), after: .centipawns(-500))
            == .blunder
    )
    // 10% works out to about 109 centipawns near equality, which is where the familiar
    // "a pawn from level is an inaccuracy" lands (docs/adr/0027).
    #expect(
        MoveQuality.of(move: .white, before: .centipawns(0), after: .centipawns(-120))
            == .inaccuracy
    )
    #expect(
        MoveQuality.of(move: .white, before: .centipawns(0), after: .centipawns(-70)) == .fine,
        "and under it is nothing at all"
    )
    #expect(MoveQuality.of(move: .white, before: nil, after: .centipawns(0)) == nil)
}

@Test("the same centipawns cost different amounts depending on the position")
func centipawnsAreWorthDifferentAmountsInDifferentPositions() {
    // Three pawns given away from a won game barely changes who wins, and this is the whole
    // reason the scale changed: the old bands called it a blunder (docs/adr/0027).
    #expect(
        MoveQuality.of(move: .white, before: .centipawns(800), after: .centipawns(500)) == .fine
    )
    #expect(
        MoveQuality.of(move: .white, before: .centipawns(600), after: .centipawns(300))
            == .inaccuracy,
        "the same 300 centipawns, closer to level, has started to matter"
    )
    // And the same three pawns from a level position decides the game.
    #expect(
        MoveQuality.of(move: .white, before: .centipawns(0), after: .centipawns(-300))
            == .mistake
    )
}

@Test("walking into a mate is a blunder, and mating is not")
func mateScoresAreGradedFinitely() {
    #expect(
        MoveQuality.of(move: .white, before: .centipawns(50), after: .mate(in: -2)) == .blunder
    )
    #expect(
        MoveQuality.of(move: .white, before: .centipawns(50), after: .mate(in: 2)) == .fine
    )
    // Mate in three instead of mate in two is not a move worth a name: it is still mate, and
    // who wins has not changed by one point.
    #expect(
        MoveQuality.of(move: .white, before: .mate(in: 2), after: .mate(in: 3)) == .fine
    )
}
