import ChessmirrorKit
import ChessmirrorKitTesting
import Testing

/// A game branches where a move is played over an earlier one, and the line that was there is
/// kept beside it and can be stepped back into (docs/adr/0043).

/// Plays UCI moves into a Game, failing the test rather than the run if one is illegal.
private func game(_ moves: [String], from startFEN: String = PGN.standardStartFEN) throws -> Game {
    try #require(Game(startFEN: startFEN, uciMoves: moves))
}

private func move(_ uci: String, in game: Game, atPly ply: Int) throws -> Move {
    try #require(game.rewound(to: ply)?.state.move(matching: uci))
}

/// Plays a move from an earlier Ply, failing the test rather than the run if it will not go.
private func play(_ uci: String, in game: inout Game, atPly ply: Int) throws {
    let played = game.play(try move(uci, in: game, atPly: ply), atPly: ply)
    try #require(played)
}

@Test("playing something else from an earlier ply keeps the line that was there")
func branchingRecordsWhatItReplaced() throws {
    var played = try game(["e2e4", "e7e5", "g1f3", "b8c6"])
    let branched = played.play(try move("f1c4", in: played, atPly: 2), atPly: 2)
    #expect(branched)
    #expect(played.plies.map(\.san) == ["e4", "e5", "Bc4"])

    let variations = played.variations(atPly: 2)
    #expect(variations.count == 1)
    #expect(variations.first?.map(\.san) == ["Nf3", "Nc6"])
    #expect(played.hasBranches)
}

@Test("playing the move that is already there is not a branch")
func replayingTheSameMoveDoesNotBranch() throws {
    var played = try game(["e2e4", "e7e5", "g1f3"])
    let again = played.play(try move("g1f3", in: played, atPly: 2), atPly: 2)
    #expect(again)
    #expect(played.plies.count == 3, "the line should be untouched")
    #expect(played.variations(atPly: 2).isEmpty)
    #expect(!played.hasBranches)
}

@Test("branching twice from one ply keeps both lines")
func twoBranchesFromOnePly() throws {
    var played = try game(["e2e4", "e7e5", "g1f3", "b8c6"])
    try play("f1c4", in: &played, atPly: 2)
    try play("d1h5", in: &played, atPly: 2)

    #expect(played.plies.map(\.san) == ["e4", "e5", "Qh5"])
    let lines = played.variations(atPly: 2).map { $0.map(\.san) }
    #expect(lines.count == 2)
    #expect(lines.contains(["Nf3", "Nc6"]))
    #expect(lines.contains(["Bc4"]))
}

@Test("a new line from an earlier ply is a 树枝; the line it was played over stays the 树干")
func branchingMarksTheNewLineAsABranch() throws {
    var played = try game(["e2e4", "e7e5", "g1f3", "b8c6"])
    try play("f1c4", in: &played, atPly: 2)
    #expect(played.plies[2].isTrunk == false)
    #expect(played.variations(atPly: 2).first?.first?.isTrunk == true)

    // And carrying on down the new line is still the 树枝: the trunk is one path.
    try play("b8c6", in: &played, atPly: 3)
    #expect(played.plies[3].isTrunk == false)

    let siblings = played.siblings(atPly: 2)
    #expect(siblings.map(\.number) == [1, 2])
    #expect(siblings[0].isTrunk && siblings[0].san == "Nf3")
    #expect(!siblings[1].isTrunk && siblings[1].san == "Bc4")
    #expect(siblings[1].variationIndex == nil, "Bc4 is the line on the board")

    // The scoresheet says where each half sits in the tree, which is what the record draws.
    let forked = try #require(played.scoresheet.first { $0.number == 2 }?.white)
    #expect(forked.isFork && forked.branchNumber == 2 && forked.siblingCount == 2 && !forked.isTrunk)
    let plain = try #require(played.scoresheet.first { $0.number == 1 }?.white)
    #expect(!plain.isFork && plain.isTrunk)
}

@Test("a 分支 can be taken as the line to carry on with")
func promotingAVariationSwapsTheLines() throws {
    var played = try game(["e2e4", "e7e5", "g1f3", "b8c6"])
    try play("f1c4", in: &played, atPly: 2)

    let promoted2 = played.promoteVariation(0, atPly: 2)

    #expect(promoted2)
    #expect(played.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6"])
    #expect(played.variations(atPly: 2).map { $0.map(\.san) } == [["Bc4"]])
    #expect(played.plies[2].isTrunk, "the 树干 is the 树干 again, on the board")
    // And the position is the one the promoted line reaches, not the one it left.
    #expect(played.state.fen.hasPrefix("r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R"))
}

