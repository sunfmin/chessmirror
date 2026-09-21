@testable import ChessmirrorKit
import Foundation
import Testing

/// Contract: what a tap on the board means is the session's answer, given the square already
/// held. It used to be the screen's, and so a thing only a finger on a simulator could check.

private func square(_ name: String) throws -> Square { try #require(Square(name)) }

@MainActor
@Suite struct BoardTapTests {
    /// A piece of the side to move is picked up; tapping one of its destinations plays there.
    @Test("a piece is picked up and put down on its square")
    func pickThenPlay() throws {
        let session = GameSession.fresh(try #require(Game(startFEN: PGN.standardStartFEN)))
        #expect(session.tap(try square("e2"), holding: nil) == .pick(try square("e2")))
        #expect(Set(session.moves(holding: try square("e2")).map(\.to)) == [try square("e3"), try square("e4")])

        guard case .play(let move) = session.tap(try square("e4"), holding: try square("e2")) else {
            Issue.record("e4 is a destination of the pawn on e2"); return
        }
        #expect(move.uci == "e2e4")
        #expect(session.game.plies.isEmpty, "the tap only says what it means; playing is the caller's")
    }

    /// Another of the side's own pieces is a new pick, not a refusal: the player changed their
    /// mind about which piece to move.
    @Test("another own piece is picked up instead")
    func anotherOwnPieceIsAPick() throws {
        let session = GameSession.fresh(try #require(Game(startFEN: PGN.standardStartFEN)))
        #expect(session.tap(try square("g1"), holding: try square("e2")) == .pick(try square("g1")))
    }

    /// A tap nowhere the held piece can go puts it down with a refusal; with nothing held, the
    /// same tap is simply nothing — there was no move being attempted to refuse.
    @Test("a put-down is a refusal only when something was held")
    func dropIsRefusedOnlyWhenHolding() throws {
        let session = GameSession.fresh(try #require(Game(startFEN: PGN.standardStartFEN)))
        #expect(session.tap(try square("e5"), holding: try square("e2")) == .drop(refused: true))
        #expect(session.tap(try square("e5"), holding: nil) == .drop(refused: false))
        #expect(session.tap(try square("e7"), holding: nil) == .drop(refused: false), "not the side to move")
    }

    /// Four moves to one square are a promotion, and the piece to become is asked for rather
    /// than guessed.
    @Test("four moves to one square ask which piece")
    func promotionAsks() throws {
        let game = try #require(Game(startFEN: "4k3/P7/8/8/8/8/8/4K3 w - - 0 1"))
        let session = GameSession.fresh(game)
        guard case .promote(let moves) = session.tap(try square("a8"), holding: try square("a7")) else {
            Issue.record("a7-a8 is a promotion"); return
        }
        #expect(Set(moves.compactMap(\.promotion)) == [.queen, .rook, .bishop, .knight])
    }

    /// On the engine's turn the board is not for touching, and nothing held rings a destination.
    @Test("the engine's turn ignores the board")
    func notTheHandsTurn() throws {
        let session = GameSession.fresh(
            try #require(Game(startFEN: PGN.standardStartFEN)),
            controllers: [.white: .engine, .black: .hand]
        )
        #expect(session.tap(try square("e2"), holding: nil) == .ignored)
        #expect(session.moves(holding: try square("e2")).isEmpty)
    }
}

/// Contract: every board in the app is seen from one chair per record, and the chair names the
/// colour at each edge.
@Suite struct OrientationTests {
    @Test("the chair names the colour at each edge")
    func edges() {
        #expect(Orientation.whiteAtBottom.bottom == .white)
        #expect(Orientation.whiteAtBottom.top == .black)
        #expect(Orientation.blackAtBottom.bottom == .black)
        #expect(Orientation.facing(.black).top == .white)
    }

    /// The shelf and the opened game read the chair off the same record: the player's side when
    /// it names one, the side to move at the start when it does not. The thumbnail used to draw
    /// every unnamed record from White, and opening one that began with Black to move turned it.
    @Test("a record is read from the player's side, or from the side that starts")
    func aRecordsChair() throws {
        let blackStarts = try #require(Game(startFEN: "4k3/8/8/8/8/8/8/4K3 b - - 0 1"))
        #expect(PGN(game: blackStarts).orientation == .blackAtBottom, "nobody named: the side that starts")

        let whiteStarts = try #require(Game(startFEN: PGN.standardStartFEN))
        let engineHadWhite = PGN(
            game: whiteStarts, seats: [.white: .engine, .black: .hand], origin: .fresh, lines: .standard
        )
        #expect(engineHadWhite.orientation == .blackAtBottom, "the player's side")
        let bothHands = PGN(
            game: whiteStarts, seats: [.white: .hand, .black: .hand], origin: .fresh, lines: .standard
        )
        #expect(bothHands.orientation == .whiteAtBottom)
    }
}
