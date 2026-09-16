@testable import ChessmirrorKit
import Foundation
import Testing
import ChessmirrorKitTesting

/// Contract: reading a 应招 is one value the session holds — which 试招 is open, the line it
/// makes, and whether the answer is still coming — opened by asking, filled in when the answer
/// arrives, and closed by asking again or by the board moving on (docs/adr/0034).
@MainActor
@Suite struct ReplyReadingTests {
    /// f3 e5, with g4 refused at the position on the board — the line is whatever the file kept.
    private func afterF3E5(refusing line: [String]) throws -> Game {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3", "e7e5"]))
        game.recordTried(.init(san: "g4", drop: 40, line: line), atPly: 2)
        return game
    }

    @Test func aTriedMoveThatCarriesItsAnswerIsReadAtOnce() throws {
        let session = GameSession.fresh(try afterF3E5(refusing: ["Qh4"]))
        defer { session.suspend() }
        session.jumpToLatest()
        #expect(session.replyReading == nil)

        session.readReply(at: 0)
        let reading = try #require(session.replyReading)
        #expect(reading.index == 0)
        #expect(reading.move.san == "g4")
        #expect(!reading.isAsking)
        #expect(reading.line == ["g4", "Qh4"], "the move that was refused leads its own answer")
        #expect(reading.arrows.map { "\($0.move.from)\($0.move.to)" } == ["g2g4", "d8h4"])
        #expect(reading.steps.map(\.san) == ["g4", "Qh4"])
        #expect(reading.steps.map(\.isYours) == [true, false])
    }

    @Test func aMoveRefusedBeforeRepliesWereKeptAsksTheSharedSearch() async throws {
        let played = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3", "e7e5", "g2g4"])
        )
        let engine = ScriptedEngine([], byPosition: [
            played.state.fen: Analysis(depth: 20, lines: [
                .init(score: .mate(in: -1), uciMoves: ["d8h4"], san: ["Qh4"])
            ]),
        ])
        let session = GameSession.fresh(try afterF3E5(refusing: []), engine: engine)
        defer { session.suspend() }
        session.jumpToLatest()

        session.readReply(at: 0)
        var reading = try #require(session.replyReading)
        #expect(reading.isAsking)
        #expect(reading.line.isEmpty, "nothing is drawn until there is an answer")
        #expect(reading.arrows.isEmpty)

        let deadline = ContinuousClock.now + .seconds(5)
        while session.replyReading?.isAsking == true, ContinuousClock.now < deadline {
            await Task.yield()
        }
        reading = try #require(session.replyReading)
        #expect(!reading.isAsking)
        #expect(reading.line == ["g4", "Qh4"])
        #expect(reading.steps.map(\.san) == ["g4", "Qh4"])
        #expect(engine.positions.filter { $0 == played.state.fen }.count == 1)
    }

    @Test func aLineThatWillNotReplayIsSaidOnlyAsFarAsItGoes() throws {
        // Nc6 is Black's, but after g4 Qh4 it is White to move: the walk stops at the queen.
        let session = GameSession.fresh(try afterF3E5(refusing: ["Qh4", "Nc6"]))
        defer { session.suspend() }
        session.jumpToLatest()
        session.readReply(at: 0)
        let reading = try #require(session.replyReading)
        #expect(reading.line == ["g4", "Qh4", "Nc6"])
        #expect(reading.steps.map(\.san) == ["g4", "Qh4"], "chips are read off the arrows")
    }

    @Test func readingTheOpenMoveAgainPutsItAway() throws {
        let session = GameSession.fresh(try afterF3E5(refusing: ["Qh4"]))
        defer { session.suspend() }
        session.jumpToLatest()
        session.readReply(at: 0)
        #expect(session.replyReading != nil)
        session.readReply(at: 0)
        #expect(session.replyReading == nil)
        session.readReply(at: 3)
        #expect(session.replyReading == nil, "there is no fourth 试招 on the strip")
    }

    @Test func theBoardMovingOnClosesTheReading() throws {
        let session = GameSession.fresh(try afterF3E5(refusing: ["Qh4"]))
        defer { session.suspend() }
        session.jumpToLatest()
        session.readReply(at: 0)
        #expect(session.replyReading != nil)
        session.step(by: -1)
        #expect(session.replyReading == nil)
        session.jumpToLatest()
        #expect(session.replyReading == nil, "coming back does not reopen a question put away")
    }

    /// The 试招 kept by a move that stands are read from the position it was played in, which
    /// is one behind the board.
    @Test func anAbsorbedTriedMoveIsWalkedFromWhereItWasRefused() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3", "e7e5"]))
        game.recordTried(.init(san: "g4", drop: 40, line: ["Qh4"]), atPly: 2)
        let stood = game.apply(uci: "d2d4")
        try #require(stood)
        game.absorbPendingTried(atPly: 2)
        let session = GameSession.fresh(game)
        defer { session.suspend() }
        session.jumpToLatest()
        #expect(session.visibleAttempts.map(\.san) == ["g4"])
        session.readReply(at: 0)
        let reading = try #require(session.replyReading)
        #expect(reading.position.uciMoves == ["f2f3", "e7e5"])
        #expect(reading.arrows.map { "\($0.move.from)\($0.move.to)" } == ["g2g4", "d8h4"])
    }
}
