@testable import ChessmirrorKit
import Foundation
import Testing

/// Contract: one walk of a Game feeds two readings of the player's mistakes, and which moves
/// count as wrong is a **gate's** question, named and written in one place (`Gate`). The 错题本
/// admits a move that stood only when a Review measured it (docs/adr/0016); one game's own record
/// admits whatever measured it (docs/adr/0036). They are meant to differ — a caller comparing a
/// `Slip` with an `Encounter` should not have to re-derive why.
@Suite struct GateTests {
    /// White plays Nf3 and it costs them. The game is Review'd so both gates have a depth-uniform
    /// number to read; the 判决 is written on the last move only.
    ///
    /// A drop is a **win-probability** difference (docs/adr/0027), so the swing has to be hundreds
    /// of centipawns to cross a 记录线 of ten: `0 → +200 → 0 → -300` makes Nf3 the only move that
    /// costs anybody anything.
    private func reviewed() throws -> Game {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3"]))
        game.setJudgement(.init(drop: 14, score: .centipawns(-300), depth: 20), atPly: 2)
        game.applyReview(
            [.centipawns(200), .centipawns(0), .centipawns(-300)],
            startEvaluation: .centipawns(0), depth: 16
        )
        return game
    }

    /// A move 把关 took back is wrong under both gates: it is a fact about the position either way.
    /// The gates differ only on the move that *stood*.
    @Test func aRefusedMoveIsWrongUnderBothGates() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
        game.setPendingTried([.init(san: "f3", drop: 24)], atPly: game.plies.count)
        let stops = game.stops(by: [.white, .black])
        #expect(stops.count == 2, "e4 stood, and the refusals wait at the position it made")

        let book = stops.flatMap { Gate.book.wrong(at: $0, in: game, lines: .standard) }
        let record = stops.flatMap { Gate.record.wrong(at: $0, in: game, lines: .standard) }
        #expect(book.map(\.san) == ["f3"])
        #expect(record.map(\.san) == ["f3"])
    }

    /// A move that stood, with nothing measured it: neither gate admits it. An unreviewed game
    /// is not a game with nothing wrong in it, it is a game nobody has looked at (docs/adr/0016).
    @Test func theBookAdmitsAStoodMoveOnlyWhenAReviewMeasuredIt() throws {
        let unreviewed = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3"]))
        let stops = unreviewed.stops(by: [.white, .black])
        #expect(stops.count == 3, "one stop per move the player made")
        #expect(
            stops.flatMap { Gate.book.wrong(at: $0, in: unreviewed, lines: .standard) }.isEmpty,
            "no Review, nothing the book may compare across games"
        )
        #expect(
            stops.flatMap { Gate.record.wrong(at: $0, in: unreviewed, lines: .standard) }.isEmpty,
            "and nothing measured it either"
        )
    }

    /// The same game, Review'd and with a 判决 on the move. Both gates see it now — the book by
    /// the Review's number (docs/adr/0016), this game's own record by whatever measured it
    /// (docs/adr/0036).
    @Test func aStoodMovePassesBothGatesByTheirOwnNumbers() throws {
        let game = try reviewed()
        let stops = game.stops(by: [.white, .black])
        #expect(stops.count == 3)

        let record = stops.flatMap { Gate.record.wrong(at: $0, in: game, lines: .standard) }
        #expect(record.map(\.san) == ["Nf3"], "this game's own account of itself, by the 判决's 14")

        let book = stops.flatMap { Gate.book.wrong(at: $0, in: game, lines: .standard) }
        #expect(book.map(\.san) == ["Nf3"], "and the Review's 20 admits it to the book")
    }

    /// A 惩罚 exercise that already wrote the move down is not counted a second time by the book
    /// — the rule that used to be spelled out at the book's call site, now part of what `book`
    /// means. The record gate has no such rule and still says what this game holds.
    @Test func theBookDoesNotCountAMoveThePunishmentAlreadyWroteDown() throws {
        var game = try reviewed()
        game.setTried([.init(san: "Nf3", drop: 0, notFound: true)], atPly: 2)
        let stops = game.stops(by: [.white, .black])

        #expect(
            stops.flatMap { Gate.book.wrong(at: $0, in: game, lines: .standard) }.isEmpty,
            "the 惩罚 exercise already wrote it down; the book does not count it twice"
        )
        #expect(
            stops.flatMap { Gate.record.wrong(at: $0, in: game, lines: .standard) }.map(\.san) == ["Nf3"],
            "and this game's own record still holds the 判决"
        )
    }

    /// The gates are named apart so no reader takes one for the other.
    @Test func theTwoGatesAreNamedApart() {
        #expect(Gate.book != Gate.record)
    }
}
