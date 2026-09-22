import ChessmirrorKit
import ChessmirrorKitTesting
import Foundation
import Testing

/// The cache the 错题本 is kept in, and the one thing in it that is not derived from the games
/// (docs/adr/0028, docs/adr/0029).

private let now = Date(timeIntervalSince1970: 1_790_000_000)

/// A log in its own temporary file, so nothing here touches the player's real one.
private func temporaryLog() -> PracticeLog {
    PracticeLog(
        url: URL(filePath: NSTemporaryDirectory())
            .appending(path: "chessmirror-practice-\(UUID().uuidString).jsonl")
    )
}

/// Deterministic, so a hundred games are the same hundred games on every machine and a timing is
/// comparable between runs.
private struct Dice {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 2_654_435_761 &+ 1 }
    mutating func next(below limit: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Int(state % UInt64(max(1, limit)))
    }
}

/// A reviewed game where the player is level all the way and then throws it away on the last
/// move. The walk is random, so every seed is a different set of positions — which is the point:
/// a hundred games that all repeated one opening would merge into one 错题 and measure nothing.
@MainActor
private func game(seed: Int, at when: Date, plies: Int = 40) throws -> GameLibrary.Entry {
    var dice = Dice(seed: UInt64(seed))
    var walked = try #require(Game(startFEN: PGN.standardStartFEN))
    var ucis: [String] = []
    for _ in 0..<plies {
        let moves = walked.state.legalMoves
        guard !moves.isEmpty else { break }
        let pick = moves[dice.next(below: moves.count)]
        guard walked.apply(pick) else { break }
        ucis.append(pick.uci)
    }
    var built = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ucis))
    var scores = [Int](repeating: 0, count: built.plies.count)
    if let last = scores.indices.last {
        // Whoever moved last hands over four pawns, so every game has exactly one 错题.
        scores[last] = built.mover(ofPly: built.plies.count) == .white ? -400 : 400
    }
    built.applyReview(
        scores.map { Score.centipawns($0) }, startEvaluation: .centipawns(0), depth: 16
    )
    let pgn = PGN(
        game: built,
        tags: [
            PGN.Tag("White", Controller.hand.playerName),
            PGN.Tag("Black", Controller.hand.playerName),
        ]
    )
    return GameLibrary.Entry(
        url: URL(filePath: "/games/seed-\(seed).pgn"), pgn: pgn, modified: when
    )
}

// --------------------------------------------------------------------- the cache

/// Contract: real PGN write → library entry → book → transient receipt. Initial loading,
/// identical saves, dismissed positions, and threshold changes must not announce new work.
@MainActor
@Test func savedMistakesProduceReceiptsOnlyForNewOccasions() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = GameLibrary(folder: GameFolder(url: directory))
    let index = MistakeIndex(log: PracticeLog(url: directory.appending(path: "practice.jsonl")))
    index.update(from: library.entries)
    #expect(index.recording == nil)
    let fixture = try game(seed: 1, at: now, plies: 4)
    let pgn = try #require(fixture.pgn)
    let url = directory.appending(path: "game.pgn")
    #expect(library.write(pgn, to: url))
    index.update(from: library.entries)
    #expect(!index.book.isEmpty)
    var receipt = try #require(index.recording)
    #expect(receipt.count == 1)
    #expect(library.write(pgn, to: url))
    index.update(from: library.entries)
    #expect(index.recording == receipt)
    let reloaded = MistakeIndex(log: index.log)
    reloaded.update(from: library.entries)
    #expect(!reloaded.book.isEmpty)
    #expect(reloaded.recording == nil)
    #expect(library.write(pgn, to: directory.appending(path: "recurrence.pgn")))
    index.update(from: library.entries)
    #expect(index.book.mistakes.count == 1)
    #expect(index.book.mistakes.first?.recurrence == 2)
    #expect(index.recording?.id != receipt.id)
    receipt = try #require(index.recording)
    #expect(receipt.count == 1)
    #expect(!library.write(pgn, to: directory))
    index.update(from: library.entries)
    #expect(index.recording == receipt, "a failed save cannot announce success")
    let position = try #require(index.book.mistakes.first?.position)
    index.dismiss(position)
    #expect(library.write(pgn, to: directory.appending(path: "again.pgn")))
    index.update(from: library.entries)
    #expect(index.book.isEmpty)
    #expect(index.recording == receipt)
    index.update(from: library.entries, lines: JudgementLines(record: 40, enqueue: 50))
    index.update(from: library.entries, lines: JudgementLines(record: 5, enqueue: 20))
    #expect(index.recording == receipt)
}

