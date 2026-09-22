/// A Game: where it started and what has been played. Everything else — the current
/// Position, whose turn it is, what is legal, whether it is over — is derived from those
/// two facts on demand, so undo is dropping an element and a 分支 is a slice
/// (docs/adr/0003, 0043).
public struct Game: Hashable, Sendable {
    /// One move as played, kept with the SAN it was written as. SAN is stored rather than
    /// recomputed because it depends on the position the move was made in, and that
    /// position is gone once the move is played.
    public struct Ply: Hashable, Sendable {
        /// Everything said *about* a move rather than the move itself.
        ///
        /// One value, because replaying a line recomputes `uci` and `san` and loses all of it,
        /// so anything that replays puts it back through `takeAnnotations`. That used to copy
        /// nine fields one by one, with the comment already confessing the failure mode: "a
        /// field being added and only two of the three call sites remembering it." A struct
        /// cannot be half-copied. The fields stay reachable one by one below — the interface is
        /// unchanged — but they are windows onto this.
        public struct Annotations: Hashable, Sendable {
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
            /// written by a **Review and by nothing else** — the same rule as `evaluation`, and
            /// for the same reason: a Line from a search at some other Depth cannot be compared
            /// with the Lines around it (docs/adr/0016, 0021).
            ///
            /// Empty rather than optional. "The Review had nothing to say here" and "there has
            /// been no Review" are told apart by `reviewDepth`, which is where every other
            /// question about provenance is already answered.
            public var line: [String] = []
            /// The moves 把关 refused before this one was allowed to stand, in the order they
            /// were played (docs/adr/0027).
            ///
            /// A comment on the move that stands rather than a 分支, because that is what they
            /// are: a rolled-back move is a thing that happened at this position rather than
            /// another line that might have been played (docs/adr/0028). Their cost was measured
            /// when they were refused and is written down with them — nothing recomputes it
            /// later, because the position they were refused in is gone.
            public var tried: [Tried] = []
            /// The lines played from this Ply's own starting position instead of this Ply —
            /// each one an alternative to *this* move and everything that followed it
            /// (docs/adr/0043).
            ///
            /// A 分支 is how a line that was played and then played over stops being lost. Step
            /// back to move ten of an imported game, play something else, and the thirty moves
            /// that were there move in here rather than into the bin; PGN has written them in
            /// brackets since 1994 and this is the same thing.
            public var variations: [[Ply]] = []
            /// Whether this Ply belongs to the 树干 — the line the game arrived as, imported or
            /// played out — rather than a line tried from an earlier Ply. The record colours the
            /// two differently, so a 树枝 cannot be mistaken for the game.
            public var isTrunk: Bool = true
            /// How many rungs of the hint ladder were open when the move that stands was played
            /// (docs/adr/0031). Zero is "unaided", which is the ordinary case.
            public var hints: Int = 0
            /// The completed interception judgement, kept separate from a full-game Review.
            public var judgement: Judgement?
            /// The 棋力 the engine played this move at, for a move the engine played under its
            /// own Controller; nil for a move by hand (docs/adr/0038). 满力 is written as such
            /// rather than left blank, because a blank is a hand, and the 连正榜 has to tell the
            /// two apart.
            public var strength: Strength?

            public init() {}
        }

        public let uci: String
        public let san: String
        /// Everything said about this move rather than the move itself. Copied in one
        /// assignment when a line is replayed (`takeAnnotations`).
        public var annotations = Annotations()

        public var evaluation: Score? {
            get { annotations.evaluation }
            set { annotations.evaluation = newValue }
        }
        public var importedEvaluation: Score? {
            get { annotations.importedEvaluation }
            set { annotations.importedEvaluation = newValue }
        }
        public var line: [String] {
            get { annotations.line }
            set { annotations.line = newValue }
        }
        public var tried: [Tried] {
            get { annotations.tried }
            set { annotations.tried = newValue }
        }
        public var variations: [[Ply]] {
            get { annotations.variations }
            set { annotations.variations = newValue }
        }
        public var isTrunk: Bool {
            get { annotations.isTrunk }
            set { annotations.isTrunk = newValue }
        }
        public var hints: Int {
            get { annotations.hints }
            set { annotations.hints = newValue }
        }
        public var judgement: Judgement? {
            get { annotations.judgement }
            set { annotations.judgement = newValue }
        }
        public var strength: Strength? {
            get { annotations.strength }
            set { annotations.strength = newValue }
        }

