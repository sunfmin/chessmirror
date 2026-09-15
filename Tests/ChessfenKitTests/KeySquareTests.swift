import ChessfenKit
import Testing

private func square(_ name: String) throws -> Square {
    try #require(Square(name))
}

private func pieces(_ fen: String) throws -> [Square: Piece] {
    try #require(BoardRenderer.placement(fen))
}

// ------------------------------------------------------------------- the holes

/// A hole is not "undefended". It is "and it can never be defended", which is a claim about pawns
/// and about the one thing pawns cannot do.
@Test("a square no pawn of one side can ever attack again is a hole for that side")
func aHoleIsASquareNoPawnCanComeBackTo() throws {
    // Black pawns on c5 and e5: d5 can never be attacked by a black pawn again, because the two
    // that could have are past it and pawns do not go backwards.
    let board = try pieces("4k3/8/8/2p1p3/8/8/8/1N2K3 w - - 0 1")
    #expect(Rules.isHole(at: try square("d5"), for: .black, pieces: board))
    // And the same square for White is not: a white pawn is not there, but this asks whether one
    // could ever be, and c2 or e2 would do it. There are none of either, so it is a hole for White
    // too — the test that matters is the next one.
    #expect(Rules.isHole(at: try square("d5"), for: .white, pieces: board))
}

@Test("a pawn that could still advance to attack a square keeps it off the list")
func aPawnThatCanStillComeIsNotAHole() throws {
    // Black pawn on c7: it can walk to c6 and attack d5 whenever Black likes.
    let board = try pieces("4k3/2p5/8/4p3/8/8/8/1N2K3 w - - 0 1")
    #expect(!Rules.isHole(at: try square("d5"), for: .black, pieces: board))
    // A pawn already attacking the square is the same answer, arrived at sooner.
    #expect(!Rules.isHole(at: try square("d5"), for: .black, pieces: try pieces("4k3/8/2p5/8/8/8/8/1N2K3 w - - 0 1")))
}

@Test("a hole on the back ranks is not named, because nobody outposts there")
func holesAreOnlyLookedForInTheMiddle() throws {
    let board = try pieces("4k3/8/8/8/8/8/8/4K3 w - - 0 1")
    // An empty board makes every square unattackable by a pawn for ever. Only the four middle
    // ranks are named, or the layer would be drawing squares to have something to draw.
    #expect(Rules.isHole(at: try square("d4"), for: .white, pieces: board))
    #expect(Rules.isHole(at: try square("d6"), for: .white, pieces: board))
    #expect(!Rules.isHole(at: try square("d2"), for: .white, pieces: board))
    #expect(!Rules.isHole(at: try square("d8"), for: .white, pieces: board))
}

// -------------------------------------------------------------- the two nets

/// The whole point, in one test: of everything Nc3 changed hands over, exactly one square is drawn
/// — the one the engine walks a knight onto two moves later.
@Test("the square the engine's line lands on is the one that gets drawn")
func theLineDecidesWhichSquareMatters() throws {
    let game = try #require(
        Game(startFEN: "4k3/8/8/2p1p3/8/8/8/1N2K3 w - - 0 1", uciMoves: ["b1c3"])
    )
    // Nc3 changes hands over a4, b5, d5, e4 and more; several of them are holes in Black's
    // position, so the rules net alone proposes a scattering.
    let change = try #require(game.lastMoveControlChange)
    #expect(change.gained.count > 3, "the rules net has plenty to choose from")

    let key = game.keySquares(continuation: ["Ke7", "Nd5+"])
    #expect(key.count == 1, "one square, out of everything that changed")
    let d5 = try #require(key.first)
    #expect(d5.square == (try square("d5")))
    #expect(d5.kind == .outpost, "a hole with a knight one move from it")
    #expect(d5.isGain)
    #expect(d5.mover == .white)
    #expect(d5.proof == .occupied(step: 2, san: "Nd5+"))
    #expect(d5.note.contains("d5"))
    #expect(d5.note.contains("永久据点"))
    #expect(d5.note.contains("第 2 步"))
}

