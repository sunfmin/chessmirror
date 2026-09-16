@testable import ChessmirrorKit
import ChessmirrorKitTesting
import Testing

/// Contract: what the game screen draws, it is handed by the session as values — the 错招 by
/// position, the curve, the finder's arrows, the depth already paid for, whether a card is being
/// answered, and who turned the finder on. The screen used to derive each of these in a private
/// computed property of its own, which is exactly the place nothing but a simulator can test.
@MainActor
@Suite(.speaking(.chinese)) struct HandedValuesTests {
    /// White gets ply 1 wrong twice before a move stands, Black tries d6 at ply 2, and White's
    /// ply 3 stood too expensively.
    private func played() throws -> Game {
        var game = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3"])
        )
        game.setTried([.init(san: "f3", drop: 24), .init(san: "a3", drop: 12)], atPly: 0)
        game.setJudgement(.init(drop: 0, score: .centipawns(20), depth: 20), atPly: 0)
        game.setTried([.init(san: "d6", drop: 30)], atPly: 1)
        game.setJudgement(.init(drop: 14, score: .centipawns(-40), depth: 20), atPly: 2)
        return game
    }

    private func hop() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // ------------------------------------------------------------------ the record strip

    /// A mistake at Ply `n` is marked on the cell at `n - 1`: the cell that shows the position it
    /// was played from (docs/adr/0036). A fresh game is both hands, so Black's 试招 counts too.
    @Test func slipsAreKeyedOnThePositionTheyWereMadeAt() throws {
        let session = GameSession.fresh(try played())
        let byPosition = session.slipByPosition
        #expect(Set(byPosition.keys) == [0, 1, 2])
        #expect(byPosition[0]?.ply == 1, "the opening cell carries the first move's 试招")
        #expect(byPosition[2]?.wrong.map(\.san) == ["Nf3"], "the move that stood, on the cell before it")
        #expect(byPosition[3] == nil, "the last cell has nothing played from it")
    }

    /// One Score is a number, not a shape: the curve draws from two known positions on.
    @Test func theCurveIsTheRecordsScoresAndKnowsWhetherItCanBeDrawn() throws {
        let quiet = GameSession.fresh(try #require(Game(startFEN: PGN.standardStartFEN)))
        #expect(!quiet.curve.isDrawable, "nothing scored, nothing to draw")
        #expect(quiet.curve.plies == 0)

        let session = GameSession.fresh(try played())
        let curve = session.curve
        #expect(curve.plies == 3)
        #expect(curve.known == [1, 3], "the two judgements, at the positions their moves made")
        #expect(curve.isDrawable)
        #expect(curve.lastKnownPly == 3)
        #expect(curve.score(atPly: 1) == .centipawns(20))
        #expect(curve.score(atPly: 2) == nil, "Black's move was never judged")
        #expect(curve.score(atPly: 9) == nil, "past the end is not a position")
        #expect(
            (0...3).map { curve.score(atPly: $0) } == (0...3).map { session.historyScore(atPly: $0) },
            "the same numbers historyScore gives one at a time"
        )
    }

    // ------------------------------------------------------------------ arrows

    /// White queen on d1, black rook hanging on d5.
    private static let hangingRook = "4k3/8/8/3r4/8/8/8/3QK3 w - - 0 1"

    /// The one walk both the 应招 and the finder's line are drawn by: legal moves on a copy of the
    /// position, whose they are asked per colour, stopping where the line stops replaying.
    @Test func theWalkReplaysALineAsArrowsAndStopsWhereItCannot() throws {
        let position = try #require(Game(startFEN: Self.hangingRook))
        let arrows = MoveArrow.walk(["Qxd5", "Kf8", "Qd8#"], from: position) { $0 == .white }
        #expect(arrows.map(\.step) == [1, 2, 3])
        #expect(arrows.map(\.move.from.description) == ["d1", "e8", "d5"])
        #expect(arrows.map(\.isYours) == [true, false, true], "asked per colour, not per index")
        #expect(arrows.allSatisfy { !$0.isPlayed })

        let broken = MoveArrow.walk(["Qxd5", "Kd7", "Qd8#"], from: position) { _ in true }
        #expect(broken.count == 1, "Kd7 walks into the queen; the walk stops at the first move that will not replay")

        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        let long = MoveArrow.walk(
            ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6", "Ba4", "Nf6"], from: start
        ) { _ in true }
        #expect(long.count == MateNews.arrowLimit, "as many as a board can carry")
    }

    /// A 应招 counts "yours" from whoever played the refused move, and is the same walk.
    @Test func aReplyIsTheWalkCountedFromTheMover() throws {
        let position = try #require(Game(startFEN: Self.hangingRook))
        let line = ["Qxd5", "Kf8", "Qd8#"]
        #expect(
            Reply.arrows(in: position, playing: line)
                == MoveArrow.walk(line, from: position) { $0 == .white }
        )
    }

    /// The finder's line comes off the session as arrows on the position on screen, yours where
    /// the hand is moving that colour.
    @Test func theFindersLineIsHandedAsArrows() async throws {
        let game = try #require(Game(startFEN: Self.hangingRook))
        let engine = ScriptedEngine(
            [],
            byPosition: [
                game.state.fen: Analysis(
                    depth: PositionSearches.depth,
                    lines: [
                        Line(score: .centipawns(500), uciMoves: ["d1d5"], san: ["Qxd5", "Kf8"]),
                        Line(score: .centipawns(20), uciMoves: ["d1d2"], san: ["Qd2"]),
                    ]
                )
            ]
        )
        let session = GameSession.playing(game, engine: engine, library: nil, strength: .full)
        #expect(session.tacticArrows.isEmpty, "nothing named yet")
        session.setFindingTactics(true)
        await hop()
        let tactic = try #require(session.tactic)
        #expect(tactic.line == ["Qxd5", "Kf8"])
        let arrows = session.tacticArrows
        #expect(arrows.map(\.move.from.description) == ["d1", "e8"])
        #expect(arrows.map(\.isYours) == [true, false], "White is the hand, Black the engine")
    }

    // ------------------------------------------------------------------ the card's frame

    /// Nothing has run: no depth to name. Once a card's Stint has finished, the depth it reached
    /// stays named, and the card is no longer being answered.
    @Test func theDepthPaidForOutlivesTheSearch() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let session = GameSession.fresh(game)
        #expect(session.standingProgress == nil)
        #expect(!session.isAdvising)

        let engine = ScriptedEngine(
            [],
            byPosition: [
                game.state.fen: Analysis(
                    depth: 12, selectiveDepth: 18,
                    lines: [Line(score: .centipawns(30), uciMoves: ["e2e4"], san: ["e4"])],
                    timeMilliseconds: 250
                )
            ]
        )
        session.attach(engine: engine, library: nil)
        session.adviseForCard()
        await hop()
        #expect(!session.isSearching, "the scripted search finished")
        #expect(!session.isAdvising, "and the card has been answered")
        let progress = try #require(session.standingProgress)
        #expect(progress.depth == 12)
        #expect(progress.selectiveDepth == 18)
        #expect(progress.milliseconds == 250)
    }

    /// While a card's Stint is still going, the card is being answered and the frame names the
    /// depth it has got to so far.
    @Test func aCardIsBeingAnsweredWhileItsSearchRuns() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let engine = ScriptedEngine(
            [],
            controlled: { _, _ in
                AsyncStream { continuation in
                    // One finished depth, and then nothing: the search is still on. (A partial
                    // snapshot would not do — the shared search forwards only complete ones.)
                    continuation.yield(Analysis(
                        depth: 7,
                        lines: [Line(score: .centipawns(10), uciMoves: ["d2d4"], san: ["d4"])]
                    ))
                }
            }
        )
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        session.adviseForCard()
        await hop()
        #expect(session.isSearching)
        #expect(session.isAdvising)
        #expect(session.standingProgress?.depth == 7)
    }

    // ------------------------------------------------------------------ the finder's switch

    /// The swipe onto 杀 or 战术 is the asking: arriving turns the finder on, leaving turns it off.
    @Test func arrivingOpensTheFinderAndLeavingClosesIt() throws {
        let session = GameSession.fresh(try #require(Game(startFEN: PGN.standardStartFEN)))
        session.arriveAtFinder()
        #expect(session.isFindingTactics)
        session.leaveFinder()
        #expect(!session.isFindingTactics)
    }

    /// A switch somebody pressed by hand is theirs: a swipe away does not put it back.
    @Test func leavingKeepsAFinderSomebodyPressedOn() throws {
        let session = GameSession.fresh(try #require(Game(startFEN: PGN.standardStartFEN)))
        session.setFindingTactics(true)
        session.arriveAtFinder()
        session.leaveFinder()
        #expect(session.isFindingTactics, "the hand turned it on, the swipe leaves it")

        session.setFindingTactics(false)
        session.arriveAtFinder()
        session.setFindingTactics(false)
        session.arriveAtFinder()
        session.leaveFinder()
        #expect(!session.isFindingTactics, "pressed off by hand and opened again by arrival: the arrival's to close")
    }

    /// 把关 keeps the finder off, and arriving does not claim a switch it could not throw.
    @Test func arrivingWhileTillingOpensNothing() throws {
        let session = GameSession.fresh(try #require(Game(startFEN: PGN.standardStartFEN)))
        session.setIntercept(JudgementLines.defaultIntercept)
        session.arriveAtFinder()
        #expect(!session.isFindingTactics)
        session.leaveFinder()
        #expect(!session.isFindingTactics)
    }
}
