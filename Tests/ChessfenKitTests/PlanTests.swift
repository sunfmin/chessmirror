import ChessfenKit
import Testing

private func square(_ name: String) throws -> Square {
    try #require(Square(name))
}

private func position(_ fen: String) throws -> Game {
    try #require(Game(startFEN: fen))
}

/// 五步计划: one Intent over a line of the player's own rather than over its first move. The unbuilt
/// consequence of docs/adr/0017, and the cap is the whole reason it can exist — past about five Ply
/// the opponent has had enough replies that no claim about the position is falsifiable, and an Intent
/// that cannot be told false is not one (docs/adr/0018).
@Test("a plan goes in as a variation whose first ply carries the claim and how far it reaches")
func aPlanIsStoredAsAVariation() throws {
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3"]))
    let stored = game.recordPlan(
        [(uci: "d2d4", san: "d4"), (uci: "e5d4", san: "exd4"), (uci: "d1d4", san: "Qxd4")],
        intent: .claim(.hold, try square("d4")),
        atPly: 2
    )

    #expect(stored)
    let plan = try #require(game.plans(atPly: 2).first)
    #expect(plan.sans == ["d4", "exd4", "Qxd4"])
    #expect(plan.intent == .claim(.hold, try square("d4")))
    #expect(plan.steps == 3)
    // And it is an ordinary Variation, which is what lets the Game and the PGN hold it unchanged.
    #expect(game.variations(atPly: 2).first?.map(\.san) == ["d4", "exd4", "Qxd4"])
    // The claim is on the first Ply and says how far it reaches, so nobody reads it as the reason
    // for that one move.
    #expect(game.variations(atPly: 2).first?.first?.intentSpan == 3)
    #expect(game.variations(atPly: 2).first?[1].intent == nil)
}

@Test("a line longer than five ply is refused rather than trimmed")
func thePlanCapIsEnforced() throws {
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
    // Six plies of a real line, because `recordPlan` takes the moves on trust the way
    // `recordGuess` does — what it enforces is the cap, and the cap is what this is about.
    let played = [
        (uci: "g8f6", san: "Nf6"), (uci: "e4e5", san: "e5"), (uci: "f6d5", san: "Nd5"),
        (uci: "c2c4", san: "c4"), (uci: "d5b6", san: "Nb6"), (uci: "d2d4", san: "d4"),
    ]
    let six = played
    let refused = game.recordPlan(six, intent: .unclear, atPly: 1)
    #expect(!refused)
    #expect(game.variations(atPly: 1).isEmpty, "and nothing is written on the way to refusing")

    let five = Array(played.prefix(5))
    let accepted = game.recordPlan(five, intent: .unclear, atPly: 1)
    #expect(accepted)
    #expect(game.plans(atPly: 1).first?.steps == 5)
}

@Test("a plan survives being written to a file and read back")
func aPlanSurvivesTheRoundTrip() throws {
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3"]))
    game.recordPlan(
        [(uci: "d2d4", san: "d4"), (uci: "e5d4", san: "exd4"), (uci: "d1d4", san: "Qxd4")],
        intent: .claim(.hold, try square("d4")),
        atPly: 2
    )

    let written = PGN(game: game).text
    #expect(written.contains("[%int hold d4]"))
    #expect(written.contains("[%plan 3]"))

    let read = try PGN(parsing: written).game
    let plan = try #require(read.plans(atPly: 2).first)
    #expect(plan.sans == ["d4", "exd4", "Qxd4"])
    #expect(plan.intent == .claim(.hold, try square("d4")))
    #expect(plan.steps == 3)
}

@Test("a one-move intent is still written without a span, so nothing reads as a plan")
func aGuessIsNotAPlan() throws {
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3"]))
    game.recordGuess(uci: "d2d4", san: "d4", intent: .claim(.hold, try square("d4")), atPly: 2)

    let written = PGN(game: game).text
    #expect(written.contains("[%int hold d4]"))
    #expect(!written.contains("[%plan"))
    let read = try PGN(parsing: written).game
    #expect(read.plans(atPly: 2).isEmpty, "one move is a Guess, and a Guess is not a plan")
    #expect(read.variations(atPly: 2).first?.first?.intent == .claim(.hold, try square("d4")))
}

