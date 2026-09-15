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
    /// Where the game came from, so 耕棋 and a rated game can be told apart in the history
    /// without being used to split the item.
    public let origin: GameOrigin

    public var id: String { "\(game.lastPathComponent)#\(ply)" }

    public init(
        game: URL, ply: Int, when: Date, played: String, wanted: String?, cost: Double,
        origin: GameOrigin
    ) {
        self.game = game
        self.ply = ply
        self.when = when
        self.played = played
        self.wanted = wanted
        self.cost = cost
        self.origin = origin
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
    /// Only the sides the player actually moved: a game where the engine had Black is a game
    /// where Black's mistakes belong to Stockfish. Only a reviewed game, because a drop needs two
    /// Scores from one depth and an unreviewed game has neither (docs/adr/0016) — an unreviewed
    /// game is not a game with nothing wrong in it, it is a game nobody has looked at.
    public static func encounters(
        in entry: GameLibrary.Entry, lines: JudgementLines = .standard
    ) -> [(PositionKey, Encounter)] {
        guard let pgn = entry.pgn else { return [] }
        let game = pgn.game
        guard game.isReviewed else { return [] }
        let mine = pgn.handColours
        guard !mine.isEmpty else { return [] }

        var found: [(PositionKey, Encounter)] = []
        // Walked forward once rather than rewound per ply: `rewound(to:)` replays from the start
        // every time it is called, which over a whole game is a quadratic number of rules probes
        // (docs/adr/0003) — the cost this whole derivation is trying not to pay on every screen.
        guard var walked = game.rewound(to: 0) else { return [] }
        for ply in 1...max(1, game.plies.count) where game.plies.indices.contains(ply - 1) {
            let fen = walked.state.fen
            guard walked.apply(uci: game.plies[ply - 1].uci) else { break }
            let mover = game.mover(ofPly: ply)
            guard mine.contains(mover), let cost = game.drop(atPly: ply), lines.records(cost),
                let key = PositionKey(fen: fen)
            else { continue }
            found.append(
                (
                    key,
                    Encounter(
                        game: entry.url,
                        ply: ply,
                        when: entry.modified,
                        played: game.plies[ply - 1].san,
                        wanted: game.reviewLine(atPly: ply - 1).first,
                        cost: cost,
                        origin: entry.origin
                    )
                )
            )
        }
        return found
    }

    /// The whole book, from a set of games and the positions the player has struck off.
    public static func derive(
        from entries: [GameLibrary.Entry],
        dismissed: Set<PositionKey> = [],
        lines: JudgementLines = .standard
    ) -> MistakeBook {
        var byPosition: [PositionKey: [Encounter]] = [:]
        for entry in entries {
            for (key, encounter) in encounters(in: entry, lines: lines) where !dismissed.contains(key) {
                byPosition[key, default: []].append(encounter)
            }
        }
        return MistakeBook(
            mistakes: byPosition.map { Mistake(position: $0.key, encounters: $0.value) }
        )
    }
}