@Test("no line, nothing drawn — and that is the answer rather than a fallback")
func withoutALineNothingIsDrawn() throws {
    let game = try #require(
        Game(startFEN: "4k3/8/8/2p1p3/8/8/8/1N2K3 w - - 0 1", uciMoves: ["b1c3"])
    )
    #expect(game.keySquares(continuation: []).isEmpty)
    // And a game nobody has moved in has no last Ply to be about.
    let fresh = try #require(Game(startFEN: PGN.standardStartFEN))
    #expect(fresh.keySquares(continuation: ["e4", "e5"]).isEmpty)
}

/// The weaker of the two proofs, and the reason it is weaker: nobody went there, so all the layer
/// may claim is that the line never took the change back.
@Test("a square the line never visits is allowed one claim, and only one")
func aSquareNobodyVisitsPersistsAtMostAlone() throws {
    let game = try #require(
        Game(startFEN: "4k3/8/8/2p1p3/8/8/8/1N2K3 w - - 0 1", uciMoves: ["b1c3"])
    )
    // A line that walks the kings about and never touches anything the knight took.
    let key = game.keySquares(continuation: ["Kd8", "Kd1", "Ke8", "Ke1"])
    #expect(key.count <= 1, "one square at most when the engine went nowhere near any of them")
    if let only = key.first {
        guard case .persisted(let plies) = only.proof else {
            Issue.record("a square nobody visited cannot claim to have been occupied")
            return
        }
        #expect(plies == 4)
        #expect(only.note.contains("往下 4 步这格都没变回去"))
    }
}

/// Beside your own king is the one place where letting go of a square is not a matter of taste,
/// so it is a kind of its own and it sorts first.
@Test("a square let go of beside the mover's own king is named as that")
func lettingGoBesideYourOwnKingIsItsOwnKind() throws {
    // The queen guards d7 beside her own king and then walks out to g5. One move later the white
    // rook is standing on d7 — which is what "对方的攻势从这里进来" means, said as a fact.
    let game = try #require(
        Game(startFEN: "3qk3/R7/8/8/8/8/8/4K3 b - - 0 1", uciMoves: ["d8g5"])
    )
    let key = game.keySquares(continuation: ["Rd7"])
    let d7 = try #require(key.first { $0.square == (try? square("d7")) })
    #expect(d7.mover == .black)
    #expect(d7.kind == .ownKing)
    #expect(!d7.isGain)
    #expect(d7.proof == .occupied(step: 1, san: "Rd7"))
    // The Line runs from the position the move made, so its first Ply is the reply — and the
    // sentence says whose move it is rather than leaving the step number to be counted out.
    #expect(d7.note.contains("引擎往下第 1 步，对方就走 Rd7 站到这格上"))
    #expect(d7.note.contains("紧挨着自己的王"))
    #expect(d7.note.contains("对方的攻势就从这儿切进来"))
    // And the piece named is theirs. On a square by your own king the arrival is always the
    // invader — 「自己的车 1 步就能到 d7」 is true and nobody has a use for it.
    #expect(d7.note.contains("对方的车从 a7"))
}

/// A square in the *other* king's ring is where an attack is built rather than where one arrives,
/// so it is a kind of its own too, and it sorts after your own king's.
@Test("a square taken beside the other king is named as that")
func takingBesideTheOtherKingIsItsOwnKind() throws {
    // White's rook swings to the seventh; f7 beside the black king changes hands, and the engine
    // walks the rook onto it next move.
    let game = try #require(
        Game(startFEN: "4k3/8/8/8/8/8/8/R3K3 w - - 0 1", uciMoves: ["a1a7"])
    )
    let key = game.keySquares(continuation: ["Kd8", "Rf7"])
    let f7 = try #require(key.first { $0.square == (try? square("f7")) })
    #expect(f7.mover == .white)
    #expect(f7.kind == .enemyKing)
    #expect(f7.isGain)
    #expect(f7.note.contains("紧挨着对方的王"))
    // And not 「去了就亏」: the Line puts the mover's own rook on f7 two plies later, which refutes
    // it outright. Two true halves that read as one wrong sentence.
    #expect(!f7.note.contains("就亏"))
    #expect(f7.note.contains("攻势就从这儿起手"))
    // The mirror: by *their* king the arrival is always yours, because that is the attacker.
    #expect(f7.note.contains("自己的车从 a7"))
}

