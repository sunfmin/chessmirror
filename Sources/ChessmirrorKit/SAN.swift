/// Standard Algebraic Notation, generated on the Swift side because Stockfish has none:
/// it speaks UCI, where `e1g1` and `Nf3` are the same event described for different
/// readers. SAN needs the whole legal move list to know when a move must be disambiguated,
/// which is exactly what a GameState already carries.
public enum SAN {
    /// The move written the way a scoresheet writes it. `move` must come from
    /// `state.legalMoves`.
    public static func text(for move: Move, in state: GameState) -> String {
        if move.isCastling {
            return (move.isShortCastling ? "O-O" : "O-O-O") + suffix(for: move)
        }

        var text = ""
        if move.piece == .pawn {
            // A pawn capture always names the file it left, even when unambiguous.
            if move.isCapture { text += fileLetter(move.from) + "x" }
            text += move.to.description
            if let promotion = move.promotion { text += "=\(promotion.letter)" }
        } else {
            text += String(move.piece.letter)
            text += disambiguation(for: move, in: state)
            if move.isCapture { text += "x" }
            text += move.to.description
        }
        return text + suffix(for: move)
    }

    /// The smallest hint that tells this move apart from its twins: nothing if no other
    /// piece of the same kind can reach the square, else the file, else the rank, else both.
    private static func disambiguation(for move: Move, in state: GameState) -> String {
        let rivals = state.legalMoves.filter {
            $0.piece == move.piece && $0.to == move.to && $0.from != move.from
        }
        if rivals.isEmpty { return "" }

        let fileIsUnique = !rivals.contains { $0.from.file == move.from.file }
        if fileIsUnique { return fileLetter(move.from) }

        let rankIsUnique = !rivals.contains { $0.from.rank == move.from.rank }
        if rankIsUnique { return String(move.from.rank + 1) }

        return move.from.description
    }

    private static func suffix(for move: Move) -> String {
        if move.isCheckmate { return "#" }
        return move.givesCheck ? "+" : ""
    }

    private static func fileLetter(_ square: Square) -> String {
        String(square.description.prefix(1))
    }

    /// The move a SAN token refers to, or nil if no legal move is written that way.
    ///
    /// Matching is done by generating SAN for every legal move and comparing, so parsing
    /// can never disagree with writing. Trailing annotations (`!`, `?`, `!!`) and the
    /// check marks are ignored, since PGN in the wild is inconsistent about them.
    public static func move(for token: String, in state: GameState) -> Move? {
        let wanted = normalise(token)
        return state.legalMoves.first { normalise(text(for: $0, in: state)) == wanted }
    }

    private static func normalise(_ token: String) -> String {
        var text = token
        while let last = text.last, "+#!?".contains(last) { text.removeLast() }
        // "e8=Q", "e8Q" and "e8/Q" all appear in the wild, and so does "0-0".
        return String(text.map { $0 == "0" ? "O" : $0 }.filter { $0 != "=" && $0 != "/" })
    }
}
