/// The record's Scores as one value: what the curve under the record strip draws, and what its
/// accessibility reads out (docs/adr/0016).
///
/// A level per position, nil where nobody has scored it. The screen used to ask the session for
/// every ply's Score three times over — once to decide whether there was a curve to draw, once to
/// draw it and once to say how far it reached — and the rule for "is there a curve" lived in the
/// view. The session now hands over the curve, and the rule is a property of it.
public struct ScoreCurve: Hashable, Sendable {
    /// Indexed by Ply: `scores[0]` is the position the game began in.
    public let scores: [Score?]

    public init(scores: [Score?]) {
        self.scores = scores
    }

    /// How many Plies the game has.
    public var plies: Int { max(scores.count - 1, 0) }

    /// The Plies somebody has scored.
    public var known: [Int] { scores.indices.filter { scores[$0] != nil } }

    /// A curve needs two points: one Score is a number, not a shape.
    public var isDrawable: Bool { known.count > 1 }

    /// The last Ply the curve reaches, as far as anyone has scored.
    public var lastKnownPly: Int? { known.last }

    public func score(atPly ply: Int) -> Score? {
        scores.indices.contains(ply) ? scores[ply] : nil
    }
}
