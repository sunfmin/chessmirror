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

    // ------------------------------------------------------------------ what the record says

    private static let italian = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6"]
    private let sep = localized("clause.separator")

    private func cell(_ reading: RecordReading, _ ply: Int, in game: Game) throws -> RecordReading.Cell {
        let half = try #require(game.scoresheet.flatMap { [$0.white, $0.black] }.compactMap { $0 }
            .first { $0.ply == ply })
        return reading.cell(half)
    }

    /// A 把关 game: White's moves judged at a point each, the engine's never, and Nh3 refused at the
    /// position after 4... Nc6 for twelve.
    private func tallied() throws -> Game {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let stood = Game.Ply.Judgement(drop: 1, score: .centipawns(20), depth: 20, intercept: 5)
        for ply in [0, 2, 4, 6] { game.setJudgement(stood, atPly: ply) }
        game.setTried([.init(san: "Nh3", drop: 12)], atPly: 4)
        return game
    }

    @Test("each measured move says what it cost, and a move nobody measured says nothing")
    func theRecordSaysWhatEachMoveCost() throws {
        let game = try tallied()
        let read = RecordReading(game: game, mine: [.white], lines: JudgementLines(noSlips: true), cursor: 8)

        let e4 = try cell(read, 1, in: game)
        #expect(e4.caption == .cost(1))
        #expect(e4.caption?.figure == "−1%")
        #expect(e4.spoken == localized("screen.spokenMove", 1, "e4") + sep + localized("book.cost", 1))

        let e5 = try cell(read, 2, in: game)
        #expect(e5.caption == .unmeasured, "the engine's move was never judged: no cost, and not zero")
        #expect(e5.caption?.figure == " ", "a blank of the same height")
        #expect(e5.spoken == localized("screen.spokenMove", 2, "e5"))

        // Nh3 was refused at the position after 4... Nc6, so that cell wears the mark.
        let nc6 = try cell(read, 4, in: game)
        #expect(nc6.mark == .owed, "twelve is over the 入列线")
        #expect(nc6.spoken == localized("screen.spokenMove", 4, "Nc6") + sep + localized("record.slipMark", 12))
        #expect(nc6.caption == .unmeasured, "the mark is not this move's cost: Nc6 was never measured")
        #expect(!nc6.spoken.hasPrefix(localized("screen.spokenMove", 4, "Nc6") + sep + localized("book.cost", 12)))
    }

    @Test("a reviewed record prices both sides, and a move that cost nothing says 0")
    func aReviewedRecordPricesBothSides() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        game.applyReview(
            [30, 30, 30, 90, 90, 90, 90, 90].map { Score.centipawns($0) },
            startEvaluation: .centipawns(30), depth: 16
        )
        let read = RecordReading(game: game, mine: [.white], lines: .standard, cursor: 8)
        let gaveAway = try #require(game.cost(atPly: 4))
        #expect(gaveAway > 0, "4... Nc6 let the position slide")
        #expect(try cell(read, 4, in: game).caption == .cost(gaveAway))
        #expect(try cell(read, 4, in: game).spoken.hasSuffix(localized("book.cost", Drop.points(gaveAway))))
        #expect(try cell(read, 1, in: game).caption == .free)
        #expect(try cell(read, 1, in: game).caption?.figure == "0")
        #expect(try cell(read, 1, in: game).spoken.hasSuffix(localized("book.cost", 0)), "a move that cost nothing says so")
        #expect(try cell(read, 8, in: game).caption == .free, "the engine's moves are priced too")
    }

    @Test("最佳 is the engine's own choice, not a nought, and it wins over a point of noise")
    func bestIsAFactAboutWhichMove() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        game.applyReview(
            [
                .init(score: .centipawns(30), line: ["e5", "Nf3"]),
                .init(score: .centipawns(30), line: ["d4", "exd4"]),
                .init(score: .centipawns(30), line: ["Nc6"]),
                .init(score: .centipawns(30), line: ["Bc4"]),
                .init(score: .centipawns(30), line: ["Bc5"]),
                .init(score: .centipawns(30), line: ["c3"]),
                .init(score: .centipawns(30), line: ["Nf6"]),
                .init(score: .centipawns(30), line: []),
            ],
            startEvaluation: .centipawns(30), depth: 16
        )
        // 1. e4 let stand under 把关 as the engine's own choice, by a search a point off the Review.
        game.setJudgement(
            .init(drop: 0.8, score: .centipawns(30), depth: 20, intercept: 10, best: true), atPly: 0
        )
        let read = RecordReading(game: game, mine: [.white], lines: .standard, cursor: 8)
        let best = localized("standing.best")
        #expect(try cell(read, 1, in: game).caption == .best, "by the judgement, over its −1%")
        #expect(try cell(read, 1, in: game).caption?.figure == localized("record.best"))
        #expect(try cell(read, 1, in: game).spoken.hasSuffix(best), "and the cell and its words agree")
        #expect(try cell(read, 2, in: game).caption == .best, "by the Review's Line after e4")
        #expect(try cell(read, 3, in: game).caption == .free, "free, but the Line wanted d4")
        #expect(try !cell(read, 3, in: game).spoken.contains(best))
        #expect(try cell(read, 4, in: game).caption == .best)
    }

    @Test("a game nobody measured has no line of costs, and the strip is as it was")
    func anUnmeasuredGameHasNoCaptions() throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let read = RecordReading(game: game, mine: [.white], lines: .standard, cursor: 0)
        #expect(try (1...8).allSatisfy { try cell(read, $0, in: game).caption == nil })
        #expect(read.opening.caption == nil)
        #expect(read.opening.name == localized("record.opening"))
        #expect(read.opening.spoken == localized("record.opening"))
        #expect(read.opening.mark == nil)
    }

    @Test("the mark at a cell's foot is owed over the 入列线, and only written down under it")
    func theMarkHasTwoWeights() throws {
        let game = try reviewed()
        let owed = RecordReading(game: game, mine: [.white], lines: .standard, cursor: 0)
        #expect(try cell(owed, 2, in: game).mark == .owed, "Nf3 was played from the position after 1... e5")
        #expect(try cell(owed, 3, in: game).mark == nil, "and the mark is not on Nf3's own cell")

        let wide = RecordReading(
            game: game, mine: [.white], lines: JudgementLines(record: 10, enqueue: 90), cursor: 0
        )
        #expect(try cell(wide, 2, in: game).mark == .written, "worth writing down, not worth drilling")
        #expect(wide.tiles.first?.isOwed == false)
    }

    @Test("a 错题 tile says where, how many and how much, and says all of it out loud")
    func aTileSaysItsPosition() throws {
        let game = try reviewed()
        let tile = try #require(reading(game, at: 0).tiles.first)
        let drop = tile.slip.drop
        #expect(tile.number == "2.", "the scoresheet's figure for White's second move")
        #expect(tile.times == nil)
        #expect(tile.figure == Drop.figure(drop))
        #expect(tile.isOwed)
        #expect(tile.spoken == localized("record.ply", 3) + sep + Drop.cost(drop))
    }

    @Test("a position with several wrong moves counts them, and the last position is 现在 out loud")
    func theLastPositionIsNowOutLoud() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
        game.recordTried(Game.Ply.Tried(san: "Qh5", drop: 20, depth: 20, line: []), atPly: 2)
        game.recordTried(Game.Ply.Tried(san: "Ke2", drop: 30, depth: 20, line: []), atPly: 2)
        let tile = try #require(reading(game, at: 2).tiles.first)
        #expect(tile.times == 2, "one position, two wrong moves")
        #expect(tile.number == "2.", "the move nobody has played there yet still has a number")
        #expect(tile.spoken.hasPrefix(localized("record.now")), "and out loud it is 现在")
        #expect(tile.spoken.hasSuffix(localized("slips.wrong", 2)))
    }

    @Test("the row of wrong moves is led by ✕ for a refusal and by a played mark for a move that stood")
    func theRowIsLedByWhatHappened() throws {
        #expect(reading(try reviewed(), at: 2).lead == .stood, "an imported game's 错招 was played")
        #expect(reading(try reviewed(), at: 3).lead == nil, "nothing to lead")

        var refused = try #require(Game(startFEN: PGN.standardStartFEN))
        refused.recordTried(Game.Ply.Tried(san: "Nh3", drop: 14.2, depth: 20, line: ["e5"]), atPly: 0)
        let read = reading(refused, at: 0)
        #expect(read.lead == .returned)
        #expect(read.lead?.spoken == localized("noSlips.returned"))
        #expect(read.opening.mark == .owed, "and the opening cell wears the mark for it")
        #expect(read.opening.spoken.hasSuffix(localized("record.slipMark", 14)))
    }

    @Test("a move on a fork says which line it is")
    func aForkSaysWhichLine() {
        let twig = Game.Half(ply: 3, san: "Nf3", isTrunk: false, branchNumber: 2, siblingCount: 2)
        #expect(twig.spoken == localized("screen.spokenMove", 3, "Nf3") + sep + localized("record.twig", 2, 2))
        let trunk = Game.Half(ply: 3, san: "Bc4", isTrunk: true, branchNumber: 1, siblingCount: 2)
        #expect(trunk.spoken.hasSuffix(localized("record.trunk", 1, 2)))
        #expect(Game.Half(ply: 1, san: "e4").spoken == localized("screen.spokenMove", 1, "e4"),
                "and a move nobody forked at is only its place")
    }

    @Test("a finished game's bar says who won instead of a score")
    func aFinishSaysWhoWon() {
        #expect(Finish.won(.white).label == localized("standing.won", PieceColour.white.label))
        #expect(Finish.drawn.label == localized("standing.drawn"))
    }
}
