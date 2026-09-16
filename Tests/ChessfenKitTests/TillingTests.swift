@testable import ChessfenKit
import Foundation
import Testing

/// Contract: 正着 weighs a move wherever the eye is standing. A saved game reopens at its first
/// position, so "play the first move again" is the ordinary way a person meets the board — and it
/// used to be the one way 正着 said nothing at all.
@MainActor
@Test func aMovePlayedFromAnEarlierPositionIsStillWeighed() async throws {
    let start = try #require(Game(startFEN: PGN.standardStartFEN))
    let played = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["d2d4"]))
    let afterF3 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3"]))
    let engine = ScriptedEngine([], byPosition: [
        start.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"]),
            .init(score: .centipawns(-20), uciMoves: ["g1f3"], san: ["Nf3"]),
        ]),
        afterF3.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(-300), uciMoves: ["e7e5"], san: ["e5"])
        ]),
    ])
    let session = GameSession.fresh(played, engine: engine)
    defer { session.suspend() }
    session.setIntercept(JudgementLines.defaultIntercept)
    await session.waitForPreparedInterception()
    session.jump(toPly: 0)
    await session.waitForPreparedInterception()
    try #require(!session.isAtLatest, "the eye is on the first position, not the end")

    session.play(try #require(start.state.move(matching: "f2f3")))
    await session.waitForJudgement()

    #expect(session.refused?.san == "f3", "a move played in 正着 mode is weighed from anywhere")
    #expect(session.game.plies.map(\.san) == ["d4"], "and a refusal leaves the game it was reading alone")
}

/// Contract: a move played from an earlier Ply that *passes* is written down like any other. The
/// refusal case is the loud one; this is the one that would go unnoticed — a move that stands with
/// no judgement and no percentage beside it, which is 正着 switched on and saying nothing.
@MainActor
@Test func aMovePlayedFromAnEarlierPositionIsJudgedWhenItPasses() async throws {
    let start = try #require(Game(startFEN: PGN.standardStartFEN))
    let played = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["d2d4"]))
    let afterE4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
    let engine = ScriptedEngine([], byPosition: [
        start.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
        ]),
        afterE4.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(10), uciMoves: ["e7e5"], san: ["e5"])
        ]),
    ])
    let session = GameSession.fresh(played, engine: engine)
    defer { session.suspend() }
    session.setIntercept(JudgementLines.defaultIntercept)
    await session.waitForPreparedInterception()
    session.jump(toPly: 0)
    await session.waitForPreparedInterception()
    try #require(!session.isAtLatest)

    session.play(try #require(start.state.move(matching: "e2e4")))
    await session.waitForJudgement()

    #expect(session.refused == nil, "a move that costs a hair stands")
    #expect(session.game.plies.map(\.san) == ["e4"], "and it replaces what was there")
    let judgement = try #require(session.game.plies.first?.judgement, "but it was weighed")
    #expect(judgement.depth == 20)
    #expect(session.moveChange != nil, "and the screen has a percentage to show")
}

