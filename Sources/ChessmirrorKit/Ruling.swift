import Foundation

/// A move that was played and taken back, and what it gave away.
public struct Refusal: Hashable, Sendable {
    public let san: String
    /// Percentage points of win probability, from the mover's own side.
    public let drop: Double

    public init(san: String, drop: Double) {
        self.san = san
        self.drop = drop
    }

    /// 「Qh4 掉 23%，退回去重走。」 — what went wrong and nothing about what to do instead.
    /// The hint ladder is a separate thing somebody has to ask for (docs/adr/0031).
    public var sentence: String {
        localized("till.refused", san, Drop.points(drop))
    }
}

/// The change the move just played made to the position, for the badge under the board.
public struct MoveChange: Hashable, Sendable {
    public let before: Score
    public let after: Score
    /// 最佳: the move was the engine's own first choice, by the search that weighed it.
    public let isBest: Bool

    public init(before: Score, after: Score, isBest: Bool = false) {
        self.before = before
        self.after = after
        self.isBest = isBest
    }

    public func percent(for colour: PieceColour) -> Double {
        (after.winPercent - before.winPercent) * (colour == .white ? 1 : -1)
    }
}

/// 原局: the game as it was being read when a move was played, kept while the move is weighed
/// (docs/adr/0035, 0037). The whole game and not only the position the move was played from —
/// which is a prefix of it when the move was played from an earlier Ply — with the eye where it
/// stood, the rungs of the hint ladder open there and the line it had been relaxed to, and when
/// the move landed on the board.
///
/// One value, because it answers one question that used to be answered in three places: what to
/// put back. A refused move puts the 原局 back, a weighing nobody finished puts it back
/// (`Ruling.unjudged`), and a session leaving the screen mid-weighing puts it back — and that
/// last one had a copy of the rule of its own, with nothing to hold it to the ruling's.
public struct Standpoint: Hashable, Sendable {
    public let game: Game
    /// Where the eye stood in `game` when the move was played.
    public let cursor: Int
    /// How far the hint ladder was open at that position, written on the move if it stands
    /// (docs/adr/0031).
    public let hints: Int
    /// The line the ladder had been climbed to, if it had: the move stands at that line and is
    /// written as a 试招 the player did not find.
    public let relaxedIntercept: Double?
    /// When the move landed on the board, for the beat it is given there before being taken back.
    public let began: ContinuousClock.Instant

    public init(
        game: Game, cursor: Int, hints: Int = 0, relaxedIntercept: Double? = nil,
        began: ContinuousClock.Instant = .now
    ) {
        self.game = game
        self.cursor = cursor
        self.hints = hints
        self.relaxedIntercept = relaxedIntercept
        self.began = began
    }

    /// How long the move has been on the board.
    public var shown: Duration { ContinuousClock.now - began }
}

/// What 正着 rules about a move once it has been weighed, and what the game looks like afterwards
/// (docs/adr/0027, 0037).
///
/// A pure reading of a `Weighing` against the 拦截线, with the game it leaves behind: the move
/// either **stands**, with its judgement written on it and the refusals made where it was played
/// from riding along as its 试招; or it is **refused**, and the game is put back exactly as it was
/// being read, with the refusal written down at the position it happened at; or the engine said
/// nothing, and the game is put back with nothing written. The session, the drill's attempt and
/// the exercise each used to do this in their own lines, and the two that did it in the session
/// had drifted — one restored the eye to where it had been, the other to the end. Now they hand
/// over what they know and are handed back the game to show, and the only thing that is theirs
/// is what a session does with a ruling: the noise, the save, the next search.
public struct Ruling: Hashable, Sendable {
    public enum Verdict: Hashable, Sendable {
        /// The move stands. The change it made to the position, when both ends were measured.
        case stands(MoveChange?)
        /// The move was taken back, and this is the sentence about it.
        case refused(Refusal)
        /// Nobody looked: the search was cancelled or the engine had nothing to say. Not a move
        /// that cost nothing — the move is put back and nothing is said.
        case unjudged
    }

    public let verdict: Verdict
    /// The game as it is to be shown once the ruling is in effect.
    public let game: Game
    /// Where the eye goes: the end of the move that stands, or back where it was.
    public let cursor: Int

    private init(verdict: Verdict, game: Game, cursor: Int) {
        self.verdict = verdict
        self.game = game
        self.cursor = cursor
    }

    /// Nobody looked — the search was cancelled, the engine had nothing to say, or the session
    /// left the screen — so the move comes off and the 原局 is put back with nothing written.
    public static func unjudged(_ standpoint: Standpoint) -> Ruling {
        Ruling(verdict: .unjudged, game: standpoint.game, cursor: standpoint.cursor)
    }

