@testable import ChessmirrorKit
import Foundation
import Testing
import ChessmirrorKitTesting

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
    session.setNoSlips(true)
    await session.waitForPreparedInterception()
    session.jump(toPly: 0)
    await session.waitForPreparedInterception()
    try #require(!session.isAtLatest, "the eye is on the first position, not the end")

    session.play(try #require(start.state.move(matching: "f2f3")))
    await session.settled()

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
    session.setNoSlips(true)
    await session.waitForPreparedInterception()
    session.jump(toPly: 0)
    await session.waitForPreparedInterception()
    try #require(!session.isAtLatest)

    session.play(try #require(start.state.move(matching: "e2e4")))
    await session.settled()

    #expect(session.refused == nil, "a move that costs a hair stands")
    #expect(session.game.plies.map(\.san) == ["e4"], "on the board")
    #expect(session.game.variations(atPly: 0).map { $0.map(\.san) } == [["d4"]], "with what was there kept beside it (docs/adr/0043)")
    #expect(session.game.plies.first?.isTrunk == false, "as the 树枝 it is")
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
    session.setNoSlips(true)
    session.jump(toPly: 2)
    await session.waitForPreparedInterception()
    let twoPliesIn = try #require(played.rewound(to: 2))

    session.play(try #require(twoPliesIn.state.move(matching: "f1c4")))
    await session.settled()
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
    session.noSlips(at: 5)
    await session.waitForPreparedInterception()
    for _ in 0..<2 {
        session.play(try #require(start.state.move(matching: "f2f3")))
        await session.settled()
        // A refusal leaves the moves alone; what it writes down is the 试招 itself (docs/adr/0037).
        #expect(session.game.uciMoves == start.uciMoves)
        #expect(session.refused?.san == "f3")
    }
    #expect(session.pendingAttempts.count == 2)
    session.setNoSlips(false)
    await session.waitForPreparedInterception()
    session.setNoSlips(true)
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
    session.noSlips(at: 5)
    await session.waitForPreparedInterception()
    session.play(try #require(start.state.move(matching: "f2f3")))
    await session.settled()

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
    // The engine wants d4: e4 is the player's own, and the position it makes is searched.
    let engine = ScriptedEngine([Analysis(depth: 20, lines: [
        .init(score: .centipawns(0), uciMoves: ["d2d4"], san: ["d4"])
    ])], byPosition: [after.state.fen: Analysis(depth: 20, lines: [
        .init(score: .centipawns(score), uciMoves: ["e7e5"], san: ["e5"])
    ])], controlled: { game, budget in
        guard game.state.fen == after.state.fen, budget == PositionSearches.budget else { return nil }
        requested.continuation.yield(())
        requested.continuation.finish()
        return gate.stream
    })
    let session = GameSession.fresh(start, controllers: [.white: .hand, .black: .engine], engine: engine)
    session.setNoSlips(enabled)
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
    await session.settled()
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
    // The engine wants d4: e4 is the player's own, weighed from both positions.
    let engine = ScriptedEngine([], byPosition: [
        start.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(0), uciMoves: ["d2d4"], san: ["d4"])]),
        after.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(score), uciMoves: [], san: [])]),
        reply.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(2 * score), uciMoves: [], san: [])])
    ])
    let session = GameSession.fresh(start, engine: engine)
    defer { session.suspend() }
    #expect(session.moveChange == nil)
    session.play(try #require(start.state.move(matching: "e2e4")))
    await session.settled()
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
    await session.settled()
    await session.measureLatestMoveChange()
    #expect(session.game.plies.count == 2)
    #expect(session.historyScore(atPly: 2) == .centipawns(2 * score))
    #expect(session.historyScore(atPly: 1) == .centipawns(score))
    #expect(session.moveChange?.before == change.after)
    session.jump(toPly: 0)
    #expect(session.historyScore(atPly: 2) == .centipawns(2 * score))
}

