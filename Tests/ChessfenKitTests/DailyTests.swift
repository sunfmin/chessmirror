import ChessfenKit
import Foundation
import Testing

/// 日课: which positions come back today, and in what order (docs/adr/0030, docs/adr/0032).

private let day = 86_400.0
private let now = Date(timeIntervalSince1970: 1_790_000_000)

/// A fixed calendar, so that what counts as "today" is the same on every machine that runs this.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

/// Positions that differ only in where one rook stands, so a test can have as many distinct
/// 错题 as it likes without any of them being interesting.
private func position(_ index: Int) -> PositionKey {
    let files = "abcdefgh"
    let file = files[files.index(files.startIndex, offsetBy: index % 8)]
    let rank = 1 + index / 8
    return PositionKey("8/8/8/8/8/8/8/K6k w - - \(file)\(rank)")
}

private func mistake(_ index: Int, cost: Double = 30, times: Int = 1) -> Mistake {
    Mistake(
        position: position(index),
        encounters: (0..<times).map { each in
            Encounter(
                game: URL(filePath: "/games/\(index)-\(each).pgn"), ply: 4,
                when: now.addingTimeInterval(-Double(each) * day),
                played: "Qh4", wanted: "Nc6", cost: cost, origin: .fresh
            )
        }
    )
}

private func go(
    _ index: Int, at when: Date, passed: Bool, source: Drill.Source = .daily, seconds: Double = 5
) -> (at: Date, attempt: PracticeLog.Attempt) {
    (
        when,
        PracticeLog.Attempt(
            position: position(index), seconds: seconds, passed: passed, played: "Nc6",
            cost: 30, hints: 0, source: source
        )
    )
}

// ------------------------------------------------------------------- the curve

@Test("the interval at the default retention is the stability, by construction")
func stabilityIsTheInterval() {
    let fsrs = FSRS()
    let memory = FSRS.Memory(stability: 12, difficulty: 5)
    #expect(abs(fsrs.interval(memory) - 12) < 0.0001)
    #expect(abs(fsrs.retrievability(memory, after: 12) - 0.9) < 0.0001)
    #expect(fsrs.retrievability(memory, after: 0) == 1)
    // The curve is a power law rather than an exponential, so it has a long tail: ten times the
    // stability is still better than a coin toss.
    #expect(fsrs.retrievability(memory, after: 120) < 0.6)
}

@Test("a first pass and a first failure start where the published weights say")
func theFirstGoIsTheWeights() {
    let fsrs = FSRS()
    let passed = fsrs.first(passed: true)
    let failed = fsrs.first(passed: false)
    #expect(abs(passed.stability - FSRS.defaultWeights[2]) < 0.0001, "Good is w[2]")
    #expect(abs(failed.stability - FSRS.defaultWeights[0]) < 0.0001, "Again is w[0]")
    #expect(abs(passed.difficulty - FSRS.defaultWeights[4]) < 0.0001)
    #expect(failed.difficulty > passed.difficulty, "getting it wrong first go makes it harder")
    #expect(failed.stability < 1, "and it comes back inside a day")
}

@Test("passing pushes an item out and failing pulls it back")
func rightAnswersGoFurtherAway() {
    let fsrs = FSRS()
    var memory = fsrs.first(passed: true)
    let first = fsrs.interval(memory)
    memory = fsrs.next(memory, passed: true, after: first)
    let second = fsrs.interval(memory)
    #expect(second > first, "\(second) has to be further out than \(first)")

    memory = fsrs.next(memory, passed: false, after: second)
    #expect(fsrs.interval(memory) < second, "a failure never leaves the memory stronger")
    #expect(memory.difficulty > FSRS.defaultWeights[4], "and the item is now harder")
}

// -------------------------------------------------------------------- the queue

@Test("a fresh book fills today up to the daily cap and the rest wait")
func onlyTenNewOnesADay() {
    let book = MistakeBook(mistakes: (0..<25).map { mistake($0) })
    let daily = Daily.forToday(book: book, attempts: [], now: now, calendar: utc)
    #expect(daily.remaining == Daily.newPerDay)
    #expect(daily.all.count == 25, "the rest are eligible, they are just not today's")
}

@Test("recurrence jumps the queue whatever any one go cost")
func recurrenceBeatsCost() {
    // One position fallen for three times at 22% and one fallen for once at 45%.
    let often = mistake(1, cost: 22, times: 3)
    let once = mistake(2, cost: 45, times: 1)
    let daily = Daily.forToday(
        book: MistakeBook(mistakes: [once, often]), attempts: [], newPerDay: 2, now: now, calendar: utc
    )
    #expect(daily.cards.first?.position == often.position, "三次 22% is a missing concept")
    #expect(daily.cards.last?.position == once.position, "45% once may only be a tired evening")
}

@Test("a move under the 入列线 is in the book and never knocks")
func onlyTheEnqueueLineTakesPracticeTime() {
    let book = MistakeBook(mistakes: [mistake(1, cost: 12), mistake(2, cost: 25)])
    let daily = Daily.forToday(
        book: book, attempts: [], lines: JudgementLines(record: 10, enqueue: 20), now: now,
        calendar: utc
    )
    #expect(daily.all.count == 1, "under a 20% 入列线, 12% is written down and not drilled")
    #expect(daily.cards.first?.position == position(2))
}

