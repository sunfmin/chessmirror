@testable import ChessmirrorKit
import Foundation
import Testing

/// Contract: 最佳 is a fact about which move it was, written on the move when it stands and read
/// off the Review otherwise — never a 掉幅 that rounded to nought (CONTEXT.md).
@Suite struct BestMoveTests {
    private static func line(_ cp: Int, _ moves: [(String, String)]) -> Line {
        Line(score: .centipawns(cp), uciMoves: moves.map(\.0), san: moves.map(\.1))
    }

    @Test("a ruling that lets the engine's own choice stand writes 最佳 on the move")
    func aRulingWritesBest() throws {
        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        var played = start
        let applied = played.apply(uci: "e2e4")
        try #require(applied)
        let before = Analysis(depth: 20, lines: [
            Self.line(30, [("e2e4", "e4"), ("e7e5", "e5")]), Self.line(20, [("d2d4", "d4")]),
        ])
        let weighed = try #require(Weighing(
            mover: .white, before: before, after: .centipawns(30), depth: 20, move: "e2e4"
        ))
        let ruling = Ruling(
            weighed, san: "e4", played: played, from: Standpoint(game: start, cursor: 0),
            lines: JudgementLines(noSlips: true, record: 5, enqueue: 5)
        )
        #expect(ruling.game.plies[0].judgement?.best == true)
        #expect(ruling.game.isBest(atPly: 1))

        let second = try #require(Weighing(
            mover: .white, before: before, after: .centipawns(20), depth: 20, move: "d2d4"
        ))
        var d4 = start
        let appliedD4 = d4.apply(uci: "d2d4")
        try #require(appliedD4)
        let other = Ruling(
            second, san: "d4", played: d4, from: Standpoint(game: start, cursor: 0),
            lines: JudgementLines(noSlips: true, record: 5, enqueue: 5)
        )
        #expect(other.game.plies[0].judgement?.best == false)
        #expect(!other.game.isBest(atPly: 1))
    }

    @Test("最佳 survives the file, and a file without the word reads as not 最佳")
    func bestSurvivesTheFile() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
        game.setJudgement(.init(drop: 0, score: .centipawns(30), depth: 20, intercept: 10, best: true), atPly: 0)
        game.setJudgement(.init(drop: 0, score: .centipawns(30), depth: 20, best: true), atPly: 1)
        let text = PGN(game: game).text
        #expect(text.contains("under 10.0 best]"))
        #expect(text.contains("+0.30 best]") || text.contains("0.30 best]"))
        let read = try PGN(parsing: text).game
        #expect(read.plies[0].judgement?.best == true)
        #expect(read.plies[0].judgement?.intercept == 10)
        #expect(read.plies[1].judgement?.best == true)
        #expect(read.isBest(atPly: 1))
        #expect(read.isBest(atPly: 2))

        let legacy = try PGN(parsing: "1. e4 {[%judged 20 0.0 +0.30 under 10.0]} e5 {[%judged 20 0.0 +0.30]} *").game
        #expect(legacy.plies[0].judgement?.best == false, "nought is not the same as 最佳")
        #expect(!legacy.isBest(atPly: 1))
        #expect(legacy.plies[1].judgement?.intercept == nil)
    }

    @Test("a Review names 最佳 by the Line it wanted from the position before")
    func aReviewNamesBest() throws {
        var game = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6"])
        )
        game.applyReview(
            [
                .init(score: .centipawns(30), line: ["e5", "Nf3", "Nc6"]),
                .init(score: .centipawns(30), line: ["Nf3", "Nc6"]),
                .init(score: .centipawns(30), line: ["Nf6"]),
                .init(score: .centipawns(30), line: []),
            ],
            startEvaluation: .centipawns(20), depth: 18
        )
        #expect(!game.isBest(atPly: 1), "no Line before the first move says what was wanted")
        #expect(game.isBest(atPly: 2), "e5, which the Line after e4 wanted")
        #expect(game.isBest(atPly: 3))
        #expect(!game.isBest(atPly: 4), "Nc6 where the Line wanted Nf6, though it cost nought")
        #expect(game.cost(atPly: 4) == 0)
    }
}
