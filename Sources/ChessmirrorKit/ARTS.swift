import Foundation

/// Adaptive Response-Time-based Sequencing, for the order of one day's queue (docs/adr/0030).
///
/// FSRS says which day a position comes back. This says what order the day is worked in, and it
/// is the one place in the schedule where **how long the player took** is allowed to matter.
/// Mettler, Massey & Kellman (2016) measured d = 0.56–0.78 against fixed sequencing, and three
/// properties of its shape are copied exactly rather than improvised on:
///
/// 1. **A wrong answer ignores the time entirely** and takes a large fixed jump. Three minutes of
///    thought ending in the wrong move and two seconds ending in the wrong move are the same
///    event, and a formula that ranked the slow one higher would be reading effort as knowledge.
/// 2. **Time only separates answers that were right.** It measures fluency, and fluency is only a
///    question once correctness is settled.
/// 3. **It enters as `log(seconds / this item's own reference)`** — compressed, and relative. This
///    is what absorbs the noise a long position, a distraction or a slow thumb puts into a
///    stopwatch, which is the objection FSRS's maintainers raised against latency in the first
///    place. That objection was about how it feels to be timed while grading yourself; nobody is
///    grading themselves here.
///
/// Everything is a pure function of the practice log: the same log gives the same order after a
/// relaunch, on another device, for ever (docs/adr/0029).
public enum ARTS {
    /// What a miss is worth. Large enough that no ratio of times can climb over it, which is
    /// property 1 said in arithmetic rather than in prose.
    public static let missPriority = 1_000.0

    /// The reference time for a position nobody has answered correctly yet, when the player has
    /// no history to average either. **The one number in the scheduler that is bootstrapped**
    /// (docs/adr/0030) — twenty seconds is a plausible look at a chess position, and it stops
    /// mattering the moment there is any real history to use instead.
    public static let assumedSeconds = 20.0

    /// A floor, because `log(0)` is not a priority and a tap in a tenth of a second is a reflex
    /// rather than a time.
    public static let shortestSeconds = 0.5

    /// How long this player usually takes: per position where they have answered it right
    /// before, and over everything they have answered right where they have not.
    public struct References: Hashable, Sendable {
        public let byPosition: [PositionKey: Double]
        /// What the population — this player's own whole history — says, for an item with no
        /// answers of its own yet.
        public let population: Double

        public init(byPosition: [PositionKey: Double], population: Double) {
            self.byPosition = byPosition
            self.population = population
        }

        public func seconds(for position: PositionKey) -> Double {
            max(Self.shortest, byPosition[position] ?? population)
        }

        private static let shortest = ARTS.shortestSeconds
    }

    /// The reference times, taken over the answers that were **right**.
    ///
    /// Right ones only, and for the same reason the priority ignores the time on a miss: a
    /// three-minute wrong answer says nothing about how long this position takes when it is
    /// known, and averaging it in would move the reference away from exactly what it is for.
    public static func references(
        _ attempts: [(at: Date, attempt: PracticeLog.Attempt)]
    ) -> References {
        var totals: [PositionKey: (sum: Double, count: Int)] = [:]
        var everySum = 0.0
        var everyCount = 0
        for row in attempts where row.attempt.passed {
            let seconds = max(shortestSeconds, row.attempt.seconds)
            let standing = totals[row.attempt.position] ?? (0, 0)
            totals[row.attempt.position] = (standing.sum + seconds, standing.count + 1)
            everySum += seconds
            everyCount += 1
        }
        return References(
            byPosition: totals.mapValues { $0.sum / Double($0.count) },
            population: everyCount > 0 ? everySum / Double(everyCount) : assumedSeconds
        )
    }

    /// The order one day is worked in: the due cards, sequenced.
    ///
    /// **Here rather than at the caller.** The formula was here and the order was in
    /// `Daily.forToday` — the sort, the tie-break and the "a position with no go at all is
    /// worth nothing" fallback — so the two decisions that can put the queue in the wrong order
    /// lived where this file's tests could not reach them. Higher priority first, and among
    /// equals the one that came due first, because a day worked from the top should clear the
    /// oldest debt first (docs/adr/0030).
    ///
    /// `scheduled` is every 日课 go ever taken, which is what the references are averaged over —
    /// not just today's cards, and not the 计划外 ones (docs/adr/0032).
    public static func order(
        _ cards: [Daily.Card], scheduled: [(at: Date, attempt: PracticeLog.Attempt)]
    ) -> [Daily.Card] {
        let references = references(scheduled)
        func rank(_ card: Daily.Card) -> Double {
            priority(
                lastPassed: card.last?.passed,
                seconds: card.last?.seconds ?? 0,
                reference: references.seconds(for: card.position)
            ) ?? 0
        }
        return cards.sorted { one, other in
            let mine = rank(one)
            let theirs = rank(other)
            if mine != theirs { return mine > theirs }
            return (one.dueAt ?? .distantPast) < (other.dueAt ?? .distantPast)
        }
    }

    /// What one position's last go is worth in the queue. Higher goes first.
    ///
    /// Nil for a position with no go at all: a new one has no response time to sequence by, and
    /// guessing a priority for it would be inventing evidence.
    public static func priority(
        lastPassed: Bool?, seconds: Double, reference: Double
    ) -> Double? {
        guard let lastPassed else { return nil }
        guard lastPassed else { return missPriority }
        return log(max(shortestSeconds, seconds) / max(shortestSeconds, reference))
    }
}
