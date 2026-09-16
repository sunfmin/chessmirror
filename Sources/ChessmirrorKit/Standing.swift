import Foundation

/// What the strip under the board says right now, and in which voice (docs/adr/0020).
///
/// One sentence, chosen by one priority, because the order *is* the meaning: a game that is over
/// outranks everything, a move being weighed outranks a refusal, a refusal outranks the change
/// the last move made, and with nothing to report the strip is quiet. The screen used to hold that
/// order as a chain of `else if`s, which made the strip's meaning a piece of view code that only
/// a simulator could test; here it is a value a session produces from the facts it already
/// holds, and the screen draws whichever voice it is handed.
public enum Standing: Hashable, Sendable {
    /// The game is over: who was mated or how it was drawn, and the scoreline.
    case finished(String)
    /// 正着 is working out what the move just played costs.
    case weighing
    /// A move has just been taken back, and this is the one sentence about it (docs/adr/0031).
    case refused(Game.Ply.Tried)
    /// 最佳: the move just played is the engine's own first choice from the position it was
    /// played from. Said as a word rather than as `+0.0%`, because it is a fact about which move
    /// it was, read off the search that judged it — not a number that happened to round to zero.
    case best
    /// The move just played, as the change it made to the player's chances: percentage points
    /// from the player's own side, already rounded to tenths.
    case change(Double)
    /// Nothing to say: no move to report on. The engine's assessment of the position is never
    /// one of the voices — it is an opinion, and the strip does not give one (docs/adr/0040).
    case quiet

    /// `+1.2%`, `-3.0%`, `0.0%` — never `-0.0%`, which is a number nobody feels.
    public static func changeLabel(_ value: Double) -> String {
        String(format: "%+.1f%%", value == 0 ? 0.0 : value)
    }
}
