import Foundation

/// 应招 — what a 试招 earned (docs/adr/0034).
///
/// A 试招 is a move 把关 took back, and the whole of what makes it a mistake is the answer it
/// invited: the opponent's move, and the few moves after it. The app already had that Line — the
/// search that judged the move produced it — so it is kept beside the 试招 it belongs to rather
/// than being asked for again. Asked for again is exactly what it is not: the position the move
/// made is gone from the board the moment it is refused, and a player who wants to see why their
/// move was wrong should not have to pay for a second search to be shown.
///
/// Nothing here decides anything. The Line was already measured; this only says how much of it is
/// worth keeping and how it is drawn.
public enum Reply {
    /// How much of the answer is kept.
    ///
    /// The 试招 itself is drawn as step one, so this is one less than the six arrows a board can
    /// carry (`MateNews.arrowLimit`): the move, the move that punishes it, and the two or three
    /// moves after that. A Line at interception Depth runs far past this, and past the arrows
    /// nobody checks a continuation — the point is to see that the move is answered, not to
    /// memorise the answer.
    public static let limit = MateNews.arrowLimit - 1

    /// The moves a 试招 is, as one line: the move played and taken back, then the 应招 to it.
    ///
    /// One list rather than two, because everything that reads it — the numbered chips, the
    /// arrows — is drawing one sequence, and the join between the move and its answer is not a
    /// place a reader should have to be told about.
    public static func moves(of tried: Game.Ply.Tried, reply: [String]? = nil) -> [String] {
        [tried.san] + (reply ?? tried.line)
    }

    /// The same for any wrong move on the strip: the move, then what answers it.
    public static func moves(of wrong: GameSession.WrongMove, reply: [String]? = nil) -> [String] {
        [wrong.san] + (reply ?? wrong.line)
    }

    /// The line as numbered arrows, from the position the 试招 was refused in.
    ///
    /// The 试招 wears the player's own colour and everything after it wears the alarm colour:
    /// whose move it is decides the colour, counted from whoever played the refused move rather
    /// than from which Controller a colour is on. In a reply the two sides are not "you" and "the
    /// engine" — they are the move that was wrong and the moves that make it wrong, and a game
    /// between two people still has to draw that.
    public static func arrows(in position: Game, playing moves: [String]) -> [MoveArrow] {
        let mover = position.state.sideToMove
        return MoveArrow.walk(moves, from: position) { $0 == mover }
    }
}