        public struct Judgement: Hashable, Sendable {
            public let drop: Double
            public let score: Score
            public let depth: Int
            /// The 拦截线 the move stood under, or nil for a move weighed with 把关 off.
            ///
            /// Every move that lands is weighed, not only under 把关, and the two are told apart
            /// here: 连正 counts the moves that *stood* — that could have been taken back and
            /// were not — and a move nothing would have refused is not one of those
            /// (CONTEXT.md, 连正).
            public let intercept: Double?
            /// 最佳: the move was the engine's own first choice, by the search that judged it
            /// (CONTEXT.md). Written down, because it is a fact about which move it was and not
            /// one a 掉幅 of nought can stand in for: two equally good moves both cost nothing.
            public let best: Bool

            public init(
                drop: Double, score: Score, depth: Int, intercept: Double? = nil, best: Bool = false
            ) {
                self.drop = max(0, drop)
                self.score = score
                self.depth = depth
                self.intercept = intercept
                self.best = best
            }

            /// Whether the move stood under 把关.
            public var stoodUnderNoSlips: Bool { intercept != nil }
        }

        /// One move 把关 took back, and what it cost.
        public struct Tried: Hashable, Sendable {
            public let san: String
            /// Percentage points of win probability, from the mover's own side (docs/adr/0027).
            public let drop: Double
            public let notFound: Bool
            /// The 应招 the move earned: the Line the engine already had for the position the
            /// move made, the opponent's move first (docs/adr/0034).
            ///
            /// Kept with the 试招 rather than searched for later, because the search that
            /// judged the move had this in hand and nothing afterwards needs to run again to
            /// say what the move was asking for. Empty for a move refused before replies were
            /// written down, and for one that left no position to answer in.
            public let line: [String]
            /// The Depth the 掉幅 was worked out at, so a number a 复判 took deeper can be told
            /// from an everyday one (docs/adr/0041). Nil for a move read from a file written
            /// before depths were kept: unknown, and never guessed at.
            public let depth: Int?

            public init(
                san: String, drop: Double, notFound: Bool = false, depth: Int? = nil,
                line: [String] = []
            ) {
                self.san = san
                self.drop = drop
                self.notFound = notFound
                self.depth = depth
                self.line = Array(line.prefix(Reply.limit))
            }
        }

