@testable import ChessmirrorKit
import Foundation
import Synchronization
import Testing
import ChessmirrorKitTesting

/// Practising one 错题: the position, one move, a verdict, and a line in the log (docs/adr/0029).

/// The position after 1. e4 e5 2. Nf3 — Black to move, and the one this suite drills.
private let afterNf3 = PositionKey("rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq -")

@MainActor private func opinion(_ score: Score, line: [String] = []) -> Analysis {
    Analysis(depth: Drill.depth, lines: [Line(score: score, uciMoves: [], san: line)])
}

private func temporaryLog() -> PracticeLog {
    PracticeLog(
        url: URL(filePath: NSTemporaryDirectory())
            .appending(path: "chessmirror-drill-\(UUID().uuidString).jsonl")
    )
}

/// An engine that has one opinion about the drilled position and one about the position the
/// player's move reaches. Both at one depth, which is what makes the two comparable at all
/// (docs/adr/0016).
@MainActor
private func engine(
    before: Score, playing san: String, after: Score, wanting wanted: String? = nil
) throws -> (engine: ScriptedEngine, move: Move) {
    let position = try #require(Game(startFEN: afterNf3.text + " 0 1"))
    var reached = position
    let legal = reached.apply(san: san)
    #expect(legal, "\(san) has to be legal here or the fixture is wrong")
    let move = try #require(position.state.move(matching: reached.plies.last!.uci))
    return (
        ScriptedEngine(
            [],
            byPosition: [
                position.state.fen: opinion(before, line: wanted.map { [$0] } ?? []),
                reached.state.fen: opinion(after),
            ]
        ),
        move
    )
}

// ------------------------------------------------------------------ the verdict

@MainActor
@Test func incompletePracticeJudgementDoesNotRecordAPass() async throws {
    let engine = ScriptedEngine([Analysis(depth: 19, lines: [
        Line(score: .centipawns(0), uciMoves: ["b8c6"], san: ["Nc6"])
    ], isPartial: true)])
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }
    let drill = try #require(Drill(position: afterNf3, engine: engine, log: log))
    let before = drill.game
    drill.play(try #require(before.state.move(matching: "b8c6")))
    #expect(drill.game != before)
    await drill.settled()
    #expect(drill.game == before)
    #expect(drill.couldNotJudge)
    #expect(drill.verdict == nil)
    #expect(log.attempts().isEmpty)
}

/// Contract: real depth-20 judgement → one practice-log entry → opponent reply → next human
/// move in the same session → persisted PGN, without a second practice attempt.
@MainActor
@Test func practiceFlowsIntoTheSameGame() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = PracticeLog(url: directory.appending(path: "practice.jsonl"))
    let engine = try EngineService(bigNetURL: Nets.big, smallNetURL: Nets.small,
        configuration: .init(threads: 2, hashMegabytes: 32, multiPV: 1))
    let drill = try #require(Drill(position: afterNf3, engine: engine, log: log))
    let library = GameLibrary(folder: GameFolder(url: directory))
    let session = GameSession.practising(drill, engine: engine, library: library)
    defer { session.suspend() }
    #expect(session.controller(for: .black) == .hand)
    #expect(session.controller(for: .white) == .engine)
    #expect(session.orientation == .blackAtBottom)
    #expect(log.attempts().isEmpty)
    session.notePracticeHelp()
    session.play(try #require(session.game.state.move(matching: "b8c6")))
    await session.settled()
    let verdict = try #require(drill.verdict)
    #expect(verdict.played == "Nc6")
    #expect(session.game.plies.first?.judgement?.depth == 20)
    #expect(log.attempts().count == 1)
    #expect(log.attempts().first?.attempt.hints == 1)
    await session.waitForPreparedInterception()
    #expect(session.game.plies.count == 2, "the engine answers for White, not the student's Black")
    #expect(session.isHandTurn)
    let before = session.game.uciMoves
    let move = try #require(session.game.state.legalMoves.first)
    session.play(move)
    await session.settled()
    #expect(session.game.uciMoves == before + [move.uci])
    #expect(log.attempts().count == 1, "continuing is not another attempt at the original question")
    let url = try #require(session.url)
    let saved = try PGN(parsing: String(contentsOf: url, encoding: .utf8))
    #expect(saved.game.uciMoves == session.game.uciMoves)
    #expect(saved.game.plies.first?.judgement?.depth == 20)
}