/// Contract: 把关 is a switch and nothing else. On, it stops the player at the 记录线; off, the
/// file says nothing of it, a real PGN file round trip comes back off, and the game never changes.
@MainActor
@Test func noSlipsIsASwitchThatReadsTheRecordLine() throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let session = GameSession.fresh(game, lines: JudgementLines(record: 15, enqueue: 20))
    session.setNoSlips(true)
    #expect(session.isNoSlipsOn)
    #expect(session.lines.intercept == 15, "it stops the player where the book writes down")
    #expect(session.pgn.tag("Intercept") == "15.0")
    session.setNoSlips(false)
    #expect(!session.isNoSlipsOn)
    #expect(session.lines.record == 15, "and switching it off moves no line")
    #expect(session.game.uciMoves == game.uciMoves)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "off.pgn")
    try session.pgn.text.write(to: file, atomically: true, encoding: .utf8)
    let saved = try PGN(parsing: String(contentsOf: file, encoding: .utf8))
    #expect(saved.tag("Intercept") == nil)
    let reopened = try #require(GameSession.opened(.init(url: file, pgn: saved, modified: Date())))
    #expect(!reopened.isNoSlipsOn)
    reopened.setNoSlips(true)
    #expect(reopened.isNoSlipsOn)
    #expect(reopened.lines.intercept == JudgementLines.standard.record)
    #expect(reopened.game == game)
}

/// Contract: a game saved when 把关 had a dial of its own comes back with 把关 on, stopping the
/// player at the 记录线 they have now; the moves already judged keep the line they stood under,
/// and the file stops carrying a line to come back on at (docs/adr/0046).
@MainActor
@Test func aGameSavedUnderItsOwnInterceptLineReopensOnTheRecordLine() throws {
    let saved = try PGN(parsing: """
        [Event "Chessmirror"]
        [White "手动"]
        [Black "Stockfish 18"]
        [Result "*"]
        [Intercept "5.0"]
        [Source "fresh"]

        1. e4 {[%judged 20 0.0 0.33 under 5.0]} e5 *
        """)
    let entry = GameLibrary.Entry(url: URL(filePath: "/games/old.pgn"), pgn: saved, modified: Date())
    let opened = try #require(GameSession.opened(entry, lines: JudgementLines(record: 15, enqueue: 15)))
    #expect(opened.isNoSlipsOn, "the file's word on the switch")
    #expect(opened.lines.intercept == 15, "the player's word on the line")
    #expect(opened.game.plies[0].judgement?.intercept == 5, "what stood under five still says five")
    #expect(opened.pgn.tag("Intercept") == "15.0")

    var off = saved
    off.setTag("Intercept", to: nil)
    off.setTag("InterceptPreference", to: "37.0")
    let quiet = try #require(GameSession.opened(
        GameLibrary.Entry(url: URL(filePath: "/games/off.pgn"), pgn: off, modified: Date())
    ))
    #expect(!quiet.isNoSlipsOn)
    #expect(quiet.pgn.tag("InterceptPreference") == nil, "a dial that is gone has nothing to come back to")
    quiet.setNoSlips(true)
    #expect(quiet.lines.intercept == JudgementLines.standard.record)
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
    session.noSlips(at: 10)
    await session.waitForPreparedInterception()
    try #require((session.searchProgress?.depth ?? 0) > 0)
    let started = ContinuousClock.now
    session.play(try #require(game.state.move(matching: "e2e4")))
    let gateTime = started.duration(to: .now)
    try #require(session.isWeighing, "the resulting position still needs its own depth-20 judgement")
    #expect(!session.isEngineTurn)
    #expect(session.game.uciMoves == ["e2e4"])
    await session.settled()
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
    legacy.setNoSlips(true)
    legacy.attach(engine: engine, library: nil)
    defer { legacy.suspend() }
    #expect(legacy.game.plies[0].judgement == nil)
    await legacy.fillMissingNoSlipsJudgements()
    #expect(legacy.game != oldGame)
    #expect(legacy.game.uciMoves == oldGame.uciMoves)
    // The same measurement, 最佳 included — but measured after the fact, so it stood under
    // nothing: a move nobody weighed before it was played did not stand under 把关
    // (docs/adr/0038).
    let measured = Game.Ply.Judgement(
        drop: judgement.drop, score: judgement.score, depth: judgement.depth, best: judgement.best
    )
    #expect(legacy.game.plies[0].judgement == measured)
    #expect(legacy.game.plies[0].judgement?.stoodUnderNoSlips == false)
    #expect(legacy.game.plies[1].judgement == nil, "only the person's moves are backfilled")
    let filled = legacy.game
    await legacy.fillMissingNoSlipsJudgements()
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
    session.noSlips(at: 10)
    await session.waitForPreparedInterception()
    session.play(try #require(game.state.move(matching: "f2f3")))
    await session.settled()
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
    session.noSlips(at: 10)
    await session.waitForPreparedInterception()
    let searches = engine.searchCount
    session.play(try #require(game.state.move(matching: "d8h4")))
    await session.settled()
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
    session.noSlips(at: 10)
    await session.waitForPreparedInterception()
    session.play(try #require(game.state.move(matching: "f2f3")))

    await session.settled()
    #expect(!session.isWeighing)
    #expect(session.refused?.san == "f3")
    #expect(session.game.uciMoves == game.uciMoves)
    #expect(engine.budgets.last == PositionSearches.budget)
    #expect(engine.budgets.count == 2)
}

@MainActor
@Test func browsingKeepsARefusalAtItsOwnPosition() async throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
    let after = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "f2f3"]))
    let engine = ScriptedEngine([Analysis(depth: 20, lines: [
        Line(score: .centipawns(0), uciMoves: ["g1f3"], san: ["Nf3"]),
    ])], byPosition: [after.state.fen: Analysis(depth: 20, lines: [
        Line(score: .centipawns(-300), uciMoves: ["d8h4"], san: ["Qh4"])
    ])])
    let session = GameSession.fresh(game, engine: engine)
    defer { session.suspend() }
    session.noSlips(at: 10)
    session.play(try #require(session.game.state.move(matching: "f2f3")))
    await session.settled()
    #expect(session.refused?.san == "f3")

    session.jumpToStart()
    #expect(session.refused == nil, "the sentence belongs to the position it was said at")
    session.jumpToLatest()
    #expect(session.refused?.san == "f3", "and comes back with the eye")
    #expect(session.game.uciMoves == game.uciMoves)
}

