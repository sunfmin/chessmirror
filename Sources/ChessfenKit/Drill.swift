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

    public init(
        played: String, intent: Intent, drop: Double, passed: Bool,
        wanted: String? = nil, wantedIntent: Intent? = nil
    ) {
        self.played = played
        self.intent = intent
        self.drop = drop
        self.passed = passed
        self.wanted = wanted
        self.wantedIntent = wantedIntent
    }

    /// 「Qxd5 吃 d5。过了。」 or 「Bd3 护 e4。掉了 12%。该走 Nf3 攻 e5。」
    ///
    /// The engine's move is named only when the attempt failed. A player who found a move that
    /// holds does not need to be told that Stockfish preferred a different one — that is the app
    /// arguing with a right answer, and 多解 is the whole reason the line is a drop rather than a
    /// comparison with one move (docs/adr/0027).
    public var sentence: String {
        guard !passed else { return localized("drill.passed", played, intent.label) }
        let cost = Int(drop.rounded())
        guard let wanted, let wantedIntent else {
            return localized("drill.failed", played, intent.label, cost)
        }
        // One key rather than two joined with a space: where the sentences meet is punctuation,
        // and punctuation between two sentences is not the same in eight languages.
        return localized(
            "drill.failed.wanted", played, intent.label, cost, wanted, wantedIntent.label
        )
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

    /// Practice uses the same complete depth-20 judgement as live interception.
    public static let depth = GameSession.interceptDepth

    public let position: PositionKey
    /// The board: the position, and the attempt once it has been played.
    public private(set) var game: Game
    public private(set) var verdict: DrillVerdict?
    /// Whether the engine is still working out what the move cost.
    public private(set) var isJudging = false
    public private(set) var couldNotJudge = false
    public private(set) var startingScore: Score?
    /// How long the player took over the move, in seconds. Nil until they have moved.
    public private(set) var seconds: Double?

    /// How many rungs of the hint ladder were opened before the move (docs/adr/0031). Zero until
    /// there is a ladder to open; recorded from the start because it is the thing that makes a
    /// pass with three hints readable as different from a pass with none.
    public var hintsOpened = 0

    public var isSettled: Bool { verdict != nil }
    /// Whose move it is here, which is the side that has to find something.
    public var mover: PieceColour { position.sideToMove }

    private var judging: Task<Void, Never>?
    private let engine: (any Engine)?
    private let log: PracticeLog
    private let lines: JudgementLines
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
        self.lines = lines
        self.source = source
        self.clock = clock
        startedAt = clock()
    }

    // ------------------------------------------------------------------- playing

    /// The one move this drill is about. Everything after it is a settlement.
    public func play(_ move: Move) {
        guard verdict == nil, !isJudging else { return }
        couldNotJudge = false
        let before = game
        var after = game
        guard after.apply(move), let played = after.plies.last else { return }
        seconds = max(0, clock().timeIntervalSince(startedAt))
        game = after
        isJudging = true
        judging = Task { await judge(move, san: played.san, before: before, after: after) }
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

    /// Asks the engine twice at one depth — the position, and the position after the move — and
    /// settles the difference.
    ///
    /// Twice rather than once with a wide MultiPV: the played move may not be in the engine's
    /// first three lines at all, and a move it never considered is exactly the move worth
    /// measuring (docs/adr/0016 is why both searches are the same depth).
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
        var best: Line?
        for await analysis in engine.analyse(before, budget: .depth(Self.depth), lines: 1) {
            guard !Task.isCancelled else { return }
            if analysis.depth >= Self.depth, !analysis.isPartial { best = analysis.best ?? best }
        }
        var afterScore: Score?
        if after.isOver {
            afterScore = await engine.evaluate(after, budget: .depth(Self.depth))
        } else {
            for await analysis in engine.analyse(after, budget: .depth(Self.depth), lines: 1) {
                guard !Task.isCancelled else { return }
                if analysis.depth >= Self.depth, !analysis.isPartial { afterScore = analysis.best?.score }
            }
        }
        guard !Task.isCancelled else { return }
        guard let drop = MoveQuality.drop(
            move: before.state.sideToMove, before: best?.score, after: afterScore
        ) else { return }

        let wanted = best.flatMap { before.reading(of: $0.san) }?.opening
        startingScore = best?.score
        if let afterScore {
            game.setJudgement(.init(drop: drop, score: afterScore, depth: Self.depth), atPly: 0)
        }
        settle(
            DrillVerdict(
                played: san,
                intent: Intent.read(move, in: before),
                drop: drop,
                passed: !lines.records(drop),
                wanted: wanted?.san,
                wantedIntent: wanted?.intent
            )
        )
    }

    /// Writes the attempt down and shows it. One line, append-only, facts only: which position,
    /// when, how long, whether it held, how many hints were open, and where the drill came from
    /// (docs/adr/0029).
    private func settle(_ settled: DrillVerdict) {
        verdict = settled
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
