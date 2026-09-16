@testable import ChessmirrorKit
import Foundation
import Testing
import ChessmirrorKitTesting

/// The 细判 of one move, crossed at the one seam it has: the engine. Nothing here stands up a
/// session, a drill or an exercise — those are three callers of this, and what they do with a
/// Weighing is their own test's business.
private func line(_ cp: Int, _ uci: String, _ san: String, more: [String] = []) -> Line {
    Line(score: .centipawns(cp), uciMoves: [uci] + more, san: [san] + more)
}

private func opening(_ uciMoves: [String] = []) throws -> Game {
    try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: uciMoves))
}

private func playing(_ uci: String, in game: Game) throws -> Game {
    var after = game
    let applied = after.apply(uci: uci)
    try #require(applied)
    return after
}

/// A move the first search had no Line for — here Nf3, where the engine listed e4 and d4 — is
/// weighed from the searches of both positions.
@MainActor
@Test func aMoveIsWeighedFromTheSearchesOfBothPositions() async throws {
    let before = try opening()
    let after = try playing("g1f3", in: before)
    let first = Analysis(depth: 18, lines: [line(30, "e2e4", "e4"), line(25, "d2d4", "d4")])
    let second = Analysis(depth: 20, lines: [line(20, "e7e5", "e5", more: ["Nf3", "Nc6"])])
    let engine = ScriptedEngine([], byPosition: [before.state.fen: first, after.state.fen: second])

    let weighed = try #require(await engine.weigh(after, from: before))

    #expect(weighed.mover == .white)
    #expect(weighed.before == first)
    #expect(weighed.scoreBefore == .centipawns(30))
    #expect(weighed.after == .centipawns(20))
    #expect(weighed.depth == 18, "the shallower of the two ends is the depth the comparison is worth")
    #expect(weighed.reply == ["e5", "Nf3", "Nc6"])
    #expect(weighed.drop == MoveQuality.drop(move: .white, before: .centipawns(30), after: .centipawns(20)))
    #expect(weighed.judgement == .init(drop: weighed.drop, score: .centipawns(20), depth: 18))
    #expect(engine.positions == [before.state.fen, after.state.fen])
}

@MainActor
@Test func aBlackMoveIsReadFromBlacksSide() async throws {
    let before = try opening(["e2e4"])
    let after = try playing("d7d5", in: before)
    let engine = ScriptedEngine([], byPosition: [
        before.state.fen: Analysis(depth: 20, lines: [line(30, "e7e5", "e5")]),
        after.state.fen: Analysis(depth: 20, lines: [line(80, "e4d5", "exd5")]),
    ])

    let weighed = try #require(await engine.weigh(after, from: before))

    #expect(weighed.mover == .black)
    #expect(weighed.drop > 0)
    #expect(weighed.drop == MoveQuality.drop(move: .black, before: .centipawns(30), after: .centipawns(80)))
}

@MainActor
@Test func aMoveIntoCheckmateIsSettledWithoutASecondSearch() async throws {
    let before = try opening(["f2f3", "e7e5", "g2g4"])
    let after = try playing("d8h4", in: before)
    #expect(after.state.outcome == .checkmate)
    let engine = ScriptedEngine([], byPosition: [
        before.state.fen: Analysis(depth: 15, lines: [line(-300, "d8h4", "Qh4#")]),
    ])

    let weighed = try #require(await engine.weigh(after, from: before))

    #expect(weighed.after == .mate(in: -1))
    #expect(weighed.depth == 15)
    #expect(weighed.reply.isEmpty)
    #expect(weighed.drop < 0)
    #expect(engine.positions == [before.state.fen])
}

@MainActor
@Test func aMoveIntoStalemateIsLevel() async throws {
    let before = try #require(Game(startFEN: "7k/8/6K1/5Q2/8/8/8/8 w - - 0 1"))
    let after = try playing("f5f7", in: before)
    #expect(after.state.outcome == .stalemate)
    let engine = ScriptedEngine([], byPosition: [
        before.state.fen: Analysis(depth: 20, lines: [Line(score: .mate(in: 3), uciMoves: ["f5g6"], san: ["Qg6"])]),
    ])

    let weighed = try #require(await engine.weigh(after, from: before))

    #expect(weighed.after == .centipawns(0))
    #expect(weighed.drop == 50)
    #expect(engine.positions == [before.state.fen])
}

