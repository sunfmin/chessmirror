/// A Game: where it started and what has been played. Everything else — the current
/// Position, whose turn it is, what is legal, whether it is over — is derived from those
/// two facts on demand, so undo is dropping an element
/// (docs/adr/0003).
public struct Game: Hashable, Sendable {
    /// One move as played, kept with the SAN it was written as. SAN is stored rather than
    /// recomputed because it depends on the position the move was made in, and that
    /// position is gone once the move is played.
    public struct Ply: Hashable, Sendable {
        public let uci: String
        public let san: String
        /// White-relative score after this move, written by a **Review and by nothing else**
        /// (docs/adr/0016).
        ///
        /// Three writers used to share this field at three different Depths — the unbounded
        /// search during play, a Review, and a Score that arrived inside an imported game —
        /// and nothing said which won. That is survivable while a number only draws a curve;
        /// it stops being survivable once the differences between consecutive Scores decide
        /// which moves a player is asked about, because mixed Depths invent mistakes that
        /// never happened. So the field is a Review's, and a Game with no `reviewDepth` has
        /// nothing comparable in here at all.
        public var evaluation: Score?
        /// A Score that came in with an imported game: somebody else's engine, at a Depth
        /// nobody wrote down. Kept so it can be shown as theirs, and never read when a move
        /// is being judged.
        public var importedEvaluation: Score?
        /// The engine's expected continuation from the position *after* this move, in SAN,
        /// written by a **Review and by nothing else** — the same rule as `evaluation`, and for
        /// the same reason: a Line from a search at some other Depth cannot be compared with the
        /// Lines around it (docs/adr/0016, 0021).
        ///
        /// Empty rather than optional. "The Review had nothing to say here" and "there has been
        /// no Review" are told apart by `reviewDepth`, which is where every other question about
        /// provenance is already answered.
        public var line: [String] = []
        public init(
            uci: String,
            san: String,
            evaluation: Score? = nil,
            importedEvaluation: Score? = nil,
            line: [String] = [],
        ) {
            self.uci = uci
            self.san = san
            self.evaluation = evaluation
            self.importedEvaluation = importedEvaluation
            self.line = line
        }

        /// How many Ply of a Review's Line are kept.
        ///
        /// Four moves each side. Past that a Line at Review Depth is a claim about a position the
        /// opponent has had four chances to disagree with, nothing in the app reads further, and
        /// every extra move is bytes in every file for as long as the file exists.
        public static let lineLimit = 8

        /// Takes over everything that is *said about* a move rather than being the move.
        ///
        /// Replaying a line recomputes `uci` and `san` and loses all of this, so anything that
        /// replays — `rewound(to:)` — puts it back through here. One list
        /// in one place, because the way this goes wrong is a field being added and only two of
        /// the three call sites remembering it.
        mutating func takeAnnotations(from other: Self) {
            evaluation = other.evaluation
            importedEvaluation = other.importedEvaluation
            line = other.line
        }
    }

    public let startFEN: String
    /// Who makes the first move, and the move number the first move is counted from.
    ///
    /// A Game recognised from a picture usually starts mid-game, often with Black to move,
    /// and everything shown or written about its moves — PGN numbering, the notation, who
    /// played the first ply — hangs off these two. Stored rather than re-parsed from the
    /// FEN by each reader, which is how four of them could disagree about whose move it was.
    public let startingSideToMove: PieceColour
    public let startingFullmoveNumber: Int
    public private(set) var plies: [Ply]
    /// The position after every ply, recomputed whenever the Game changes.
    public private(set) var state: GameState

    /// The one Depth every `Ply.evaluation` in this Game was computed at, or nil for a Game
    /// no Review has been over.
    ///
    /// A property of the pass rather than of a move, because uniformity is what a Review
    /// *is*: recording the Depth once turns "has this been reviewed, and how deeply" from an
    /// inference into a fact, and nil is what stops a Game from being ranked on Scores that
    /// cannot be compared with each other (docs/adr/0016).
    public private(set) var reviewDepth: Int?
    /// The Review's Score for the starting position — what the first move is compared
    /// against. Without it the first move's quality cannot be recomputed from a saved file,
    /// which is why it is written rather than living only in the run that produced it.
    public private(set) var startEvaluation: Score?

    /// Whether a Review has been over this Game, which is the only condition under which its
    /// Scores may be compared with each other or a move called a mistake.
    public var isReviewed: Bool { reviewDepth != nil }

