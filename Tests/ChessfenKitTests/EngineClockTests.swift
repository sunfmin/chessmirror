import ChessfenKit
import Testing

/// How long the engine gets over a move it plays for a colour it controls, and what happens when
/// it holds both of them.
///
/// None of this is visible in a picture: a clock is a number handed to a search, and a game the
/// app plays against itself is a thing that happens over time rather than a state to photograph.
@MainActor
@Suite(.serialized)
struct EngineClock {
    /// The Italian, eight plies in, White to move — so whoever holds White is on the clock the
    /// moment the session is tuned.
    private static let italian = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6"]

    /// One search that answers and ends, which is what a bounded one does: the engine reports what
    /// it found and the stream finishes, and that is what makes it play the move.
    private static let searching = [
        Analysis(
            depth: 26,
            selectiveDepth: 34,
            lines: [
                Line(score: .centipawns(38), uciMoves: ["d2d4", "e5d4"], san: ["d4", "exd4"])
            ],
            timeMilliseconds: 2_400
        )
    ]

    private func session(
        _ engine: ScriptedEngine,
        controllers: [PieceColour: Controller],
        opinion: Bool = false,
        stint: Duration = .seconds(10)
    ) throws -> GameSession {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(game, controllers: controllers)
        // A Game starts with the engine's opinion off (docs/adr/0015), so the tests about what
        // the *advisory* search is asked for turn it on, the way a person would. Said before the
        // engine is attached, so it is one search that starts and not two.
        if opinion { session.setPractising(false) }
        // Ten seconds is the app's Stint; a test that waited one would be a test nobody runs.
        session.adviceStint = stint
        session.attach(engine: engine, library: nil)
        // What the screen does in `onAppear`, and what makes the engine start.
        session.retune()
        return session
    }

    /// The search runs in a task of its own, so what it was asked is known a hop later — which is
    /// exactly as true of the screen as it is of this test.
    private func hop() async {
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Nobody is on the clock, so nobody is playing: the app plays itself, at the clock it names.
    @Test("with both sides on the engine the app plays itself, three seconds a move")
    func selfPlayMovesOnItsOwn() async throws {
        let engine = ScriptedEngine(Self.searching)
        let session = try session(engine, controllers: [.white: .engine, .black: .engine])
        await hop()

        #expect(session.isSelfPlaying)
        #expect(session.thinkingTime == .fixed(seconds: 3))
        #expect(session.game.plies.count == 9, "nobody touched the board and it moved")
        #expect(session.game.plies.last?.san == "d4")
        #expect(
            engine.budgets.allSatisfy { $0 == .time(.seconds(3)) },
            "every move of a game with no player in it is played on the named clock"
        )
    }

    /// Against a person it is still Mirrored Time, and the second engine is what changes it.
    @Test("the clock is the mirror until the engine is playing itself")
    func theSecondEngineNamesAClock() async throws {
        let engine = ScriptedEngine(Self.searching, isEndless: true)
        let session = try session(engine, controllers: [.white: .engine, .black: .hand])
        await hop()

        #expect(session.thinkingTime == .mirrored)
        #expect(
            engine.budgets.last == .time(MirroredTime.opening),
            "nothing has been played by hand yet, so there is nothing to mirror"
        )

        session.setController(.engine, for: .black)
        await hop()

