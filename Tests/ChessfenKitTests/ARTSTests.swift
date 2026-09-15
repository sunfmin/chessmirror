import ChessfenKit
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