    /// Fails when the FEN would not survive validation — the Confirm Position gate is
    /// what stops that from happening (docs/adr/0008).
    public init?(startFEN: String) {
        guard let state = Rules.probe(startFEN: startFEN) else { return nil }
        self.startFEN = startFEN
        self.startingSideToMove = state.sideToMove
        self.startingFullmoveNumber = state.fullmoveNumber
        self.plies = []
        self.state = state
        self.reviewDepth = nil
        self.startEvaluation = nil
    }

    /// Rebuilds a Game from a starting FEN and a list of UCI moves, refusing the lot if
    /// any move is not legal where it falls.
    public init?(startFEN: String, uciMoves: [String]) {
        guard var game = Game(startFEN: startFEN) else { return nil }
        for uci in uciMoves {
            guard game.apply(uci: uci) else { return nil }
        }
        self = game
    }

    public var isOver: Bool { state.outcome.isOver }

    /// Every position the Game has stood in, as UCI move prefixes — what a Review walks.
    public var uciMoves: [String] { plies.map(\.uci) }

    /// The two squares of the move at `ply`, for the board to join with an arrow — the one
    /// place a ply becomes the squares to mark. The session and the Review each used to turn
    /// the same ply into the same squares their own way.
    public func moveSquares(atPly ply: Int) -> MoveSquares? {
        guard ply > 0, plies.indices.contains(ply - 1) else { return nil }
        return MoveSquares(uci: plies[ply - 1].uci)
    }

    @discardableResult
    public mutating func apply(_ move: Move) -> Bool {
        guard state.legalMoves.contains(move) else { return false }
        let san = SAN.text(for: move, in: state)
        guard let next = Rules.probe(startFEN: startFEN, moves: uciMoves + [move.uci])
        else { return false }
        plies.append(Ply(uci: move.uci, san: san))
        state = next
        return true
    }

    @discardableResult
    public mutating func apply(uci: String) -> Bool {
        guard let move = state.move(matching: uci) else { return false }
        return apply(move)
    }

    /// Accepts a SAN token, which is what reading a PGN produces.
    @discardableResult
    public mutating func apply(san: String) -> Bool {
        guard let move = SAN.move(for: san, in: state) else { return false }
        return apply(move)
    }

    /// Plays a move from the position after `ply` moves, dropping whatever used to follow.
    ///
    /// This is what browsing back and playing something else does. Three cases, and the third is
    /// the interesting one: past the end is not a thing, playing the move that is already there
    /// just carries on down the line that exists, and anything else **replaces** the rest.
    ///
    /// Replaces, where it used to branch. A Game was a tree and is a list now (docs/adr/0028): the
    /// only two things that ever wrote a branch were a Drill's answer and a 五步计划, both gone,
    /// and what is left is somebody taking a move back and playing another — which is one game and
    /// not two. 耕棋's rolled-back moves are kept as comments, and a list of those is still a list.
    @discardableResult
    public mutating func play(_ move: Move, atPly ply: Int) -> Bool {
        guard (0...plies.count).contains(ply) else { return false }
        if ply == plies.count { return apply(move) }
        if plies[ply].uci == move.uci { return true }

        guard var replayed = rewound(to: ply), replayed.apply(move) else { return false }
        plies = replayed.plies
        state = replayed.state
        return true
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard !plies.isEmpty else { return false }
        let shortened = Array(plies.dropLast())
        guard let previous = Rules.probe(startFEN: startFEN, moves: shortened.map(\.uci))
        else { return false }
        plies = shortened
        state = previous
        return true
    }

    /// The Game as it stood after `ply` moves, for stepping through a Review.
    ///
    /// Replaying is what recomputes the Position, but it would also throw away what replaying
    /// cannot know — the Scores and Lines a Review recorded — so those are carried across
    /// afterwards.
    public func rewound(to ply: Int) -> Game? {
        guard (0...plies.count).contains(ply) else { return nil }
        guard var game = Game(startFEN: startFEN) else { return nil }
        for played in plies.prefix(ply) {
            guard game.apply(uci: played.uci) else { return nil }
        }
        for index in 0..<ply {
            game.plies[index].takeAnnotations(from: plies[index])
        }
        game.reviewDepth = reviewDepth
        game.startEvaluation = startEvaluation
        return game
    }

    /// Records a whole Review: one Score per ply, the starting position's, and the single
    /// Depth all of them were computed at.
    ///
    /// The only way an evaluation gets into a Game, and it takes the Depth in the same call
    /// on purpose — a Score without the Depth it was computed at is a number nothing may be
    /// compared against, and making that impossible to express is cheaper than remembering
    /// not to (docs/adr/0016).
    public mutating func applyReview(_ scores: [Score?], startEvaluation: Score?, depth: Int) {
        applyReview(
            scores.map { ReviewedPly(score: $0) }, startEvaluation: startEvaluation, depth: depth
        )
    }

