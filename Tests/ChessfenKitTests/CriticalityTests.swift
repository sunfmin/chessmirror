import ChessfenKit
import Testing

private let start = PGN.standardStartFEN

private func played(_ moves: [String]) throws -> Game {
    try #require(Game(startFEN: start, uciMoves: moves))
}

/// Six moves of a real opening, so the SAN in the answers is real SAN.
private let opening = ["e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "a7a6"]

/// A beginner's game: five ordinary moves and one piece handed over.
private func giveawayGame() throws -> Game {
    var game = try played(opening)
    game.applyReview(
        [
            .centipawns(30),  // 1. e4      white gained 10
            .centipawns(25),  // 1… e5      black gained 5
            .centipawns(35),  // 2. Nf3     white gained 10
            .centipawns(30),  // 2… Nc6     black gained 5
            .centipawns(-600),  // 3. Bb5?? white lost 630
            .centipawns(-590),  // 3… a6    black lost 10
        ],
        startEvaluation: .centipawns(20),
        depth: 18
    )
    return game
}

/// A club player's game: the same six moves, nobody throws anything away, and the eval drifts
/// by a few tenths of a pawn the way it does between two people who can both play.
private func driftingGame() throws -> Game {
    var game = try played(opening)
    game.applyReview(
        [
            .centipawns(5),  // 1. e4    white lost 5
            .centipawns(35),  // 1… e5   black lost 30
            .centipawns(0),  // 2. Nf3   white lost 35
            .centipawns(40),  // 2… Nc6  black lost 40
            .centipawns(20),  // 3. Bb5  white lost 20
            .centipawns(45),  // 3… a6   black lost 25
        ],
        startEvaluation: .centipawns(10),
        depth: 18
    )
    return game
}

@Test("the moves of a reviewed game are ranked by what they lost, worst first")
func everyJudgeableMoveIsRanked() throws {
    let game = try giveawayGame()
    let ranked = try #require(game.criticality())

    #expect(ranked.count == 6)
    #expect(ranked.map(\.lost) == ranked.map(\.lost).sorted(by: >))
    #expect(ranked.first?.ply == 5)
    #expect(ranked.first?.san == "Bb5")
    #expect(ranked.first?.lost == 630)
    #expect(ranked.first?.mover == .white)
}

@Test("one colour's moves can be ranked on their own")
func rankingOneColour() throws {
    let game = try driftingGame()

    let black = try #require(game.criticality(by: .black))
    #expect(black.allSatisfy { $0.mover == .black })
    #expect(black.map(\.ply) == [4, 2, 6])
    #expect(black.map(\.lost) == [40, 30, 25])

    let white = try #require(game.criticality(by: .white))
    #expect(white.map(\.ply) == [3, 5, 1])
}

@Test("a giveaway and a game of small drifts get sensibly different answers out of one rule")
func rankingServesBothPlayers() throws {
    let beginner = try #require(try giveawayGame().worstMoves())
    let club = try #require(try driftingGame().worstMoves())

    #expect(beginner.count == 3)
    #expect(club.count == 3)

    // The beginner is told about the piece, and the label goes with it.
    #expect(beginner[0].lost == 630)
    #expect(beginner[0].quality == .blunder)

    // The club player is told about their three worst moves too, and none of them earns a
    // label. Ranking is what picks the moves; the labels only describe what was picked.
    #expect(club.map(\.ply) == [4, 3, 2])
    #expect(club.allSatisfy { $0.quality == .fine })
    #expect(club.allSatisfy { $0.lost < 50 })
}

@Test("the labels name a ranked move and never choose which moves are ranked")
func labelsNameButDoNotSelect() throws {
    var game = try played(opening)
    game.applyReview(
        [
            .centipawns(20),  // 1. e4   white lost 0    → 正常
            .centipawns(180),  // 1… e5   black lost 160  → 失误
            .centipawns(250),  // 2. Nf3  white gained 70 → 正常
            .centipawns(320),  // 2… Nc6  black lost 70   → 不精确
            .centipawns(-40),  // 3. Bb5  white lost 360  → 漏着
            .centipawns(-35),  // 3… a6   black lost 5    → 正常
        ],
        startEvaluation: .centipawns(20),
        depth: 18
    )
    let ranked = try #require(game.criticality())

    // Every ply is present, labelled or not.
    #expect(ranked.count == 6)
    #expect(Set(ranked.map(\.ply)) == Set(1...6))
    // And each label agrees with what the same Scores say through `quality(atPly:)`, which is
    // the absolute scale nothing here is allowed to reinterpret.
    for entry in ranked {
        #expect(entry.quality == game.quality(atPly: entry.ply))
    }
    #expect(ranked.first { $0.ply == 5 }?.quality == .blunder)
    #expect(ranked.first { $0.ply == 2 }?.quality == .mistake)
    #expect(ranked.first { $0.ply == 4 }?.quality == .inaccuracy)
    #expect(ranked.first { $0.ply == 1 }?.quality == .fine)
}

@Test("a move that gained is ranked too, at the bottom")
func gainedMovesAreStillRanked() throws {
    let ranked = try #require(try giveawayGame().criticality())
    // Four of these six moves improved their side's Score, and they are all in the list — at
    // the bottom of it, which is where a rank puts a good move.
    #expect(ranked.filter { $0.lost < 0 }.count == 4)
    #expect(ranked.last?.ply == 3)
    #expect(ranked.last?.lost == -10)

    // And in a game where nobody threw anything away, every move is still ranked.
    let drifting = try #require(try driftingGame().criticality())
    #expect(drifting.count == 6)
    #expect(drifting.first?.lost == 40)
    #expect(drifting.last?.lost == 5)
}

@Test("two equally bad moves are asked about in the order they were played")
func tiesBreakByWhenItHappened() throws {
    var game = try played(opening)
    // Both of White's later moves lose exactly 400.
    game.applyReview(
        [
            .centipawns(0),
            .centipawns(0),
            .centipawns(-400),
            .centipawns(-400),
            .centipawns(-800),
            .centipawns(-800),
        ],
        startEvaluation: .centipawns(0),
        depth: 18
    )
    let white = try #require(game.criticality(by: .white))
    #expect(white.map(\.lost) == [400, 400, 0])
    #expect(white.map(\.ply) == [3, 5, 1])
}

@Test("a game no Review has been over is refused, not ranked")
func unreviewedGamesAreRefused() throws {
    let game = try played(opening)
    #expect(!game.isReviewed)
    #expect(game.criticality() == nil)
    #expect(game.worstMoves() == nil)
    #expect(game.criticality(by: .white) == nil)
}

@Test("somebody else's engine numbers do not make a game rankable")
func importedScoresAreNotRankable() throws {
    let read = try PGN(
        parsing: """
            [Event "Rated blitz game"]
            [Result "1-0"]

            1. e4 {[%eval 0.24]} e5 {[%eval 0.31]} 2. Nf3 {[%eval -3.10]} 1-0
            """
    )
    // A three-pawn swing sitting right there in the file, and still no ranking: the Depth
    // those numbers came from is not written down, so comparing them invents mistakes.
    #expect(read.game.plies[2].importedEvaluation == .centipawns(-310))
    #expect(read.game.criticality() == nil)
}

@Test("a ranking survives being saved and read back")
func rankingRoundTripsThroughPGN() throws {
    let game = try giveawayGame()
    let reread = try PGN(parsing: PGN(game: game).text).game

    let before = try #require(game.criticality())
    let after = try #require(reread.criticality())
    #expect(before == after)
}

@Test("a ply the Review never reached is not ranked as harmless")
func unscoredPliesAreNotRanked() throws {
    var game = try giveawayGame()
    let continued = game.apply(uci: "b5a4")
    #expect(continued)

    let ranked = try #require(game.criticality())
    #expect(ranked.count == 6)
    #expect(ranked.contains { $0.ply == 7 } == false)
}

@Test("a reviewed game with no moves ranks nothing, and says so as an empty list")
func anEmptyGameIsNotARefusal() throws {
    var game = try played([])
    game.applyReview([Score?](), startEvaluation: .centipawns(20), depth: 18)
    #expect(game.criticality()?.isEmpty == true)
}

@Test("the move number a ply is written under follows the position the game started from")
func moveNumbersFollowTheStartingPosition() throws {
    let standard = try played(opening)
    #expect((1...6).map { standard.moveNumber(ofPly: $0) } == [1, 1, 2, 2, 3, 3])

    // A photographed position: Black to move, and the game was already 24 moves old.
    let midGame = try #require(
        Game(
            startFEN: "r1bq1rk1/pp2ppbp/2np2p1/8/3NP3/2N1BP2/PPPQ2PP/R3KB1R b KQ - 0 24",
            uciMoves: ["c6d4", "e3d4", "d8a5"]
        )
    )
    #expect(midGame.mover(ofPly: 1) == .black)
    #expect((1...3).map { midGame.moveNumber(ofPly: $0) } == [24, 25, 25])
}