@Test("what was said about a move goes with it into a 分支 and back")
func annotationsTravelWithTheLine() throws {
    var played = try game(["e2e4", "e7e5", "g1f3", "b8c6"])
    played.setJudgement(.init(drop: 3, score: .centipawns(20), depth: 18), atPly: 2)
    played.setTried([.init(san: "Qh5", drop: 30)], atPly: 3)
    try play("f1c4", in: &played, atPly: 2)

    let aside = try #require(played.variations(atPly: 2).first)
    #expect(aside[0].judgement?.drop == 3)
    #expect(aside[1].tried.map(\.san) == ["Qh5"])

    let promoted2 = played.promoteVariation(0, atPly: 2)

    #expect(promoted2)
    #expect(played.plies[2].judgement?.drop == 3)
    #expect(played.plies[3].tried.map(\.san) == ["Qh5"])
}

@Test("refusals made along a line ride with it into the 分支")
func refusalsGoWithTheLineTheyWereMadeOn() throws {
    var played = try game(["e2e4", "e7e5", "g1f3", "b8c6"])
    played.recordTried(.init(san: "Bc4", drop: 12), atPly: 1)
    played.recordTried(.init(san: "Qh5", drop: 31), atPly: 3)

    try play("d7d5", in: &played, atPly: 1)
    #expect(played.uciMoves == ["e2e4", "d7d5"])
    // The refusal at Ply 1 stays for the new move to take; the one at Ply 3 was made on the
    // line that left, and rides on the move that stood there — the same door it takes when the
    // player carries on down a line.
    #expect(played.pendingTried.map(\.ply) == [1])
    let aside = try #require(played.variations(atPly: 1).first)
    #expect(aside.map(\.san) == ["e5", "Nf3", "Nc6"])
    #expect(aside[2].tried.map(\.san) == ["Qh5"])

    // And back on the trunk, the 错招 is still there to be read.
    let promoted1 = played.promoteVariation(0, atPly: 1)
    #expect(promoted1)
    #expect(played.plies[3].tried.map(\.san) == ["Qh5"])
}

@Test("cycling the fork walks every sibling and comes back")
@MainActor
func cyclingTheForkWalksEverySibling() throws {
    let start = try game(["e2e4", "e7e5", "g1f3", "b8c6"])
    let session = GameSession.fresh(start)
    defer { session.suspend() }
    session.jump(toPly: 2)
    session.play(try #require(session.viewed.state.move(matching: "f1c4")))
    #expect(session.game.plies.map(\.san) == ["e4", "e5", "Bc4"])
    #expect(session.cursor == 3)
    #expect(session.forkPly == 2, "the eye is on the fork it just made")

    session.cycleFork(by: 1)
    #expect(session.game.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6"])
    #expect(session.cursor == 3, "the eye stays on the move at the fork")
    session.cycleFork(by: 1)
    #expect(session.game.plies.map(\.san) == ["e4", "e5", "Bc4"])
}

@Test("a game with branches survives a round trip through PGN")
func variationsRoundTripThroughPGN() throws {
    var played = try game(["e2e4", "e7e5", "g1f3", "b8c6", "f1b5"])
    try play("f1c4", in: &played, atPly: 2)
    // Carrying on down the new line, which is an append rather than another branch.
    try play("b8c6", in: &played, atPly: 3)

    let text = PGN(game: played, tags: [PGN.Tag("White", "甲"), PGN.Tag("Black", "乙")]).text
    #expect(text.contains("("), "the 分支 should be written in brackets")

    let reread = try PGN(parsing: text)
    #expect(reread.game.plies.map(\.san) == played.plies.map(\.san))
    #expect(
        reread.game.variations(atPly: 2).map { $0.map(\.san) }
            == played.variations(atPly: 2).map { $0.map(\.san) }
    )
    #expect(reread.game.state.fen == played.state.fen)
}

@Test("the 树干 stays the 树干 through the file, whichever line is on the board")
func theTrunkSurvivesARoundTripWithABranchOnTheBoard() throws {
    var played = try game(["e2e4", "e7e5", "g1f3", "b8c6"])
    try play("f1c4", in: &played, atPly: 2)
    try play("b8c6", in: &played, atPly: 3)

    let text = PGN(game: played).text
    #expect(text.contains("[%branch]"), "the file says where the line left the 树干")
    #expect(text.contains("[%trunk]"), "and which bracketed line the 树干 is")
    let reread = try PGN(parsing: text).game
    #expect(reread.plies.map(\.san) == ["e4", "e5", "Bc4", "Nc6"])
    #expect(reread.plies[2].isTrunk == false)
    #expect(reread.plies[3].isTrunk == false, "and everything after it on that line")
    #expect(reread.plies[1].isTrunk == true)
    #expect(reread.variations(atPly: 2).first?.map(\.isTrunk) == [true, true])
    #expect(reread.siblings(atPly: 2).map(\.san) == ["Nf3", "Bc4"], "树干 first, still")
}