/// A passing move the prepared search already has a Line for is judged from that Line, at once:
/// its own Score, at the prepared depth, with no search of the position it made (`Weighing`).
@MainActor
@Test func preparedPassingMoveIsJudgedFromThePreparedSearch() async throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let engine = ScriptedEngine([Analysis(depth: 20, lines: [
        Line(score: .centipawns(20), uciMoves: ["e2e4"], san: ["e4"]),
        Line(score: .centipawns(10), uciMoves: ["d2d4"], san: ["d4"]),
    ])])
    let session = GameSession.fresh(game, engine: engine)
    defer { session.suspend() }
    session.noSlips(at: 10)

    await session.waitForPreparedInterception()
    #expect(session.searchProgress?.depth == 20)
    let started = ContinuousClock.now
    session.play(try #require(game.state.move(matching: "d2d4")))
    let elapsed = started.duration(to: .now)
    #expect(session.game.uciMoves == ["d2d4"])
    #expect(session.isWeighing)
    await session.settled()
    #expect(!session.isWeighing)
    #expect(session.game.plies.first?.judgement?.depth == 20)
    #expect(session.game.plies.first?.judgement?.score == .centipawns(10), "its own Line's Score")
    #expect(session.game.plies.first?.judgement?.drop == MoveQuality.drop(move: .white, before: .centipawns(20), after: .centipawns(10)))
    #expect(engine.budgets.allSatisfy { $0 == PositionSearches.budget })
    print("Prepared passing move committed in \(elapsed)")
}

