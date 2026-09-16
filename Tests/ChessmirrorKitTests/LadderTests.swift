@testable import ChessmirrorKit
import Foundation
import Testing

/// Contract: the 正着榜 is read out of the games (docs/adr/0038). Every move that stood under 正着
/// is credited to the rung the engine was on when it was played; a 连正 is a run at one rung,
/// ended by a 试招 or by a change of rung; a stretch at no rung is credited nowhere. Only the
/// longest run is kept per rung: a count of everything that stood was the length of the game.
@Suite struct LadderTests {
    private static let under = Game.Ply.Judgement(
        drop: 1, score: .centipawns(20), depth: 20, intercept: 5
    )
    private static let italian = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6", "d2d4"]

    /// 1. e4 e5 2. Nf3 Nc6 at 1400, then 3. Bc4 Bc5 4. c3 Nf6 5. d4 at 1800, White's five moves
    /// all standing and a 试招 before 4. c3.
    private static func climbed() throws -> Game {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: italian))
        for ply in [0, 2, 4, 6, 8] { game.setJudgement(under, atPly: ply) }
        game.setStrength(.elo(1400), atPly: 1)
        game.setStrength(.elo(1400), atPly: 3)
        game.setStrength(.elo(1800), atPly: 5)
        game.setStrength(.elo(1800), atPly: 7)
        game.setTried([.init(san: "Nh3", drop: 12)], atPly: 6)
        return game
    }

    @Test("each stretch is credited to its own rung, and a run does not cross rungs")
    func creditsFollowTheRung() throws {
        let climbed = try Self.climbed()
        let credits = Ladder.credits(in: climbed, by: [.white])
        let at1400 = try #require(credits.first(where: { $0.strength == Strength.elo(1400) }))
        #expect(at1400.longestRun == 2)
        let at1800 = try #require(credits.first(where: { $0.strength == Strength.elo(1800) }))
        #expect(at1800.longestRun == 2, "4. c3 and 5. d4 — the 试招 before 4. c3 ended the run 3. Bc4 began, and d4 is at the rung before it")
        #expect(credits.count == 2)
    }

    @Test("a game against a human is at no rung, and goes on no ladder")
    func aHumanGameIsCreditedNowhere() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        for ply in [0, 2, 4, 6, 8] { game.setJudgement(Self.under, atPly: ply) }
        #expect(Ladder.credits(in: game, by: [.white]).isEmpty)
        #expect(game.noSlips(by: [.white]).longestRun == 5, "though the row still counts them")
    }

    @Test("满力 is a rung of its own, and moves played with 正着 off stand under nothing")
    func fullStrengthIsARung() throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        game.setJudgement(Self.under, atPly: 0)
        game.setJudgement(
            Game.Ply.Judgement(drop: 1, score: .centipawns(20), depth: 20), atPly: 2
        )
        for ply in [1, 3, 5, 7] { game.setStrength(.full, atPly: ply) }
        let credits = Ladder.credits(in: game, by: [.white])
        #expect(credits == [Ladder.Credit(strength: .full, longestRun: 1)])
    }

    @Test("the ladder keeps each rung's longest run, with the game it was made in")
    func theLadderKeepsBests() throws {
        let climb = URL(filePath: "/games/climb.pgn")
        let long = URL(filePath: "/games/long.pgn")
        let climbed = try Self.climbed()
        let ladder = Ladder.sum([
            (game: climb, credits: Ladder.credits(in: climbed, by: [.white])),
            (game: long, credits: [
                Ladder.Credit(strength: .elo(1800), longestRun: 1),
                Ladder.Credit(strength: .full, longestRun: 4),
            ]),
        ])
        #expect(ladder.rows.map(\.strength) == [.elo(1400), .elo(1800), .full], "ladder order")
        let at1800 = try #require(ladder[.elo(1800)])
        #expect(at1800.longestRun == Ladder.Best(value: 2, game: climb), "the climb's two beat the long game's one")
        #expect(ladder[.elo(1400)]?.longestRun == Ladder.Best(value: 2, game: climb))
        #expect(ladder[.full]?.longestRun == Ladder.Best(value: 4, game: long))
        #expect(ladder[.elo(2800)] == nil, "no rung nobody has stood at")
        #expect(Ladder.derive(from: [GameLibrary.Entry]()).isEmpty)
    }

    @Test("a game the ladder reads is the one its 正着 was written into, through a file")
    func theLadderReadsAFile() throws {
        let game = try Self.climbed()
        let written = PGN(
            game: game,
            tags: [
                PGN.Tag("White", Controller.hand.playerName),
                PGN.Tag("Black", Controller.engine.playerName),
            ]
        ).text
        let read = try PGN(parsing: written)
        let entry = GameLibrary.Entry(
            url: URL(filePath: "/games/climb.pgn"), pgn: read, modified: Date()
        )
        let credits = Ladder.credits(in: entry)
        let at1800 = credits.first(where: { $0.strength == Strength.elo(1800) })
        let at1400 = credits.first(where: { $0.strength == Strength.elo(1400) })
        #expect(at1800?.longestRun == 2)
        #expect(at1400?.longestRun == 2)
    }

    @MainActor
    @Test("the index keeps the ladder beside the book, and walks a game once for both")
    func theIndexCachesTheLadder() throws {
        let log = PracticeLog(
            url: URL(filePath: NSTemporaryDirectory())
                .appending(path: "chessmirror-ladder-\(UUID().uuidString).jsonl")
        )
        let index = MistakeIndex(log: log)
        let climbed = try Self.climbed()
        let entry = GameLibrary.Entry(
            url: URL(filePath: "/games/climb.pgn"),
            pgn: PGN(
                game: climbed,
                tags: [
                    PGN.Tag("White", Controller.hand.playerName),
                    PGN.Tag("Black", Controller.engine.playerName),
                ]
            ),
            modified: Date(timeIntervalSince1970: 1_790_000_000)
        )
        index.update(from: [entry])
        #expect(index.walkedLastTime == 1)
        #expect(index.ladder[.elo(1800)]?.longestRun == .init(value: 2, game: entry.url))

        index.update(from: [entry])
        #expect(index.walkedLastTime == 0, "nothing changed, nothing walked")
        #expect(index.ladder[.elo(1800)]?.longestRun.value == 2, "and the ladder is still there")

        index.update(from: [])
        #expect(index.ladder.isEmpty, "a game deleted leaves with its credits")
    }
}