    /// Whether a 掉幅 is one 正着 stops for, at the line as it stands — the relaxed one if the hint
    /// ladder was climbed to it. Never when 正着 is off.
    public static func intercepts(_ drop: Double, lines: JudgementLines, relaxedIntercept: Double? = nil) -> Bool {
        drop > 0 && drop >= (relaxedIntercept ?? lines.intercept ?? .infinity)
    }

    /// The move comes off the board: it was refused, or nobody could say.
    public var takesTheMoveBack: Bool {
        if case .stands = verdict { return false }
        return true
    }

    /// 把关's ruling on a move played in the game.
    ///
    /// `played` is the game with the move on the end of it, as the board showed it while it was
    /// weighed; `standpoint` is the 原局 it was played from. A move played from an earlier Ply is
    /// judged from there, and a refusal puts the reader back where they stood rather than at the
    /// end of a game they were not looking at. The hint ladder's rungs and the line it was
    /// relaxed to come with the 原局: the rungs are written on a move that stands (docs/adr/0031),
    /// and a move let through at a relaxed line is itself a 试招 the player did not find.
    public init(
        _ weighed: Weighing?, san: String, played: Game, from standpoint: Standpoint,
        lines: JudgementLines
    ) {
        guard let weighed else {
            self = .unjudged(standpoint)
            return
        }
        if Self.intercepts(weighed.drop, lines: lines, relaxedIntercept: standpoint.relaxedIntercept) {
            // Written down at the position it happened at, which is where the eye was standing
            // (docs/adr/0037) — with the 应招 it earned, picked up from the search that judged it
            // (docs/adr/0034), because the position the move made is off the board from here on.
            var restored = standpoint.game
            restored.recordTried(
                .init(san: san, drop: weighed.drop, depth: weighed.depth, line: weighed.reply),
                atPly: standpoint.cursor
            )
            self.init(
                verdict: .refused(Refusal(san: san, drop: weighed.drop)),
                game: restored, cursor: standpoint.cursor
            )
            return
        }
        var standing = played
        standing.letStand(
            atPly: played.plies.count - 1, san: san, drop: weighed.drop, score: weighed.after,
            depth: weighed.depth, lines: lines, relaxedIntercept: standpoint.relaxedIntercept,
            hints: standpoint.hints, best: weighed.isBest
        )
        self.init(
            verdict: .stands(
                MoveChange(before: weighed.scoreBefore, after: weighed.after, isBest: weighed.isBest)
            ),
            game: standing, cursor: standing.plies.count
        )
    }

    /// The ruling on a drill's one attempt, made by the drill itself once it has judged and
    /// written down the attempt (`Drill.ruling`, docs/adr/0029). What is left to rule is whether
    /// 把关 takes it back: the game is the drill's board with the attempt on it, and a refusal puts
    /// it back to the position alone.
    ///
    /// The judgement the drill wrote stays as it is, without a 拦截线 on it: a drill's attempt is
    /// written down but never counted among the moves that stood (docs/adr/0038).
    init(_ verdict: DrillVerdict, in game: Game, startingScore: Score?, lines: JudgementLines) {
        if Self.intercepts(verdict.drop, lines: lines) {
            var restored = game.rewound(to: 0) ?? game
            restored.recordTried(
                .init(san: verdict.played, drop: verdict.drop, line: verdict.reply), atPly: 0
            )
            self.init(
                verdict: .refused(Refusal(san: verdict.played, drop: verdict.drop)),
                game: restored, cursor: 0
            )
            return
        }
        var change: MoveChange?
        if let startingScore, let after = game.plies.first?.judgement?.score {
            change = MoveChange(before: startingScore, after: after)
        }
        self.init(verdict: .stands(change), game: game, cursor: game.plies.count)
    }
}

extension Game {
    /// What is written on a move that is allowed to stand (docs/adr/0027, 0031, 0037): its
    /// judgement, if it was measured; itself as a 试招 the player did not find, if it was let
    /// through at a relaxed line; and the refusals made where it was played from, which it takes
    /// with the rungs of the hint ladder that were open.
    ///
    /// The judgement carries the 拦截线 it stood under — the relaxed one if the ladder had been
    /// climbed to it — and none when 正着 was off, which is how 正着数 tells a move that stood from
    /// a move that was merely measured (CONTEXT.md, 正着数).
    mutating func letStand(
        atPly ply: Int, san: String, drop: Double?, score: Score?, depth: Int,
        lines: JudgementLines, relaxedIntercept: Double?, hints: Int, best: Bool = false
    ) {
        if let drop, let score {
            setJudgement(
                .init(
                    drop: drop, score: score, depth: depth,
                    intercept: relaxedIntercept ?? lines.intercept, best: best
                ),
                atPly: ply
            )
        }
        var relaxed: [Ply.Tried] = []
        if relaxedIntercept != nil, let drop, lines.records(drop) {
            relaxed = [.init(san: san, drop: drop, notFound: true, depth: depth)]
        }
        absorbPendingTried(atPly: ply, hints: hints, adding: relaxed)
    }
}
