/// What a Review found at one Ply: the Score, and the Line the same search produced.
///
/// The Line used to be thrown away. It is the answer to "and then what?" — which of the squares a
/// move changed hands over actually mattered is a question about where the game goes next, and the
/// search that produced the Score produced those moves too (docs/adr/0021). Keeping it costs no
/// engine time. Asking for it later would cost a Stint (docs/adr/0020), which is the whole reason
/// it is picked up on the way past rather than fetched when somebody looks.
public struct ReviewedPly: Hashable, Sendable {
    public let score: Score?
    /// The engine's expected continuation from the position *after* this Ply, in SAN, capped at
    /// `Game.Ply.lineLimit`. Empty when the search had nothing to say — a mate delivered, a
    /// position the engine could not be asked about.
    public let line: [String]

    public init(score: Score?, line: [String] = []) {
        self.score = score
        self.line = line
    }
}
