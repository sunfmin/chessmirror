@testable import ChessfenKit
import Foundation
import Testing

/// Contract: finding opportunities cannot displace an engine-controlled turn, including
/// the following engine turn after a human reply. Real Stockfish must commit both moves.
@MainActor
@Test func automaticFindingsDoNotDisplaceEngineMoves() async throws {
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
    #expect(session.thinking == .own, "an already-enabled finder must not precede the next engine turn")
    deadline = ContinuousClock.now + .seconds(5)
    while session.game.plies.count == 2, ContinuousClock.now < deadline { await Task.yield() }
    #expect(session.game.plies.count == 3)
}

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
    let session = try #require(GameSession.opened(entry, engine: nil, library: library))
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
}

/// Contract: deliberately misleading foreign scores change search order, not coverage; the
/// real local engine still finds the same mistake positions as the unannotated game.
@Test func realImportedScoresCannotHideLocalMistakes() async throws {
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
}

/// A complete, nontrivial local pass used to report issue #35's measured elapsed time.
@Test func measureRealImportReview() async throws {
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
}

@MainActor
@Test(arguments: [false, true])
func selectingOneImportWritesOnlyThatGameAndOpeningStartsReview(engineArrivesLate: Bool) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = GameLibrary(folder: GameFolder(url: folder))
    let book = MistakeIndex(log: PracticeLog(url: folder.appending(path: "practice.jsonl")))
    let importer = ImportSession()
    let chapter = PGNImport.ImportChapter(id: 2, name: "Selected game",
                                         pgn: try PGN(parsing: "1. e4 e5 *"))
    #expect(importer.status(of: chapter, in: library, book: book) == .notImported)
    let entry = try #require(importer.open(chapter, into: library))
    #expect(library.entries.count == 1)
    #expect(library.reviewingURLs.isEmpty)
    #expect(entry.pgn?.game.isReviewed == false)
    #expect(importer.status(of: chapter, in: library, book: book) == .awaitingReview)
    let engine = ScriptedEngine([Analysis(depth: 16, lines: [
        Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
    ])])
    let session = try #require(GameSession.opened(
        entry, engine: engineArrivesLate ? nil : engine, library: library
    ))
    defer { session.suspend() }
    if engineArrivesLate {
        #expect(library.reviewingURLs.isEmpty)
        #expect(session.game.reviewDepth == nil)
        session.attach(engine: engine, library: library)
    }
    // Reappearing while a review is running must not queue another copy.
    session.attach(engine: engine, library: library)
    #expect(library.reviewingURLs.contains(entry.url))
    #expect(importer.status(of: chapter, in: library, book: book) == .scoring)
    await library.waitForImportReviews()
    #expect(library.reviewingURLs.isEmpty)
    #expect(session.game.reviewDepth == 16)
    #expect(engine.searchCount == 3)
    let disk = try PGN(parsing: String(contentsOf: entry.url, encoding: .utf8))
    #expect(disk.game.reviewDepth == 16)
    #expect(disk.tag("ReviewSift") == "full-local")
    #expect(importer.status(of: chapter, in: library, book: book) == .ready(0))
    let again = try #require(importer.open(chapter, into: library))
    #expect(again.url == entry.url)
    #expect(library.entries.count == 1)
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
