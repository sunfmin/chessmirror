import Foundation

/// 掷子 — how the opponent picks between moves it cannot tell apart (CONTEXT.md, docs/adr/0049).
///
/// Stockfish at 满力 has no opinion about variety: the same position on the same budget gives the
/// same move every time, so an opponent that always played its first line played the same game
/// from the first move to the last, every game. The rung above 满力 never had the problem —
/// Stockfish's own `Skill` picks among its top lines with a clock-seeded random (docs/adr/0038) —
/// and this is that idea at 满力, made explicit and bounded instead of left to the engine.
///
/// **Only the move the opponent plays.** The search the pick is read off is unchanged and is
/// still the position's shared answer: 最佳 is still the first line, 细判 still weighs a move
/// against it, and the hint still points at it. What is tossed for is which of the moves *the
/// engine believes are the same move in every way that counts* it actually pushes.
public struct Toss: Sendable {
    /// How much worse than the best line a line may score, in centipawns from the mover's side,
    /// and still be worth tossing for.
    ///
    /// Fifteen hundredths of a pawn: below what a player can feel and well below 掉幅's own
    /// floor, so nothing the toss ever picks is a move the app would call a mistake if a person
    /// played it. Widening this would not make the opponent more interesting, it would make it
    /// weaker.
    public static let margin = 15

    /// Which of `count` candidates to take. The whole of the randomness, behind a seam, because
    /// a test cannot assert on a coin it is not holding.
    private let pick: @Sendable (Int) -> Int

    public init(pick: @escaping @Sendable (Int) -> Int = { Int.random(in: 0..<$0) }) {
        self.pick = pick
    }

    /// Never tosses: the strongest line, every time. What the app played before there was a toss
    /// at all, and what a test asks for when the move it expects is the point.
    public static let strongest = Toss { _ in 0 }

    /// The moves worth tossing between, best first: the first line, plus every line the engine
    /// scores within `margin` of it from `mover`'s side.
    ///
    /// A mate is not tossed for — being mated in three and mating in three are not a matter of
    /// hundredths of a pawn, and a line whose Score is a mate is either the one move to play or
    /// no company for the one move to play. Lines that name the same move (a bound search can
    /// report one) count once.
    public static func candidates(in analysis: Analysis, by mover: PieceColour) -> [String] {
        guard let best = analysis.best, let top = centipawns(best.score, by: mover) else {
            return analysis.bestMove.map { [$0] } ?? []
        }
        var moves: [String] = []
        for line in analysis.lines {
            guard let move = line.bestMove, !moves.contains(move) else { continue }
            guard let value = centipawns(line.score, by: mover), top - value <= margin else { continue }
            moves.append(move)
        }
        return moves
    }

    /// The move the opponent plays out of this search, from `mover`'s side. Nil when the search
    /// named no move at all, which is a search that has not got anywhere yet.
    public func move(from analysis: Analysis, by mover: PieceColour) -> String? {
        let moves = Self.candidates(in: analysis, by: mover)
        guard let first = moves.first else { return nil }
        let index = pick(moves.count)
        // A seam that answers out of range gets 最佳 rather than a crash: the toss is a flourish,
        // and nothing about the opponent's move is worth trapping on.
        return moves.indices.contains(index) ? moves[index] : first
    }

    /// The Score from the mover's side, or nil for a mate. Scores in this package are
    /// White-relative (`Score`), and "worse than the best" only means anything from one side.
    private static func centipawns(_ score: Score, by mover: PieceColour) -> Int? {
        guard case .centipawns(let value) = score else { return nil }
        return mover == .white ? value : -value
    }
}
