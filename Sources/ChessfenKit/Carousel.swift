/// Where a whole Line arrived, as against where it started.
///
/// A carousel that only recites moves is a carousel nobody learns from: you watch five plies go by,
/// the position is different, and the difference is exactly what a beginner cannot see. So the end
/// of the line is compared with the start and the difference is said in one sentence, out of the
/// same fixed templates over checkable facts the rest of the layer uses (docs/adr/0018, 0021).
public struct LineOutcome: Hashable, Sendable {
    /// How many plies were walked.
    public let steps: Int
    /// The clauses, in the order they are said. Kept apart from `sentence` so a test can name one
    /// without matching a whole paragraph.
    public let clauses: [String]
    /// 「5 步之后，d5 里坐着一个赶不走的马，你的王边少了 2 个守卫。」
    public var sentence: String {
        guard !clauses.isEmpty else { return "\(steps) 步之后，位置没什么实质变化。" }
        return "\(steps) 步之后，\(clauses.joined(separator: "，"))。"
    }
}

extension Game {
    /// What a Line adds up to, from the point of view of the side to move now.
    ///
    /// Nil when the Line will not replay from this position — an honest refusal, because a sentence
    /// about a line that was never played is a sentence about nothing.
    ///
    /// Three facts and no more: what was taken, what got a square it cannot be thrown off, and what
    /// the side's own king lost. Each one is a count anybody can go and check on the board, and each
    /// clause is omitted when its count is zero rather than being written as a zero.
    public func outcome(of line: [String]) -> LineOutcome? {
        guard !line.isEmpty,
            let beforePieces = BoardRenderer.placement(state.fen),
            let beforeControl = Rules.control(startFEN: startFEN, moves: uciMoves)
        else { return nil }
        let mover = state.sideToMove
        let opponent = mover.opposite

        var end = self
        for san in line {
            guard end.apply(san: san) else { return nil }
        }
        guard let afterPieces = BoardRenderer.placement(end.state.fen),
            let afterControl = Rules.control(startFEN: end.startFEN, moves: end.uciMoves)
        else { return nil }

        var clauses: [String] = []

        // What was taken, named rather than scored: "1 个马" is a thing to look for on the board
        // where "+2.9" is a thing to be told.
        func lost(_ colour: PieceColour) -> [(PieceKind, Int)] {
            PieceKind.allCases.compactMap { kind -> (PieceKind, Int)? in
                func count(_ pieces: [Square: Piece]) -> Int {
                    pieces.values.count { $0.colour == colour && $0.kind == kind }
                }
                let gone = count(beforePieces) - count(afterPieces)
                return gone > 0 ? (kind, gone) : nil
            }
        }
        func list(_ losses: [(PieceKind, Int)]) -> String {
            losses.map { "\($0.1) 个\($0.0.name)" }.joined(separator: "、")
        }
        let mine = lost(mover)
        let theirs = lost(opponent)
        if !mine.isEmpty || !theirs.isEmpty {
            let took = theirs.isEmpty ? "你没吃到子" : "你吃了对方 \(list(theirs))"
            let gave = mine.isEmpty ? "自己一个子没丢" : "自己丢了 \(list(mine))"
            clauses.append("\(took)，\(gave)")
        }

        // A piece of yours standing where their pawns can never reach it. The one positional fact
        // in the language a club player already uses, and the reason the line was worth watching.
        let planted = afterPieces.compactMap { square, piece -> (Square, Piece)? in
            guard piece.colour == mover, piece.kind != .pawn, piece.kind != .king,
                beforePieces[square]?.colour != mover,
                Rules.isHole(at: square, for: opponent, pieces: afterPieces)
            else { return nil }
            return (square, piece)
        }
        // Furthest into their half first, then the dearest piece, then by square — a sentence that
        // names a square has to name the same square every time it is asked.
        let outpost = planted.min { one, other in
            func depth(_ square: Square) -> Int { mover == .white ? square.rank : 7 - square.rank }
            if depth(one.0) != depth(other.0) { return depth(one.0) > depth(other.0) }
            if one.1.kind.rawValue != other.1.kind.rawValue {
                return one.1.kind.rawValue > other.1.kind.rawValue
            }
            return one.0.index < other.0.index
        }
        if let outpost {
            clauses.append("\(outpost.0) 里坐着一个赶不走的\(outpost.1.kind.name)")
        }

        // And what your own king lost while all that was going on — counted in guards and not in
        // squares, because "two fewer guards" is what a player can act on. The ring is the one the
        // king ends on: the claim is about what is looking after it *now* against what was looking
        // after those same squares before, which is the question a player asks after a line.
        if let king = afterPieces.first(where: { $0.value.colour == mover && $0.value.kind == .king })
        {
            var dropped = 0
            for file in (king.key.file - 1)...(king.key.file + 1) where (0..<8).contains(file) {
                for rank in (king.key.rank - 1)...(king.key.rank + 1)
                where (0..<8).contains(rank) && !(file == king.key.file && rank == king.key.rank) {
                    let square = Square(file: file, rank: rank)
                    let fall =
                        beforeControl.attackers(of: square, by: mover)
                        - afterControl.attackers(of: square, by: mover)
                    if fall > 0 { dropped += fall }
                }
            }
            if dropped > 0 { clauses.append("你的王边少了 \(dropped) 个守卫") }
        }

        return LineOutcome(steps: line.count, clauses: clauses)
    }
}