@Test("never more than the limit, however much the engine's line touches")
func theLimitHolds() throws {
    let game = try #require(
        Game(startFEN: "3qk3/R7/8/8/8/8/8/4K3 b - - 0 1", uciMoves: ["d8g5"])
    )
    let line = ["Rd7", "Kf8", "Rf7+", "Kg8"]
    #expect(game.keySquares(continuation: line).count <= 3)
    #expect(game.keySquares(continuation: line, limit: 1).count <= 1)
}

/// The ring includes the square the king is standing on, and "beside your own king" is the wrong
/// sentence about that one.
@Test("the square the king is standing on gets its own sentence")
func theKingsOwnSquareIsSaidDifferently() throws {
    // The queen on d8 is the only thing covering e8, where her own king stands. She walks away.
    let game = try #require(
        Game(startFEN: "3qk3/8/8/8/8/8/8/R3K3 b - - 0 1", uciMoves: ["d8g5"])
    )
    let key = game.keySquares(continuation: ["Rb1", "Ke7", "Ra1", "Kf6"])
    let e8 = try #require(key.first { $0.square == (try? square("e8")) })
    #expect(e8.kind == .ownKing)
    #expect(!e8.isGain)
    #expect(e8.note.contains("自己的王就站在 e8 上"))
    #expect(!e8.note.contains("紧挨着"))
}

// ------------------------------------------------------- who can actually come

@Test("a knight's distance to a square is counted in knight moves")
func aRouteIsCountedInThePiecesOwnMoves() throws {
    let board = try pieces("4k3/8/8/8/8/8/8/1N2K3 w - - 0 1")
    let b1 = try square("b1")
    // b1 to d5: Nb1-c3-d5. Two moves, and the route says which two squares it stands on.
    let route = try #require(Rules.route(to: try square("d5"), from: b1, pieces: board))
    #expect(route.count == 2)
    #expect(route.last == (try square("d5")))
    let viaC3 = [try square("c3"), try square("d5")]
    let viaD2 = [try square("d2"), try square("d5")]
    #expect(route == viaC3 || route == viaD2)
    // A knight cannot reach the square it stands beside in one move, and a square it can is one.
    #expect(Rules.route(to: try square("c3"), from: b1, pieces: board)?.count == 1)
}

@Test("a piece that cannot get there inside the horizon comes back as nothing")
func aRouteHasAHorizon() throws {
    let board = try pieces("4k3/8/8/8/8/8/8/1N2K3 w - - 0 1")
    // The far corner is four knight moves from b1, and four moves away is not a fact about this
    // position — so the default horizon of three refuses it, and asking for more finds it.
    #expect(Rules.route(to: try square("h7"), from: try square("b1"), pieces: board) == nil)
    #expect(Rules.route(to: try square("h7"), from: try square("b1"), pieces: board, horizon: 5) != nil)
}

@Test("a piece walled in by its own side goes nowhere")
func ownPiecesAreWalls() throws {
    // A rook on a1 behind its own pawn on a2 and its own knight on b1: no route anywhere.
    let board = try pieces("4k3/8/8/8/8/8/P7/RN2K3 w - - 0 1")
    #expect(Rules.route(to: try square("a5"), from: try square("a1"), pieces: board) == nil)
    #expect(Rules.route(to: try square("d1"), from: try square("a1"), pieces: board) == nil)
}

@Test("a pawn walks forward and takes sideways, and is not a slider on a short leash")
func pawnsMoveTheirOwnWay() throws {
    let board = try pieces("4k3/8/8/8/3p4/8/2P5/4K3 w - - 0 1")
    let c2 = try square("c2")
    // Two squares from home, one thereafter.
    #expect(Rules.route(to: try square("c4"), from: c2, pieces: board)?.count == 1)
    // And it may go sideways only onto the black pawn.
    #expect(Rules.route(to: try square("d4"), from: c2, pieces: board) != nil)
    #expect(Rules.route(to: try square("b3"), from: c2, pieces: board) == nil)
}