/// Contract: a refusal is recorded where it happened, wherever in the game that is. Playing a
/// wrong move from a position in the middle of a game and walking away used to lose it three
/// times over: no mark on the record, no 错题 in the row, and nothing in the file — because the
/// refusals were written as if they belonged to the end of the game.
@MainActor
@Test func aRefusalInTheMiddleOfAGameIsRecordedThere() async throws {
    let start = try #require(Game(startFEN: PGN.standardStartFEN))
    let played = try #require(
        Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6"])
    )
    let afterBad = try #require(
        Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "f1c4"])
    )
    let engine = ScriptedEngine([], byPosition: [
        // The position two Plies in, which is where the player will try the bad move from.
        (try #require(played.rewound(to: 2))).state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(0), uciMoves: ["g1f3"], san: ["Nf3"])
        ]),
        afterBad.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(-400), uciMoves: ["g8f6"], san: ["Nf6"])
        ]),
    ])
    let session = GameSession.fresh(played, engine: engine)
    session.setIntercept(JudgementLines.defaultIntercept)
    session.jump(toPly: 2)
    await session.waitForPreparedInterception()
    let twoPliesIn = try #require(played.rewound(to: 2))

    session.play(try #require(twoPliesIn.state.move(matching: "f1c4")))
    await session.waitForJudgement()
    #expect(session.refused?.san == "Bc4")
    #expect(session.game.uciMoves == played.uciMoves, "the game is untouched")
    #expect(session.game.pendingTried.map(\.ply) == [2], "and the refusal belongs to Ply 2")
    #expect(session.cursor == 2, "with the eye left where the move was played")

    // The row under the board: a 错题 at that position, marked at that position.
    let slip = try #require(session.slips.first)
    #expect(slip.positionPly == 2)
    #expect(slip.wrong.map(\.san) == ["Bc4"])

    // And it is in the file, at the position rather than at the end of the movetext.
    let read = try PGN(parsing: session.pgn.text).game
    #expect(read.pendingTried.map(\.ply) == [2])
    #expect(read.pendingTried.first?.tries.first?.san == "Bc4")
    #expect(read.slips(by: [.white], lines: .standard).map(\.positionPly) == [2])
}

/// Contract: the real session prepares, refuses twice, toggles and revisits a position.
/// All consumers must share one ten-second search per position, including the refused board.
@MainActor
@Test func repeatedPositionIsSearchedOnlyOnce() async throws {
    let start = try #require(Game(startFEN: PGN.standardStartFEN))
    let after = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3"]))
    let engine = ScriptedEngine([], byPosition: [
        start.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])]),
        after.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(-300), uciMoves: ["e7e5"], san: ["e5"])])
    ])
    let session = GameSession.fresh(start, engine: engine)
    defer { session.suspend() }
    session.setIntercept(5)
    await session.waitForPreparedInterception()
    for _ in 0..<2 {
        session.play(try #require(start.state.move(matching: "f2f3")))
        await session.waitForJudgement()
        // A refusal leaves the moves alone; what it writes down is the 试招 itself (docs/adr/0037).
        #expect(session.game.uciMoves == start.uciMoves)
        #expect(session.refused?.san == "f3")
    }
    #expect(session.pendingAttempts.count == 2)
    session.setTilling(false)
    await session.waitForPreparedInterception()
    session.setTilling(true)
    await session.waitForPreparedInterception()
    session.jump(toPly: 0)
    await session.waitForPreparedInterception()
    #expect(engine.positions.filter { $0 == start.state.fen }.count == 1)
    #expect(engine.positions.filter { $0 == after.state.fen }.count == 1)
    #expect(engine.budgets.allSatisfy { $0 == PositionSearches.budget })
}

/// Contract: the search that refuses a move is the one that knows the answer to it. The position
/// the move made is off the board the moment it is taken back, so the 应招 has to be kept with
/// the move rather than looked up later (docs/adr/0034).
@MainActor
@Test func aRefusedMoveKeepsTheReplyItEarned() async throws {
    let start = try #require(Game(startFEN: PGN.standardStartFEN))
    let after = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3"]))
    let engine = ScriptedEngine([], byPosition: [
        start.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
        ]),
        after.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(-300), uciMoves: ["e7e5", "d2d4"], san: ["e5", "d4"])
        ]),
    ])
    let session = GameSession.fresh(start, engine: engine)
    defer { session.suspend() }
    session.setIntercept(5)
    await session.waitForPreparedInterception()
    session.play(try #require(start.state.move(matching: "f2f3")))
    await session.waitForJudgement()

    let tried = try #require(session.pendingAttempts.first)
    #expect(tried.san == "f3")
    #expect(tried.line == ["e5", "d4"])
    // Nothing new was searched to keep it: the answer the refusal already got carried the Line.
    #expect(engine.positions.filter { $0 == after.state.fen }.count == 1)
    // And it is drawn from the position the move was refused in, which is the one on the board.
    let arrows = Reply.arrows(
        in: try #require(session.refusedPosition), playing: Reply.moves(of: tried)
    )
    #expect(arrows.map(\.step) == [1, 2, 3])
    #expect(arrows.map(\.isYours) == [true, false, true])
}