@MainActor
@Test("a reload that changed nothing walks no games at all")
func anUnchangedLibraryIsNotWalkedAgain() throws {
    let index = MistakeIndex(log: temporaryLog())
    let entries = try (1...20).map { try game(seed: $0, at: now) }

    index.update(from: entries)
    #expect(index.walkedLastTime == 20, "the first time, all of them")
    let first = index.book.mistakes.count
    #expect(first > 0)

    index.update(from: entries)
    #expect(index.walkedLastTime == 0, "and the second time, none")
    #expect(index.book.mistakes.count == first, "without losing what it found")
}

@MainActor
@Test("a game saved means a game walked, not the whole library")
func onlyTheChangedGameIsWalked() throws {
    let index = MistakeIndex(log: temporaryLog())
    var entries = try (1...20).map { try game(seed: $0, at: now) }
    index.update(from: entries)

    entries.append(try game(seed: 99, at: now.addingTimeInterval(60)))
    index.update(from: entries)
    #expect(index.walkedLastTime == 1, "the new one and nothing else")

    // A file written since — a game played on, or reviewed — is a different game under the same
    // name, so it is walked again.
    entries[3] = try game(seed: 4, at: now.addingTimeInterval(120))
    index.update(from: entries)
    #expect(index.walkedLastTime == 1)

    // And a game deleted leaves with its findings.
    let withoutTheNewest = Array(entries.dropLast())
    index.update(from: withoutTheNewest)
    #expect(index.walkedLastTime == 0)
    #expect(index.book.mistakes.count < 21)
}

@MainActor
@Test("moving a line throws the cache away, because it changes which moves count")
func aMovedLineRewalksEverything() throws {
    let index = MistakeIndex(log: temporaryLog())
    let entries = try (1...10).map { try game(seed: $0, at: now) }
    index.update(from: entries)
    #expect(index.walkedLastTime == 10)

    index.update(from: entries, lines: .standard)
    #expect(index.walkedLastTime == 0, "the same lines are the same lines")

    index.update(from: entries, lines: JudgementLines(record: 40, enqueue: 50))
    #expect(index.walkedLastTime == 10)
    #expect(index.book.isEmpty, "31 points is under a 40-point 记录线")
}

@MainActor
@Test("a hundred games are derived once and then cost nothing")
func aHundredGamesOpenFastEnough() throws {
    let index = MistakeIndex(log: temporaryLog())
    let entries = try (1...100).map { try game(seed: $0, at: now) }

    let cold = ContinuousClock().measure { index.update(from: entries) }
    #expect(index.walkedLastTime == 100)
    let warm = ContinuousClock().measure { index.update(from: entries) }
    #expect(index.walkedLastTime == 0)

    print("[BOOK] 100 games — cold \(cold), warm \(warm)")
    // This machine gets 66 ms cold and a tenth of a millisecond warm. The bounds are loose
    // enough for a slower one and tight enough to catch the walk coming back.
    #expect(cold < .seconds(3), "deriving a hundred games once, got \(cold)")
    #expect(warm < .milliseconds(20), "opening a screen after that, got \(warm)")
    #expect(warm * 10 < cold, "warm \(warm) has to be a different order of thing from cold \(cold)")
}

// ------------------------------------------------------------------ striking off

@MainActor
@Test("a position struck off stays off, and can be put back")
func dismissingOneKeepsItOut() throws {
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }
    let index = MistakeIndex(log: log)
    let entries = try (1...5).map { try game(seed: $0, at: now) }
    index.update(from: entries)

    let struck = try #require(index.book.mistakes.first?.position)
    let before = index.book.mistakes.count
    index.dismiss(struck)
    #expect(index.book.mistakes.count == before - 1)
    #expect(index.book[struck] == nil)

    // And it stays off across a reload, because it is a fact in the log rather than a flag in the
    // cache (docs/adr/0029) — throwing the cache away does not bring it back.
    index.update(from: entries, lines: JudgementLines(record: 5, enqueue: 20))
    #expect(index.book[struck] == nil, "the cache was rebuilt from scratch and it is still off")

    index.restore(struck)
    #expect(index.book[struck] != nil, "no reason was asked for in either direction")
}

