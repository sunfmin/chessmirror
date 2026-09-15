/// What one move of a Line is for, read out of the move rather than declared by anybody.
public struct MoveReading: Hashable, Sendable {
    /// Where in the Line this move is, counting from one.
    public let step: Int
    public let san: String
    public let intent: Intent

    public var label: String { "\(intent.label)" }

    public init(step: Int, san: String, intent: Intent) {
        self.step = step
        self.san = san
        self.intent = intent
    }
}

/// What a Line is *for*, in the seven words a player uses for their own moves.
///
/// An engine gives a number and a sequence of moves and never a reason, so the reason is derived
/// here — from the moves, with the same rules code that tells a declared Intent true or false
/// (docs/adr/0018, 0021). Two things fall out of that, and they are the whole point of this type:
///
/// 1. 「为什么好」 has an answer that can be checked rather than asserted. Every verb printed here
///    is one the app could also be told it got wrong.
/// 2. The player's reason and the engine's are now written in the same eight words, so
///    「我说的是护 f7，引擎说的是占 d5」 is a comparison and not a translation exercise.
public struct LineReading: Hashable, Sendable {
    /// The move being recommended, and what it is for.
    public let opening: MoveReading
    /// One later move of the mover's own, where the same machinery gives a clean answer and it says
    /// something the opening did not. Nil rather than invented: a plan the code cannot read is a
    /// plan it does not get to describe.
    public let later: MoveReading?

    public init(opening: MoveReading, later: MoveReading?) {
        self.opening = opening
        self.later = later
    }

    /// 「占 d5，往后第 3 步 Ng5 再 攻 g7」 — or just 「占 d5」 when the rest of the line reads as nothing.
    ///
    /// `往后` is the whole of why this is not "第 3 步" on its own. The number is a ply of the
    /// engine's Line, the same numbering 五步 walks; it is not item 3 of a list on this card, and
    /// the opening is not 第 1 步 of one. The SAN names the move so the number has something to
    /// point at.
    public var sentence: String {
        guard let later else { return opening.label }
        return "\(opening.label)，\(Self.ahead(later)) 再 \(later.label)"
    }

    /// The later half as its own line, for 要害. Same facts as `sentence`; the goal is named again
    /// only when it is a different one, because "第 4 步再防御" without a move reads as a missing
    /// list.
    public var laterLine: String? {
        guard let later else { return nil }
        let when = Self.ahead(later)
        if later.intent.goal == opening.intent.goal {
            return "\(when) 再 \(later.label)"
        }
        return "\(when) 再\(later.intent.goal)：\(later.label)"
    }

    private static func ahead(_ later: MoveReading) -> String {
        "往后第 \(later.step) 步 \(later.san)"
    }
}

