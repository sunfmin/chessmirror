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
    /// One wrong move made at this position: a 试招 耕棋 took back, or the move that stood when it
    /// stood too expensively.
    public struct Wrong: Hashable, Sendable {
        public let san: String
        /// What it cost, in percentage points of win probability (docs/adr/0027).
        public let drop: Double
        /// True when this is one 耕棋 took back, rather than the move that stood.
        public let wasTried: Bool

        public init(san: String, drop: Double, wasTried: Bool) {
            self.san = san
            self.drop = drop
            self.wasTried = wasTried
        }
    }

    /// Every wrong move the player made at this position, worst first.
    ///
    /// **A list, because a position is not a move.** The same player at the same position tries
    /// what they try — three 试招 and then a fourth move, or the same 试招 twice — and every one of
    /// them is a fact about *this position*. Naming the entry after one of them would name it
    /// after a move that, half the time, never happened.
    public let wrong: [Wrong]
    /// What the engine wanted instead, when a Line was kept. Nil rather than guessed.
    public let wanted: String?

    /// A Ply is a place in a game and a game is played one Ply at a time, so the Ply is the
    /// identity. One move per Ply, however many 试招 were refused there on the way to it.
    public var id: Int { ply }

    public init(ply: Int, position: PositionKey, wrong: [Wrong], wanted: String?) {
        self.ply = ply
        self.position = position
        self.wrong = wrong
        self.wanted = wanted
    }

    /// The worst of them — the number this position is worth stopping for.
    public var drop: Double { wrong.first?.drop ?? 0 }

    /// Whether any of them was a move 耕棋 took back.
    public var wasTried: Bool { wrong.contains { $0.wasTried } }

    /// The position this happened at, counted in Plies played — which is what the record strip's
    /// cells count, because a cell *is* a position: tapping the move at Ply `n` puts the board on
    /// the position after `n` Plies.
    ///
    /// So a mistake at Ply `n` is marked on the cell at `n - 1`, which shows the position the move
    /// was played from. That is the whole point of the mark — it says 「这里你走错过，来重新下」
    /// and the board it takes you to is the one to try again from.
    public var positionPly: Int { ply - 1 }

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
        stops(by: mine).compactMap { stop in
            // Everything wrong that happened here, whether it stood or not — the 试招 in the order
            // they were refused, and the move that finally stood if it was too expensive too.
            var wrong = stop.tried
                .filter { lines.records($0.drop) }
                .map { Slip.Wrong(san: $0.san, drop: $0.drop, wasTried: true) }
            if let move = stop.move, let stood = move.judgement?.drop ?? drop(atPly: stop.ply),
                lines.records(stood) {
                wrong.append(Slip.Wrong(san: move.san, drop: stood, wasTried: false))
            }
            guard !wrong.isEmpty else { return nil }
            return Slip(
                ply: stop.ply, position: stop.position,
                wrong: wrong.sorted { $0.drop > $1.drop }, wanted: stop.wanted
            )
        }
    }
}

