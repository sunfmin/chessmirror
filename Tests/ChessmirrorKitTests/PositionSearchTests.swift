@testable import ChessmirrorKit
import Foundation
import Synchronization
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

/// Waits, briefly, for something the store does on its own actor.
private func until(_ condition: @escaping () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
}

private func read(_ store: PositionSearches, _ game: Game, using engine: ScriptedEngine,
                  budget: SearchBudget = PositionSearches.budget) async -> Analysis? {
    var last: Analysis?
    for await snapshot in store.analyse(game, using: engine, budget: budget) { last = snapshot }
    return last
}

/// Contract: the store keeps the deepest result it knows (docs/adr/0041). A deeper ask on a
/// position nobody has looked at runs the everyday search first and lets everyday readers go
/// when it ends; the deeper search then runs for the ones who asked, and when it finishes it
/// replaces the everyday entry for everybody, on disk too. Nothing is searched twice.
@Test func theStoreKeepsTheDeepestResultItKnows() async throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let line = [Line(score: .centipawns(30), uciMoves: ["e2e4"], san: ["e4"])]
    let shallow = Analysis(depth: 20, lines: line)
    let climbing = Analysis(depth: 24, lines: line)
    let deep = Analysis(depth: 28, lines: line)
    let everyday = AsyncStream<Analysis>.makeStream()
    let deeper = AsyncStream<Analysis>.makeStream()
    let engine = ScriptedEngine([], controlled: { _, budget in
        budget == PositionSearches.deeper ? deeper.stream : everyday.stream
    })
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PositionSearches(storage: directory.appending(path: "positions.json"))

    async let wantsDeep = read(store, game, using: engine, budget: PositionSearches.deeper)
    async let wantsShallow = read(store, game, using: engine)
    await until { engine.searchCount == 1 }
    #expect(engine.budgets == [PositionSearches.budget], "the everyday search runs first, once")
    everyday.continuation.yield(shallow)
    everyday.continuation.finish()
    #expect(await wantsShallow == shallow, "an everyday reader is not made to wait for the deeper search")

    await until { engine.searchCount == 2 }
    #expect(engine.budgets.last == PositionSearches.deeper)
    deeper.continuation.yield(climbing)
    #expect(await read(store, game, using: engine) == shallow, "while it climbs, the entry is the everyday one")
    #expect(engine.searchCount == 2)
    deeper.continuation.yield(deep)
    deeper.continuation.finish()
    #expect(await wantsDeep == deep)

    #expect(await read(store, game, using: engine) == deep, "and now everybody reads the deeper answer")
    #expect(await read(store, game, using: engine, budget: PositionSearches.deeper) == deep)
    #expect(engine.searchCount == 2, "without anything being searched again")
    let reopened = PositionSearches(storage: directory.appending(path: "positions.json"))
    #expect(await read(reopened, game, using: engine) == deep, "on disk as well")
    #expect(engine.searchCount == 2)
}

/// A deeper search that runs out of its minute short of depth 28 still replaces a shallower
/// entry, and the position is still open to being asked deeper again — the engine's hash table
/// makes that a continuation, which is not this store's business.
@Test func aDeeperSearchCutOffByTheClockStillDeepensTheEntry() async throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let line = [Line(score: .centipawns(30), uciMoves: ["e2e4"], san: ["e4"])]
    let shallow = Analysis(depth: 20, lines: line)
    let partway = Analysis(depth: 25, lines: line)
    let engine = ScriptedEngine([], byBudget: [
        PositionSearches.budget: [shallow], PositionSearches.deeper: [partway],
    ])
    let store = PositionSearches()
    #expect(await read(store, game, using: engine) == shallow)
    #expect(await read(store, game, using: engine, budget: PositionSearches.deeper) == partway)
    #expect(await read(store, game, using: engine) == partway, "25 is deeper than 20, so it is what the store knows")
    #expect(engine.searchCount == 2)
    _ = await read(store, game, using: engine, budget: PositionSearches.deeper)
    #expect(engine.searchCount == 3, "short of 28, a deeper ask searches again")
}

/// A deeper search nobody is waiting for any more is cancelled, and the entry is left exactly
/// as the everyday search left it.
@Test func aDeeperSearchNobodyWaitsForIsCancelledAndWritesNothing() async throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let line = [Line(score: .centipawns(30), uciMoves: ["e2e4"], san: ["e4"])]
    let shallow = Analysis(depth: 20, lines: line)
    let deeper = AsyncStream<Analysis>.makeStream()
    let stopped = Mutex(false)
    deeper.continuation.onTermination = { _ in stopped.withLock { $0 = true } }
    let engine = ScriptedEngine([shallow], controlled: { _, budget in
        budget == PositionSearches.deeper ? deeper.stream : nil
    })
    let store = PositionSearches()
    #expect(await read(store, game, using: engine) == shallow)

    let asking = Task { await read(store, game, using: engine, budget: PositionSearches.deeper) }
    await until { engine.searchCount == 2 }
    deeper.continuation.yield(Analysis(depth: 24, lines: line))
    asking.cancel()
    _ = await asking.value
    await until { stopped.withLock { $0 } }
    #expect(stopped.withLock { $0 }, "the engine is told to stop")
    #expect(await read(store, game, using: engine) == shallow, "and the entry is as it was")
    #expect(engine.searchCount == 2)
}