extension Intent {
    /// Reads a move as one of the seven verbs, or as 说不清.
    ///
    /// Every candidate it proposes is confirmed by `check` before it is returned, so the reading and
    /// the checker cannot drift apart: a verb this returns is a verb the app would agree with if
    /// somebody declared it. That is also why the answer is never invented — a move whose reason
    /// none of the seven can carry comes back 说不清, exactly as a player's does, and the rule from
    /// docs/adr/0018 holds here too: a verb that cannot be wrong does not get printed.
    ///
    /// The order the verbs are tried in is the order of what a move is most usefully *for*:
    /// material, then a threat, then getting out of the way, then the positional two. A move can
    /// honestly be several of these and only one of them is worth saying.
    public static func read(_ move: Move, in before: Game) -> Intent {
        guard let beforePieces = BoardRenderer.placement(before.state.fen),
            let beforeControl = Rules.control(startFEN: before.startFEN, moves: before.uciMoves)
        else { return .unclear }
        var after = before
        guard after.apply(move),
            let afterPieces = BoardRenderer.placement(after.state.fen),
            let afterControl = Rules.control(startFEN: after.startFEN, moves: after.uciMoves)
        else { return .unclear }

        let mover = before.state.sideToMove
        let opponent = mover.opposite
        let captured =
            move.isEnPassant ? Square(file: move.to.file, rank: move.from.rank) : move.to

        /// The most valuable piece of a set of squares, then the lowest square — a tie broken by
        /// something arbitrary is a sentence that changes when the position has not.
        func dearest(_ squares: [Square], in pieces: [Square: Piece]) -> Square? {
            squares.min { one, other in
                let mine = pieces[one]?.kind.rawValue ?? 0
                let theirs = pieces[other]?.kind.rawValue ?? 0
                if mine != theirs { return mine > theirs }
                return one.index < other.index
            }
        }

        var candidates: [(Verb, Square)] = [(.take, captured), (.trade, captured)]

        // 攻 — an enemy piece this move newly threatens and that cannot hold: outnumbered,
        // or taking it would win material (a pawn looking at a queen).
        let threatened = afterPieces.compactMap { square, piece -> Square? in
            guard piece.colour == opponent,
                afterControl.attackers(of: square, by: mover)
                    > beforeControl.attackers(of: square, by: mover),
                after.cannotHold(square, against: mover, control: afterControl)
            else { return nil }
            return square
        }
        if let target = dearest(threatened, in: afterPieces) { candidates.append((.attack, target)) }

        // 躲 — the piece that was threatening the square this move left. The cheapest of them,
        // because a pawn chasing a queen is the sharpest form of the claim.
        let chasers = beforePieces.compactMap { square, piece -> Square? in
            guard piece.colour == opponent, piece.kind != .king,
                Rules.route(to: move.from, from: square, pieces: beforePieces, horizon: 1) != nil
            else { return nil }
            return square
        }
        if let chaser = chasers.min(by: {
            (beforePieces[$0]?.kind.rawValue ?? 0, UInt32($0.index))
                < (beforePieces[$1]?.kind.rawValue ?? 0, UInt32($1.index))
        }) {
            candidates.append((.flee, chaser))
        }

        candidates.append((.block, move.to))

        // 护 — one of the mover's own pieces that was under threat and now has one more defender.
        // Never the king: a king cannot be taken, so an extra piece looking at its square defends
        // nothing, and it would otherwise win every tie by being the dearest thing on the board.
        //
        // Somebody has to be looking at it. Any developing move adds a defender to *something*, so
        // a 护 that only asks whether the count went up is true of nearly every move and therefore
        // says nothing about any of them — 1.e4 e5 2.Bc4 read as 「护 a2」, which is a fact and not
        // a reason. Defending what nobody is attacking is not a plan (docs/adr/0018, 0022).
        let helped = afterPieces.compactMap { square, piece -> Square? in
            guard piece.colour == mover, piece.kind != .king, square != move.to,
                afterControl.attackers(of: square, by: mover)
                    > beforeControl.attackers(of: square, by: mover)
            else { return nil }
            return square
        }
        let rescued = helped.filter {
            beforeControl.attackers(of: $0, by: opponent)
                > beforeControl.attackers(of: $0, by: mover)
        }
        // A piece the opponent is at least looking at, when none of them was actually hanging.
        // This is the whole of the tightening: 1.e4 e5 2.Bc4 gained a2 a second defender and
        // nothing on the board has ever looked at a2, where O-O gained f2 one and a bishop on c5
        // is pointed straight at it. The first is arithmetic; the second is why people castle.
        let contested = helped.filter { afterControl.attackers(of: $0, by: opponent) > 0 }
        let worth = rescued.isEmpty ? contested : rescued
        if let target = dearest(worth, in: afterPieces) {
            candidates.append((.defend, target))
        }

        // 占 — a square this move took control of, which is almost never the square it moved to: a
        // piece does not attack the square it stands on, so walking onto d5 *lowers* the count on
        // d5. 占 is control and not occupation (docs/adr/0018), and a move that walks onto a square
        // is named by the layer instead, as a 据点 (docs/adr/0021).
        //
        // Only empty squares on the opponent's side of the board are offered. Almost every move
        // newly controls *something*, so without that the verb would be true of everything and
        // worth saying about nothing — a king stepping sideways would read 「占 c2」. Ground gained
        // in front of your own king is not a plan; ground gained in theirs is.
        func margin(_ control: SquareControl, _ square: Square) -> Int {
            control.attackers(of: square, by: mover) - control.attackers(of: square, by: opponent)
        }
        func isTheirSide(_ square: Square) -> Bool {
            mover == .white ? square.rank >= 4 : square.rank <= 3
        }
        let taken = (0..<64).compactMap(Square.init(index:)).filter { square in
            afterPieces[square] == nil && isTheirSide(square)
                && afterControl.holder(of: square) == mover
                && margin(afterControl, square) > margin(beforeControl, square)
        }
        // The biggest change first, then the most central square, then its own number. Centrality
        // only ever chooses between claims that are each already true — it is a preference, never
        // the thing being claimed.
        let held = taken.min { one, other in
            let mine = margin(afterControl, one) - margin(beforeControl, one)
            let theirs = margin(afterControl, other) - margin(beforeControl, other)
            if mine != theirs { return mine > theirs }
            func fromMiddle(_ square: Square) -> Int {
                max(abs(square.file * 2 - 7), abs(square.rank * 2 - 7))
            }
            if fromMiddle(one) != fromMiddle(other) { return fromMiddle(one) < fromMiddle(other) }
            return one.index < other.index
        }
        if let held { candidates.append((.hold, held)) }
        candidates.append((.hold, move.to))

        for (verb, target) in candidates {
            let claim = Intent.claim(verb, target)
            if claim.check(move, in: before)?.held == true { return claim }
        }
        return .unclear
    }
}