@MainActor
@Test("a move that is not the engine's first choice passes, so long as it costs little")
func aSecondChoiceThatHoldsPasses() async throws {
    // Black to move. Level before; +45 for White after — about four points of Black's win chance,
    // under the 记录线. The engine wanted something else entirely, and that is not the question.
    let (scripted, move) = try engine(
        before: .centipawns(0), playing: "Nc6", after: .centipawns(45), wanting: "d5"
    )
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }
    let drill = try #require(Drill(position: afterNf3, engine: scripted, log: log))

    drill.play(move)
    await drill.settled()

    let verdict = try #require(drill.verdict)
    #expect(verdict.passed, "four points is under the line, whatever the engine preferred")
    #expect(verdict.played == "Nc6")
    #expect(verdict.drop < JudgementLines.standard.record, "drop was \(verdict.drop)")
}

@MainActor
@Test("a soft move that costs twelve points does not pass")
func aTwelvePointMoveFails() async throws {
    let (scripted, move) = try engine(
        before: .centipawns(0), playing: "Qh4", after: .centipawns(133), wanting: "Nc6"
    )
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }
    let drill = try #require(Drill(position: afterNf3, engine: scripted, log: log))

    drill.play(move)
    await drill.settled()

    let verdict = try #require(drill.verdict)
    #expect(!verdict.passed)
    #expect(abs(verdict.drop - 12.0) < 0.2, "drop was \(verdict.drop)")
    #expect(verdict.wanted == "Nc6", "and the engine's move is named, now that it is wanted")
}

/// The 线 a drill is judged under and the 线 it is refused under are one value, the drill's own.
/// A session practising it mirrors those 线 and lands the drill's ruling as it is — a twelve-point
/// move is refused under a 记录线 of five and stands under one of thirty, and nothing in the
/// session has a line of its own to say otherwise. The line that takes it back is the line that
/// writes it down (docs/adr/0046), so the move that stands is also the move that passes.
@MainActor
@Test("the drill rules its own attempt, and the session lands it under the same 线")
func theDrillRulesItsOwnAttempt() async throws {
    for (record, stands) in [(5.0, false), (30.0, true)] {
        let (scripted, move) = try engine(
            before: .centipawns(0), playing: "Qh4", after: .centipawns(133), wanting: "Nc6"
        )
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log.url) }
        let lines = JudgementLines(noSlips: true, record: record, enqueue: record)
        let drill = try #require(Drill(position: afterNf3, engine: scripted, log: log, lines: lines))
        let session = GameSession.practising(drill, engine: scripted)
        defer { session.suspend() }
        #expect(session.lines == lines, "one value for the 线")

        session.play(move)
        await session.settled()

        let ruling = try #require(drill.ruling)
        #expect(ruling.takesTheMoveBack == !stands, "at \(record)")
        #expect(session.game == ruling.game, "the session shows what the drill ruled")
        if stands {
            #expect(session.game.plies.count == 1)
            #expect(session.refused == nil)
        } else {
            #expect(session.game.plies.isEmpty, "back to the position alone")
            #expect(session.refused?.san == "Qh4")
            #expect(session.game.pendingTries(atPly: 0).map(\.san) == ["Qh4"])
        }
        #expect(drill.verdict?.passed == stands, "taken back and written down are one line")
    }
}

@MainActor
@Test("both a pass and a fail say why, and only the fail names the engine's move")
func everyAttemptIsToldSomething() async throws {
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }

    let (held, holding) = try engine(
        before: .centipawns(0), playing: "Nc6", after: .centipawns(45), wanting: "d5"
    )
    let good = try #require(Drill(position: afterNf3, engine: held, log: log))
    good.play(holding)
    await good.settled()

    let (lost, losing) = try engine(
        before: .centipawns(0), playing: "Qh4", after: .centipawns(133), wanting: "Nc6"
    )
    let bad = try #require(Drill(position: afterNf3, engine: lost, log: log))
    bad.play(losing)
    await bad.settled()

    try Speech.speaking(.chinese) {
        let passed = try #require(good.verdict).sentence
        let failed = try #require(bad.verdict).sentence
        // Rowland 2014: retrieval practice with no corrective feedback is worth nothing
        // measurable, so there is no quiet success here.
        #expect(passed.contains("Nc6"), "\(passed)")
        #expect(passed.contains("过了"), "a pass is told what it did too: \(passed)")
        #expect(!passed.contains("该走"), "and is not argued with: \(passed)")
        #expect(failed.contains("Qh4"), "\(failed)")
        #expect(failed.contains("12%"), "how much it cost, in the one scale: \(failed)")
        #expect(failed.contains("该走 Nc6"), "and what to have played: \(failed)")
    }
}