/// Contract: a 试招 written down before replies were kept still has one to show, out of the
/// shared bounded position search — the same search the refusal itself paid for.
@MainActor
@Test func aReplyIsAskedForOnlyWhenTheFileKeptNone() async throws {
    let start = try #require(Game(startFEN: PGN.standardStartFEN))
    let after = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3"]))
    let engine = ScriptedEngine([], byPosition: [
        start.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
        ]),
        after.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(-300), uciMoves: ["e7e5", "d2d4"], san: ["e5", "d4"])
        ]),
    ])
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
    game.setTried([.init(san: "f3", drop: 20)], atPly: 0)
    let session = GameSession.fresh(game, engine: engine)
    defer { session.suspend() }
    let tried = try #require(session.visibleAttempts.first)
    #expect(tried.line.isEmpty)
    #expect(await session.reply(for: tried) == ["e5", "d4"])
    #expect(engine.positions.filter { $0 == after.state.fen }.count == 1)

    // A 试招 that already carries its 应招 is answered without touching the engine at all.
    let searches = engine.searchCount
    let kept = Game.Ply.Tried(san: "f3", drop: 20, line: ["e5"])
    #expect(await session.reply(for: kept) == ["e5"])
    #expect(engine.searchCount == searches)
}

/// Contract: hold the resulting position at depth 19. Neither side can move and no
/// opponent clock may start. Only depth 20 can publish the percentage and release or refuse.
@MainActor
@Test(arguments: [true, false], [12, 20])
func opponentWaitsForOneCompletedSearch(_ enabled: Bool, _ finalDepth: Int) async throws {
    let score = -300
    let start = try #require(Game(startFEN: PGN.standardStartFEN))
    let after = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
    let gate = AsyncStream<Analysis>.makeStream()
    let requested = AsyncStream<Void>.makeStream()
    let engine = ScriptedEngine([Analysis(depth: 20, lines: [
        .init(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
    ])], byPosition: [after.state.fen: Analysis(depth: 20, lines: [
        .init(score: .centipawns(score), uciMoves: ["e7e5"], san: ["e5"])
    ])], controlled: { game, budget in
        guard game.state.fen == after.state.fen, budget == PositionSearches.budget else { return nil }
        requested.continuation.yield(())
        requested.continuation.finish()
        return gate.stream
    })
    let session = GameSession.fresh(start, controllers: [.white: .hand, .black: .engine], engine: engine)
    session.showPositionFeedback()
    session.setTilling(enabled)
    defer { gate.continuation.finish(); session.suspend() }
    session.play(try #require(start.state.move(matching: "e2e4")))
    var request = requested.stream.makeAsyncIterator()
    _ = await request.next()
    gate.continuation.yield(Analysis(depth: finalDepth - 1, lines: [
        .init(score: .centipawns(score), uciMoves: ["e7e5"], san: ["e5"])
    ]))
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while session.searchProgress?.depth != finalDepth - 1, ContinuousClock.now < deadline { await Task.yield() }
    try #require(session.searchProgress?.depth == finalDepth - 1, "the judgement must consume the held intermediate result")
    #expect(session.isWeighing)
    #expect(!session.isHandTurn)
    #expect(!session.isEngineTurn)
    #expect(!session.canPlayBestMove)
    #expect(session.moveChange == nil)
    #expect(engine.budgets.allSatisfy { $0 == PositionSearches.budget })
    gate.continuation.yield(Analysis(depth: finalDepth, lines: [
        .init(score: .centipawns(score), uciMoves: ["e7e5"], san: ["e5"])
    ]))
    gate.continuation.finish()
    await session.waitForJudgement()
    #expect(!session.isWeighing)
    if enabled && score < 0 {
        #expect(session.game.uciMoves == start.uciMoves)
        #expect(session.refused?.san == "e4")
        #expect(engine.budgets.allSatisfy { $0 == PositionSearches.budget })
    } else {
        #expect(session.game.plies.first?.judgement?.depth == finalDepth)
        #expect(session.game.plies.first?.judgement?.score == .centipawns(score))
        await session.waitForPreparedInterception()
        #expect(session.game.uciMoves == ["e2e4", "e7e5"])
        #expect(engine.positions.filter { $0 == after.state.fen }.count == 1, "opponent reuses the adjudication's best reply")
    }
}

@MainActor
@Test(arguments: [-133, 133])
func moveChangeUsesTheSameTwoScoresAsTheBar(_ score: Int) async throws {
    let start = try #require(Game(startFEN: PGN.standardStartFEN))
    var after = start
    let applied = after.apply(uci: "e2e4")
    #expect(applied)
    let reply = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
    let engine = ScriptedEngine([], byPosition: [
        start.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])]),
        after.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(score), uciMoves: [], san: [])]),
        reply.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(2 * score), uciMoves: [], san: [])])
    ])
    let session = GameSession.fresh(start, engine: engine)
    session.showPositionFeedback()
    defer { session.suspend() }
    #expect(session.moveChange == nil)
    session.play(try #require(start.state.move(matching: "e2e4")))
    await session.waitForJudgement()
    await session.measureLatestMoveChange()
    let change = try #require(session.moveChange)
    #expect(change.before == .centipawns(0))
    #expect(change.after == .centipawns(score))
    #expect(session.feedbackScore == change.after)
    #expect(abs(change.percent(for: .white) - (Score.centipawns(score).winPercent - 50)) < 0.001)
    #expect(change.percent(for: .black) == -change.percent(for: .white))
    session.jump(toPly: 0)
    #expect(session.moveChange == nil, "reading an old position is not a newly played move")
    #expect(session.historyScore(atPly: 1) == change.after, "the curve still reaches the last move")
    #expect(session.historyScore(atPly: 0) == change.before)
    session.jump(toPly: 1)
    #expect(session.moveChange == change)
    session.play(try #require(session.game.state.move(matching: "e7e5")))
    #expect(session.moveChange == nil, "the old badge must not describe a new move")
    await session.waitForJudgement()
    await session.measureLatestMoveChange()
    #expect(session.game.plies.count == 2)
    #expect(session.historyScore(atPly: 2) == .centipawns(2 * score))
    #expect(session.historyScore(atPly: 1) == .centipawns(score))
    #expect(session.moveChange?.before == change.after)
    session.jump(toPly: 0)
    #expect(session.historyScore(atPly: 2) == .centipawns(2 * score))
}

/// Contract: toggling interception remembers its threshold, keeps the badge under the board on,
/// survives a real PGN file round trip while OFF, and never changes the game.
@MainActor
@Test func tillingToggleRemembersItsThreshold() throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let session = GameSession.fresh(game)
    session.setTilling(true)
    #expect(session.isTilling)
    #expect(session.lines.intercept == 5)
    session.setIntercept(37)
    session.setTilling(false)
    #expect(!session.isTilling)
    #expect(session.hasTillingFeedback)
    #expect(session.preferredIntercept == 37)
    #expect(session.game.uciMoves == game.uciMoves)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "off.pgn")
    try session.pgn.text.write(to: file, atomically: true, encoding: .utf8)
    let saved = try PGN(parsing: String(contentsOf: file, encoding: .utf8))
    #expect(saved.tag("Intercept") == nil)
    let reopened = try #require(GameSession.opened(.init(url: file, pgn: saved, modified: Date())))
    #expect(!reopened.isTilling)
    reopened.setTilling(true)
    #expect(reopened.isTilling)
    #expect(reopened.lines.intercept == 37)
    #expect(reopened.pgn.tag("InterceptPreference") == nil, "active threshold has only one authoritative tag")
    #expect(reopened.game == game)
}

