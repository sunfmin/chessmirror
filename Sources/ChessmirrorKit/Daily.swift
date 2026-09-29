import Foundation

/// 日课: everything the player should practise today, in one order (docs/adr/0030, docs/adr/0032).
///
/// **One queue, and it cannot be cut up.** There is no filter here, no sort control, no theme
/// picker and no way to say "just these five" — not because they would be hard to build but
/// because they are the feature that undoes the thing being built. A learner who chooses what to
/// practise chooses what they are already good at (Kornell & Bjork), and a set narrowed to one
/// theme announces the answer before the position is on the screen (Einstellung). The API has no
/// hole for one either: what comes out is an ordered list, and the screen's only verb is "next".
///
/// Computed from the practice log every time, never stored (docs/adr/0029). Delete every derived
/// thing in the app and the same day comes back.
public struct Daily: Hashable, Sendable {
    /// One position in today's queue, with what FSRS makes of its history: a 错题, or a 藏局 of
    /// a 自动集 (docs/adr/0051). The two share one queue and one schedule, and nothing on the
    /// card a screen shows says which it is before the position is on the board.
    public struct Card: Hashable, Sendable, Identifiable {
        public let position: PositionKey
        /// The 错题, when this is one.
        public let mistake: Mistake?
        /// The 藏局, when this is one found in the games rather than got wrong in them.
        public let holding: Holding?
        /// What the schedule knows about it — nil for a position nobody has practised yet.
        public let memory: FSRS.Memory?
        /// When it came due. Nil for a new one, which is due the day it is let in.
        public let dueAt: Date?
        /// How many times it has been failed under the schedule.
        public let lapses: Int
        /// The last go, which is what ARTS sequences the day by (docs/adr/0030). Nil for a
        /// position nobody has practised.
        public let last: Go?

        /// One go, as the order needs it: whether it held, and how long it took.
        public struct Go: Hashable, Sendable {
            public let at: Date
            public let passed: Bool
            public let seconds: Double

            public init(at: Date, passed: Bool, seconds: Double) {
                self.at = at
                self.passed = passed
                self.seconds = seconds
            }
        }

        public var id: String { position.text }
        public var isNew: Bool { memory == nil }

        /// 掌握: the app does not expect to need this one for a long time — its next go is half
        /// a year after the last (docs/adr/0030). A reading, never a state: nothing is suspended
        /// and nothing is deleted on the strength of it, an item that reads as settled simply
        /// does not come up.
        ///
        /// **Read off the card rather than worked out again.** It was `Daily.isSettled(card:
        /// fsrs:)` — you needed the whole day in hand to ask about one position, and a second
        /// FSRS to ask it with, which could be a different FSRS from the one that scheduled the
        /// card. The gap between the last go and the next one *is* the interval FSRS decided on,
        /// so the card already carries the answer.
        public var isSettled: Bool {
            guard let dueAt, let last else { return false }
            return dueAt.timeIntervalSince(last.at) >= Daily.settledInterval * 86_400
        }

        public init(
            mistake: Mistake, memory: FSRS.Memory?, dueAt: Date?, lapses: Int, last: Go? = nil
        ) {
            self.position = mistake.position
            self.mistake = mistake
            self.holding = nil
            self.memory = memory
            self.dueAt = dueAt
            self.lapses = lapses
            self.last = last
        }

        public init(
            holding: Holding, memory: FSRS.Memory?, dueAt: Date?, lapses: Int, last: Go? = nil
        ) {
            self.position = holding.position
            self.mistake = nil
            self.holding = holding
            self.memory = memory
            self.dueAt = dueAt
            self.lapses = lapses
            self.last = last
        }
    }

    /// Today's queue, in the order it should be worked.
    public let cards: [Card]
    /// Everything eligible for practice, today's or not, each carrying its schedule. Today's
    /// queue is a slice of this; the rest is how anybody asks what the log has decided about a
    /// position that is *not* knocking — that a 计划外 go moved nothing, that the same log gives
    /// the same dates for ever (docs/adr/0029, 0032).
    public let all: [Card]

    public var remaining: Int { cards.count }
    public var isEmpty: Bool { cards.isEmpty }
    public var next: Card? { cards.first }

    /// How many positions a day may be let in for the first time.
    ///
    /// Ten, because a day that admits everything is a day that buries the player in a fortnight
    /// and a schedule nobody keeps is not a schedule. What does not fit waits, in the order
    /// `Mistake.isMorePressing` puts them in — 复发 before cost (docs/adr/0028).
    public static let newPerDay = 10

    /// How many 藏局 of the 自动集 a day may let in for the first time, counted apart from the
    /// 错题 so that shots found in the games never crowd out the moves the player got wrong
    /// (docs/adr/0051). What does not fit waits, the most recently found first.
    public static let foundPerDay = 5

    /// How far off a next go has to be for the position to read as 掌握: half a year, in days
    /// (`Card.isSettled`).
    public static let settledInterval = 180.0

    // ------------------------------------------------------------------ working it out

