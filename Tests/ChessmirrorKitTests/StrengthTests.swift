import Foundation
import Testing

@testable import ChessmirrorKit
import ChessmirrorKitTesting

/// Contract: a 棋力 bounds the opponent's own move and nothing else, is written onto every move
/// the engine plays, and comes back out of the file (docs/adr/0038).
///
/// Which move a bound engine plays is a seeded random inside Stockfish, so nothing here asserts
/// a move. What is asserted is the seam: which searches were bound, and which were not.
@MainActor
@Suite struct StrengthTests {
    private static let start = Game(startFEN: PGN.standardStartFEN)!
    private static let afterE4 = Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"])!
    private static let afterE5 = Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"])!

    /// An opinion per position, so the engine has a legal move to play wherever it is asked.
    private static func engine() -> ScriptedEngine {
        ScriptedEngine([], byPosition: [
            start.state.fen: Analysis(depth: 20, lines: [
                .init(score: .centipawns(30), uciMoves: ["e2e4"], san: ["e4"]),
            ]),
            afterE4.state.fen: Analysis(depth: 20, lines: [
                .init(score: .centipawns(10), uciMoves: ["e7e5"], san: ["e5"]),
            ]),
            afterE5.state.fen: Analysis(depth: 20, lines: [
                .init(score: .centipawns(20), uciMoves: ["g1f3"], san: ["Nf3"]),
            ]),
        ])
    }

