@testable import ChessmirrorKit
import Foundation
import Testing
import ChessmirrorKitTesting

/// Contract: what a search found is handed back without searching again, and the keeping of it
/// is bounded. It used to be a dictionary that grew one entry per position looked at, forever.

private func answer(_ cp: Int) -> Analysis {
    Analysis(depth: 20, lines: [Line(score: .centipawns(cp), uciMoves: ["e2e4"], san: ["e4"])])
}

@Test func whatWasPaidForIsHandedBack() {
    var cache = RecentAnalyses()
    cache["a"] = answer(10)

    #expect(cache["a"] == answer(10))
    #expect(cache["b"] == nil)
}

@Test func theCacheDoesNotGrowPastItsBound() {
    var cache = RecentAnalyses()
    for position in 0..<(RecentAnalyses.capacity * 3) {
        cache["position \(position)"] = answer(position)
    }

    #expect(cache.count == RecentAnalyses.capacity)
}

/// What goes is what was read or written longest ago — so walking back and forth over the last
/// few positions, the case the cache exists for, keeps all of them.
@Test func thePositionLongestUntouchedIsTheOneDropped() {
    var cache = RecentAnalyses()
    for position in 0..<RecentAnalyses.capacity {
        cache["position \(position)"] = answer(position)
    }
    // The oldest is read, which makes it the newest thing touched.
    #expect(cache["position 0"] == answer(0))

    cache["one more"] = answer(999)

    #expect(cache["position 0"] == answer(0), "reading it kept it")
    #expect(cache["position 1"] == nil, "and the next-oldest is what went")
    #expect(cache.count == RecentAnalyses.capacity)
}

/// The session's own use of it: a position already searched is answered out of the cache rather
/// than searched a second time.
@MainActor
@Test func aPositionAlreadySearchedIsNotSearchedAgain() async throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
    let engine = ScriptedEngine([answer(31)])
    let session = GameSession.fresh(game, engine: engine)
    defer { session.suspend() }
    session.retune()
    await session.waitForPreparedInterception()
    try #require(session.strip.depth == 20)
    let asked = engine.positions.count

    // Away and back: the position has been searched, so coming back to it asks nothing.
    session.step(by: -1)
    await session.waitForPreparedInterception()
    session.step(by: 1)
    await session.waitForPreparedInterception()

    #expect(session.strip.depth == 20, "the depth already paid for is still shown")
    #expect(engine.positions.count <= asked + 1, "the position was not searched twice")
}