@MainActor
@Test func theReplyIsCutToWhatABoardCarries() async throws {
    let before = try opening()
    let after = try playing("g1f3", in: before)
    let long = ["e5", "Nf3", "Nc6", "Bb5", "a6", "Ba4", "Nf6", "O-O"]
    let engine = ScriptedEngine([], byPosition: [
        before.state.fen: Analysis(depth: 20, lines: [line(30, "e2e4", "e4")]),
        after.state.fen: Analysis(depth: 20, lines: [Line(score: .centipawns(20), uciMoves: long, san: long)]),
    ])

    let weighed = try #require(await engine.weigh(after, from: before))

    #expect(weighed.reply == Array(long.prefix(Reply.limit)))
    #expect(weighed.reply.count < long.count)
}

@MainActor
@Test func progressHearsBothSearchesInTheOrderTheyRan() async throws {
    let before = try opening()
    let after = try playing("g1f3", in: before)
    let first = Analysis(depth: 18, lines: [line(30, "e2e4", "e4")])
    let second = Analysis(depth: 20, lines: [line(20, "e7e5", "e5")])
    let engine = ScriptedEngine([], byPosition: [before.state.fen: first, after.state.fen: second])

    var heard: [Weighing.Progress] = []
    _ = await engine.weigh(after, from: before) { heard.append($0) }

    #expect(heard.map(\.snapshot) == [first, second])
    #expect(heard.map(\.depth) == [18, 18], "the depth so far is the shallower end so far")
}

/// The one thing a 复判 varies is the budget: both ends are asked at it, and nothing else about
/// the judgement changes (docs/adr/0041).
@MainActor
@Test func theBudgetIsAskedOfBothEnds() async throws {
    let before = try opening()
    let after = try playing("g1f3", in: before)
    let engine = ScriptedEngine([], byPosition: [
        before.state.fen: Analysis(depth: 28, lines: [line(30, "e2e4", "e4")]),
        after.state.fen: Analysis(depth: 26, lines: [line(20, "e7e5", "e5")]),
    ])

    let weighed = try #require(await engine.weigh(after, from: before, budget: PositionSearches.deeper))

    // The store answers a position nobody has looked at everyday-first, then deeper; the deeper
    // ask is one per end, and the ends are the two positions of the move.
    #expect(engine.budgets.filter { $0 == PositionSearches.deeper }.count == 2)
    #expect(Array(NSOrderedSet(array: engine.positions)) as? [String] == [before.state.fen, after.state.fen])
    #expect(weighed.depth == 26)
    #expect(weighed.reply == ["e5"])
}

/// The shallower end is the depth whichever end it is: a deeper look at one side of a
/// comparison is not a deeper comparison.
@MainActor
@Test func theDepthIsTheShallowerEndWhicheverEndItIs() async throws {
    let before = try opening()
    let after = try playing("g1f3", in: before)
    let shallowFirst = ScriptedEngine([], byPosition: [
        before.state.fen: Analysis(depth: 16, lines: [line(30, "e2e4", "e4")]),
        after.state.fen: Analysis(depth: 24, lines: [line(20, "e7e5", "e5")]),
    ])
    let shallowSecond = ScriptedEngine([], byPosition: [
        before.state.fen: Analysis(depth: 24, lines: [line(30, "e2e4", "e4")]),
        after.state.fen: Analysis(depth: 16, lines: [line(20, "e7e5", "e5")]),
    ])

    #expect(try #require(await shallowFirst.weigh(after, from: before)).depth == 16)
    #expect(try #require(await shallowSecond.weigh(after, from: before)).depth == 16)
}

@MainActor
@Test func nothingKnownAboutThePositionPlayedFromIsNotAJudgement() async throws {
    let before = try opening()
    let after = try playing("e2e4", in: before)
    let silent = ScriptedEngine([])
    #expect(await silent.weigh(after, from: before) == nil)

    let paused = ScriptedEngine([Analysis(depth: 20, lines: [line(30, "e2e4", "e4")])])
    paused.pause()
    #expect(await paused.weigh(after, from: before) == nil)
}

