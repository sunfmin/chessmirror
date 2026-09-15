import Foundation

/// 错招 — one move in one game that the player got wrong (docs/adr/0036).
///
/// Not a 错题. A 错题 is a *position*, shared by every game that ever reached it, and the book is
/// built out of those (docs/adr/0028). A 错招 is what happened at one place in one game, which is
/// what somebody reading that game is looking for: 「这一局里我哪儿走错了，带我过去。」
///
/// The position carried here is the one the move was played **from** — the one to try again from —
/// rather than the one it led to. That is the difference between reading a game and practising it.
public struct Slip: Hashable, Sendable, Identifiable {
    /// The Ply the move was played at, counting from one: what the record strip counts.
    public let ply: Int
    /// The position it was played from, as a position and not a FEN — the same key the 错题本
    /// identifies a position by, so a 错招 here and a 错题 there can be recognised as one thing.
    public let position: PositionKey
    /// The move that earned this cost, in SAN. A 试招 when 耕棋 took it back.
    public let played: String
    /// What the engine wanted instead, when a Line was kept. Nil rather than guessed.
    public let wanted: String?
    /// What it cost, in percentage points of win probability (docs/adr/0027).
    public let drop: Double
    /// True when the move named above is one 耕棋 took back, rather than the one that stood.
    ///
    /// The label matters: 「f3 −20%」 beside a move that never happened is a different sentence
    /// from the same numbers beside the move that did, and the 已退回 strip already says it.
    public let wasTried: Bool

    /// A Ply is a place in a game and a game is played one Ply at a time, so the Ply is the
    /// identity. One move per Ply, however many 试招 were refused there on the way to it.
    public var id: Int { ply }

    public init(
        ply: Int,
        position: PositionKey,
        played: String,
        wanted: String?,
        drop: Double,
        wasTried: Bool
    ) {
        self.ply = ply
        self.position = position
        self.played = played
        self.wanted = wanted
        self.drop = drop
        self.wasTried = wasTried
    }

    /// Whether this one is worth the player's practice time, by the 入列线 — which is what the
    /// 日课 would hand them. Everything here is at or over the 记录线, so this is the split
    /// between "written down" and "owed".
    public func isWorthDrilling(_ lines: JudgementLines) -> Bool { lines.enqueues(drop) }
}

extension Game {
    /// Every 错招 in this Game, oldest first — the player's own moves that cost at or over the
    /// 记录线.
    ///
    /// **One entry per Ply.** A position where three 试招 were refused and a fourth move was
    /// finally played is one place in the game and one stop on the way through it; the strip of
    /// 已退回 attempts belongs to the position, and this is a list of positions.
    ///
    /// The cost of a move that stood comes from the `[%judged]` 耕棋 wrote with it, or from a
    /// Review when there is one. A Review is *not* required — this is one game's account of
    /// itself, and every judgement in it came from the same bounded search of the same position —
    /// which is not the same question as the 错题本's, where scores from different games are
    /// compared and so must come from one uniform pass (docs/adr/0016).
    public func slips(by mine: Set<PieceColour>, lines: JudgementLines) -> [Slip] {
        guard !mine.isEmpty, !plies.isEmpty, var walked = rewound(to: 0) else { return [] }
        var found: [Slip] = []
        for ply in 1...plies.count where plies.indices.contains(ply - 1) {
            let fen = walked.state.fen
            guard walked.apply(uci: plies[ply - 1].uci) else { break }
            let mover = mover(ofPly: ply)
            guard mine.contains(mover), let key = PositionKey(fen: fen) else { continue }

            // The worst thing that happened at this Ply, whether it stood or not: the move to
            // show, and the number that makes it a mistake worth finding.
            var worst: (played: String, drop: Double, wasTried: Bool)?
            func worse(than candidate: Double) -> Bool { worst.map { candidate > $0.drop } ?? true }
            for attempt in plies[ply - 1].tried where lines.records(attempt.drop) {
                if worse(than: attempt.drop) {
                    worst = (attempt.san, attempt.drop, true)
                }
            }
            let stood = plies[ply - 1].judgement?.drop ?? drop(atPly: ply)
            if let stood, lines.records(stood), worse(than: stood) {
                worst = (plies[ply - 1].san, stood, false)
            }
            guard let worst else { continue }
            found.append(
                Slip(
                    ply: ply,
                    position: key,
                    played: worst.played,
                    wanted: reviewLine(atPly: ply - 1).first,
                    drop: worst.drop,
                    wasTried: worst.wasTried
                )
            )
        }
        return found
    }
}
