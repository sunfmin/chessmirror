import ChessmirrorKit
import Testing

/// The one scale everything is judged on, and the three lines drawn on it (docs/adr/0027).

private func played(_ ucis: [String]) throws -> Game {
    try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ucis))
}

// ------------------------------------------------------------------- the curve

@Test("the curve is lichess's, and it reads level as level")
func theCurveIsTheOneLichessJudgesBy() {
    #expect(Score.centipawns(0).winPercent == 50)
    // 2 / (1 + exp(-0.00368208 × cp)) - 1 is lichess's own `rawWinningChances`; as a
    // probability that is the sigmoid, so a few points of it can be checked by hand.
    #expect(abs(Score.centipawns(100).winPercent - 59.10) < 0.05)
    #expect(abs(Score.centipawns(-100).winPercent - 40.90) < 0.05)
    #expect(abs(Score.centipawns(500).winPercent - 86.32) < 0.05)
    // Symmetric about level, which is what makes a drop mean the same thing to either side.
    for cp in [37, 109, 250, 900] {
        let up = Score.centipawns(cp).winPercent
        let down = Score.centipawns(-cp).winPercent
        #expect(abs((up + down) - 100) < 0.000_1, "\(cp)")
    }
}

@Test("a mate is who wins, not a very large number of pawns")
func mateIsOneOrZero() {
    #expect(Score.mate(in: 3).winPercent == 100)
    #expect(Score.mate(in: 12).winPercent == 100)
    #expect(Score.mate(in: -1).winPercent == 0)
}

@Test("ten percent is about a pawn from level, which is where the old bands were right")
func tenPercentIsAboutAPawn() {
    let level = Score.centipawns(0).winPercent
    #expect(level - Score.centipawns(-109).winPercent < 10)
    #expect(level - Score.centipawns(-112).winPercent > 10)
}

// ------------------------------------------------------------------- the lines

@Test("the two standing lines default to ten and ten, with 正着 off")
func theLinesHaveDefaults() {
    let lines = JudgementLines.standard
    #expect(lines.intercept == nil, "正着 is a thing you switch on, not a thing you are in")
    #expect(lines.record == 10, "a slip under ten is not a 错题 for the book")
    #expect(lines.enqueue == 10, "and what is written down is worth the practice time")

    #expect(!Ruling.intercepts(50, lines: lines), "nothing is intercepted while it is off")
    #expect(lines.records(10))
    #expect(!lines.records(9.9))
    #expect(lines.enqueues(10))
    #expect(!lines.enqueues(9.9))
    #expect(!lines.records(nil), "an unreviewed move is not a move with nothing wrong with it")

    // They are still two lines: a player who wants a wide book and a narrow queue moves one.
    let wide = JudgementLines(record: 5, enqueue: 20)
    #expect(wide.records(9.9))
    #expect(!wide.enqueues(9.9), "worth writing down, not worth practice time")
}

@Test("each line moves on its own")
func theLinesAreSeparate() {
    var lines = JudgementLines(intercept: 30, record: 5, enqueue: 25)
    #expect(Ruling.intercepts(30, lines: lines))
    #expect(!Ruling.intercepts(29, lines: lines))
    #expect(lines.records(5), "a lower record line writes down more, and intercepts no more")
    #expect(!lines.enqueues(24))

    lines.intercept = nil
    #expect(!Ruling.intercepts(99, lines: lines), "and switching 把关 off changes neither of the others")
    #expect(lines.records(5))
    #expect(lines.enqueues(25))
}

@Test("the intercept slider defaults to five and supports the full percentage range")
func theInterceptDialIsContinuous() {
    #expect(JudgementLines.defaultIntercept == 5)
    #expect(JudgementLines.interceptRange == 0...100)
    #expect(!Ruling.intercepts(0, lines: JudgementLines(intercept: 0)))
    #expect(Ruling.intercepts(0.1, lines: JudgementLines(intercept: 0)))
    #expect(Ruling.intercepts(5, lines: JudgementLines(intercept: 5)))
}

// -------------------------------------------------------------- the settlement

