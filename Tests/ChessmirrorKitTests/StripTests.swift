@testable import ChessmirrorKit
import Foundation
import Testing

/// Contract: the strip under the board is one value the session produces — voice, tally, depth
/// and bar — and every state of it is reachable here without a screen (`Strip`, docs/adr/0020).
@Suite("Strip")
@MainActor
struct StripTests {
    private func opening(_ uciMoves: [String] = []) throws -> Game {
        try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: uciMoves))
    }

    /// Every game has the strip: there is no switch that turns the bar or the depth off
    /// (docs/adr/0040). A game nothing has judged yet draws an empty bar and a depth of zero.
    @Test func aGameNothingHasJudgedHasAnEmptyBar() throws {
        let session = GameSession.fresh(try opening(["e2e4"]))
        defer { session.suspend() }

        #expect(session.strip == Strip(
            voice: .quiet, tally: nil, depth: 0, bar: Strip.Bar(score: nil, finish: nil)
        ))
    }

    /// A bar to draw, reading what was written on the move on screen, and a depth to account
    /// for — zero before the search has said anything.
    @Test func theBarReadsTheJudgementOnTheMove() throws {
        var game = try opening(["e2e4", "e7e5"])
        game.setJudgement(.init(drop: 1, score: .centipawns(35), depth: 20), atPly: 1)
        let session = GameSession.fresh(game)
        defer { session.suspend() }

        #expect(session.strip.bar == Strip.Bar(score: .centipawns(35), finish: nil))
        #expect(session.strip.depth == 0)
        #expect(session.strip.voice == .quiet)
        #expect(session.strip.tally == nil, "nothing stood under 正着, so nothing to count")
    }

    /// A finished game draws its result, and has no search to account for.
    @Test func aFinishedGameReadsItsResult() throws {
        let mated = try opening(["f2f3", "e7e5", "g2g4", "d8h4"])
        let session = GameSession.fresh(mated)
        defer { session.suspend() }

        #expect(mated.finish == .won(.black))
        #expect(session.strip.bar == Strip.Bar(score: nil, finish: .won(.black)))
        #expect(session.strip.depth == nil)
        #expect(session.strip.voice == .finished("\(mated.turn) 0-1"))
    }

    @Test func aDrawIsHalfABar() throws {
        let stalemate = try #require(Game(startFEN: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"))
        #expect(stalemate.state.outcome.isDraw)
        #expect(stalemate.finish == .drawn)
        #expect(Finish.drawn.whiteShare == 0.5)
        #expect(Finish.won(.white).whiteShare == 1)
        #expect(Finish.won(.black).whiteShare == 0)
        #expect(try opening().finish == nil)
    }

    /// The tally is on the strip for as long as 正着 is on or has left something standing.
    @Test func theTallyShowsWhileNoSlipsIsOnOrHasLeftSomethingStanding() throws {
        let session = GameSession.fresh(try opening())
        defer { session.suspend() }
        #expect(session.strip.tally == nil)

        session.setNoSlips(true)
        #expect(session.strip.tally == Game.NoSlips(run: 0, longestRun: 0), "on, with nothing yet")

        session.setNoSlips(false)
        #expect(session.strip.tally == nil, "off again with nothing stood, and the row is as it was")

        var stood = try opening(["e2e4", "e7e5"])
        stood.setJudgement(.init(drop: 1, score: .centipawns(20), depth: 20, intercept: 5), atPly: 0)
        let after = GameSession.fresh(stood)
        defer { after.suspend() }
        #expect(after.strip.tally?.longestRun == 1, "off, but a move stood: the tally stays")
    }
}
