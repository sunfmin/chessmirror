import ChessfenKit
import Testing

private let start = PGN.standardStartFEN

private func played(_ moves: [String]) throws -> Game {
    try #require(Game(startFEN: start, uciMoves: moves))
}

// A game from somewhere else, analysed by somebody else's engine: `[%eval]` on every move and
// no Review Depth anywhere, which is exactly what a lichess export looks like.
private let foreignAnalysedGame = """
    [Event "Rated blitz game"]
    [Site "https://lichess.org/abcd1234"]
    [White "someone"]
    [Black "someone-else"]
    [Result "1-0"]

    1. e4 {[%eval 0.24]} e5 {[%eval 0.31]} 2. Nf3 {[%eval 0.28]} Nc6 {[%eval 0.30]} 1-0
    """

@Test("an imported game's Scores are kept as somebody else's, and judged by nothing")
func importedScoresAreNotTheReview() throws {
    let read = try PGN(parsing: foreignAnalysedGame)

    #expect(!read.game.isReviewed)
    #expect(read.game.reviewDepth == nil)
    #expect(read.game.plies.map(\.importedEvaluation) == [
        .centipawns(24), .centipawns(31), .centipawns(28), .centipawns(30),
    ])
    // Nothing in the Review's field, so nothing can be ranked or named a mistake from it.
    #expect(read.game.plies.allSatisfy { $0.evaluation == nil })
    for ply in 0...read.game.plies.count {
        #expect(read.game.reviewScore(atPly: ply) == nil)
    }
    for ply in 1...read.game.plies.count {
        #expect(read.game.quality(atPly: ply) == nil)
    }
}

@Test("an imported game's Scores go back out as they came in")
func importedScoresRoundTrip() throws {
    let once = try PGN(parsing: foreignAnalysedGame)
    let twice = try PGN(parsing: once.text)

    #expect(twice.game.plies.map(\.importedEvaluation) == once.game.plies.map(\.importedEvaluation))
    #expect(!twice.game.isReviewed)
    // And nothing has quietly claimed the numbers on the way through.
    #expect(!once.text.contains("ReviewDepth"))
}

@Test("a Review's Depth is written once for the game and read back from the tag")
func reviewDepthIsOneTagPerGame() throws {
    var game = try played(["e2e4", "e7e5", "g1f3"])
    game.applyReview(
        [.centipawns(30), .centipawns(20), .centipawns(35)],
        startEvaluation: .centipawns(25),
        depth: 22
    )

    let text = PGN(game: game).text
    #expect(text.contains("[ReviewDepth \"22\"]"))
    // One home for the fact: written from the Game, and not left in the tag list to be
    // written a second time when the file is read and written again.
    #expect(text.components(separatedBy: "ReviewDepth").count - 1 == 1)

    let reread = try PGN(parsing: text)
    #expect(reread.game.reviewDepth == 22)
    #expect(reread.tag("ReviewDepth") == nil)
    #expect(PGN(game: reread.game).text.components(separatedBy: "ReviewDepth").count - 1 == 1)
}

@Test("the first move's quality survives a save, because the baseline is written")
func firstMoveIsJudgeableFromTheFileAlone() throws {
    var game = try played(["e2e4", "e7e5"])
    // The first move throws away most of two pawns: a mistake, but only if the position
    // it started from was written down too.
    game.applyReview(
        [.centipawns(-150), .centipawns(-145)], startEvaluation: .centipawns(30), depth: 14
    )
    #expect(game.quality(atPly: 1) == .mistake)

    let reread = try PGN(parsing: PGN(game: game).text)
    #expect(reread.game.startEvaluation == .centipawns(30))
    #expect(reread.game.reviewScore(atPly: 0) == .centipawns(30))
    #expect(reread.game.quality(atPly: 1) == .mistake)
}

@Test("a game with no baseline still judges every move it can")
func missingBaselineOnlyCostsTheFirstMove() throws {
    var game = try played(["e2e4", "e7e5", "g1f3"])
    game.applyReview(
        [.centipawns(30), .centipawns(25), .centipawns(-300)], startEvaluation: nil, depth: 14
    )
    #expect(game.quality(atPly: 1) == nil)
    #expect(game.quality(atPly: 3) == .blunder)
}

@Test("who played a ply follows the position the game started from")
func moverFollowsTheStartingSide() throws {
    let white = try played(["e2e4"])
    #expect(white.mover(ofPly: 1) == .white)
    #expect(white.mover(ofPly: 2) == .black)

    // A recognised position with Black to move: the first ply is Black's.
    let black = try #require(
        Game(startFEN: "r3k3/8/2N5/8/8/8/8/4K3 b q - 0 1", uciMoves: ["e8f7"])
    )
    #expect(black.mover(ofPly: 1) == .black)
    #expect(black.mover(ofPly: 2) == .white)
}

@Test("rewinding a reviewed game keeps the Review with it")
func rewindingKeepsTheReview() throws {
    var game = try played(["e2e4", "e7e5", "g1f3"])
    game.applyReview(
        [.centipawns(30), .centipawns(25), .centipawns(35)],
        startEvaluation: .centipawns(20),
        depth: 16
    )
    let rewound = try #require(game.rewound(to: 2))
    #expect(rewound.reviewDepth == 16)
    #expect(rewound.startEvaluation == .centipawns(20))
    #expect(rewound.reviewScore(atPly: 2) == .centipawns(25))
}

@Test("a move played after a Review is not a mistake, it is unscored")
func aPlyWithNoScoreIsNeverAMistake() throws {
    var game = try played(["e2e4", "e7e5"])
    game.applyReview(
        [.centipawns(30), .centipawns(25)], startEvaluation: .centipawns(20), depth: 14
    )
    let continued = game.apply(uci: "g1f3")
    #expect(continued)

    #expect(game.isReviewed)
    #expect(game.reviewScore(atPly: 3) == nil)
    #expect(game.quality(atPly: 3) == nil)
    // And the moves the Review did cover are still judged.
    #expect(game.quality(atPly: 1) == .fine)
}
