@testable import ChessmirrorKit
import ChessmirrorKitTesting
import Testing

/// Mate, tactics, and a reply are one replay: arrows and chips agree on colour, and the first
/// move that will not replay ends both.
@Suite struct LineWalkTests {
    private static let hangingRook = "4k3/8/8/3r4/8/8/8/3QK3 w - - 0 1"

    @Test func aMateLineStopsWhereItWillNotReplay() throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let san = ["e4", "e5", "Qh5", "nope", "Nf3"]
        let news = try #require(MateNews.read(
            Analysis(depth: 12, lines: [
                Line(score: .mate(in: 3), uciMoves: ["e2e4", "e7e5", "d1h5", "a2a3", "g1f3"], san: san),
            ]),
            in: game, hands: [.white]
        ))
        #expect(news.arrows.map(\.step) == [1, 2, 3])
        #expect(news.steps.map(\.san) == ["e4", "e5", "Qh5"])
        #expect(news.steps.map(\.isYours) == news.arrows.map(\.isYours))
        #expect(news.steps.map(\.isYours) == [true, false, true])
        #expect(!news.steps.contains { $0.san == "Nf3" })
    }

    @Test func aReplyLineStopsWhereItWillNotReplay() throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let reading = ReplyReading(
            index: 0,
            move: RecordReading.WrongMove(
                source: .stood(ply: 1), san: "f3", drop: 20, depth: 16, line: []
            ),
            position: game,
            line: ["e4", "e5", "nope", "Nf3"],
            isAsking: false
        )
        #expect(reading.arrows.map(\.step) == [1, 2])
        #expect(reading.steps.map(\.san) == ["e4", "e5"])
        #expect(reading.steps.map(\.isYours) == reading.arrows.map(\.isYours))
        #expect(reading.steps.map(\.isYours) == [true, false])
    }
}

@MainActor
@Suite struct TacticsLineWalkTests {
    private static let hangingRook = "4k3/8/8/3r4/8/8/8/3QK3 w - - 0 1"

    @Test func aTacticsLineStopsWhereItWillNotReplay() async throws {
        let game = try #require(Game(startFEN: Self.hangingRook))
        let engine = ScriptedEngine([], byPosition: [
            game.state.fen: Analysis(depth: PositionSearches.depth, lines: [
                Line(score: .centipawns(500), uciMoves: ["d1d5"], san: ["Qxd5", "Kf8", "nope", "Qd8"]),
                Line(score: .centipawns(20), uciMoves: ["d1d2"], san: ["Qd2"]),
            ]),
        ])
        let session = GameSession.playing(game, engine: engine, library: nil, strength: .full)
        defer { session.suspend() }
        session.setFindingTactics(true)
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        let tactic = try #require(session.tactic)
        #expect(tactic.line == ["Qxd5", "Kf8", "nope", "Qd8"])
        let arrows = session.tacticArrows
        let chips = session.steps(on: .tactics)
        #expect(arrows.map(\.step) == [1, 2])
        #expect(chips.map(\.san) == ["Qxd5", "Kf8"])
        #expect(chips.map(\.isYours) == arrows.map(\.isYours))
        #expect(chips.map(\.isYours) == [true, false])
    }
}
