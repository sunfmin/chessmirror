import Foundation

/// The lines drawn on the win-probability scale, and what each of them buys (docs/adr/0027, 0046).
///
/// Two numbers, and a switch that reads the first of them:
///
/// - **记录线** is what gets written into the game as a mistake worth remembering — and, while
///   把关 is on, what the player is stopped for and the board rolled back over. One number for
///   both, because they are one question: "what counts as a mistake". A 把关 that refused at five
///   while the book wrote down at ten turned back moves nobody would call a mistake, and left the
///   player two dials to reconcile (docs/adr/0046). It is still the only dial 把关 has on the
///   judgement of a move — the engine's 棋力 shapes the opponent it plays and never what a move
///   costs (docs/adr/0038, 0009).
/// - **入列线** is what earns a place in the player's future practice time. It never sits *below*
///   the 记录线 — practice time is spent on things that were written down — and a player who wants
///   a wide book and a narrow queue raises it, because a mistake can be worth remembering without
///   being worth drilling.
///
/// Percentage points of win probability, from the mover's own point of view.
public struct JudgementLines: Hashable, Sendable, Codable {
    /// Whether 把关 is on: a move costing the 记录线 or more is taken back. Off is the ordinary game.
    public var tilling: Bool
    /// Where a move gets written down, and where 把关 takes it back.
    public var record: Double
    /// Where a written-down move also earns practice time.
    public var enqueue: Double

    public init(tilling: Bool = false, record: Double = 10, enqueue: Double = 10) {
        self.tilling = tilling
        self.record = record
        self.enqueue = enqueue
    }

    /// 10 / 10, with 把关 off. The numbers a person who has never touched this gets.
    ///
    /// Both at ten: what is worth writing down is worth practising, and — 把关 reading the same
    /// line — what is worth writing down is what is worth stopping the player for. They were
    /// five, and a book that took every five-point slip filled with moves nobody would call a
    /// mistake — 「10% 的错题才会进入错题本」. They are still two lines and either moves on its own
    /// (docs/adr/0027) — a player who wants the book kept wider than the queue raises one of
    /// them — but the pair a phone ships with agree.
    public static let standard = JudgementLines()

    /// The scale a line is drawn on. A line off it is not a line.
    public static let scale = 0.0...100.0

    /// The 拦截线: where 把关 takes the move back, which is the 记录线 while it is on. Nil for 把关
    /// switched off. Derived, never set — what a judgement is stamped with (`Ply.Judgement
    /// .intercept`) and what the file says in its `Intercept` tag.
    public var intercept: Double? { tilling ? record : nil }

    /// Whether every line is a finite number on the scale.
    public var isDrawn: Bool {
        [record, enqueue].allSatisfy { $0.isFinite && Self.scale.contains($0) }
    }

    public func records(_ drop: Double?) -> Bool {
        guard let drop else { return false }
        return drop >= record
    }

    public func enqueues(_ drop: Double?) -> Bool {
        guard let drop else { return false }
        return drop >= enqueue
    }
}

/// What came of the opponent handing something over: how much they gave, how much was taken, and
/// how much of it went back (docs/adr/0027).
///
/// Said **after the reply lands and never before**. "There is something to win here" is the
/// strongest hint in chess, and a screen that says it while the player is still thinking has
/// answered the question it was supposed to be asking. So this is a settlement, not a warning:
/// the gift is only named once it has been either taken or missed.
public struct Settlement: Hashable, Sendable {
    /// What the opponent's move gave away, in percentage points, from the player's side.
    public let gift: Double
    /// How much of it the player still holds after replying. Can exceed the gift — a reply can
    /// be better than the position the opponent left.
    public let kept: Double
    /// What the reply gave back. Zero when the whole gift was taken.
    public let missed: Double

    /// Reads the three win chances around one exchange, all from the player's point of view:
    /// before the opponent moved, after they moved, and after the reply.
    ///
    /// Nil when the opponent's move gave away less than `lines.record` — most moves — because
    /// there is nothing to settle about a position nobody handed over.
    public init?(
        player: PieceColour,
        before: Score?,
        afterTheirMove: Score?,
        afterMyReply: Score?,
        lines: JudgementLines = .standard
    ) {
        guard let before, let afterTheirMove, let afterMyReply else { return nil }
        func mine(_ score: Score) -> Double {
            player == .white ? score.winPercent : 100 - score.winPercent
        }
        let gift = mine(afterTheirMove) - mine(before)
        guard lines.records(gift) else { return nil }

        self.gift = gift
        self.kept = mine(afterMyReply) - mine(before)
        self.missed = mine(afterTheirMove) - mine(afterMyReply)
    }

    /// Whether the reply gave enough back to be worth the sentence's second half. A point or two
    /// of the gift lost to a move that was otherwise right is noise, not a lesson.
    public var isClean: Bool { missed < MoveQuality.inaccuracyFrom }

    /// The sentence, in whole points because tenths of a percent are not a thing anybody feels.
    ///
    /// Two shapes, and which one is used is the whole content: a gift taken whole is one clause,
    /// and a gift partly handed back is three numbers that have to add up in front of the reader.
    public var sentence: String {
        let gift = Int(self.gift.rounded())
        guard !isClean else { return localized("settle.took", gift) }
        return localized("settle.missed", gift, Int(kept.rounded()), Int(missed.rounded()))
    }
}
