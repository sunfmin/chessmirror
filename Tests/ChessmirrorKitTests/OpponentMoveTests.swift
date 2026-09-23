@testable import ChessmirrorKit
import Foundation
import Testing
import ChessmirrorKitTesting

/// What the opponent plays, and how often it has to search to know (docs/adr/0049).
///
/// The bug these hold the line on: at 满力 the opponent read the position's stored answer, and
/// two engines started from the standard position played the same game every time, each move
/// landing the instant the one before it did — the store answering out of a file written by a
/// game played yesterday.
@MainActor
@Suite(.serialized)
struct OpponentMove {
    private static let start = PGN.standardStartFEN

    /// Two openings the engine cannot tell apart, and one it can.
    private static func twoWays(
        _ second: Int = 10, moves: [String] = ["e2e4", "d2d4"]
    ) -> Analysis {
        Analysis(depth: 20, lines: [
            Line(score: .centipawns(20), uciMoves: [moves[0]], san: [moves[0]]),
            Line(score: .centipawns(second), uciMoves: [moves[1]], san: [moves[1]]),
        ])
    }

    private func engineToMove(_ engine: ScriptedEngine, toss: Toss) throws -> GameSession {
        let game = try #require(Game(startFEN: Self.start))
        let session = GameSession.fresh(
            game, controllers: [.white: .engine, .black: .hand], engine: engine
        )
        session.toss = toss
        return session
    }

    // ------------------------------------------------------------------ the toss

    @Test("the toss picks only between moves the search scores within a pawn's fifteenth")
    func theMarginBoundsTheToss() throws {
        let level = Self.twoWays()
        #expect(Toss.candidates(in: level, by: .white) == ["e2e4", "d2d4"])
        // Black's side of the same reading: Scores in this package are White-relative, so what
        // is worse for Black is a *larger* number and the margin has to be read the other way up.
        let black = Analysis(depth: 20, lines: [
            Line(score: .centipawns(-20), uciMoves: ["e7e5"], san: ["e5"]),
            Line(score: .centipawns(-10), uciMoves: ["c7c5"], san: ["c5"]),
            Line(score: .centipawns(300), uciMoves: ["f7f6"], san: ["f6"]),
        ])
        #expect(Toss.candidates(in: black, by: .black) == ["e7e5", "c7c5"])
        let apart = Self.twoWays(-300)
        #expect(Toss.candidates(in: apart, by: .white) == ["e2e4"])
        // A coin that says "the second one" when there is no second one still plays the first.
        #expect(Toss { _ in 1 }.move(from: apart, by: .white) == "e2e4")
        #expect(Toss { _ in 1 }.move(from: level, by: .white) == "d2d4")
        #expect(Toss.strongest.move(from: level, by: .white) == "e2e4")
        #expect(Toss().move(from: Analysis(depth: 1, lines: []), by: .white) == nil)
    }

    @Test("a mate is never tossed for")
    func mateIsPlayedNotTossed() {
        let mating = Analysis(depth: 20, lines: [
            Line(score: .mate(in: 2), uciMoves: ["d1h5"], san: ["Qh5#"]),
            Line(score: .centipawns(900), uciMoves: ["e2e4"], san: ["e4"]),
        ])
        #expect(Toss.candidates(in: mating, by: .white) == ["d1h5"])
        #expect(Toss { _ in 1 }.move(from: mating, by: .white) == "d1h5")
    }

    // -------------------------------------------------------------- the opponent

    @Test("the opponent plays the move the toss picked, not the first line")
    func theOpponentPlaysWhatTheTossPicked() async throws {
        let engine = ScriptedEngine([], byPosition: [Self.start: Self.twoWays()])
        let session = try engineToMove(engine, toss: Toss { _ in 1 })
        defer { session.suspend() }
        session.retune()
        await session.waitForPreparedInterception()
        #expect(session.game.uciMoves == ["d2d4"])
    }

    @Test("a move the search puts a piece behind is never played, whatever the toss says")
    func theTossCannotReachAWorseMove() async throws {
        let engine = ScriptedEngine([], byPosition: [Self.start: Self.twoWays(-300)])
        let session = try engineToMove(engine, toss: Toss { _ in 1 })
        defer { session.suspend() }
        session.retune()
        await session.waitForPreparedInterception()
        #expect(session.game.uciMoves == ["e2e4"])
    }

    /// The whole bug, at the seam it happened on: the second game from the same position.
    @Test("a position the opponent has already played from is searched again")
    func aSecondGameIsNotAReplay() async throws {
        let engine = ScriptedEngine([], byPosition: [Self.start: Self.twoWays()])
        let first = try engineToMove(engine, toss: .strongest)
        first.retune()
        await first.waitForPreparedInterception()
        #expect(first.game.uciMoves == ["e2e4"])
        #expect(engine.positions.filter { $0 == Self.start }.count == 1)
        first.suspend()

        let second = try engineToMove(engine, toss: .strongest)
        defer { second.suspend() }
        second.retune()
        await second.waitForPreparedInterception()
        #expect(second.game.uciMoves == ["e2e4"])
        #expect(
            engine.positions.filter { $0 == Self.start }.count == 2,
            "a game already played is searched again rather than replayed out of the store"
        )
        #expect(engine.budgets.allSatisfy { $0 == PositionSearches.budget })
    }

    /// And the other half of the rule: the search the position has just been given still stands
    /// in for the reply's, so 把关 judging a move does not make the opponent pay for it twice.
    @Test("the search a position was just given is still the opponent's own")
    func theFirstAskIsStillFree() async throws {
        let game = try #require(Game(startFEN: Self.start))
        let engine = ScriptedEngine([], byPosition: [Self.start: Self.twoWays()])
        let session = GameSession.fresh(game, engine: engine)
        // The point here is how many searches it took, not which move came out, so the toss is
        // held still: left to itself it would play either of these two openings.
        session.toss = .strongest
        defer { session.suspend() }
        // The board's own search of the position in front of the player, for 把关 to read.
        session.retune()
        await session.waitForPreparedInterception()
        #expect(engine.positions.filter { $0 == Self.start }.count == 1)
        // Handed to the engine, it plays out of that search and starts none of its own.
        session.setController(.engine, for: .white)
        await session.waitForPreparedInterception()
        #expect(session.game.uciMoves == ["e2e4"])
        #expect(engine.positions.filter { $0 == Self.start }.count == 1)
    }
}
