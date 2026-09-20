import Foundation

/// A position, as the thing a 错题 is (docs/adr/0028).
///
/// The placement, whose move it is, the castling rights and the en-passant square — the first
/// four fields of a FEN, and nothing after them. The half-move clock and the move number are not
/// part of what a position *is*, and keeping them would make the same position reached by two
/// move orders into two strangers, which is exactly the merge this whole book is built on.
public struct PositionKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let text: String

    /// Nil for anything that is not a FEN with those four fields in it.
    public init?(fen: String) {
        let fields = fen.split(separator: " ")
        guard fields.count >= 4 else { return nil }
        text = fields.prefix(4).joined(separator: " ")
    }

    public init(_ text: String) { self.text = text }

    public var description: String { text }

    /// Whose move it is here, which is the side that got it wrong.
    public var sideToMove: PieceColour {
        text.split(separator: " ").dropFirst().first == "b" ? .black : .white
    }
}

/// One time the player stood in a position and got it wrong (docs/adr/0028).
///
/// The 错题 is the position; this is an occasion. Everything that varies between occasions lives
/// here — when, which game, what was played, what it cost — so that four of these hanging off one
/// position can be read as a history rather than as four unrelated findings.
public struct Encounter: Hashable, Sendable, Identifiable {
    /// The game this happened in, and where in it.
    public let game: URL
    public let ply: Int
    /// When the game was played, as the file says.
    public let when: Date
    /// What was actually played, in SAN.
    public let played: String
    /// What the engine wanted instead, when the Review kept a line. Nil rather than guessed.
    public let wanted: String?
    /// What it cost, in percentage points of win probability (docs/adr/0027).
    public let cost: Double
    /// Where the game came from, so 把关 and a rated game can be told apart in the history
    /// without being used to split the item.
    public let origin: GameOrigin

    /// The ordinal distinguishes repeated attempts at the same move. Nil is the actual move.
    public let attempt: Int?
    public let notFound: Bool
    public var id: String { "\(game.absoluteString)#\(ply)-\(attempt.map(String.init) ?? "played")" }

    public init(
        game: URL, ply: Int, when: Date, played: String, wanted: String?, cost: Double,
        origin: GameOrigin, attempt: Int? = nil, notFound: Bool = false
    ) {
        self.game = game
        self.ply = ply
        self.when = when
        self.played = played
        self.wanted = wanted
        self.cost = cost
        self.origin = origin
        self.attempt = attempt
        self.notFound = notFound
    }
}

/// One position the player keeps getting wrong, and every time they have (docs/adr/0028).
public struct Mistake: Identifiable, Hashable, Sendable {
    public let position: PositionKey
    /// Every occasion, newest first.
    public let encounters: [Encounter]

    public var id: String { position.text }

    public init(position: PositionKey, encounters: [Encounter]) {
        self.position = position
        self.encounters = encounters.sorted { $0.when > $1.when }
    }

    /// How many times this has happened. The most useful number the app knows about a player,
    /// and it exists only because the four times are one thing.
    public var recurrence: Int { encounters.count }

    /// The worst it has ever cost.
    public var worstCost: Double { encounters.map(\.cost).max() ?? 0 }

    public var lastSeen: Date? { encounters.first?.when }
    public var firstSeen: Date? { encounters.last?.when }

    /// What was played here, most-played first, with how many times each.
    ///
    /// Two different bad moves in one position is one hole in the player's understanding, not
    /// two — so this is read, never used to divide the item (docs/adr/0028).
    public var attempts: [(move: String, times: Int)] {
        var counts: [String: Int] = [:]
        for encounter in encounters { counts[encounter.played, default: 0] += 1 }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (move: $0.key, times: $0.value) }
    }

    /// 复发 is the only thing allowed to jump the queue, whatever any one occasion cost: twelve
    /// percent three times says the player has no concept here, and forty percent once may only
    /// say they were tired (docs/adr/0028).
    ///
    /// Recurrence first, then the worst it ever cost, then the most recent — so a list sorted by
    /// this reads as "what you keep doing" rather than "your worst moment".
    public func isMorePressing(than other: Mistake) -> Bool {
        if recurrence != other.recurrence { return recurrence > other.recurrence }
        if worstCost != other.worstCost { return worstCost > other.worstCost }
        return (lastSeen ?? .distantPast) > (other.lastSeen ?? .distantPast)
    }

    /// 「这个局面你栽过 4 次，三次走 Nf3，一次走 Bd3，最近一次是 3 天前」 — the sentence no other
    /// identity can produce (docs/adr/0028).
    public func sentence(now: Date = Date()) -> String {
        var parts = [localized("book.fell", plural: recurrence)]
        for attempt in attempts.prefix(3) {
            parts.append(localized("book.played", attempt.times, attempt.move))
        }
        if let last = lastSeen {
            parts.append(localized("book.lastTime", Mistake.ago(from: last, to: now)))
        }
        return parts.joined(separator: localized("clause.separator")) + localized("sentence.end")
    }

    /// How long ago, in the coarsest unit that still says something.
    public static func ago(from: Date, to: Date) -> String {
        let seconds = max(0, to.timeIntervalSince(from))
        let days = Int(seconds / 86_400)
        if days >= 1 { return localized("ago.days", plural: days) }
        let hours = Int(seconds / 3_600)
        if hours >= 1 { return localized("ago.hours", plural: hours) }
        return localized("ago.justNow")
    }
}

