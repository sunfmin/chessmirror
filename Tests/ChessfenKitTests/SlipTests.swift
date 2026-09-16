@testable import ChessfenKit
import Testing

/// Contract: a game can say where the player went wrong in it — one entry per Ply, carrying the
/// position that move was played from, at the two weights the app's two lines already draw
/// (docs/adr/0036).
@MainActor
@Suite struct SlipTests {
    /// White gets ply 1 wrong twice before a move stands, and ply 3 wrong once. Black's ply 2 is
    /// a 试招 too, and is not the player's.
    private func played() throws -> Game {
        var game = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3"])
        )
        game.setTried([.init(san: "f3", drop: 24), .init(san: "a3", drop: 12)], atPly: 0)
        game.setJudgement(.init(drop: 0, score: .centipawns(20), depth: 20), atPly: 0)
        game.setTried([.init(san: "d6", drop: 30)], atPly: 1)
        game.setJudgement(.init(drop: 14, score: .centipawns(-40), depth: 20), atPly: 2)
        return game
    }

    /// One entry per position, and every wrong move made at it — a position is not a move, and a
    /// player at one position tries what they try.
    @Test func oneEntryPerPositionWithEveryWrongMoveMadeThere() throws {
        let slips = try played().slips(by: [.white], lines: .standard)
        #expect(slips.map(\.ply) == [1, 3], "one stop per place in the game, and not Black's move")
        let first = try #require(slips.first)
        #expect(first.wrong.map(\.san) == ["f3", "a3"], "both 试招, worst first")
        #expect(first.wrong.allSatisfy { $0.wasTried })
        #expect(first.drop == 24, "and the entry is worth stopping for the worst of them")
        let third = try #require(slips.last)
        #expect(third.wrong.map(\.san) == ["Nf3"])
        #expect(!third.wrong[0].wasTried, "this one stood, and the [%judged] is where its cost came from")
    }

    /// The position carried is the one the move was played **from** — the one to try again from.
    @Test func thePositionIsTheOneTheMoveWasPlayedFrom() throws {
        let game = try played()
        let slips = game.slips(by: [.white], lines: .standard)
        let opening = try #require(PositionKey(fen: PGN.standardStartFEN))
        #expect(slips[0].position == opening, "the first move was played from the opening")
        let afterTwo = try #require(game.rewound(to: 2))
        #expect(
            slips[1].position == PositionKey(fen: afterTwo.state.fen),
            "and the third Ply from the position two Plies in"
        )
    }

    /// The mark goes on a *position*, and the record strip's cells are positions: a mistake at Ply
    /// `n` is marked on the cell at `n - 1`, which is the one that shows the board it was played
    /// from. Getting this wrong put every mark one move too late, which is to say on a position
    /// the player was not mistaken in.
    @Test func theMarkBelongsToThePositionNotTheMove() throws {
        let game = try played()
        let slips = game.slips(by: [.white], lines: .standard)
        #expect(slips.map(\.ply) == [1, 3])
        #expect(slips.map(\.positionPly) == [0, 2], "the opening, and the position after two Plies")
    }

    /// A refusal nothing absorbed is the position the game ends on, which is the cell of the last
    /// move — and when a move is played there and takes it, the same position, still.
    @Test func aTailRefusalBelongsToTheEndOfTheGame() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
        game.setPendingTried([.init(san: "Qh4", drop: 30)], atPly: game.plies.count)
        let slips = game.slips(by: [.white], lines: .standard)
        #expect(slips.map(\.ply) == [2])
        #expect(slips[0].positionPly == 1, "the position after the only move")
        #expect(slips[0].wasTried)
    }

    /// Two lines, two weights — which is the whole reason the list is one list rather than two:
    /// everything here has been written down, and only some of it is still owed.
    @Test func theEnrolLineSaysWhichOnesAreOwed() throws {
        let game = try played()
        let lines = JudgementLines(intercept: nil, record: 10, enqueue: 20)
        let slips = game.slips(by: [.white], lines: lines)
        #expect(
            slips.map { $0.isWorthDrilling(lines) } == [true, false],
            "24% is owed, 14% is not"
        )
    }

    /// The 记录线 is what the list is gated on: below it there is nothing to find.
    @Test func aGameNobodyGotAnythingWrongInHasNoSlips() throws {
        let clean = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"])
        )
        #expect(clean.slips(by: [.white], lines: .standard).isEmpty)
        // A game whose judgements are all under the line is the same nothing.
        var quiet = clean
        quiet.setJudgement(.init(drop: 3, score: .centipawns(10), depth: 20), atPly: 0)
        #expect(quiet.slips(by: [.white], lines: .standard).isEmpty)
    }
}
