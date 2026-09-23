@testable import ChessmirrorKit
import Foundation
import Testing
import ChessmirrorKitTesting

/// Contract: finding opportunities cannot displace an engine-controlled turn, including
/// the following engine turn after a human reply. Real Stockfish must commit both moves.
@MainActor
@Test func automaticFindingsDoNotDisplaceEngineMoves() async throws {
        try await Quietly.alone {
    let engine = try EngineService(bigNetURL: Nets.big, smallNetURL: Nets.small,
                                  configuration: .init(threads: 1, hashMegabytes: 32, multiPV: 1))
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let session = GameSession.fresh(game, controllers: [.white: .engine, .black: .hand], engine: engine)
    defer { session.suspend() }
    session.retune()
    #expect(session.thinking == .own)
    session.setFindingTactics(true)
    #expect(session.isFindingTactics)
    #expect(session.thinking == .own, "enabling discovery must leave the current move running")
    var deadline = ContinuousClock.now + .seconds(5)
    while session.game.plies.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
    try #require(session.game.plies.count == 1, "the engine must actually commit its move")
    let reply = try #require(session.viewed.state.legalMoves.first)
    session.play(reply)
    #expect(session.game.plies.count == 2)
    // The reply is weighed before it stands — every move is — and with 把关 off it stands.
    await session.settled()
    #expect(session.game.plies.count == 2)
    #expect(session.thinking == .own, "an already-enabled finder must not precede the next engine turn")
    deadline = ContinuousClock.now + .seconds(5)
    while session.game.plies.count == 2, ContinuousClock.now < deadline { await Task.yield() }
    #expect(session.game.plies.count == 3)

        }}

/// Contract: explicit import ownership survives disk, session save, and duplicate import;
/// each side's real reviewed loss enters only that side's personal book.
@MainActor
@Test func importedOwnershipSurvivesSavingAndBookRebuild() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = GameLibrary(folder: GameFolder(url: folder))
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
    game.applyReview([.centipawns(-500), .centipawns(500)],
                     startEvaluation: .centipawns(0), depth: 16)
    let pgn = PGN(game: game, tags: [.init("White", "Original White"), .init("Black", "Original Black")])
    let chapter = PGNImport.ImportChapter(id: 1, name: "Ownership", pgn: pgn)
    let importer = ImportSession()
    #expect(library.entries.isEmpty)
    let entry = try #require(importer.open(chapter, into: library, tracking: .white))
    #expect(library.entries.count == 1)
    let reopened = try PGN(parsing: String(contentsOf: entry.url, encoding: .utf8))
    #expect(reopened.handColours == [.white])
    let session = try #require(GameSession.opened(entry, engine: nil, library: library).session)
    defer { session.suspend() }
    #expect(session.pgn.tag("White") == "Original White")
    #expect(session.pgn.tag("Black") == "Original Black")
    #expect(library.write(session.pgn, to: entry.url))
    let whiteBook = MistakeBook.derive(from: library.entries)
    #expect(whiteBook.mistakes.count == 1)
    #expect(whiteBook.mistakes.first?.position.sideToMove == .white)
    let changed = try #require(importer.open(chapter, into: library, tracking: .black))
    #expect(changed.url == entry.url)
    #expect(library.entries.count == 1)
    let blackDisk = try PGN(parsing: String(contentsOf: changed.url, encoding: .utf8))
    #expect(blackDisk.handColours == [.black])
    let blackBook = MistakeBook.derive(from: library.entries)
    #expect(blackBook.mistakes != whiteBook.mistakes)
    #expect(blackBook.mistakes.count == 1)
    #expect(blackBook.mistakes.first?.position.sideToMove == .black)
}