/// The book: every position the player has got wrong, derived from the games (docs/adr/0028).
///
/// Derived, and that is the rule — there is no second store of mistakes, because a mistake is a
/// fact about a game and games live in PGN (docs/adr/0010, docs/adr/0029). What is *not* derived
/// is the player saying "not this one", which is behaviour rather than a fact about any game, and
/// lives in the practice log.
public struct MistakeBook: Sendable {
    /// Every 错题, most pressing first.
    public let mistakes: [Mistake]

    public init(mistakes: [Mistake]) {
        self.mistakes = mistakes.sorted { $0.isMorePressing(than: $1) }
    }

    public subscript(position: PositionKey) -> Mistake? {
        mistakes.first { $0.position == position }
    }

    public var isEmpty: Bool { mistakes.isEmpty }

    // ------------------------------------------------------------------ deriving

    /// Every move in one game that cost more than the 记录线, as Encounters.
    ///
    /// Two kinds of move end up here and they are the same kind of fact:
    ///
    /// - **A move that was played**, whose cost a Review measured. A game with no Review
    ///   contributes none of these — a drop needs two Scores from one depth and an unreviewed
    ///   game has neither (docs/adr/0016). An unreviewed game is not a game with nothing wrong in
    ///   it, it is a game nobody has looked at.
    /// - **A move 把关 took back**, whose cost was measured when it was refused and written into
    ///   the file with it (docs/adr/0027). These need no Review, because the measurement already
    ///   happened; a 把关 game therefore fills the book while it is being played. Whether the
    ///   refusal rode onto the move that finally stood or is still waiting at the position it
    ///   happened at (docs/adr/0037) makes no difference to the book: both are one occasion of
    ///   getting one position wrong.
    ///
    /// Only the sides the player actually moved, either way: a game where the engine had Black is
    /// a game where Black's mistakes belong to Stockfish.
    public static func encounters(
        in entry: GameLibrary.Entry, lines: JudgementLines = .standard
    ) -> [(PositionKey, Encounter)] {
        guard let pgn = entry.pgn else { return [] }
        let game = pgn.game
        var found: [(PositionKey, Encounter)] = []
        for stop in game.stops(by: pgn.handColours) {
            // The move that stood, by the book's own gate: a Review's number and nothing else,
            // because the book compares across games (docs/adr/0016) — and not a second time when
            // a 惩罚 exercise already wrote it down as the move the player did not find. The
            // 试招 come first, because they happened first: they are what the player reached
            // for before the move that stands.
            var stood: Double?
            if let move = stop.move, game.isReviewed,
                !stop.tried.contains(where: { $0.notFound && $0.san == move.san }) {
                stood = game.drop(atPly: stop.ply)
            }
            for wrong in stop.wrong(recordedBy: lines, stood: stood) {
                found.append(
                    (
                        stop.position,
                        Encounter(
                            game: entry.url, ply: stop.ply, when: entry.when, played: wrong.san,
                            wanted: stop.wanted, cost: wrong.drop, origin: entry.origin,
                            attempt: wrong.attempt, notFound: wrong.notFound
                        )
                    )
                )
            }
        }
        return found
    }

    /// The book from 遭遇 already walked: one 错题 per position, the struck-off left out.
    ///
    /// **The one place a book is made.** The walk is the expensive half and has two callers with
    /// different needs — a whole library at once here, one file at a time in `MistakeIndex`,
    /// which keeps what it walked — but what a book *is* cannot differ between them. It did: the
    /// app assembled its book in the index and this function was left running for the tests
    /// alone, so a change to how 遭遇 become 错题 had to be made twice and only one of the two
    /// was covered.
    public static func book(
        of found: [(PositionKey, Encounter)], dismissed: Set<PositionKey> = []
    ) -> MistakeBook {
        var byPosition: [PositionKey: [Encounter]] = [:]
        for (key, encounter) in found where !dismissed.contains(key) {
            byPosition[key, default: []].append(encounter)
        }
        return MistakeBook(
            mistakes: byPosition.map { Mistake(position: $0.key, encounters: $0.value) }
        )
    }

    /// The whole book, from a set of games and the positions the player has struck off: the walk
    /// and the assembly in one call, for a caller with no cache to keep.
    public static func derive(
        from entries: [GameLibrary.Entry],
        dismissed: Set<PositionKey> = [],
        lines: JudgementLines = .standard
    ) -> MistakeBook {
        book(
            of: entries.flatMap { encounters(in: $0, lines: lines) },
            dismissed: dismissed
        )
    }
}
