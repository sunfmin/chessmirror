import ChessmirrorKit
import Foundation
import Testing

/// The order of one day's queue (docs/adr/0030).

private let day = 86_400.0
private let now = Date(timeIntervalSince1970: 1_790_000_000)

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

private func position(_ index: Int) -> PositionKey {
    let files = "abcdefgh"
    let file = files[files.index(files.startIndex, offsetBy: index % 8)]
    return PositionKey("8/8/8/8/8/8/8/K6k w - - \(file)\(1 + index / 8)")
}

private func mistake(_ index: Int) -> Mistake {
    Mistake(
        position: position(index),
        encounters: [
            Encounter(
                game: URL(filePath: "/games/\(index).pgn"), ply: 4, when: now,
                played: "Qh4", wanted: "Nc6", cost: 30, origin: .fresh
            )
        ]
    )
}

private func go(
    _ index: Int, at when: Date, passed: Bool, seconds: Double
) -> (at: Date, attempt: PracticeLog.Attempt) {
    (
        when,
        PracticeLog.Attempt(
            position: position(index), seconds: seconds, passed: passed, played: "Nc6",
            cost: 30, hints: 0, source: .daily
        )
    )
}

/// The order of today's queue for a given history, which is the only thing these tests look at.
private func order(
    _ count: Int, _ attempts: [(at: Date, attempt: PracticeLog.Attempt)]
) -> [PositionKey] {
    Daily.forToday(
        book: MistakeBook(mistakes: (0..<count).map { mistake($0) }),
        attempts: attempts,
        now: now,
        calendar: utc
    ).cards.map(\.position)
}

// --------------------------------------------------- 1. a miss ignores the clock

@Test("a position missed last time comes before one that was held, however long each took")
func missesComeFirstWhateverTheClock() {
    let long = now.addingTimeInterval(-40 * day)
    // The miss was answered in two seconds; the hold took three minutes. The miss still leads.
    let queue = order(
        2,
        [
            go(0, at: long, passed: false, seconds: 2),
            go(1, at: long, passed: true, seconds: 180),
        ]
    )
    #expect(queue.first == position(0), "three minutes of thought and two seconds are the same event")
}

@Test("two misses are not ordered by how long they took either")
func missesDoNotRankAgainstEachOther() {
    let older = now.addingTimeInterval(-40 * day)
    let newer = now.addingTimeInterval(-20 * day)
    let queue = order(
        2,
        [go(0, at: older, passed: false, seconds: 1), go(1, at: newer, passed: false, seconds: 300)]
    )
    // Equal priority, so the tie falls to how long each has been waiting — not to the stopwatch.
    #expect(queue == [position(0), position(1)])
}

// ------------------------------------------- 2 & 3. time separates the right ones

@Test("between two held positions, the one that came slowly for itself goes first")
func slowerRelativeToItselfComesFirst() {
    let when = now.addingTimeInterval(-40 * day)
    var attempts: [(at: Date, attempt: PracticeLog.Attempt)] = []
    // Position 0 is normally a five-second position and took five seconds last time.
    // Position 1 is normally a five-second position and took twenty.
    for each in 0..<3 {
        let earlier = when.addingTimeInterval(-Double(10 + each) * day)
        attempts.append(go(0, at: earlier, passed: true, seconds: 5))
        attempts.append(go(1, at: earlier, passed: true, seconds: 5))
    }
    attempts.append(go(0, at: when, passed: true, seconds: 5))
    attempts.append(go(1, at: when, passed: true, seconds: 20))

    #expect(order(2, attempts).first == position(1), "twenty against its own five is hesitation")
}

