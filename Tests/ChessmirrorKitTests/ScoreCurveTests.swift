@testable import ChessmirrorKit
import Foundation
import Testing

/// Contract: a 分数曲线 is a value of its own (`ScoreCurve`) — a level per position, nil where
/// nobody has scored it — and one Score is a number, not a shape. It stands alone: a test
/// builds one from a list of Scores and never needs a session, an engine or a game.
@Suite struct ScoreCurveTests {
    @Test func oneScoreIsANumberNotAShape() {
        #expect(!ScoreCurve(scores: [nil, .centipawns(10)]).isDrawable)
        #expect(!ScoreCurve(scores: [.centipawns(10)]).isDrawable, "one point, however known")
        #expect(ScoreCurve(scores: [nil, .centipawns(10), nil, .centipawns(20)]).isDrawable)
    }

    @Test func thePliesAreTheGapsBetweenThePositions() {
        #expect(ScoreCurve(scores: []).plies == 0)
        #expect(ScoreCurve(scores: [.centipawns(0)]).plies == 0, "a starting position is not a move")
        #expect(ScoreCurve(scores: [nil, nil, nil, nil]).plies == 3)
    }

    @Test func knownIsWhereAnybodyHasScoredAndTheLastIsWhereTheCurveReaches() {
        let curve = ScoreCurve(scores: [nil, .centipawns(20), nil, .centipawns(-40), nil])
        #expect(curve.known == [1, 3])
        #expect(curve.lastKnownPly == 3)
    }

    @Test func aScoreIsReadByPlyAndOffTheEndIsNotAPosition() {
        let curve = ScoreCurve(scores: [nil, .centipawns(20), nil])
        #expect(curve.score(atPly: 0) == nil)
        #expect(curve.score(atPly: 1) == .centipawns(20))
        #expect(curve.score(atPly: 2) == nil)
        #expect(curve.score(atPly: 9) == nil, "past the end is not a position")
        #expect(curve.score(atPly: -1) == nil)
    }

    @Test func mateScoresAreScoresToo() {
        let curve = ScoreCurve(scores: [.centipawns(0), .mate(in: 3), nil])
        #expect(curve.isDrawable)
        #expect(curve.score(atPly: 1) == .mate(in: 3))
    }
}