/// Contract: a queued import cannot stop foreground analysis; cancellation removes its queued
/// work, and a subsequent background request completes after foreground analysis is cancelled.
@Test func backgroundImportWaitsForForegroundAndCanBeCancelled() async throws {
        try await Quietly.alone {
    let engine = try EngineService(
        bigNetURL: Nets.big, smallNetURL: Nets.small,
        configuration: .init(threads: 1, hashMegabytes: 32, multiPV: 1)
    )
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let updates = AsyncStream<Analysis>.makeStream()
    let foreground = Task {
        defer { updates.continuation.finish() }
        for await snapshot in engine.analyse(game, budget: .untilStopped, lines: 1) {
            updates.continuation.yield(snapshot)
        }
    }
    defer { foreground.cancel() }
    var iterator = updates.stream.makeAsyncIterator()
    _ = try #require(await iterator.next(), "foreground search never started")
    let cancelled = Task { await engine.analyseInBackground(game, depth: 16) }
    defer { cancelled.cancel() }
    let deadline = ContinuousClock.now + .seconds(5)
    while await engine.queuedBackgroundSearchCount() == 0, ContinuousClock.now < deadline {
        await Task.yield()
    }
    try #require(await engine.queuedBackgroundSearchCount() == 1,
                 "background search must wait without superseding the foreground")
    cancelled.cancel()
    #expect(await cancelled.value == nil)
    #expect(await engine.queuedBackgroundSearchCount() == 0)

    let waiting = Task { await engine.analyseInBackground(game, depth: 16) }
    defer { waiting.cancel() }
    foreground.cancel()
    await foreground.value
    let result = try #require(await waiting.value)
    #expect(result.depth == 16)
    #expect(!result.isPartial)

        }}

/// Contract: deliberately misleading foreign scores change search order, not coverage; the
/// real local engine still finds the same mistake positions as the unannotated game.
@Test func realImportedScoresCannotHideLocalMistakes() async throws {
        try await Quietly.alone {
    let engine = try EngineService(
        bigNetURL: Nets.big, smallNetURL: Nets.small,
        configuration: .init(threads: 1, hashMegabytes: 32, multiPV: 1)
    )
    var plain = try PGN(parsing: "1. f3 e5 2. g4 Qh4# 0-1")
    var imported = try PGN(parsing:
        "1. f3 {[%eval 0]} e5 {[%eval 0]} 2. g4 {[%eval 0]} Qh4# {[%eval 10]} 0-1")
    // Scoring parity is independent of selecting the player's side on import.
    plain.setTag("White", to: Controller.hand.playerName)
    imported.setTag("White", to: Controller.hand.playerName)
    #expect(ImportReview.plan(for: imported.game).positions == [0, 1, 3, 4, 2])
    let full = try await ImportReview.judge(plain, using: engine)
    await engine.clear()
    let prioritized = try await ImportReview.judge(imported, using: engine)
    func mistakes(_ pgn: PGN) -> Set<PositionKey> {
        Set(MistakeBook.derive(from: [GameLibrary.Entry(
            url: URL(filePath: "/games/parity.pgn"), pgn: pgn, modified: Date()
        )]).mistakes.map(\.position))
    }
    #expect(!mistakes(full).isEmpty)
    #expect(mistakes(prioritized) == mistakes(full))
    #expect(try #require(prioritized.game.drop(atPly: 3)) >= 20)
    #expect(prioritized.game.plies.allSatisfy { $0.evaluation != nil })

        }}

/// A complete, nontrivial local pass used to report issue #35's measured elapsed time.
@Test func measureRealImportReview() async throws {
        try await Quietly.alone {
    let pgn = try PGN(parsing: """
        1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 5. Qxf3 dxe5
        6. Bc4 Nf6 7. Qb3 Qe7 8. Nc3 c6 9. Bg5 b5 10. Nxb5 cxb5
        11. Bxb5+ Nbd7 12. O-O-O Rd8 13. Rxd7 Rxd7 14. Rd1 Qe6
        15. Bxd7+ Nxd7 16. Qb8+ Nxb8 17. Rd8# 1-0
        """)
    let engine = try EngineService(
        bigNetURL: Nets.big, smallNetURL: Nets.small,
        configuration: .init(threads: 2, hashMegabytes: 32, multiPV: 1)
    )
    let started = ContinuousClock.now
    let reviewed = try await ImportReview.judge(pgn, using: engine)
    let elapsed = started.duration(to: .now)
    #expect(reviewed.game.plies.count == 33)
    #expect(reviewed.game.reviewDepth == 16)
    #expect(reviewed.game.plies.allSatisfy { $0.evaluation != nil })
    print("IMPORT REVIEW: 33 plies, depth 16, 2 threads, 32 MiB hash: \(elapsed)")

        }}

