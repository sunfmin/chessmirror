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
@MainActor public protocol Feedback: AnyObject {
    var isSoundOn: Bool { get set }
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

/// An adapter that makes no noise. The default, and what a machine with no audio gets.
@MainActor public final class SilentFeedback: Feedback {
    public var isSoundOn = false
    public init() {}
    public func play(_ sound: FeedbackSound) {}
}

/// The Feedback everything plays through.
///
/// Global because a sound is not something a Game should have to be handed in order to have —
/// threading a speaker through every construction site would grow exactly the ritual that
/// `GameSession.open` exists to remove. Settable because that is the seam: the app installs its
/// own on the way up, and a test installs a recording one.
@MainActor public enum Sounds {
    public static var current: any Feedback = SilentFeedback()
}
