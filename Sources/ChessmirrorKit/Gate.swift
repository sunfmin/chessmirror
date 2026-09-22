import Foundation

/// Which question 「这一手走错没」 is being asked of a Game — and where the rule that answers it
/// lives (docs/adr/0016, 0036).
///
/// One walk of a Game (`Game.stops`) feeds both readings of a player's mistakes: the game's own
/// list of 错招, and the 错题本's 遭遇. What differs is what each does with the move that **stood** —
/// whether it counts as wrong at all, and by whose number. That was spelled out at each call
/// site, the book's version carrying an extra rule about a 惩罚 exercise that had already written
/// the move down, with nothing in either module's interface to say which gate was running. A
/// caller comparing a `Slip.wrong` with an `Encounter.played` had to re-derive the rule to know
/// why they could differ.
public enum Gate: Hashable, Sendable {
    /// 错题本's. A move that stood is wrong only when a **Review** measured it — the book compares
    /// across games, and a drop needs two Scores from one depth (docs/adr/0016) — and not when a
    /// 惩罚 exercise already wrote it down as the move the player did not find.
    case book
    /// One game's own record. A move that stood is wrong when **anything** measured it: the
    /// `[%judged]` 把关 wrote with it, else a Review. This is one game's account of itself, where
    /// every judgement in it came from the same bounded search of the same position.
    case record

    /// What the move that stood at `stop` costs under this gate, or nil when the gate does not
    /// admit it as wrong at all.
    public func stood(at stop: Game.Stop, in game: Game) -> Double? {
        guard let move = stop.move else { return nil }
        switch self {
        case .book:
            guard game.isReviewed,
                !stop.tried.contains(where: { $0.notFound && $0.san == move.san })
            else { return nil }
            return game.drop(atPly: stop.ply)
        case .record:
            return game.cost(atPly: stop.ply)
        }
    }

    /// Everything wrong that happened at `stop` under this gate: the 试招 the 记录线 writes down,
    /// and the move that stood if this gate says it was too expensive.
    public func wrong(
        at stop: Game.Stop, in game: Game, lines: JudgementLines
    ) -> [Game.Stop.Wrong] {
        stop.wrong(recordedBy: lines, stood: stood(at: stop, in: game))
    }
}
