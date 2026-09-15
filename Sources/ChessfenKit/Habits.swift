import Foundation

/// 老毛病 — one thing the player keeps doing, and every time they did it.
///
/// Two modes, and the list is closed on purpose. A mode earns its place by being a **board
/// fact** — something a player can be shown rather than told — so there is no "positional
/// understanding" mode and no "opening knowledge" mode, because neither could be pointed at on a
/// board. The three that were made of what the player *said* went with the declaration itself
/// (docs/adr/0031).
public struct Habit: Identifiable, Hashable, Sendable {
    public enum Mode: String, Hashable, Sendable, CaseIterable {
        /// You left one of your own pieces unguarded, and got away with it.
        case giveaway
        /// You left one unguarded and the opponent's very next move took it.
        case missedReply

        public var label: String {
            switch self {
            case .giveaway: localized("habit.giveaway")
            case .missedReply: localized("habit.missedReply")
            }
        }

        /// What the mode is, in the terms the board shows it in — never a score and never a
        /// grade. One sentence a player can go and check.
        public var explanation: String {
            switch self {
            case .giveaway: localized("habit.giveaway.explained")
            case .missedReply: localized("habit.missedReply.explained")
            }
        }

        /// The order two modes with the same count are listed in — the sharper diagnosis first,
        /// so a tie never reads as arbitrary.
        var rank: Int {
            switch self {
            case .missedReply: 0
            case .giveaway: 1
            }
        }
    }

    /// One time it happened, and the way back to it.
    public struct Occurrence: Identifiable, Hashable, Sendable {
        /// The file it happened in — which is the game (docs/adr/0010), so this is both the
        /// identity and the way to open it.
        public let game: URL
        public let title: String
        /// Counting from one, the way `Game` counts plies.
        public let ply: Int
        public let moveNumber: Int
        public let mover: PieceColour
        public let san: String
        /// What the board said, in the same terms the mode is named in. Nil when there was
        /// nothing to add beyond the mode itself.
        public let note: String?

        public var id: String { "\(game.path)#\(ply)" }

        public init(
            game: URL, title: String, ply: Int, moveNumber: Int, mover: PieceColour,
            san: String, note: String?
        ) {
            self.game = game
            self.title = title
            self.ply = ply
            self.moveNumber = moveNumber
            self.mover = mover
            self.san = san
            self.note = note
        }
    }

    public let mode: Mode
    /// Every time it happened, most recent game first.
    public let occurrences: [Occurrence]

    public var count: Int { occurrences.count }
    public var id: String { mode.rawValue }
}

/// What the saved games say the player keeps doing — counted on demand and stored nowhere.
///
/// Not a rating and not an accuracy percentage. A rating here would be a fake number: there are
/// no opponents and no pool behind it, and it would compete with the real one the player already
/// has elsewhere. This is the coach's sentence instead (docs/adr/0018).
///
/// Recomputing means a game corrected or deleted in the Files app changes the answer the next
/// time it is asked, with nothing to reconcile. The cost is a pass over a few kilobytes per game
/// and a replay of the handful of plies that get looked at.
public struct Habits: Hashable, Sendable {
    /// Why a game was left out. Every one of these is said out loud rather than folded into the
    /// count: a game that could not be judged must not read as a clean one.
    public enum Exclusion: String, Hashable, Sendable, CaseIterable {
        /// No Review has been over it, so its moves cannot be ranked at all (docs/adr/0016).
        case unreviewed
        /// The file will not parse.
        case unreadable
        /// iCloud has told this device the game exists but not yet handed it over.
        case waiting

        public var label: String {
            switch self {
            case .unreviewed: localized("habit.excluded.unreviewed")
            case .unreadable: localized("habit.excluded.unreadable")
            case .waiting: localized("habit.excluded.waiting")
            }
        }
    }

    /// The modes that actually happened, most times first. A mode that did not happen is not in
    /// the list — a row of zeros is not a diagnosis.
    public let habits: [Habit]
    /// How many games the answer was computed from.
    public let gamesCounted: Int
    public let excluded: [Exclusion: Int]

    /// Nothing could be counted, which is a different statement from "nothing was found".
    public var hasNothingToCount: Bool { gamesCounted == 0 }
    /// Games were counted and no mode came out of them.
    public var isClean: Bool { gamesCounted > 0 && habits.isEmpty }

    public var excludedCount: Int { excluded.values.reduce(0, +) }

    /// Exclusions worth saying, in a stable order.
    public var exclusions: [(reason: Exclusion, count: Int)] {
        Exclusion.allCases.compactMap { reason in
            guard let count = excluded[reason], count > 0 else { return nil }
            return (reason, count)
        }
    }

    public func habit(_ mode: Habit.Mode) -> Habit? {
        habits.first { $0.mode == mode }
    }

