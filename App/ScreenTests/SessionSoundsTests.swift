import ChessmirrorKit
import Foundation
import Testing

@testable import Chessmirror

/// What the app plays for each thing a session says happened. The session no longer makes a
/// noise itself (`GameSession.Event`), so this is where "a refusal sounds like a refusal" is
/// kept true — against the sounds the session used to play from its own lines.
@MainActor
struct SessionSounds {
    final class Recording: Feedback {
        var isSoundOn = true
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

    /// The screen's wiring, end to end: a session on a screen is heard through whatever
    /// Feedback is installed when the event arrives.
    @Test func aSessionIsHeardThroughTheInstalledFeedback() throws {
        let speaker = Recording()
        let previous = Sounds.current
        Sounds.current = speaker
        defer { Sounds.current = previous }
        let (e4, game) = try move("e2e4")
        let session = GameSession.fresh(game)
        session.onEvent = { Sounds.current.hear($0) }

        session.play(e4)
        session.step(by: -1)

        #expect(speaker.played == [.move, .move])
    }
}
