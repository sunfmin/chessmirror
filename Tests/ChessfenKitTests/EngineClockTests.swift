@testable import ChessfenKit
import Testing

/// Contract: advice, settings, a card, an asked move and an opponent all use the same
/// completed position search. The old mirrored/stint clocks no longer start searches.
@MainActor @Suite(.serialized)
struct EngineClock {
    @Test func allLiveConsumersShareThePositionClock() async throws {
        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        let after = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
        let engine = ScriptedEngine([], byPosition: [
            start.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])]),
            after.state.fen: Analysis(depth: 12, lines: [.init(score: .centipawns(0), uciMoves: ["e7e5"], san: ["e5"])])
        ])
        let session = GameSession.fresh(start, engine: engine)
        defer { session.suspend() }
        session.showPositionFeedback()
        session.retune()
        await session.waitForPreparedInterception()
        #expect(engine.searchCount == 1)
        session.adviseForCard()
        await session.waitForPreparedInterception()
        #expect(session.analysis?.bestMove == "e2e4")
        session.retune()
        await session.waitForPreparedInterception()
        #expect(engine.searchCount == 1, "settings and cards reuse the same result")
        session.setController(.engine, for: .white)
        await session.waitForPreparedInterception()
        #expect(session.game != start)
        // A refusal leaves the moves alone; what it writes down is the 试招 itself (docs/adr/0037).
        #expect(session.game.uciMoves == ["e2e4"])
        await session.waitForPreparedInterception()
        #expect(engine.positions.filter { $0 == start.state.fen }.count == 1)
        #expect(engine.positions.filter { $0 == after.state.fen }.count == 1)
        session.jump(toPly: 0)
        await session.waitForPreparedInterception()
        #expect(session.game.uciMoves == ["e2e4"], "reading history never plays a move")
        #expect(session.analysis?.bestMove == "e2e4")
        #expect(engine.searchCount == 2)
        #expect(engine.budgets.allSatisfy { $0 == PositionSearches.budget })
        #expect(engine.lines.allSatisfy { $0 == 2 })
    }

    @Test func cancellationAndAnotherSubscriberNeverRestartTheSearch() async throws {
        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        let gate = AsyncStream<Analysis>.makeStream()
        let requested = AsyncStream<Void>.makeStream()
        let engine = ScriptedEngine([], controlled: { _, _ in
            requested.continuation.yield(())
            requested.continuation.finish()
            return gate.stream
        })
        let session = GameSession.fresh(start, engine: engine)
        defer { gate.continuation.finish(); session.suspend() }
        session.showPositionFeedback()
        session.retune()
        var requests = requested.stream.makeAsyncIterator()
        _ = await requests.next()
        session.retune()
        session.adviseForCard()
        gate.continuation.yield(Analysis(depth: 12, lines: [
            .init(score: .centipawns(15), uciMoves: ["e2e4"], san: ["e4"])
        ]))
        gate.continuation.finish()
        await session.waitForPreparedInterception()
        #expect(session.analysis == nil, "a card dealt while the board searched is at rest")
        #expect(session.searchProgress?.depth == 12)
        #expect(engine.searchCount == 1)
        // A card that asks once the shared search has finished is answered out of its cache.
        session.adviseForCard()
        await session.waitForPreparedInterception()
        #expect(session.analysis?.best?.score == .centipawns(15))
        #expect(engine.searchCount == 1, "and nothing was searched again")
        session.suspend()
        session.retune()
        await session.waitForPreparedInterception()
        #expect(engine.searchCount == 1)
        #expect(session.game.uciMoves == start.uciMoves)
    }

    @Test func pausedScreensDoNotStartOrQueueLiveWork() async throws {
        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        let engine = ScriptedEngine([Analysis(depth: 12, lines: [
            .init(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
        ])])
        engine.pause()
        let session = GameSession.fresh(start, engine: engine)
        defer { session.suspend() }
        session.showPositionFeedback()
        session.retune()
        await session.waitForPreparedInterception()
        #expect(engine.searchCount == 0)
        engine.resume()
        session.retune()
        await session.waitForPreparedInterception()
        #expect(engine.searchCount == 1)
        #expect(session.feedbackScore == .centipawns(0))
    }
}
