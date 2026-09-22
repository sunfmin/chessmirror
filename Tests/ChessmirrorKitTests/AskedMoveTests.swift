import ChessmirrorKit
import Foundation
import Testing
import ChessmirrorKitTesting

/// What 让引擎走 does, and how long the screen goes on asking about the pieces it read off a
/// photograph. Neither is visible in a picture — a press is a moment and the screenshots are of
/// states — so they are checked here.
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

    /// A position search that stays open until this test says otherwise.
    ///
    /// Every reader of a live position shares one bounded search, and it ends by itself at ten
    /// seconds or depth twenty (see `PositionSearches`) — so the button a thumb holds is watching
    /// a search that will finish without it. A test that wants to watch one mid-flight has to be
    /// the one that ends it, which is what this hands back.
    private func heldSearch(
        at fen: String
    ) -> (
        stream: AsyncStream<Analysis>, continuation: AsyncStream<Analysis>.Continuation,
        control: @Sendable (Game, SearchBudget) -> AsyncStream<Analysis>?
    ) {
        let made = AsyncStream<Analysis>.makeStream()
        let control: @Sendable (Game, SearchBudget) -> AsyncStream<Analysis>? = { game, _ in
            game.state.fen == fen ? made.stream : nil
        }
        return (made.stream, made.continuation, control)
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
    /// It is the same bounded search everything else reads, so it also has an end of its own.
    @Test("holding the engine button starts a search that reports how far it has got")
    func holdingReports() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let held = heldSearch(at: game.state.fen)
        let session = try session(ScriptedEngine(Self.searching, controlled: held.control))

        let hold = Task { await session.holdForMove() }
        await hop()
        held.continuation.yield(Self.searching[0])
        held.continuation.yield(Self.searching[1])
        await hop()

        #expect(session.isThinking)
        #expect(session.searchProgress?.depth == 26, "the deepest snapshot so far")
        #expect(session.searchProgress?.selectiveDepth == 34)
        #expect(session.searchProgress?.seconds == 2.4)
        #expect(session.game.plies.count == 8, "nothing is played while it is being held")

        // Ten seconds or depth twenty ends it, thumb or no thumb, and the move it was asked for
        // is played: a press that has stopped waiting for anything is a press that has finished.
        held.continuation.finish()
        let move = await hold.value
        #expect(!session.isThinking)
        #expect(session.game.plies.count == 9)
        #expect(move?.uci == "d2d4")
    }

    /// Letting go plays what it found, for whichever colour was on the clock. Letting go of
    /// this one call is cancelling it — there is no second call to forget to pair with it.
    @Test("letting go plays the move the search settled on")
    func lettingGoPlays() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let held = heldSearch(at: game.state.fen)
        let session = try session(ScriptedEngine(Self.searching, controlled: held.control))

        let hold = Task { await session.holdForMove() }
        await hop()
        held.continuation.yield(Self.searching[1])
        await hop()
        hold.cancel()
        let move = await hold.value

        #expect(session.game.plies.count == 9, "letting go plays at once")
        #expect(move?.uci == "d2d4")
        #expect(!session.isThinking)
    }

    /// A press is a drag that keeps reporting, and the button hears it before it hears itself.
    @Test("a press that reports twice still only starts one search")
    func pressingTwiceAsksOnce() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let held = heldSearch(at: game.state.fen)
        let engine = ScriptedEngine(Self.searching, controlled: held.control)
        let session = try session(engine)

        async let first = session.holdForMove()
        async let second = session.holdForMove()
        await hop()

        #expect(engine.searchCount == 1, "one thumb, one search")
        #expect(session.isThinking)
        held.continuation.finish()
        _ = await first
        _ = await second
    }

    /// A tap is a press let go of before the engine has said a word, and it still moves.
    @Test("a tap plays the move the board was already recommending")
    func tapPlaysTheArrow() async throws {
        let session = try session(ScriptedEngine(Self.searching, isEndless: true))
        // A standing Analysis, arrived at the one way the screen gets one: a card asked for it
        // (docs/adr/0040), while it is the player's move.
        session.adviseForCard()
        await hop()
        #expect(session.analysis?.bestMove == "d2d4", "the arrow on the board")

        let hold = Task { await session.holdForMove() }
        hold.cancel()
        let move = await hold.value

        #expect(move?.uci == "d2d4")
        #expect(session.game.plies.count == 9)
    }

    /// The two searches are told apart, and this is the fact the screen leans on: it chooses
    /// between two different buttons by asking *whose* move is being walked, so a thumb's search
    /// must not read as the engine's own. Reading "is a search running" instead swapped 让引擎走 for
    /// 马上走 on the first instant of a press — and a button taken out from under a finger is never
    /// let go of, so the press ran on with nobody holding it and played nothing.
    @Test("a search a thumb asked for is not the engine walking a move of its own")
    func askedIsNotTheEnginesOwn() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let held = heldSearch(at: game.state.fen)
        let session = try session(ScriptedEngine(Self.searching, controlled: held.control))

        let hold = Task { await session.holdForMove() }
        await hop()
        held.continuation.yield(Self.searching[1])
        await hop()

        #expect(session.thinking == .asked)
        #expect(session.thinking != .own, "so 让引擎走 stays on screen under the thumb holding it")

        // 马上走 ends the engine's own move and plays what that search had. Turned on an Asked
        // Move it would take the search down and play nothing — which is what a hold that had
        // nothing left to release used to leave behind.
        session.moveNow()

        #expect(session.thinking == .asked, "stopping the engine's clock is not stopping a thumb")
        #expect(session.game.plies.count == 8, "and nothing is played behind the thumb's back")

        hold.cancel()
        let move = await hold.value

        #expect(session.game.plies.count == 9, "the press still ends where a press ends: a move")
        #expect(move?.uci == "d2d4")
    }

    /// The other kind. This is the one 马上走 is for, and cutting it short plays what it had.
    @Test("the engine's own move is the other kind of thinking, and 马上走 is what ends it")
    func theEnginesOwnMoveIsCutShort() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let held = heldSearch(at: game.state.fen)
        let session = GameSession.fresh(game, controllers: [.white: .engine, .black: .hand])
        session.attach(engine: ScriptedEngine(Self.searching, controlled: held.control), library: nil)
        session.retune()
        await hop()
        held.continuation.yield(Self.searching[1])
        await hop()

        #expect(session.thinking == .own, "it is walking a move it took on itself")
        #expect(!session.canPlayBestMove, "so there is no second button asking for the same move")

        session.moveNow()

        #expect(session.thinking == nil)
        #expect(session.game.plies.count == 9, "and it plays what it liked best when it was stopped")
        #expect(session.game.plies.last?.san == "d4")
    }

    /// The strip hides what the engine thinks, not what it is doing.
    @Test("a search asked for reports its progress but not its opinion")
    func aHeldSearchKeepsTheStopwatch() async throws {
        let session = try session(ScriptedEngine(Self.searching, isEndless: true))

        let hold = Task { await session.holdForMove() }
        await hop()

        #expect(session.searchProgress?.depth == 26)
        #expect(session.analysis == nil, "no Score reaches the screen while practising")

        hold.cancel()
        _ = await hold.value
    }

    /// A hold is one call whose lifetime is the thumb's: the screen going away lets go of it,
    /// which is what stops a press running on with nobody holding it. The move it had is played
    /// on the way out — a press is a request for a move, and the screen leaving is not a reason
    /// to forget it (`suspend` is what plays it, and `commit` starts no weighing of its own).
    @Test("the screen going away lets go of a hold instead of leaving it running")
    func theScreenGoingLetsGoOfTheHold() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let held = heldSearch(at: game.state.fen)
        let session = try session(ScriptedEngine(Self.searching, controlled: held.control))

        let hold = Task { await session.holdForMove() }
        await hop()
        held.continuation.yield(Self.searching[1])
        await hop()
        #expect(session.isThinking, "the thumb is still down")

        session.disappear()
        let move = await hold.value

        #expect(!session.isThinking, "nothing is left thinking for a board nobody is looking at")
        #expect(!session.isSearching)
        #expect(move?.uci == "d2d4", "and what the thumb was asking for is what it gets")
    }

    /// A game read off a photograph goes on offering the editor for as long as it exists, saved
    /// and reopened included: the thing most likely to be wrong about such a game is a piece, and
    /// finding that out ten moves later is the normal case (docs/adr/0028). A game that came out
    /// of a file nobody photographed has nothing to correct, so it never asks.
    @Test("a photographed game keeps offering the pieces back; an imported one never asks")
    func onlyAPhotographAsksAboutItsPieces() throws {
        let fen = "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/2P2N2/PP1P1PPP/RNBQK2R w KQkq - 0 5"
        let game = try #require(Game(startFEN: fen))
        let shaky: Set<Square> = [Square("c6")!, Square("f6")!]

        let fresh = GameSession.recognised(game, shaky: shaky)
        #expect(fresh.canEditPosition)
        #expect(fresh.unconfirmedSquares == shaky)

        // Saved and opened again: the origin travels in the file, and so does the offer.
        let reopened = try #require(GameSession.opened(GameLibrary.Entry(
            url: URL(filePath: "/games/chessmirror-photo.pgn"),
            pgn: PGN(game: game, tags: [
                PGN.Tag(GameOrigin.tagName, GameOrigin.recognised.rawValue)
            ]),
            modified: Date(timeIntervalSince1970: 1_786_000_000)
        )))
        #expect(reopened.canEditPosition, "a photograph is still a photograph after it is saved")

        // The rings go once a move is played — by then the position has been accepted in practice —
        // but the way back to the editor does not.
        let move = try #require(reopened.viewed.state.legalMoves.first)
        reopened.play(move)
        #expect(reopened.unconfirmedSquares.isEmpty)
        #expect(reopened.canEditPosition)

        let imported = try #require(GameSession.opened(GameLibrary.Entry(
            url: URL(filePath: "/games/somebody-elses.pgn"),
            pgn: PGN(game: game, tags: [
                PGN.Tag(GameOrigin.tagName, GameOrigin.imported.tagValue)
            ]),
            modified: Date(timeIntervalSince1970: 1_786_000_000)
        )))
        #expect(!imported.canEditPosition)
        #expect(imported.unconfirmedSquares.isEmpty)
    }
}