        #expect(session.thinkingTime == .fixed(seconds: 3))
        #expect(engine.budgets.last == .time(.seconds(3)))
    }

    /// A clock chosen by hand stands for both colours and both kinds of game.
    @Test("changing the clock takes effect on the move being thought about now")
    func changingTheClockRestartsTheSearch() async throws {
        let engine = ScriptedEngine(Self.searching, isEndless: true)
        let session = try session(engine, controllers: [.white: .engine, .black: .engine])
        await hop()
        #expect(engine.budgets.last == .time(.seconds(3)))

        session.setThinkingTime(.fixed(seconds: 10))
        await hop()

        #expect(session.thinkingTime == .fixed(seconds: 10))
        #expect(
            engine.budgets.last == .time(.seconds(10)),
            "the move being waited for is the one this is reached for because of"
        )
        #expect(session.isThinking, "and it is still that move being thought about")
        #expect(session.game.plies.count == 8)
    }

    /// The mirror needs somebody to mirror. Choosing it and then leaving the board to the engine
    /// says which clock it is really on rather than quietly meaning the opening second for ever.
    @Test("self-play overrules a standing choice of the mirror")
    func selfPlayOverrulesTheMirror() async throws {
        let engine = ScriptedEngine(Self.searching, isEndless: true)
        let session = try session(engine, controllers: [.white: .engine, .black: .hand])
        session.setThinkingTime(.fixed(seconds: 10))
        session.setThinkingTime(.mirrored)
        #expect(session.thinkingTime == .mirrored)

        session.setController(.engine, for: .black)
        await hop()

        #expect(session.thinkingTime == .fixed(seconds: 3))
        #expect(engine.budgets.last == .time(.seconds(3)))

        // And it is a refusal for as long as it applies, not a rewriting of what was chosen: the
        // mirror comes back the moment there is somebody to mirror.
        session.setController(.hand, for: .black)
        #expect(session.thinkingTime == .mirrored)
    }

    /// Browsing is where a machine game is paused: the engine only plays from the latest position.
    @Test("stepping back stops the engine playing itself, and coming back carries on")
    func steppingBackStopsSelfPlay() async throws {
        let engine = ScriptedEngine(Self.searching)
        let session = try session(
            engine, controllers: [.white: .engine, .black: .engine], opinion: true
        )
        await hop()
        #expect(session.game.plies.count == 9)

        session.step(by: -1)
        await hop()

        #expect(!session.isEngineTurn, "nothing is played from an earlier position")
        #expect(session.game.plies.count == 9)
        #expect(
            engine.budgets.last == .untilStopped,
            "what runs instead is the advice the position on screen deserves"
        )
    }

    /// What a search is for decides how many Lines it is asked for: choosing a move is one
    /// candidate, advice to a player is the three the panel has room for — and each extra
    /// line costs about as much as a Depth, so the distinction is the clock's worth.
    @Test("a move the engine plays for itself is one line; advice is three")
    func movePickingAsksForOneLine() async throws {
        let engine = ScriptedEngine(Self.searching)
        let session = try session(
            engine, controllers: [.white: .engine, .black: .engine], opinion: true
        )
        await hop()
        #expect(engine.lines.allSatisfy { $0 == 1 }, "a move only has to be one move")

        session.step(by: -1)
        await hop()
        #expect(engine.lines.last == 3, "what a player reads is the panel's candidates")
    }

    /// And with the opinion where a Game leaves it — off — that advisory search is not run at
    /// all. Not hidden: never started, so a phone does not deepen a search nobody is allowed to
    /// see the result of (docs/adr/0015).
    @Test("with the engine's opinion off, browsing starts no search at all")
    func silenceStartsNothing() async throws {
        let engine = ScriptedEngine(Self.searching)
        let session = try session(engine, controllers: [.white: .engine, .black: .engine])
        await hop()
        let playedItself = engine.searchCount

        session.step(by: -1)
        await hop()

        #expect(session.isPractising, "which is where a Game starts")
        #expect(engine.searchCount == playedItself, "nothing new was asked of the engine")
        #expect(session.analysis == nil, "and there is no number on the screen")
    }

    // ------------------------------------------------------------------- the Stint

    /// The advisory search used to deepen for as long as it was left alone, which on a phone put
    /// down on a table is for ever. It now runs a Stint and stops (docs/adr/0020).
    @Test("advice runs its Stint and then stops, keeping what it found")
    func adviceStopsAfterItsStint() async throws {
        let engine = ScriptedEngine(Self.searching, isEndless: true)
        let session = try session(
            engine, controllers: [.white: .hand, .black: .hand], opinion: true,
            stint: .milliseconds(40)
        )
        await hop()

        #expect(session.isAdviceSpent, "the clock ran out and took the search down with it")
        #expect(engine.searchCount == 1, "and nothing started another behind it")
        #expect(session.analysis?.bestMove == "d2d4", "what it found stays on the screen")
        #expect(session.searchProgress?.depth == 26, "and so does how far it got")
    }

    /// The search is still asked for unbounded, and that is the load-bearing part: the pause gate
    /// refuses an unbounded search while the app is away because it belongs to a screen somebody
    /// is looking at (docs/adr/0009). A Stint is a clock the session keeps, not a budget the
    /// engine is handed — a ten-second `movetime` would be admitted at that gate and held.
    @Test("a Stint is the session's clock, not a budget handed to the engine")
    func stintDoesNotBoundTheSearch() async throws {
        let engine = ScriptedEngine(Self.searching, isEndless: true)
        let session = try session(
            engine, controllers: [.white: .hand, .black: .hand], opinion: true,
            stint: .milliseconds(40)
        )
        await hop()

        #expect(session.isAdviceSpent)
        #expect(engine.budgets == [.untilStopped])

        session.adviseAgain()
        await hop()

        #expect(engine.searchCount == 2, "another Stint is another search")
        #expect(engine.budgets == [.untilStopped, .untilStopped])
        #expect(session.isAdviceSpent, "which has itself run out by now")
    }

    /// A Stint's clock is wound for one search, and every other way a search ends unwinds it. It
    /// used to be possible for the timer belonging to the advice a thumb interrupted to fire while
    /// that thumb's own search was running, and take the move down with it.
    @Test("a Stint's clock does not reach past the search it was wound for")
    func stintClockLetsGoOfAnAskedMove() async throws {
        let engine = ScriptedEngine(Self.searching, isEndless: true)
        let session = try session(
            engine, controllers: [.white: .hand, .black: .hand], opinion: true,
            stint: .milliseconds(60)
        )

        // Straight onto the button, while the advice is still inside its Stint.
        session.beginAskedMove()
        await hop()

        #expect(session.thinking == .asked, "the thumb's search is the one running")
        #expect(!session.isAdviceSpent, "and the clock it replaced is not still counting")
        #expect(session.game.plies.count == 8, "nothing was played out from under it")

        session.endAskedMove()

        #expect(session.game.plies.count == 9, "the press still ends in the move it asked for")
    }

    // ---------------------------------------------------------- a card's Stint

    /// Arriving at a card is the asking, even during Practice: the board stays silent, and the
    /// card is what the ten seconds are for. Without this, 走马灯 and 要害格 wait for a Review
    /// that Practice will not start.
    @Test("a card arriving during practice spends a Stint, and the walk can read that line")
    func aCardSpendsAStintDuringPractice() async throws {
        let engine = ScriptedEngine(Self.searching, isEndless: true)
        let session = try session(
            engine, controllers: [.white: .hand, .black: .hand],
            stint: .milliseconds(40)
        )
        await hop()
        #expect(session.isPractising)
        #expect(session.analysis == nil, "practice still starts no search of its own")
        #expect(session.viewedContinuation.isEmpty, "and there is no Review to read a line from")

        session.adviseForCard()
        await hop()

        #expect(engine.budgets.last == .untilStopped)
        #expect(engine.lines.last == 1, "a card walks one Line, not the old three-candidate panel")
        #expect(session.analysis?.bestMove == "d2d4")
        #expect(
            session.viewedContinuation == ["d4", "exd4"],
            "the card can walk what the Stint found"
        )
        #expect(session.isAdviceSpent)
    }

    /// A swipe onto another card of the same position is not a new question. What the engine
    /// already found stays, and the clock is not wound again.
    @Test("a card arriving while the engine is talking reuses what it already found")
    func aCardReusesAStintWhileTalking() async throws {
        let engine = ScriptedEngine(Self.searching, isEndless: true)
        let session = try session(
            engine, controllers: [.white: .hand, .black: .hand], opinion: true,
            stint: .milliseconds(40)
        )
        await hop()
        let before = engine.searchCount
        #expect(session.analysis != nil)

        session.adviseForCard()
        await hop()

        #expect(engine.searchCount == before, "the standing Analysis is this position's already")
        #expect(session.analysis?.bestMove == "d2d4")
    }

    /// Two cards, one position: the second swipe must not pay for the same search again.
    @Test("a second card on the same position does not spend another Stint")
    func aSecondCardReusesTheStint() async throws {
        let engine = ScriptedEngine(Self.searching, isEndless: true)
        let session = try session(
            engine, controllers: [.white: .hand, .black: .hand],
            stint: .milliseconds(40)
        )
        await hop()

        session.adviseForCard()
        await hop()
        let once = engine.searchCount
        #expect(once == 1)
        #expect(session.analysis?.bestMove == "d2d4")

        session.adviseForCard()
        await hop()
        #expect(engine.searchCount == once, "the same position, already paid for")
        #expect(session.analysis?.bestMove == "d2d4")
        #expect(session.searchProgress?.depth == 26, "the Depth the Stint reached stays with it")
    }

    /// A move the engine is walking is not advice, and a swipe must not take it off the clock.
    @Test("a card does not take the engine off a move it is walking")
    func aCardDoesNotInterruptTheEnginesMove() async throws {
        let engine = ScriptedEngine(Self.searching, isEndless: true)
        let session = try session(engine, controllers: [.white: .engine, .black: .hand])
        await hop()
        #expect(session.thinking == .own)
        let before = engine.searchCount

        session.adviseForCard()
        await hop()

        #expect(engine.searchCount == before, "the move is still the one being thought about")
        #expect(session.thinking == .own)
    }

    /// A Guess still being held is the player answering. The engine does not speak first, even
    /// if the card they are on is one that would otherwise spend a Stint.
    @Test("a card does not speak while a Guess is still being held")
    func aCardDoesNotSpeakOverAGuess() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let engine = ScriptedEngine(Self.searching, isEndless: true)
        let session = GameSession.fresh(game)
        session.adviceStint = .milliseconds(40)
        session.attach(engine: engine, library: nil)
        session.jump(toPly: 6)
        session.offer(try #require(session.viewed.state.move(matching: "d2d4")))
        #expect(session.guess != nil)
        let before = engine.searchCount

        session.adviseForCard()
        await hop()

        #expect(engine.searchCount == before)
        #expect(session.analysis == nil)
    }
}