@Test("the same stopwatch reading orders differently against different references")
func itIsTheRatioAndNotTheSeconds() {
    let when = now.addingTimeInterval(-40 * day)
    var attempts: [(at: Date, attempt: PracticeLog.Attempt)] = []
    // Both answered in exactly ten seconds last time. One is a position this player usually
    // takes three seconds over; the other usually takes thirty.
    for each in 0..<3 {
        let earlier = when.addingTimeInterval(-Double(10 + each) * day)
        attempts.append(go(0, at: earlier, passed: true, seconds: 3))
        attempts.append(go(1, at: earlier, passed: true, seconds: 30))
    }
    attempts.append(go(0, at: when, passed: true, seconds: 10))
    attempts.append(go(1, at: when, passed: true, seconds: 10))

    #expect(
        order(2, attempts) == [position(0), position(1)],
        "ten seconds over a three-second position is slow; over a thirty-second one it is fast"
    )
    // And the same two readings with the references swapped come out the other way round, which
    // is the whole claim: the seconds are identical and only the reference moved.
    var swapped: [(at: Date, attempt: PracticeLog.Attempt)] = []
    for each in 0..<3 {
        let earlier = when.addingTimeInterval(-Double(10 + each) * day)
        swapped.append(go(0, at: earlier, passed: true, seconds: 30))
        swapped.append(go(1, at: earlier, passed: true, seconds: 3))
    }
    swapped.append(go(0, at: when, passed: true, seconds: 10))
    swapped.append(go(1, at: when, passed: true, seconds: 10))
    #expect(order(2, swapped) == [position(1), position(0)])
}

// ------------------------------------------------------------- the bootstrapped number

@Test("a position with no history of its own borrows the player's, and a player with none is fine")
func theReferenceFallsBackWithoutBreaking() {
    let empty = ARTS.references([])
    #expect(empty.population == ARTS.assumedSeconds, "one bootstrapped number, and this is it")
    #expect(empty.seconds(for: position(3)) == ARTS.assumedSeconds)

    let when = now.addingTimeInterval(-10 * day)
    let known = ARTS.references([
        go(0, at: when, passed: true, seconds: 8),
        go(0, at: when, passed: true, seconds: 12),
        go(1, at: when, passed: false, seconds: 300),
    ])
    #expect(known.seconds(for: position(0)) == 10, "its own average, over the ones it got right")
    #expect(known.seconds(for: position(1)) == 10, "the player's own average, not 20")
    #expect(known.seconds(for: position(7)) == 10, "and a position never seen borrows the same")
}

@Test("a wrong answer never moves the reference it would be measured against")
func missesDoNotPollutTheReference() {
    let when = now.addingTimeInterval(-10 * day)
    let references = ARTS.references([
        go(0, at: when, passed: true, seconds: 6),
        go(0, at: when, passed: false, seconds: 600),
    ])
    #expect(references.seconds(for: position(0)) == 6, "600 seconds of being wrong says nothing")
}

@Test("a tap in no time at all is a reflex rather than a time")
func thereIsAFloorUnderTheClock() {
    let quick = ARTS.priority(lastPassed: true, seconds: 0, reference: 10)
    let slow = ARTS.priority(lastPassed: true, seconds: 100, reference: 10)
    #expect(quick != nil && quick!.isFinite, "log(0) is not a priority")
    #expect(slow! > quick!)
    #expect(ARTS.priority(lastPassed: false, seconds: 1, reference: 10) == ARTS.missPriority)
    #expect(ARTS.priority(lastPassed: nil, seconds: 1, reference: 10) == nil, "a new one has no time")
}

// ------------------------------------------------------------------- purity

@Test("the order is a pure function of the log")
func theSameLogGivesTheSameOrder() {
    let when = now.addingTimeInterval(-30 * day)
    let attempts = [
        go(0, at: when, passed: true, seconds: 4),
        go(1, at: when, passed: false, seconds: 30),
        go(2, at: when, passed: true, seconds: 22),
        go(3, at: when.addingTimeInterval(-day), passed: true, seconds: 9),
    ]
    let first = order(5, attempts)
    // Shuffled input, because a log read back off disk is in file order and nothing else.
    let again = order(5, attempts.reversed())
    #expect(first == again)
    #expect(first.first == position(1), "the miss, whatever order the rows arrived in")
}

// ------------------------------------------------------------------- the order

