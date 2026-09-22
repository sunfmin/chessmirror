@testable import ChessmirrorKit
import ChessmirrorKitTesting
import Foundation
import Testing

/// Contract: every way a move becomes part of the game ends at one door (`land`) and, when the
/// move stands, one routine (`stoodOnBoard`). A ruled move and one nobody weighed used to carry
/// two copies of that tail and had drifted — one absorbed the 试招 made where the move was played
/// from and the other did not. These are the facts both must now agree on.
@MainActor
@Suite(.speaking(.chinese)) struct LandingTests {
    private func analysis(_ cp: Int, _ uci: String, _ san: String) -> Analysis {
        Analysis(depth: 20, lines: [.init(score: .centipawns(cp), uciMoves: [uci], san: [san])])
    }

    // ------------------------------------------------------------------ the shared tail

    /// A 试招 made where the move was played from rides onto the move that finally stands
    /// (docs/adr/0037) — whichever intake the standing move came through.
    @Test func aStandingMoveCarriesTheRefusalsMadeWhereItWasPlayedFrom() async throws {
        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        let afterE4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
        let afterF3 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3"]))
        // The engine wants d4 at 0. f3 costs 300 and is refused; e4 holds the position and stands.
        let engine = ScriptedEngine([], byPosition: [
            start.state.fen: analysis(0, "d2d4", "d4"),
            afterF3.state.fen: analysis(-300, "e7e5", "e5"),
            afterE4.state.fen: analysis(0, "e7e5", "e5"),
        ])
        let session = GameSession.fresh(start, engine: engine, strength: .full)
        defer { session.suspend() }
        session.noSlips(at: 5)
        await session.waitForPreparedInterception()

        // A move taken back writes the 试招 where it happened.
        session.play(try #require(start.state.move(matching: "f2f3")))
        await session.settled()
        #expect(session.refused?.san == "f3", "把关 took it back")
        #expect(session.game.plies.isEmpty, "and the game is as it was")

        // A move that stands afterwards carries it as its 试招.
        session.play(try #require(start.state.move(matching: "e2e4")))
        await session.settled()
        await session.measureLatestMoveChange()
        #expect(session.game.plies.count == 1, "e4 stood")
        #expect(
            session.game.plies[0].tried.map(\.san) == ["f3"],
            "the refusal rides onto the move that stood (docs/adr/0037)"
        )
        #expect(session.refused == nil, "and the strip is no longer saying there was a refusal")
    }

    /// The engine's own move goes through `commit` and the same tail: a refusal made at the
    /// position it was played from is absorbed there too. This is the drift `stoodOnBoard`
    /// exists to stop — `commit` used to absorb and `land` did not.
    @Test func anEngineMoveAbsorbsRefusalsToo() async throws {
        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        let afterE4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
        let afterA3 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["a2a3"]))
        let engine = ScriptedEngine([], byPosition: [
            start.state.fen: analysis(30, "e2e4", "e4"),
            afterA3.state.fen: analysis(-300, "e7e5", "e5"),
            afterE4.state.fen: analysis(30, "e7e5", "e5"),
        ])
        let session = GameSession.fresh(start, engine: engine, strength: .full)
        defer { session.suspend() }
        session.noSlips(at: 5)
        await session.waitForPreparedInterception()

        // A hand move taken back at the start.
        session.play(try #require(start.state.move(matching: "a2a3")))
        await session.settled()
        #expect(session.refused?.san == "a3")

        // The engine plays for White — through `commit`, not through a ruling.
        let e4 = try #require(start.state.move(matching: "e2e4"))
        session.playByEngine(e4)
        #expect(session.game.uciMoves == ["e2e4"])
        #expect(
            session.game.plies[0].tried.map(\.san) == ["a3"],
            "the engine's own move absorbs the refusal like any other (docs/adr/0037)"
        )
        #expect(session.refused == nil, "and the strip has moved on")
    }

    /// A standing move drops the Analysis that described the position before it: the number for
    /// the new position is not the old one's.
    @Test func aStandingMoveDropsTheStaleAnalysis() async throws {
        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        let afterE4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
        let engine = ScriptedEngine([], byPosition: [
            start.state.fen: analysis(0, "d2d4", "d4"),
            afterE4.state.fen: analysis(133, "e7e5", "e5"),
        ])
        let session = GameSession.fresh(start, engine: engine)
        defer { session.suspend() }
        session.adviseForCard()
        await session.waitForPreparedInterception()
        #expect(session.analysis != nil, "the card has its answer for the start")

        session.play(try #require(start.state.move(matching: "e2e4")))
        await session.settled()
        await session.measureLatestMoveChange()
        #expect(session.game.plies.count == 1)
        #expect(session.barReading.change != nil, "the badge describes the move just played")
    }

    // ------------------------------------------------------------------ the take-back hold

    /// The hold is what makes a roll-back visible at all (a cached search answers inside one
    /// frame, so the piece would otherwise go and come back between two draws). It is an
    /// argument, not a baked-in sleep, so a test can pass `.zero` and assert the roll-back
    /// itself instead of waiting out a gesture it cannot see.
    @Test func theTakeBackHoldIsSomethingAHandsCanZero() async throws {
        let previous = GameSession.takeBackHold
        GameSession.takeBackHold = .zero
        defer { GameSession.takeBackHold = previous }

        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        let afterF3 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3"]))
        let engine = ScriptedEngine([], byPosition: [
            start.state.fen: analysis(0, "d2d4", "d4"),
            afterF3.state.fen: analysis(-300, "e7e5", "e5"),
        ])
        let session = GameSession.fresh(start, engine: engine, strength: .full)
        defer { session.suspend() }
        session.noSlips(at: 5)
        await session.waitForPreparedInterception()

        let clock = ContinuousClock()
        session.play(try #require(start.state.move(matching: "f2f3")))
        await session.settled()
        let took = ContinuousClock.now - clock.now
        #expect(session.refused?.san == "f3")
        #expect(session.game.plies.isEmpty, "the move came back off the board")
        #expect(took < .milliseconds(400), "with the hold zeroed, no gesture wait is paid")
    }
}
