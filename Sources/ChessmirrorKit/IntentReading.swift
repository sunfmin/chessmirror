/// What a move is **for**: one verb and one target Square, read out of the move by the rules
/// code (docs/adr/0031).
///
/// Nobody declares one any more — the player is never asked, and this is never written to a
/// file. What survives is the vocabulary, because the app still has to say what a move does:
/// the tactics card's sentence, 把关's hint layers and a drill's feedback are all written in
/// these words.
///
/// The shape is still the point. A verb with a target can be drawn on the board — an arrow and
/// a ring — and can be told false by the rules code; freeform words can be neither, which is
/// why there is no free text here and never will be. The rule that produced the list is worth
/// keeping if it is ever edited: **a verb that cannot be wrong does not get a slot.**
public enum Intent: Hashable, Sendable {
    /// A claim about a Square, which the rules code can agree or disagree with.
    case claim(Verb, Square)
    /// 说不清 — no reason at all.
    ///
    /// Recorded rather than skipped. A Game with twenty-five of these is itself the whole
    /// diagnosis, and it is a diagnosis no engine could have produced: an engine can say a move
    /// was bad, and only the player can say they had no idea why they played it.
    case unclear

    /// The seven things a move can be *for*. Each one claims something that can turn out false.
    ///
    /// 将 is not here, and its absence is the rule: the app already knows whether a move gives
    /// check, so declaring it could never be wrong and so teaches nothing. 吃 is here because its
    /// claim is not "this is a capture" — that is also unfalsifiable — but "I win material here",
    /// which the exchange value can call false.
    public enum Verb: String, Hashable, Sendable, CaseIterable {
        /// 吃 — I win material on that square.
        case take
        /// 换 — this is a trade that does not lose.
        case trade
        /// 攻 — I now threaten that piece and it cannot hold: outnumbered, or taking it
        /// would win material — a pawn looking at a queen.
        case attack
        /// 护 — that piece or square now has one more defender.
        case defend = "def"
        /// 躲 — this piece was hanging, and on that square it is not.
        case flee
        /// 挡 — I interposed on a line by stepping onto that square.
        case block
        /// 占 — I hold that square more than the opponent does.
        case hold

        /// What it is called on screen. One character each, because a row of eight has to fit on
        /// a phone beside the board rather than under it.
        public var label: String {
            switch self {
            case .take: localized("verb.take")
            case .trade: localized("verb.trade")
            case .attack: localized("verb.attack")
            case .defend: localized("verb.defend")
            case .flee: localized("verb.flee")
            case .block: localized("verb.block")
            case .hold: localized("verb.hold")
            }
        }
    }

    /// 说不清's own name on screen, so the eighth button is written from the same place as the
    /// other seven.
    public static var unclearLabel: String { localized("intent.unclear") }

    public var verb: Verb? {
        switch self {
        case .claim(let verb, _): verb
        case .unclear: nil
        }
    }

    public var target: Square? {
        switch self {
        case .claim(_, let square): square
        case .unclear: nil
        }
    }

    public var label: String {
        switch self {
        case .claim(let verb, let square): "\(verb.label) \(square)"
        case .unclear: Self.unclearLabel
        }
    }