/// Contract: the order a day is worked in is ARTS's, tie-break and fallback included.
///
/// The formula lived here and the order lived in `Daily.forToday`, which is where the two things
/// that can put a queue in the wrong order — the sort's tie-break, and what a card with no go at
/// all is worth — sat out of reach of this file's tests.
@MainActor
@Suite struct ARTSOrderTests {
    private let quick = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -"
    private let slow = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -"
    private let missed = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq -"
    private let fresh = "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq -"

    private func card(_ fen: String, due: TimeInterval, last: Daily.Card.Go?) -> Daily.Card {
        Daily.Card(
            mistake: Mistake(position: PositionKey(fen), encounters: []),
            memory: nil,
            dueAt: Date(timeIntervalSince1970: due),
            lapses: 0,
            goes: last == nil ? 0 : 1,
            last: last
        )
    }

    private func go(_ passed: Bool, seconds: Double, at when: TimeInterval) -> Daily.Card.Go {
        Daily.Card.Go(at: Date(timeIntervalSince1970: when), passed: passed, seconds: seconds)
    }

    private func attempt(
        _ fen: String, passed: Bool, seconds: Double, at when: TimeInterval
    ) -> (at: Date, attempt: PracticeLog.Attempt) {
        (
            at: Date(timeIntervalSince1970: when),
            attempt: PracticeLog.Attempt(
                position: PositionKey(fen), seconds: seconds, passed: passed,
                played: "e4", cost: 0, hints: 0, source: .daily
            )
        )
    }

    @Test("a miss jumps the queue, a slow right answer waits, a fast one waits longest")
    func theDayIsOrdered() {
        // Each position's reference is its own history of right answers, so 「慢」 and 「快」 are
        // slow and fast *for this position*: both took ten seconds when they were known.
        let history = [
            attempt(quick, passed: true, seconds: 10, at: 0),
            attempt(quick, passed: true, seconds: 2, at: 10),
            attempt(slow, passed: true, seconds: 10, at: 0),
            attempt(slow, passed: true, seconds: 60, at: 10),
            attempt(missed, passed: false, seconds: 120, at: 10),
        ]
        let cards = [
            card(quick, due: 100, last: go(true, seconds: 2, at: 10)),
            card(fresh, due: 200, last: nil),
            card(missed, due: 300, last: go(false, seconds: 120, at: 10)),
            card(slow, due: 400, last: go(true, seconds: 60, at: 10)),
        ]

        let order = ARTS.order(cards, scheduled: history).map(\.position)
        #expect(
            order == [PositionKey(missed), PositionKey(slow), PositionKey(fresh), PositionKey(quick)]
        )
        #expect(order.first == PositionKey(missed), "a miss ignores the clock and jumps the queue")
        #expect(
            order[1] == PositionKey(slow),
            "a right answer that came slowly is ahead of one nobody has answered"
        )
        #expect(order.last == PositionKey(quick), "an answer that came fast waits its turn")
    }

    @Test("a card with no go at all sits where a punctual right answer would")
    func theFallbackIsZero() {
        // Nil priority means 「没证据」, not 「最不急」: a new card ranks with an answer that came
        // in exactly its own reference time, and the day's order does not push it to the end.
        let history = [
            attempt(quick, passed: true, seconds: 10, at: 0),
            attempt(quick, passed: true, seconds: 10, at: 10),
        ]
        let punctual = card(quick, due: 400, last: go(true, seconds: 10, at: 10))
        let new = card(fresh, due: 100, last: nil)
        #expect(ARTS.order([punctual, new], scheduled: history).map(\.position)
            == [PositionKey(fresh), PositionKey(quick)], "equal rank, so the older debt first")
    }

    @Test("cards that rank the same are worked oldest debt first")
    func theTieIsBrokenByWhenItCameDue() {
        let later = card(quick, due: 900, last: nil)
        let earlier = card(slow, due: 100, last: nil)
        let order = ARTS.order([later, earlier], scheduled: []).map(\.position)
        #expect(order == [PositionKey(slow), PositionKey(quick)])
    }
}
