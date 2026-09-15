/// Every piece of the side to move that can legally reach one square.
///
/// The scanner is the half of the layer that answers a question instead of volunteering one, and
/// that is the whole of why it exists: before a Guess is committed nothing draws itself, because a
/// king-ring painted unprompted is the blunder check performed on the player's behalf, which is the
/// one thing they are here to learn to do (docs/adr/0015, 0021). Point at a square and the app
/// answers about that square. Point at nothing and it says nothing.
public struct Scan: Hashable, Sendable {
    /// One way of getting there: which piece, from where, and the move that does it.
    public struct Arrival: Hashable, Sendable {
        public let from: Square
        public let piece: Piece
        public let move: Move
        public let san: String
    }

    public let target: Square
    /// Whose pieces these are — the side to move, and nobody else's.
    public let mover: PieceColour
    /// Cheapest piece first, then by square. A pawn before a queen, because the cheapest way in is
    /// the one worth thinking about first, and the order must not depend on a dictionary.
    public let arrivals: [Arrival]

    public var origins: Set<Square> { Set(arrivals.map(\.from)) }
    public var isEmpty: Bool { arrivals.isEmpty }
}

/// One move played as a hypothesis: what it buys, and what it costs.
///
/// Every sentence is a fixed template over a fact the rules code computed — which piece, which
/// square, how many attackers — in the style an Intent is already judged in (docs/adr/0018).
/// Nothing here is prose about the position, and nothing is printed that the app could not also be
/// told is false.
public struct Trial: Hashable, Sendable {
    public let move: Move
    public let san: String
    /// What the move is *for*, read with the same reader the engine's own Line goes through, so
    /// the two answers are written in the same seven verbs (docs/adr/0021).
    public let intent: Intent
    public let gains: [String]
    public let costs: [String]
}

extension Game {
    /// Every legal move of the side to move that lands on `square`.
    ///
    /// Legal and not merely geometric: a piece pinned to its own king cannot reach anything, and a
    /// scanner that lit it up would be teaching the wrong lesson twice over.
    public func scan(at square: Square) -> Scan {
        let mover = state.sideToMove
        let pieces = BoardRenderer.placement(state.fen) ?? [:]
        let arrivals =
            state.legalMoves
            .filter { $0.to == square }
            .compactMap { move -> Scan.Arrival? in
                guard let piece = pieces[move.from] else { return nil }
                return Scan.Arrival(
                    from: move.from,
                    piece: piece,
                    move: move,
                    san: SAN.text(for: move, in: state)
                )
            }
            .sorted {
                ($0.piece.kind.rawValue, $0.from.index) < ($1.piece.kind.rawValue, $1.from.index)
            }
        return Scan(target: square, mover: mover, arrivals: arrivals)
    }