/// A real post-move depth-20 judgement, followed by an opponent reply on its own clock.
@MainActor
@Test func realPreparedMoveWaitsForThePlayedPositionBeforeTheOpponentSearch() async throws {
    let engine = try EngineService(
        bigNetURL: Nets.big, smallNetURL: Nets.small,
        configuration: .init(threads: 2, hashMegabytes: 32, multiPV: 1)
    )
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let session = GameSession.fresh(game, controllers: [.white: .hand, .black: .engine], engine: engine)
    defer { session.suspend() }
    session.setIntercept(10)
    await session.waitForPreparedInterception()
    try #require((session.searchProgress?.depth ?? 0) > 0)
    let started = ContinuousClock.now
    session.play(try #require(game.state.move(matching: "e2e4")))
    let gateTime = started.duration(to: .now)
    try #require(session.isWeighing, "the resulting position still needs its own depth-20 judgement")
    #expect(!session.isEngineTurn)
    #expect(session.game.uciMoves == ["e2e4"])
    await session.waitForJudgement()
    await session.waitForPreparedInterception()
    #expect(session.game.plies.count == 2)
    let judgement = try #require(session.game.plies[0].judgement)
    #expect((1...20).contains(judgement.depth))
    #expect(judgement.drop < 10)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "judged.pgn")
    try session.pgn.text.write(to: file, atomically: true, encoding: .utf8)
    let reopened = try PGN(parsing: String(contentsOf: file, encoding: .utf8))
    #expect(reopened.game.plies[0].judgement == judgement)
    #expect(reopened.game.reviewDepth == nil, "live judgements must not pretend to be a full Review")
    #expect(reopened.game.rewound(to: 1)?.plies[0].judgement == judgement)
    print("REAL INTERCEPT: cached e4 committed in \(gateTime); opponent replied in \(started.duration(to: .now)) on a 1-second clock")
    session.suspend()
    let oldGame = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: session.game.uciMoves))
    let legacy = GameSession.fresh(oldGame, controllers: [.white: .hand, .black: .engine])
    legacy.setIntercept(JudgementLines.defaultIntercept)
    legacy.attach(engine: engine, library: nil)
    defer { legacy.suspend() }
    #expect(legacy.game.plies[0].judgement == nil)
    await legacy.fillMissingTillingJudgements()
    #expect(legacy.game != oldGame)
    #expect(legacy.game.uciMoves == oldGame.uciMoves)
    // The same measurement — but measured after the fact, so it stood under nothing: a move
    // nobody weighed before it was played did not stand under 正着 (docs/adr/0038).
    let measured = Game.Ply.Judgement(
        drop: judgement.drop, score: judgement.score, depth: judgement.depth
    )
    #expect(legacy.game.plies[0].judgement == measured)
    #expect(legacy.game.plies[0].judgement?.stoodUnderNoSlips == false)
    #expect(legacy.game.plies[1].judgement == nil, "only the person's moves are backfilled")
    let filled = legacy.game
    await legacy.fillMissingTillingJudgements()
    #expect(legacy.game == filled)
}

