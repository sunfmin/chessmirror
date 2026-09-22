@testable import ChessmirrorKit
import Foundation
import Testing
import ChessmirrorKitTesting

/// A session on a screen follows the app's one engine host by itself: it takes the engine when
/// it arrives, stops searching when the app leaves the front, and starts again when it comes
/// back. The screen calls `appear` and `disappear` and wires nothing else.
@Suite("the session follows its host")
@MainActor
struct SessionHostTests {
    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    }

    /// An engine whose every search is held open: what the session is doing stays visible as
    /// `isSearching`, rather than finishing between one line of the test and the next.
    private func held() -> ScriptedEngine {
        ScriptedEngine([], controlled: { _, _ in AsyncStream { _ in } })
    }

    @Test func theAppLeavingSuspendsAndComingBackRetunes() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let engine = held()
        let host = EngineHost(engine)
        let session = GameSession.fresh(game)
        defer { session.disappear() }
        session.noSlips(at: 10)
        #expect(!session.isSearching, "nothing searches before the screen is there")

        session.appear(on: host, library: nil)
        #expect(session.isSearching, "on screen, 把关 searches the position in front of the player")
        // The shared store asks the engine a hop after the session asks it.
        await until { engine.searchCount == 1 }

        host.setActive(false)
        await until { !session.isSearching }
        #expect(!session.isSearching, "the app left: the session suspended itself")

        host.setActive(true)
        await until { session.isSearching }
        #expect(session.isSearching, "and came back: a fresh retune, nothing the screen did")
    }

    @Test func theScreenGoneMeansTheHostIsNoLongerFollowed() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let engine = held()
        let host = EngineHost(engine)
        let session = GameSession.fresh(game)
        session.noSlips(at: 10)
        session.appear(on: host, library: nil)
        // The shared store asks the engine a hop after the session asks it.
        await until { engine.searchCount == 1 }
        session.disappear()
        #expect(!session.isSearching)
        let searches = engine.searchCount

        host.setActive(false)
        host.setActive(true)
        for _ in 0..<10 { await Task.yield() }
        #expect(!session.isSearching, "a screen that has gone does not search on the app's return")
        #expect(engine.searchCount == searches)
    }

    @Test func theEngineArrivingIsTakenAndSearched() async throws {
        try await Quietly.alone {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let host = EngineHost(nets: { .init(big: Nets.big, small: Nets.small) })
        let session = GameSession.fresh(game)
        defer { session.disappear() }
        session.noSlips(at: 10)
        session.appear(on: host, library: nil)
        #expect(!session.isSearching, "no engine yet: nothing to search with")

        await host.start()
        #expect(host.isReady)
        await until { session.isSearching }
        #expect(session.isSearching, "the engine arrived, and the session took it without being told")
    
        }}

    /// The host's two facts are one seam (`onStatusChange`): a subscriber is a standing
    /// subscription, and dropping the token is what unsubscribes.
    @Test func aWatchOnTheHostFiresOnChangeAndStopsWhenDropped() async throws {
        let host = EngineHost(ScriptedEngine([]))
        var fired = 0
        var watch: EngineHost.Watch? = host.onStatusChange { fired += 1 }
        host.setActive(false)
        await until { fired == 1 }
        #expect(fired == 1, "the app leaving is a change")

        host.setActive(true)
        await until { fired == 2 }
        #expect(fired == 2, "and coming back is another")

        watch?.stop()
        watch = nil
        host.setActive(false)
        for _ in 0..<10 { await Task.yield() }
        #expect(fired == 2, "a dropped token hears nothing more")
    }

    /// A listener cannot outlive its screen: `disappear` takes it away, so a session off screen
    /// is a silent one.
    @Test func disappearingTakesTheListenerAway() throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let session = GameSession.fresh(game)
        var heard = 0
        session.appear(on: EngineHost(ScriptedEngine([])), library: nil, hearing: { _ in heard += 1 })
        session.disappear()

        let e4 = try #require(game.state.move(matching: "e2e4"))
        session.play(e4)
        #expect(heard == 0, "nothing is heard on a session nobody is looking at")
    }
}
