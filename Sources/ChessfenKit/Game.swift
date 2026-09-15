/// A Game: where it started and what has been played. Everything else — the current
/// Position, whose turn it is, what is legal, whether it is over — is derived from those
/// two facts on demand, so undo is dropping an element and a variation is a slice
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
        /// The moves that were played from this ply's own starting position instead of this
        /// ply — each one an alternative to *this* move and everything that followed it.
        ///
        /// A Variation is how a line that was tried and left behind stops being lost. Step
        /// back to move ten, play something else, and the eleven moves that used to be there
        /// move in here rather than into the bin; PGN has written them in brackets since 1994
        /// and this is the same thing.
        public var variations: [[Ply]] = []
        /// What the player said this move was *for*, if they were asked (docs/adr/0018).
        ///
        /// Written by the player and by nobody else — no engine can produce one, which is the
        /// reason it is worth storing. Nil means nobody was asked; `.unclear` means somebody was
        /// asked and had no reason, and the difference between those two is the whole diagnosis.
        public var intent: Intent?
        /// How many Ply that Intent is a claim about, when it is a claim about more than this one.
        ///
        /// Nil is the ordinary case: the reason for this move. A number means the Intent belongs to
        /// the whole line this Ply starts — a 五步计划 — and reading it as the reason for the first
        /// move would be reading a sentence nobody said (docs/adr/0017, 0021). Capped at
        /// `planLimit`, because a claim about a longer line cannot be told false.
        public var intentSpan: Int?
        /// Whether this ply belongs to the Game's trunk — the line that was played, not a line
        /// that was tried from an earlier Ply and left hanging. The record colours the two
        /// differently, so a branch cannot be mistaken for the game.
        public var isTrunk: Bool

        public init(
            uci: String,
            san: String,
            evaluation: Score? = nil,
            importedEvaluation: Score? = nil,
            line: [String] = [],
            variations: [[Ply]] = [],
            intent: Intent? = nil,
            intentSpan: Int? = nil,
            isTrunk: Bool = true
        ) {
            self.uci = uci
            self.san = san
            self.evaluation = evaluation
            self.importedEvaluation = importedEvaluation
            self.line = line
            self.variations = variations
            self.intent = intent
            self.intentSpan = intentSpan
            self.isTrunk = isTrunk
        }

        /// The longest line one Intent is allowed to be a claim about.
        ///
        /// Five, and the number is about what can be checked rather than about how far people see:
        /// past about five Ply the opponent has had enough replies that no claim about the position
        /// is honestly falsifiable any more, and an Intent that cannot be told false is not one
        /// (docs/adr/0017, 0018).
        public static let planLimit = 5

        /// How many Ply of a Review's Line are kept.
        ///
        /// Four moves each side. Past that a Line at Review Depth is a claim about a position the
        /// opponent has had four chances to disagree with, nothing in the app reads further, and
        /// every extra move is bytes in every file for as long as the file exists.
        public static let lineLimit = 8

        /// Takes over everything that is *said about* a move rather than being the move.
        ///
        /// Replaying a line recomputes `uci` and `san` and loses all of this, so anything that
        /// replays — `rewound(to:)`, promoting a Variation — puts it back through here. One list
        /// in one place, because the way this goes wrong is a field being added and only two of
        /// the three call sites remembering it.
        mutating func takeAnnotations(from other: Self) {
            evaluation = other.evaluation
            importedEvaluation = other.importedEvaluation
            line = other.line
            variations = other.variations
            intent = other.intent
            isTrunk = other.isTrunk
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
        plies.append(Ply(uci: move.uci, san: san, isTrunk: plies.last?.isTrunk ?? true))
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

    /// Plays a move from the position after `ply` moves, keeping whatever used to be played
    /// from there as a Variation.
    ///
    /// This is what browsing back and playing something else does. Three cases, and the
    /// third is the interesting one: past the end is not a thing, playing the move that is
    /// already there just carries on down the line that exists, and anything else branches.
    @discardableResult
    public mutating func play(_ move: Move, atPly ply: Int) -> Bool {
        guard (0...plies.count).contains(ply) else { return false }
        if ply == plies.count { return apply(move) }
        if plies[ply].uci == move.uci { return true }

        guard var branch = rewound(to: ply), branch.apply(move) else { return false }

        // The line being left behind, with everything that hung off it, becomes an
        // alternative to the move now standing in its place.
        let abandoned = Array(plies[ply...])
        var replacement = branch.plies[ply]
        replacement.isTrunk = false
        replacement.variations = [abandoned]
        // Alternatives already recorded at this point are alternatives to the same position,
        // so they belong to the new move too rather than to the line that just left.
        replacement.variations.append(contentsOf: abandoned.first?.variations ?? [])

        plies = Array(plies[..<ply]) + [replacement]
        state = branch.state
        return true
    }

    /// Records a line as an alternative to the move at `ply`. Used when reading a PGN, where
    /// the brackets arrive after the move they belong to.
    public mutating func addVariation(_ variation: [Ply], atPly ply: Int) {
        guard plies.indices.contains(ply), !variation.isEmpty else { return }
        plies[ply].variations.append(variation.map { ply in
            var copy = ply
            copy.isTrunk = false
            return copy
        })
    }

    /// Records a Guess, and what the player said it was for, as an alternative to the move at
    /// `ply` — counting from zero, like `addVariation`.
    ///
    /// This is where a Drill's answer goes when it is not the move that was played. It belongs in
    /// a Variation and not on the played Ply: writing "the reason for Nf3" against a game where
    /// the player proposed d4 would put a sentence in the file that nobody ever said.
    ///
    /// Answering the same question twice with the same move updates that alternative rather than
    /// leaving two of them, because a file full of duplicate one-move brackets is how the record
    /// stops being readable.
    @discardableResult
    public mutating func recordGuess(
        uci: String, san: String, intent: Intent?, atPly ply: Int
    ) -> Bool {
        guard plies.indices.contains(ply) else { return false }
        if let existing = plies[ply].variations.firstIndex(where: { $0.first?.uci == uci }) {
            plies[ply].variations[existing][0].intent = intent
            return true
        }
        plies[ply].variations.append([Ply(uci: uci, san: san, intent: intent, isTrunk: false)])
        return true
    }

    /// The lines that were played from the same position as the move at `ply`.
    public func variations(atPly ply: Int) -> [[Ply]] {
        plies.indices.contains(ply) ? plies[ply].variations : []
    }

    /// One of the moves that can be played from the position at `ply`, including the one
    /// currently standing there. The trunk is numbered first, then the branches, so a swipe
    /// that cycles them does not renumber the tree.
    public struct Sibling: Hashable, Sendable {
        /// 1-based, trunk first.
        public let number: Int
        /// Nil when this sibling is the ply currently in the Game's line.
        public let variationIndex: Int?
        public let san: String
        public let isTrunk: Bool
    }

    public func siblings(atPly ply: Int) -> [Sibling] {
        guard plies.indices.contains(ply) else { return [] }
        var items: [(variationIndex: Int?, head: Ply)] = [(nil, plies[ply])]
        for (index, line) in plies[ply].variations.enumerated() {
            guard let head = line.first else { continue }
            items.append((index, head))
        }
        items.sort { a, b in
            if a.head.isTrunk != b.head.isTrunk { return a.head.isTrunk && !b.head.isTrunk }
            if a.head.san != b.head.san { return a.head.san < b.head.san }
            return (a.variationIndex ?? -1) < (b.variationIndex ?? -1)
        }
        return items.enumerated().map { offset, item in
            Sibling(
                number: offset + 1,
                variationIndex: item.variationIndex,
                san: item.head.san,
                isTrunk: item.head.isTrunk
            )
        }
    }

    /// Takes a Variation as the line to carry on with, and puts the line it replaces where it
    /// came from. Stepping into a branch, in other words.
    @discardableResult
    public mutating func promoteVariation(_ index: Int, atPly ply: Int) -> Bool {
        guard plies.indices.contains(ply) else { return false }
        let alternatives = plies[ply].variations
        guard alternatives.indices.contains(index) else { return false }

        var chosen = alternatives[index]
        var abandoned = Array(plies[ply...])
        abandoned[0].variations = []

        var rest = alternatives
        rest.remove(at: index)
        chosen[0].variations = [abandoned] + rest

        guard let head = rewound(to: ply) else { return false }
        var rebuilt = head
        for step in chosen {
            guard rebuilt.apply(uci: step.uci) else { return false }
        }
        // Replay dropped everything that was said *about* these moves, so it goes back on.
        // The Review Depth carries across untouched: it says what Depth the Scores that
        // exist were computed at, and a promoted line's plies either carry Scores from the
        // same pass or carry none — in which case `reviewScore` is nil and nothing about
        // them is judged. A ply with no Score is never a mistake.
        for (offset, step) in chosen.enumerated() {
            rebuilt.plies[ply + offset].takeAnnotations(from: step)
        }
        self = rebuilt
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
    /// cannot know — the Scores a Review recorded, the Variations that hang off the moves, and
    /// what the player said each one was for — so those are carried across afterwards.
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

    /// Declares what the move at `ply` was for, counting from one — or takes the declaration
    /// back, with nil.
    ///
    /// Counting from one rather than from zero, unlike the two setters above, because an Intent
    /// belongs to a move somebody played: there is no Intent for the position a Game started
    /// from, so there is no ply 0 to address.
    @discardableResult
    public mutating func setIntent(_ intent: Intent?, atPly ply: Int) -> Bool {
        guard plies.indices.contains(ply - 1) else { return false }
        plies[ply - 1].intent = intent
        return true
    }

    /// What the player said the move at `ply` was for, counting from one.
    public func intent(atPly ply: Int) -> Intent? {
        plies.indices.contains(ply - 1) ? plies[ply - 1].intent : nil
    }

    /// Records how far the Intent at `ply` reaches, counting from one. Used when reading a PGN.
    @discardableResult
    public mutating func setIntentSpan(_ span: Int?, atPly ply: Int) -> Bool {
        guard plies.indices.contains(ply - 1) else { return false }
        plies[ply - 1].intentSpan = span.map { min(max(1, $0), Ply.planLimit) }
        return true
    }

    /// Records a line of the player's own, with one Intent over the whole of it.
    ///
    /// It goes in as a Variation, because that is what it is — a line played from this position
    /// instead of the move that was played — and the Game and the PGN already know how to hold one.
    /// What is new is only that the Intent on its first Ply carries a span, so the claim reads as
    /// being about the plan and not about its first move (docs/adr/0017).
    ///
    /// Refused rather than truncated when the line is longer than `Ply.planLimit`: a plan that
    /// cannot be checked is a wish, and silently keeping the first five moves of somebody's
    /// seven-move idea would be judging a claim they did not make.
    @discardableResult
    public mutating func recordPlan(
        _ line: [(uci: String, san: String)], intent: Intent, atPly ply: Int
    ) -> Bool {
        guard plies.indices.contains(ply), !line.isEmpty, line.count <= Ply.planLimit
        else { return false }
        var written = line.map { Ply(uci: $0.uci, san: $0.san, isTrunk: false) }
        written[0].intent = intent
        written[0].intentSpan = line.count
        // The same rule `recordGuess` follows: answering the same question twice with the same
        // first move replaces that alternative rather than leaving two of them.
        if let existing = plies[ply].variations.firstIndex(where: {
            $0.first?.uci == written[0].uci && $0.first?.intentSpan != nil
        }) {
            plies[ply].variations[existing] = written
        } else {
            plies[ply].variations.append(written)
        }
        return true
    }

    /// The plans recorded against the move at `ply` — the Variations whose first Ply carries an
    /// Intent about the whole line rather than about itself.
    public func plans(atPly ply: Int) -> [Plan] {
        variations(atPly: ply).compactMap { variation in
            guard let first = variation.first, let intent = first.intent,
                let span = first.intentSpan
            else { return nil }
            return Plan(line: Array(variation.prefix(span)), intent: intent)
        }
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

/// A line of the player's own with one Intent over the whole of it.
///
/// The unbuilt consequence of docs/adr/0017, finally built. An Intent used to attach to a single
/// Ply, which meant a plan could only ever be declared one move at a time — and 「我要占住 d5」 is
/// not a claim about one move. It is a claim about five, and it is checkable exactly because it is
/// capped at five: past that the opponent has had enough replies that no claim about the position
/// can be told false, and a verb that cannot be wrong does not get one of the eight slots
/// (docs/adr/0018).
public struct Plan: Hashable, Sendable {
    /// The moves of the plan, in order. At most `Game.Ply.planLimit` of them.
    public let line: [Game.Ply]
    /// The one claim, about the whole line.
    public let intent: Intent

    public var sans: [String] { line.map(\.san) }
    public var steps: Int { line.count }
}
