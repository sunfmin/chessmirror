import ChessfenKit
import Testing

/// Plays UCI moves into a Game, failing the test rather than the run if one is illegal.
private func game(_ moves: [String], from startFEN: String = PGN.standardStartFEN) throws -> Game {
    try #require(Game(startFEN: startFEN, uciMoves: moves))
}

@Test("playing something else from an earlier ply keeps the line that was there")
func branchingRecordsWhatItReplaced() throws {
    var played = try game(["e2e4", "e7e5", "g1f3", "b8c6"])
    let knight = try #require(played.rewound(to: 2)?.state.move(matching: "f1c4"))

    let branched = played.play(knight, atPly: 2)
    #expect(branched)
    #expect(played.plies.count == 3)
    #expect(played.plies.map(\.san) == ["e4", "e5", "Bc4"])

    let variations = played.variations(atPly: 2)
    #expect(variations.count == 1)
    #expect(variations.first?.map(\.san) == ["Nf3", "Nc6"])
}

@Test("playing the move that is already there is not a branch")
func replayingTheSameMoveDoesNotBranch() throws {
    var played = try game(["e2e4", "e7e5", "g1f3"])
    let same = try #require(played.rewound(to: 2)?.state.move(matching: "g1f3"))
    let again = played.play(same, atPly: 2)
    #expect(again)
    #expect(played.plies.count == 3, "the line should be untouched")
    #expect(played.variations(atPly: 2).isEmpty)
}

@Test("branching twice from one ply keeps both lines")
func twoBranchesFromOnePly() throws {
    var played = try game(["e2e4", "e7e5", "g1f3", "b8c6"])
    let bishop = try #require(played.rewound(to: 2)?.state.move(matching: "f1c4"))
    let queen = try #require(played.rewound(to: 2)?.state.move(matching: "d1h5"))

    let first = played.play(bishop, atPly: 2)
    let second = played.play(queen, atPly: 2)
    #expect(first)
    #expect(second)

    #expect(played.plies.map(\.san) == ["e4", "e5", "Qh5"])
    let lines = played.variations(atPly: 2).map { $0.map(\.san) }
    #expect(lines.count == 2)
    #expect(lines.contains(["Nf3", "Nc6"]))
    #expect(lines.contains(["Bc4"]))
}

@Test("a new line from an earlier ply is a branch; the abandoned line stays the trunk")
func branchingMarksTheNewLineAsABranch() throws {
    var played = try game(["e2e4", "e7e5", "g1f3", "b8c6"])
    let bishop = try #require(played.rewound(to: 2)?.state.move(matching: "f1c4"))
    let branched = played.play(bishop, atPly: 2)
    #expect(branched)
    #expect(played.plies[2].isTrunk == false)
    #expect(played.variations(atPly: 2).first?.first?.isTrunk == true)

    let siblings = played.siblings(atPly: 2)
    #expect(siblings.map(\.number) == [1, 2])
    #expect(siblings[0].isTrunk && siblings[0].san == "Nf3")
    #expect(!siblings[1].isTrunk && siblings[1].san == "Bc4")
    #expect(siblings[1].variationIndex == nil, "Bc4 is the line on the board")
}

@Test("cycling the fork walks every sibling and comes back")
@MainActor
func cyclingTheForkWalksEverySibling() throws {
    let start = try game(["e2e4", "e7e5", "g1f3", "b8c6"])
    let session = GameSession.fresh(start)
    session.jump(toPly: 2)
    session.play(try #require(session.viewed.state.move(matching: "f1c4")))
    #expect(session.game.plies.map(\.san) == ["e4", "e5", "Bc4"])

    session.cycleFork(by: 1)
    #expect(session.game.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6"])
    session.cycleFork(by: 1)
    #expect(session.game.plies.map(\.san) == ["e4", "e5", "Bc4"])
}

@Test("a variation can be taken as the line to carry on with")
func promotingAVariationSwapsTheLines() throws {
    var played = try game(["e2e4", "e7e5", "g1f3", "b8c6"])
    let bishop = try #require(played.rewound(to: 2)?.state.move(matching: "f1c4"))
    let branched = played.play(bishop, atPly: 2)
    #expect(branched)

    let promoted = played.promoteVariation(0, atPly: 2)
    #expect(promoted)
    #expect(played.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6"])
    #expect(played.variations(atPly: 2).map { $0.map(\.san) } == [["Bc4"]])
    // And the position is the one the promoted line reaches, not the one it left.
    #expect(played.state.fen.hasPrefix("r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R"))
}

@Test("a game with branches survives a round trip through PGN")
func variationsRoundTripThroughPGN() throws {
    var played = try game(["e2e4", "e7e5", "g1f3", "b8c6", "f1b5"])
    let bishop = try #require(played.rewound(to: 2)?.state.move(matching: "f1c4"))
    let branched = played.play(bishop, atPly: 2)
    #expect(branched)
    #expect(played.plies.count == 3)
    // Carrying on down the new line, which is an append rather than another branch.
    let knight = try #require(played.rewound(to: 3)?.state.move(matching: "b8c6"))
    let carried = played.play(knight, atPly: 3)
    #expect(carried)

    let text = PGN(game: played, tags: [PGN.Tag("White", "甲"), PGN.Tag("Black", "乙")]).text
    #expect(text.contains("("), "the variation should be written in brackets")

    let reread = try PGN(parsing: text)
    #expect(reread.game.plies.map(\.san) == played.plies.map(\.san))
    #expect(
        reread.game.variations(atPly: 2).map { $0.map(\.san) }
            == played.variations(atPly: 2).map { $0.map(\.san) }
    )
    #expect(reread.game.state.fen == played.state.fen)
}

@Test("evaluations inside a variation come back with it")
func variationEvaluationsRoundTrip() throws {
    var played = try game(["e2e4", "e7e5", "g1f3"])
    let bishop = try #require(played.rewound(to: 2)?.state.move(matching: "f1c4"))
    let branched = played.play(bishop, atPly: 2)
    #expect(branched)
    played.applyReview(
        [.centipawns(18), nil, .centipawns(31)], startEvaluation: nil, depth: 14
    )

    let reread = try PGN(parsing: PGN(game: played).text)
    #expect(reread.game.plies.first?.evaluation == .centipawns(18))
    #expect(reread.game.plies[2].evaluation == .centipawns(31))
    #expect(reread.game.reviewDepth == 14)
}

@Test("brackets a reader cannot place are ignored rather than fatal")
func strayBracketsAreTolerated() throws {
    // A variation before any move has nothing to be an alternative to.
    let pgn = try PGN(parsing: "[Event \"x\"]\n\n(1. d4) 1. e4 e5 2. Nf3 *\n")
    #expect(pgn.game.plies.map(\.san) == ["e4", "e5", "Nf3"])
}

@Test("a variation read from another program's PGN is kept, not dropped")
func foreignVariationsAreKept() throws {
    let text = """
        [Event "Test"]
        [Result "*"]

        1. e4 e5 2. Nf3 (2. Bc4 Nc6 3. Qh5) 2... Nc6 3. Bb5 *
        """
    let pgn = try PGN(parsing: text)
    #expect(pgn.game.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6", "Bb5"])
    #expect(pgn.game.variations(atPly: 2).map { $0.map(\.san) } == [["Bc4", "Nc6", "Qh5"]])
}