@MainActor
@Test(arguments: [false, true])
func selectingOneImportWritesOnlyThatGameAndTheReviewWaitsToBeAsked(engineArrivesLate: Bool) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = GameLibrary(folder: GameFolder(url: folder))
    let book = MistakeIndex(log: PracticeLog(url: folder.appending(path: "practice.jsonl")))
    let importer = ImportSession()
    let chapter = PGNImport.ImportChapter(id: 2, name: "Selected game",
                                         pgn: try PGN(parsing: "1. e4 e5 *"))
    #expect(importer.status(of: chapter, in: library, wrongByGame: book.wrongByGame) == .notImported)
    let entry = try #require(importer.open(chapter, into: library))
    #expect(library.entries.count == 1)
    #expect(library.reviewingURLs.isEmpty)
    #expect(entry.pgn?.game.isReviewed == false)
    #expect(importer.status(of: chapter, in: library, wrongByGame: book.wrongByGame) == .awaitingReview)
    let engine = ScriptedEngine([Analysis(depth: 16, lines: [
        Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
    ])])
    let session = try #require(GameSession.opened(
        entry, engine: engineArrivesLate ? nil : engine, library: library
    ).session)
    defer { session.suspend() }
    // Opening the game starts nothing: the Review is offered, and the player asks for it.
    #expect(session.awaitsReview)
    #expect(library.reviewingURLs.isEmpty)
    #expect(session.reviewProgress == nil)
    #expect(session.reviewRow == .offered(failed: false, canStart: !engineArrivesLate))
    if engineArrivesLate {
        #expect(!session.canReview, "no engine yet, so the offer cannot be taken up")
        session.review()
        #expect(library.reviewingURLs.isEmpty, "asking without an engine starts nothing")
        session.attach(engine: engine, library: library)
    }
    #expect(session.canReview)
    session.review()
    #expect(session.isReviewing)
    #expect(!session.canReview, "a Review already running cannot be asked for again")
    guard case .running = session.reviewRow else {
        Issue.record("expected the row to be counting, got \(String(describing: session.reviewRow))")
        return
    }
    // Asking again, or reappearing, while it runs must not queue another copy.
    session.review()
    session.attach(engine: engine, library: library)
    #expect(library.reviewingURLs.contains(entry.url))
    guard case .scoring = importer.status(of: chapter, in: library, wrongByGame: book.wrongByGame) else {
        Issue.record("expected the chapter to be scoring, got \(importer.status(of: chapter, in: library, wrongByGame: book.wrongByGame))")
        return
    }
    await library.waitForImportReviews()
    #expect(library.reviewingURLs.isEmpty)
    #expect(session.reviewProgress == nil)
    #expect(session.reviewNews == .done(slips: 0))
    #expect(session.reviewRow == .done(slips: 0))
    #expect(!session.awaitsReview)
    #expect(session.game.reviewDepth == 16)
    // The review's own searches, apart from the live position searches the opened game starts.
    #expect(engine.budgets.filter { $0 != PositionSearches.budget }.count == 3)
    let disk = try PGN(parsing: String(contentsOf: entry.url, encoding: .utf8))
    #expect(disk.game.reviewDepth == 16)
    #expect(disk.tag("ReviewSift") == "full-local")
    #expect(importer.status(of: chapter, in: library, wrongByGame: book.wrongByGame) == .ready(0))
    let again = try #require(importer.open(chapter, into: library))
    #expect(again.url == entry.url)
    #expect(library.entries.count == 1)
}