@MainActor
@Test func incompleteJudgementDoesNotLetAMoveStand() async throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    var played = game
    let applied = played.apply(uci: "f2f3")
    try #require(applied)
    let engine = ScriptedEngine([Analysis(depth: 20, lines: [
        Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
    ])], byPosition: [played.state.fen: Analysis(depth: 19, lines: [
        Line(score: .centipawns(-300), uciMoves: ["e7e5"], san: ["e5"])
    ], isPartial: true)])
    let session = GameSession.fresh(game, engine: engine)
    defer { session.suspend() }
    session.setIntercept(10)
    await session.waitForPreparedInterception()
    session.play(try #require(game.state.move(matching: "f2f3")))
    await session.waitForJudgement()
    #expect(session.game.uciMoves == game.uciMoves)
    #expect(session.game.uciMoves.isEmpty)
    #expect(session.refused == nil)
    #expect(!session.pgn.text.contains("%tried"))
    #expect(engine.budgets.allSatisfy { $0 == PositionSearches.budget })
}

@MainActor
@Test func unlistedCheckmateCommitsWithoutSearchingTerminalBoard() async throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN,
                                uciMoves: ["f2f3", "e7e5", "g2g4"]))
    let engine = ScriptedEngine([Analysis(depth: 20, lines: [
        Line(score: .centipawns(-300), uciMoves: ["b8c6"], san: ["Nc6"])
    ])])
    let session = GameSession.fresh(game, engine: engine)
    defer { session.suspend() }
    session.setIntercept(10)
    await session.waitForPreparedInterception()
    let searches = engine.searchCount
    session.play(try #require(game.state.move(matching: "d8h4")))
    await session.waitForJudgement()
    #expect(session.game != game)
    #expect(session.game.state.outcome == .checkmate)
    #expect(session.game.plies.last?.san == "Qh4#")
    #expect(session.refused == nil)
    #expect(engine.searchCount == searches)
}

