/// A move offered at a past Ply and not yet committed.
///
/// Held rather than played, because a Drill is a question and a played move is an answer already
/// marked. Between the two there has to be a moment where the move is on the board, visible, and
/// still yours to take back — that moment is this (docs/adr/0015).
///
/// Note the order a Drill has to happen in: the move *and* the reason are both given before
/// anything is shown. A reason offered after the answer is a reason fitted to it.
public struct Guess: Hashable, Sendable {
    /// Which Ply is being answered, counting from one: the move that was played from the
    /// position on screen.
    public let ply: Int
    public let move: Move
    public let san: String
}

/// What committing a Guess showed: your move, the engine's, and the one actually played, each
/// with a Score, all three computed at one Depth.
///
/// Three answers side by side and no combined number, because "you found the move" and "you found
/// a move as good as the engine's" and "you found what you played last time" are different facts,
/// and rolling them into a percentage is how an app ends up saying nothing.
public struct Reveal: Hashable, Sendable {
    public let ply: Int
    /// Whose move it was — the side the Scores below are read from the point of view of.
    public let mover: PieceColour
    /// The one Depth all three Scores were computed at. Without it they cannot be compared with
    /// each other, which is the whole lesson of docs/adr/0016.
    public let depth: Int

    public let guess: String
    public let guessScore: Score?
    /// The move that was played in the Game when it was played for real.
    public let played: String
    public let playedScore: Score?
    /// What the engine would play here. Nil when the engine could not be asked.
    public let best: String?
    public let bestScore: Score?
    /// What the engine expects to happen *after* the move that was offered, in SAN.
    ///
    /// Free, and only free here: the search that scored the Guess produced these moves and used
    /// to drop them. It is what lets the board say which of the squares the Guess changed hands
    /// over actually mattered, which is a question about where the game goes next
    /// (docs/adr/0021). Empty when the search could not be made.
    public let guessLine: [String]
    /// What the engine's own recommendation is for, in the same seven verbs the player declares in.
    ///
    /// Read out of the Line the search already produced and never declared by anybody, so it is a
    /// reason the same checker can be pointed at (docs/adr/0021). Nil when the engine could not be
    /// asked; 说不清 inside, when it was asked and none of the seven can honestly carry the answer.
    public let bestReading: LineReading?

    /// What the player said the move was for, and whether that claim actually held.
    ///
    /// Beside the Scores and never folded into them. A move can be found for a reason that is not
    /// true, and a true reason can be given for a move that does not work, and those are the two
    /// most useful things this app can tell somebody (docs/adr/0018).
    public let intent: Intent?
    public let intentCheck: IntentCheck?

    public var isSameAsPlayed: Bool { guess == played }
    public var isSameAsBest: Bool { best.map { $0 == guess } ?? false }

    /// What the Guess gave up against the engine's move, in centipawns from the mover's point of
    /// view. Nil when either Score is missing.
    public var lost: Int? {
        guard let bestScore, let guessScore else { return nil }
        let swing = MoveQuality.centipawns(bestScore) - MoveQuality.centipawns(guessScore)
        return swing * (mover == .white ? 1 : -1)
    }

    /// How the Guess reads on the absolute scale — the same one a Review uses on a played move,
    /// so a Drill and a Review cannot disagree about what counts as a mistake.
    public var quality: MoveQuality? {
        MoveQuality.of(move: mover, before: bestScore, after: guessScore)
    }

    /// Whether the Guess is inside the band that counts: within half a pawn of the engine's move.
    ///
    /// The band is `MoveQuality`'s own — anything it calls 正常 counts — rather than a second
    /// threshold invented here. A Drill that graded on a stricter scale than the Review would be
    /// telling a player their move was wrong and the file that it was fine.
    public var counts: Bool? {
        quality.map { $0 == .fine }
    }
}

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

/// A uniform-depth pass over a Game, while it is running.
///
/// Every ply re-scored at one Depth so the Scores can be compared with each other. It is started
/// by turning the engine's opinion on and by nothing else — there is nowhere else to ask for it,
/// which is what makes the switch the only moment a Game can acquire one (docs/adr/0015, 0016).
public struct ReviewPass: Hashable, Sendable {
    public let depth: Int
    public var completed: Int
    public let total: Int
    public var isRunning: Bool

    public var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }
}
