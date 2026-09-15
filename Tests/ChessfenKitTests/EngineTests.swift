import ChessfenKit
import Foundation
import Synchronization
import Testing

/// The weights, found by path rather than copied into the test bundle: they are 112 MiB,
/// and duplicating them into every build product to run the tests is a poor trade.
enum Nets {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ChessfenKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // ios
        .appendingPathComponent("Resources/Nets")

    static let big = directory.appendingPathComponent("nn-c288c895ea92.nnue")
    static let small = directory.appendingPathComponent("nn-37f18f62d772.nnue")

    static var arePresent: Bool {
        FileManager.default.fileExists(atPath: big.path)
            && FileManager.default.fileExists(atPath: small.path)
    }
}

/// One engine for the whole suite, because building a thread pool and a table per test
/// would dominate the run — and because there is only ever one in the app either. One
/// engine means one search, so these tests run in order rather than at once; a second
/// analysis would legitimately supersede the first and truncate its stream.
private let shared: EngineService? = {
    guard Nets.arePresent else { return nil }
    return try? EngineService(
        bigNetURL: Nets.big,
        smallNetURL: Nets.small,
        configuration: .init(threads: 2, hashMegabytes: 64, multiPV: 3)
    )
}()

/// Serialized because the tests share one engine, and one engine is one search: a second
/// analysis legitimately supersedes the first and truncates its stream, so running these
/// at once would have them stealing each other's answers.
@Suite("Stockfish engine", .serialized)
struct EngineTests {
    private func engine() throws -> EngineService {
    try #require(shared, "the NNUE weights are missing — see ios/README.md")
}

    @Test("the engine starts once its weights are where it was told")
    func engineStarts() async throws {
        let service = try engine()
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        // Construction sets the options; a first search proves the whole path — create,
        // options, search, report.
        #expect(await service.evaluate(game, budget: .depth(2)) != nil)
    }

