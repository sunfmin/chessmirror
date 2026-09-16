@testable import ChessmirrorKit
import ChessmirrorKitTesting
import Testing

/// Contract: the wrong moves listed under the record belong to the position on the board. A 错题
/// tile walked to shows that position's own 试招, and a move that stood too expensively — the only
/// kind of 错招 an imported game has — is listed and answered the way a refusal is
/// (docs/adr/0034, 0036).
@MainActor
@Suite struct WrongMovesTests {
    /// e4 e5 Nf3, with f3 refused at the opening before e4 stood.
    private func refusedThenStood() throws -> Game {
        var game = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3"])
        )
        game.setTried([.init(san: "f3", drop: 24, line: ["e5"])], atPly: 0)
        return game
    }

    /// e4 e5 Nf3 as an imported game: nothing refused, Nf3 judged at 14%, and a Review whose
    /// Line after Nf3 is the answer to it.
    private func reviewed() throws -> Game {
        var game = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3"])
        )
        game.setJudgement(.init(drop: 14, score: .centipawns(-40), depth: 20), atPly: 2)
        game.applyReview(
            [
                ReviewedPly(score: .centipawns(30), line: ["e5"]),
                ReviewedPly(score: .centipawns(30), line: ["Nf3"]),
                ReviewedPly(score: .centipawns(-40), line: ["Nc6", "Bb5"]),
            ],
            startEvaluation: .centipawns(30), depth: 20
        )
        return game
    }

    /// The tile takes the board to the position the move was played from, and the moves listed
    /// there are that position's — not the Ply behind it, which is where they used to be read.
    @Test func aTileWalkedToListsThePositionsOwnAttempts() throws {
        let session = GameSession.fresh(try refusedThenStood())
        defer { session.suspend() }
        let slip = try #require(session.slips.first)
        session.jump(toPly: slip.positionPly)
        #expect(session.cursor == 0)
        #expect(session.visibleAttempts.map(\.san) == ["f3"], "the opening's own refusal")
        #expect(session.refusedPosition == session.viewed)
        #expect(session.visibleWrongs.map(\.san) == ["f3"])
        #expect(session.visibleWrongs.first?.triedIndex == 0)
        #expect(session.visibleWrongs.first?.stood == false)

        session.readReply(at: 0)
        let reading = try #require(session.replyReading)
        #expect(reading.line == ["f3", "e5"])
        #expect(reading.position == session.viewed)
    }

    /// At the position after the move that stood, the eye is on that move, and the strip still
    /// says what it took with it — the live game's view, unchanged.
    @Test func theMoveThatLandedStillShowsWhatItTookWithIt() throws {
        let session = GameSession.fresh(try refusedThenStood())
        defer { session.suspend() }
        session.jump(toPly: 1)
        #expect(session.visibleAttempts.map(\.san) == ["f3"])
        #expect(session.refusedPosition == session.game.rewound(to: 0))
        #expect(session.visibleWrongs.map(\.san) == ["f3"])
        session.jump(toPly: 2)
        #expect(session.visibleAttempts.isEmpty, "e5 took nothing, and the position after it has nothing of its own")
        #expect(session.visibleWrongs.isEmpty)
    }

    /// An imported game's 错招 stood. At its own position it is a chip like a refusal's, its 应招
    /// is the Review's Line from the position it made, and there is no 复判 to offer for it.
    @Test func aMoveThatStoodTooExpensivelyIsListedAndAnswered() throws {
        let session = GameSession.fresh(try reviewed(), engine: ScriptedEngine([]))
        defer { session.suspend() }
        let slip = try #require(session.slips.first)
        #expect(slip.ply == 3)
        session.jump(toPly: slip.positionPly)
        #expect(session.cursor == 2)
        #expect(session.visibleAttempts.isEmpty, "nothing was ever refused in an imported game")

        let wrong = try #require(session.visibleWrongs.first)
        #expect(session.visibleWrongs.count == 1)
        #expect(wrong.stood)
        #expect(wrong.source == .stood(ply: 3))
        #expect(wrong.san == "Nf3")
        #expect(wrong.drop == 14)
        #expect(wrong.depth == 20)
        #expect(wrong.line == ["Nc6", "Bb5"], "the Review's Line after the move is its 应招")
        #expect(session.refusedPosition == session.viewed)

        session.readReply(at: 0)
        let reading = try #require(session.replyReading)
        #expect(!reading.isAsking)
        #expect(reading.line == ["Nf3", "Nc6", "Bb5"])
        #expect(reading.steps.map(\.isYours) == [true, false, true])
        #expect(session.rejudgeOffer(at: 0) == .none, "the game judged it; a 复判 is for a 试招")
        session.rejudge(at: 0)
        #expect(session.rejudging == nil)

        // Not at the position after it: there the badge says what the move cost.
        session.jump(toPly: 3)
        #expect(session.visibleWrongs.isEmpty)
    }

    /// A move that stood in a game nobody reviewed has no Line kept: pressing it asks the shared
    /// search for the position it made, as a 试招 without a reply does.
    @Test func aMoveThatStoodWithNoLineKeptAsksTheSearch() async throws {
        var game = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3"])
        )
        game.setJudgement(.init(drop: 14, score: .centipawns(-40), depth: 20), atPly: 2)
        let engine = ScriptedEngine([], byPosition: [
            game.state.fen: Analysis(depth: 20, lines: [
                .init(score: .centipawns(40), uciMoves: ["b8c6"], san: ["Nc6"])
            ]),
        ])
        let session = GameSession.fresh(game, engine: engine)
        defer { session.suspend() }
        session.jump(toPly: 2)
        let wrong = try #require(session.visibleWrongs.first)
        #expect(wrong.stood)
        #expect(wrong.line.isEmpty)

        session.readReply(at: 0)
        #expect(session.replyReading?.isAsking == true)
        let deadline = ContinuousClock.now + .seconds(5)
        while session.replyReading?.isAsking == true, ContinuousClock.now < deadline {
            await Task.yield()
        }
        let reading = try #require(session.replyReading)
        #expect(!reading.isAsking)
        #expect(reading.line == ["Nf3", "Nc6"])
    }
}
