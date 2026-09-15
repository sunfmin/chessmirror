import Foundation

/// How good a position is, as the engine sees it.
///
/// **Always from White's point of view**, which is the one thing about scores that has to
/// be decided once and never drifted from. Stockfish reports from the side to move's point
/// of view; PGN's `[%eval]` is White-relative; a curve is unreadable unless every point
/// agrees. The flip happens at the engine boundary and nowhere else.
public enum Score: Hashable, Sendable {
    /// Hundredths of a pawn. Positive favours White.
    case centipawns(Int)
    /// Mate in this many moves. Positive means White mates, negative means White is mated.
    case mate(in: Int)

    /// The `[%eval …]` form lichess and chess.com write: pawns to two decimals, or `#3`.
    public var pgnText: String {
        switch self {
        case .centipawns(let value):
            let pawns = Double(value) / 100
            return String(format: "%.2f", pawns)
        case .mate(let moves):
            return "#\(moves)"
        }
    }

    public init?(pgnText: String) {
        if pgnText.hasPrefix("#") {
            guard let moves = Int(pgnText.dropFirst()) else { return nil }
            self = .mate(in: moves)
            return
        }
        guard let pawns = Double(pgnText) else { return nil }
        self = .centipawns(Int((pawns * 100).rounded()))
    }

    /// Reads as it does on a board: `+1.20`, `-0.35`, `#3`.
    public var displayText: String {
        switch self {
        case .centipawns(let value):
            let pawns = Double(value) / 100
            return String(format: "%+.2f", pawns)
        case .mate(let moves):
            return "#\(moves)"
        }
    }
}
