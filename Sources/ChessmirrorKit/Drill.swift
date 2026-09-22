import Foundation

/// What came of one attempt at one 错题 (docs/adr/0029).
///
/// **Said every time, pass or fail.** Retrieval practice without corrective feedback is worth
/// nothing measurable (Rowland 2014), so there is no quiet success here: a move that held gets
/// told what it did as plainly as a move that did not.
public struct DrillVerdict: Hashable, Sendable {
    /// What was played, in SAN.
    public let played: String
    /// What that move was for, read out of the move rather than asked about (docs/adr/0018).
    public let intent: Intent
    /// What it cost, in percentage points of win probability (docs/adr/0027).
    public let drop: Double
    /// Whether it stayed under the 记录线.
    public let passed: Bool
    /// The engine's own move, and what it was for. Nil when the engine had nothing to say —
    /// never invented, because an invented answer is worse than none.
    public let wanted: String?
    public let wantedIntent: Intent?
    /// The 应招 the attempt earned: the Line the search that judged it produced, in SAN, the
    /// opponent's move first. Empty for an attempt that held, and for one that left no position
    /// to answer in (docs/adr/0034).
    public let reply: [String]

    public init(
        played: String, intent: Intent, drop: Double, passed: Bool,
        wanted: String? = nil, wantedIntent: Intent? = nil, reply: [String] = []
    ) {
        self.played = played
        self.intent = intent
        self.drop = drop
        self.passed = passed
        self.wanted = wanted
        self.wantedIntent = wantedIntent
        self.reply = reply
    }

    /// 「Qxd5 吃 d5。过了。」 or 「Bd3 护 e4。掉了 12%。该走 Nf3 攻 e5。」
    ///
    /// The engine's move is named only when the attempt failed. A player who found a move that
    /// holds does not need to be told that Stockfish preferred a different one — that is the app
    /// arguing with a right answer, and 多解 is the whole reason the line is a drop rather than a
    /// comparison with one move (docs/adr/0027).
    public var sentence: String {
        guard !passed else { return localized("drill.passed", Self.phrase(played, intent)) }
        let cost = Drop.points(drop)
        guard let wanted else {
            return localized("drill.failed", Self.phrase(played, intent), cost)
        }
        // One key rather than two joined with a space: where the sentences meet is punctuation,
        // and punctuation between two sentences is not the same in eight languages.
        return localized(
            "drill.failed.wanted", Self.phrase(played, intent), cost,
            Self.phrase(wanted, wantedIntent)
        )
    }

    /// A move and what it is for — 「Bd3 护 e4」 — or the move on its own when nothing could be
    /// read out of it.
    ///
    /// 「说不清」 is an honest answer to 为什么, and it is not the answer to *this* question. Printed
    /// here it put a shrug in the middle of a verdict — 「Be3 说不清。这一手掉了 16% 胜率。该走 Bxc4
    /// 说不清。」 — which reads as the app hedging about the one thing it is certain of. A move with
    /// no reading is just a move.
    private static func phrase(_ move: String, _ intent: Intent?) -> String {
        guard let intent, intent != .unclear else { return move }
        return localized("drill.move", move, intent.label)
    }
}

/// One 错题, being practised (docs/adr/0029).
///
/// The position goes up, the player moves, and the move is judged on the same scale the book was
/// built with: **what it cost**, not whether it matched the engine's first choice. A position
/// with three moves that hold has three right answers, and an app that only accepts one of them
/// is teaching a move rather than a position.
///
/// Nothing here is scheduled. There is no due date, no interval and no mastery flag — what a
/// drill leaves behind is one line in the practice log saying what happened, and when the
/// scheduler arrives it will read those lines (docs/adr/0029).
@Observable @MainActor public final class Drill {
    /// Where this attempt came from, which is a fact about the session rather than about the
    /// position: a drill somebody chose off the book is not the same evidence as one the day's
    /// queue handed them.
    public enum Source: String, Hashable, Sendable, Codable {
        /// 日课派的.
        case daily
        /// 计划外 — picked off the book.
        case picked
    }

