import Foundation

/// Who moves for one colour — the player by hand, or the engine.
///
/// Both colours have one, either can be changed at any point in a Game, and all four
/// combinations mean something: play a side, hand-move both to replay a book game, swap
/// sides mid-game, or sit back and let the engine play itself.
public enum Controller: String, Hashable, Sendable, CaseIterable, Codable {
    case hand
    case engine

    /// What to write in PGN's White or Black tag for a side played this way.
    ///
    /// Not localized, and it must not be: this is written into the file and read back out of it
    /// — `PGN.handMoved` decides whose moves a Habit is counted over by comparing against it —
    /// so a game saved in one language has to still be readable in another.
    public var playerName: String {
        switch self {
        case .hand: "手动"
        case .engine: "Stockfish 18"
        }
    }
}

/// What a Review has to say about one move, by how much worse the position got.
///
/// Named from the mover's point of view: a Score is White-relative, so Black losing 200
/// centipawns means its win chance went *up*. Deliberately coarse, because a Review's job is
/// to point at the moves worth a second look, not to grade a performance.
///
/// Measured in **win probability, not centipawns** (docs/adr/0027). The old bands — 300 a
/// blunder, 150 a mistake, 50 an inaccuracy — called throwing three pawns away from a won game
/// a blunder and shrugged at a pawn thrown away from a level one, which is backwards. On this
/// scale the same three names land where they were always meant to: near equality 10% is about
/// 109 centipawns, so an ordinary inaccuracy is still an inaccuracy, and 300 centipawns given
/// up while eight pawns ahead is 9 points and nothing at all.
public enum MoveQuality: String, Hashable, Sendable, CaseIterable {
    case blunder
    case mistake
    case inaccuracy
    case fine

    public var label: String {
        switch self {
        case .blunder: localized("quality.blunder")
        case .mistake: localized("quality.mistake")
        case .inaccuracy: localized("quality.inaccuracy")
        case .fine: localized("quality.fine")
        }
    }

    /// The marks these get in annotated chess, which is what a move list shows.
    public var mark: String {
        switch self {
        case .blunder: "??"
        case .mistake: "?"
        case .inaccuracy: "?!"
        case .fine: ""
        }
    }

    /// Where the three names begin, in percentage points of win probability given away.
    ///
    /// The lowest of them is also the default 记录线 and 拦截线, which is not a coincidence: a
    /// move worth a name is a move worth writing down (docs/adr/0027). They are constants
    /// because they name a move, and the three *lines* — what to stop for, what to write down,
    /// what to drill — are a `JudgementLines`, which the player sets.
    public static let inaccuracyFrom = 10.0
    public static let mistakeFrom = 20.0
    public static let blunderFrom = 30.0

    /// How much win probability a move gave away, in percentage points, from the mover's own
    /// point of view. Negative for a move that improved on what the engine had — which happens,
    /// and reads as a gain rather than being clamped to nothing.
    ///
    /// Nil rather than zero when either end is missing. The two are not the same thing: one is
    /// "this move cost nothing" and the other is "nobody has looked", and a caller that cannot
    /// tell them apart will file an unreviewed game as a game with no mistakes in it.
    public static func drop(
        move mover: PieceColour, before: Score?, after: Score?
    ) -> Double? {
        guard let before, let after else { return nil }
        let mine = mover == .white
            ? (before.winPercent, after.winPercent)
            : (100 - before.winPercent, 100 - after.winPercent)
        return mine.0 - mine.1
    }

    /// Compares the Score before a move with the Score after it, on the win-probability scale.
    public static func of(
        move mover: PieceColour, before: Score?, after: Score?
    ) -> MoveQuality? {
        guard let lost = drop(move: mover, before: before, after: after) else { return nil }
        return switch lost {
        case blunderFrom...: .blunder
        case mistakeFrom..<blunderFrom: .mistake
        case inaccuracyFrom..<mistakeFrom: .inaccuracy
        default: .fine
        }
    }
}