// ------------------------------------------------------------------ and whether it held

@Test("a plan is judged over the whole line, and the step that made it true is named", .speaking(.chinese))
func aPlanIsJudgedOverTheLine() throws {
    // The rook takes the fifth rank on the third ply of the plan, and that is when 占 d5 becomes
    // true — not on the first move, which is what a one-Ply Intent would have been about.
    let game = try position("4k3/8/8/8/8/8/8/R3K3 w - - 0 1")
    let check = try #require(
        Intent.claim(.hold, try square("d5")).check(plan: ["Ra3", "Kd8", "Ra5"], in: game)
    )

    #expect(check.held)
    #expect(check.step == 3)
    #expect(check.san == "Ra5")
    #expect(check.note != nil, "and what the board says, in the terms the claim was made in")
}

@Test("a plan whose claim never comes true is told so, with the state it actually left behind", .speaking(.chinese))
func aPlanThatNeverHeld() throws {
    let game = try position("4k3/8/8/8/8/8/8/R3K3 w - - 0 1")
    let check = try #require(
        Intent.claim(.hold, try square("d5")).check(plan: ["Ra3", "Kd8", "Ra4"], in: game)
    )

    #expect(check.verdict == .failed)
    #expect(check.step == 3, "the last move of the mover's own, because that is where it ended up")
    #expect(check.san == "Ra4")
    #expect(check.note == "d5 还算不上你的：0 对 0")
}

@Test("only the mover's own moves can make their own claim true", .speaking(.chinese))
func theOpponentsMovesDoNotCount() throws {
    // Black walks its rook onto a4 where White's rook is looking at it. That makes 攻 a4 true of
    // the position and it was not White's doing, so the plan does not get to claim it.
    let game = try position("4k3/8/r7/8/8/8/8/R3K3 w - - 0 1")
    let check = try #require(
        Intent.claim(.attack, try square("a4")).check(plan: ["Ra3", "Ra4"], in: game)
    )

    #expect(check.verdict == .failed)
    #expect(check.step == 1)
    #expect(check.san == "Ra3")
}

@Test("说不清 over a plan is no claim, exactly as it is over one move", .speaking(.chinese))
func anUnclearPlanClaimsNothing() throws {
    let game = try position("4k3/8/8/8/8/8/8/R3K3 w - - 0 1")
    let check = try #require(Intent.unclear.check(plan: ["Ra3", "Kd8"], in: game))
    #expect(check.verdict == .noClaim)
    #expect(check.step == nil)
}

@Test("a line that will not replay is refused rather than guessed at")
func anUnplayablePlanIsRefused() throws {
    let game = try position("4k3/8/8/8/8/8/8/R3K3 w - - 0 1")
    let claim = Intent.claim(.hold, try square("d5"))
    #expect(claim.check(plan: [], in: game) == nil)
    #expect(claim.check(plan: ["Qh8"], in: game) == nil)
}

