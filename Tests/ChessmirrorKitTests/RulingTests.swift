@testable import ChessmirrorKit
import Foundation
import Testing

/// Contract: what 正着 rules about a weighed move is a pure reading, and the game it leaves behind
/// is part of the ruling — the session, the drill's attempt and the exercise all get the same answer
/// from the same facts, with no engine and no session in the room.
@Suite("Ruling")
struct RulingTests {
    private func opening(_ uciMoves: [String] = []) throws -> Game {
        try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: uciMoves))
    }

    private func analysis(_ cp: Int, _ uci: String, _ san: String) -> Analysis {
        Analysis(depth: 20, lines: [Line(score: .centipawns(cp), uciMoves: [uci], san: [san])])
    }

    /// White plays `uci` from `before`, and the engine says the position went from `cp` to `after`.
    private func weigh(_ uci: String, from before: Game, cp: Int, after: Int, reply: [String] = ["e5"]) throws
        -> (played: Game, san: String, weighed: Weighing)
    {
        var played = before
        let applied = played.apply(uci: uci)
        try #require(applied)
        let san = try #require(played.plies.last?.san)
        let weighed = try #require(Weighing(
            mover: before.state.sideToMove, before: analysis(cp, "e2e4", "e4"),
            after: .centipawns(after), depth: 20, reply: reply
        ))
        return (played, san, weighed)
    }

    @Test func aMoveUnderTheLineStandsAndTakesTheRefusalsMadeBeforeIt() throws {
        var before = try opening()
        before.recordTried(.init(san: "f3", drop: 20, line: ["e5"]), atPly: 0)
        let (played, san, weighed) = try weigh("e2e4", from: before, cp: 30, after: 20)

        let ruling = Ruling(weighed, san: san, played: played, before: before, cursor: 0,
                            lines: JudgementLines(intercept: 5), hints: 2)

        #expect(ruling.verdict == .stands(MoveChange(before: .centipawns(30), after: .centipawns(20))))
        #expect(!ruling.takesTheMoveBack)
        #expect(ruling.cursor == 1)
        #expect(ruling.game.uciMoves == ["e2e4"])
        let stood = try #require(ruling.game.plies[0].judgement)
        #expect(stood == .init(drop: weighed.drop, score: .centipawns(20), depth: 20, intercept: 5))
        #expect(stood.stoodUnderNoSlips)
        #expect(ruling.game.plies[0].tried.map(\.san) == ["f3"], "the refusal rides on the move that stands")
        #expect(ruling.game.plies[0].hints == 2)
        #expect(ruling.game.pendingTried.isEmpty)
    }

    /// A move played from the middle of a game is refused *there*: the game stays whole, the refusal
    /// is written at the position it happened at, and the eye goes back where it stood.
    @Test func aMoveOverTheLineIsRefusedWhereTheEyeStood() throws {
        let before = try opening(["e2e4", "e7e5", "g1f3", "b8c6"])
        let twoIn = try #require(before.rewound(to: 2))
        let (played, san, weighed) = try weigh("f1c4", from: twoIn, cp: 30, after: -400, reply: ["Nf6", "d3"])
        #expect(played.uciMoves == ["e2e4", "e7e5", "f1c4"], "the board showed the move while it was weighed")

        let ruling = Ruling(weighed, san: san, played: played, before: before, cursor: 2,
                            lines: JudgementLines(intercept: 5), hints: 1)

        #expect(ruling.verdict == .refused(Refusal(san: "Bc4", drop: weighed.drop)))
        #expect(ruling.takesTheMoveBack)
        #expect(ruling.cursor == 2)
        #expect(ruling.game.uciMoves == before.uciMoves, "the line being read is not swallowed")
        #expect(ruling.game.pendingTries(atPly: 2) == [.init(san: "Bc4", drop: weighed.drop, depth: weighed.depth, line: ["Nf6", "d3"])], "with the depth it was judged at (docs/adr/0041)")
        #expect(ruling.game.plies.allSatisfy { $0.judgement == nil && $0.tried.isEmpty })
    }

    /// Two refusals at one position, then a move that stands: the move carries both, in order.
    @Test func theMoveThatStandsTakesEveryRefusalInTheOrderTheyHappened() throws {
        let start = try opening()
        let lines = JudgementLines(intercept: 5)
        var game = start
        var cursor = 0
        for uci in ["f2f3", "g2g4"] {
            let (played, san, weighed) = try weigh(uci, from: game, cp: 0, after: -300)
            let ruling = Ruling(weighed, san: san, played: played, before: game, cursor: cursor, lines: lines)
            #expect(ruling.takesTheMoveBack)
            game = ruling.game
            cursor = ruling.cursor
        }
        #expect(game.pendingTries(atPly: 0).map(\.san) == ["f3", "g4"])

        let (played, san, weighed) = try weigh("e2e4", from: game, cp: 0, after: 0)
        let ruling = Ruling(weighed, san: san, played: played, before: game, cursor: cursor, lines: lines)

        #expect(ruling.game.uciMoves == ["e2e4"])
        #expect(ruling.game.plies[0].tried.map(\.san) == ["f3", "g4"])
        #expect(ruling.game.pendingTried.isEmpty)
    }

    @Test func nothingIsWrittenWhenNobodyLooked() throws {
        var before = try opening(["e2e4", "e7e5"])
        before.recordTried(.init(san: "Qh5", drop: 12), atPly: 2)
        let (played, san, _) = try weigh("g1f3", from: before, cp: 0, after: 0)

        let ruling = Ruling(nil, san: san, played: played, before: before, cursor: 2,
                            lines: JudgementLines(intercept: 5), hints: 3)

        #expect(ruling.verdict == .unjudged)
        #expect(ruling.takesTheMoveBack, "the move comes off the board")
        #expect(ruling.game == before, "and nothing is written, not even a refusal")
        #expect(ruling.cursor == 2)
    }

    /// The hint ladder climbed to a relaxed line lets a move through that the 拦截线 would have
    /// stopped — and writes it down as a 试招 the player did not find, under the line it stood at.
    @Test func aRelaxedLineLetsTheMoveThroughAsAMoveNotFound() throws {
        var before = try opening()
        before.recordTried(.init(san: "f3", drop: 20), atPly: 0)
        let (played, san, weighed) = try weigh("d2d4", from: before, cp: 30, after: -100)
        let lines = JudgementLines(intercept: weighed.drop - 1, record: 5)
        #expect(Ruling.intercepts(weighed.drop, lines: lines), "the line as set would have stopped it")
        #expect(!Ruling.intercepts(weighed.drop, lines: lines, relaxedIntercept: weighed.drop + 1))

        let ruling = Ruling(weighed, san: san, played: played, before: before, cursor: 0,
                            lines: lines, relaxedIntercept: weighed.drop + 1, hints: 3)

        #expect(!ruling.takesTheMoveBack)
        let judgement = try #require(ruling.game.plies[0].judgement)
        #expect(judgement.intercept == weighed.drop + 1, "it stood under the relaxed line")
        #expect(ruling.game.plies[0].tried.map(\.san) == ["f3", "d4"], "after the ones refused on the way")
        #expect(ruling.game.plies[0].tried.last?.notFound == true)
        #expect(ruling.game.plies[0].hints == 3)
    }

    /// With 正着 off a move is measured — the badge needs the number — but never stood: no line, no
    /// refusal, and a judgement that does not count for 正着数.
    @Test func withNoSlipsOffAMoveIsMeasuredButNeverStood() throws {
        let before = try opening()
        let (played, san, weighed) = try weigh("g2g4", from: before, cp: 30, after: -500)
        #expect(!Ruling.intercepts(weighed.drop, lines: .standard))

        let ruling = Ruling(weighed, san: san, played: played, before: before, cursor: 0, lines: .standard)

        #expect(!ruling.takesTheMoveBack)
        let judgement = try #require(ruling.game.plies[0].judgement)
        #expect(judgement.drop == weighed.drop)
        #expect(judgement.intercept == nil)
        #expect(!judgement.stoodUnderNoSlips)
    }

    /// A drill's attempt is ruled at the same line. The drill has already written its judgement,
    /// without a 拦截线 on it, and that is left alone: a drill's move never counts as one that stood.
    @Test func aDrillsAttemptIsRuledAtTheSameLineAndKeepsItsOwnJudgement() throws {
        let start = try opening()
        var attempted = start
        let applied = attempted.apply(uci: "g2g4")
        try #require(applied)
        attempted.setJudgement(.init(drop: 30, score: .centipawns(-500), depth: 20), atPly: 0)
        let verdict = DrillVerdict(played: "g4", intent: Intent.read(try #require(start.state.move(matching: "g2g4")), in: start),
                                   drop: 30, passed: false, reply: ["d5"])

        let refused = Ruling(verdict, in: attempted, startingScore: .centipawns(30), lines: JudgementLines(intercept: 5))
        #expect(refused.verdict == .refused(Refusal(san: "g4", drop: 30)))
        #expect(refused.cursor == 0)
        #expect(refused.game.plies.isEmpty, "back to the position alone")
        #expect(refused.game.pendingTries(atPly: 0) == [.init(san: "g4", drop: 30, line: ["d5"])])

        let stood = Ruling(verdict, in: attempted, startingScore: .centipawns(30), lines: JudgementLines(intercept: 50))
        #expect(stood.verdict == .stands(MoveChange(before: .centipawns(30), after: .centipawns(-500))))
        #expect(stood.cursor == 1)
        #expect(stood.game == attempted, "the drill's judgement is left as it wrote it")
        #expect(stood.game.plies[0].judgement?.stoodUnderNoSlips == false)

        let unmeasured = Ruling(verdict, in: attempted, startingScore: nil, lines: .standard)
        #expect(unmeasured.verdict == .stands(nil), "no badge without both ends measured")
    }
}