    /// The depth ceiling every live search shares: the 搜索预算's (the time can win).
    public static var depth: Int { PositionSearches.depth }

    public let position: PositionKey
    /// The board: the position, and the attempt once it has been played.
    public private(set) var game: Game
    public private(set) var verdict: DrillVerdict?
    /// 把关's ruling on the attempt, made here with the verdict under this drill's own 线: whether
    /// the move stands or is taken back, and the game either way. A session practising this
    /// drill lands it and does nothing else with the judgement — the 线 a drill is judged under
    /// and the 线 it is refused under are one value, this one.
    public private(set) var ruling: Ruling?
    /// Whether the engine is still working out what the move cost.
    public private(set) var isJudging = false
    public private(set) var couldNotJudge = false
    public private(set) var startingScore: Score?
    /// How long the player took over the move, in seconds. Nil until they have moved.
    public private(set) var seconds: Double?

    /// How many cards were opened before the move (docs/adr/0025, 0047) — 杀 and 战术 are dealt
    /// in practice, and opening one is counted as help rather than refused. The number the
    /// 练习日志 writes on this attempt, and the thing that makes a pass with two cards open
    /// readable as different from a pass with none.
    ///
    /// Written only through `noteHelp()`. It was a bare `var` naming a 提示层 that ADR 0042
    /// retired, which left the one number the log has about help settable by anybody.
    public private(set) var hintsOpened = 0

    /// One card opened. Counted while the question is still open: help after the verdict is not
    /// help with the answer.
    public func noteHelp() {
        guard !isSettled, !isJudging else { return }
        hintsOpened += 1
    }

    public var isSettled: Bool { verdict != nil }

    /// Where the attempt stands, as the verdict row says it (docs/adr/0029): asking, weighing
    /// the move, 过了, 没过, or unable to judge it at all.
    public enum Standing: Hashable, Sendable {
        case asking, judging, held, dropped, unjudged

        /// The row's one word.
        public var word: String {
            switch self {
            case .asking: localized("drill.prompt")
            case .judging: localized("drill.judging")
            case .held: localized("drill.held")
            case .dropped: localized("drill.dropped")
            case .unjudged: localized("drill.noEngine")
            }
        }
    }

    public var standing: Standing {
        if let verdict { return verdict.passed ? .held : .dropped }
        if couldNotJudge { return .unjudged }
        return isJudging ? .judging : .asking
    }

    /// Why, and only when the answer was no. A move that held has been told that it held; a
    /// paragraph explaining a right answer is the app arguing with it (docs/adr/0027).
    public var explanation: String? {
        guard let verdict, !verdict.passed else { return nil }
        return verdict.sentence
    }

    /// Whether the row offers the way on: once there is an answer, or once there cannot be one.
    public var offersWayOn: Bool { isSettled || couldNotJudge }
    /// Whose move it is here, which is the side that has to find something.
    public var mover: PieceColour { position.sideToMove }

    private var judging: Task<Void, Never>?
    private let engine: (any Engine)?
    private let log: PracticeLog
    /// The 线 this attempt is judged and ruled under, arriving with 把关 on (docs/adr/0047): the
    /// player's two numbers as they are, and the switch the drill does not leave to a setting.
    /// The player may still flip it — the session's switch writes here, and the attempt is ruled
    /// under what it says when the attempt settles (docs/adr/0048).
    public internal(set) var lines: JudgementLines
    private let source: Source
    private let clock: @Sendable () -> Date
    private let startedAt: Date