@MainActor
@Test func aReviewReportsHowFarItHasGotAndSaysWhenItCouldNotFinish() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = GameLibrary(folder: GameFolder(url: folder))
    let importer = ImportSession()
    let chapter = PGNImport.ImportChapter(id: 3, name: "Three moves",
                                         pgn: try PGN(parsing: "1. e4 e5 2. Nf3 *"))
    let entry = try #require(importer.open(chapter, into: library))

    // Every position settles: the progress climbs to the plan's four positions.
    var seen: [ImportReview.Progress] = []
    let judged = try await ImportReview.judge(
        try #require(entry.pgn),
        using: ScriptedEngine([Analysis(depth: 16, lines: [
            Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
        ])])
    ) { seen.append($0) }
    #expect(judged.game.isReviewed)
    #expect(seen.map(\.judged) == [0, 1, 2, 3, 4])
    #expect(seen.allSatisfy { $0.total == 4 })
    #expect(seen.last?.fraction == 1)

    // An engine that never reaches the depth settles nothing: the session is told, nothing is
    // written, and the offer stands so it can be asked again.
    let shallow = ScriptedEngine([Analysis(depth: 8, lines: [
        Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
    ])])
    let session = try #require(GameSession.opened(entry, engine: shallow, library: library).session)
    defer { session.suspend() }
    session.review()
    #expect(session.isReviewing)
    await library.waitForImportReviews()
    #expect(session.reviewNews == .failed)
    #expect(session.awaitsReview)
    #expect(session.canReview, "nothing running, so it can be asked again")
    #expect(session.reviewRow == .offered(failed: true, canStart: true))
    let disk = try PGN(parsing: String(contentsOf: entry.url, encoding: .utf8))
    #expect(!disk.game.isReviewed, "no partial Review is ever written")
    #expect(disk.game.plies.allSatisfy { $0.line.isEmpty }, "an unfinished Review writes no line either")
}

@Test func importScoresPrioritizeButNeverExcludeLocalJudgements() async throws {
    let pgn = try PGN(parsing: "1. e4 {[%eval 0]} e5 {[%eval 0]} 2. Nf3 {[%eval -2]} Nc6 {[%eval -2]} *")
    let plan = ImportReview.plan(for: pgn.game)
    #expect(plan.usesImportedScores)
    #expect(plan.plies == [1, 3, 2, 4])
    #expect(plan.positions == [0, 1, 2, 3, 4])
    let engine = ScriptedEngine([Analysis(depth: 16, lines: [
        Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
    ])])
    let judged = try await ImportReview.judge(pgn, using: engine)
    #expect(engine.searchCount == 5)
    #expect(judged.game.drop(atPly: 3) == 0, "the imported loss must never become a local verdict")
    #expect(judged.game.reviewDepth == 16)
    let reopened = try PGN(parsing: judged.text)
    #expect(reopened.tag("ReviewSift") == "imported-eval-7-priority")
    #expect(reopened.game.drop(atPly: 3) == 0)
    #expect(reopened.game.plies.allSatisfy { $0.line == ["e4"] }, "sift changes order, not what a search keeps")
}

@Test func importsWithoutCompleteScoresUseAFullLocalPass() async throws {
    let pgn = try PGN(parsing: "1. e4 e5 2. Nf3 *")
    #expect(ImportReview.plan(for: pgn.game).positions == [0, 1, 2, 3])
    let engine = ScriptedEngine([Analysis(depth: 16, lines: [
        Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
    ])])
    let judged = try await ImportReview.judge(pgn, using: engine)
    #expect(engine.searchCount == 4)
    #expect(judged.tag("ReviewSift") == "full-local")
    #expect(judged.game.plies.allSatisfy { $0.evaluation != nil })
}