/// A Line being played out on the main board, one Ply at a time.
///
/// 走马灯: the concrete form of "seeing five moves ahead", as against being told that one should.
/// Ephemeral by definition — no Variation is made, nothing reaches the PGN, and leaving it restores
/// the position exactly, because a Line is a hypothesis and nothing in it was played (docs/adr/0021).
/// It costs no engine time either: the Line is the one the Review already stored.
public struct Walk: Hashable, Sendable {
    public let line: [String]
    /// How many plies of it are on the board: 0 is the position the Line starts from.
    public var step: Int
    /// Where the whole line arrives — computed once, because it is about the line and not about
    /// where in it you have got to.
    public let outcome: LineOutcome

    public var isAtStart: Bool { step == 0 }
    public var isAtEnd: Bool { step == line.count }
    /// The plies played so far.
    public var played: [String] { Array(line.prefix(step)) }
    /// What the Line still expects, which is the second net the 要害格 layer reads at each step.
    public var remaining: [String] { Array(line.dropFirst(step)) }

    public init(line: [String], step: Int, outcome: LineOutcome) {
        self.line = line
        self.step = step
        self.outcome = outcome
    }
}

/// A line being walked out on the board, and what the engine says comes next.
///
/// Two halves, and keeping them apart is the whole of it. `steps` is what you actually played —
/// that is the plan, it is what gets an Intent and what gets judged. `ahead` is the engine's best
/// five from wherever you have got to: advice, recomputed after every move, never committed, and
/// never mistaken for something you claimed (docs/adr/0017, 0022).
///
/// The board is always at the tip of `steps`. There is no scrubbing back and forth, because there
/// is nothing to scrub: the position on the glass is the position you walked to, and the way back
/// is to take a move off.
public struct PlanDraft: Hashable, Sendable {
    /// One move, with the way it is written. Held as a pair so the move and its SAN cannot drift
    /// apart, which two arrays walked in step eventually do.
    public struct Step: Hashable, Sendable {
        public let move: Move
        public let san: String

        public init(move: Move, san: String) {
            self.move = move
            self.san = san
        }
    }

    /// The Ply the line branches from, counting like the cursor: the plan is an alternative to the
    /// move that was played here.
    public let ply: Int
    /// What you walked. This is the plan.
    public var steps: [Step] = []
    /// What the engine would play from the tip, at most five. This is not.
    public var ahead: [Step] = []

    public var moves: [Move] { steps.map(\.move) }
    public var sans: [String] { steps.map(\.san) }
    public var aheadSans: [String] { ahead.map(\.san) }

    public var isEmpty: Bool { steps.isEmpty }
    /// Whether the walk has gone past what a claim can be checked over.
    ///
    /// Not a stop: walking on is exploring and there is nothing wrong with it. It is 交卷 that the
    /// cap is about — past five Ply the opponent has had enough replies that no claim about the
    /// position is falsifiable (docs/adr/0018).
    public var isFull: Bool { steps.count >= Game.Ply.planLimit }
    public var isTooLong: Bool { steps.count > Game.Ply.planLimit }

    /// What the board shows: everything walked, always.
    public var played: [String] { sans }
    /// What the layer reads each square against — the engine's next five, which is exactly the
    /// second net docs/adr/0021 asks for and the one case where it costs nothing to have one.
    public var remaining: [String] { aheadSans }

    public init(ply: Int, steps: [Step] = [], ahead: [Step] = []) {
        self.ply = ply
        self.steps = steps
        self.ahead = ahead
    }
}

/// What one Ply of a line is for, and what it gives away.
///
/// The row under a numbered arrow. A line handed over as five moves is five moves — the thing a
/// club player cannot do with it is say why each one is there, which is the whole of what they
/// were going to have to learn. So every Ply goes through the same reader a single hypothesis
/// does: the verb it answers to, what it buys, and what it costs (docs/adr/0021, 0022).
public struct PlanNote: Hashable, Sendable {
    /// Counting from one, the way the arrow on the board and the row under it are numbered.
    public let step: Int
    /// Whether it belongs to the side to move at the head of the line.
    ///
    /// The opponent's replies are read too, and read from *their* seat: on those rows 「值」 is
    /// what is coming at you. A plan whose answers were left blank is a plan nobody checked.
    public let isYours: Bool
    public let trial: Trial

    public var san: String { trial.san }
    public var intent: Intent { trial.intent }
    public var gains: [String] { trial.gains }
    public var costs: [String] { trial.costs }
}

/// One move of a plan as the board draws it.
public struct PlanArrow: Hashable, Sendable {
    public let step: Int
    public let move: MoveSquares
    public let isYours: Bool
    /// Whether the board is already past this move.
    public let isPlayed: Bool

    public init(step: Int, move: MoveSquares, isYours: Bool, isPlayed: Bool) {
        self.step = step
        self.move = move
        self.isYours = isYours
        self.isPlayed = isPlayed
    }
}

extension Game {
    /// Every Ply of a line, read in the position it is actually played in.
    ///
    /// `player` is whose side 「你」 means, and it is a parameter rather than `state.sideToMove`
    /// because a line does not always start on your move. Walk one move of a plan and the next five
    /// begin with the opponent's reply; read from the head of that line, every row would come back
    /// with its colours swapped, and the board would draw your queen as theirs.
    ///
    /// Nil when the line will not replay from here — an honest refusal, in the same shape
    /// `outcome(of:)` and `Intent.check(plan:)` already refuse in.
    public func readPlan(of line: [String], as player: PieceColour? = nil) -> [PlanNote]? {
        guard !line.isEmpty else { return nil }
        let mover = player ?? state.sideToMove
        var walk = self
        var notes: [PlanNote] = []
        for (index, san) in line.enumerated() {
            let position = walk
            let isYours = position.state.sideToMove == mover
            guard walk.apply(san: san), let played = walk.plies.last,
                let move = position.state.move(matching: played.uci),
                let trial = position.tryOut(move)
            else { return nil }
            notes.append(PlanNote(step: index + 1, isYours: isYours, trial: trial))
        }
        return notes
    }
}
