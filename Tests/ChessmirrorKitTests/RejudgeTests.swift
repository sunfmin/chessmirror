@testable import ChessmirrorKit
import Foundation
import Testing
import ChessmirrorKitTesting

/// Contract: a 复判 judges one 试招 again, deeper — both ends to depth 28 through the shared store
/// — and rewrites that one move's 掉幅, 应招 and depth in place, saving the game. The refusal
/// stays, the stood move keeps its judgement, and a move played or the eye moving on cancels it
/// unwritten (CONTEXT.md, 复判; docs/adr/0041).
@Suite("复判")
@MainActor
struct RejudgeTests {
    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    }

    /// f3 e5, with g4 refused and pending at the position on the board.
    private func pendingG4(depth: Int? = 20) throws -> Game {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3", "e7e5"]))
        game.recordTried(.init(san: "g4", drop: 40, depth: depth, line: ["Qh4"]), atPly: 2)
        return game
    }

    private nonisolated static let beforeFEN = "rnbqkbnr/pppp1ppp/8/4p3/8/5P2/PPPPP1PP/RNBQKBNR w KQkq - 0 2"
    private nonisolated static let afterG4FEN = "rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq - 0 2"

    /// An engine that answers the deeper budget only, one finished stream per end.
    private func deeperEngine(beforeDepth: Int, afterDepth: Int) -> ScriptedEngine {
        let before = Analysis(depth: beforeDepth, lines: [Line(score: .centipawns(20), uciMoves: ["d2d4"], san: ["d4"])])
        let after = Analysis(depth: afterDepth, lines: [Line(score: .mate(in: -1), uciMoves: ["d8h4"], san: ["Qh4"])])
        let afterG4 = Self.afterG4FEN
        return ScriptedEngine([], controlled: { game, budget in
            guard budget == PositionSearches.deeper else { return nil }
            let answer = game.state.fen == afterG4 ? after : before
            return AsyncStream { $0.yield(answer); $0.finish() }
        })
    }

    private var expectedDrop: Double {
        MoveQuality.drop(move: .white, before: .centipawns(20), after: .mate(in: -1)) ?? -1
    }

    @Test func aPendingTriedMoveIsRewrittenInPlaceAndTheGameSaved() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = GameLibrary(folder: GameFolder(url: folder))
        let engine = deeperEngine(beforeDepth: 28, afterDepth: 26)
        let session = GameSession.fresh(try pendingG4(), engine: engine, library: library)
        defer { session.suspend() }
        session.jumpToLatest()
        #expect(session.rejudgeOffer(at: 0) == .ready)
        #expect(session.rejudgeOffer(at: 1) == .none, "no such move")

        session.rejudge(at: 0)
        #expect(session.rejudging?.tried.san == "g4")
        #expect(session.rejudgeOffer(at: 0) == .waiting, "one at a time")
        await until { session.rejudging == nil }

        let rewritten = session.game.pendingTries(atPly: 2)
        #expect(rewritten == [.init(san: "g4", drop: expectedDrop, depth: 26, line: ["Qh4"])],
                "the shallower of the two ends is the depth the number is worth")
        #expect(session.game.uciMoves == ["f2f3", "e7e5"], "the refusal stands: nothing was played")
        // The store answers a position nobody has looked at everyday-first, then deeper; the
        // deeper ask is one per end, and the ends are the two positions of the move.
        #expect(engine.budgets.filter { $0 == PositionSearches.deeper }.count == 2)
        #expect(Array(NSOrderedSet(array: engine.positions)) as? [String] == [Self.beforeFEN, Self.afterG4FEN])
        let url = try #require(session.url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("[%pending 2 g4 -"), "saved: \(text)")
        #expect(text.contains("% 26 | Qh4]"), "with the depth after the cost")
        #expect(session.rejudgeOffer(at: 0) == .ready, "short of 28, it can be asked again")
    }

    @Test func aTriedMoveOnAStoodMoveIsRewrittenAndTheStoodMoveKeepsItsJudgement() async throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3", "e7e5", "b1c3"]))
        let judgement = Game.Ply.Judgement(drop: 2, score: .centipawns(10), depth: 20, intercept: 5)
        game.setJudgement(judgement, atPly: 2)
        game.setTried([.init(san: "g4", drop: 40, depth: 20, line: ["Qh4"])], hints: 1, atPly: 2)
        let engine = deeperEngine(beforeDepth: 28, afterDepth: 28)
        let session = GameSession.fresh(game, engine: engine)
        defer { session.suspend() }
        session.jumpToLatest()
        #expect(session.visibleAttempts.map(\.san) == ["g4"])

        session.rejudge(at: 0)
        await until { session.rejudging == nil }
        #expect(session.game.plies[2].tried == [.init(san: "g4", drop: expectedDrop, depth: 28, line: ["Qh4"])])
        #expect(session.game.plies[2].hints == 1, "the ladder count rides along")
        #expect(session.game.plies[2].judgement == judgement, "the move that stood is not re-judged")
        #expect(session.rejudgeOffer(at: 0) == .none, "at 28 there is nothing more to offer")
    }

    @Test func anOpenReadingIsBroughtUpToDateWhenTheNumberLands() async throws {
        let engine = deeperEngine(beforeDepth: 28, afterDepth: 28)
        let session = GameSession.fresh(try pendingG4(), engine: engine)
        defer { session.suspend() }
        session.jumpToLatest()
        session.readReply(at: 0)
        #expect(session.replyReading?.move.depth == 20)

        session.rejudge(at: 0)
        #expect(session.replyReading?.move.depth == 20, "unchanged until the number lands")
        await until { session.rejudging == nil }
        let reading = try #require(session.replyReading)
        #expect(reading.move.depth == 28)
        #expect(reading.move.drop == expectedDrop)
        #expect(reading.line == ["g4", "Qh4"])
        #expect(!reading.isAsking)
    }

    @Test func amoveOrTheEyeMovingOnCancelsItUnwritten() async throws {
        // Every everyday search answers, so a move played can be weighed and stand; only the
        // deeper one hangs, which is the 复判 under test.
        let engine = ScriptedEngine([Analysis(depth: 20, lines: [
            .init(score: .centipawns(0), uciMoves: ["d2d4"], san: ["d4"])
        ])], controlled: { _, budget in
            budget == PositionSearches.deeper ? AsyncStream { _ in } : nil
        })
        let game = try pendingG4()
        let session = GameSession.fresh(game, engine: engine)
        defer { session.suspend() }
        session.jumpToLatest()

        session.rejudge(at: 0)
        await until { engine.searchCount == 1 }
        #expect(session.rejudging != nil)
        session.jump(toPly: 1)
        #expect(session.rejudging == nil, "the eye moved on")
        session.jumpToLatest()
        #expect(session.game.pendingTries(atPly: 2) == game.pendingTries(atPly: 2), "nothing written")

        session.rejudge(at: 0)
        await until { engine.searchCount == 2 }
        session.play(try #require(session.game.state.move(matching: "d2d4")))
        #expect(session.rejudging == nil, "a move was played")
        await session.waitForJudgement()
        #expect(session.game.uciMoves == ["f2f3", "e7e5", "d2d4"])
        #expect(session.game.plies[2].tried.map(\.drop) == [40], "carried along as it was")
    }

    @Test func aMoveFromAnOlderFileWithNoDepthIsOffered() throws {
        let session = GameSession.fresh(try pendingG4(depth: nil), engine: ScriptedEngine([]))
        defer { session.suspend() }
        session.jumpToLatest()
        #expect(session.rejudgeOffer(at: 0) == .ready)
        let unplugged = GameSession.fresh(try pendingG4(depth: nil))
        defer { unplugged.suspend() }
        unplugged.jumpToLatest()
        #expect(unplugged.rejudgeOffer(at: 0) == .none, "nothing to judge it with")
    }

    /// The 错题本 needs no hand of its own in this: a rewritten file is re-walked by its date, and
    /// a 遭遇 whose deeper 掉幅 falls under the 记录线 leaves by the filter that already exists.
    @Test func theBookReadsTheDeeperNumberOffTheFile() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
        game.setTried([.init(san: "f3", drop: 15, depth: 20)], atPly: 0)
        let lines = JudgementLines(record: 10, enqueue: 20)
        let url = URL(filePath: "/games/rejudged.pgn")
        func book(_ game: Game, at modified: Date) throws -> MistakeBook {
            let pgn = try PGN(parsing: PGN(game: game, tags: [.init("White", Controller.hand.playerName)]).text)
            return MistakeBook.derive(from: [GameLibrary.Entry(url: url, pgn: pgn, modified: modified)], lines: lines)
        }
        #expect(try book(game, at: Date()).mistakes.count == 1)
        game.setTried([.init(san: "f3", drop: 6, depth: 28)], atPly: 0)
        #expect(try book(game, at: Date()).mistakes.isEmpty, "under the 记录线 now, so it leaves")
        game.setTried([.init(san: "f3", drop: 12, depth: 28)], atPly: 0)
        let kept = try book(game, at: Date())
        #expect(kept.mistakes.first?.encounters.first?.cost == 12, "over it, with the new cost")
    }
}