    /// The same, from a pass that kept the Line each Score came out of.
    ///
    /// The Lines go in through here and through nowhere else, so "written by a Review" is a
    /// property of the code rather than a rule somebody has to remember (docs/adr/0016, 0021).
    public mutating func applyReview(
        _ reviewed: [ReviewedPly], startEvaluation: Score?, depth: Int
    ) {
        for (ply, result) in reviewed.enumerated() where plies.indices.contains(ply) {
            plies[ply].evaluation = result.score
            plies[ply].line = Array(result.line.prefix(Ply.lineLimit))
        }
        self.startEvaluation = startEvaluation
        self.reviewDepth = depth
    }

    /// The Review's Score for the position after `ply` moves — index 0 being the position the
    /// Game started from. Nil for a Game no Review has been over, whatever is in its fields.
    public func reviewScore(atPly ply: Int) -> Score? {
        guard isReviewed else { return nil }
        if ply == 0 { return startEvaluation }
        return plies.indices.contains(ply - 1) ? plies[ply - 1].evaluation : nil
    }

    /// The Review's Line from the position after `ply` moves, in SAN. Empty for a Game no Review
    /// has been over, whatever is in its fields — the same refusal `reviewScore` makes.
    public func reviewLine(atPly ply: Int) -> [String] {
        guard isReviewed, ply > 0, plies.indices.contains(ply - 1) else { return [] }
        return plies[ply - 1].line
    }

    /// Who played the `ply`th move, counting from one. Not always White: a Game recognised
    /// from a picture may well have started with Black to move.
    public func mover(ofPly ply: Int) -> PieceColour {
        ply.isMultiple(of: 2) ? startingSideToMove.opposite : startingSideToMove
    }

    /// The move number the `ply`th move is written under, counting plies from one.
    ///
    /// Not `(ply + 1) / 2`: that is only right for a Game that began at move one with White
    /// to move, and a Game recognised from a picture usually began neither. PGN's numbering
    /// hangs off `startingSideToMove` and `startingFullmoveNumber`, and this is the one place
    /// it is worked out.
    public func moveNumber(ofPly ply: Int) -> Int {
        startingSideToMove == .white
            ? startingFullmoveNumber + (ply - 1) / 2
            : startingFullmoveNumber + ply / 2
    }

    /// What a Review made of the move at `ply`, counting from one. Nil when the Game has not
    /// been reviewed, or when either side of the comparison is missing.
    public func quality(atPly ply: Int) -> MoveQuality? {
        guard ply > 0 else { return nil }
        return MoveQuality.of(
            move: mover(ofPly: ply),
            before: reviewScore(atPly: ply - 1),
            after: reviewScore(atPly: ply)
        )
    }

    /// Where a PGN's `[%eval]` comments land while a file is being read. Which of the two
    /// slots they go to is decided once, by whether the file carried a Review Depth.
    mutating func setEvaluation(_ score: Score?, atPly ply: Int, reviewed: Bool) {
        if ply < 0 {
            if reviewed { startEvaluation = score }
            return
        }
        guard plies.indices.contains(ply) else { return }
        if reviewed {
            plies[ply].evaluation = score
        } else {
            plies[ply].importedEvaluation = score
        }
    }

    /// Where a PGN's `[%line]` comments land. Only for a file that carried a Review Depth: a Line
    /// from somebody else's engine at a Depth nobody wrote down has no reader here and is dropped
    /// on the floor, which is what happened to every Line before this field existed.
    mutating func setLine(_ line: [String], atPly ply: Int, reviewed: Bool) {
        guard reviewed, ply >= 0, plies.indices.contains(ply) else { return }
        plies[ply].line = Array(line.prefix(Ply.lineLimit))
    }

    /// Set from the file's `[ReviewDepth]` tag as it is read, so the tag has exactly one home.
    mutating func setReviewDepth(_ depth: Int?) {
        reviewDepth = depth
    }

    /// PGN's result token for however the Game stands.
    public var resultToken: String {
        switch state.outcome {
        case .ongoing: "*"
        case .checkmate: state.sideToMove == .white ? "0-1" : "1-0"
        case .stalemate, .fiftyMoveRule, .threefoldRepetition, .insufficientMaterial:
            "1/2-1/2"
        }
    }
}

