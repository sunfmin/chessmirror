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

/// How long the engine thinks before moving a colour it controls: about as long as the
/// player took over their own last move.
///
/// The engine is never handicapped — no skill level, no Elo limit, no reduced depth. It
/// plays at full strength and the only thing that shapes how well it plays is how long it
/// is left alone, which is exactly the courtesy a human opponent extends (docs/adr/0009).
public enum MirroredTime {
    /// A floor, because a player who taps a move out in a tenth of a second has not
    /// offered a thinking time so much as a reflex, and an engine answering in 100 ms
    /// looks broken rather than fast.
    public static let shortest = Duration.milliseconds(400)
    /// A ceiling, because mirroring a player who put the phone down and went to lunch
    /// would be obedient and useless.
    public static let longest = Duration.seconds(30)
    /// What to spend when there is nothing to mirror yet — the engine's first move.
    public static let opening = Duration.seconds(1)

    public static func budget(mirroring played: Duration?) -> SearchBudget {
        guard let played else { return .time(opening) }
        return .time(min(max(played, shortest), longest))
    }
}

/// How long the engine thinks over a move it plays for a colour it controls.
///
/// Time is the only dial in this app — the engine is never handicapped, so how long it is left
/// alone is the whole of how well it plays (docs/adr/0009) — and this is that dial. Two kinds of
/// answer, and which one is right depends on who is on the other side of the board.
///
/// It says nothing about the other two things the engine does. Advice is unbounded, because it is
/// deepening under a player who is thinking; an Asked Move takes as long as the button is held.
/// This is only for a move the engine plays because it is holding a Controller.
public enum ThinkingTime: Hashable, Sendable {
    /// About as long as the player took over their own last move: Mirrored Time, the courtesy a
    /// human opponent extends. It needs a human to extend it to.
    case mirrored
    /// The same number of seconds every move, whoever is on the other side.
    case fixed(seconds: Int)

    /// What the engine plays itself at when nobody has said otherwise.
    ///
    /// Both Controllers on the engine leaves no last human move to mirror, so a clock has to be
    /// named rather than derived. Three seconds, because a game the engine plays against itself is
    /// watched rather than played: a move every half second is a wall of notation nobody can
    /// follow, and a move a minute is not something anyone sits in front of either.
    public static let selfPlay = ThinkingTime.fixed(seconds: 3)

    /// What a saved record's engine opponent answers at: one second a move. The record is being
    /// played through rather than played against, and a brisk answer keeps the person in the game.
    public static let openedRecord = ThinkingTime.fixed(seconds: 1)

    /// The clocks offered on screen, in order. A short list of round numbers, because this is
    /// chosen with a thumb between moves rather than typed into a field.
    public static let offered: [ThinkingTime] = [
        .mirrored, .fixed(seconds: 1), .fixed(seconds: 3), .fixed(seconds: 10),
        .fixed(seconds: 30),
    ]

    /// What to give the engine, given how long the player took over their own last move.
    public func budget(mirroring played: Duration?) -> SearchBudget {
        switch self {
        case .mirrored: MirroredTime.budget(mirroring: played)
        case .fixed(let seconds): .time(.seconds(seconds))
        }
    }
}

/// What a Review has to say about one move, by how much worse the position got.
///
/// Named from the mover's point of view: a Score is White-relative, so Black losing 200
/// centipawns means the number went *up*. Thresholds are the familiar ones — the same
/// bands lichess uses — and they are deliberately coarse, because a Review's job is to
/// point at the moves worth a second look, not to grade a performance.
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

    /// Compares the Score before a move with the Score after it.
    ///
    /// A mate score is worth more than any number of pawns, so it is converted to a large
    /// one rather than compared as a special case: being mated in three is not "minus
    /// infinity" for these purposes, it is simply very bad, and the difference between
    /// very bad and slightly less bad should not read as a blunder.
    public static func of(
        move mover: PieceColour, before: Score?, after: Score?
    ) -> MoveQuality? {
        guard let before, let after else { return nil }
        let lost = (centipawns(before) - centipawns(after)) * (mover == .white ? 1 : -1)
        return switch lost {
        case 300...: .blunder
        case 150..<300: .mistake
        case 50..<150: .inaccuracy
        default: .fine
        }
    }

    /// Mate scores flattened onto the centipawn scale so differences stay finite.
    static func centipawns(_ score: Score) -> Int {
        switch score {
        case .centipawns(let value): max(-3000, min(3000, value))
        case .mate(let moves): moves > 0 ? 10000 - moves * 100 : -10000 - moves * 100
        }
    }
}