@MainActor
@Test(arguments: [0.0, 5.0, 7.0, 37.0, 100.0])
func theSwitchSurvivesReopeningAndTheLineIsThePlayers(_ line: Double) throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
    let session = GameSession.fresh(game)
    session.noSlips(at: line)
    #expect(session.isNoSlipsOn)
    let pgn = try PGN(parsing: session.pgn.text)
    let opened = try #require(GameSession.opened(GameLibrary.Entry(
        url: URL(filePath: "/games/no-slips.pgn"), pgn: pgn, modified: Date()
    )))
    #expect(pgn.intercept == line, "the file says where the moves in it were stopped")
    #expect(opened.isNoSlipsOn)
    #expect(opened.lines.intercept == JudgementLines.standard.record, "and the player says where the next is")
    opened.noSlips(at: .nan)
    #expect(opened.lines == JudgementLines(noSlips: true), "a line off the scale is not a line")
    opened.noSlips(at: 101)
    #expect(opened.lines == JudgementLines(noSlips: true))
    opened.setNoSlips(false)
    #expect(!opened.isNoSlipsOn)
    #expect(opened.pgn.tag("Intercept") == nil)
}

/// Contract: real Stockfish judges Fool's Mate → session restores the board → a legal retry
/// stands → PGN retains the refused move once. The disabled setting must allow the same blunder.
@MainActor
@Test func noSlipsRejectsMateAndPreservesTheRetry() async throws {
    let engine = try EngineService(
        bigNetURL: Nets.big, smallNetURL: Nets.small,
        configuration: .init(threads: 2, hashMegabytes: 32, multiPV: 1)
    )
    let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3", "e7e5"]))
    let session = GameSession.fresh(game, engine: engine)
    defer { session.suspend() }
    session.noSlips(at: 10)
    let blunder = try #require(game.state.move(matching: "g2g4"))
    session.play(blunder)
    #expect(session.isWeighing)

    await session.settled()
    #expect(!session.isWeighing, "Stockfish must finish judging within 30 seconds")
    #expect(session.game.uciMoves == game.uciMoves, "the rejected move must restore the entire game")
    #expect(try #require(session.refused).san == "g4")
    #expect(session.refused!.drop >= 10)

    // Switching interception off lets a retry stand, while preserving the earlier refusal.
    session.setNoSlips(false)
    session.play(try #require(game.state.move(matching: "e2e4")))
    await session.settled()
    #expect(session.game.uciMoves == ["f2f3", "e7e5", "e2e4"])
    let read = try PGN(parsing: session.pgn.text)
    #expect(read.game.plies.last?.tried.count == 1)
    #expect(read.game.plies.last?.tried.first?.san == "g4")

    let disabled = GameSession.fresh(game, engine: engine)
    defer { disabled.suspend() }
    disabled.play(blunder)
    #expect(disabled.isWeighing, "every move is weighed; 把关 off only means it stands")
    await disabled.settled()
    #expect(!disabled.isWeighing)
    #expect(disabled.game.uciMoves.last == "g2g4")
    #expect(disabled.refused == nil)
}

@MainActor
@Test func suspendingNoSlipsRestoresTheUnjudgedPosition() async throws {
    let engine = try EngineService(
        bigNetURL: Nets.big, smallNetURL: Nets.small,
        configuration: .init(threads: 1, hashMegabytes: 16, multiPV: 1)
    )
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let session = GameSession.fresh(game, engine: engine)
    session.noSlips(at: 10)
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
    session.setNoSlips(true)
    await session.waitForPreparedInterception()
    session.play(try #require(game.state.move(matching: "d2d4")))
    await session.settled()
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

/// Contract: one door for a move's judgement. A move that lands without a ruling — the engine's
/// own — is weighed by the same 细判 that rules under 把关, and the record and the badge are
/// written from that one Weighing: the same Score, the same 最佳. It used to be written from the
/// before-table alone, with 最佳 always false, and the badge from a second weighing; the two
/// disagreed about the engine's own first choice (CONTEXT.md, 细判, 最佳).
@MainActor
@Test func theEnginesOwnMoveIsJudgedByTheOneWeighingTheBadgeReads() async throws {
    let start = try #require(Game(startFEN: PGN.standardStartFEN))
    let afterE4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
    let afterE5 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
    let engine = ScriptedEngine([], byPosition: [
        start.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(30), uciMoves: ["e2e4"], san: ["e4"]),
        ]),
        // The engine's own first choice from here is e5, and the line it has for it lands at 25.
        afterE4.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(25), uciMoves: ["e7e5", "g1f3"], san: ["e5", "Nf3"]),
            .init(score: .centipawns(45), uciMoves: ["c7c5"], san: ["c5"]),
        ]),
        afterE5.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(25), uciMoves: ["g1f3"], san: ["Nf3"]),
        ]),
    ])
    let session = GameSession.fresh(start, controllers: [.white: .hand, .black: .engine], engine: engine)
    defer { session.suspend() }

    session.play(try #require(start.state.move(matching: "e2e4")))
    await session.settled()
    await session.waitForPreparedInterception()
    try #require(session.game.uciMoves == ["e2e4", "e7e5"], "the engine answered")
    await session.settled()

    let judgement = try #require(session.game.plies[1].judgement)
    let change = try #require(session.moveChange)
    #expect(judgement.best, "the engine's own first choice is 最佳 on the record")
    #expect(judgement.score == .centipawns(25))
    #expect(judgement.intercept == nil, "it landed under no 拦截线")
    #expect(change.isBest == judgement.best)
    #expect(change.after == judgement.score)
    #expect(session.historyScore(atPly: 2) == judgement.score)
    #expect(session.standing == .best)

    // The file says the same, and reading it back is the same judgement.
    let read = try PGN(parsing: session.pgn.text)
    #expect(read.game.plies[1].judgement == judgement)
}