    /// Nil for a position that will not parse, which is the only refusal.
    public init?(
        position: PositionKey,
        engine: (any Engine)?,
        log: PracticeLog = .standard,
        lines: JudgementLines = .standard,
        source: Source = .picked,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        // A key carries the four fields that make a position; the clocks are not part of what a
        // position is (docs/adr/0028), so a fresh pair is put back on to make a whole FEN.
        guard let game = Game(startFEN: position.text + " 0 1") else { return nil }
        self.position = position
        self.game = game
        self.engine = engine
        self.log = log
        // 练习 is played under 把关, whatever a game of the player's is set to (docs/adr/0047).
        // Here rather than at the screen that opens a drill, because a rule a caller has to
        // remember is a rule the app went four months without: the refusal was written, tested
        // and unreachable, and every 错题 answered wrong stood on the board instead.
        self.lines = {
            var mine = lines
            mine.noSlips = true
            return mine
        }()
        self.source = source
        self.clock = clock
        startedAt = clock()
    }

    // ------------------------------------------------------------------- playing

    /// What a session must do with a move offered to this attempt.
    enum Intake: Sendable {
        /// Not this attempt's move — already settled, already judging, or it will not apply.
        case refused
        /// Landed and under 细判. Wait `settled()`, then read `ruling`.
        case judging(game: Game)
        /// Landed with nothing measurable. Put the game back and write nothing.
        case unjudged(game: Game)
    }

    /// The one move this drill is about. Everything after it is a settlement.
    ///
    /// Owns the whole intake — the guard, the apply, the wait flag, the game the move made — so
    /// a session never has to know how an attempt decides a move is its own (docs/adr/0047).
    func take(_ move: Move) -> Intake {
        guard verdict == nil, !isJudging else { return .refused }
        couldNotJudge = false
        let before = game
        var after = game
        guard after.apply(move), let played = after.plies.last else { return .refused }
        seconds = max(0, clock().timeIntervalSince(startedAt))
        game = after
        isJudging = true
        judging = Task { await judge(move, san: played.san, before: before, after: after) }
        return .judging(game: after)
    }

    public func play(_ move: Move) {
        _ = take(move)
    }

    /// Waits until the attempt has been settled. What a screen moving on to the next question
    /// waits for, and the one thing a test has to hold on to — a verdict arrives when the engine
    /// has answered and not a moment sooner.
    public func settled() async { await judging?.value }

    public func cancel() {
        judging?.cancel()
        judging = nil
        if !isSettled, let start = game.rewound(to: 0) { game = start }
        isJudging = false
    }

    /// The same 细判 把关 gives a move as it lands (`Weighing`): a move outside the baseline's
    /// candidate lines still has an independently evaluated resulting position, and the 应招 comes
    /// out of the same search that settled the attempt (docs/adr/0034) — a drill's position is
    /// taken back the moment it is refused, exactly as 把关's is, so this is the last moment the
    /// answer to it can be had without a second search.
    private func judge(_ move: Move, san: String, before: Game, after: Game) async {
        defer {
            if !Task.isCancelled {
                isJudging = false
                if verdict == nil {
                    game = before
                    couldNotJudge = true
                }
            }
        }
        guard let engine else { return }
        let weighed = await engine.weigh(after, from: before)
        guard !Task.isCancelled, let weighed else { return }

        let wanted = weighed.before.best.flatMap { before.reading(of: $0.san) }?.opening
        startingScore = weighed.scoreBefore
        game.setJudgement(weighed.judgement, atPly: 0)
        settle(
            DrillVerdict(
                played: san,
                intent: Intent.read(move, in: before),
                drop: weighed.drop,
                passed: !lines.records(weighed.drop),
                wanted: wanted?.san,
                wantedIntent: wanted?.intent,
                reply: weighed.reply
            )
        )
    }

    /// Writes the attempt down and shows it. One line, append-only, facts only: which position,
    /// when, how long, whether it held, how many hints were open, and where the drill came from
    /// (docs/adr/0029). And rules on it, once, under the same 线.
    private func settle(_ settled: DrillVerdict) {
        verdict = settled
        ruling = Ruling(settled, in: game, startingScore: startingScore, lines: lines)
        log.append(
            .drilled(
                PracticeLog.Attempt(
                    position: position,
                    seconds: seconds ?? 0,
                    passed: settled.passed,
                    played: settled.played,
                    cost: settled.drop,
                    hints: hintsOpened,
                    source: source
                )
            ),
            at: clock()
        )
    }
}
