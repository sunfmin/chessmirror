import ChessfenKit
import Foundation
import Testing

/// What 让引擎走 does, and what filing a game stops the screen asking about. Neither is visible in a
/// picture — a press is a moment and the screenshots are of states — so they are checked here.
@MainActor
@Suite(.serialized)
struct AskedMove {
    private static let italian = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6"]

    private static let searching = [
        Analysis(
            depth: 12,
            selectiveDepth: 17,
            lines: [
                Line(score: .centipawns(24), uciMoves: ["b1a3"], san: ["Na3"])
            ],
            timeMilliseconds: 300
        ),
        Analysis(
            depth: 26,
            selectiveDepth: 34,
            lines: [
                Line(score: .centipawns(38), uciMoves: ["d2d4", "e5d4"], san: ["d4", "exd4"])
            ],
            timeMilliseconds: 2_400
        ),
    ]

    private func session(_ engine: ScriptedEngine) throws -> GameSession {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        return session
    }

    /// The search runs in a task of its own, so what it has reported is known a hop later — which is
    /// exactly as true of the screen as it is of this test.
    private func hop() async {
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Held time is thinking time: the search runs while the button is down and reports as it goes.
    @Test("holding the engine button starts a search that reports how far it has got")
    func holdingReports() async throws {
        let session = try session(ScriptedEngine(Self.searching, isEndless: true))

        session.beginAskedMove()
        await hop()

        #expect(session.isThinking)
        #expect(session.searchProgress?.depth == 26, "the deepest snapshot so far")
        #expect(session.searchProgress?.selectiveDepth == 34)
        #expect(session.searchProgress?.seconds == 2.4)
        #expect(session.game.plies.count == 8, "nothing is played while it is being held")
    }

    /// Letting go plays what it found, for whichever colour was on the clock.
    @Test("letting go plays the move the search settled on")
    func lettingGoPlays() async throws {
        let session = try session(ScriptedEngine(Self.searching, isEndless: true))

        session.beginAskedMove()
        await hop()
        session.endAskedMove()

        #expect(session.game.plies.count == 9, "letting go plays at once")
        #expect(session.game.plies.last?.san == "d4")
        #expect(!session.isThinking)
    }

    /// A press is a drag that keeps reporting, and the button hears it before it hears itself.
    @Test("a press that reports twice still only starts one search")
    func pressingTwiceAsksOnce() async throws {
        let engine = ScriptedEngine(Self.searching, isEndless: true)
        let session = try session(engine)

        session.beginAskedMove()
        session.beginAskedMove()
        await hop()

        #expect(engine.searchCount == 1, "one thumb, one search")
        #expect(session.isThinking)
    }

    /// A tap is a press let go of before the engine has said a word, and it still moves.
    @Test("a tap plays the move the board was already recommending")
    func tapPlaysTheArrow() async throws {
        let session = try session(ScriptedEngine(Self.searching, isEndless: true))
        // A standing Analysis, arrived at the way the screen gets one: somebody has turned the
        // engine's opinion on — a Game starts without it — and it is advising while it is the
        // player's move.
        session.setPractising(false)
        session.retune()
        await hop()
        #expect(session.analysis?.bestMove == "d2d4", "the arrow on the board")

        session.beginAskedMove()
        session.endAskedMove()

        #expect(session.game.plies.count == 9)
        #expect(session.game.plies.last?.san == "d4")
    }

    /// The two searches are told apart, and this is the fact the screen leans on: it chooses
    /// between two different buttons by asking *whose* move is being walked, so a thumb's search
    /// must not read as the engine's own. Reading "is a search running" instead swapped 让引擎走 for
    /// 马上走 on the first instant of a press — and a button taken out from under a finger is never
    /// let go of, so the press ran on with nobody holding it and played nothing.
    @Test("a search a thumb asked for is not the engine walking a move of its own")
    func askedIsNotTheEnginesOwn() async throws {
        let session = try session(ScriptedEngine(Self.searching, isEndless: true))

        session.beginAskedMove()
        await hop()

        #expect(session.thinking == .asked)
        #expect(session.thinking != .own, "so 让引擎走 stays on screen under the thumb holding it")

        // 马上走 ends the engine's own move and plays what that search had. Turned on an Asked
        // Move it would take the search down and play nothing — which is what a hold that had
        // nothing left to release used to leave behind.
        session.moveNow()

        #expect(session.thinking == .asked, "stopping the engine's clock is not stopping a thumb")
        #expect(session.game.plies.count == 8, "and nothing is played behind the thumb's back")

        session.endAskedMove()

        #expect(session.game.plies.count == 9, "the press still ends where a press ends: a move")
        #expect(session.game.plies.last?.san == "d4")
    }

    /// The other kind. This is the one 马上走 is for, and cutting it short plays what it had.
    @Test("the engine's own move is the other kind of thinking, and 马上走 is what ends it")
    func theEnginesOwnMoveIsCutShort() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(game, controllers: [.white: .engine, .black: .hand])
        session.attach(engine: ScriptedEngine(Self.searching, isEndless: true), library: nil)
        session.retune()
        await hop()

        #expect(session.thinking == .own, "it is walking a move it took on itself")
        #expect(!session.canPlayBestMove, "so there is no second button asking for the same move")

        session.moveNow()

        #expect(session.thinking == nil)
        #expect(session.game.plies.count == 9, "and it plays what it liked best when it was stopped")
        #expect(session.game.plies.last?.san == "d4")
    }

    /// Practice hides what the engine thinks, not what it is doing.
    @Test("a search asked for while practising reports its progress but not its opinion")
    func practisingKeepsTheStopwatch() async throws {
        let session = try session(ScriptedEngine(Self.searching, isEndless: true))
        session.setPractising(true)

        session.beginAskedMove()
        await hop()

        #expect(session.searchProgress?.depth == 26)
        #expect(session.analysis == nil, "no Score reaches the screen while practising")
    }

    /// A game somebody has filed has been looked at and kept, so the screen stops asking about the
    /// pieces it once was not sure of.
    @Test("filing a game into a collection puts the piece question to rest")
    func filedGameStopsAsking() throws {
        let fen = "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/2P2N2/PP1P1PPP/RNBQK2R w KQkq - 0 5"
        let game = try #require(Game(startFEN: fen))
        let shaky: Set<Square> = [Square("c6")!, Square("f6")!]

        let unfiled = GameSession.recognised(game, shaky: shaky)
        #expect(unfiled.canEditPosition)
        #expect(unfiled.unconfirmedSquares == shaky)

        // Filed is a property of a saved game: the collection is written into the file.
        let filed = try #require(GameSession.opened(GameLibrary.Entry(
            url: URL(filePath: "/games/chessfen-filed.pgn"),
            pgn: PGN(game: game, tags: [
                PGN.Tag(GameOrigin.tagName, GameOrigin.recognised.rawValue),
                PGN.Tag("Event", "西西里防御"),
            ]),
            modified: Date(timeIntervalSince1970: 1_786_000_000)
        )))
        #expect(!filed.canEditPosition)
        #expect(filed.unconfirmedSquares.isEmpty)
        // And filing survives the next move being written: `pgn` must not file it back out.
        #expect(filed.pgn.tag("Event") == "西西里防御")
    }
}
