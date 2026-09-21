import Foundation

/// One noise the app can make.
///
/// The list lives here rather than beside the synthesiser because it is what a *Game* has to say
/// about itself — a move landed, a move was refused — and the thing that turns that into a sound
/// is a detail of one platform.
public enum FeedbackSound: Hashable, Sendable, CaseIterable {
    /// A piece landing on wood.
    case move
    /// A piece taking another: the same landing with a crack in front of it.
    case capture
    /// A check — a rising two-tone, because it is a warning rather than an event.
    case check
    case gameOver
    /// A tap that could not be played.
    case refused
}

/// What a move sounds and feels like.
///
/// A seam rather than a singleton reached for directly, for the reason every seam here exists:
/// there are two adapters. The app's makes noise through AVFoundation and buzzes the Taptic
/// engine; a test's records what it was asked to play, which is the only way an assertion about
/// *what a game sounded like* can be written at all.
///
/// Whether it makes a noise at all is the player's setting (`PlayerSettings.isSoundOn`), which the
/// app's adapter reads; the seam is only what to play.
@MainActor public protocol Feedback: AnyObject {
    func play(_ sound: FeedbackSound)
}

extension Feedback {
    /// The sound a move makes, from what the move did. Checkmate is the end of the game rather
    /// than a check, so it says so.
    ///
    /// Derived here rather than in each adapter, so a move played by hand, asked for, or made by
    /// a Controller sounds the same — that mapping is a fact about chess, not about a speaker.
    public func play(_ move: Move, outcome: Outcome) {
        play(move.isCapture ? .capture : .move)
        if outcome.isOver {
            play(.gameOver)
        } else if move.givesCheck {
            play(.check)
        }
    }
}

extension Feedback {
    /// What a session's event sounds like.
    ///
    /// Beside the sounds rather than in the session, which says what happened and nothing about
    /// a speaker (`GameSession.Event`). A fork gets the rising two-tone a check gets: a line
    /// leaving the one it was played over is worth a noise of its own, and that is the noise that
    /// means "look".
    public func hear(_ event: GameSession.Event) {
        switch event {
        case .landed(let move, let outcome): play(move, outcome: outcome)
        case .refused: play(.refused)
        case .forked: play(.check)
        case .stepped: play(.move)
        }
    }
}

/// An adapter that makes no noise. The default, and what a machine with no audio gets.
@MainActor public final class SilentFeedback: Feedback {
    public init() {}
    public func play(_ sound: FeedbackSound) {}
}

/// The Feedback everything plays through.
///
/// Global because a sound is not something a screen should have to be handed in order to make —
/// threading a speaker through every construction site would grow exactly the ritual that
/// `GameSession.open` exists to remove. Settable because that is the seam: the app installs its
/// own on the way up, and a test installs a recording one.
///
/// **The kit's own code does not reach for it.** A session says what happened
/// (`GameSession.Event`) and the screen it is on turns that into a noise; this is what that
/// screen plays through.
@MainActor public enum Sounds {
    public static var current: any Feedback = SilentFeedback()
}
