import ChessmirrorKit
import Foundation
import Testing

/// Contract: 记录读数 is had from a Game and the 判决线, and from nothing else.
///
/// Everything here used to be reachable only through a `GameSession` — which meant an engine to
/// script, a host to attach and a `suspend()` to remember. A record is a reading of what is
/// written down; these tests stand up no session at all.
@Suite struct RecordReadingTests {
    /// 1. e4 e5 2. Nf3, where Nf3 is scored as throwing four pawns away, so it is White's 错招.
    private func reviewed() throws -> Game {
        var game = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3"])
        )
        game.applyReview(
            [.centipawns(0), .centipawns(0), .centipawns(-400)],
            startEvaluation: .centipawns(0), depth: 16
        )
        return game
    }

    private func reading(_ game: Game, at cursor: Int) -> RecordReading {
        RecordReading(game: game, mine: [.white], lines: .standard, cursor: cursor)
    }

    @Test("a reviewed game's 错招 are read straight off the record")
    func slipsComeOffTheGame() throws {
        let game = try reviewed()
        let read = reading(game, at: 2)
        #expect(read.slips.map(\.ply) == [3], "White's third move is the one that cost")
        #expect(read.slipByPosition[2] != nil, "and it is marked on the position it was played from")

        // The move that stood is a wrong move at its own position, and only there.
        #expect(read.wrongs.map(\.san) == ["Nf3"])
        #expect(read.wrongs.first?.stood == true)
        #expect(read.wrongsPly == 2)
        #expect(reading(game, at: 3).wrongs.isEmpty, "at the position after it, the badge says it")
    }

    @Test("moving the eye keeps the walk")
    func movingKeepsTheSlips() throws {
        let game = try reviewed()
        let read = reading(game, at: 0)
        let moved = read.moved(to: 2)
        #expect(moved.cursor == 2)
        #expect(moved.slips.map(\.ply) == read.slips.map(\.ply))
        #expect(read.wrongs.isEmpty, "nothing was wrong at the opening")
        #expect(moved.wrongs.map(\.san) == ["Nf3"])
    }

    @Test("the next 错招 from where the eye is")
    func theNextSlip() throws {
        let game = try reviewed()
        #expect(reading(game, at: 0).next?.ply == 3)
        #expect(reading(game, at: 2).next == nil, "standing on the last one, there is no next")
    }

    @Test("a 试招 refused at a position is read at that position")
    func refusalsAreReadWhereTheyHappened() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN))
        game.recordTried(Game.Ply.Tried(san: "Nh3", drop: 14.2, depth: 20, line: ["e5"]), atPly: 0)
        let read = reading(game, at: 0)

        #expect(read.place == .pending)
        #expect(read.attempts.map(\.san) == ["Nh3"])
        #expect(read.wrongs.map(\.san) == ["Nh3"])
        #expect(read.wrongs.first?.stood == false)
        #expect(read.wrongs.first?.triedIndex == 0)
        #expect(read.wrongs.first?.line == ["e5"], "the 应招 it earned comes with it")
        #expect(read.wrongsPly == 0)
        // A refusal is a 错招 of this game as much as a move that stood is (docs/adr/0036, 0037):
        // it is written at the position it happened at, and the tile there counts it.
        #expect(read.slips.map(\.positionPly) == [0])
        #expect(read.slips.first?.wrong.map(\.san) == ["Nh3"])
        #expect(read.slips.first?.wrong.first?.wasTried == true)
    }

    @Test("a raised 记录线 reads fewer 错招 off the same game")
    func theLineDecidesWhatIsRead() throws {
        let game = try reviewed()
        let strict = RecordReading(game: game, mine: [.white], lines: .standard, cursor: 2)
        let lax = RecordReading(
            game: game, mine: [.white],
            lines: JudgementLines(noSlips: false, record: 90, enqueue: 90), cursor: 2
        )
        #expect(!strict.slips.isEmpty)
        #expect(lax.slips.isEmpty, "nothing costs ninety points here")
        #expect(lax.wrongs.isEmpty)
    }

    @Test("whose moves count is whose the caller says")
    func onlyTheHandsMovesAreRead() throws {
        let game = try reviewed()
        let asBlack = RecordReading(game: game, mine: [.black], lines: .standard, cursor: 2)
        #expect(asBlack.slips.isEmpty, "Nf3 is White's, and Black was not playing it")
    }
}
