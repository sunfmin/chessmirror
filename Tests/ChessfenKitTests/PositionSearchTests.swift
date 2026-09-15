@testable import ChessfenKit
import Foundation
import Testing

/// Concurrent consumers → one search → shallow result → disk round trip → no new work.
@Test func positionSearchSharesAndPersistsTheCompletedResult() async throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let result = Analysis(depth: 12, lines: [.init(score: .centipawns(34), uciMoves: ["e2e4"], san: ["e4"])])
    let gate = AsyncStream<Analysis>.makeStream()
    let requested = AsyncStream<Void>.makeStream()
    let engine = ScriptedEngine([], controlled: { _, _ in
        requested.continuation.yield(())
        requested.continuation.finish()
        return gate.stream
    })
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "positions.json")
    let store = PositionSearches(storage: file)
    func read(_ store: PositionSearches) async -> Analysis? {
        var last: Analysis?
        for await snapshot in store.analyse(game, using: engine) { last = snapshot }
        return last
    }
    #expect(engine.searchCount == 0)
    async let first = read(store)
    async let second = read(store)
    var requests = requested.stream.makeAsyncIterator()
    _ = await requests.next()
    gate.continuation.yield(result)
    gate.continuation.yield(Analysis(depth: 13, lines: result.lines, isPartial: true))
    gate.continuation.finish()
    #expect(await first == result)
    #expect(await second == result)
    #expect(engine.searchCount == 1)
    #expect(engine.budgets == [PositionSearches.budget])
    #expect(await read(store) == result)
    let reopened = PositionSearches(storage: file)
    #expect(await read(reopened) == result)
    #expect(engine.searchCount == 1)
    let differentClock = try #require(Game(startFEN: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 99 1"))
    #expect(PositionSearches.key(game) != PositionSearches.key(differentClock), "draw clocks cannot borrow an unsafe result")
}

/// The real C++ search receives both limits together and stops for either one.
@Test func nativeSearchStopsAtWhicheverLimitArrivesFirst() async throws {
    let engine = try EngineService(bigNetURL: Nets.big, smallNetURL: Nets.small,
                                   configuration: .init(threads: 2, hashMegabytes: 32))
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    for budget in [SearchBudget.timeOrDepth(.milliseconds(100), 40), .timeOrDepth(.seconds(10), 4)] {
        var last: Analysis?
        let start = ContinuousClock.now
        for await result in engine.analyse(game, budget: budget, lines: 2) { last = result }
        let result = try #require(last)
        #expect(result.bestMove.flatMap { game.state.move(matching: $0) } != nil)
        #expect(start.duration(to: .now) < .seconds(2), "neither case should wait for the other limit")
        if budget == .timeOrDepth(.seconds(10), 4) { #expect(result.depth == 4) }
        else { #expect(result.depth < 40) }
    }
}