@MainActor
@Test func aSecondSearchThatSaysNothingIsNotAJudgementEither() async throws {
    let before = try opening()
    let after = try playing("g1f3", in: before)
    // An opinion on the position played from, and silence on the one the move made: the two
    // ends of a comparison are both needed, and half of one is not a cheaper answer.
    let engine = ScriptedEngine([], byPosition: [
        before.state.fen: Analysis(depth: 20, lines: [line(30, "e2e4", "e4")]),
        after.state.fen: Analysis(depth: 20, lines: []),
    ])
    #expect(await engine.weigh(after, from: before) == nil)
}

@MainActor
@Test func aCancelledWeighingIsNil() async throws {
    let before = try opening()
    let after = try playing("e2e4", in: before)
    // An endless search: the engine keeps deepening until the listener goes away.
    let engine = ScriptedEngine([Analysis(depth: 12, lines: [line(30, "e2e4", "e4")])], isEndless: true)

    let weighing = Task { @MainActor in await engine.weigh(after, from: before) }
    weighing.cancel()

    #expect(await weighing.value == nil)
}

@Test func aWeighingNeedsALineToBeMeasuredFrom() {
    let blank = Analysis(depth: 20, lines: [])
    #expect(Weighing(mover: .white, before: blank, after: .centipawns(0), depth: 20) == nil)
    let known = Analysis(depth: 20, lines: [line(0, "e2e4", "e4")])
    #expect(Weighing(mover: .white, before: known, after: .centipawns(0), depth: 20) != nil)
}

@Test func aFinishedPositionHasItsScoreWithoutASearch() throws {
    let fools = try opening(["f2f3", "e7e5", "g2g4", "d8h4"])
    #expect(fools.state.outcomeScore == .mate(in: -1))
    let scholars = try opening(["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6", "h5f7"])
    #expect(scholars.state.outcomeScore == .mate(in: 1))
    let stalemate = try #require(Game(startFEN: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"))
    #expect(stalemate.state.outcomeScore == .centipawns(0))
    #expect(try opening().state.outcomeScore == nil)
}

/// A move the first search has a Line for is weighed from that Line — Score, depth and 应招 all
/// from the one search (docs/adr/0016) — and the engine's own first choice is 最佳, costing
/// exactly nothing. Only a move outside the Lines needs the position it made searched.
@MainActor
@Test func aMoveInTheEnginesOwnLinesIsWeighedFromThatSearch() async throws {
    let before = try opening()
    let first = Analysis(depth: 18, lines: [
        line(30, "e2e4", "e4", more: ["e5", "Nf3"]), line(20, "d2d4", "d4", more: ["d5"]),
    ])
    let e4 = try playing("e2e4", in: before)
    let d4 = try playing("d2d4", in: before)
    let h4 = try playing("h2h4", in: before)
    let second = Analysis(depth: 20, lines: [line(-10, "e7e5", "e5", more: ["Nf3"])])
    let engine = ScriptedEngine([], byPosition: [
        before.state.fen: first, e4.state.fen: second, d4.state.fen: second, h4.state.fen: second,
    ])

    let best = try #require(await engine.weigh(e4, from: before))
    #expect(best.isBest)
    #expect(best.drop == 0)
    #expect(best.after == .centipawns(30))
    #expect(best.depth == 18, "the first search's depth: nothing else was searched")
    #expect(best.reply == ["e5", "Nf3"], "the 应招 is the rest of its own Line")
    #expect(best.move == "e2e4")

    let secondBest = try #require(await engine.weigh(d4, from: before))
    #expect(!secondBest.isBest)
    #expect(secondBest.after == .centipawns(20), "its own Line's Score, from the same search")
    #expect(secondBest.reply == ["d5"])
    #expect(engine.positions.filter { $0 == e4.state.fen || $0 == d4.state.fen }.isEmpty,
        "neither position the moves made was searched")

    let outside = try #require(await engine.weigh(h4, from: before))
    #expect(!outside.isBest)
    #expect(outside.after == .centipawns(-10), "a move the search had no Line for is searched")
    #expect(outside.depth == 18, "two ends, and the first is the shallower")
    #expect(outside.reply == ["e5", "Nf3"])
    #expect(engine.positions.contains(h4.state.fen))
}