@MainActor
@Test func unlistedLosingMoveIsNeverSearchedAgainForConfirmation() async throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    var after = game
    let applied = after.apply(uci: "f2f3")
    #expect(applied)
    let engine = ScriptedEngine([Analysis(depth: 20, lines: [
        Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
    ])], byPosition: [after.state.fen: Analysis(depth: 20, lines: [
        Line(score: .centipawns(-300), uciMoves: ["e7e5"], san: ["e5"])
    ])])
    let session = GameSession.fresh(game, engine: engine)
    defer { session.suspend() }
    session.setIntercept(10)
    await session.waitForPreparedInterception()
    session.play(try #require(game.state.move(matching: "f2f3")))

    await session.waitForJudgement()
    #expect(!session.isWeighing)
    #expect(session.refused?.san == "f3")
    #expect(session.game.uciMoves == game.uciMoves)
    #expect(engine.budgets.last == PositionSearches.budget)
    #expect(engine.budgets.count == 2)
}

@MainActor
@Test func browsingKeepsHintLayersAtTheirOwnPosition() throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
    let session = GameSession.fresh(game)
    session.setIntercept(10)
    session.requestHint()
    session.requestHint()
    session.requestHint()
    session.relaxIntercept(to: 20)
    session.jumpToStart()
    #expect(session.hintLayer == 0)
    #expect(session.relaxedIntercept == nil)
    session.jumpToLatest()
    #expect(session.hintLayer == 3)
    #expect(session.relaxedIntercept == 20)
    #expect(session.game.uciMoves == game.uciMoves)
}

@MainActor
@Test func revealingAfterARefusalKeepsExactlyOneEncounter() async throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let after = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["d2d4"]))
    let engine = ScriptedEngine([Analysis(depth: 20, lines: [
        Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"]),
        Line(score: .centipawns(-300), uciMoves: ["d2d4"], san: ["d4"]),
    ])], byPosition: [after.state.fen: Analysis(depth: 20, lines: [
        Line(score: .centipawns(-300), uciMoves: ["e7e5"], san: ["e5"])
    ])])
    let session = GameSession.fresh(game, engine: engine)
    defer { session.suspend() }
    session.setIntercept(10)
    session.play(try #require(game.state.move(matching: "d2d4")))

    await session.waitForJudgement()
    #expect(!session.isWeighing)
    #expect(session.refused?.san == "d4")
    #expect(session.game.uciMoves == game.uciMoves)
    session.revealTillingMove()
    #expect(session.game.uciMoves == game.uciMoves, "Reveal requires all three explicit hint requests")
    for _ in 0..<3 { session.requestHint() }
    session.revealTillingMove()
    await session.waitForJudgement()
    #expect(session.game.uciMoves == ["e2e4"])
    #expect(session.hintLayer == 0)
    #expect(session.relaxedIntercept == nil)
    let pgn = try PGN(parsing: session.pgn.text)
    #expect(pgn.game.plies[0].hints == 3)
    let book = MistakeBook.derive(from: [GameLibrary.Entry(
        url: URL(filePath: "/games/reveal.pgn"), pgn: pgn, modified: Date()
    )])
    let mistake = try #require(book.mistakes.first)
    #expect(mistake.encounters.count == 1)
    #expect(mistake.encounters[0].played == "d4")
    #expect(mistake.encounters[0].notFound)
}