    /// How many of a game's ranked-worst moves get looked at — the same three the Drill asks
    /// about, so what a player is told about is what they were asked about.
    public static let ranked = 3

    // ------------------------------------------------------------------ counting

    /// Reads the library and says what the player keeps doing.
    ///
    /// Pure, and deliberately: it takes the entries rather than the `GameLibrary`, so it can be
    /// run off the main thread and tested against a library that is a handful of values.
    public static func over(_ entries: [GameLibrary.Entry]) -> Habits {
        var found: [Habit.Mode: [Habit.Occurrence]] = [:]
        var counted = 0
        var excluded: [Exclusion: Int] = [:]

        for entry in entries {
            if entry.isDownloading {
                excluded[.waiting, default: 0] += 1
                continue
            }
            guard let pgn = entry.pgn else {
                excluded[.unreadable, default: 0] += 1
                continue
            }
            // Ranking Scores of unrecorded Depth is a list of invented mistakes, so an
            // unreviewed game is left out of the whole tally and said to be left out. Counting
            // its declared reasons while its moves went unjudged would make two of the five
            // modes answer a smaller question than the others, which is the way a tally starts
            // lying about which mode is worst.
            guard pgn.game.isReviewed else {
                excluded[.unreviewed, default: 0] += 1
                continue
            }
            counted += 1
            for (mode, occurrence) in occurrences(in: pgn, at: entry.url, titled: entry.title) {
                found[mode, default: []].append(occurrence)
            }
        }

        let habits = found
            .map { Habit(mode: $0.key, occurrences: $0.value) }
            .sorted { ($0.count, -$0.mode.rank) > ($1.count, -$1.mode.rank) }
        return Habits(habits: habits, gamesCounted: counted, excluded: excluded)
    }

    /// Everything one game has to say. The two halves ask different questions of it, and each
    /// asks about the plies it has any business asking about.
    static func occurrences(
        in pgn: PGN, at url: URL, titled title: String
    ) -> [(Habit.Mode, Habit.Occurrence)] {
        board(in: pgn, at: url, titled: title)
    }

    /// The modes the board can prove, over the game's ranked-worst moves.
    ///
    /// The rank is what chooses which moves get looked at — never a centipawn threshold
    /// (docs/adr/0017) — and the board is what says which kind of error each one was. A ranked
    /// move that hung nothing gets no mode at all: this tally has no name for a positional
    /// error, and inventing one would be the fake number it exists to avoid.
    private static func board(
        in pgn: PGN, at url: URL, titled title: String
    ) -> [(Habit.Mode, Habit.Occurrence)] {
        let game = pgn.game
        // Only the side a person is recorded as having moved. When the file does not say — a
        // photographed game, an import — both sides are the player's to answer for, because
        // somebody studying such a file is studying all of it.
        let hands = pgn.handPlayed
        let colour: PieceColour? = hands.count == 1 ? hands.first : nil
        guard let worst = game.worstMoves(ranked, by: colour) else { return [] }

        var out: [(Habit.Mode, Habit.Occurrence)] = []
        for played in worst {
            guard let before = game.rewound(to: played.ply - 1),
                let after = game.rewound(to: played.ply),
                let looseBefore = before.loosePieces(of: played.mover),
                let looseAfter = after.loosePieces(of: played.mover)
            else { continue }
            // What this move left hanging, as against what was already hanging before it: the
            // statement has to be about the move, or it is about the position the opponent made.
            let exposed = looseAfter.subtracting(looseBefore)
            guard !exposed.isEmpty else { continue }
            let where_ = exposed.sorted { $0.index < $1.index }.listed

            // Did they take it? The very next ply, because that is what "算对手那一步" means.
            let taken = game.plies.indices.contains(played.ply)
                ? MoveSquares(uci: game.plies[played.ply].uci).map { exposed.contains($0.to) }
                    ?? false
                : false
            out.append(
                (
                    taken ? .missedReply : .giveaway,
                    Habit.Occurrence(
                        game: url,
                        title: title,
                        ply: played.ply,
                        moveNumber: game.moveNumber(ofPly: played.ply),
                        mover: played.mover,
                        san: played.san,
                        note: localized(
                            taken ? "habit.note.taken" : "habit.note.exposed", where_
                        )
                    )
                )
            )
        }
        return out
    }

}

extension PGN {
    /// The colours a person is recorded as having moved by hand.
    ///
    /// Read off the White and Black tags, which is where this app writes who was moving each
    /// side (`Controller.playerName`). Empty for a game whose tags name two people, or nobody:
    /// such a file does not say which side was the player's, and guessing would put somebody
    /// else's mistakes on their list.
    public var handPlayed: Set<PieceColour> {
        var out: Set<PieceColour> = []
        if tag("White") == Controller.hand.playerName { out.insert(.white) }
        if tag("Black") == Controller.hand.playerName { out.insert(.black) }
        return out
    }
}
