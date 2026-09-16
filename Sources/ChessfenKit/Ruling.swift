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

    /// 正着's ruling on a move played in the game.
    ///
    /// - `played` is the game with the move on the end of it, as the board showed it while it was
    ///   weighed. `before` is the game as it was being read when the move was played — the whole
    ///   game, not just the position the move was played from — and `cursor` is where the eye
    ///   stood in it. A move played from an earlier Ply is judged from there, and a refusal puts the
    ///   reader back where they were rather than at the end of a game they were not looking at.
    /// - `hints` is how far the hint ladder was open, written on the move that stands
    ///   (docs/adr/0031); `relaxedIntercept` is the line it was let through at, if the ladder was
    ///   climbed to one, which makes the move itself a 试招 the player did not find.
    public init(
        _ weighed: Weighing?, san: String, played: Game, before: Game, cursor cursorBefore: Int,
        lines: JudgementLines, relaxedIntercept: Double? = nil, hints: Int = 0
    ) {
        guard let weighed else {
            verdict = .unjudged
            game = before
            cursor = cursorBefore
            return
        }
        if Self.intercepts(weighed.drop, lines: lines, relaxedIntercept: relaxedIntercept) {
            // Written down at the position it happened at, which is where the eye was standing
            // (docs/adr/0037) — with the 应招 it earned, picked up from the search that judged it
            // (docs/adr/0034), because the position the move made is off the board from here on.
            var restored = before
            restored.recordTried(
                .init(san: san, drop: weighed.drop, depth: weighed.depth, line: weighed.reply),
                atPly: cursorBefore
            )
            verdict = .refused(Refusal(san: san, drop: weighed.drop))
            game = restored
            cursor = cursorBefore
            return
        }
        var standing = played
        standing.letStand(
            atPly: played.plies.count - 1, san: san, drop: weighed.drop, score: weighed.after,
            depth: weighed.depth, lines: lines, relaxedIntercept: relaxedIntercept, hints: hints,
            best: weighed.isBest
        )
        verdict = .stands(
            MoveChange(before: weighed.scoreBefore, after: weighed.after, isBest: weighed.isBest)
        )
        game = standing
        cursor = standing.plies.count
    }

    /// The ruling on a drill's one attempt, which the drill has already judged and written down
    /// (`Drill`, docs/adr/0029). What is left to rule is whether 正着 takes it back: the game is the
    /// drill's board with the attempt on it, and a refusal puts it back to the position alone.
    ///
    /// The judgement the drill wrote stays as it is, without a 拦截线 on it: a drill's attempt is
    /// written down but never counted among the moves that stood (docs/adr/0038).
    public init(
        _ verdict: DrillVerdict, in game: Game, startingScore: Score?,
        lines: JudgementLines, relaxedIntercept: Double? = nil
    ) {
        if Self.intercepts(verdict.drop, lines: lines, relaxedIntercept: relaxedIntercept) {
            var restored = game.rewound(to: 0) ?? game
            restored.recordTried(
                .init(san: verdict.played, drop: verdict.drop, line: verdict.reply), atPly: 0
            )
            self.verdict = .refused(Refusal(san: verdict.played, drop: verdict.drop))
            self.game = restored
            cursor = 0
            return
        }
        var change: MoveChange?
        if let startingScore, let after = game.plies.first?.judgement?.score {
            change = MoveChange(before: startingScore, after: after)
        }
        self.verdict = .stands(change)
        self.game = game
        cursor = game.plies.count
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