@MainActor
@Test func hintLadderAndRelaxationBelongToOneMove() async throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let after = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["d2d4"]))
    let engine = ScriptedEngine([Analysis(depth: 20, lines: [
        Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"]),
        Line(score: .centipawns(-180), uciMoves: ["d2d4"], san: ["d4"]),
    ])], byPosition: [after.state.fen: Analysis(depth: 20, lines: [
        Line(score: .centipawns(-180), uciMoves: ["e7e5"], san: ["e5"])
    ])])
    let session = GameSession.fresh(game, engine: engine)
    defer { session.suspend() }
    session.setIntercept(10)

    await session.waitForPreparedInterception()
    #expect(session.searchProgress?.depth == 20)
    #expect(session.hintLayer == 0)
    #expect(session.hintScore == nil)
    session.relaxIntercept(to: 20)
    #expect(session.relaxedIntercept == nil)
    session.requestHint()
    #expect(session.hintLayer == 1)
    #expect(session.hintScore == .centipawns(0))
    session.requestHint()
    #expect(session.hintLayer == 2)
    session.requestHint()
    session.relaxIntercept(to: 20)
    #expect(session.relaxedIntercept == 20)
    session.play(try #require(game.state.move(matching: "d2d4")))
    #expect(session.game.uciMoves == ["d2d4"])
    await session.waitForJudgement()
    #expect(session.hintLayer == 0)
    #expect(session.relaxedIntercept == nil)
    #expect(session.lines.intercept == 10)
    let read = try PGN(parsing: session.pgn.text)
    #expect(read.game.plies[0].hints == 3)
    #expect(read.game.plies[0].tried.count == 1)
    #expect(read.game.plies[0].tried.first?.notFound == true)
    let book = MistakeBook.derive(from: [GameLibrary.Entry(
        url: URL(filePath: "/games/relaxed.pgn"), pgn: read, modified: Date()
    )])
    #expect(book.mistakes.count == 1)
    #expect(book.mistakes.first?.encounters.first?.notFound == true)
}

@MainActor
@Test func preparedPassingMoveStillJudgesTheResultingPosition() async throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let engine = ScriptedEngine([Analysis(depth: 20, lines: [
        Line(score: .centipawns(20), uciMoves: ["e2e4"], san: ["e4"]),
        Line(score: .centipawns(10), uciMoves: ["d2d4"], san: ["d4"]),
    ])])
    let session = GameSession.fresh(game, engine: engine)
    defer { session.suspend() }
    session.setIntercept(10)

    await session.waitForPreparedInterception()
    #expect(session.searchProgress?.depth == 20)
    let started = ContinuousClock.now
    session.play(try #require(game.state.move(matching: "d2d4")))
    let elapsed = started.duration(to: .now)
    #expect(session.game.uciMoves == ["d2d4"])
    #expect(session.isWeighing)
    await session.waitForJudgement()
    #expect(!session.isWeighing)
    #expect(session.game.plies.first?.judgement?.depth == 20)
    #expect(engine.budgets.allSatisfy { $0 == PositionSearches.budget })
    #expect(engine.positions.contains(session.game.state.fen), "the resulting position gets its own search")
    print("Prepared passing move committed in \(elapsed)")
}

@MainActor
@Test(arguments: [0.0, 5.0, 7.0, 37.0, 100.0])
func interceptionSettingSurvivesReopening(_ line: Double) throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
    let session = GameSession.fresh(game)
    session.setIntercept(line)
    #expect(session.isTilling)
    let pgn = try PGN(parsing: session.pgn.text)
    let opened = try #require(GameSession.opened(GameLibrary.Entry(
        url: URL(filePath: "/games/tilling.pgn"), pgn: pgn, modified: Date()
    )))
    #expect(opened.lines.intercept == line)
    opened.setIntercept(.nan)
    #expect(opened.lines.intercept == line)
    opened.setIntercept(101)
    #expect(opened.lines.intercept == line)
    opened.setIntercept(nil)
    #expect(!opened.isTilling)
    #expect(opened.pgn.tag("Intercept") == nil)
}

