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
    /// One position in today's queue, with what FSRS makes of its history.
    public struct Card: Hashable, Sendable, Identifiable {
        public let mistake: Mistake
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

        public var id: String { mistake.id }
        public var position: PositionKey { mistake.position }
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
            self.mistake = mistake
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

    /// How far off a next go has to be for the position to read as 掌握: half a year, in days
    /// (`Card.isSettled`).
    public static let settledInterval = 180.0

    // ------------------------------------------------------------------ working it out

    /// Today's queue, from the book and the log.
    ///
    /// Only positions over the 入列线 are eligible at all: a move between the 记录线 and the
    /// 入列线 is worth writing down and looking at, and is not worth anybody's practice time
    /// (docs/adr/0027). The rest of the book stays readable and simply never knocks.
    public static func forToday(
        book: MistakeBook,
        attempts: [(at: Date, attempt: PracticeLog.Attempt)],
        lines: JudgementLines = .standard,
        newPerDay: Int = Daily.newPerDay,
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

        let eligible = book.mistakes.filter { lines.enqueues($0.worstCost) }
        let all = eligible.map { mistake -> Card in
            let gone = history[mistake.position] ?? []
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
            return Card(
                mistake: mistake,
                memory: memory,
                dueAt: memory.flatMap { standing in last.map { fsrs.due(standing, after: $0) } },
                lapses: lapses,
                last: gone.last
            )
        }

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
        let admitted = history.count { _, gone in (gone.first?.at ?? .distantPast) >= today }
        let room = max(0, newPerDay - admitted)
        let fresh = all
            .filter(\.isNew)
            .sorted { $0.mistake.isMorePressing(than: $1.mistake) }
            .prefix(room)

        // Due before new, and a card just failed sorts to the back of the due ones on its own:
        // its next go is hours away where an overdue one's was days ago. Within the day this is
        // the order ARTS replaces (docs/adr/0030).
        return Daily(cards: due + fresh, all: all)
    }

    public init(cards: [Card], all: [Card] = []) {
        self.cards = cards
        self.all = all.isEmpty ? cards : all
    }
}
