import ChessfenKit
import Testing

/// One case per verb where the claim holds, and one where it does not (docs/adr/0018).
///
/// Sparse positions on purpose: the whole value of a verb is that the rules code can call it
/// false, and a five-piece position is one a reader can check by eye against the assertion.
@Suite(.speaking(.chinese)) struct IntentCheckTests {
    private func check(
        _ fen: String, _ uci: String, _ intent: Intent
    ) throws -> IntentCheck {
        let game = try #require(Game(startFEN: fen), "\(fen) did not validate")
        let move = try #require(game.state.move(matching: uci), "\(uci) is not legal in \(fen)")
        return try #require(intent.check(move, in: game), "\(intent.pgnText) could not be checked")
    }

    private func square(_ name: String) throws -> Square {
        try #require(Square(name))
    }

    // 吃 — I win material here.
    @Test("吃 holds when the capture wins material, and fails when it is paid back")
    func take() throws {
        // A rook on e5 with nothing looking at it.
        let won = try check(
            "4k3/8/8/4r3/8/8/8/4QK2 w - - 0 1", "e1e5", .claim(.take, try square("e5"))
        )
        #expect(won.verdict == .held)

        // The same rook, with a pawn on d6 behind it: queen for rook is not winning material.
        let paid = try check(
            "4k3/8/3p4/4r3/8/8/8/4QK2 w - - 0 1", "e1e5", .claim(.take, try square("e5"))
        )
        #expect(paid.verdict == .failed)
        #expect(paid.note?.contains("不赚") == true)
    }

    @Test("吃 fails when the move did not take anything on the square named")
    func takeOnTheWrongSquare() throws {
        let elsewhere = try check(
            "4k3/8/8/4r3/8/8/8/4QK2 w - - 0 1", "e1e5", .claim(.take, try square("e4"))
        )
        #expect(elsewhere.verdict == .failed)
        #expect(elsewhere.note?.contains("e4") == true)
    }

    // 换 — a trade that does not lose.
    @Test("换 holds for an even trade and fails when the trade loses")
    func trade() throws {
        // Knight takes knight, pawn takes knight: level.
        let even = try check(
            "4k3/8/2p5/3n4/8/2N5/8/4K3 w - - 0 1", "c3d5", .claim(.trade, try square("d5"))
        )
        #expect(even.verdict == .held)

        // Rook takes a defended pawn: a rook for a pawn.
        let bad = try check(
            "4k3/8/2p5/3p4/8/8/8/3RK3 w - - 0 1", "d1d5", .claim(.trade, try square("d5"))
        )
        #expect(bad.verdict == .failed)
        #expect(bad.note?.contains("亏") == true)
    }

    // 攻 — I now threaten it and it cannot hold.
    @Test("攻 holds against a piece that cannot be held and fails against one that can")
    func attack() throws {
        // The rook swings to the d-file: the knight is looked at once and defended not at all.
        let hanging = try check(
            "4k3/8/8/3n4/8/8/8/R3K3 w - - 0 1", "a1d1", .claim(.attack, try square("d5"))
        )
        #expect(hanging.verdict == .held)

        // The same, with a pawn on c6: one attacker, one defender, and it holds.
        let defended = try check(
            "4k3/8/2p5/3n4/8/8/8/R3K3 w - - 0 1", "a1d1", .claim(.attack, try square("d5"))
        )
        #expect(defended.verdict == .failed)
        #expect(defended.note?.contains("守得住") == true)
    }

    @Test("攻 holds when taking the piece would win material, even if the count is level")
    func attackingADearerDefendedPiece() throws {
        // A pawn steps to f4 and looks at the queen on e3. The queen is guarded by the pawn
        // on f2: one attacker, one defender, so a count of hanging would miss it. Taking the
        // queen with the pawn still wins a queen for a pawn, so the queen cannot hold.
        let check = try check(
            "6k1/8/8/5p2/8/4Q3/5P1P/6K1 b - - 0 1", "f5f4", .claim(.attack, try square("e3"))
        )
        #expect(check.verdict == .held)
        #expect(check.note?.contains("守不住") == true)
    }

    @Test("攻 fails when there is nothing of the opponent's on the square")
    func attackingAnEmptySquare() throws {
        let empty = try check(
            "4k3/8/8/3n4/8/8/8/R3K3 w - - 0 1", "a1d1", .claim(.attack, try square("d4"))
        )
        #expect(empty.verdict == .failed)
        #expect(empty.note?.contains("没有对方的子") == true)
    }

    // 护 — it now has one more defender.
    @Test("护 holds when the square gains a defender and fails when it does not")
    func defend() throws {
        let defended = try check(
            "4k3/8/8/8/8/3P4/8/R3K3 w - - 0 1", "a1a3", .claim(.defend, try square("d3"))
        )
        #expect(defended.verdict == .held)
        #expect(defended.note?.contains("守子") == true)

        // The rook goes to a2 instead: the pawn on d3 is exactly as defended as it was.
        let unchanged = try check(
            "4k3/8/8/8/8/3P4/8/R3K3 w - - 0 1", "a1a2", .claim(.defend, try square("d3"))
        )
        #expect(unchanged.verdict == .failed)
        #expect(unchanged.note?.contains("没有增加") == true)
    }

    // 躲 — this piece was hanging and now is not.
    @Test("躲 holds when a hanging piece reaches safety and fails when it does not")
    func flee() throws {
        // The knight on d4 is looked at by the rook on d8 and defended by nobody. f5 is quiet.
        let safe = try check(
            "k2r4/8/8/8/3N4/8/8/7K w - - 0 1", "d4f5", .claim(.flee, try square("d8"))
        )
        #expect(safe.verdict == .held)

        // The same, with a pawn on e6: f5 is not safety, it is the next square it is taken on.
        let outOfTheFrying = try check(
            "k2r4/8/4p3/8/3N4/8/8/7K w - - 0 1", "d4f5", .claim(.flee, try square("d8"))
        )
        #expect(outOfTheFrying.verdict == .failed)
        #expect(outOfTheFrying.note?.contains("一样会被吃") == true)
    }

    @Test("躲 fails when the piece was not hanging in the first place")
    func fleeingNothing() throws {
        // The knight on d1 is looked at once by the rook and defended once by the king: even.
        let notHanging = try check(
            "4k3/8/8/8/8/8/3r4/3NK3 w - - 0 1", "d1c3", .claim(.flee, try square("d2"))
        )
        #expect(notHanging.verdict == .failed)
        #expect(notHanging.note?.contains("悬") == true)
    }

    // 挡 — I interposed on a line.
    @Test("挡 holds when the move gets in the way of something and fails when it does not")
    func block() throws {
        // The rook on e8 is checking down the e-file; the knight steps in front of it.
        let interposed = try check(
            "4rk2/8/8/8/8/8/8/4K1N1 w - - 0 1", "g1e2", .claim(.block, try square("e2"))
        )
        #expect(interposed.verdict == .held)
        #expect(interposed.note?.contains("e1") == true)

        // The same move with nothing to block.
        let pointless = try check(
            "4k3/8/8/8/8/8/8/4K1N1 w - - 0 1", "g1e2", .claim(.block, try square("e2"))
        )
        #expect(pointless.verdict == .failed)
        #expect(pointless.note?.contains("没有挡住") == true)
    }

    // 占 — I hold this square more than the opponent does.
    @Test("占 holds when the square becomes yours and fails when it is still contested")
    func hold() throws {
        let taken = try check(
            "4k3/8/8/8/8/8/8/R3K3 w - - 0 1", "a1a5", .claim(.hold, try square("d5"))
        )
        #expect(taken.verdict == .held)

        // A black pawn on c6 looks at d5 too: one each, and the square is nobody's.
        let contested = try check(
            "4k3/8/2p5/8/8/8/8/R3K3 w - - 0 1", "a1a5", .claim(.hold, try square("d5"))
        )
        #expect(contested.verdict == .failed)
        #expect(contested.note?.contains("算不上") == true)
    }

    // 说不清 — no claim.
    @Test("说不清 is neither right nor wrong, and says so")
    func unclear() throws {
        let shrug = try check("4k3/8/8/8/8/8/8/R3K3 w - - 0 1", "a1a5", .unclear)
        #expect(shrug.verdict == .noClaim)
        #expect(shrug.note == nil)
        #expect(!shrug.held)
    }

    @Test("every verb has a case that holds and a case that fails")
    func theTableIsCovered() throws {
        // The rule this table was made by is that a verb which cannot be wrong does not get a
        // slot, so a verb with no failing case in this file would be a verb that should not
        // exist. This is the list, checked against the enum rather than against a comment.
        let covered: Set<Intent.Verb> = [.take, .trade, .attack, .defend, .flee, .block, .hold]
        #expect(covered == Set(Intent.Verb.allCases))
    }
}
