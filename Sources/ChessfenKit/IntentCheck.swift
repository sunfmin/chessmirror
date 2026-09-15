/// Whether a declared Intent actually held, and why not when it did not.
///
/// The second of a Drill's two verdicts, and kept apart from the first on purpose: "right move,
/// wrong reason" and "wrong move, right reason" are different failures with different remedies,
/// and multiplying them into one number is how an app ends up saying nothing (docs/adr/0018).
public struct IntentCheck: Hashable, Sendable {
    public enum Verdict: Hashable, Sendable {
        /// The claim is true of the position the move made.
        case held
        /// The claim is not true. `note` says what the board says instead.
        case failed
        /// 说不清 — no claim was made, so there is nothing to be right or wrong about.
        case noClaim
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
    /// Nil when it could not be checked at all — an unreadable position, an illegal move. Not
    /// `.failed`: an app that cannot tell has no business saying somebody was wrong.
    public func check(_ move: Move, in before: Game) -> IntentCheck? {
        guard case .claim(let verb, let target) = self else {
            return IntentCheck(verdict: .noClaim, note: nil)
        }

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

/// Whether a plan's one Intent held over the line it was declared about, and where.
///
/// The same verdicts a single-Ply Intent gets, plus the step: 「第 3 步 Nd5 的时候成立」 is a fact a
/// player can go and look at, where 「计划成立」 is a grade. And it is the *same checker* that
/// produced it — the claim is put to each of the mover's own moves in turn, in the position that
/// move was played in, and the first one it holds on is the answer (docs/adr/0017, 0018).
public struct PlanCheck: Hashable, Sendable {
    public let verdict: IntentCheck.Verdict
    /// Which move of the plan made the claim true, counting from one. Nil when none did.
    public let step: Int?
    /// That move, in SAN.
    public let san: String?
    /// What the board says, in the same terms the claim was made in.
    public let note: String?

    public var held: Bool { verdict == .held }
}

extension Intent {
    /// Checks this Intent over a whole line, one move at a time.
    ///
    /// `line` is SAN from `before` onwards — the plan as it was played out. Only the mover's own
    /// moves are put to the test: the opponent's replies are what the plan has to survive, not what
    /// it claims. The claim holds if it held on one of them, and the step is reported so the player
    /// can go and look at the move that did it.
    ///
    /// Nil when the line will not replay. Not `.failed`: an app that cannot tell has no business
    /// saying somebody was wrong.
    public func check(plan line: [String], in before: Game) -> PlanCheck? {
        guard case .claim = self else {
            return PlanCheck(verdict: .noClaim, step: nil, san: nil, note: nil)
        }
        guard !line.isEmpty else { return nil }

        let mover = before.state.sideToMove
        var walk = before
        var last: (step: Int, san: String, check: IntentCheck)?
        for (index, san) in line.enumerated() {
            let position = walk
            let isOurs = position.state.sideToMove == mover
            guard walk.apply(san: san), let played = walk.plies.last,
                let move = position.state.move(matching: played.uci)
            else { return nil }
            guard isOurs, let check = check(move, in: position) else { continue }
            if check.held {
                return PlanCheck(
                    verdict: .held, step: index + 1, san: san, note: check.note
                )
            }
            last = (index + 1, san, check)
        }
        // Nothing in the plan made it true. The note is the last of the mover's own moves, because
        // that is the state of affairs the plan actually left behind.
        guard let last else { return nil }
        return PlanCheck(
            verdict: .failed, step: last.step, san: last.san, note: last.check.note
        )
    }
}