// ---------------------------------------------------------------- the log itself

@Test("the log is append-only, and the standing answer is computed from it")
func theLogOnlyEverGrows() throws {
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }
    let one = PositionKey("8/8/8/8/8/8/8/K6k w - -")
    let other = PositionKey("8/8/8/8/8/8/8/K5k1 w - -")

    log.append(.dismissed(one), at: now)
    log.append(.dismissed(other), at: now.addingTimeInterval(1))
    log.append(.restored(one), at: now.addingTimeInterval(2))

    #expect(log.entries().count == 3, "nothing was rewritten to say the first one is back")
    #expect(log.dismissed() == [other], "the last word about a position wins")
    #expect(log.entries().map(\.at) == log.entries().map(\.at).sorted(), "oldest first")
}

@Test("a corrupt line costs that line and not the history")
func oneBadRowIsSkipped() throws {
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }
    let key = PositionKey("8/8/8/8/8/8/8/K6k w - -")
    log.append(.dismissed(key), at: now)

    // Half a line, the way a crash mid-write leaves one.
    let handle = try #require(try? FileHandle(forWritingTo: log.url))
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"at\":\"2026-09\n".utf8))
    try handle.close()

    log.append(.restored(key), at: now.addingTimeInterval(1))
    #expect(log.entries().count == 2, "the two good rows")
    #expect(log.dismissed().isEmpty, "and the restore after the damage was still read")
}

@Test("a log nobody has written reads as nothing, not as an error")
func anEmptyLogIsQuiet() {
    #expect(temporaryLog().entries().isEmpty)
    #expect(temporaryLog().dismissed().isEmpty)
}

// -------------------------------------------------------------------- the day

@MainActor
@Test("throwing the index away and building it again schedules the very same day")
func aRebuiltIndexKeepsTheDueDates() throws {
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }
    let entries = try (1...6).map { try game(seed: $0, at: now) }

    let first = MistakeIndex(log: log)
    first.update(from: entries)
    let card = try #require(first.daily.all.first)
    log.append(
        .drilled(
            PracticeLog.Attempt(
                position: card.position, seconds: 8, passed: true, played: "Nc6", cost: 2,
                hints: 0, source: .daily
            )
        ),
        at: Date(timeIntervalSince1970: 1_789_000_000)
    )
    first.refresh(now: now)
    let scheduled = first.daily.all.first { $0.position == card.position }?.dueAt

    // A different object over the same two inputs — which is what deleting the cache is.
    let rebuilt = MistakeIndex(log: log)
    rebuilt.update(from: entries)
    rebuilt.refresh(now: now)
    let again = rebuilt.daily.all.first { $0.position == card.position }?.dueAt

    #expect(scheduled != nil)
    #expect(scheduled == again, "the date is computed, so there is nothing to lose")
}

// ------------------------------------------------------------------ per game

/// Contract: the number on a game's row and the number an imported chapter reports are one
/// reading of the book, by position rather than by 遭遇, less what has been struck off.
@MainActor
@Test("each game's wrong positions are read off the book, and struck-off ones are not counted")
func wrongPositionsPerGameFollowTheBook() throws {
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }
    let index = MistakeIndex(log: log)
    let entries = try (1...3).map { try game(seed: $0, at: now) }
    index.update(from: entries)

    #expect(index.wrongByGame.count == 3)
    #expect(entries.allSatisfy { index.wrongByGame[$0.url] == 1 }, "one 错题 per fixture game")

    let struck = try #require(index.book.mistakes.first)
    let itsGame = try #require(struck.encounters.first?.game)
    index.dismiss(struck.position)
    #expect(index.wrongByGame[itsGame] == nil, "struck off, so nothing wrong left in that game")
    #expect(index.wrongByGame.count == 2)

    index.restore(struck.position)
    #expect(index.wrongByGame[itsGame] == 1)
}

