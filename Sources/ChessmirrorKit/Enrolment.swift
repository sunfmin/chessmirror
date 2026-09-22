import Foundation

/// 入列 — whether a mistake earns the player's future practice time (docs/adr/0027).
///
/// One rule on one line (入列线), asked of two objects. They are named apart because they can
/// answer differently for one position, and a reader who takes one for the other will think the
/// app is contradicting itself:
///
/// - a **错题** — the position — is owed practice time when the worst it has ever cost crosses
///   the 入列线. This is what puts it in 日课, because practice time is spent on positions
///   (docs/adr/0028), and it is the only question `Daily` asks of the book.
/// - a **错招** — one game's account of reaching that position — is what *earned* that, when its
///   own cost crosses. This is what a mark on the record is weighed by: how hard *this* mistake
///   pressed, in this game.
///
/// A position whose worst 遭遇 crossed the line is in 日课 whatever a lesser 遭遇 in another game
/// cost, and that lesser one's mark stays held back. That is the rule and not a drift: the mark
/// is a reading of one game's record, and the 日课 is a reading of the whole book. Both used to
/// be asked as `lines.enqueues(someDrop)` under the one question 「还欠不欠」, and which drop was
/// passed decided the answer — with nothing in either module's interface to say so.
public enum Enrolment: Hashable, Sendable {
    /// Crossed the 入列线: this earns practice time.
    case owed
    /// Between the 记录线 and the 入列线: worth writing down, not worth drilling.
    case written

    /// A 错招's own cost — one occasion's 掉幅, which is what a mark on a record weighs.
    public init(slip: Slip, lines: JudgementLines) {
        self = lines.enqueues(slip.drop) ? .owed : .written
    }

    /// A 错题's worth — the worst 遭遇 it has ever had, which is what 日课 admits on.
    public init(mistake: Mistake, lines: JudgementLines) {
        self = lines.enqueues(mistake.worstCost) ? .owed : .written
    }

    public var isOwed: Bool { self == .owed }
}
