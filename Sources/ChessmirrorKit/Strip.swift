import Foundation

/// How a game ended, as far as a bar is concerned.
///
/// A finished game has no Score: there is nothing left to search, so the engine says nothing and
/// a bar left to draw a missing number would sit exactly half and half — the picture of a level
/// game, and the opposite of the truth when somebody has just been mated.
public enum Finish: Hashable, Sendable {
    case won(PieceColour)
    case drawn

    /// How much of the bar is White's at the end: all of it, none of it, or a bar that is neither.
    public var whiteShare: Double {
        switch self {
        case .won(let colour): colour == .white ? 1 : 0
        case .drawn: 0.5
        }
    }
}

extension Game {
    /// How this game ended, or nil while it is being played.
    public var finish: Finish? {
        switch state.outcome {
        case .ongoing: nil
        case .checkmate: .won(state.sideToMove.opposite)
        default: .drawn
        }
    }
}

/// The strip under the board, as one value (docs/adr/0020).
///
/// Four things that are one thought — what the strip is saying and in which voice, how far the
/// game has gone without a slip, how deep the search of the position has got, and who is ahead
/// as a length — and the screen used to work each of them out for itself from five or six of the
/// session's facts, in view code only a simulator could test. Now the session says all four at
/// once, from the facts it already holds, and the screen draws what it is handed: a voice, a
/// tally if there is one to show, a depth if there is a search to account for, a bar if there is
/// anything to draw one of.
public struct Strip: Hashable, Sendable {
    /// What the strip says, by one priority (`Standing`).
    public let voice: Standing
    /// 连正, for as long as 把关 is on or has left something standing; nil otherwise.
    public let tally: Game.NoSlips?
    /// How deep the search of the position has got. Zero is a search in flight that has said
    /// nothing yet, which a screen says in words — 「正在计算」 — and never as a depth of nought.
    /// Nil when there is nothing to account for: a game that is over, an exercise on the board,
    /// or a position nothing is searching and nothing has searched.
    public let depth: Int?
    /// Who is ahead, or how it ended. Nil when there is nothing to draw: the badge is off and the
    /// game is still being played.
    public let bar: Bar?

    /// The bar reads the badge's number — where the move just played landed, else the position on
    /// screen, else whatever Analysis a card has asked for (docs/adr/0040). Once the game has ended
    /// it reads the result instead.
    public struct Bar: Hashable, Sendable {
        public let score: Score?
        public let finish: Finish?

        public init(score: Score?, finish: Finish?) {
            self.score = score
            self.finish = finish
        }
    }

    public init(voice: Standing, tally: Game.NoSlips?, depth: Int?, bar: Bar?) {
        self.voice = voice
        self.tally = tally
        self.depth = depth
        self.bar = bar
    }
}