@MainActor
@Test("an imported game's status is the library's fact and the book's count")
func importStatusReadsTheBook() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = GameLibrary(folder: GameFolder(url: directory))
    let index = MistakeIndex(log: PracticeLog(url: directory.appending(path: "practice.jsonl")))

    let reviewed = try game(seed: 7, at: now)
    index.update(from: [reviewed])
    #expect(PGNImport.Status(scoring: nil, isReviewed: true, wrong: 1) == .ready(1))
    #expect(
        PGNImport.Status(
            scoring: library.reviewing[reviewed.url],
            isReviewed: reviewed.pgn?.game.isReviewed == true,
            wrong: index.wrongByGame[reviewed.url] ?? 0
        ) == .ready(1),
        "the facts the status is made of are the review state and the book's count"
    )

    let pending = GameLibrary.Entry(
        url: URL(filePath: "/games/pending.pgn"),
        pgn: PGN(game: try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"])), tags: []),
        modified: now
    )
    #expect(
        PGNImport.Status(
            scoring: nil,
            isReviewed: pending.pgn?.game.isReviewed == true,
            wrong: 0
        ) == .awaitingReview
    )

    let clean = GameLibrary.Entry(url: URL(filePath: "/games/clean.pgn"), pgn: reviewedButClean(), modified: now)
    index.update(from: [reviewed, clean])
    #expect(PGNImport.Status(scoring: nil, isReviewed: true, wrong: 0) == .ready(0), "reviewed with nothing wrong is ready, at zero")
    #expect(PGNImport.Status(scoring: .init(judged: 1, total: 3), isReviewed: false, wrong: 0) == .scoring(.init(judged: 1, total: 3)))
}

/// A reviewed game in which nobody gave anything away.
private func reviewedButClean() -> PGN {
    var game = Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"])!
    game.applyReview([.centipawns(20), .centipawns(20)], startEvaluation: .centipawns(20), depth: 16)
    return PGN(game: game, tags: [])
}

/// Contract: the index's book and a book derived straight from the same games are the same book.
///
/// They were two loops for a while, and the one the app ran was the one no test asserted against.
/// Now both assemble through `MistakeBook.book`, and this says so in the only way that stays
/// true if somebody separates them again: by comparing the answers, dismissals and all.
@MainActor
@Test func theIndexAgreesWithADerivedBook() throws {
    let entries = try (1...6).map { try game(seed: $0, at: now, plies: 6) }
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }
    let index = MistakeIndex(log: log)
    index.update(from: entries)

    func positions(_ book: MistakeBook) -> [PositionKey] {
        book.mistakes.map(\.position).sorted { $0.text < $1.text }
    }
    func occasions(_ book: MistakeBook) -> [Int] {
        book.mistakes.sorted { $0.position.text < $1.position.text }.map(\.recurrence)
    }

    let derived = MistakeBook.derive(from: entries)
    #expect(!index.book.isEmpty)
    #expect(positions(index.book) == positions(derived))
    #expect(occasions(index.book) == occasions(derived))

    // And they agree about what has been struck off, which is the one fact the index holds that
    // a bare derivation has to be handed (docs/adr/0029).
    let struck = try #require(index.book.mistakes.first?.position)
    index.dismiss(struck)
    let afterwards = MistakeBook.derive(from: entries, dismissed: [struck])
    #expect(positions(index.book) == positions(afterwards))
    #expect(!positions(index.book).contains(struck))
}

