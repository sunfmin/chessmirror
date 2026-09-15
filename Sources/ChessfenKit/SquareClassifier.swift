/// What was found on a square, and how sure the matcher is.
public struct SquareVerdict: Hashable, Sendable {
    public let piece: Piece?
    /// Silhouette IoU with the winning Template, or Ink coverage for an empty square.
    public let score: Double
    /// Gap to the runner-up Template; 1 when the square is empty.
    public let margin: Double
    /// How far the body sat from the line between white and black, as a fraction of the
    /// Local Light; 1 when the square is empty.
    public let colourMargin: Double

    /// False for a Shaky Square — the ones the Confirm Position screen points at.
    public var confident: Bool {
        guard piece != nil else { return true }
        return score >= SquareClassifier.lowScore && margin >= SquareClassifier.lowMargin
            && colourMargin >= SquareClassifier.lowColourMargin
    }
}

public enum SquareClassifier {
    /// A body at least this fraction of its Local Light is a white piece.
    ///
    /// Measured over photographs and screenshots alike, white bodies come out from about
    /// 0.6 of their Local Light upwards and black bodies below about 0.36 — the two are
    /// far apart, and half way is the emptiest place between them.
    static let whiteFraction = 0.5
    /// Shape agreement below this is shaky.
    public static let lowScore = 0.55
    /// A gap to the runner-up below this is shaky.
    public static let lowMargin = 0.04
    /// A body this near the white/black line was a coin toss, and the Square is shaky
    /// however well its shape matched. A red check halo under a white king lands here, and
    /// so does a piece read off a screen through a moiré.
    public static let lowColourMargin = 0.1

    /// Matches the square's Ink against the piece Silhouettes of its own colour.
    ///
    /// Only its own colour: telling a white knight from a black knight is a question about
    /// brightness, which the body luma already answered, and mixing the two sides into one
    /// twelve-way shape contest would only invite a white bishop to win as a black one.
    ///
    /// `light` is the Local Light beside this Cell — the brightness the body is judged
    /// against, since brightness on its own is a fact about the photograph and not about
    /// the piece.
    public static func classify(_ reading: SquareReading, light: Double) -> SquareVerdict {
        guard reading.occupied else {
            return SquareVerdict(
                piece: nil, score: reading.coverage, margin: 1, colourMargin: 1
            )
        }
        let brightness = (reading.bodyLuma ?? 0) / max(1, light)
        let colour: PieceColour = brightness >= whiteFraction ? .white : .black
        let shape = Morphology.normalise(reading.ink, size: PieceTemplates.shapeSize)

        // A Silhouette is scored against the Template and against its mirror, because a
        // photographed board can be seen from either side and half the pieces are not
        // symmetric — a knight faces left or right depending on which way you look.
        var scored: [(score: Double, kind: PieceKind)] = PieceTemplates.shapes(for: colour)
            .map { kind, template in
                let upright = Morphology.intersectionOverUnion(shape, template)
                let mirrored = Morphology.intersectionOverUnion(shape, template.mirrored)
                return (max(upright, mirrored), kind)
            }
        scored.sort { $0.score > $1.score }
        guard let best = scored.first else {
            return SquareVerdict(
                piece: nil, score: reading.coverage, margin: 1, colourMargin: 1
            )
        }
        let runnerUp = scored.count > 1 ? scored[1].score : 0
        return SquareVerdict(
            piece: Piece(colour: colour, kind: best.kind),
            score: best.score,
            margin: best.score - runnerUp,
            colourMargin: abs(brightness - whiteFraction)
        )
    }
}