        public init(
            uci: String,
            san: String,
            evaluation: Score? = nil,
            importedEvaluation: Score? = nil,
            line: [String] = [],
            tried: [Tried] = [],
            hints: Int = 0,
            judgement: Judgement? = nil,
            strength: Strength? = nil,
            variations: [[Ply]] = [],
            isTrunk: Bool = true,
        ) {
            self.uci = uci
            self.san = san
            self.evaluation = evaluation
            self.importedEvaluation = importedEvaluation
            self.line = line
            self.tried = tried
            self.hints = hints
            self.judgement = judgement
            self.strength = strength
            self.variations = variations
            self.isTrunk = isTrunk
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
        /// replays — `rewound(to:)`, stepping into a 分支 — puts it back through here. One list
        /// in one place, because the way this goes wrong is a field being added and only two of
        /// the three call sites remembering it.
        mutating func takeAnnotations(from other: Self) {
            annotations = other.annotations
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

    /// The 试招 made at one position, which no move has been played there to carry yet.
    ///
    /// A refused move normally rides onto the move that finally stands — `[%tried]` on that move,
    /// which is what it is: something that happened at the position *before* it. When no such move
    /// is played, the position it did happen at has to be named some other way, and in a Game a
    /// position is named by how many Plies have been played at it (docs/adr/0037).
    public struct Pending: Hashable, Sendable {
        /// Plies played at the position these were refused at. Zero is the opening.
        public let ply: Int
        public let tries: [Ply.Tried]

        public init(ply: Int, tries: [Ply.Tried]) {
            self.ply = ply
            self.tries = tries
        }
    }

    public private(set) var pendingTried: [Pending] = []

    /// Records the refusals made at a position, replacing whatever was there: a position 把关
    /// stopped the player at three times has three refusals, not six.
    public mutating func setPendingTried(_ tries: [Ply.Tried], atPly ply: Int) {
        pendingTried.removeAll { $0.ply == ply }
        guard !tries.isEmpty, ply >= 0 else { return }
        pendingTried.append(Pending(ply: ply, tries: tries))
        pendingTried.sort { $0.ply < $1.ply }
    }

    /// The 试招 refused at the position after `ply` moves that no move has absorbed, oldest
    /// first. Empty for a position nobody has been stopped at.
    public func pendingTries(atPly ply: Int) -> [Ply.Tried] {
        pendingTried.first { $0.ply == ply }?.tries ?? []
    }

    /// Writes one more refusal down at the position it happened at, after the ones already
    /// there (docs/adr/0037). The one door a refusal comes in by while no move stands to carry
    /// it — 把关's and a drill's alike.
    public mutating func recordTried(_ tried: Ply.Tried, atPly ply: Int) {
        setPendingTried(pendingTries(atPly: ply) + [tried], atPly: ply)
    }

    /// The move at `ply` takes the refusals made at the position it was played from: they
    /// become its `tried`, and the pending slot at that position is emptied. A move that found
    /// nothing to take leaves whatever the move already carried — playing the move that is
    /// already there is not a new move.
    public mutating func absorbPendingTried(atPly ply: Int) {
        let taken = pendingTries(atPly: ply)
        if !taken.isEmpty {
            setTried(taken, atPly: ply)
        }
        setPendingTried([], atPly: ply)
    }

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
        // A move carried on from a 树枝 is on that 树枝: the 树干 is one path from the opening,
        // and nothing appended past a fork can rejoin it (docs/adr/0043).
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

    /// Plays a move from the position after `ply` moves, keeping whatever used to be played from
    /// there as a 分支.
    ///
    /// This is what browsing back and playing something else does. Three cases, and the third is
    /// the interesting one: past the end is not a thing, playing the move that is already there
    /// just carries on down the line that exists, and anything else **branches**: the line that
    /// was there moves in beside the new move, whole, and can be stepped back into
    /// (docs/adr/0043). It used to replace the rest (docs/adr/0028), which on an imported game
    /// meant that trying one idea from move ten wrote over the thirty moves somebody played.
    @discardableResult
    public mutating func play(_ move: Move, atPly ply: Int) -> Bool {
        guard (0...plies.count).contains(ply) else { return false }
        if ply == plies.count { return apply(move) }
        if plies[ply].uci == move.uci { return true }

        guard var branch = rewound(to: ply), branch.apply(move) else { return false }

        // The line being left behind, with everything that hung off it, becomes an alternative
        // to the move now standing in its place — and the refusals made along it go with it.
        var abandoned = Array(plies[ply...])
        carryRefusals(into: &abandoned, from: ply)
        var replacement = branch.plies[ply]
        replacement.isTrunk = false
        replacement.variations = [abandoned]
        // Alternatives already recorded at this point are alternatives to the same position, so
        // they belong to the new move too rather than to the line that just left.
        replacement.variations.append(contentsOf: abandoned[0].variations)
        replacement.variations[0][0].variations = []

        plies = Array(plies[..<ply]) + [replacement]
        state = branch.state
        return true
    }

    /// The same, for a move named by its UCI — what a ruling has in hand once the move has been
    /// weighed (docs/adr/0035).
    @discardableResult
    public mutating func play(uci: String, atPly ply: Int) -> Bool {
        guard let move = rewound(to: ply)?.state.move(matching: uci) else { return false }
        return play(move, atPly: ply)
    }

    /// Moves the refusals made past `ply` onto the line that is leaving the trunk, so a 错题
    /// made on that line is still written on it when it comes back (docs/adr/0037, 0043).
    ///
    /// A refusal at a position along the line rides onto the move that stands there — the same
    /// door it takes when the player carries on down the line — and the refusals at `ply` itself
    /// stay: the new move was played from that position, and they are its to take. A refusal at
    /// the end of the line has no move to ride on and no position on the trunk any more; it is
    /// the one thing this loses, and it is written to the file as long as the line is the game.
    private mutating func carryRefusals(into line: inout [Ply], from ply: Int) {
        for pending in pendingTried where pending.ply > ply {
            let index = pending.ply - ply
            guard line.indices.contains(index) else { continue }
            line[index].tried = pending.tries + line[index].tried
        }
        pendingTried.removeAll { $0.ply > ply }
    }

    /// Records a line as an alternative to the move at `ply`. Used when reading a PGN, where the
    /// brackets arrive after the move they belong to. Whether the line is 树干 or 树枝 is the
    /// line's own to say (`setBranch`): a file is read with the line on the board first, and that
    /// line is not always the trunk.
    public mutating func addVariation(_ variation: [Ply], atPly ply: Int) {
        guard plies.indices.contains(ply), !variation.isEmpty else { return }
        plies[ply].variations.append(variation)
    }

    /// The lines that were played from the same position as the move at `ply`.
    public func variations(atPly ply: Int) -> [[Ply]] {
        plies.indices.contains(ply) ? plies[ply].variations : []
    }

    /// One of the moves that can be played from the position at `ply`, including the one
    /// currently standing there. The 树干 is numbered first, then the 树枝, so a swipe that
    /// cycles them does not renumber the tree.
    public struct Sibling: Hashable, Sendable {
        /// 1-based, trunk first.
        public let number: Int
        /// Nil when this sibling is the Ply currently in the Game's line.
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

    /// Takes a 分支 as the line to carry on with, and puts the line it replaces where it came
    /// from. Stepping into a branch, in other words.
    @discardableResult
    public mutating func promoteVariation(_ index: Int, atPly ply: Int) -> Bool {
        guard plies.indices.contains(ply) else { return false }
        let alternatives = plies[ply].variations
        guard alternatives.indices.contains(index) else { return false }

        var chosen = alternatives[index]
        var abandoned = Array(plies[ply...])
        abandoned[0].variations = []
        carryRefusals(into: &abandoned, from: ply)

        var rest = alternatives
        rest.remove(at: index)
        chosen[0].variations = [abandoned] + rest

        guard let head = rewound(to: ply) else { return false }
        var rebuilt = head
        for step in chosen {
            guard rebuilt.apply(uci: step.uci) else { return false }
        }
        // Replay dropped everything that was said *about* these moves, so it goes back on. The
        // Review Depth carries across untouched: it says what Depth the Scores that exist were
        // computed at, and a promoted line's Plies either carry Scores from the same pass or
        // carry none — in which case `reviewScore` is nil and nothing about them is judged.
        for (offset, step) in chosen.enumerated() {
            rebuilt.plies[ply + offset].takeAnnotations(from: step)
        }
        rebuilt.pendingTried = pendingTried
        self = rebuilt
        return true
    }

    /// Whether any position in the Game has more than one line played from it.
    public var hasBranches: Bool {
        plies.contains { !$0.variations.isEmpty }
    }

    /// Where a PGN's `[%branch]` lands: the Ply just read is a 树枝, and so is everything that
    /// follows it on its line (docs/adr/0043). A file is read with the line on the board as the
    /// mainline, and that is not always the 树干.
    mutating func setBranch(atPly ply: Int) {
        guard plies.indices.contains(ply) else { return }
        for index in ply..<plies.count {
            plies[index].isTrunk = false
        }
    }

    /// Where a PGN's `[%trunk]` lands: the bracketed line whose head was just read is the 树干,
    /// from that Ply on (docs/adr/0043).
    mutating func setTrunk(atPly ply: Int) {
        guard plies.indices.contains(ply) else { return }
        for index in ply..<plies.count {
            plies[index].isTrunk = true
        }
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard !plies.isEmpty else { return false }
        let shortened = Array(plies.dropLast())
        guard let previous = Rules.probe(startFEN: startFEN, moves: shortened.map(\.uci))
        else { return false }
        plies = shortened
        state = previous
        pendingTried.removeAll { $0.ply > plies.count }
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
        // The refusals made at positions along the way are still at those positions: a game cut
        // short at Ply 2 was stopped at Ply 2 as surely as the whole game was, and the move
        // played from there is the one that takes them (docs/adr/0037).
        game.pendingTried = pendingTried.filter { $0.ply <= ply }
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

    /// The `ply`th move's place as a scoresheet writes it: `12.` for White's move, `12…` for
    /// Black's. Counted the same way for the move nobody has played yet — a 错招 at the end of a
    /// game sits at the Ply one past the last move (docs/adr/0037), and that is the place the
    /// next move takes.
    public func moveLabel(ofPly ply: Int) -> String {
        "\(moveNumber(ofPly: ply))\(mover(ofPly: ply) == .white ? "." : "…")"
    }

    /// One half of a scoresheet row: the move, the Ply it stands at — which is the cursor that
    /// puts it on the board — and where it sits in the tree: 树干 or a numbered 树枝, and how
    /// many lines fork from the position it was played from (docs/adr/0043).
    public struct Half: Hashable, Sendable {
        public let ply: Int
        public let san: String
        public let isTrunk: Bool
        /// This move's number among the lines played from its position, 树干 first.
        public let branchNumber: Int
        /// How many lines were played from its position; one for a position nobody forked at.
        public let siblingCount: Int

        public init(ply: Int, san: String, isTrunk: Bool = true, branchNumber: Int = 1, siblingCount: Int = 1) {
            self.ply = ply
            self.san = san
            self.isTrunk = isTrunk
            self.branchNumber = branchNumber
            self.siblingCount = siblingCount
        }

        /// Whether the position this move was played from has more than one line out of it.
        public var isFork: Bool { siblingCount > 1 }

        /// Said the way somebody reading a game aloud says it: a bare "Nf6" out of VoiceOver is a
        /// move with no place in the game, and place is the whole of what the record strip is
        /// for — and on a fork, which line this is of the ones played from here (docs/adr/0043).
        public var spoken: String {
            let step = localized("screen.spokenMove", ply, san)
            guard isFork else { return step }
            let place = localized(isTrunk ? "record.trunk" : "record.twig", branchNumber, siblingCount)
            return step + localized("clause.separator") + place
        }
    }

    /// One move number and its two halves — the way a scoresheet is ruled, and the unit a
    /// record of the game is read in. A Game recognised from a picture usually begins in the
    /// middle of a row, with Black to move, and then the first row has no White half.
    public struct ScoresheetRow: Identifiable, Hashable, Sendable {
        public let number: Int
        public let white: Half?
        public let black: Half?
        public var id: Int { number }
    }

    /// The moves as a scoresheet rules them. The numbering hangs off where the Game began, and
    /// this is the one walk that lays the moves out under it.
    public var scoresheet: [ScoresheetRow] {
        var rows: [ScoresheetRow] = []
        for (index, ply) in plies.enumerated() {
            let siblings = siblings(atPly: index)
            let half = Half(
                ply: index + 1, san: ply.san, isTrunk: ply.isTrunk,
                branchNumber: siblings.first { $0.variationIndex == nil }?.number ?? 1,
                siblingCount: siblings.count
            )
            let number = moveNumber(ofPly: index + 1)
            if mover(ofPly: index + 1) == .white {
                rows.append(ScoresheetRow(number: number, white: half, black: nil))
            } else if let last = rows.last, last.number == number, last.black == nil {
                rows[rows.count - 1] = ScoresheetRow(number: number, white: last.white, black: half)
            } else {
                rows.append(ScoresheetRow(number: number, white: nil, black: half))
            }
        }
        return rows
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

    /// How much win probability the move at `ply` gave away, from its own mover's point of view
    /// (docs/adr/0027). Nil for a Game no Review has been over — which is not zero.
    public func drop(atPly ply: Int) -> Double? {
        guard ply > 0 else { return nil }
        return MoveQuality.drop(
            move: mover(ofPly: ply),
            before: reviewScore(atPly: ply - 1),
            after: reviewScore(atPly: ply)
        )
    }

    /// What the move at `ply` cost, by whatever number the Game already holds for it: the
    /// judgement 把关 or the badge wrote on it first, else what a Review makes of it — the rule
    /// the 错招 list uses (docs/adr/0036). Nil for a move nobody has measured, which is not zero.
    public func cost(atPly ply: Int) -> Double? {
        guard ply > 0, plies.indices.contains(ply - 1) else { return nil }
        return plies[ply - 1].judgement?.drop ?? drop(atPly: ply)
    }

    /// 最佳: whether the move at `ply` was the engine's own first choice from the position it
    /// was played from (CONTEXT.md). By the judgement that let it stand, which wrote the fact
    /// down; or by the Review, whose Line from the position before names the move it wanted
    /// there. Never by a cost that rounded to nought.
    public func isBest(atPly ply: Int) -> Bool {
        guard ply > 0, plies.indices.contains(ply - 1) else { return false }
        if let judgement = plies[ply - 1].judgement { return judgement.best }
        return reviewLine(atPly: ply - 1).first == plies[ply - 1].san
    }

    /// Whether any move in the Game has a cost to show. A record with nothing measured in it
    /// has no line of costs to draw.
    public var hasCosts: Bool {
        plies.indices.contains { cost(atPly: $0 + 1) != nil }
    }

    /// What came of the opponent's mistake the move at `ply` was the reply to, or nil when the
    /// move before it gave nothing away.
    ///
    /// Asked about the *reply*, which is what makes this a settlement rather than a warning: it
    /// can only be answered once the reply exists, so there is no state in which the screen knows
    /// there is something to win and the player does not (docs/adr/0027). Every Score it reads
    /// comes from the one Review, so all three are at one depth (docs/adr/0016).
    public func settlement(atPly ply: Int, lines: JudgementLines = .standard) -> Settlement? {
        guard ply > 1 else { return nil }
        return Settlement(
            player: mover(ofPly: ply),
            before: reviewScore(atPly: ply - 2),
            afterTheirMove: reviewScore(atPly: ply - 1),
            afterMyReply: reviewScore(atPly: ply),
            lines: lines
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

    /// Where a PGN's `[%tried]` comments land. Not gated on a Review Depth, unlike the Scores:
    /// a refused move's cost was measured when it was refused and written down with it, so it is
    /// a fact about what happened at the board rather than a number from somebody's engine at an
    /// unknown depth (docs/adr/0016 is about the second kind).
    mutating func addTried(_ attempt: Ply.Tried, atPly ply: Int) {
        guard plies.indices.contains(ply) else { return }
        plies[ply].tried.append(attempt)
    }

    mutating func setHints(_ rungs: Int, atPly ply: Int) {
        guard plies.indices.contains(ply), rungs > 0 else { return }
        plies[ply].hints = rungs
    }

    /// Records what 把关 refused before the move at `ply` was allowed to stand.
    public mutating func setJudgement(_ judgement: Ply.Judgement, atPly ply: Int) {
        guard plies.indices.contains(ply) else { return }
        plies[ply].judgement = judgement
    }

    public mutating func setTried(_ attempts: [Ply.Tried], hints: Int = 0, atPly ply: Int) {
        guard plies.indices.contains(ply) else { return }
        plies[ply].tried = attempts
        plies[ply].hints = hints
    }

    /// Records the 棋力 the engine played the move at `ply` at (docs/adr/0038).
    public mutating func setStrength(_ strength: Strength?, atPly ply: Int) {
        guard plies.indices.contains(ply) else { return }
        plies[ply].strength = strength
    }

    /// The 棋力 the `ply`th move was played at, counting from one.
    ///
    /// An engine move's own; for a move by hand, the 棋力 of the engine move that answered it —
    /// that is the opponent the move was played against — or, when nothing answered because the
    /// game ended there, of the engine move before it. Nil against a human, and nil for every
    /// game saved before 棋力 was written down, which the 连正榜 credits to no rung.
    ///
    /// This is the whole of what a "stretch" is (docs/adr/0038): a game can change 棋力 as it
    /// goes, and each move is credited to the rung in force when it was played. Nothing needs the
    /// stretches listed out as ranges — the 连正榜 reads the rung move by move.
    public func strength(ofPly ply: Int) -> Strength? {
        guard plies.indices.contains(ply - 1) else { return nil }
        if let own = plies[ply - 1].strength { return own }
        if plies.indices.contains(ply), let reply = plies[ply].strength { return reply }
        if ply >= 2, let before = plies[ply - 2].strength { return before }
        return nil
    }

    /// The one Elo every engine move by `colour` was played at, or nil when there was none, the
    /// rung changed, or the engine was at 满力 — the cases where a standard `WhiteElo` tag would
    /// be a lie (docs/adr/0038).
    public func constantElo(of colour: PieceColour) -> Int? {
        var rungs: Set<Strength> = []
        for (index, ply) in plies.enumerated() where mover(ofPly: index + 1) == colour {
            if let strength = ply.strength { rungs.insert(strength) }
        }
        guard rungs.count == 1, let only = rungs.first else { return nil }
        return only.elo
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
