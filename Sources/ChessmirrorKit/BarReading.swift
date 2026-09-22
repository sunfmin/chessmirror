import Foundation

/// 优势条读数 — the one number the advantage bar shows, and where it came from
/// (docs/adr/0026).
///
/// "Which number is on the bar right now" used to be answered by four members with three
/// hand-written priority chains (`noSlipsScore`, `feedbackScore`, `historyScore`, and the
/// bar half of `strip`), and the rule "while a move is being weighed, show the position it
/// was played from" was written out twice. A bug in the priority was a bug in whichever
/// chain the reader happened to use — `theBarHoldsItsNumberWhileAMoveIsWeighed` and
/// `moveChangeUsesTheSameTwoScoresAsTheBar` exist only because the chains disagreed.
///
/// Three doors a number can reach the bar by, and no more: the move just landed, a live
/// search of a position, or what the record says. There is no fourth for "the engine's
/// opinion" — the intercept table 把关 and the badge read, and the standing Analysis a card
/// keeps, are the same bounded search in two homes (GameSession+Clock: "a card that took
/// the search over owes the board nothing"). Splitting them here would be two faces of one
/// fact, which is the thing this reading exists to stop.
public struct BarReading: Hashable, Sendable {
    /// Where the number came from.
    public enum Source: Hashable, Sendable {
        /// The move just played, and what it did to the game (`MoveChange`).
        case landed(MoveChange)
        /// The live bounded search of a position (docs/adr/0040: a number, never a voice).
        case searching(Score)
        /// What the record says: a judgement written on a move, a badge, or a Review.
        case record(Score)
    }

    public let source: Source?

    public init(_ source: Source?) {
        self.source = source
    }

    /// The number for the bar. Nil is a bar with no number, which draws a level game.
    public var score: Score? {
        switch source {
        case nil: nil
        case .landed(let change): change.after
        case .searching(let score), .record(let score): score
        }
    }

    /// The badge under the board, when the number is the move just played. Navigating the
    /// record is not a new move, and a new move is not this one — so a reading taken at an
    /// older position has no badge, even though the badge itself is still there.
    public var change: MoveChange? {
        if case .landed(let change) = source { change } else { nil }
    }
}

/// The moves and position a stored fact belongs to.
///
/// A badge and an unjudged landing both need to know whether the game has moved on since
/// they were written, and that check used to be written out by hand wherever it was needed
/// — a compared tuple in three places, with a field each would forget to add.
struct OfGame: Hashable, Sendable {
    let moves: [String]
    let fen: String

    init(_ game: Game) {
        moves = game.uciMoves
        fen = game.state.fen
    }

    /// Whether this is still the game the fact was written about.
    func matches(_ game: Game) -> Bool {
        moves == game.uciMoves && fen == game.state.fen
    }
}

/// The badge for the move just played: what it did to the game, and which game it is of.
///
/// One value rather than a compared tuple, so the identity rule cannot drift between the
/// badge, the curve and the measurement that writes it (`measureLatestMoveChange`).
struct LandedBadge: Hashable, Sendable {
    let of: OfGame
    let change: MoveChange

    init(_ game: Game, change: MoveChange) {
        of = OfGame(game)
        self.change = change
    }

    /// Whether this badge describes the game as it now stands.
    func describes(_ game: Game) -> Bool {
        of.matches(game)
    }
}