extension Game {
    /// What the engine's Line is for, read from this position.
    ///
    /// `line` is SAN from this position onwards — a Review's or a Reveal's. Nil when the first move
    /// will not replay, which is the only refusal: a first move that reads as nothing still comes
    /// back, wearing 说不清, because "the engine played this and the app cannot say why" is a true
    /// and useful thing for a screen to admit.
    ///
    /// The later half is one of the mover's *own* moves, further down the line, saying something the
    /// opening did not. The opponent's moves are not what the recommendation is for.
    public func reading(of line: [String]) -> LineReading? {
        guard !line.isEmpty else { return nil }
        let mover = state.sideToMove
        var walk = self
        var readings: [MoveReading] = []
        for (index, san) in line.enumerated() {
            let position = walk
            let isOurs = position.state.sideToMove == mover
            guard walk.apply(san: san), let played = walk.plies.last,
                let move = position.state.move(matching: played.uci)
            else { break }
            guard isOurs else { continue }
            readings.append(
                MoveReading(step: index + 1, san: san, intent: Intent.read(move, in: position))
            )
        }
        guard let opening = readings.first else { return nil }
        let later = readings.dropFirst().first {
            $0.intent != .unclear && $0.intent.verb != opening.intent.verb
        }
        return LineReading(opening: opening, later: later)
    }

    /// What this position's move is for: the last Ply if there is one, otherwise the engine's
    /// next move from `continuation`.
    ///
    /// The latest position has a last Ply the same as any other — the move that just landed —
    /// so 这步的要害 does not wait for a rewind. An empty Game still answers, from the Line:
    /// that is 「为什么要下这一步」 when nothing has been played yet.
    public func purpose(continuation: [String] = []) -> LineReading? {
        if let last = plies.last, let before = rewound(to: plies.count - 1),
            let move = before.state.move(matching: last.uci)
        {
            let opening = MoveReading(
                step: 1, san: last.san, intent: Intent.read(move, in: before)
            )
            return LineReading(
                opening: opening, later: laterOwnMove(in: continuation, after: opening.intent)
            )
        }
        return reading(of: continuation)
    }

    /// The original mover's next move in the engine's Line that says something the opening did
    /// not. Opponent replies are skipped: they are not why *this* move was played.
    private func laterOwnMove(in continuation: [String], after opening: Intent) -> MoveReading? {
        let mover = state.sideToMove.opposite
        var walk = self
        for (index, san) in continuation.enumerated() {
            let position = walk
            guard walk.apply(san: san), let played = walk.plies.last,
                let move = position.state.move(matching: played.uci)
            else { break }
            guard position.state.sideToMove == mover else { continue }
            let intent = Intent.read(move, in: position)
            if intent != .unclear, intent.verb != opening.verb {
                return MoveReading(step: index + 1, san: san, intent: intent)
            }
        }
        return nil
    }
}