@Test("judgements and refusals inside a 分支 come back with it")
func annotationsInsideAVariationRoundTrip() throws {
    var played = try game(["e2e4", "e7e5", "g1f3", "b8c6"])
    played.setJudgement(.init(drop: 3, score: .centipawns(20), depth: 18, intercept: 5), atPly: 2)
    played.setTried([.init(san: "Qh5", drop: 30, depth: 18, line: ["Nf6"])], atPly: 3)
    try play("f1c4", in: &played, atPly: 2)
    played.applyReview([.centipawns(18), nil, .centipawns(31)], startEvaluation: nil, depth: 14)

    let reread = try PGN(parsing: PGN(game: played).text).game
    #expect(reread.plies.first?.evaluation == .centipawns(18))
    #expect(reread.plies[2].evaluation == .centipawns(31))
    #expect(reread.reviewDepth == 14)
    let aside = try #require(reread.variations(atPly: 2).first)
    #expect(aside[0].judgement?.drop == 3)
    #expect(aside[0].judgement?.intercept == 5)
    #expect(aside[1].tried.first?.san == "Qh5")
    #expect(aside[1].tried.first?.line == ["Nf6"])
}

@Test("brackets a reader cannot place are ignored rather than fatal")
func strayBracketsAreTolerated() throws {
    // A 分支 before any move has nothing to be an alternative to.
    let pgn = try PGN(parsing: "[Event \"x\"]\n\n(1. d4) 1. e4 e5 2. Nf3 *\n")
    #expect(pgn.game.plies.map(\.san) == ["e4", "e5", "Nf3"])
    // And one that will not read is dropped whole, without taking the game with it.
    let broken = try PGN(parsing: "[Event \"x\"]\n\n1. e4 e5 (1... Ke7 Nf3) 2. Nf3 *\n")
    #expect(broken.game.plies.map(\.san) == ["e4", "e5", "Nf3"])
    #expect(broken.game.variations(atPly: 1).isEmpty)
}

@Test("a 分支 read from another program's PGN is kept, not dropped")
func foreignVariationsAreKept() throws {
    let text = """
        [Event "Test"]
        [Result "*"]

        1. e4 e5 2. Nf3 (2. Bc4 Nc6 3. Qh5) 2... Nc6 3. Bb5 *
        """
    let pgn = try PGN(parsing: text)
    #expect(pgn.game.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6", "Bb5"])
    #expect(pgn.game.variations(atPly: 2).map { $0.map(\.san) } == [["Bc4", "Nc6", "Qh5"]])
    #expect(pgn.game.plies[2].isTrunk, "the line the file is written as is the 树干")
    #expect(pgn.game.variations(atPly: 2).first?.map(\.isTrunk) == [false, false, false], "and its asides are 树枝")
    #expect(pgn.game.siblings(atPly: 2).map(\.san) == ["Nf3", "Bc4"], "so the written line is numbered first")
}

/// Contract: a game against the engine is answered wherever the player's move lands. Going back
/// and playing the move that is already on the record carries on down that line — and the line
/// has the opponent's reply on it, so that is what the board shows next. It used to stop one move
/// short, on the engine's turn with the engine saying nothing: 「对手方不自动走棋，虽然设置的还是引擎」.
@MainActor
@Test("replaying the move on the record is answered by the reply on the record")
func replayingTheRecordedMoveIsAnswered() throws {
    let session = GameSession.playing(try game(["e2e4", "e7e5", "g1f3", "b8c6"]))
    defer { session.suspend() }
    session.jump(toPly: 2)
    session.play(try #require(session.viewed.state.move(matching: "g1f3")))

    #expect(session.cursor == 4, "the opponent's reply is played, not left for the player")
    #expect(session.game.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6"], "down the line that was there")
    #expect(!session.game.hasBranches)
    #expect(session.isHandTurn)
}

/// The same through 把关: the move is weighed first, and the reply follows once it stands.
@MainActor
@Test("a replayed move that was weighed is answered too")
func aWeighedReplayIsAnswered() async throws {
    let line = try game(["e2e4", "e7e5", "g1f3", "b8c6"])
    let before = try #require(line.rewound(to: 2))
    let after = try #require(line.rewound(to: 3))
    let engine = ScriptedEngine([], byPosition: [
        before.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(20), uciMoves: ["g1f3"], san: ["Nf3"])
        ]),
        after.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(-20), uciMoves: ["b8c6"], san: ["Nc6"])
        ]),
    ])
    let session = GameSession.playing(line, engine: engine)
    defer { session.suspend() }
    session.jump(toPly: 2)
    session.play(try #require(session.viewed.state.move(matching: "g1f3")))
    await session.settled()

    #expect(session.cursor == 4)
    #expect(session.game.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6"])
    #expect(!session.game.hasBranches)
}

/// Browsing is not playing: stepping onto the engine's turn in the middle of a record moves
/// nothing, or a game could not be read.
@MainActor
@Test("browsing onto the opponent's turn plays nothing")
func browsingOntoTheOpponentsTurnPlaysNothing() throws {
    let session = GameSession.playing(try game(["e2e4", "e7e5", "g1f3", "b8c6"]))
    defer { session.suspend() }
    session.jump(toPly: 1)
    #expect(session.cursor == 1)
}
