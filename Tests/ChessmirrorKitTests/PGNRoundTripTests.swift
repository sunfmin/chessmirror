@testable import ChessmirrorKit
import Testing

/// What this app writes into a PGN comment comes back as the same value, through the one
/// spelling the writer and the reader share. Older judgement comments still open. A comment
/// this app does not know is dropped, and the game opens anyway.
@Suite struct PGNRoundTripTests {
    @Test func annotationsThisAppWritesComeBackTheSame() throws {
        var game = try #require(Game(
            startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3"]
        ))
        game.setJudgement(
            .init(drop: 0, score: .centipawns(30), depth: 20, intercept: 10, best: true), atPly: 0
        )
        game.setJudgement(
            .init(drop: 4.5, score: .centipawns(-12), depth: 18), atPly: 1
        )
        game.setTried([
            .init(san: "a3", drop: 12, notFound: true, depth: 20, line: ["e5", "Nf3"]),
            .init(san: "f3", drop: 23.5, depth: 16, line: ["e5"]),
        ], atPly: 0)
        game.setStrength(.elo(1800), atPly: 2)
        game.applyReview(
            [
                .init(score: .centipawns(30), line: ["e5", "Nf3"]),
                .init(score: .centipawns(10), line: ["Nf3"]),
                .init(score: .centipawns(20), line: ["Nc6"]),
            ],
            startEvaluation: .centipawns(15),
            depth: 16
        )
        let branched = game.play(uci: "d2d4", atPly: 0)
        #expect(branched)
        // A 试招 nothing has carried yet, written after the branch so it stays on the game
        // rather than riding into the line that left.
        game.setPendingTried(
            [.init(san: "c5", drop: 40, notFound: true, depth: 22, line: ["Nf3"])], atPly: 1
        )

        let text = PGN(game: game).text
        let read = try PGN(parsing: text).game
        #expect(read == game)
        let kept = try #require(read.plies[0].variations.first?.first)
        #expect(kept.tried.map(\.san) == ["a3", "f3"])
        #expect(kept.tried[0].notFound)
        #expect(kept.tried[0].depth == 20)
        #expect(kept.tried[0].line == ["e5", "Nf3"])
        #expect(kept.judgement?.best == true)
        #expect(kept.judgement?.intercept == 10)
        #expect(kept.line == ["e5", "Nf3"])
        #expect(read.plies[0].variations[0][2].strength == .elo(1800))
        #expect(read.plies[0].isTrunk == false)
        let pending = read.pendingTries(atPly: 1)
        #expect(pending.map(\.san) == ["c5"])
        #expect(pending.first?.notFound == true)
        #expect(pending.first?.depth == 22)
        #expect(pending.first?.line == ["Nf3"])
    }

    @Test func movetextNumbersMatchTheScoresheet() throws {
        let position = "r3k3/2N5/8/8/8/8/8/4K3 b q - 0 17"
        var game = try #require(Game(startFEN: position))
        let kingMoved = game.apply(uci: "e8d8")
        let knightTook = game.apply(uci: "c7a8")
        #expect(kingMoved)
        #expect(knightTook)
        let text = PGN(game: game).text
        for (index, ply) in game.plies.enumerated() {
            let number = game.moveNumber(ofPly: index + 1)
            let onTheSheet = game.scoresheet.contains {
                $0.number == number && ($0.white?.san == ply.san || $0.black?.san == ply.san)
            }
            #expect(onTheSheet)
            if game.mover(ofPly: index + 1) == .white {
                #expect(text.contains("\(number). \(ply.san)"))
            } else if index == 0 {
                #expect(text.contains("\(number)... \(ply.san)"))
            }
        }
    }

    @Test func anOlderJudgementCommentStillOpens() throws {
        let legacy = try PGN(parsing: """
            1. e4 {[%judged 20 0.0 +0.30]} e5 {[%judged 20 3.2 +0.10 under 10.0]} *
            """)
        #expect(legacy.game.plies[0].judgement == .init(drop: 0, score: .centipawns(30), depth: 20))
        #expect(legacy.game.plies[0].judgement?.best == false)
        #expect(legacy.game.plies[1].judgement?.intercept == 10)
        #expect(legacy.game.plies[1].judgement?.drop == 3.2)
        #expect(legacy.game.plies[1].judgement?.best == false)
    }

    @Test func aForeignCommentIsDroppedAndTheGameStillOpens() throws {
        let read = try PGN(parsing: "1. e4 {a note in prose [%foo hello] [%bar]} e5 *")
        #expect(read.game.uciMoves == ["e2e4", "e7e5"])
        #expect(read.game.plies.allSatisfy {
            $0.judgement == nil && $0.tried.isEmpty && $0.line.isEmpty && $0.strength == nil
        })
    }
}