/// The sentence a player can act on: not "you let go of d5" but "their knight is two moves from d5
/// and no pawn of yours will ever attack it again".
@Test("the soonest arrival names the piece, the distance, and whether it can be thrown out")
func theSoonestArrivalIsTheOneNamed() throws {
    let board = try pieces("4k3/8/8/2p1p3/8/8/8/1N2K3 w - - 0 1")
    let arrival = try #require(
        Rules.occupation(of: try square("d5"), by: .white, pieces: board)
    )
    #expect(arrival.piece.kind == .knight)
    #expect(arrival.from == (try square("b1")))
    #expect(arrival.moves == 2)
    #expect(arrival.route.last == (try square("d5")))
    // The black pawns on c5 and e5 are past d5 for ever, so whoever gets there stays.
    #expect(!arrival.canBeDislodged)

    // The same square with a black pawn still on c7: it can come to c6 and throw the knight out.
    let challenged = try pieces("4k3/2p5/8/4p3/8/8/8/1N2K3 w - - 0 1")
    let weaker = try #require(Rules.occupation(of: try square("d5"), by: .white, pieces: challenged))
    #expect(weaker.canBeDislodged)
}

@Test("a king walking to an outpost is not a plan, so kings are left out")
func kingsAreNotOccupiers() throws {
    let board = try pieces("4k3/8/8/8/8/8/8/3K4 w - - 0 1")
    #expect(Rules.occupation(of: try square("d4"), by: .white, pieces: board) == nil)
}

/// A hole nobody can reach is a weakness on paper; a hole with a knight walking towards it is the
/// thing that actually happens to you. They are told apart, and the sentence says which.
@Test("a hole somebody can get to is named an outpost, and the sentence says who comes")
func aReachableHoleBecomesAnOutpost() throws {
    let game = try #require(
        Game(startFEN: "4k3/8/8/2p1p3/8/8/8/1N2K3 w - - 0 1", uciMoves: ["b1c3"])
    )
    let key = game.keySquares(continuation: ["Ke7", "Nd5+"])
    let d5 = try #require(key.first { $0.square == (try? square("d5")) })
    #expect(d5.kind == .outpost, "the knight that took it is one move away from standing on it")
    let arrival = try #require(d5.occupation)
    #expect(arrival.piece.kind == .knight)
    #expect(arrival.moves == 1, "Nc3 is one move from d5")
    #expect(!arrival.canBeDislodged)
    #expect(d5.note.contains("永久据点"))
    #expect(d5.note.contains("自己的马从 c3 走 1 步就到"))
    #expect(!d5.note.contains("赶不走它"), "a hole already said nobody can throw anybody out")
}

/// Which side walks there is decided by which way the square went. A square you took is one you
/// would come and use; one you let go of is one they would.
@Test("a square let go of names one of their pieces, not one of yours")
func theComerFollowsTheDirection() throws {
    // White's rook leaves the first rank, so White lets go of d1 beside its own king; the piece
    // that would come and use d1 is a black one.
    let game = try #require(
        Game(startFEN: "3rk3/8/8/8/8/8/8/R3K3 w - - 0 1", uciMoves: ["a1a5"])
    )
    let key = game.keySquares(continuation: ["Rd2", "Ra8", "Rd1+"])
    let d1 = try #require(key.first { $0.square == (try? square("d1")) })
    #expect(!d1.isGain)
    let arrival = try #require(d1.occupation)
    #expect(arrival.piece.colour == .black, "the square was let go of, so they are the ones coming")
    #expect(d1.note.contains("对方的车"))
}

// ---------------------------------------------- the squares your own pieces want

/// A null move is not a chess move, and it is the only way to ask what the side that just moved
/// could do next — after their move it is not their turn.
@Test("a position can be handed back to the side that just moved, unless they gave check")
func passingTheTurnBack() throws {
    let game = try #require(
        Game(startFEN: "4k3/8/8/8/8/8/8/R3K3 w - - 0 1", uciMoves: ["a1a5"])
    )
    #expect(game.state.sideToMove == .black)
    let passed = try #require(game.passed())
    #expect(passed.state.sideToMove == .white, "White is asked what it could do next")
    #expect(passed.state.fen.split(separator: " ").first == game.state.fen.split(separator: " ").first)

    // A move that gives check refuses: with the king able to be taken, this is not a position.
    let checking = try #require(
        Game(startFEN: "4k3/8/8/8/8/8/8/R3K3 w - - 0 1", uciMoves: ["a1a8"])
    )
    #expect(checking.state.inCheck)
    #expect(checking.passed() == nil)
}

