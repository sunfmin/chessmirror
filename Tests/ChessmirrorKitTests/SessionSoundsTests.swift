import ChessmirrorKit
import Foundation
import Testing

/// Contract: what the app plays for each thing a session says happened. The session makes no
/// noise itself (`GameSession.Event`), so this is where "a refusal sounds like a refusal" is kept
/// true — against the sounds the session used to play from its own lines.
@MainActor
@Suite struct SessionSoundsTests {
    final class Recording: Feedback {
        var played: [FeedbackSound] = []
        func play(_ sound: FeedbackSound) { played.append(sound) }
    }

    private func move(_ uci: String, in moves: [String] = []) throws -> (Move, Game) {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: moves))
        return (try #require(game.state.move(matching: uci)), game)
    }

    @Test func aQuietMoveIsAPieceLanding() throws {
        let speaker = Recording()
        speaker.hear(.landed(try move("e2e4").0, outcome: .ongoing))
        #expect(speaker.played == [.move])
    }

    @Test func aCaptureCracksAndACheckWarns() throws {
        let speaker = Recording()
        let (capture, _) = try move("e4d5", in: ["e2e4", "d7d5"])
        speaker.hear(.landed(capture, outcome: .ongoing))
        #expect(speaker.played == [.capture])

        speaker.played = []
        let (check, _) = try move("d1h5", in: ["e2e4", "f7f6"])
        speaker.hear(.landed(check, outcome: .ongoing))
        #expect(speaker.played == [.move, .check])
    }

    @Test func checkmateIsTheEndOfTheGameRatherThanACheck() throws {
        let speaker = Recording()
        let (mate, _) = try move("d8h4", in: ["f2f3", "e7e5", "g2g4"])
        speaker.hear(.landed(mate, outcome: .checkmate))
        #expect(speaker.played == [.move, .gameOver])
    }

    @Test func aRefusalAForkAndAStepEachHaveTheirNoise() {
        let speaker = Recording()
        speaker.hear(.refused)
        speaker.hear(.forked)
        speaker.hear(.stepped)
        #expect(speaker.played == [.refused, .check, .move])
    }

    /// A session is heard through whatever Feedback its listener plays to, event by event.
    @Test func aSessionIsHeardEventByEvent() throws {
        let speaker = Recording()
        let (e4, game) = try move("e2e4")
        let session = GameSession.fresh(game)
        session.hear { speaker.hear($0) }

        session.play(e4)
        session.step(by: -1)

        #expect(speaker.played == [.move, .move])
    }
}
