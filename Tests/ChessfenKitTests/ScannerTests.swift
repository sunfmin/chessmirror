import ChessfenKit
import Testing

private func square(_ name: String) throws -> Square {
    try #require(Square(name))
}

private func position(_ fen: String) throws -> Game {
    try #require(Game(startFEN: fen))
}

private func move(_ uci: String, in game: Game) throws -> Move {
    try #require(game.state.move(matching: uci))
}

/// The half of the layer that answers instead of volunteering. Everything else on the board speaks
/// after a Guess is committed; this speaks when somebody points at a square, and about nothing else
/// (docs/adr/0015, 0021).
@Test("pointing at a square lists every piece that can reach it, cheapest first")
func scanningListsTheWaysIn() throws {
    // A black pawn on d5, and three white pieces that can take it.
    let game = try position("4k3/8/8/3p4/4P3/2N5/8/3RK3 w - - 0 1")
    let scan = game.scan(at: try square("d5"))

    #expect(scan.target == (try square("d5")))
    #expect(scan.mover == .white)
    #expect(scan.arrivals.map(\.san) == ["exd5", "Nxd5", "Rxd5"], "pawn, knight, rook")
    #expect(scan.origins == Set([try square("e4"), try square("c3"), try square("d1")]))
}

@Test("a piece that cannot legally go there is not offered, whatever the geometry says")
func aPinnedPieceIsNotAWayIn() throws {
    // The knight on c3 is pinned to the king on a1 by the bishop on d4. It reaches d5 on paper and
    // cannot move at all in fact — a scanner that lit it up would teach the wrong lesson twice.
    let game = try position("4k3/8/8/8/3b4/2N5/8/K7 w - - 0 1")
    #expect(game.state.legalMoves.filter { $0.from == (try! square("c3")) }.isEmpty)
    #expect(game.scan(at: try square("d5")).isEmpty)
}

@Test("a square nothing can reach comes back empty rather than with an excuse")
func nothingReachesIt() throws {
    let game = try position("4k3/8/8/8/8/8/8/4K3 w - - 0 1")
    #expect(game.scan(at: try square("h8")).arrivals.isEmpty)
}

// ------------------------------------------------------------------ what a trial says

@Test("a trial says what the move is for, in the same seven verbs a player declares in", .speaking(.chinese))
func aTrialNamesItsVerb() throws {
    let game = try position("4k3/8/8/3p4/4P3/2N5/8/3RK3 w - - 0 1")
    let played = try move("e4d5", in: game)
    let trial = try #require(game.tryOut(played))

    #expect(trial.san == "exd5")
    #expect(trial.intent == Intent.read(played, in: game), "one reader, not two")
    #expect(trial.intent == .claim(.take, try square("d5")))
    // The verb, and then the board fact that makes it true — the same note the Reveal shows when a
    // player declares the claim themselves.
    #expect(trial.gains.first?.hasPrefix("吃 d5：") == true)
}

@Test("a trial onto a square their pawns can never attack again says so", .speaking(.chinese))
func aTrialOntoAnOutpost() throws {
    // Both pawns that could ever have attacked d5 are already past it, so d5 is a hole: whoever
    // gets there stays.
    let game = try position("4k3/8/8/8/2p1p3/2N5/8/4K3 w - - 0 1")
    let trial = try #require(game.tryOut(try move("c3d5", in: game)))

    #expect(trial.gains.contains("马到 d5 就赶不走了：对方的兵再也攻不到这格。"))
    #expect(!trial.costs.contains { $0.hasPrefix("站不住") }, "and nothing can take it there")
}

@Test("a trial onto a square where the piece can be taken says so, and names the taker", .speaking(.chinese))
func aTrialThatCannotStand() throws {
    let game = try position("4k3/8/4p3/8/8/2N5/8/4K3 w - - 0 1")
    let trial = try #require(game.tryOut(try move("c3d5", in: game)))

    #expect(trial.costs.contains("站不住：兵从 e6 就能吃它，对方 1 个子看着 d5，自己 0 个接应。"))
}

@Test("a trial that can be kicked off by a pawn says that instead", .speaking(.chinese))
func aTrialThatCanBeKickedOff() throws {
    // Nothing attacks d5 yet, but the pawn on c7 can come to c6 and does the job then.
    let game = try position("4k3/2p5/8/8/8/2N5/8/4K3 w - - 0 1")
    let trial = try #require(game.tryOut(try move("c3d5", in: game)))

    #expect(trial.costs.contains("吃不掉，但赶得走：对方的兵推上来就能攻 d5。"))
}

@Test("a trial that takes a guard away from your own king says which square", .speaking(.chinese))
func aTrialThatLoosensTheKing() throws {
    // The knight on f3 is the second thing looking at h2. Send it to the middle and the king is
    // the only one left.
    let game = try position("4k3/8/8/8/8/5N2/6PP/6K1 w - - 0 1")
    let trial = try #require(game.tryOut(try move("f3d4", in: game)))

    #expect(trial.costs.contains("自己王边上的 h2 少了看守。"))
}

@Test("a trial that stops guarding one of your own pieces says which one", .speaking(.chinese))
func aTrialThatAbandonsAGuard() throws {
    // The rook on a1 is the only thing holding the knight on a4, which the rook on h4 is looking
    // at. Step off the file and the knight is nobody's.
    let game = try position("4k3/8/8/8/N6r/8/8/R3K3 w - - 0 1")
    let trial = try #require(game.tryOut(try move("a1d1", in: game)))

    #expect(trial.costs.contains("走了以后 马 a4 没人管了。"))
}

@Test("a move nobody can read still gets tried, and says so where the verb would go", .speaking(.chinese))
func aTrialWithNoReadableVerb() throws {
    let game = try position("4k3/8/8/8/8/8/8/4K3 w - - 0 1")
    let trial = try #require(game.tryOut(try move("e1d1", in: game)))

    #expect(trial.intent == .unclear)
    #expect(trial.gains == ["这步是干什么的，说不清。"])
}

@Test("what a trial says is the same every time it is asked")
func trialsAreDeterministic() throws {
    // Three black pieces looking at d5 and two white ones behind it: every sentence in here has a
    // tie in it, and a dictionary must not be the thing breaking them.
    let game = try position("4k3/2p1p3/8/8/1P6/2N5/3R4/4K3 w - - 0 1")
    let played = try move("c3d5", in: game)
    let answers = (0..<30).map { _ in game.tryOut(played) }
    #expect(Set(answers.map { ($0?.gains ?? []) + ($0?.costs ?? []) }).count == 1)
}

@Test("trying a move out does not play it")
func aTrialIsNotAMove() throws {
    let game = try position("4k3/8/8/3p4/4P3/2N5/8/3RK3 w - - 0 1")
    _ = game.tryOut(try move("e4d5", in: game))
    #expect(game.state.fen == "4k3/8/8/3p4/4P3/2N5/8/3RK3 w - - 0 1")
    #expect(game.plies.isEmpty)
}
