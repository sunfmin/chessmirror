@testable import ChessmirrorKit
import ChessmirrorKitTesting
import Foundation
import Testing

/// Contract: the bar has one number and one place that decides it (`BarReading`). The priority
/// is the move just landed, then a live search of the position on screen, then what the record
/// says of it, then the standing Analysis — and while a move is being weighed, the position it
/// was played from. The number always carries its provenance, so a caller can tell a badge from
/// a live search without re-deriving which chain produced it.
@MainActor
@Suite(.speaking(.chinese)) struct BarReadingTests {
    private func analysis(_ cp: Int, _ uci: String, _ san: String) -> Analysis {
        Analysis(depth: 20, lines: [.init(score: .centipawns(cp), uciMoves: [uci], san: [san])])
    }

    private func hop() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // ------------------------------------------------------------------ the value

    /// The number is whatever the source carries; only `.landed` is a badge.
    @Test func theNumberReadsOffItsSourceAndOnlyALandedSourceIsABadge() {
        let change = MoveChange(before: .centipawns(10), after: .centipawns(40), isBest: true)
        let landed = BarReading(.landed(change))
        #expect(landed.score == .centipawns(40))
        #expect(landed.change == change)

        for source in [BarReading.Source.searching(.centipawns(1)), .record(.centipawns(2))] {
            let reading = BarReading(source)
            #expect(reading.change == nil, "\(source) is not a badge")
            switch source {
            case .searching(let score): #expect(reading.score == score)
            case .record(let score): #expect(reading.score == score)
            case .landed: Issue.record("not this case")
            }
        }
        #expect(BarReading(nil).score == nil, "a bar with no number, which draws a level game")
    }

    /// The identity rule lives in one place: navigating away is not a new move, and a new move
    /// is not this one.
    @Test func aBadgeDescribesOneGameAndNoOther() throws {
        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        var after = start
        let played = after.apply(uci: "e2e4")
        #expect(played)
        let badge = LandedBadge(after, change: MoveChange(before: .centipawns(0), after: .centipawns(1)))
        #expect(badge.describes(after))
        #expect(!badge.describes(start), "the game it was played from is not the game it made")
    }

    // ------------------------------------------------------------------ the priority

    /// A finished game still has a bar number if the record has one — the strip's voice says
    /// the result, and the bar keeps its history (docs/adr/0026).
    @Test func theRecordSuppliesTheNumberWhenNothingIsSearching() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
        game.setJudgement(.init(drop: 1, score: .centipawns(35), depth: 20), atPly: 0)
        game.applyReview([.centipawns(40), .centipawns(20)], startEvaluation: .centipawns(0), depth: 16)
        let session = GameSession.fresh(game)
        defer { session.suspend() }
        session.jumpToLatest()

        guard case .record(let score)? = session.barReading.source else {
            Issue.record("the record is the source when nothing is searching, got \(String(describing: session.barReading.source))")
            return
        }
        #expect(score == .centipawns(20), "the Review's number for the position the game is in")
        #expect(session.barReading.change == nil, "a Review is history, not a badge")
        #expect(session.feedbackScore == score, "and it is the number on the bar")
    }

    /// The badge of the move just played outranks the record: it is the freshest weighing of
    /// exactly this position.
    @Test func theBadgeOfTheMoveJustPlayedOutranksTheRecord() async throws {
        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        let afterE4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
        let engine = ScriptedEngine([], byPosition: [
            start.state.fen: analysis(0, "d2d4", "d4"),
            afterE4.state.fen: analysis(133, "e7e5", "e5"),
        ])
        var withHistory = afterE4
        withHistory.applyReview([.centipawns(0), .centipawns(200)], startEvaluation: .centipawns(0), depth: 8)
        // Play the move ourselves so the badge is written by this session's weighing.
        let session = GameSession.fresh(start, engine: engine)
        defer { session.suspend() }
        session.play(try #require(start.state.move(matching: "e2e4")))
        await session.settled()
        await session.measureLatestMoveChange()

        guard case .landed(let change)? = session.barReading.source else {
            Issue.record("the move just played is the source, got \(String(describing: session.barReading.source))")
            return
        }
        #expect(change.after == .centipawns(133))
        #expect(session.moveChange == change, "the badge under the board is the same change")
        #expect(session.feedbackScore == change.after, "and the bar reads its number")
    }

    /// Navigating the record is not a new move: the badge stays behind and the number falls to
    /// whatever the record says of the position the eye is on.
    @Test func walkingBackLeavesTheBadgeBehind() async throws {
        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        let afterE4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
        let engine = ScriptedEngine([], byPosition: [
            start.state.fen: analysis(0, "d2d4", "d4"),
            afterE4.state.fen: analysis(133, "e7e5", "e5"),
        ])
        let session = GameSession.fresh(start, engine: engine)
        defer { session.suspend() }
        session.play(try #require(start.state.move(matching: "e2e4")))
        await session.settled()
        await session.measureLatestMoveChange()
        #expect(session.barReading.change != nil)

        session.jump(toPly: 0)
        #expect(session.barReading.change == nil, "reading an old position is not a newly played move")
        #expect(session.moveChange == nil)
    }

    /// While a move is being weighed, the position it made has no number — that is what the
    /// weighing is — so the bar steps back to the position the move was played from, and says
    /// so. A bar with no number draws a level game over a position that is nothing like it.
    @Test func whileWeighingTheBarHoldsThePlayedFromPosition() async throws {
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
        try #require(session.barReading.score == .centipawns(300))

        session.play(try #require(start.state.move(matching: "e2e4")))
        for _ in 0..<20 { await Task.yield() }
        try #require(session.isWeighing, "the position the move made has no answer yet")
        #expect(session.barReading.score == .centipawns(300), "not nil, which the bar draws as 50/50")
        #expect(session.strip.bar?.score == .centipawns(300), "and the strip draws the same number")
        #expect(session.feedbackScore == session.barReading.score, "one reading, one number")
    }

    /// A card's Stint and the board's own search are one bounded search in two homes, so the
    /// bar reads it either way — and the engine's opinion is still never a voice
    /// (docs/adr/0040).
    @Test func aCardsSearchIsTheBoardsSearchAndNeverAVoice() async throws {
        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        let engine = ScriptedEngine([analysis(38, "e2e4", "e4")])
        let session = GameSession.fresh(start, engine: engine)
        defer { session.suspend() }
        session.adviseForCard()
        await session.waitForPreparedInterception()
        #expect(session.analysis?.best?.score == .centipawns(38), "the card has its answer")
        guard case .searching(let score)? = session.barReading.source else {
            Issue.record("the live search is the source, got \(String(describing: session.barReading.source))")
            return
        }
        #expect(score == .centipawns(38), "the same search the badge's table is filled from")
        #expect(session.standing == .quiet, "and it is never a voice")
    }
}