/// Contract: the book follows the games. Freshness is the index's own — it used to be a view
/// modifier on one screen, so how current the book was depended on where the app had been.
@MainActor
@Test func theBookFollowsTheLibrary() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = GameLibrary(folder: GameFolder(url: directory))
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }
    let index = MistakeIndex(log: log)

    index.follow(library)
    #expect(index.book.isEmpty, "nothing is in the folder yet")

    let fixture = try game(seed: 7, at: now, plies: 4)
    #expect(library.write(try #require(fixture.pgn), to: directory.appending(path: "game.pgn")))
    // No screen, no `update` call: the write moved the library, and the book followed.
    for _ in 0..<40 where index.book.isEmpty {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(!index.book.isEmpty)

    index.unfollow()
    #expect(library.write(try #require(fixture.pgn), to: directory.appending(path: "again.pgn")))
    let held = index.book.mistakes.first?.recurrence
    for _ in 0..<10 {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(index.book.mistakes.first?.recurrence == held, "unfollowed, the book stands still")
}

// ------------------------------------------------------------------ 日课 from the index

@MainActor
private func hop() async {
    for _ in 0..<20 {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// The question after this one: today's next card, or the book's next 错题 round to the first,
/// and nothing when there is nothing else to ask.
@MainActor
@Test("the next question comes from the day or the book, and runs out")
func theNextQuestion() throws {
    let index = MistakeIndex(log: temporaryLog())
    index.update(from: try (1...3).map { try game(seed: $0, at: now) })
    let book = index.book.mistakes
    #expect(book.count == 3)
    #expect(index.next(after: book[0], source: .picked) == book[1])
    #expect(index.next(after: book[2], source: .picked) == book[0], "round to the first")

    let cards = index.daily.cards
    #expect(cards.count == 3)
    #expect(index.next(after: cards[0].mistake, source: .daily) == cards[1].mistake)
    #expect(index.next(after: cards[1].mistake, source: .daily) == cards[0].mistake,
            "the first card still standing that is not this one")

    let one = MistakeIndex(log: temporaryLog())
    one.update(from: [try game(seed: 1, at: now)])
    let only = try #require(one.book.mistakes.first)
    #expect(one.next(after: only, source: .picked) == nil, "a book of one")
    #expect(one.next(after: only, source: .daily) == nil, "the end of the queue")
}

/// The door says what is left today, that today is done, or that there is nothing yet.
@MainActor
@Test("the daily door says how much is left, that it is done, or that there is nothing yet")
func theDailyDoorSaysWhereTheDayIs() throws {
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }
    let index = MistakeIndex(log: log)
    #expect(index.dailyLabel == localized("daily.none"))

    index.update(from: try (1...3).map { try game(seed: $0, at: now) })
    #expect(index.dailyLabel == localized("daily.left", plural: 3))

    for card in index.daily.cards {
        log.append(.drilled(PracticeLog.Attempt(
            position: card.position, seconds: 5, passed: true, played: "?", cost: 0, hints: 0,
            source: .daily
        )))
    }
    index.refresh()
    #expect(index.daily.isEmpty)
    #expect(index.dailyLabel == localized("daily.done"))
}

/// A drill the index hands out writes to its log under its lines, and when it settles the day is
/// worked out again — the practised card leaves today's queue without anybody refreshing it.
@MainActor
@Test("an attempt settled from 日课 takes its card off today's queue")
func aSettledAttemptMovesTheDay() async throws {
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }
    let index = MistakeIndex(log: log)
    index.update(from: try (1...3).map { try game(seed: $0, at: now) })
    let card = try #require(index.daily.next)
    let engine = ScriptedEngine([
        Analysis(depth: Drill.depth, lines: [Line(score: .centipawns(0), uciMoves: [], san: [])])
    ])

    let drill = try #require(index.practise(card.mistake, engine: engine, source: .daily))
    #expect(drill.lines.noSlips, "under 把关, as every 练习 is")
    drill.play(try #require(drill.game.state.legalMoves.first))
    await drill.settled()
    #expect(drill.verdict?.passed == true)
    #expect(log.attempts().count == 1, "written into the index's own log")
    await hop()
    #expect(index.daily.remaining == 2)
    #expect(!index.daily.cards.contains { $0.position == card.position })
}

/// The book follows the player's lines the way it follows the games: moved above the one 错题's
/// cost, the book empties; moved back, it comes back.
@MainActor
@Test("the book follows the player's lines as it follows the games")
func theBookFollowsTheLines() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = GameLibrary(folder: GameFolder(url: folder))
    let pgn = try #require(try game(seed: 1, at: now).pgn)
    #expect(library.write(pgn, to: folder.appending(path: "seed-1.pgn")))
    let settings = PlayerSettings(store: InMemorySettings())
    let index = MistakeIndex(log: temporaryLog())
    defer { index.unfollow() }

    index.follow(library, settings: settings)
    #expect(index.book.mistakes.count == 1)
    settings.record = 40
    await hop()
    #expect(index.book.isEmpty, "31 points is under a 40-point 记录线")
    settings.record = 10
    await hop()
    #expect(index.book.mistakes.count == 1)
}
