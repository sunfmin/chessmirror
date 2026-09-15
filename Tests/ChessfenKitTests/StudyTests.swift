import ChessfenKit
import Foundation
import Synchronization
import Testing

/// The one board as a study: browse back, answer, then be told (docs/adr/0015).
@MainActor
@Suite(.speaking(.chinese)) struct StudyTests {
    /// Four plies, so ply 3 is a real question with a real answer already in the file.
    private static let opening = ["e2e4", "e7e5", "g1f3", "b8c6"]

    private func game(_ moves: [String] = opening) throws -> Game {
        try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: moves))
    }

    private func session(_ engine: any Engine, moves: [String] = opening) throws -> GameSession {
        let session = GameSession.fresh(try game(moves))
        session.attach(engine: engine, library: nil)
        return session
    }

    /// The searches all run in tasks of their own, so their answers are known a hop later.
    private func hop() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func analysis(_ score: Score, best: (uci: String, san: String)? = nil) -> Analysis {
        Analysis(
            depth: 14,
            selectiveDepth: 18,
            lines: [
                Line(
                    score: score,
                    uciMoves: best.map { [$0.uci] } ?? [],
                    san: best.map { [$0.san] } ?? []
                )
            ],
            nodes: 1_000_000,
            nodesPerSecond: 1_000_000,
            timeMilliseconds: 500
        )
    }

    /// A whole Line at one Depth, for the searches whose product is a line rather than a Score.
    private func line(_ score: Score, _ san: [String]) -> Analysis {
        Analysis(depth: 14, selectiveDepth: 18, lines: [Line(score: score, uciMoves: [], san: san)])
    }

    private func move(_ uci: String, in session: GameSession) throws -> Move {
        try #require(session.viewed.state.move(matching: uci))
    }

    // ---------------------------------------------------------------- a guess

    @Test("browsing back with the engine silent turns the board into a question")
    func browsingBackIsAStudy() throws {
        let session = try session(PositionalEngine([:]))
        #expect(!session.isStudying, "the latest position is a game, not a question")

        session.jump(toPly: 2)
        #expect(session.isStudying)
        #expect(session.guess == nil)
        #expect(session.reveal == nil)
        #expect(session.analysis == nil, "no Score, no arrow, no Lines")

        // With the opinion on, the same position is a position being read rather than asked.
        session.setPractising(false)
        #expect(!session.isStudying)
    }

    @Test("a move offered at a past ply goes on the board and not into the game")
    func offeringDoesNotPlay() throws {
        let session = try session(PositionalEngine([:]))
        session.jump(toPly: 2)
        let d4 = try move("d2d4", in: session)

        session.offer(d4)

        #expect(session.guess?.san == "d4")
        #expect(session.guess?.ply == 3)
        // On the board: the position being looked at is the one after the guess.
        #expect(session.viewed.plies.last?.san == "d4")
        // And not in the Game: the record still says Nf3, the file has not been written, and the
        // board is not taking a second answer.
        #expect(session.game.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6"])
        #expect(session.game.variations(atPly: 2).isEmpty)
        #expect(!session.isHandTurn)
    }

    @Test("taking a guess back leaves nothing behind, and so does moving the question")
    func withdrawingAndMovingOn() throws {
        let session = try session(PositionalEngine([:]))
        session.jump(toPly: 2)
        session.offer(try move("d2d4", in: session))

        session.withdrawGuess()
        #expect(session.guess == nil)
        #expect(session.viewed.plies.count == 2, "the board is back at the question")
        #expect(session.isHandTurn)

        // And a guess left standing goes away when the eye moves: the cursor is the question.
        session.offer(try move("d2d4", in: session))
        #expect(session.guess != nil)
        session.jump(toPly: 1)
        #expect(session.guess == nil)
        #expect(session.reveal == nil)
    }

    @Test("with the engine's opinion on, a move at a past ply is played, not offered")
    func opinionOnMeansTheOldBranching() throws {
        let session = try session(PositionalEngine([:]))
        session.setPractising(false)
        session.jump(toPly: 2)

        session.play(try move("d2d4", in: session))

        #expect(session.guess == nil, "nothing was being asked")
        #expect(session.game.plies[2].san == "d4", "it branched, the way it always has")
        #expect(session.game.variations(atPly: 2).first?.first?.san == "Nf3")
    }

    // ---------------------------------------------------------------- the reveal

    /// The scenario every reveal test uses: after 1. e4 e5 the engine likes Nf3 (+0.30); d4 is
    /// worth +0.10 and Qh5 is worth −4.00, and Nf3 as played comes out at +0.28.
    private func markedSession(
        guessing uci: String, because reason: Intent? = nil
    ) async throws -> GameSession {
        let before = try game(["e2e4", "e7e5"])
        let afterD4 = try game(["e2e4", "e7e5", "d2d4"])
        let afterQh5 = try game(["e2e4", "e7e5", "d1h5"])
        let afterNf3 = try game(["e2e4", "e7e5", "g1f3"])
        let engine = PositionalEngine([
            before.state.fen: analysis(.centipawns(30), best: ("g1f3", "Nf3")),
            afterD4.state.fen: analysis(.centipawns(10)),
            afterQh5.state.fen: analysis(.centipawns(-400)),
            afterNf3.state.fen: analysis(.centipawns(28)),
        ])
        let session = try session(engine)
        session.jump(toPly: 2)
        session.offer(try move(uci, in: session))
        // A Drill takes a reason as well as a move, so every fixture gives one.
        switch reason ?? .unclear {
        case .claim(let verb, let target):
            session.choose(verb)
            session.aim(at: target)
        case .unclear:
            session.declareUnclear()
        }
        session.commitGuess()
        await hop()
        return session
    }

    // ---------------------------------------------------------------- 五步计划

    /// One Intent over a line of the player's own, which is what docs/adr/0017 said an Intent should
    /// be able to be and what nothing was ever built for. The mirror of the carousel: that one shows
    /// the engine's plan landing, this one puts your own on trial.
    @Test("a plan is built on the board, judged over the whole line, and stored as a variation")
    func aPlanIsBuiltAndJudged() throws {
        let session = try session(PositionalEngine([:]))
        session.jump(toPly: 2)
        session.startPlan()
        let draft = try #require(session.planDraft)
        #expect(draft.ply == 2)
        #expect(session.showsControlChange, "the layer marks each step as the line is built")

        // Five moves of White's oldest plan there is — two pieces onto f7 — played on the board
        // and into no Game.
        for uci in ["f1c4", "g8f6", "g1f3", "b8c6", "f3g5"] {
            session.playInPlan(try #require(session.board.state.move(matching: uci)))
        }
        #expect(session.planDraft?.sans == ["Bc4", "Nf6", "Nf3", "Nc6", "Ng5"])
        #expect(
            session.board.plies.map(\.san) == ["e4", "e5", "Bc4", "Nf6", "Nf3", "Nc6", "Ng5"]
        )
        #expect(session.game.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6"], "and nothing yet")

        // The layer's second net is whatever the engine is showing from the tip, and this engine
        // shows nothing — so it is empty, and nothing pretends otherwise.
        #expect(session.boardContinuation.isEmpty)

        // One reason, over the whole line, declared the same way a Guess's is.
        #expect(!session.canCommitPlan, "a plan with no reason is not a plan")
        session.choose(.attack)
        session.aim(at: try #require(Square("f7")))
        #expect(session.canCommitPlan)
        session.commitPlan()

        #expect(session.planDraft == nil)
        let plan = try #require(session.game.plans(atPly: 2).first)
        #expect(plan.sans == ["Bc4", "Nf6", "Nf3", "Nc6", "Ng5"])
        #expect(plan.intent == .claim(.attack, try #require(Square("f7"))))
        // Judged by the same checker a one-move Intent uses, and told which move did it: two
        // pieces looking at f7 against one king is the fifth move of the plan, not its first.
        let check = try #require(session.planCheck)
        #expect(check.held)
        #expect(check.step == 5)
        #expect(check.san == "Ng5")
        // And where the line arrived, by the same reckoning the carousel uses.
        #expect(session.planOutcome?.steps == 5)
    }

    /// The whole of what docs/adr/0022 is about: the board is a place to try a line out, and the
    /// engine keeps five moves ahead of wherever you have got to.
    ///
    /// A blank five-move canvas was a wall — the player who could already write the line down did
    /// not need the feature. A frozen five-move line was a replay button. What is left is a board
    /// you can move on, five arrows that recompute after every move, and one reason you still owe.
    @Test("the engine shows five ahead, you walk, and it shows five ahead of that")
    func aPlanIsWalkedAndTheEngineKeepsUp() async throws {
        let before = try game(["e2e4", "e7e5"])
        let afterBc4 = try game(["e2e4", "e7e5", "f1c4"])
        let engine = PositionalEngine([
            before.state.fen: line(.centipawns(32), ["Bc4", "Nf6", "Nf3", "Nc6", "Ng5", "d5"]),
            afterBc4.state.fen: line(.centipawns(28), ["Nf6", "Nf3", "Nc6"]),
        ])
        let session = try session(engine)
        session.jump(toPly: 2)
        session.startPlan()
        #expect(session.isPlanning, "and it says so while the search runs")
        await hop()

        #expect(!session.isPlanning)
        // Five and not six: the cap is what makes a claim checkable, and a longer line is cut here.
        #expect(session.planDraft?.aheadSans == ["Bc4", "Nf6", "Nf3", "Nc6", "Ng5"])
        #expect(session.planDraft?.isEmpty == true, "nothing walked yet, so there is no plan yet")
        #expect(session.board.state.fen == session.viewed.state.fen)
        // One row per move, each read in the position it is played in — and the replies read from
        // their seat, because a plan whose answers are blank is a plan nobody checked.
        #expect(session.planNotes.map(\.san) == ["Bc4", "Nf6", "Nf3", "Nc6", "Ng5"])
        #expect(session.planNotes.map(\.isYours) == [true, false, true, false, true])
        #expect(session.planNotes.last?.intent == .claim(.attack, try #require(Square("f7"))))
        #expect(session.planArrows.map(\.step) == [1, 2, 3, 4, 5])

        // Walk one. The board moves, and the five are recomputed from where that leaves you.
        session.playInPlan(try #require(session.board.state.move(matching: "f1c4")))
        #expect(session.planDraft?.ahead.isEmpty == true, "stale arrows come down at once")
        #expect(session.planNotes.isEmpty)
        await hop()

        #expect(session.planDraft?.sans == ["Bc4"], "what you walked is the plan")
        #expect(session.board.plies.map(\.san) == ["e4", "e5", "Bc4"])
        #expect(session.planDraft?.aheadSans == ["Nf6", "Nf3", "Nc6"], "and five ahead of that")
        #expect(session.planNotes.map(\.san) == ["Nf6", "Nf3", "Nc6"])
        // One move in, the engine's five open with the opponent's reply — and 「你的」 goes on
        // meaning yours, or the board draws your own queen in the colour of a threat.
        #expect(session.planNotes.map(\.isYours) == [false, true, false])
        #expect(session.planArrows.map(\.isYours) == [false, true, false])

        // And the reason is still the player's, over what they walked, still judged.
        #expect(session.canCommitPlan == false, "a line walked is not yet a claim")
        session.choose(.hold)
        session.aim(at: try #require(Square("d5")))
        #expect(session.canCommitPlan)
        session.commitPlan()
        #expect(session.game.plans(atPly: 2).first?.sans == ["Bc4"], "what you played, not what was shown")
        #expect(session.planCheck?.held == true)
        #expect(session.planNotes.isEmpty)
    }

    /// Why the five stop being five unrelated suggestions.
    ///
    /// Measured against Stockfish, walking its own line four moves at depth 14: cleared between
    /// searches, the tail is rewritten at every step; left warm, each answer is the last one rolled
    /// forward one move. Nothing in a plan shows a Score, so nothing in it needs the Depth to be
    /// uncontaminated — and continuity is what makes it a plan (docs/adr/0022).
    @Test("looking ahead does not throw away what the last look-ahead learned")
    func theLookAheadKeepsItsTable() async throws {
        let before = try game(["e2e4", "e7e5"])
        let afterBc4 = try game(["e2e4", "e7e5", "f1c4"])
        let engine = PositionalEngine([
            before.state.fen: line(.centipawns(32), ["Bc4", "Nf6", "Nf3"]),
            afterBc4.state.fen: line(.centipawns(28), ["Nf6", "Nf3", "Nc6"]),
        ])
        let session = try session(engine)
        session.jump(toPly: 2)
        session.startPlan()
        await hop()
        session.playInPlan(try #require(session.board.state.move(matching: "f1c4")))
        await hop()

        #expect(session.planDraft?.aheadSans == ["Nf6", "Nf3", "Nc6"])
        #expect(engine.searchCount == 2, "one search a move, which is what it costs")
        #expect(engine.clearCount == 0, "and none of them starts by forgetting the last one")
    }

    @Test("tapping a row walks the board that far down the line")
    func aRowIsTheTransport() async throws {
        let before = try game(["e2e4", "e7e5"])
        let engine = PositionalEngine([
            before.state.fen: line(.centipawns(32), ["Bc4", "Nf6", "Nf3", "Nc6", "Ng5"])
        ])
        let session = try session(engine)
        session.jump(toPly: 2)
        session.startPlan()
        await hop()

        session.followPlan(through: 3)
        #expect(session.planDraft?.sans == ["Bc4", "Nf6", "Nf3"])
        #expect(session.board.plies.map(\.san) == ["e4", "e5", "Bc4", "Nf6", "Nf3"])
        #expect(session.planDraft?.ahead.isEmpty == true, "and it looks ahead again from there")
    }

    @Test("walking off the engine's line is allowed, and the next five are about where you went")
    func youCanLeaveTheEnginesLine() async throws {
        let before = try game(["e2e4", "e7e5"])
        let afterD4 = try game(["e2e4", "e7e5", "d2d4"])
        let engine = PositionalEngine([
            before.state.fen: line(.centipawns(32), ["Bc4", "Nf6", "Nf3"]),
            afterD4.state.fen: line(.centipawns(10), ["exd4", "Qxd4"]),
        ])
        let session = try session(engine)
        session.jump(toPly: 2)
        session.startPlan()
        await hop()

        // Not one of the five, and refused by nothing: deviating is the whole reason the board is
        // live rather than a replay button.
        session.playInPlan(try #require(session.board.state.move(matching: "d2d4")))
        await hop()
        #expect(session.planDraft?.sans == ["d4"])
        #expect(session.planDraft?.aheadSans == ["exd4", "Qxd4"])

        // And back out of it, which looks ahead again from where that leaves you.
        session.undoPlanMove()
        await hop()
        #expect(session.planDraft?.isEmpty == true)
        #expect(session.planDraft?.aheadSans == ["Bc4", "Nf6", "Nf3"])
    }

    @Test("exploring past five is free, and only 交卷 is not")
    func theCapIsAboutTheClaimAndNotTheWalk() async throws {
        let engine = PositionalEngine([:])
        let session = try session(engine)
        session.jump(toPly: 2)
        session.startPlan()
        for uci in ["f1c4", "g8f6", "g1f3", "b8c6", "f3g5", "d7d5"] {
            session.playInPlan(try #require(session.board.state.move(matching: uci)))
        }
        #expect(session.planDraft?.steps.count == 6, "walking on is exploring, and that is free")
        #expect(session.planDraft?.isTooLong == true)

        session.choose(.attack)
        session.aim(at: try #require(Square("f7")))
        #expect(!session.canCommitPlan, "but a claim over six plies cannot be told false")
        session.commitPlan()
        #expect(session.game.variations(atPly: 2).isEmpty)

        session.undoPlanMove()
        #expect(session.canCommitPlan)
        session.commitPlan()
        #expect(session.game.plans(atPly: 2).first?.steps == 5)
    }

    @Test("a search that comes back to find moves already on the board leaves them alone")
    func theEnginesLineNeverOverwritesYourOwn() async throws {
        let before = try game(["e2e4", "e7e5"])
        let engine = PositionalEngine([
            before.state.fen: line(.centipawns(30), ["Bc4", "Nf6"])
        ])
        let session = try session(engine)
        session.jump(toPly: 2)
        session.startPlan()
        // In before the answer is: the one thing on this screen that was the player's own.
        session.playInPlan(try #require(session.board.state.move(matching: "d2d4")))
        await hop()

        #expect(session.planDraft?.sans == ["d4"], "overtaken, and what was walked stands")
        #expect(
            session.planDraft?.aheadSans.isEmpty == true,
            "and the five that were about the old position are not drawn over the new one"
        )
    }

    @Test("no line from the engine is not a dead end: the board is still a board")
    func aPlanWithoutAnEngineIsStillAPlan() async throws {
        let session = try session(PositionalEngine([:]))
        session.jump(toPly: 2)
        session.startPlan()
        await hop()

        #expect(session.planDraft?.ahead.isEmpty == true)
        #expect(!session.isPlanning)
        session.playInPlan(try #require(session.board.state.move(matching: "d2d4")))
        #expect(session.planDraft?.sans == ["d4"])
        #expect(session.board.plies.map(\.san) == ["e4", "e5", "d4"])
    }

    @Test("nothing else gets to put a second hypothesis on the board while a plan is on it")
    func aPlanHoldsTheBoardAlone() async throws {
        let before = try game(["e2e4", "e7e5"])
        let engine = PositionalEngine([
            before.state.fen: Analysis(
                depth: 14,
                lines: [
                    Line(
                        score: .centipawns(30),
                        uciMoves: ["f1c4", "g8f6"], san: ["Bc4", "Nf6"]
                    )
                ]
            )
        ])
        let session = try session(engine)
        session.jump(toPly: 2)
        session.applyReview(
            [
                ReviewedPly(score: .centipawns(20), line: ["e5", "Nf3"]),
                ReviewedPly(score: .centipawns(25), line: ["Nf3", "Nc6"]),
                ReviewedPly(score: .centipawns(30), line: ["Nc6", "Bc4"]),
                ReviewedPly(score: .centipawns(28), line: ["Bc4", "Bc5"]),
            ],
            startEvaluation: nil,
            depth: 18
        )
        session.startPlan()
        await hop()
        #expect(session.planDraft?.aheadSans == ["Bc4", "Nf6"])

        // Refused rather than closed under them: a plan holds a reason somebody typed, and the two
        // arrows would point at two different lines.
        session.armScanner()
        #expect(!session.isScannerArmed)
        session.startWalk()
        #expect(session.walk == nil)
        #expect(session.planDraft?.aheadSans == ["Bc4", "Nf6"], "and the plan is where it was")

        // Both come back the moment the plan is put away.
        session.abandonPlan()
        session.armScanner()
        #expect(session.isScannerArmed)
    }

    @Test("a plan thrown away leaves nothing behind")
    func aPlanCanBeAbandoned() throws {
        let session = try session(PositionalEngine([:]))
        session.jump(toPly: 2)
        session.startPlan()
        session.playInPlan(try #require(session.board.state.move(matching: "d2d4")))
        session.choose(.hold)
        session.aim(at: try #require(Square("d4")))

        session.abandonPlan()
        #expect(session.planDraft == nil)
        #expect(session.declaredIntent == nil, "the reason goes with the line it was about")
        #expect(session.game.variations(atPly: 2).isEmpty)
        #expect(session.board.state.fen == session.viewed.state.fen)
    }

    @Test("there is no plan at the latest position, because there is no move to be one instead of")
    func aPlanNeedsAMoveToBranchFrom() throws {
        let session = try session(PositionalEngine([:]))
        #expect(session.isAtLatest)
        session.startPlan()
        #expect(session.planDraft == nil, "a line played here is the game, not a plan about it")
    }

    // ---------------------------------------------------------------- 走马灯

    /// The Line the Review already stored, played out on the main board. Nothing is written and no
    /// search is started: watching a plan happen is worth a picture, not a Stint (docs/adr/0020, 0021).
    private func reviewedSession(_ engine: any Engine) throws -> GameSession {
        let session = try session(engine)
        session.applyReview(
            [
                ReviewedPly(score: .centipawns(30), line: ["e5", "Nf3", "Nc6"]),
                ReviewedPly(score: .centipawns(20), line: ["Nf3", "Nc6", "Bb5"]),
                ReviewedPly(score: .centipawns(25), line: ["Nc6", "Bb5", "a6"]),
                ReviewedPly(score: .centipawns(22), line: ["Bb5", "a6", "Ba4"]),
            ],
            startEvaluation: nil,
            depth: 18
        )
        return session
    }

    @Test("the stored line plays out on the board, and the game never hears about it")
    func theCarouselPlaysTheStoredLine() throws {
        let engine = PositionalEngine([:])
        let session = try reviewedSession(engine)
        session.jump(toPly: 2)

        session.startWalk()
        let walk = try #require(session.walk)
        #expect(walk.line == ["Nf3", "Nc6", "Bb5"], "the line the Review stored, not a new one")
        #expect(walk.isAtStart)
        #expect(session.board.state.fen == session.viewed.state.fen, "step 0 is where it started")
        #expect(session.showsControlChange, "and the layer comes on with it")
        #expect(session.walkArrows.map(\.step) == [1, 2, 3], "the arrows are the line, numbered")
        #expect(session.walkArrows.map(\.isYours) == [true, false, true])
        #expect(session.walkArrows.first?.move.to == (try #require(Square("f3"))))

        session.stepWalk(by: 1)
        #expect(session.board.plies.map(\.san) == ["e4", "e5", "Nf3"])
        #expect(session.boardContinuation == ["Nc6", "Bb5"], "the layer reads what is still ahead")
        #expect(session.boardLastMove?.to == (try #require(Square("f3"))))

        session.stepWalk(by: 2)
        #expect(session.walk?.isAtEnd == true)
        #expect(session.board.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6", "Bb5"])
        // And none of it reached the Game: no ply, no Variation, no search.
        #expect(session.game.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6"])
        #expect(session.game.variations(atPly: 2).isEmpty)
        #expect(engine.searchCount == 0, "the line was already paid for")

        session.endWalk()
        #expect(session.walk == nil)
        #expect(session.board.state.fen == session.viewed.state.fen)
        #expect(session.boardContinuation == ["Nf3", "Nc6", "Bb5"])
    }

    @Test("a walk still on its first ply takes a longer Line as the search deepens")
    func aWalkOnTheFirstPlyTakesALongerLine() throws {
        let session = try reviewedSession(PositionalEngine([:]))
        session.jump(toPly: 2)
        session.startWalk(line: ["Nf3"])
        #expect(session.walk?.line == ["Nf3"])
        session.startWalk(line: ["Nf3", "Nc6", "Bb5"])
        #expect(session.walk?.line == ["Nf3", "Nc6", "Bb5"], "五步 does not freeze on the first snapshot")
        session.stepWalk(by: 1)
        session.startWalk(line: ["Nf3", "Nc6", "Bb5", "a6"])
        #expect(session.walk?.line == ["Nf3", "Nc6", "Bb5"], "a walk under way is not replaced")
    }

    @Test("the transport stops at both ends instead of wrapping")
    func theCarouselClampsAtBothEnds() throws {
        let session = try reviewedSession(PositionalEngine([:]))
        session.jump(toPly: 2)
        session.startWalk()

        session.stepWalk(by: 9)
        #expect(session.walk?.step == 3, "three plies in the line, and no fourth")
        session.stepWalk(by: -9)
        #expect(session.walk?.step == 0)
    }

    @Test("where the whole line arrived is said once, and is about the line and not the step")
    func theCarouselSaysWhereItArrived() throws {
        let session = try reviewedSession(PositionalEngine([:]))
        session.jump(toPly: 2)
        session.startWalk()
        let outcome = try #require(session.walk?.outcome)

        #expect(outcome.steps == 3)
        #expect(outcome.sentence.hasPrefix("3 步之后，"))
        // The same sentence at every step: it is about where the line ends up, and stepping through
        // it does not change where that is.
        session.stepWalk(by: 2)
        #expect(session.walk?.outcome == outcome)
    }

    @Test("with no line stored there is nothing to play, and nothing happens")
    func theCarouselNeedsALine() throws {
        let session = try session(PositionalEngine([:]))
        session.jump(toPly: 2)
        #expect(session.viewedContinuation.isEmpty)

        session.startWalk()
        #expect(session.walk == nil, "no line, no carousel — and no search to go and get one")
        #expect(!session.showsControlChange)
    }

    @Test("asking about a square, or moving the question, takes the carousel off the board")
    func theCarouselGoesWithTheQuestion() throws {
        let session = try reviewedSession(PositionalEngine([:]))
        session.jump(toPly: 2)
        session.startWalk()
        session.stepWalk(by: 1)

        // One hypothesis on the board at a time.
        session.armScanner()
        #expect(session.walk == nil)

        session.endScan()
        session.startWalk()
        session.stepWalk(by: 1)
        session.jump(toPly: 1)
        #expect(session.walk == nil)
        #expect(session.board.state.fen == session.viewed.state.fen)
    }

    // ---------------------------------------------------------------- the scanner

    /// The scanner is the one thing allowed to talk before a Guess is in, and it only ever talks
    /// about the square somebody pointed at (docs/adr/0015, 0021).
    @Test("pointing at a square answers about it, and the trial never reaches the game")
    func theScannerAnswersAboutOneSquare() throws {
        let engine = PositionalEngine([:])
        let session = try session(engine)

        // Nothing is being asked, so nothing is being answered.
        #expect(session.scan == nil)
        session.scan(at: try #require(Square("d4")))
        #expect(session.scan == nil, "and a tap on the board is not a question until it is armed")

        session.armScanner()
        session.scan(at: try #require(Square("d4")))
        let scan = try #require(session.scan)
        #expect(scan.arrivals.map(\.san) == ["d4", "Nd4"], "the pawn before the knight")

        session.tryOut(try #require(scan.arrivals.first?.move))
        let trial = try #require(session.trial)
        #expect(trial.san == "d4")
        // On the glass and nowhere else: the board draws it, the position being studied does not
        // know about it, and the Game is untouched.
        #expect(session.board.state.fen != session.viewed.state.fen)
        #expect(session.board.plies.map(\.san).last == "d4")
        #expect(session.viewed.plies.map(\.san).last == "Nc6")
        #expect(session.game.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6"])
        #expect(session.game.variations(atPly: 4).isEmpty)

        // And leaving restores the board exactly.
        session.endScan()
        #expect(session.scan == nil)
        #expect(session.trial == nil)
        #expect(session.board.state.fen == session.viewed.state.fen)
    }

    @Test("the engine says nothing about the scanned square until it is asked")
    func theScannerAsksTheEngineLast() async throws {
        let asked = try game()
        let engine = PositionalEngine([
            asked.state.fen: Analysis(
                depth: 14,
                selectiveDepth: 18,
                lines: [
                    Line(
                        score: .centipawns(30), uciMoves: ["f1c4"], san: ["Bc4", "Bc5", "c3"]
                    )
                ],
                nodes: 1_000_000,
                nodesPerSecond: 1_000_000,
                timeMilliseconds: 500
            )
        ])
        let session = try session(engine)
        session.armScanner()
        session.scan(at: try #require(Square("d4")))
        session.tryOut(try #require(session.scan?.arrivals.first?.move))
        await hop()

        // The order is the whole design: the trial's own assessment is on screen and the engine
        // has not been asked for anything.
        #expect(session.trial?.gains.isEmpty == false)
        #expect(session.scanAnswer == nil)
        #expect(engine.searchCount == 0, "no search at all, not a search whose answer was hidden")

        session.askEngine()
        await hop()

        let answer = try #require(session.scanAnswer)
        #expect(engine.searchCount == 1)
        #expect(answer.best == "Bc4")
        #expect(answer.depth == 14)
        #expect(answer.score == .centipawns(30))
        #expect(answer.isSameAsTrial == false)
        // And its reason is in the same seven verbs the trial's is.
        #expect(try #require(answer.reading).opening.san == "Bc4")
    }

    @Test("moving the question, or answering it, closes the scanner")
    func theScannerGoesWithTheQuestion() throws {
        let session = try session(PositionalEngine([:]))
        session.armScanner()
        session.scan(at: try #require(Square("d4")))
        session.tryOut(try #require(session.scan?.arrivals.first?.move))
        #expect(session.trial != nil)

        session.jump(toPly: 2)
        #expect(session.scan == nil, "a question about a square is a question about a position")
        #expect(session.trial == nil)
        #expect(!session.isScannerArmed)

        // And a Guess ends the asking, because a trial under a Guess is two hypotheses at once.
        session.armScanner()
        session.scan(at: try #require(Square("d4")))
        session.offer(try move("d2d4", in: session))
        #expect(session.guess?.san == "d4")
        #expect(session.scan == nil)
        #expect(!session.isScannerArmed)
    }

    /// The engine gives a number and a sequence of moves and never a reason. The Reveal carries the
    /// reason anyway, read out of that same sequence with the same rules code that judges the
    /// player's own claim — so 「我说的是攻 c5，引擎那步是为了攻 e5」 is a comparison and not a
    /// translation exercise (docs/adr/0021).
    @Test("the reveal carries what the engine's own move is for, in the same seven verbs")
    func theEnginesMoveIsTranslated() async throws {
        let before = try game(["e2e4", "e7e5"])
        let afterD4 = try game(["e2e4", "e7e5", "d2d4"])
        let engine = PositionalEngine([
            before.state.fen: Analysis(
                depth: 14,
                selectiveDepth: 18,
                lines: [
                    Line(
                        score: .centipawns(30),
                        uciMoves: ["g1f3"],
                        san: ["Nf3", "Nc6", "Bb5"]
                    )
                ],
                nodes: 1_000_000,
                nodesPerSecond: 1_000_000,
                timeMilliseconds: 500
            ),
            afterD4.state.fen: analysis(.centipawns(10)),
        ])
        let session = try session(engine)
        session.jump(toPly: 2)
        session.offer(try move("d2d4", in: session))
        session.declareUnclear()
        session.commitGuess()
        await hop()

        let reading = try #require(session.reveal?.bestReading)
        #expect(reading.opening.san == "Nf3")
        // The knight looks at e5 and nothing looks back. Bb5 is Black's problem and not White's
        // plan, so it is read and then dropped: 攻 c6 would need the knight to be outnumbered, and
        // b7 and d7 both guard it.
        #expect(reading.opening.intent == .claim(.attack, try #require(Square("e5"))))
        #expect(reading.sentence == "攻 e5")
        // And every verb it prints is one the checker would agree with, which is the property the
        // reading is built on rather than a coincidence of this fixture.
        let played = try #require(before.state.move(matching: "g1f3"))
        #expect(reading.opening.intent.check(played, in: before)?.held == true)
    }

    @Test("a good guess is shown against the engine's move and the one that was played")
    func aGuessInsideTheBand() async throws {
        let session = try await markedSession(guessing: "d2d4")
        let reveal = try #require(session.reveal)

        #expect(reveal.guess == "d4")
        #expect(reveal.best == "Nf3")
        #expect(reveal.played == "Nf3")
        #expect(reveal.guessScore == .centipawns(10))
        #expect(reveal.bestScore == .centipawns(30))
        #expect(reveal.playedScore == .centipawns(28))
        #expect(reveal.depth == 14, "and the Depth all three were computed at is named")
        #expect(reveal.mover == .white)

        // Twenty centipawns off the engine's move: inside the band, and the band is the same one
        // a Review grades a played move by.
        #expect(reveal.lost == 20)
        #expect(reveal.quality == .fine)
        #expect(reveal.counts == true)
        #expect(!reveal.isSameAsBest)
        #expect(!reveal.isSameAsPlayed)
        #expect(!session.isRevealing)
        // Still nothing in the Game: a marked guess is not a played move.
        #expect(session.game.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6"])
    }

    @Test("a bad guess is told it is bad, on the same scale a played move is judged by")
    func aGuessOutsideTheBand() async throws {
        let session = try await markedSession(guessing: "d1h5")
        let reveal = try #require(session.reveal)

        #expect(reveal.guess == "Qh5")
        #expect(reveal.lost == 430)
        #expect(reveal.quality == .blunder)
        #expect(reveal.counts == false)
    }

    @Test("guessing the move that was played says so, and is not searched twice")
    func guessingWhatWasPlayed() async throws {
        let session = try await markedSession(guessing: "g1f3")
        let reveal = try #require(session.reveal)

        #expect(reveal.guess == "Nf3")
        #expect(reveal.isSameAsPlayed)
        #expect(reveal.isSameAsBest)
        #expect(reveal.playedScore == reveal.guessScore, "one position, one number")
        #expect(reveal.counts == true)
    }

    @Test("a guess worth keeping becomes a branch, with the line it replaced beside it")
    func keepingAGuess() async throws {
        let session = try await markedSession(guessing: "d2d4")
        session.keepGuess()

        #expect(session.guess == nil)
        #expect(session.reveal == nil)
        #expect(session.game.plies[2].san == "d4")
        #expect(session.game.variations(atPly: 2).first?.map(\.san) == ["Nf3", "Nc6"])
        #expect(session.cursor == 3)
    }

    // ---------------------------------------------------------------- and why

    @Test("a claim is a verb and then a target, and neither alone will commit")
    func aClaimNeedsBoth() throws {
        let session = try session(PositionalEngine([:]))
        session.jump(toPly: 2)
        session.offer(try move("d2d4", in: session))
        #expect(!session.canCommitGuess, "a move with no reason is not an answer")

        session.choose(.hold)
        #expect(session.declaringVerb == .hold)
        #expect(session.declaredIntent == nil, "a verb with no target is not a claim yet")
        #expect(!session.canCommitGuess)

        session.aim(at: try #require(Square("d5")))
        #expect(session.declaredIntent == .claim(.hold, try #require(Square("d5"))))
        #expect(session.canCommitGuess)

        // And it can be changed right up until it is committed.
        session.choose(.defend)
        #expect(session.declaredIntent == nil)
        session.choose(nil)
        #expect(session.declaringVerb == nil)
    }

    @Test("说不清 is one tap, and it is a declaration like any other")
    func unclearIsOneTap() throws {
        let session = try session(PositionalEngine([:]))
        session.jump(toPly: 2)
        session.offer(try move("d2d4", in: session))

        session.declareUnclear()

        #expect(session.declaredIntent == .unclear)
        #expect(session.declaringVerb == nil, "nothing left half-chosen behind it")
        #expect(session.canCommitGuess)
    }

    @Test("committing writes the reason into the game, true or not")
    func theReasonIsWrittenDown() async throws {
        let session = try await markedSession(guessing: "d2d4", because: .claim(.hold, Square("d5")!))

        // The guess was not the move that was played, so it is written where a line that was not
        // played goes — with the reason on it.
        let variations = session.game.variations(atPly: 2)
        #expect(variations.count == 1)
        #expect(variations.first?.first?.san == "d4")
        #expect(variations.first?.first?.intent == .claim(.hold, Square("d5")!))
        // And the played move is untouched: nobody ever said that was why Nf3 was played.
        #expect(session.game.intent(atPly: 3) == nil)

        // It survives the file, which is the whole point of it being written at all.
        let reread = try PGN(parsing: session.pgn.text).game
        #expect(reread.variations(atPly: 2).first?.first?.intent == .claim(.hold, Square("d5")!))
    }

    @Test("a reason given for the move that was actually played lands on that move")
    func theReasonForAPlayedMove() async throws {
        let session = try await markedSession(guessing: "g1f3", because: .claim(.attack, Square("e5")!))

        #expect(session.game.intent(atPly: 3) == .claim(.attack, Square("e5")!))
        #expect(session.game.variations(atPly: 2).isEmpty, "nothing was left to one side")
    }

    @Test("the same question answered twice the same way leaves one line, not two")
    func answeringTwiceDoesNotDuplicate() async throws {
        let session = try await markedSession(guessing: "d2d4", because: .claim(.hold, Square("d5")!))
        session.withdrawGuess()
        session.offer(try move("d2d4", in: session))
        session.choose(.defend)
        session.aim(at: try #require(Square("d4")))
        session.commitGuess()
        await hop()

        #expect(session.game.variations(atPly: 2).count == 1)
        #expect(
            session.game.variations(atPly: 2).first?.first?.intent
                == .claim(.defend, Square("d4")!),
            "the second answer replaced the first rather than sitting beside it"
        )
    }

    @Test("the move and the reason are marked separately")
    func twoVerdictsNeverOne() async throws {
        // A good move for a reason that is not true: d4 is inside the band, and it takes nothing
        // on d4 — the commonest wrong reason of all, "I win something here" about a quiet move.
        let rightMove = try await markedSession(guessing: "d2d4", because: .claim(.take, Square("d4")!))
        let reveal = try #require(rightMove.reveal)
        #expect(reveal.counts == true, "the move is fine")
        #expect(reveal.intentCheck?.verdict == .failed, "and the reason is not")
        #expect(reveal.intent == .claim(.take, Square("d4")!))
        #expect(reveal.intentCheck?.note != nil, "with something about the board to look at")

        // A bad move for a true reason: Qh5 throws a queen at nothing, and it does attack e5.
        let rightReason = try await markedSession(guessing: "d1h5", because: .claim(.attack, Square("e5")!))
        let second = try #require(rightReason.reveal)
        #expect(second.counts == false)
        #expect(second.intentCheck?.verdict == .held)

        // 说不清 is marked as neither.
        let shrug = try await markedSession(guessing: "d2d4", because: .unclear)
        #expect(try #require(shrug.reveal).intentCheck?.verdict == .noClaim)
    }

    @Test("playing a kept guess for real carries the reason into the main line")
    func keepingCarriesTheReason() async throws {
        let session = try await markedSession(guessing: "d2d4", because: .claim(.hold, Square("d5")!))
        session.keepGuess()

        #expect(session.game.plies[2].san == "d4")
        #expect(session.game.intent(atPly: 3) == .claim(.hold, Square("d5")!))
        #expect(session.game.variations(atPly: 2).first?.map(\.san) == ["Nf3", "Nc6"])
    }

    // ---------------------------------------------------------------- the layers

    @Test("the layer showing what a move changed starts off, on every Game")
    func theChangeLayerStartsOff() throws {
        let session = try session(PositionalEngine([:]))
        #expect(!session.showsControlChange)

        session.setShowsControlChange(true)
        #expect(session.showsControlChange)

        // And the next position in a collection asks again, like the engine's opinion and for the
        // same reason.
        let entry = GameLibrary.Entry(
            url: URL(filePath: "/games/chessfen-layers.pgn"),
            pgn: PGN(game: try game(), tags: []),
            modified: Date(timeIntervalSince1970: 1_786_001_000)
        )
        let next = try #require(GameSession.opened(entry))
        #expect(!next.showsControlChange)
    }

    // ---------------------------------------------------------------- the pass

    @Test("turning the engine's opinion on is what gives a Game its uniform pass")
    func theSwitchStartsThePass() async throws {
        let engine = ScriptedEngine([analysis(.centipawns(30), best: ("g1f3", "Nf3"))])
        let session = try session(engine)
        #expect(!session.game.isReviewed)
        #expect(session.reviewPass == nil)

        session.setPractising(false)
        await hop()

        let pass = try #require(session.reviewPass)
        #expect(pass.depth == GameSession.reviewDepth)
        #expect(pass.total == 4)
        #expect(pass.completed == 4)
        #expect(!pass.isRunning)
        #expect(session.game.isReviewed)
        #expect(session.game.reviewDepth == GameSession.reviewDepth)
        #expect(session.game.criticality()?.count == 4, "and so the Game can now be ranked")
    }

    @Test("a Game that already has a pass is not made to sit through another")
    func areviewedGameIsLeftAlone() async throws {
        let engine = ScriptedEngine([analysis(.centipawns(30), best: ("g1f3", "Nf3"))])
        let session = try session(engine)
        session.applyReview(
            [.centipawns(20), .centipawns(15), .centipawns(25), .centipawns(20)],
            startEvaluation: .centipawns(10),
            depth: 22
        )

        session.setPractising(false)
        await hop()

        #expect(session.reviewPass == nil, "nothing was started")
        #expect(session.game.reviewDepth == 22, "and the Depth it was done at stands")
    }

    @Test("a pass reports how far it has got, and leaving stops it without writing anything")
    func leavingStopsThePass() async throws {
        let engine = HeldEngine(analysis(.centipawns(30), best: ("g1f3", "Nf3")))
        let session = try session(engine)

        session.setPractising(false)
        await hop()
        let running = try #require(session.reviewPass)
        #expect(running.isRunning)
        #expect(running.total == 4)
        #expect(!session.game.isReviewed, "not yet: half a pass is not half a Review")

        session.suspend()
        await hop()

        #expect(session.reviewPass == nil)
        #expect(!session.game.isReviewed, "and it wrote nothing on the way out")
        #expect(session.game.criticality() == nil)
    }

    @Test("a move played while a pass runs throws the pass away rather than writing it")
    func aMoveDuringThePassInvalidatesIt() async throws {
        let engine = HeldEngine(analysis(.centipawns(30), best: ("g1f3", "Nf3")))
        let session = try session(engine)
        session.setPractising(false)
        await hop()
        #expect(session.reviewPass?.isRunning == true)

        // Somebody browses back and plays something else: the game the pass is about is gone.
        session.jump(toPly: 2)
        session.play(try move("d2d4", in: session))
        engine.release()
        await hop()

        #expect(session.reviewPass == nil)
        #expect(!session.game.isReviewed)
    }

    @Test("the worst moves are reachable from the session, and only once there is a pass")
    func worstMovesAreTheQuestions() async throws {
        let engine = ScriptedEngine([analysis(.centipawns(30), best: ("g1f3", "Nf3"))])
        let session = try session(engine)
        #expect(session.worstMoves() == nil, "no pass, no ranking, and no pretending otherwise")

        session.applyReview(
            [.centipawns(20), .centipawns(15), .centipawns(-400), .centipawns(-390)],
            startEvaluation: .centipawns(10),
            depth: 14
        )
        let worst = try #require(session.worstMoves())
        #expect(worst.first?.ply == 3)

        // And walking to one is what puts the board on the question it asks: the position the
        // move was played from, with the move itself still to come.
        session.setPractising(true)
        session.jump(toPly: (worst.first?.ply ?? 1) - 1)
        #expect(session.cursor == 2)
        #expect(session.isStudying)
    }
}

// ------------------------------------------------------------------------ fakes

/// An engine with an opinion per position, keyed by FEN. What a study needs and a script cannot
/// give: three searches of three different positions, each with its own answer.
private final class PositionalEngine: Engine {
    private let answers: [String: Analysis]
    private let cleared = Mutex(0)
    private let searches = Mutex(0)

    init(_ answers: [String: Analysis]) { self.answers = answers }

    /// How many searches have been asked for at all. The scanner's whole claim is that the engine
    /// says nothing until somebody taps, and a count is the only way to hold it to that.
    var searchCount: Int { searches.withLock { $0 } }

    /// How many times the search was told to forget what it knew — a study's Scores are only at
    /// the Depth they claim if nothing deeper was learned first.
    var clearCount: Int { cleared.withLock { $0 } }

    var isPaused: Bool { false }
    func pause() {}
    func resume() {}
    func clear() async { cleared.withLock { $0 += 1 } }

    func analyse(_ game: Game, budget: SearchBudget, lines: Int) -> AsyncStream<Analysis> {
        searches.withLock { $0 += 1 }
        let answer = answers[game.state.fen]
        return AsyncStream { continuation in
            if let answer { continuation.yield(answer) }
            continuation.finish()
        }
    }

    func evaluate(_ game: Game, budget: SearchBudget) async -> Score? {
        answers[game.state.fen]?.best?.score
    }

    func review(
        _ game: Game, depth: Int, onPly: (@Sendable (Int, ReviewedPly) -> Void)?
    ) async -> [ReviewedPly] {
        game.plies.indices.map { ply in
            let best = answers[game.rewound(to: ply + 1)?.state.fen ?? ""]?.best
            let result = ReviewedPly(
                score: best?.score, line: Array((best?.san ?? []).prefix(Game.Ply.lineLimit))
            )
            onPly?(ply, result)
            return result
        }
    }
}

/// An engine whose pass does not finish until it is let go — which is how a screen going away
/// mid-pass can be tested at all.
private final class HeldEngine: Engine {
    private let answer: Analysis
    private let released = Mutex(false)

    init(_ answer: Analysis) { self.answer = answer }

    func release() { released.withLock { $0 = true } }

    var isPaused: Bool { false }
    func pause() {}
    func resume() {}
    func clear() async {}

    func analyse(_ game: Game, budget: SearchBudget, lines: Int) -> AsyncStream<Analysis> {
        let answer = self.answer
        return AsyncStream { continuation in
            continuation.yield(answer)
            continuation.finish()
        }
    }

    func evaluate(_ game: Game, budget: SearchBudget) async -> Score? { answer.best?.score }

    func review(
        _ game: Game, depth: Int, onPly: (@Sendable (Int, ReviewedPly) -> Void)?
    ) async -> [ReviewedPly] {
        let result = ReviewedPly(
            score: answer.best?.score,
            line: Array((answer.best?.san ?? []).prefix(Game.Ply.lineLimit))
        )
        onPly?(0, result)
        while !released.withLock({ $0 }) {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return game.plies.indices.map { _ in result }
    }
}
