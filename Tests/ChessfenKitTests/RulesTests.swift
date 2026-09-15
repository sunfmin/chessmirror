import ChessfenKit
import Testing

private let start = PGN.standardStartFEN

@Test("the starting position offers twenty moves and is ongoing")
func startingPositionIsOngoing() throws {
    let state = try #require(Rules.probe(startFEN: start))
    #expect(state.legalMoves.count == 20)
    #expect(state.outcome == .ongoing)
    #expect(state.sideToMove == .white)
    #expect(!state.inCheck)
    #expect(state.fullmoveNumber == 1)
}

@Test("checkmate ends the game and names the checking piece")
func checkmateIsDetected() throws {
    // Fool's mate.
    let game = try #require(
        Game(startFEN: start, uciMoves: ["f2f3", "e7e5", "g2g4", "d8h4"])
    )
    #expect(game.state.outcome == .checkmate)
    #expect(game.state.inCheck)
    #expect(game.state.checkers.map(\.description) == ["h4"])
    #expect(game.state.legalMoves.isEmpty)
    #expect(game.resultToken == "0-1")
    #expect(game.plies.last?.san == "Qh4#")
}

@Test("stalemate is a draw, not a mate")
func stalemateIsDetected() throws {
    let state = try #require(Rules.probe(startFEN: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"))
    #expect(state.outcome == .stalemate)
    #expect(!state.inCheck)
    #expect(state.legalMoves.isEmpty)
}

@Test("a position repeated three times is a draw")
func threefoldRepetitionIsDetected() throws {
    // Knights out and back, twice: the starting position occurs on plies 0, 4 and 8.
    let shuffle = ["g1f3", "g8f6", "f3g1", "f6g8", "g1f3", "g8f6", "f3g1", "f6g8"]
    let game = try #require(Game(startFEN: start, uciMoves: shuffle))
    #expect(game.state.outcome == .threefoldRepetition)

    // Two occurrences are not enough.
    let twice = try #require(Game(startFEN: start, uciMoves: Array(shuffle.prefix(4))))
    #expect(twice.state.outcome == .ongoing)
}

@Test("the fifty-move rule is read off the halfmove clock")
func fiftyMoveRuleIsDetected() throws {
    let state = try #require(Rules.probe(startFEN: "8/8/8/4k3/8/8/8/4K1R1 w - - 100 60"))
    #expect(state.outcome == .fiftyMoveRule)
    #expect(state.halfmoveClock == 100)
}

@Test(
    "material too thin to mate with is a draw",
    arguments: [
        ("8/8/8/4k3/8/8/8/4K3 w - - 0 1", Outcome.insufficientMaterial),
        ("8/8/8/4k3/8/8/8/4K1B1 w - - 0 1", .insufficientMaterial),
        ("8/8/8/4k3/8/8/8/4K1N1 w - - 0 1", .insufficientMaterial),
        // Bishops on the same colour can never mate; on opposite colours they can.
        // g8 and g1 are opposite colours, f8 and g1 are the same.
        ("5b2/8/8/4k3/8/8/8/4K1B1 w - - 0 1", .insufficientMaterial),
        ("6b1/8/8/4k3/8/8/8/4K1B1 w - - 0 1", .ongoing),
        // Two knights is thin but not impossible, so the rule leaves it alone.
        ("8/8/8/4k3/8/8/8/3NKN2 w - - 0 1", .ongoing),
        ("8/8/8/4k3/8/8/8/4K1R1 w - - 0 1", .ongoing),
    ]
)
func insufficientMaterialIsJudged(fen: String, expected: Outcome) throws {
    let state = try #require(Rules.probe(startFEN: fen))
    #expect(state.outcome == expected)
}

@Test("castling is offered as the king landing on g1, not on the rook")
func castlingLandsWhereThePlayerSeesIt() throws {
    let state = try #require(Rules.probe(startFEN: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"))

    let short = try #require(state.move(matching: "e1g1"))
    #expect(short.isCastling)
    #expect(short.to.description == "g1")
    #expect(!short.isCapture)  // the square holds the player's own rook
    #expect(SAN.text(for: short, in: state) == "O-O")

    let long = try #require(state.move(matching: "e1c1"))
    #expect(SAN.text(for: long, in: state) == "O-O-O")
}

@Test("en passant is generated and written as a normal pawn capture")
func enPassantIsGenerated() throws {
    let state = try #require(Rules.probe(startFEN: "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1"))
    let capture = try #require(state.move(matching: "e5d6"))
    #expect(capture.isEnPassant)
    #expect(capture.isCapture)
    #expect(SAN.text(for: capture, in: state) == "exd6")
}

