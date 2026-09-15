import ChessfenKit
import Testing

private func position(_ fen: String) throws -> Game {
    try #require(Game(startFEN: fen))
}

/// 走马灯: the Line played out on the board, and one sentence saying where it arrived. Without that
/// sentence a carousel is reciting moves — the position is different afterwards and the difference
/// is exactly what a beginner cannot see (docs/adr/0021).
@Test("a line that wins a piece says which piece, from either side's count")
func theOutcomeCountsWhatWasTaken() throws {
    // White takes the knight on d5 with a pawn; Black takes the pawn back with the king.
    let game = try position("8/8/2k5/3n4/4P3/8/8/4K3 w - - 0 1")
    let outcome = try #require(game.outcome(of: ["exd5", "Kxd5"]))

    #expect(outcome.steps == 2)
    #expect(outcome.clauses.first == "你吃了对方 1 个马，自己丢了 1 个兵")
}

@Test("a line that takes without losing says so on both halves of the clause")
func theOutcomeSaysWhenNothingWasGivenBack() throws {
    let game = try position("4k3/8/8/3n4/4P3/8/8/4K3 w - - 0 1")
    let outcome = try #require(game.outcome(of: ["exd5"]))
    #expect(outcome.clauses.contains("你吃了对方 1 个马，自己一个子没丢"))
}

@Test("a line that plants a piece where their pawns can never reach it names the square")
func theOutcomeNamesAnOutpost() throws {
    // Both pawns that could ever have attacked d5 are already past it, so the knight that walks
    // there is a knight nobody throws off.
    let game = try position("4k3/8/8/8/2p1p3/2N5/8/4K3 w - - 0 1")
    let outcome = try #require(game.outcome(of: ["Nd5", "Kd7"]))

    // And the knight came from c3, where it was the second thing looking at both d1 and e2 — so
    // the same two moves that plant it also cost the king two guards, and the sentence says both.
    #expect(outcome.clauses.contains("d5 里坐着一个赶不走的马"))
    #expect(outcome.sentence == "2 步之后，d5 里坐着一个赶不走的马，你的王边少了 2 个守卫。")
}

@Test("a line that walks a guard away from your own king counts the guards")
func theOutcomeCountsTheKingsGuards() throws {
    // The knight on f3 is the second thing looking at h2, and the rook on f2 is looking at f1 and
    // g2. Send both to the other side of the board and the king is on its own.
    let game = try position("4k3/8/8/8/8/5N2/5R1P/6K1 w - - 0 1")
    let outcome = try #require(game.outcome(of: ["Nd4", "Kd8", "Ra2", "Kc8"]))

    #expect(outcome.clauses.contains { $0.hasPrefix("你的王边少了") })
}

@Test("a line that changes nothing worth naming says that instead of inventing a clause")
func theOutcomeAdmitsNothingHappened() throws {
    let game = try position("4k3/8/8/8/8/8/8/4K3 w - - 0 1")
    let outcome = try #require(game.outcome(of: ["Kd1", "Kd8"]))

    #expect(outcome.clauses.isEmpty)
    #expect(outcome.sentence == "2 步之后，位置没什么实质变化。")
}

@Test("an empty line, and one that will not replay, are refused")
func anUnplayableLineHasNoOutcome() throws {
    let game = try position("4k3/8/8/8/8/8/8/4K3 w - - 0 1")
    #expect(game.outcome(of: []) == nil)
    #expect(game.outcome(of: ["Qh8"]) == nil)
    #expect(game.outcome(of: ["Kd1", "Qa1"]) == nil, "and one that stops being legal partway")
}

@Test("the sentence is the same every time the same line is walked")
func theOutcomeIsDeterministic() throws {
    // Two knights that both land on holes and two squares beside the king that both lose a guard:
    // every clause in here has a tie in it.
    let game = try position("4k3/8/8/8/2p1p3/2N1N3/5P1P/6K1 w - - 0 1")
    let answers = (0..<30).map { _ in game.outcome(of: ["Nd5", "Kd7", "Ncd5", "Kc7"])?.sentence }
    #expect(Set(answers).count == 1, "thirty walks, one sentence")
}

@Test("a walk knows where it is, what it has played, and what it still expects")
func aWalkTracksItself() throws {
    let line = ["Nd5", "Kd7", "Nf6"]
    let game = try position("4k3/8/8/8/2p1p3/2N5/8/4K3 w - - 0 1")
    var walk = Walk(line: line, step: 0, outcome: try #require(game.outcome(of: line)))

    #expect(walk.isAtStart)
    #expect(walk.played.isEmpty)
    #expect(walk.remaining == line, "at the start the whole line is still ahead")

    walk.step = 2
    #expect(walk.played == ["Nd5", "Kd7"])
    #expect(walk.remaining == ["Nf6"])
    #expect(!walk.isAtEnd)

    walk.step = 3
    #expect(walk.isAtEnd)
    #expect(walk.remaining.isEmpty)
}