    /// Every way into a game starts at the rung it is handed. A photographed board and a corrected
    /// one took no rung at all and started at 满力, so the first engine seated on a game read off
    /// the camera played at full strength whatever the player had picked.
    @Test("every way into a game starts at the rung it is handed")
    func everyWayInTakesTheRung() {
        let rung = Strength.elo(1600)
        let game = Self.start
        #expect(GameSession.recognised(game, strength: rung).strength == rung)
        #expect(GameSession.corrected(
            game, controllers: [.white: .hand, .black: .hand], orientation: .whiteAtBottom,
            origin: .recognised, picture: nil, shaky: [], engine: nil, library: nil, strength: rung
        ).strength == rung)
        #expect(GameSession.fresh(game, strength: rung).strength == rung)
        #expect(GameSession.playing(game, strength: rung).strength == rung)
        #expect(GameSession.recognised(game).strength == .full, "and 满力 is still the default")
    }

    /// The engine's bar names the engine with the rung it is on, and the name alone at 满力.
    @Test("the engine is named with its rung")
    func theEngineIsNamedWithItsRung() {
        #expect(Strength.elo(1800).engineName == "Stockfish 18 · 1800")
        #expect(Strength.full.engineName == "Stockfish 18")
    }

    /// One move by hand under 正着, answered by the engine: the judging searches, the engine's own
    /// search, and the search that prepares the next position, in that order.
    private func playE4(against strength: Strength, engine: ScriptedEngine) async throws -> GameSession {
        let session = GameSession.fresh(
            Self.start, controllers: [.white: .hand, .black: .engine], engine: engine,
            strength: strength
        )
        session.noSlips(at: 5)
        await session.waitForPreparedInterception()
        session.play(try #require(Self.start.state.move(matching: "e2e4")))
        await session.settled()
        // The engine's own move, and then the preparation of the position it made.
        await session.waitForPreparedInterception()
        await session.waitForPreparedInterception()
        return session
    }

    @Test func theOpponentsOwnSearchIsBoundAndNothingElseIs() async throws {
        let engine = Self.engine()
        let session = try await playE4(against: .elo(1400), engine: engine)
        defer { session.suspend() }

        #expect(session.game.uciMoves == ["e2e4", "e7e5"], "the engine answered")
        let bound = engine.strengths.indices.filter { engine.strengths[$0] != .full }
        #expect(bound.count == 1, "one search was bound: the opponent's own move")
        let index = try #require(bound.first)
        #expect(engine.strengths[index] == .elo(1400))
        #expect(engine.positions[index] == Self.afterE4.state.fen, "and it was the position the engine moved from")
        #expect(engine.strengths.last == .full, "the search after it is at 满力 again")
        #expect(engine.budgets[index] == PositionSearches.budget, "on the same clock as ever")
        // Written onto the move the engine played, and onto nothing the player played.
        #expect(session.game.plies.map(\.strength) == [nil, .elo(1400)])
    }

    @Test func atFullStrengthNothingIsBoundAndTheMoveStillSaysSo() async throws {
        let engine = Self.engine()
        let session = try await playE4(against: .full, engine: engine)
        defer { session.suspend() }

        #expect(session.game.uciMoves == ["e2e4", "e7e5"])
        #expect(engine.strengths.allSatisfy { $0 == .full })
        #expect(session.game.plies.map(\.strength) == [nil, .full], "满力 is a fact about the move too")
    }

    /// 细判 weighs every move at 满力 whatever the 棋力: the same move costs the same 掉幅 at 1400
    /// and at 满力, and the searches that weighed it were never bound.
    @Test func judgementsAreAtFullStrengthWhateverTheRung() async throws {
        let weak = Self.engine()
        let weakSession = try await playE4(against: .elo(1400), engine: weak)
        defer { weakSession.suspend() }
        let strong = Self.engine()
        let strongSession = try await playE4(against: .full, engine: strong)
        defer { strongSession.suspend() }

        let atWeak = try #require(weakSession.game.plies[0].judgement)
        let atStrong = try #require(strongSession.game.plies[0].judgement)
        #expect(atWeak.drop == atStrong.drop)
        #expect(atWeak.score == atStrong.score)
        #expect(atWeak.intercept == 5, "and it stood under 正着 at the 拦截线 in force")
        // The two searches that judged e4 — the position it was played from and the one it made —
        // were at 满力 in the weaker game too.
        let judging = weak.strengths.indices.filter {
            weak.positions[$0] == Self.start.state.fen
                || (weak.positions[$0] == Self.afterE4.state.fen && weak.strengths[$0] == .full)
        }
        #expect(!judging.isEmpty)
        #expect(judging.allSatisfy { weak.strengths[$0] == .full })
    }

    /// A rung changed while the engine is thinking takes effect on that move: the search starts
    /// again under the new rung rather than carrying on under the old one.
    @Test func changingTheRungRestartsTheMoveBeingThoughtAbout() async throws {
        // A search that never answers, so the engine is still thinking when the rung changes.
        let engine = ScriptedEngine([], controlled: { _, _ in AsyncStream { _ in } })
        let session = GameSession.fresh(
            Self.start, controllers: [.white: .engine, .black: .hand], engine: engine,
            strength: .elo(1400)
        )
        defer { session.suspend() }
        session.retune()
        await hop()
        #expect(session.thinking == .own)
        #expect(engine.searchCount == 1)
        #expect(engine.strengths.last == .elo(1400))

        session.setStrength(.elo(1800))
        await hop()
        #expect(session.strength == .elo(1800))
        #expect(engine.searchCount == 2, "the move being thought about starts again")
        #expect(engine.strengths.last == .elo(1800), "under the new rung")
        #expect(session.thinking == .own, "and it is still the engine's move")

        session.setStrength(.elo(1800))
        await hop()
        #expect(engine.searchCount == 2, "the same rung again is not a change")
    }

    /// The engine's search starts in a task of its own, so it is known a hop later.
    private func hop() async {
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // ------------------------------------------------------------------ the file

    @Test func aGameAtTwoRungsWritesEachMoveAndReadsBackTheRungOfEveryPly() throws {
        var game = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6"])
        )
        game.setStrength(.elo(1600), atPly: 1)
        game.setStrength(.elo(2000), atPly: 3)
        let text = PGN(game: game).text
        #expect(text.contains("[%strength 1600]"))
        #expect(text.contains("[%strength 2000]"))
        #expect(!text.contains("[%strength full]"), "no hand move carries a rung")

        let read = try PGN(parsing: text).game
        #expect(read.plies.map(\.strength) == [nil, .elo(1600), nil, .elo(2000)])
        // The player's move is credited to the rung of the reply it was played against.
        #expect(
            (1...4).map { read.strength(ofPly: $0) } == [.elo(1600), .elo(1600), .elo(2000), .elo(2000)],
            "two stretches: the first two Plies at 1600, the next two at 2000"
        )
    }

    /// A game the player finished with mate has no reply to credit their last move to, so it is
    /// credited to the engine's move before it; a game against a human is credited to nothing.
    @Test func aRungIsReadForwardThenBackAndNeverInvented() throws {
        // 1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qxf7# — Black on the engine at 1800.
        var mate = try #require(Game(
            startFEN: PGN.standardStartFEN,
            uciMoves: ["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6", "h5f7"]
        ))
        for ply in [1, 3, 5] { mate.setStrength(.elo(1800), atPly: ply) }
        #expect(mate.strength(ofPly: 7) == .elo(1800), "Qxf7# was played against the 1800 engine")
        #expect((1...7).allSatisfy { mate.strength(ofPly: $0) == .elo(1800) }, "one stretch, one rung")

        let hands = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
        #expect((1...2).allSatisfy { hands.strength(ofPly: $0) == nil })
        #expect(hands.strength(ofPly: 3) == nil, "a Ply nobody has played is at no rung")
    }

    @Test func theStandardEloTagIsWrittenOnlyWhenTheWholeGameWasAtOneRung() throws {
        var game = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6"])
        )
        game.setStrength(.elo(1800), atPly: 1)
        game.setStrength(.elo(1800), atPly: 3)
        let steady = GameSession.fresh(game, controllers: [.white: .hand, .black: .engine])
        #expect(steady.pgn.tag("BlackElo") == "1800")
        #expect(steady.pgn.tag("WhiteElo") == nil, "White was a hand")

        game.setStrength(.elo(2000), atPly: 3)
        let changed = GameSession.fresh(game, controllers: [.white: .hand, .black: .engine])
        #expect(changed.pgn.tag("BlackElo") == nil, "a game that changed rung says so per move")
        #expect(changed.pgn.text.contains("[%strength 2000]"))

        game.setStrength(.full, atPly: 1)
        game.setStrength(.full, atPly: 3)
        let unbound = GameSession.fresh(game, controllers: [.white: .hand, .black: .engine])
        #expect(unbound.pgn.tag("BlackElo") == nil, "满力 has no Elo to write")
        #expect(unbound.pgn.text.contains("[%strength full]"))
    }

    /// A file from before 棋力 was written down: the roster says who the engine was, and its
    /// moves were at 满力, because that was the only opponent there was (docs/adr/0009).
    @Test func aFileWithoutRungsReadsItsEngineMovesAsFullStrength() throws {
        let legacy = """
        [White "手动"]
        [Black "Stockfish 18"]

        1. e4 e5 2. Nf3 Nc6 *
        """
        let read = try PGN(parsing: legacy).game
        #expect(read.plies.map(\.strength) == [nil, .full, nil, .full])
        #expect((1...4).allSatisfy { read.strength(ofPly: $0) == .full })

        let hands = try PGN(parsing: "[White \"手动\"]\n[Black \"手动\"]\n\n1. e4 e5 *").game
        #expect(hands.plies.map(\.strength) == [nil, nil])

        // A file that writes rungs writes one on every engine move; a move without one is a hand's.
        let mixed = """
        [White "手动"]
        [Black "Stockfish 18"]

        1. e4 e5 {[%strength 1600]} 2. Nf3 Nc6 *
        """
        #expect(try PGN(parsing: mixed).game.plies.map(\.strength) == [nil, .elo(1600), nil, nil])
    }

    @Test func aReopenedGameComesBackAtTheRungOfItsLastEngineMove() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
        game.setStrength(.elo(2000), atPly: 1)
        let played = GameLibrary.Entry(
            url: URL(filePath: "/games/chessmirror-at-2000.pgn"), pgn: PGN(game: game),
            modified: Date(timeIntervalSince1970: 1_786_000_000)
        )
        #expect(try #require(GameSession.opened(played, strength: .elo(1400))).strength == .elo(2000))

        let fresh = GameLibrary.Entry(
            url: URL(filePath: "/games/chessmirror-fresh.pgn"), pgn: PGN(game: Self.start),
            modified: Date(timeIntervalSince1970: 1_786_000_000)
        )
        #expect(try #require(GameSession.opened(fresh, strength: .elo(1400))).strength == .elo(1400),
                "with nothing in the game to say otherwise, the remembered rung")
        #expect(GameSession.playing(Self.start, strength: .elo(2200)).strength == .elo(2200))
        #expect(GameSession.playing(Self.start).strength == .full, "满力 until somebody picks")
    }

    @Test func theLadderIsFixedAndARungReadsBackFromItsText() {
        #expect(Strength.ladder.last == .full)
        #expect(Strength.ladder.compactMap(\.elo) == [1400, 1600, 1800, 2000, 2200, 2500, 2800])
        for rung in Strength.ladder {
            #expect(Strength(text: rung.text) == rung)
        }
        #expect(Strength(text: "900") == nil, "below what Stockfish accepts")
        #expect(Strength(text: "strong") == nil)
        Speech.speaking(.chinese) {
            #expect(Strength.full.label == "满力")
            #expect(Strength.elo(1800).label == "1800")
        }
    }
}
