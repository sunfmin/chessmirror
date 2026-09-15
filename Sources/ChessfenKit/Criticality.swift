/// How much one Ply mattered — a **rank within its own Game**, not a number of centipawns
/// (docs/adr/0017).
///
/// This is what decides which moves a player is asked about, and ranking rather than
/// thresholding is how one mechanism serves a beginner and a club player with no level
/// setting anywhere: a beginner's worst three moves are their giveaways, a club player's are
/// their inaccuracies, and the same code finds both.
public struct Criticality: Hashable, Sendable {
    /// Which move, counting from one.
    public let ply: Int
    public let san: String
    public let mover: PieceColour
    /// Centipawns thrown away by this move, from the mover's point of view.
    ///
    /// Negative for a move that *gained*, and such moves are still ranked: a Game with no bad
    /// move in it still has a worst three, which is the right answer for a club player and
    /// harmless for a beginner. Ranking is not a search for moves over a line.
    public let lost: Int
    /// The absolute label, when the loss earns one. It **names** a ranked move and never
    /// chooses one — that distinction is the whole of docs/adr/0017.
    public let quality: MoveQuality?
}

extension Game {
    /// Every move this Game's Review could judge, worst first.
    ///
    /// Nil for a Game no Review has been over. That is a refusal and not an empty answer: a
    /// rank built on Scores of mixed or unrecorded Depth is a list of invented mistakes, and
    /// this app is allowed to be wrong but never quietly wrong (docs/adr/0016).
    ///
    /// A ply the Review did not reach has no Score, so it is not ranked at all rather than
    /// ranked as harmless — the same rule as `quality(atPly:)`.
    public func criticality(by colour: PieceColour? = nil) -> [Criticality]? {
        guard isReviewed else { return nil }

        var ranked: [Criticality] = []
        for ply in 1...max(plies.count, 1) where plies.indices.contains(ply - 1) {
            let mover = mover(ofPly: ply)
            if let colour, mover != colour { continue }
            guard let before = reviewScore(atPly: ply - 1), let after = reviewScore(atPly: ply)
            else { continue }

            let swing = MoveQuality.centipawns(before) - MoveQuality.centipawns(after)
            ranked.append(
                Criticality(
                    ply: ply,
                    san: plies[ply - 1].san,
                    mover: mover,
                    lost: swing * (mover == .white ? 1 : -1),
                    quality: MoveQuality.of(move: mover, before: before, after: after)
                )
            )
        }
        // Worst first, and ties broken by when it happened, so the order is stable and the
        // earlier of two equally bad moves is the one asked about first.
        return ranked.sorted { ($0.lost, -$0.ply) > ($1.lost, -$1.ply) }
    }

    /// The `count` moves this Game's Review liked least, worst first. Nil for a Game no Review
    /// has been over.
    public func worstMoves(_ count: Int = 3, by colour: PieceColour? = nil) -> [Criticality]? {
        criticality(by: colour).map { Array($0.prefix(count)) }
    }
}