    @Test("a missing net is refused rather than taking the process with it")
    func aMissingNetIsRefused() {
        // Stockfish answers a failed net load with exit(EXIT_FAILURE), which in an app means
        // the process simply vanishes. The bridge checks the files first; this is that check.
        let absent = Nets.directory.appendingPathComponent("nn-000000000000.nnue")
        #expect(throws: EngineService.StartupFailure.networkMissing) {
            _ = try EngineService(bigNetURL: absent, smallNetURL: absent)
        }
    }

    @Test("a file too small to be a net is refused too")
    func aTruncatedNetIsRefused() throws {
        let stub = FileManager.default.temporaryDirectory
            .appendingPathComponent("chessfen-truncated.nnue")
        try Data(repeating: 0, count: 1024).write(to: stub)
        defer { try? FileManager.default.removeItem(at: stub) }

        #expect(throws: EngineService.StartupFailure.networkTooSmall) {
            _ = try EngineService(bigNetURL: stub, smallNetURL: stub)
        }
    }

    @Test("an analysis deepens, and every line it reports is playable")
    func analysisDeepens() async throws {
        let service = try engine()
        let game = try #require(Game(startFEN: PGN.standardStartFEN))

        var snapshots: [Analysis] = []
        for await analysis in service.analyse(game, budget: .depth(10)) {
            snapshots.append(analysis)
        }

        #expect(snapshots.count > 1, "one snapshot per Depth was expected, got \(snapshots.count)")
        #expect(snapshots.map(\.depth) == snapshots.map(\.depth).sorted())
        #expect(snapshots.last?.depth == 10)

        let final = try #require(snapshots.last)
        #expect(final.lines.count == 3, "MultiPV was 3, got \(final.lines.count)")
        #expect(final.nodes > 0)
        for line in final.lines {
            let move = try #require(line.bestMove)
            #expect(game.state.move(matching: move) != nil, "\(move) is not legal here")
            #expect(!line.san.isEmpty)
        }
        // The opening is roughly level, and no reasonable search says otherwise.
        if case .centipawns(let value) = final.best?.score {
            #expect(abs(value) < 100, "the start position scored \(value)")
        } else {
            Issue.record("the start position should not be a mate score")
        }
    }

    @Test("a mate is found and named as a mate")
    func mateIsFound() async throws {
        let service = try engine()
        // Back-rank mate in one: Ra8#.
        let game = try #require(Game(startFEN: "6k1/5ppp/8/8/8/8/8/R3K2R w - - 0 1"))

        var last: Analysis?
        for await analysis in service.analyse(game, budget: .depth(8)) { last = analysis }
        let best = try #require(last?.best)
        #expect(best.score == .mate(in: 1))
        #expect(best.san.first == "Ra8#")
    }

    @Test("scores are White-relative whichever side is to move")
    func scoresAreWhiteRelative() async throws {
        let service = try engine()
        // White is a queen up. The sign must not depend on whose turn it is.
        let whiteToMove = try #require(Game(startFEN: "4k3/8/8/8/8/8/8/3QK3 w - - 0 1"))
        let blackToMove = try #require(Game(startFEN: "4k3/8/8/8/8/8/8/3QK3 b - - 0 1"))

        var white: Analysis?
        for await analysis in service.analyse(whiteToMove, budget: .depth(8)) { white = analysis }
        var black: Analysis?
        for await analysis in service.analyse(blackToMove, budget: .depth(8)) { black = analysis }

        for (label, analysis) in [("white to move", white), ("black to move", black)] {
            let score = try #require(analysis?.best?.score)
            switch score {
            case .centipawns(let value):
                #expect(value > 200, "\(label) scored \(value); White is a queen up")
            case .mate(let moves):
                #expect(moves > 0, "\(label) scored #\(moves); White is the one mating")
            }
        }
    }

    @Test("a time budget produces a legal move and honours the clock")
    func aTimeBudgetHonoursTheClock() async throws {
        let service = try engine()
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))

        let started = ContinuousClock.now
        var last: Analysis?
        for await analysis in service.analyse(game, budget: .time(.milliseconds(400))) {
            last = analysis
        }
        let elapsed = ContinuousClock.now - started

        let uci = try #require(last?.bestMove)
        #expect(game.state.move(matching: uci) != nil)
        #expect(elapsed < .seconds(4), "took \(elapsed) for a 400 ms budget")
    }

    @Test("an unbounded analysis stops when it is asked to")
    func unboundedAnalysisStops() async throws {
        let service = try engine()
        let game = try #require(Game(startFEN: PGN.standardStartFEN))

        var seen = 0
        for await _ in service.analyse(game, budget: .untilStopped) {
            seen += 1
            // Ending the loop terminates the stream, which stops the engine — the same path a
            // screen being dismissed takes.
            if seen >= 3 { break }
        }
        #expect(seen == 3)

        // And the engine is usable straight afterwards, rather than wedged.
        var after = 0
        for await _ in service.analyse(game, budget: .depth(4)) { after += 1 }
        #expect(after > 0)
    }

    @Test("a review scores every ply at one uniform depth")
    func reviewScoresEveryPly() async throws {
        let service = try engine()
        let game = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6"])
        )

        await service.clear()
        let reviewed = await service.review(game, depth: 6)
        #expect(reviewed.count == game.plies.count)
        #expect(reviewed.allSatisfy { $0.score != nil })

        // Four sensible opening moves; nobody is winning yet, and nobody is mated.
        for score in reviewed.compactMap({ $0.score }) {
            guard case .centipawns(let value) = score else {
                Issue.record("an opening ply should not score as a mate")
                continue
            }
            #expect(abs(value) < 150, "an opening ply scored \(value)")
        }

        // And the Line the search produced comes back with it, which is the whole point of
        // asking a Review for one: nothing else in the app can afford to (docs/adr/0021).
        #expect(reviewed.allSatisfy { !$0.line.isEmpty }, "a Review that kept no lines")
        #expect(
            reviewed.allSatisfy { $0.line.count <= Game.Ply.lineLimit },
            "a line longer than the cap would be written to every file for ever"
        )
        // SAN, not UCI: what goes in the file is what a person can read.
        #expect(reviewed.allSatisfy { $0.line.allSatisfy { !$0.isEmpty && $0.first!.isLetter || $0.first! == "O" } })
    }

    @Test("a review of a game with no moves is empty rather than nil-padded")
    func reviewOfAnEmptyGameIsEmpty() async throws {
        let service = try engine()
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        #expect(await service.review(game, depth: 4).isEmpty)
    }

    // ------------------------------------------------- the app coming and going
    //
    // What remains here is the half of the pause gate that no pure value can answer: what
    // pause and resume actually do to a live search. What a paused engine *decides* moved
    // to the seams — `SearchGate` answers budgets, and the depth grouper turns frames into
    // Analysis — where a test cannot hang, because there is no search to wait on.
    //
    // Every test here resumes in a `defer`: the suite shares one engine, so an engine left
    // paused by a failing test would hang every test after it rather than fail its own.

    /// Runs `work` and gives up after `limit`, `nil` meaning it did not finish in time.
    ///
    /// The test below turns on an unbounded search *ending*, and the way it regresses is that it
    /// does not: the stream never finishes and the test hangs. A hung suite is a much worse
    /// report than a failed expectation, so the deadline is what turns one into the other.
    private func within<T: Sendable>(
        _ limit: Duration, _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            // Cancelling the loser terminates its stream, which stops the engine — so a search
            // that outran the deadline does not carry on into the next test.
            group.cancelAll()
            return first
        }
    }

    @Test("pausing stops the search already running")
    func pausingStopsTheRunningSearch() async throws {
        let service = try engine()
        defer { service.resume() }
        let game = try #require(Game(startFEN: PGN.standardStartFEN))

        // The loop never breaks out. The app going away is the only thing that can end this
        // stream, so this passes only if the pause is what ended it.
        let seen = try #require(
            await within(.seconds(5)) {
                var count = 0
                for await _ in service.analyse(game, budget: .untilStopped) {
                    count += 1
                    if count == 2 { service.pause() }
                }
                return count
            },
            "pausing did not stop the search that was running"
        )
        #expect(seen >= 2)
    }

    @Test("a bounded search waits for the app rather than coming back empty")
    func aBoundedSearchHoldsWhilePaused() async throws {
        let service = try engine()
        defer { service.resume() }
        let game = try #require(Game(startFEN: PGN.standardStartFEN))

        let answered = Atomic<Bool>(false)
        service.pause()
        let search = Task {
            let score = await service.evaluate(game, budget: .depth(6))
            answered.store(true, ordering: .releasing)
            return score
        }

        // Depth 6 from the start position takes a few milliseconds, so this is long enough for
        // an engine that ignored the gate to have finished and given itself away.
        try await Task.sleep(for: .milliseconds(400))
        // Read out before asserting: `Atomic` is non-copyable, and `#expect` needs to be handed
        // something it can capture.
        let answeredWhilePaused = answered.load(ordering: .acquiring)
        #expect(!answeredWhilePaused, "a paused engine answered a bounded search")

        service.resume()
        #expect(await search.value != nil, "a held search should run on the way back, not fail")
    }
}