@MainActor
@Test("a position the engine has no opinion about settles into nothing rather than a guess")
func noEngineMeansNoVerdict() async throws {
    let position = try #require(Game(startFEN: afterNf3.text + " 0 1"))
    var reached = position
    let legal = reached.apply(san: "Nc6")
    #expect(legal)
    let move = try #require(position.state.move(matching: reached.plies.last!.uci))
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }

    let drill = try #require(Drill(position: afterNf3, engine: nil, log: log))
    drill.play(move)
    await drill.settled()

    #expect(drill.verdict == nil)
    #expect(!drill.isJudging)
    #expect(log.attempts().isEmpty, "nothing happened, so nothing is written down")
}

// ---------------------------------------------------------------------- the log

@MainActor
@Test("a finished drill leaves one line, with how long it took")
func theLogGainsOneLine() async throws {
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }
    let (scripted, move) = try engine(
        before: .centipawns(0), playing: "Qh4", after: .centipawns(133), wanting: "Nc6"
    )
    // A clock that reads two ticks: the moment the position went up, and the moment they moved.
    let ticks = Mutex([Date(timeIntervalSince1970: 1_790_000_000)])
    // Built outside the macro: a closure argument inside one is checked as if it escaped into
    // another isolation domain, which this one never does.
    let built = Drill(
        position: afterNf3, engine: scripted, log: log, source: .picked,
        clock: {
            ticks.withLock { times in
                let now = times.last ?? Date()
                times.append(now.addingTimeInterval(7))
                return now
            }
        }
    )
    let drill = try #require(built)

    drill.play(move)
    await drill.settled()

    let written = log.attempts()
    #expect(written.count == 1)
    let attempt = try #require(written.first?.attempt)
    #expect(attempt.position == afterNf3)
    #expect(attempt.seconds == 7, "thinking time, not the engine's")
    #expect(attempt.passed == false)
    #expect(attempt.played == "Qh4")
    #expect(attempt.hints == 0)
    #expect(attempt.source == .picked)
}

@Test("the log holds nothing a scheduler would have to be migrated out of")
func theLogHasNoSchedulingFields() throws {
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }
    log.append(
        .drilled(
            PracticeLog.Attempt(
                position: afterNf3, seconds: 7, passed: false, played: "Qh4", cost: 12,
                hints: 0, source: .daily
            )
        ),
        at: Date(timeIntervalSince1970: 1_790_000_000)
    )

    let text = try String(contentsOf: log.url, encoding: .utf8)
    // Read as text rather than through the type, because what this is holding is the shape on
    // disk: the type could grow a due date and the round trip would never notice (docs/adr/0029).
    for forbidden in ["due", "interval", "ease", "difficulty", "stability", "mastered", "state"] {
        #expect(!text.contains("\"\(forbidden)\""), "the log wrote a \(forbidden) field: \(text)")
    }
    #expect(text.contains("\"seconds\":7"))
    #expect(text.contains("\"source\":\"daily\""))
}

@Test("two devices each practising one position merge by union")
func twoLogsMergeByUnion() throws {
    let one = temporaryLog()
    let other = temporaryLog()
    let merged = temporaryLog()
    defer { for log in [one, other, merged] { try? FileManager.default.removeItem(at: log.url) } }
    let second = PositionKey("rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq -")

    func attempt(_ position: PositionKey) -> PracticeLog.Fact {
        .drilled(
            PracticeLog.Attempt(
                position: position, seconds: 4, passed: true, played: "Nf3", cost: 1,
                hints: 0, source: .picked
            )
        )
    }
    one.append(attempt(afterNf3), at: Date(timeIntervalSince1970: 1_790_000_000))
    other.append(attempt(second), at: Date(timeIntervalSince1970: 1_790_000_100))

    // The merge is a concatenation, and that is only true because there is no state here to
    // disagree about: every line is something that happened on one device (docs/adr/0029).
    let both = try String(contentsOf: one.url, encoding: .utf8)
        + String(contentsOf: other.url, encoding: .utf8)
    try both.write(to: merged.url, atomically: true, encoding: .utf8)

    let rows = merged.attempts()
    #expect(rows.count == 2)
    #expect(Set(rows.map(\.attempt.position)) == [afterNf3, second])
}