@Test("a draft keeps what you walked apart from what the engine is showing", .speaking(.chinese))
func aDraftTracksItself() throws {
    var draft = PlanDraft(ply: 2)
    #expect(draft.isEmpty)
    #expect(!draft.isFull)

    var walk = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
    for uci in ["d2d4", "e5d4", "d1d4"] {
        let move = try #require(walk.state.move(matching: uci))
        draft.steps.append(PlanDraft.Step(move: move, san: SAN.text(for: move, in: walk.state)))
        _ = walk.apply(move)
    }
    let next = try #require(walk.state.move(matching: "b8c6"))
    draft.ahead = [PlanDraft.Step(move: next, san: SAN.text(for: next, in: walk.state))]

    // What you walked is the plan; the board shows all of it, always.
    #expect(draft.sans == ["d4", "exd4", "Qxd4"])
    #expect(draft.played == ["d4", "exd4", "Qxd4"])
    // What the engine is showing is what the layer reads each square against, and is not the plan.
    #expect(draft.aheadSans == ["Nc6"])
    #expect(draft.remaining == ["Nc6"])

    // The cap is about the claim, not the walk: it is 交卷 that isTooLong closes, and it takes six.
    #expect(!draft.isFull)
    #expect(!draft.isTooLong)
    for uci in ["b8c6", "g1f3", "g8f6"] {
        let move = try #require(walk.state.move(matching: uci))
        draft.steps.append(PlanDraft.Step(move: move, san: SAN.text(for: move, in: walk.state)))
        _ = walk.apply(move)
    }
    #expect(draft.steps.count == 6)
    #expect(draft.isFull)
    #expect(draft.isTooLong)
}

// ------------------------------------------------------- and what each step of it is for

/// The half a handed-over line does not carry. Five moves is a line; five moves each with a reason
/// and a cost is a plan somebody could have thought of themselves (docs/adr/0022).
@Test("every move of a line gets its own verb, its own gain and its own cost", .speaking(.chinese))
func aPlanIsReadStepByStep() throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
    let notes = try #require(game.readPlan(of: ["Bc4", "Nf6", "Nf3", "Nc6", "Ng5"]))

    #expect(notes.map(\.step) == [1, 2, 3, 4, 5])
    #expect(notes.map(\.san) == ["Bc4", "Nf6", "Nf3", "Nc6", "Ng5"])
    // A legal line alternates, so whose move a step is follows from its number — and the rows say
    // so, because "what is coming at me" is half of what a plan has to survive.
    #expect(notes.map(\.isYours) == [true, false, true, false, true])

    // Each one read by the same reader a single hypothesis goes through, in the position it is
    // actually played in: the bishop takes d5, the fifth move is the one that gets to f7.
    #expect(notes[0].intent == .claim(.hold, try square("d5")))
    #expect(notes[2].intent == .claim(.attack, try square("e5")))
    #expect(notes[4].intent == .claim(.attack, try square("f7")))
    #expect(notes[4].gains.first == "攻 f7：f7 上的子挨打了，而且守不住")
    // And what it gives away, which is the half a line of engine moves never mentions.
    #expect(notes[4].costs.contains("自己王边上的 d2 少了看守。"))
}

@Test("the opponent's replies are read from the opponent's seat, which is what makes them threats")
func theRepliesAreReadToo() throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
    let notes = try #require(game.readPlan(of: ["Bc4", "Nf6"]))

    let reply = try #require(notes.last)
    #expect(!reply.isYours)
    #expect(reply.intent == .claim(.attack, try square("e4")), "your pawn, from their side of it")
}

@Test("a line that will not replay is refused rather than read halfway")
func anUnreadablePlanIsRefused() throws {
    let game = try position("4k3/8/8/8/8/8/8/R3K3 w - - 0 1")
    #expect(game.readPlan(of: []) == nil)
    #expect(game.readPlan(of: ["Qh8"]) == nil)
    #expect(game.readPlan(of: ["Ra3", "Qa1"]) == nil, "and one that stops being legal partway")
}

@Test("reading the same line twice says the same thing about every one of its steps")
func aPlanReadingIsDeterministic() throws {
    // Two knights that can each land on a hole and two squares by the king that each lose a guard:
    // every sentence in here has a tie in it.
    let game = try position("4k3/8/8/8/2p1p3/2N1N3/5P1P/6K1 w - - 0 1")
    let answers = (0..<30).map { _ in
        game.readPlan(of: ["Nd5", "Kd7", "Ncd5", "Kc7"])?.map { "\($0.intent)\($0.gains)\($0.costs)" }
    }
    #expect(Set(answers.map { $0?.joined() ?? "" }).count == 1, "thirty readings, one set of rows")
}