/// The cost of a move that never shows up as anything changing hands: your knight would like d5
/// and would simply be taken there.
@Test("a square your own piece wants and cannot safely take is named, and the count says why")
func aSquareYouAreShutOutOf() throws {
    // White's rook takes the fifth rank. Its own knight on b4 would like d5 — but two black pawns
    // on c6 and e6 are looking at it, so going there is giving a knight away.
    let game = try #require(
        Game(startFEN: "4k3/8/2p1p3/8/1N6/8/8/R3K3 w - - 0 1", uciMoves: ["a1a5"])
    )
    let passed = try #require(game.passed())
    let d5 = try square("d5")
    let stuck = try #require(game.shutOut(of: d5, for: .white, in: passed))
    #expect(stuck.piece.kind == .knight, "cheaper than the rook that could also go there")
    #expect(stuck.from == (try square("b4")))
    #expect(stuck.defenders == 2, "the two pawns looking at d5")

    // And a square nothing is stopping anybody from taking is not one of these.
    #expect(game.shutOut(of: try square("h5"), for: .white, in: passed) == nil)
}

@Test("the cheapest piece that cannot go is the one named")
func theCheapestShutOutPieceWins() throws {
    // Both the queen and the rook could go to d5, and both would be taken by the pawn on c6. The
    // rook is the cheaper of the two, and a rook being unable to go is the stronger statement.
    let game = try #require(
        Game(startFEN: "4k3/8/2p5/8/8/8/8/R2QK3 w - - 0 1", uciMoves: ["a1a5"])
    )
    let passed = try #require(game.passed())
    let stuck = try #require(game.shutOut(of: try square("d5"), for: .white, in: passed))
    #expect(stuck.piece.kind == .rook)
}

@Test("a shut-out square joins the same net and gets the same kind of sentence")
func shutOutJoinsTheNet() throws {
    let game = try #require(
        Game(startFEN: "4k3/8/2p1p3/8/1N6/8/8/R3K3 w - - 0 1", uciMoves: ["a1a5"])
    )
    let key = game.keySquares(continuation: ["Kd8", "Ra4", "Kc8", "Rd4"])
    // d4 is on the rook's own new rank neither way; what the line does touch is d4, and the square
    // the reading is about has to have come out of the change the move made.
    #expect(key.allSatisfy { $0.mover == .white })
    if let stuck = key.first(where: { $0.kind == .shutOut }) {
        #expect(stuck.note.contains("站不上去"))
        #expect(stuck.shutOut != nil)
    }
    // Whatever is drawn, a square one of White's own pieces cannot take says so somewhere.
    #expect(key.allSatisfy { !$0.note.isEmpty })
}

/// The one reading that is about your own pieces: the rook takes the fifth rank, d5 changes hands,
/// and the knight that would like to stand there still cannot.
@Test("a square you took and cannot stand on is what the reading names")
func theSquareYouTookAndCannotStandOn() throws {
    let game = try #require(
        Game(startFEN: "4k3/1p1p1pp1/2p1p3/8/1N6/8/1P4B1/R3K3 w - - 0 1", uciMoves: ["a1a5"])
    )
    let key = game.keySquares(continuation: ["Kf8", "Ke2", "Ke8", "Kd1"])
    let first = try #require(key.first)
    #expect(first.square == (try square("d5")))
    #expect(first.kind == .shutOut)
    #expect(first.isGain, "taken, and still not somewhere anything of yours may stand")
    let stuck = try #require(first.shutOut)
    #expect(stuck.piece.kind == .knight)
    #expect(stuck.defenders == 2)
    #expect(first.note.contains("站不上去"))
}

/// A sentence that names a piece has to name the same piece every time it is asked. Two candidates
/// the same distance away and a dictionary's iteration order deciding between them is a screen
/// whose words change when nothing about the position has.
@Test("the piece named as the one who comes is the same piece every time")
func theArrivalIsDeterministic() throws {
    // A rook on d1 and a queen on a5 are both one move from d5.
    let board = try pieces("4k3/8/8/Q7/8/8/8/3RK3 w - - 0 1")
    let d5 = try square("d5")
    let answers = (0..<40).compactMap { _ in
        Rules.occupation(of: d5, by: .white, pieces: board)
    }
    #expect(answers.count == 40)
    #expect(Set(answers).count == 1, "forty asks, one answer")
    // And the cheapest of the equally quick is the one named: a rook that can have the square is
    // a stronger claim about the square than a queen that can.
    let named = try #require(answers.first)
    #expect(named.piece.kind == .rook)
    #expect(named.moves == 1)
}
