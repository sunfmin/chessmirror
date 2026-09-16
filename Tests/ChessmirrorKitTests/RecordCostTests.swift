@testable import ChessmirrorKit
import Foundation
import Testing

/// Contract: every move on the record can say what it cost, by whatever number the Game already
/// holds — the judgement written on it first, a Review's difference second, nothing when nobody
/// has measured it — and the answer agrees with the 错招 list wherever that list names a move.
@Suite("Record costs")
struct RecordCostTests {
    @Test func aJudgementFirstAReviewSecondAndNothingWhenUnmeasured() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3"]))
        #expect(!game.hasCosts, "nothing measured, nothing to show")
        #expect(game.cost(atPly: 0) == nil, "the opening is not a move")
        #expect(game.cost(atPly: 1) == nil)

        game.setJudgement(.init(drop: 3.4, score: .centipawns(30), depth: 20), atPly: 0)
        #expect(game.hasCosts)
        #expect(game.cost(atPly: 1) == 3.4)
        #expect(game.cost(atPly: 2) == nil, "the engine's move was never judged, and that is not zero")
        #expect(game.cost(atPly: 4) == nil, "past the end")

        // A Review prices every move, the opponent's included; a judgement already on a move wins.
        game.applyReview(
            [.centipawns(30), .centipawns(90), .centipawns(90)], startEvaluation: .centipawns(20), depth: 16
        )
        #expect(game.cost(atPly: 1) == 3.4, "the judgement stays the move's number")
        let reviewed = try #require(game.cost(atPly: 2))
        #expect(reviewed == game.drop(atPly: 2))
        #expect(reviewed > 0, "Black gave something away")
        #expect(game.cost(atPly: 3) == 0, "White's third move found the best, so it cost nothing")
    }

    @Test func theRecordAndTheSlipListReadTheSameNumberForAMoveThatStood() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3", "e7e5", "g2g4", "d8h4"]))
        game.setJudgement(.init(drop: 32, score: .mate(in: -1), depth: 20, intercept: 5), atPly: 2)
        let lines = JudgementLines(record: 10, enqueue: 20)
        let slips = game.slips(by: [.white], lines: lines)
        let slip = try #require(slips.first)
        let stood = try #require(slip.wrong.first { !$0.wasTried })
        #expect(stood.san == "g4")
        #expect(game.cost(atPly: slip.ply) == stood.drop)
    }
}