@Test("a gift taken whole is one sentence, and a gift partly given back is three numbers")
func aSettlementAddsUp() throws {
    var game = try played(["e2e4", "e7e5", "g1f3"])
    // Black's move throws a lot away; White's reply takes most of it, and leaves a little.
    game.applyReview(
        [.centipawns(20), .centipawns(400), .centipawns(280)],
        startEvaluation: .centipawns(20),
        depth: 16
    )
    let settled = try #require(game.settlement(atPly: 3), "White's reply is the one that settles")
    #expect(abs(settled.gift - 29.5) < 0.2)
    #expect(abs(settled.kept - 21.9) < 0.2)
    #expect(abs(settled.missed - 7.6) < 0.2)
    #expect(abs((settled.kept + settled.missed) - settled.gift) < 0.000_1, "it has to add up")
    #expect(settled.isClean, "under ten points back is noise, not a lesson")
    #expect(settled.sentence.contains("30"))
}

@Test("a gift handed most of the way back is said as three numbers")
func aMissedGiftNamesWhatWentBack() throws {
    var game = try played(["e2e4", "e7e5", "g1f3"])
    game.applyReview(
        [.centipawns(0), .centipawns(400), .centipawns(60)],
        startEvaluation: .centipawns(0),
        depth: 16
    )
    let settled = try #require(game.settlement(atPly: 3))
    #expect(!settled.isClean)
    let sentence = settled.sentence
    #expect(sentence.contains("31"), "the gift")
    #expect(sentence.contains("6"), "and what was kept of it")
    #expect(sentence.contains("26"), "and what went back")
}

@Test("nothing is settled when the opponent gave nothing away")
func noGiftNoSentence() throws {
    var game = try played(["e2e4", "e7e5", "g1f3"])
    game.applyReview(
        [.centipawns(20), .centipawns(15), .centipawns(25)],
        startEvaluation: .centipawns(20),
        depth: 16
    )
    #expect(game.settlement(atPly: 3) == nil)
}

@Test("a settlement is never available before the reply that settles it")
func aSettlementWaitsForTheReply() throws {
    var game = try played(["e2e4", "e7e5", "g1f3"])
    game.applyReview(
        [.centipawns(0), .centipawns(400), .centipawns(390)],
        startEvaluation: .centipawns(0),
        depth: 16
    )
    // Standing on Black's blunder — the moment "there is something here" would be a hint.
    #expect(game.settlement(atPly: 2) == nil, "the gift is not named while it is still on offer")
    #expect(game.settlement(atPly: 1) == nil)
    #expect(game.settlement(atPly: 0) == nil)
    // And once White has replied it can be said.
    #expect(game.settlement(atPly: 3) != nil)
}

@Test("evaluations nobody stated a depth for judge nothing at all")
func mixedProvenanceRefusesToJudge() throws {
    // A lichess export: every move carries an `[%eval]`, and nothing says what depth any of
    // them came from. They land in the imported slot and `reviewScore` refuses them
    // (docs/adr/0016) — so a scale sensitive enough to draw three lines on never sees a pair
    // of numbers from two different searches.
    let read = try PGN(parsing: """
        [Event "Rated Blitz game"]
        [White "sunfmin"]

        1. e4 {[%eval 0.00]} e5 {[%eval 4.00]} 2. Nf3 {[%eval 3.90]} *
        """)
    let game = read.game
    #expect(game.plies.count == 3)
    #expect(!game.isReviewed, "no ReviewDepth, no Review")
    #expect(game.reviewScore(atPly: 2) == nil)
    #expect(game.settlement(atPly: 3) == nil, "and so nothing to settle, however big the gift")
    #expect(game.drop(atPly: 2) == nil)
    #expect(game.quality(atPly: 2) == nil)

    // The same game, scored at one depth, does have all three.
    var scored = game
    scored.applyReview(
        [.centipawns(0), .centipawns(400), .centipawns(390)],
        startEvaluation: .centipawns(0),
        depth: 16
    )
    #expect(scored.settlement(atPly: 3) != nil)
}

@Test("a drop is what the mover gave away, and a gain reads as a gain")
func dropIsFromTheMoversSide() throws {
    var game = try played(["e2e4", "e7e5"])
    game.applyReview(
        [.centipawns(0), .centipawns(-300)], startEvaluation: .centipawns(0), depth: 16
    )
    #expect(game.drop(atPly: 1) == 0, "White's first move changed nothing")
    let blacks = try #require(game.drop(atPly: 2))
    #expect(blacks < -20, "Black's move gained: a negative drop, not a clamped zero")
}