    /// The coarse reason a move is played, for 这步的要害: 进攻 or 防御, and 交换 / 占位 when
    /// neither fits. The seven verbs stay the checkable claim; this is how they are said as a goal.
    public var goal: String {
        switch self {
        case .claim(.take, _), .claim(.attack, _): localized("intent.goal.attack")
        case .claim(.defend, _), .claim(.flee, _), .claim(.block, _): localized("intent.goal.defend")
        case .claim(.trade, _): localized("intent.goal.trade")
        case .claim(.hold, _): localized("intent.goal.hold")
        case .unclear: Self.unclearLabel
        }
    }
}

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
        return localized("intent.sequence", opening.label, Self.ahead(later), later.label)
    }

    /// The later half as its own line, for 要害. Same facts as `sentence`; the goal is named again
    /// only when it is a different one, because "第 4 步再防御" without a move reads as a missing
    /// list.
    public var laterLine: String? {
        guard let later else { return nil }
        let when = Self.ahead(later)
        if later.intent.goal == opening.intent.goal {
            return localized("intent.later", when, later.label)
        }
        return localized("intent.laterGoal", when, later.intent.goal, later.label)
    }

    private static func ahead(_ later: MoveReading) -> String {
        localized("intent.ahead", later.step, later.san)
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

extension Rules {
    /// How far one piece is from a square, ignoring everything the other side does.
    ///
    /// The approximation is deliberate and has to be said out loud: this walks one piece over the
    /// board as it stands, treating its own side's pieces as walls and the other side's as squares
    /// it may land on. Nobody replies. What it answers is "how far away is that knight", which is
    /// the question a player actually asks about an outpost — not "can this be forced", which is a
    /// search and would cost a Stint (docs/adr/0020).
    ///
    /// Nil when the piece cannot get there within `horizon` moves. Three by default: a piece four
    /// moves away from a square is not a fact about this position.
    public static func route(
        to target: Square, from origin: Square, pieces: [Square: Piece], horizon: Int = 3
    ) -> [Square]? {
        guard let piece = pieces[origin], origin != target else { return nil }
        var seen: Set<Square> = [origin]
        var edge: [(square: Square, path: [Square])] = [(origin, [])]
        for _ in 0..<horizon {
            var next: [(square: Square, path: [Square])] = []
            for (square, path) in edge {
                for step in steps(of: piece, from: square, pieces: pieces) {
                    if step == target { return path + [step] }
                    guard !seen.contains(step) else { continue }
                    // A square with somebody on it can be landed on and not walked through: what
                    // happens after a capture is a different position, and this one is not it.
                    seen.insert(step)
                    if pieces[step] == nil { next.append((step, path + [step])) }
                }
            }
            edge = next
            if edge.isEmpty { break }
        }
        return nil
    }

    /// Where one piece may move in one move, by geometry alone: no checks, no pins, no turn order.
    private static func steps(
        of piece: Piece, from square: Square, pieces: [Square: Piece]
    ) -> [Square] {
        func free(_ file: Int, _ rank: Int) -> Square? {
            guard (0..<8).contains(file), (0..<8).contains(rank) else { return nil }
            let there = Square(file: file, rank: rank)
            return pieces[there]?.colour == piece.colour ? nil : there
        }
        func slide(_ directions: [(Int, Int)]) -> [Square] {
            var found: [Square] = []
            for (df, dr) in directions {
                var file = square.file + df
                var rank = square.rank + dr
                while let there = free(file, rank) {
                    found.append(there)
                    if pieces[there] != nil { break }
                    file += df
                    rank += dr
                }
            }
            return found
        }
        let straight = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        let slanted = [(1, 1), (1, -1), (-1, 1), (-1, -1)]
        switch piece.kind {
        case .knight:
            return [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
                .compactMap { free(square.file + $0.0, square.rank + $0.1) }
        case .bishop: return slide(slanted)
        case .rook: return slide(straight)
        case .queen: return slide(straight + slanted)
        case .king: return (straight + slanted).compactMap { free(square.file + $0.0, square.rank + $0.1) }
        case .pawn:
            // Forwards onto an empty square, sideways onto an occupied one. A pawn's two ways of
            // moving are the reason it cannot be treated as a slider with a short leash.
            let ahead = piece.colour == .white ? 1 : -1
            var found: [Square] = []
            if (0..<8).contains(square.rank + ahead) {
                let one = Square(file: square.file, rank: square.rank + ahead)
                if pieces[one] == nil {
                    found.append(one)
                    let home = piece.colour == .white ? 1 : 6
                    if square.rank == home {
                        let two = Square(file: square.file, rank: square.rank + ahead * 2)
                        if pieces[two] == nil { found.append(two) }
                    }
                }
                for file in [square.file - 1, square.file + 1] where (0..<8).contains(file) {
                    let take = Square(file: file, rank: square.rank + ahead)
                    if let other = pieces[take], other.colour != piece.colour { found.append(take) }
                }
            }
            return found
        }
    }
}

/// Whether an Intent is actually true of the position a move made, and what the board says when
/// it is not.
///
/// Nobody declares an Intent any more (docs/adr/0031), so this is no longer a verdict on anybody.
/// It is the predicate the *reading* is built out of: `Intent.read` proposes candidate claims in
/// the order they would be worth saying and keeps the first one this agrees with, which is what
/// makes 「占 d5」 a fact about the board rather than a label somebody chose. The note is the other
/// half of why it survived the drills: 「f7 的守子没有增加」 is a sentence a player can go and look
/// at, and it is the sentence 把关 and a practice answer both need.
public struct IntentCheck: Hashable, Sendable {
    public enum Verdict: Hashable, Sendable {
        /// The claim is true of the position the move made.
        case held
        /// The claim is not true. `note` says what the board says instead.
        case failed
    }

    public let verdict: Verdict
    /// One short sentence about the board, in the same terms the claim was made in. The teaching
    /// is here: "f7 的守子没有增加" is a fact a player can go and look at, where "错" is not.
    public let note: String?

    public var held: Bool { verdict == .held }
}

extension Intent {
    /// Checks this Intent against the position `move` makes.
    ///
    /// Nil when there is nothing to check or it could not be checked at all — 说不清, an unreadable
    /// position, an illegal move. Not `.failed`: an app that cannot tell has no business saying
    /// anything was wrong.
    public func check(_ move: Move, in before: Game) -> IntentCheck? {
        // 说不清 claims nothing, so there is nothing here to be true or false — and nil rather
        // than a third verdict, because a caller that has to handle "no answer" already has to
        // handle the unreadable position below.
        guard case .claim(let verb, let target) = self else { return nil }

        let mover = before.state.sideToMove
        let opponent = mover.opposite
        var after = before
        guard after.apply(move),
            let beforeControl = Rules.control(startFEN: before.startFEN, moves: before.uciMoves),
            let afterControl = Rules.control(startFEN: after.startFEN, moves: after.uciMoves),
            let beforePieces = BoardRenderer.placement(before.state.fen),
            let afterPieces = BoardRenderer.placement(after.state.fen)
        else { return nil }

        func held(_ note: String) -> IntentCheck { IntentCheck(verdict: .held, note: note) }
        func failed(_ note: String) -> IntentCheck { IntentCheck(verdict: .failed, note: note) }

        /// Where the piece was actually taken from — not the destination, for en passant.
        let captured =
            move.isEnPassant ? Square(file: move.to.file, rank: move.from.rank) : move.to
        let exchange = Rules.exchangeValue(
            startFEN: before.startFEN, moves: before.uciMoves, uci: move.uci
        )

        switch verb {
        // 吃 — "I win material here". Not "this is a capture", which no player could get wrong
        // and which would therefore teach nothing.
        case .take:
            guard move.isCapture, captured == target else {
                return failed(localized("check.take.notHere", "\(target)"))
            }
            guard let exchange else { return nil }
            return exchange == .winning
                ? held(localized("check.take.won", "\(target)"))
                : failed(localized("check.take.notWorth", "\(target)"))

        // 换 — "a trade that does not lose". The pair 吃/换 is the one players confuse most, and
        // the exchange value is exactly what tells them apart.
        case .trade:
            guard move.isCapture, captured == target else {
                return failed(localized("check.trade.notHere", "\(target)"))
            }
            guard let exchange else { return nil }
            return exchange == .losing
                ? failed(localized("check.trade.losing", "\(target)"))
                : held(localized("check.trade.affordable", "\(target)"))

        // 攻 — "I now threaten that piece, and it cannot hold". Two halves, both falsifiable:
        // the threat has to be new, and the piece cannot hold — outnumbered, or taking it
        // would win material. A pawn looking at a queen is one of each and still a threat.
        case .attack:
            guard let piece = afterPieces[target], piece.colour == opponent else {
                return failed(localized("check.attack.noPiece", "\(target)"))
            }
            let now = afterControl.attackers(of: target, by: mover)
            let was = beforeControl.attackers(of: target, by: mover)
            guard now > was else {
                return failed(localized("check.attack.noNewThreat", "\(target)"))
            }
            guard after.cannotHold(target, against: mover, control: afterControl) else {
                return failed(
                    localized(
                        "check.attack.defended", "\(target)", now,
                        afterControl.attackers(of: target, by: opponent)
                    )
                )
            }
            return held(localized("check.attack.held", "\(target)"))

        // 护 — "it now has one more defender". Purely a statement about the control map, which is
        // why it is the easiest of the eight to check and the easiest to be wrong about.
        case .defend:
            let now = afterControl.attackers(of: target, by: mover)
            let was = beforeControl.attackers(of: target, by: mover)
            return now > was
                ? held(localized("check.defend.held", "\(target)", was, now))
                : failed(localized("check.defend.unchanged", "\(target)", was))

        // 躲 — "this piece was hanging, and where it went it is not". The target is the attacker
        // it ran from, so the claim names both ends of it.
        case .flee:
            guard let attacker = beforePieces[target], attacker.colour == opponent else {
                return failed(localized("check.flee.noAttacker", "\(target)"))
            }
            let attacked = beforeControl.attackers(of: move.from, by: opponent)
            let defended = beforeControl.attackers(of: move.from, by: mover)
            guard attacked > defended else {
                return failed(
                    localized("check.flee.notHanging", "\(move.from)", attacked, defended)
                )
            }
            guard let exchange else { return nil }
            return exchange == .losing
                ? failed(localized("check.flee.stillTaken", "\(move.to)"))
                : held(localized("check.flee.held", "\(move.from)", "\(target)"))

        // 挡 — "I interposed on a line". Geometry and nothing else: something of the mover's,
        // in line with the square stepped onto, is attacked less than it was.
        case .block:
            guard move.to == target else {
                return failed(localized("check.block.notThere", "\(target)"))
            }
            let relieved = (0..<64).compactMap(Square.init(index:)).first { square in
                square != target
                    && afterPieces[square]?.colour == mover
                    && Self.inLine(target, square)
                    && afterControl.attackers(of: square, by: opponent)
                        < beforeControl.attackers(of: square, by: opponent)
            }
            guard let relieved else {
                return failed(localized("check.block.nothing", "\(target)"))
            }
            return held(localized("check.block.held", "\(target)", "\(relieved)"))

        // 占 — "I hold this square more than the opponent does". Before against after, so holding
        // a square you already held is not a claim.
        case .hold:
            guard afterControl.holder(of: target) == mover else {
                let mine = afterControl.attackers(of: target, by: mover)
                let theirs = afterControl.attackers(of: target, by: opponent)
                return failed(localized("check.hold.notYours", "\(target)", mine, theirs))
            }
            let now =
                afterControl.attackers(of: target, by: mover)
                - afterControl.attackers(of: target, by: opponent)
            let was =
                beforeControl.attackers(of: target, by: mover)
                - beforeControl.attackers(of: target, by: opponent)
            return now > was
                ? held(localized("check.hold.held", "\(target)", was, now))
                : failed(localized("check.hold.unchanged", "\(target)"))
        }
    }

    /// Whether two squares share a rank, a file or a diagonal — the three ways a piece can stand
    /// between two others.
    private static func inLine(_ one: Square, _ other: Square) -> Bool {
        one.file == other.file || one.rank == other.rank
            || abs(one.file - other.file) == abs(one.rank - other.rank)
    }
}