@Test("a log written, forgotten and read again is the same log")
func theLogSurvivesTheApp() throws {
    let url = URL(filePath: NSTemporaryDirectory())
        .appending(path: "chessmirror-drill-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    PracticeLog(url: url).append(
        .drilled(
            PracticeLog.Attempt(
                position: afterNf3, seconds: 12, passed: true, played: "Nc6", cost: 2,
                hints: 1, source: .daily
            )
        )
    )
    // A different object over the same file, which is what a relaunch is.
    let reopened = PracticeLog(url: url).attempts()
    #expect(reopened.count == 1)
    #expect(reopened.first?.attempt.hints == 1)
    #expect(reopened.first?.attempt.seconds == 12)
}

// ------------------------------------------------------------------ the cards

/// Contract: 把关 takes a move back; whether 杀 and 战术 may be looked at is a different question
/// (docs/adr/0047).
///
/// The two used to be one line — cards were dealt when the switch was off — so putting practice
/// under 把关 would have taken the deck away with it, and `hintsOpened`, which counts a card being
/// pressed, would have had nothing left to count.
@MainActor
@Test("a drill keeps its cards under 把关, and a game under 把关 has none")
func practiceKeepsItsCardsUnderNoSlips() throws {
    let (scripted, _) = try engine(
        before: .centipawns(0), playing: "Qh4", after: .centipawns(133)
    )
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }
    let drill = try #require(Drill(
        position: afterNf3, engine: scripted, log: log, lines: JudgementLines(noSlips: true)
    ))
    let session = GameSession.practising(drill, engine: scripted)
    defer { session.suspend() }
    #expect(session.isNoSlipsOn)
    #expect(session.dealsCards, "practice is dealt its cards under 把关")
    session.setFindingTactics(true)
    #expect(session.isFindingTactics, "and the finder may run for them")

    let game = GameSession.fresh(
        try #require(Game(startFEN: PGN.standardStartFEN)), engine: scripted,
        lines: JudgementLines(noSlips: true)
    )
    defer { game.suspend() }
    #expect(!game.dealsCards, "a game under 把关 deals none")
    game.setFindingTactics(true)
    #expect(!game.isFindingTactics)
}

/// Contract: the 线 a drill is judged under are the session's own, and there is only the one
/// value (docs/adr/0047). A switch that could put a 练习 out of 把关 would make the refusal the
/// drill is built on optional.
@MainActor
@Test("a 练习 cannot be switched out of 把关, and the file says so")
func practiceCannotLeaveTheGate() throws {
    let (scripted, _) = try engine(
        before: .centipawns(0), playing: "Qh4", after: .centipawns(133)
    )
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }
    let drill = try #require(Drill(position: afterNf3, engine: scripted, log: log))
    let session = GameSession.practising(drill, engine: scripted)
    defer { session.suspend() }

    #expect(session.isNoSlipsOn, "a drill arrives under 把关 whatever the player's game is set to")
    session.setNoSlips(false)
    #expect(session.isNoSlipsOn, "and the switch cannot take it out")
    #expect(drill.lines.noSlips)
    #expect(session.lines == drill.lines, "one value, not two kept in step")

    // Nor by the long way round, which is how a reopened game is handed the player's numbers.
    session.setLines(JudgementLines(noSlips: false, record: 25, enqueue: 25))
    #expect(session.isNoSlipsOn)
    #expect(session.lines.record == drill.lines.record)

    // And the file it writes says 把关 was on, which is what a later reader goes by.
    #expect(session.pgn.intercept != nil)
}

// ------------------------------------------------------------------ under 把关