@Test("a position answered right today is gone; one answered wrong comes back today")
func passingEmptiesTheDayAndFailingDoesNot() {
    let book = MistakeBook(mistakes: [mistake(1), mistake(2)])
    let morning = now.addingTimeInterval(-3 * 3_600)

    let bothRight = Daily.forToday(
        book: book,
        attempts: [go(1, at: morning, passed: true), go(2, at: morning, passed: true)],
        now: now, calendar: utc
    )
    #expect(bothRight.isEmpty, "练完就空")

    let oneWrong = Daily.forToday(
        book: book,
        attempts: [go(1, at: morning, passed: false), go(2, at: morning, passed: true)],
        now: now, calendar: utc
    )
    #expect(oneWrong.cards.map(\.position) == [position(1)], "答错的当天回来")
}

@Test("a right answer is not asked for again tomorrow")
func aPassedItemStaysAway() {
    let book = MistakeBook(mistakes: [mistake(1)])
    let attempts = [go(1, at: now, passed: true)]
    let tomorrow = Daily.forToday(book: book, attempts: attempts, now: now.addingTimeInterval(day), calendar: utc)
    #expect(tomorrow.isEmpty, "the first pass buys about \(FSRS.defaultWeights[2]) days")
    let laterOn = Daily.forToday(
        book: book, attempts: attempts, now: now.addingTimeInterval(5 * day), calendar: utc
    )
    #expect(laterOn.remaining == 1, "and then it is back")
}

@Test("the overdue come before the barely due, and the new come after both")
func theOrderIsDueThenNew() {
    let book = MistakeBook(mistakes: [mistake(1), mistake(2), mistake(3)])
    let daily = Daily.forToday(
        book: book,
        attempts: [
            go(1, at: now.addingTimeInterval(-30 * day), passed: true),
            go(2, at: now.addingTimeInterval(-5 * day), passed: true),
        ],
        now: now, calendar: utc
    )
    #expect(daily.cards.map(\.position) == [position(1), position(2), position(3)])
    #expect(daily.cards.last?.isNew == true)
}

// ------------------------------------------------------ what the queue refuses

@Test("practising off the book changes nothing about when the schedule asks")
func anUnplannedGoDoesNotMoveTheDate() {
    let book = MistakeBook(mistakes: [mistake(1)])
    let scheduled = [go(1, at: now.addingTimeInterval(-2 * day), passed: true)]
    let before = Daily.forToday(book: book, attempts: scheduled, now: now, calendar: utc)

    let alsoPicked =
        scheduled + [go(1, at: now.addingTimeInterval(-3_600), passed: false, source: .picked)]
    let after = Daily.forToday(book: book, attempts: alsoPicked, now: now, calendar: utc)

    #expect(before.all.first?.dueAt == after.all.first?.dueAt, "计划外 is recorded, not counted")
    #expect(after.all.first?.lapses == 0, "and a failure off the book is not a lapse")
}

@Test("the day is a pure function of the log, so a rebuilt index schedules the same day")
func theSameLogGivesTheSameDay() {
    let book = MistakeBook(mistakes: (0..<12).map { mistake($0) })
    let attempts = [
        go(0, at: now.addingTimeInterval(-9 * day), passed: true),
        go(0, at: now.addingTimeInterval(-4 * day), passed: false),
        go(1, at: now.addingTimeInterval(-2 * day), passed: true),
    ]
    let first = Daily.forToday(book: book, attempts: attempts, now: now, calendar: utc)
    // Everything derived thrown away and worked out again from the same two inputs.
    let again = Daily.forToday(
        book: MistakeBook(mistakes: book.mistakes), attempts: attempts, now: now, calendar: utc
    )
    #expect(first.cards.map(\.position) == again.cards.map(\.position))
    #expect(first.all.map(\.dueAt) == again.all.map(\.dueAt), "the dates too, to the second")
}

@Test("a long run of right answers reads as 掌握, and is not a state anybody stored")
func masteryIsAReadingOfTheInterval() {
    let book = MistakeBook(mistakes: [mistake(1)])
    var attempts: [(at: Date, attempt: PracticeLog.Attempt)] = []
    var when = now.addingTimeInterval(-400 * day)
    // Practised whenever it came due, and never missed.
    for _ in 0..<7 {
        attempts.append(go(1, at: when, passed: true))
        let soFar = Daily.forToday(book: book, attempts: attempts, now: when, calendar: utc)
        let interval = soFar.all.first?.memory.map { FSRS().interval($0) } ?? 0
        when = when.addingTimeInterval(interval * day)
    }
    let daily = Daily.forToday(book: book, attempts: attempts, now: now, calendar: utc)
    let card = try! #require(daily.all.first)
    #expect(daily.isSettled(card), "seven straight passes is half a year away")
    #expect(!daily.isStubborn(card))
    #expect(daily.isEmpty, "and it simply does not come up")
}

@Test("a position failed three times is labelled, not suspended and not deleted")
func stubbornOnesAreOnlyLabelled() {
    let book = MistakeBook(mistakes: [mistake(1)])
    let attempts = (1...3).map { each in
        go(1, at: now.addingTimeInterval(-Double(4 - each) * day), passed: false)
    }
    let daily = Daily.forToday(book: book, attempts: attempts, now: now, calendar: utc)
    let card = try! #require(daily.all.first)
    #expect(daily.isStubborn(card))
    #expect(daily.cards.contains { $0.position == card.position }, "it keeps coming back")
}
