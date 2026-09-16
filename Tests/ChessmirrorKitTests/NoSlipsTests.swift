import Foundation
import Testing

@testable import ChessmirrorKit
import ChessmirrorKitTesting

/// Contract: 连正 comes out of the game as the glossary defines it — the run of the player's moves
/// that stood under 正着 since the last 试招 — with 正着 off pausing the run and nothing but a 试招
/// ending it (CONTEXT.md).
@MainActor
@Suite struct NoSlipsTests {
    private static let under = Game.Ply.Judgement(
        drop: 1, score: .centipawns(20), depth: 20, intercept: 5
    )
    private static let measured = Game.Ply.Judgement(drop: 1, score: .centipawns(20), depth: 20)

    /// 1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. c3 Nf6 5. d4 — White's moves judged along the way.
    private func italian() throws -> Game {
        try #require(Game(
            startFEN: PGN.standardStartFEN,
            uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6", "d2d4"]
        ))
    }

    @Test func runAndLongestRunAreReadAsTheGlossaryDefinesThem() throws {
        var game = try italian()
        game.setJudgement(Self.under, atPly: 0)
        // Nf3 stood after Nh3 was taken back: a 试招 ends the run, and the move that then stood
        // begins a new one.
        game.setJudgement(Self.under, atPly: 2)
        game.setTried([.init(san: "Nh3", drop: 12)], atPly: 2)
        game.setJudgement(Self.under, atPly: 4)
        // c3 was measured with 正着 off: counted nowhere, and the run is paused, not ended.
        game.setJudgement(Self.measured, atPly: 6)
        game.setJudgement(Self.under, atPly: 8)

        let read = game.noSlips(by: [.white])
        #expect(read.run == 3, "Nf3, Bc4 and d4 since Nh3 was taken back; c3 did not stand under 正着")
        #expect(read.longestRun == 3)
        #expect(game.noSlips(by: [.black]) == .none, "Black's moves were never judged")
    }

    /// The walk under the row and under the 正着榜 is one walk: each of the player's own moves,
    /// with whether it stood, whether a 试招 came before it, and the rung it was played against.
    @Test func theRowAndTheLadderReadTheSameOwnMoves() throws {
        // 1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. c3 Nf6, White to move.
        var game = try #require(Game(
            startFEN: PGN.standardStartFEN,
            uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6"]
        ))
        game.setJudgement(Self.under, atPly: 0)
        game.setJudgement(Self.under, atPly: 2)
        game.setTried([.init(san: "Nh3", drop: 12)], atPly: 2)
        game.setJudgement(Self.measured, atPly: 4)
        game.setStrength(.elo(1400), atPly: 1)
        game.setStrength(.elo(1800), atPly: 3)
        // And a refusal waiting at the end, where White's next move would go.
        game.recordTried(.init(san: "Ke2", drop: 30), atPly: 8)

        let moves = game.ownMoves(by: [.white])
        #expect(moves.map(\.ply) == [1, 3, 5, 7, 9], "four moves and the place the refusal waits at")
        #expect(moves.map(\.stood) == [true, true, false, false, false])
        #expect(moves.map(\.afterSlip) == [false, true, false, false, true])
        #expect(
            moves.map(\.strength) == [.elo(1400), .elo(1800), .elo(1800), nil, nil],
            "Bc4 by the rung before it; c3 has no engine move within reach to say"
        )

        // Both readers agree with the walk, and with each other, about the refusal at the end.
        #expect(game.noSlips(by: [.white]) == .init(run: 0, longestRun: 1))
        let credits = Ladder.credits(in: game, by: [.white])
        #expect(credits.count == 2, "a run of one at each rung")
        #expect(credits.first { $0.strength == .elo(1800) }?.longestRun == 1)
        #expect(game.ownMoves(by: [.black]).map(\.ply) == [2, 4, 6, 8], "Black's moves, and no refusal of Black's")
    }

    @Test func aRefusalWaitingAtTheEndZeroesTheRun() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
        game.setJudgement(Self.under, atPly: 0)
        #expect(game.noSlips(by: [.white]) == .init(run: 1, longestRun: 1))

        // Stopped at the position after e5, with no move played there yet (docs/adr/0037).
        game.recordTried(.init(san: "Ke2", drop: 30), atPly: 2)
        #expect(game.noSlips(by: [.white]) == .init(run: 0, longestRun: 1))
        #expect(game.noSlips(by: [.black]) == .none, "the refusal was White's, not Black's")

        // The next move that stands takes the refusal with it and starts a run of one.
        let stood = game.apply(uci: "g1f3")
        #expect(stood)
        game.absorbPendingTried(atPly: 2)
        game.setJudgement(Self.under, atPly: 2)
        #expect(game.noSlips(by: [.white]) == .init(run: 1, longestRun: 1))
    }

    @Test func switchingNoSlipsOffPausesTheRunRatherThanResettingIt() throws {
        var game = try italian()
        game.setJudgement(Self.under, atPly: 0)
        game.setJudgement(Self.measured, atPly: 2)
        game.setJudgement(Self.under, atPly: 4)
        #expect(game.noSlips(by: [.white]) == .init(run: 2, longestRun: 2))
    }

    @Test func movesAgainstAHumanCountAllTheSame() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3"]))
        game.setJudgement(Self.under, atPly: 0)
        game.setJudgement(Self.under, atPly: 1)
        game.setJudgement(Self.under, atPly: 2)
        #expect(game.noSlips(by: [.white, .black]) == .init(run: 3, longestRun: 3))
        #expect(game.noSlips(by: [.white]) == .init(run: 2, longestRun: 2))
    }

    @Test func theFiguresSurviveTheFile() throws {
        var game = try italian()
        game.setJudgement(Self.under, atPly: 0)
        game.setJudgement(Self.under, atPly: 2)
        game.setTried([.init(san: "Nh3", drop: 12)], atPly: 2)
        game.setJudgement(Self.measured, atPly: 4)
        let text = PGN(game: game).text
        #expect(text.contains("under 5.0"))
        let read = try PGN(parsing: text).game
        #expect(read.noSlips(by: [.white]) == game.noSlips(by: [.white]))
        #expect(read.plies[4].judgement?.intercept == nil, "a measured move stays a measured move")
    }

    /// The session's own reading: a refusal leaves the run at nought, and the next move that
    /// stands is a run of one.
    @Test func theSessionReadsTheFiguresOffItsGame() async throws {
        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        let afterF3 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3"]))
        let afterE4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
        let engine = ScriptedEngine([], byPosition: [
            start.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])]),
            afterF3.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(-300), uciMoves: ["e7e5"], san: ["e5"])]),
            afterE4.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(0), uciMoves: ["e7e5"], san: ["e5"])]),
        ])
        let session = GameSession.fresh(start, engine: engine)
        defer { session.suspend() }
        session.setIntercept(10)
        await session.waitForPreparedInterception()
        #expect(session.noSlips == .none)

        session.play(try #require(start.state.move(matching: "f2f3")))
        await session.waitForJudgement()
        #expect(session.refused?.san == "f3")
        #expect(session.noSlips == .init(run: 0, longestRun: 0))

        session.play(try #require(start.state.move(matching: "e2e4")))
        await session.waitForJudgement()
        #expect(session.game.uciMoves == ["e2e4"])
        #expect(session.noSlips == .init(run: 1, longestRun: 1))
        #expect(session.game.plies[0].judgement?.intercept == 10)

        // With 正着 off, the figures stand as they were.
        session.setTilling(false)
        #expect(session.noSlips.longestRun == 1)
    }
}
