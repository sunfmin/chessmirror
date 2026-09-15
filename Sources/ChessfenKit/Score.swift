import Foundation

/// How good a position is, as the engine sees it.
///
/// **Always from White's point of view**, which is the one thing about scores that has to
/// be decided once and never drifted from. Stockfish reports from the side to move's point
/// of view; PGN's `[%eval]` is White-relative; a curve is unreadable unless every point
/// agrees. The flip happens at the engine boundary and nowhere else.
public enum Score: Hashable, Sendable, Codable {
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

extension Score {
    /// The steepness of the curve a centipawn is read through. lichess's own constant, from
    /// `rawWinningChances` in `ui/ceval/src/winningChances.ts`:
    /// `2 / (1 + exp(-0.00368208 × cp)) - 1`, which is the same curve written as a signed
    /// advantage instead of a probability.
    public static let winCurve = 0.003_682_08

    /// White's chance of winning this position, 0…1 (docs/adr/0027).
    ///
    /// The scale everything in this app is judged on, because a centipawn is worth a different
    /// amount in every position: three pawns thrown away from a won game barely moves this, and
    /// one pawn thrown away from a level one moves it a lot. That is the shape a judgement wants
    /// and the shape a bar wants, so both read this and there is one curve to be wrong about.
    ///
    /// A mate is 1 or 0 and not a large centipawn count: being mated in three and being mated in
    /// twelve are the same fact about who wins, and the difference between them is not a drop
    /// anybody should be told about.
    public var winChance: Double {
        switch self {
        case .centipawns(let value):
            1 / (1 + exp(-Self.winCurve * Double(value)))
        case .mate(let moves):
            moves > 0 ? 1 : 0
        }
    }

    /// The same number as a percentage, which is the unit every line in this app is drawn in —
    /// 10% intercept, 10% record, 20% enqueue (docs/adr/0027).
    public var winPercent: Double { winChance * 100 }
}