/// The review the library and the session start, with a continuation on every search that had one.
@MainActor
@Test func theReviewTheLibraryStartsKeepsTheLineItSearched() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = GameLibrary(folder: GameFolder(url: folder))
    let played = try #require(Game(
        startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "d1h5"]
    ))
    let positions = (0...played.plies.count).map { played.rewound(to: $0)!.state.fen }
    func opinion(_ centipawns: Int, san: [String], uci: [String]) -> Analysis {
        Analysis(depth: ImportReview.depth, lines: [
            Line(score: .centipawns(centipawns), uciMoves: uci, san: san),
        ])
    }
    let engine = ScriptedEngine([], byPosition: [
        positions[0]: opinion(20, san: ["e4", "e5"], uci: ["e2e4", "e7e5"]),
        positions[1]: opinion(30, san: ["e5", "Qh5"], uci: ["e7e5", "d1h5"]),
        positions[2]: opinion(25, san: ["Nf3", "Nc6"], uci: ["g1f3", "b8c6"]),
        positions[3]: opinion(-400, san: ["Nc6", "Bc4"], uci: ["b8c6", "f1c4"]),
    ])
    let chapter = PGNImport.ImportChapter(id: 9, name: "Kept lines", pgn: PGN(game: played))
    let entry = try #require(ImportSession().open(chapter, into: library, tracking: .white))
    let session = try #require(GameSession.opened(entry, engine: engine, library: library).session)
    defer { session.suspend() }
    session.review()
    await library.waitForImportReviews()

    let disk = try PGN(parsing: String(contentsOf: entry.url, encoding: .utf8))
    #expect(disk.tag("ReviewSift") == "full-local")
    #expect(disk.game.reviewDepth == ImportReview.depth)
    #expect(disk.game.plies[0].line == ["e5", "Qh5"])
    #expect(disk.game.plies[1].line == ["Nf3", "Nc6"])
    #expect(disk.game.plies[2].line == ["Nc6", "Bc4"])
    #expect(disk.game.isBest(atPly: 2), "e5 is what the line after e4 named")
    #expect(!disk.game.isBest(atPly: 3), "Qh5 where that line named Nf3")
    #expect(!disk.game.isBest(atPly: 1), "nothing before the first move names it")

    session.jump(toPly: 2)
    let stood = try #require(session.reading.wrongs.first { $0.stood && $0.san == "Qh5" })
    let asked = engine.positions.filter { $0 == positions[3] }.count
    let reply = await session.reply(for: stood)
    #expect(reply == ["Nc6", "Bc4"])
    #expect(engine.positions.filter { $0 == positions[3] }.count == asked, "the stored line is not searched again")
}

@Test func aSettledPositionKeepsNoLineAndIsNotSearched() async throws {
    let pgn = try PGN(parsing: "1. f3 e5 2. g4 Qh4# 0-1")
    let engine = ScriptedEngine([Analysis(depth: ImportReview.depth, lines: [
        Line(score: .centipawns(10), uciMoves: ["a2a3"], san: ["a3"]),
    ])])
    let judged = try await ImportReview.judge(pgn, using: engine)
    #expect(engine.searchCount == 4, "the mated position is settled without a search")
    #expect(judged.game.plies[3].evaluation == .mate(in: -1))
    #expect(judged.game.plies[3].line.isEmpty)
    #expect(judged.game.plies.dropLast().allSatisfy { $0.line == ["a3"] })
}

@Test func aSearchWithNoContinuationKeepsAnEmptyLine() async throws {
    let pgn = try PGN(parsing: "1. e4 *")
    let engine = ScriptedEngine([Analysis(depth: ImportReview.depth, lines: [
        Line(score: .centipawns(20), uciMoves: ["e2e4"], san: []),
    ])])
    let judged = try await ImportReview.judge(pgn, using: engine)
    #expect(judged.game.isReviewed)
    #expect(judged.game.plies[0].evaluation == .centipawns(20))
    #expect(judged.game.plies[0].line.isEmpty)
}