    /// What one move would buy and cost, without playing it.
    ///
    /// Nil when the move will not replay or the position cannot be read. The order the sentences
    /// come back in is the order the ticket asks for and the order docs/adr/0015 requires: what the
    /// move is worth first, in the player's own terms, and the engine's opinion only when somebody
    /// asks for it afterwards.
    public func tryOut(_ move: Move) -> Trial? {
        guard let beforePieces = BoardRenderer.placement(state.fen),
            let beforeControl = Rules.control(startFEN: startFEN, moves: uciMoves)
        else { return nil }
        let san = SAN.text(for: move, in: state)
        var after = self
        guard after.apply(move),
            let afterPieces = BoardRenderer.placement(after.state.fen),
            let afterControl = Rules.control(startFEN: after.startFEN, moves: after.uciMoves)
        else { return nil }

        let mover = state.sideToMove
        let opponent = mover.opposite
        let intent = Intent.read(move, in: self)

        func margin(_ control: SquareControl, _ square: Square, for colour: PieceColour) -> Int {
            control.attackers(of: square, by: colour)
                - control.attackers(of: square, by: colour.opposite)
        }
        /// The cheapest of a set of squares, then the lowest — a sentence that names a piece has to
        /// name the same piece every time it is asked.
        func cheapest(_ squares: [Square], in pieces: [Square: Piece]) -> Square? {
            squares.min {
                (pieces[$0]?.kind.rawValue ?? 0, UInt32($0.index))
                    < (pieces[$1]?.kind.rawValue ?? 0, UInt32($1.index))
            }
        }

        // ------------------------------------------------------------------ what it buys

        var gains: [String] = []
        if case .claim = intent, let note = intent.check(move, in: self)?.note {
            gains.append("\(intent.label)：\(note)")
        } else {
            gains.append("这步是干什么的，说不清。")
        }
        let arrival = afterPieces[move.to]
        // An outpost, in the ordinary sense: a square the other side's pawns can never attack
        // again is a square whoever gets there keeps. Said only of the pieces it is a fact about —
        // a pawn or a king standing somewhere unassailable is not an outpost, it is a pawn.
        if let arrival, arrival.kind != .pawn, arrival.kind != .king,
            Rules.isHole(at: move.to, for: opponent, pieces: afterPieces)
        {
            gains.append("\(arrival.kind.name)到 \(move.to) 就赶不走了：对方的兵再也攻不到这格。")
        }

        // ------------------------------------------------------------------ and what it costs

        var costs: [String] = []
        let attackers = afterControl.attackers(of: move.to, by: opponent)
        let defenders = afterControl.attackers(of: move.to, by: mover)
        if attackers > defenders {
            let looking = afterPieces.compactMap { square, piece -> Square? in
                guard piece.colour == opponent,
                    Rules.route(to: move.to, from: square, pieces: afterPieces, horizon: 1) != nil
                else { return nil }
                return square
            }
            if let taker = cheapest(looking, in: afterPieces), let piece = afterPieces[taker] {
                costs.append(
                    "站不住：\(piece.kind.name)从 \(taker) 就能吃它，"
                        + "对方 \(attackers) 个子看着 \(move.to)，自己 \(defenders) 个接应。"
                )
            } else {
                costs.append("站不住：对方 \(attackers) 个子看着 \(move.to)，自己 \(defenders) 个接应。")
            }
        } else if let arrival, arrival.kind != .pawn, arrival.kind != .king,
            // Only where the claim means something: `isHole` refuses the back ranks on purpose,
            // and "a pawn will come and kick your rook off d1" is not a fact about chess.
            (2...5).contains(move.to.rank),
            !Rules.isHole(at: move.to, for: opponent, pieces: afterPieces)
        {
            costs.append("吃不掉，但赶得走：对方的兵推上来就能攻 \(move.to)。")
        }

        // What it lets go of near your own king. The one place a square losing a defender is worth
        // a sentence whether or not anything is standing on it.
        if let king = afterPieces.first(where: { $0.value.colour == mover && $0.value.kind == .king })
        {
            let loosened = neighbours(of: king.key).filter { square in
                margin(afterControl, square, for: mover) < margin(beforeControl, square, for: mover)
            }
            if !loosened.isEmpty {
                let named = loosened.sorted { $0.index < $1.index }.prefix(2)
                costs.append(
                    "自己王边上的 \(named.map(\.description).joined(separator: "、")) 少了看守。"
                )
            }
        }

        // And what the piece stops guarding by leaving. A square that changed hands is a diff; a
        // piece of your own that nothing is looking after any more is a move you can lose to.
        let abandoned = afterPieces.compactMap { square, piece -> Square? in
            guard piece.colour == mover, piece.kind != .king, square != move.to,
                afterControl.attackers(of: square, by: mover)
                    < beforeControl.attackers(of: square, by: mover),
                afterControl.attackers(of: square, by: opponent)
                    > afterControl.attackers(of: square, by: mover)
            else { return nil }
            return square
        }
        if let left = dearest(abandoned, in: afterPieces) {
            costs.append("走了以后 \(afterPieces[left]?.kind.name ?? "") \(left) 没人管了。")
        }

        return Trial(move: move, san: san, intent: intent, gains: gains, costs: costs)
    }

    /// The dearest of a set of squares, then the lowest.
    private func dearest(_ squares: [Square], in pieces: [Square: Piece]) -> Square? {
        squares.min { one, other in
            let mine = pieces[one]?.kind.rawValue ?? 0
            let theirs = pieces[other]?.kind.rawValue ?? 0
            if mine != theirs { return mine > theirs }
            return one.index < other.index
        }
    }

    private func neighbours(of square: Square) -> [Square] {
        var found: [Square] = []
        for file in (square.file - 1)...(square.file + 1) where (0..<8).contains(file) {
            for rank in (square.rank - 1)...(square.rank + 1)
            where (0..<8).contains(rank) && !(file == square.file && rank == square.rank) {
                found.append(Square(file: file, rank: rank))
            }
        }
        return found
    }
}

/// What the engine says about the position that was scanned — asked for, never volunteered.
///
/// It comes last and only on a tap. The order is the whole design: you point at a square, you hear
/// what your own move is worth in your own terms, and you find out what the engine thought
/// afterwards. Reversed, it is a hint button (docs/adr/0015).
public struct ScanAnswer: Hashable, Sendable {
    public let depth: Int
    public let best: String
    public let score: Score?
    /// The engine's move read through the seven verbs, so its reason and the player's are written
    /// in the same words (docs/adr/0021). Nil when the Line could not be read.
    public let reading: LineReading?
    /// Whether the engine's move is the one that was tried.
    public let isSameAsTrial: Bool
}