/// Contract: real Stockfish judges Fool's Mate → session restores the board → a legal retry
/// stands → PGN retains the refused move once. The disabled setting must allow the same blunder.
@MainActor
@Test func tillingRejectsMateAndPreservesTheRetry() async throws {
    let engine = try EngineService(
        bigNetURL: Nets.big, smallNetURL: Nets.small,
        configuration: .init(threads: 2, hashMegabytes: 32, multiPV: 1)
    )
    let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3", "e7e5"]))
    let session = GameSession.fresh(game, engine: engine)
    defer { session.suspend() }
    session.setIntercept(10)
    let blunder = try #require(game.state.move(matching: "g2g4"))
    session.play(blunder)
    #expect(session.isWeighing)

    await session.waitForJudgement()
    #expect(!session.isWeighing, "Stockfish must finish judging within 30 seconds")
    #expect(session.game.uciMoves == game.uciMoves, "the rejected move must restore the entire game")
    #expect(try #require(session.refused).san == "g4")
    #expect(session.refused!.drop >= 10)

    // Switching interception off lets a retry stand, while preserving the earlier refusal.
    session.setIntercept(nil)
    session.play(try #require(game.state.move(matching: "e2e4")))
    await session.waitForJudgement()
    #expect(session.game.uciMoves == ["f2f3", "e7e5", "e2e4"])
    let read = try PGN(parsing: session.pgn.text)
    #expect(read.game.plies.last?.tried.count == 1)
    #expect(read.game.plies.last?.tried.first?.san == "g4")

    let disabled = GameSession.fresh(game, engine: engine)
    defer { disabled.suspend() }
    disabled.play(blunder)
    #expect(!disabled.isWeighing)
    #expect(disabled.game.uciMoves.last == "g2g4")
    #expect(disabled.refused == nil)
}

@MainActor
@Test func suspendingTillingRestoresTheUnjudgedPosition() async throws {
    let engine = try EngineService(
        bigNetURL: Nets.big, smallNetURL: Nets.small,
        configuration: .init(threads: 1, hashMegabytes: 16, multiPV: 1)
    )
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let session = GameSession.fresh(game, engine: engine)
    session.setIntercept(10)
    session.play(try #require(game.state.move(matching: "e2e4")))
    #expect(session.game != game)
    session.suspend()
    #expect(session.game.uciMoves == game.uciMoves)
    #expect(!session.isWeighing)
    await Task.yield()
    #expect(session.game.uciMoves == game.uciMoves)
}

/// Contract: a 试招 that no move absorbed is still there when the game is opened again.
///
/// A refused move rides onto the move that finally stands, as a comment on it — so a refusal the
/// player then walked away from had nowhere to be written and was simply forgotten. Play a wrong
/// move, look at it, leave: the game came back with no trace of it and nothing to practise.
@MainActor
@Test func aRefusalThatNothingAbsorbedSurvivesLeavingTheGame() async throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let afterD4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["d2d4"]))
    let engine = ScriptedEngine([], byPosition: [
        game.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
        ]),
        afterD4.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(-300), uciMoves: ["e7e5"], san: ["e5"])
        ]),
    ])
    let session = GameSession.fresh(game, engine: engine)
    session.setIntercept(JudgementLines.defaultIntercept)
    await session.waitForPreparedInterception()
    session.play(try #require(game.state.move(matching: "d2d4")))
    await session.waitForJudgement()
    #expect(session.refused?.san == "d4")
    let written = session.pgn.text
    session.suspend()

    let reopened = try PGN(parsing: written).game
    #expect(reopened.plies.isEmpty, "nothing was played")
    #expect(reopened.pendingTried.map(\.tries.first?.san) == ["d4"], "and the refusal is in the file")
    #expect(reopened.pendingTried.first?.tries.first?.line == ["e5"], "with the 应招 it earned")
    #expect(
        reopened.slips(by: [.white], lines: .standard).map(\.ply) == [1],
        "so the row under the record has somewhere to take the player"
    )
}