    /// Today's queue, from the book and the log.
    ///
    /// Only positions over the 入列线 are eligible at all: a move between the 记录线 and the
    /// 入列线 is worth writing down and looking at, and is not worth anybody's practice time
    /// (docs/adr/0027). The rest of the book stays readable and simply never knocks.
    ///
    /// The 自动集's 藏局 come in beside them (`found`), shuffled in rather than queued after: a
    /// position that is already an owed 错题 is scheduled as that and only once (docs/adr/0051).
    public static func forToday(
        book: MistakeBook,
        attempts: [(at: Date, attempt: PracticeLog.Attempt)],
        lines: JudgementLines = .standard,
        found: [Holding] = [],
        newPerDay: Int = Daily.newPerDay,
        foundPerDay: Int = Daily.foundPerDay,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Daily {
        // One FSRS, with the weights it ships with. It was a parameter for two years and nothing
        // ever passed one: a seam with no second adapter is a seam that only costs.
        let fsrs = FSRS()
        // 计划外 goes are recorded and then ignored here: practising something because you felt
        // like it is not evidence about when the schedule should have asked (docs/adr/0032).
        var history: [PositionKey: [Card.Go]] = [:]
        var scheduled: [(at: Date, attempt: PracticeLog.Attempt)] = []
        for row in attempts where row.attempt.source == .daily {
            history[row.attempt.position, default: []].append(
                Card.Go(at: row.at, passed: row.attempt.passed, seconds: row.attempt.seconds)
            )
            scheduled.append(row)
        }
        for key in history.keys {
            history[key]?.sort { $0.at < $1.at }
        }

        let eligible = book.mistakes.filter { Enrolment(mistake: $0, lines: lines).isOwed }
        let owed = Set(eligible.map(\.position))
        let kept = found.filter { !owed.contains($0.position) }
        func schedule(_ position: PositionKey) -> (FSRS.Memory?, Date?, Int, Card.Go?) {
            let gone = history[position] ?? []
            var memory: FSRS.Memory?
            var last: Date?
            var lapses = 0
            for go in gone {
                if let standing = memory, let previous = last {
                    let days = go.at.timeIntervalSince(previous) / 86_400
                    memory = fsrs.next(standing, passed: go.passed, after: days)
                } else {
                    memory = fsrs.first(passed: go.passed)
                }
                if !go.passed { lapses += 1 }
                last = go.at
            }
            return (
                memory,
                memory.flatMap { standing in last.map { fsrs.due(standing, after: $0) } },
                lapses,
                gone.last
            )
        }
        let mistakes = eligible.map { mistake -> Card in
            let (memory, dueAt, lapses, last) = schedule(mistake.position)
            return Card(mistake: mistake, memory: memory, dueAt: dueAt, lapses: lapses, last: last)
        }
        let holdings = kept.map { holding -> Card in
            let (memory, dueAt, lapses, last) = schedule(holding.position)
            return Card(holding: holding, memory: memory, dueAt: dueAt, lapses: lapses, last: last)
        }
        let all = mistakes + holdings

        // The whole of today is available from the moment it starts, the way every spaced
        // repetition app does it: a schedule that dribbled cards out by the hour would mean
        // opening the app five times to finish a day.
        let endOfDay = calendar.startOfDay(for: now).addingTimeInterval(86_400)
        // ARTS orders what FSRS has already decided is due: missed before held, and among the
        // held, the ones that came slowly for *this* position before the ones that came quickly
        // (docs/adr/0030). How overdue a card is only breaks a tie — the day was FSRS's decision
        // and this does not relitigate it. The order is ARTS's own (`ARTS.order`); which cards
        // are due today is this function's.
        let due = ARTS.order(
            all.filter { card in card.dueAt.map { $0 < endOfDay } ?? false },
            scheduled: scheduled
        )

        // How many have already been let in today, so that a day's intake is a day's intake
        // however many times the app is opened.
        let today = calendar.startOfDay(for: now)
        let foundKeys = Set(kept.map(\.position))
        let firstToday = history.filter { _, gone in (gone.first?.at ?? .distantPast) >= today }
        let admittedFound = firstToday.keys.count { foundKeys.contains($0) }
        let admitted = firstToday.count - admittedFound
        let fresh = mistakes
            .filter(\.isNew)
            .sorted { one, other in
                guard let one = one.mistake, let other = other.mistake else { return false }
                return one.isMorePressing(than: other)
            }
            .prefix(max(0, newPerDay - admitted))
        let freshFound = holdings
            .filter(\.isNew)
            .sorted { one, other in
                let a = one.holding?.added ?? .distantPast
                let b = other.holding?.added ?? .distantPast
                return a == b ? one.position.text < other.position.text : a > b
            }
            .prefix(max(0, foundPerDay - admittedFound))

        // Due before new, and a card just failed sorts to the back of the due ones on its own:
        // its next go is hours away where an overdue one's was days ago. Within the day this is
        // the order ARTS replaces (docs/adr/0030). The new ones of the two kinds take turns, so
        // the queue never runs a block of one kind that would say what the next answer is.
        return Daily(cards: due + Self.alternate(Array(fresh), Array(freshFound)), all: all)
    }

    /// One of each in turn, then whatever is left of the longer.
    static func alternate(_ one: [Card], _ other: [Card]) -> [Card] {
        var mixed: [Card] = []
        for index in 0..<max(one.count, other.count) {
            if index < one.count { mixed.append(one[index]) }
            if index < other.count { mixed.append(other[index]) }
        }
        return mixed
    }

    public init(cards: [Card], all: [Card] = []) {
        self.cards = cards
        self.all = all.isEmpty ? cards : all
    }
}