/// Contract: 练习 is played under 把关 (docs/adr/0047).
///
/// The wrong answer comes off the board, the 试招 is written at the position it was played from,
/// the file is saved although no move stands — answered wrong and walked away from is the
/// commonest 错题 there is (docs/adr/0037) — and the book counts one more 遭遇 while the log
/// still counts one go.
@MainActor
@Test("a wrong answer is taken back, written down, and lands in the book")
func aWrongAnswerIsTakenBackAndWrittenDown() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = GameLibrary(folder: GameFolder(url: directory))
    let log = PracticeLog(url: directory.appending(path: "practice.jsonl"))
    let (scripted, move) = try engine(
        before: .centipawns(0), playing: "Qh4", after: .centipawns(133), wanting: "Nc6"
    )
    // The lines the app hands a drill: the player's two numbers, with 把关 off. The drill switches
    // it on itself, which is the whole of this change.
    let drill = try #require(Drill(
        position: afterNf3, engine: scripted, log: log, lines: JudgementLines(noSlips: false),
        source: .daily
    ))
    #expect(drill.lines.noSlips, "练习 is played under 把关 whatever a game is set to")
    let session = GameSession.practising(drill, engine: scripted, library: library)
    defer { session.suspend() }

    session.play(move)
    await session.settled()

    #expect(drill.verdict?.passed == false)
    #expect(session.game.plies.isEmpty, "the wrong answer came back off the board")
    #expect(session.refused?.san == "Qh4")
    #expect(session.game.pendingTries(atPly: 0).map(\.san) == ["Qh4"])
    #expect(session.board.state.fen == afterNf3.text + " 0 1", "the question is on the board again")
    #expect(log.attempts().count == 1, "one go, whatever the book makes of it")

    let url = try #require(session.url, "a refusal is worth a file even with no move in it")
    let saved = try PGN(parsing: String(contentsOf: url, encoding: .utf8))
    #expect(saved.game.plies.isEmpty)
    #expect(saved.handColours == [afterNf3.sideToMove])
    let book = MistakeBook.derive(
        from: [GameLibrary.Entry(url: url, pgn: saved, modified: Date())]
    )
    #expect(book.mistakes.count == 1)
    #expect(book.mistakes.first?.position == afterNf3)
    #expect(book.mistakes.first?.encounters.first?.played == "Qh4")
}

/// The other half: an answer that holds still stands, and the game goes on from it.
@MainActor
@Test("an answer that holds stands, and 把关 is still on for what follows")
func anAnswerThatHoldsStands() async throws {
    let (scripted, move) = try engine(
        before: .centipawns(0), playing: "Nc6", after: .centipawns(45), wanting: "d5"
    )
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }
    let drill = try #require(Drill(position: afterNf3, engine: scripted, log: log))
    let session = GameSession.practising(drill, engine: scripted)
    defer { session.suspend() }

    session.play(move)
    await session.settled()

    #expect(drill.verdict?.passed == true)
    #expect(session.game.plies.count == 1)
    #expect(session.refused == nil)
    #expect(session.isNoSlipsOn, "and what follows is played under 把关 too")
}

// ------------------------------------------------------------------ the verdict row

/// The row under the board says where the attempt stands in one word, explains only a fail, and
/// offers the way on once there is an answer or there cannot be one (docs/adr/0029).
@MainActor
@Test("the verdict row says where the attempt stands")
func theVerdictRowSaysWhereTheAttemptStands() async throws {
    let log = temporaryLog()
    defer { try? FileManager.default.removeItem(at: log.url) }

    let (held, holding) = try engine(
        before: .centipawns(0), playing: "Nc6", after: .centipawns(45), wanting: "d5"
    )
    let good = try #require(Drill(position: afterNf3, engine: held, log: log))
    #expect(good.standing == .asking)
    #expect(!good.offersWayOn, "nothing to move on from before the move")
    good.play(holding)
    #expect(good.standing == .judging)
    await good.settled()
    #expect(good.standing == .held)
    #expect(good.explanation == nil, "a move that held is not argued with")
    #expect(good.offersWayOn)

    let (lost, losing) = try engine(
        before: .centipawns(0), playing: "Qh4", after: .centipawns(133), wanting: "Nc6"
    )
    let bad = try #require(Drill(position: afterNf3, engine: lost, log: log))
    bad.play(losing)
    await bad.settled()
    #expect(bad.standing == .dropped)
    #expect(bad.explanation == bad.verdict?.sentence)

    let unjudged = try #require(Drill(position: afterNf3, engine: nil, log: log))
    unjudged.play(losing)
    await unjudged.settled()
    #expect(unjudged.standing == .unjudged)
    #expect(unjudged.offersWayOn, "a drill that cannot be judged still lets you on")

    Speech.speaking(.chinese) {
        #expect(Drill.Standing.held.word == localized("drill.held"))
        #expect(Drill.Standing.dropped.word == localized("drill.dropped"))
        #expect(Drill.Standing.unjudged.word == localized("drill.noEngine"))
        #expect(Drill.Standing.asking.word == localized("drill.prompt"))
    }
}