@Test("promotion carries its piece into the notation")
func promotionIsWritten() throws {
    let state = try #require(Rules.probe(startFEN: "4k3/P7/8/8/8/8/8/4K3 w - - 0 1"))
    let queening = try #require(state.move(matching: "a7a8q"))
    #expect(queening.promotion == .queen)
    // The new queen sees along the eighth rank to the king on e8, so it is also check.
    #expect(queening.givesCheck)
    #expect(SAN.text(for: queening, in: state) == "a8=Q+")

    let knighting = try #require(state.move(matching: "a7a8n"))
    #expect(SAN.text(for: knighting, in: state) == "a8=N")
}

@Test("moves that need telling apart get the smallest hint that does it")
func disambiguationIsMinimal() throws {
    // Two knights on the same rank: the file separates them.
    let files = try #require(Rules.probe(startFEN: "4k3/8/8/8/8/2N1N3/8/4K3 w - - 0 1"))
    let fromC3 = try #require(files.move(matching: "c3d5"))
    #expect(SAN.text(for: fromC3, in: files) == "Ncd5")

    // Two knights on the same file: the rank separates them.
    let ranks = try #require(Rules.probe(startFEN: "4k3/8/8/2N5/8/2N5/8/4K3 w - - 0 1"))
    let fromC3Again = try #require(ranks.move(matching: "c3e4"))
    #expect(SAN.text(for: fromC3Again, in: ranks) == "N3e4")

    // A lone knight needs no hint at all.
    let lone = try #require(Rules.probe(startFEN: "4k3/8/8/8/8/2N5/8/4K3 w - - 0 1"))
    let only = try #require(lone.move(matching: "c3d5"))
    #expect(SAN.text(for: only, in: lone) == "Nd5")
}

@Test("mate gets a hash and mere check gets a plus")
func checkAndMateSuffixes() throws {
    let state = try #require(Rules.probe(startFEN: "6k1/5ppp/8/8/8/8/8/R3K2R w K - 0 1"))
    let mate = try #require(state.move(matching: "a1a8"))
    #expect(mate.isCheckmate)
    #expect(SAN.text(for: mate, in: state) == "Ra8#")

    // Taking the h-pawn is not check: the rook stops on h7, and the pawn on g7 blocks the
    // rank behind it. Exactly the kind of thing a hand-written suffix would get wrong.
    let quiet = try #require(state.move(matching: "h1h7"))
    #expect(!quiet.givesCheck)
    #expect(SAN.text(for: quiet, in: state) == "Rxh7")

    // A king with room to run turns the same rook check into a plain "+".
    let open = try #require(Rules.probe(startFEN: "4k3/8/8/8/8/8/8/R3K3 w - - 0 1"))
    let check = try #require(open.move(matching: "a1a8"))
    #expect(check.givesCheck)
    #expect(!check.isCheckmate)
    #expect(SAN.text(for: check, in: open) == "Ra8+")
}

@Test("every legal move survives a round trip through its own notation")
func sanRoundTripsForEveryLegalMove() throws {
    let positions = [
        start,
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "4k3/P7/8/8/8/8/8/4K3 w - - 0 1",
        "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1",
        "4k3/8/8/2N5/8/2N5/8/4K3 w - - 0 1",
    ]
    for fen in positions {
        let state = try #require(Rules.probe(startFEN: fen))
        for move in state.legalMoves {
            let san = SAN.text(for: move, in: state)
            #expect(SAN.move(for: san, in: state) == move, "\(san) in \(fen)")
        }
    }
}

@Test("applying and undoing leaves the game exactly where it was")
func undoRestoresTheGame() throws {
    var game = try #require(Game(startFEN: start))
    let before = game.state

    let applied = game.apply(uci: "e2e4")
    #expect(applied)
    #expect(game.state != before)
    #expect(game.plies.map(\.san) == ["e4"])

    let undone = game.undo()
    #expect(undone)
    #expect(game.state == before)
    #expect(game.plies.isEmpty)

    let undoneAgain = game.undo()
    #expect(!undoneAgain)
}

@Test("an illegal move is refused rather than applied")
func illegalMovesAreRefused() throws {
    var game = try #require(Game(startFEN: start))
    let illegalUci = game.apply(uci: "e2e5")
    let illegalSan = game.apply(san: "Qh5")
    #expect(!illegalUci)
    #expect(!illegalSan)
    #expect(game.plies.isEmpty)
    #expect(Game(startFEN: start, uciMoves: ["e2e4", "e7e5", "e4e5"]) == nil)
}

@Test("rewinding produces the game as it stood")
func rewindingWalksTheGame() throws {
    let game = try #require(
        Game(startFEN: start, uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6"])
    )
    let afterTwo = try #require(game.rewound(to: 2))
    #expect(afterTwo.plies.map(\.san) == ["e4", "e5"])
    #expect(afterTwo.state.fullmoveNumber == 2)
    #expect(game.rewound(to: 0)?.state == Rules.probe(startFEN: start))
    #expect(game.rewound(to: 99) == nil)
}