/// Contract: a move that was already in the file without a judgement gets the badge and the
/// curve's last point from the badge's weighing, and nothing written onto it — filling old files
/// in is the explicit migration, never something a screen starts.
@MainActor
@Test func aMoveFromTheFileGetsTheBadgeAndNothingWritten() async throws {
    let start = try #require(Game(startFEN: PGN.standardStartFEN))
    let played = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
    let engine = ScriptedEngine([], byPosition: [
        start.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(0), uciMoves: ["d2d4"], san: ["d4"])]),
        played.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(-133), uciMoves: [], san: [])]),
    ])
    let session = GameSession.fresh(played, engine: engine)
    defer { session.suspend() }
    await session.measureLatestMoveChange()

    let change = try #require(session.moveChange)
    #expect(change.after == .centipawns(-133))
    #expect(session.historyScore(atPly: 1) == .centipawns(-133), "the curve reaches the last move")
    #expect(session.historyScore(atPly: 0) == .centipawns(0))
    #expect(session.game.plies[0].judgement == nil, "and the file is not written to")
}

/// Contract: a bar with no number draws a level game, so the bar is never without one while a
/// move is being weighed. The position the move made has not been searched yet — that is what
/// the weighing is — and on a phone that is ten seconds or more of a bar sitting at half and
/// half over a position that is nothing like level. Until the verdict, it holds the number of
/// the position the move was played from.
@MainActor
@Test func theBarHoldsItsNumberWhileAMoveIsWeighed() async throws {
    let start = try #require(Game(startFEN: PGN.standardStartFEN))
    let afterE4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
    let unanswered = AsyncStream<Analysis>.makeStream()
    let engine = ScriptedEngine([], byPosition: [
        start.state.fen: Analysis(depth: 20, lines: [
            .init(score: .centipawns(300), uciMoves: ["d2d4"], san: ["d4"])
        ]),
    ], controlled: { game, _ in game.state.fen == afterE4.state.fen ? unanswered.stream : nil })
    let session = GameSession.fresh(start, engine: engine)
    defer {
        session.suspend()
        unanswered.continuation.finish()
    }
    session.setNoSlips(true)
    await session.waitForPreparedInterception()
    try #require(session.strip.bar?.score == .centipawns(300))

    session.play(try #require(start.state.move(matching: "e2e4")))
    for _ in 0..<20 { await Task.yield() }
    try #require(session.isWeighing, "the position the move made has no answer yet")
    #expect(session.strip.bar?.score == .centipawns(300), "not nil, which the bar draws as 50/50")
}
