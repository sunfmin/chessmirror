import ChessfenKit
import SwiftUI
import Testing

@testable import Chessfen

/// 老毛病, photographed — and held to the one promise it makes: a count and a way back to the
/// move, never a rating and never a percentage (docs/adr/0018).
@MainActor
@Suite(.serialized, .speaking(.chinese))
struct HabitsScreenshots {
    private static func played(_ moves: [String]) throws -> Game {
        try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: moves))
    }

    private static func square(_ name: String) throws -> Square {
        try #require(Square(name))
    }

    private static func entry(_ game: Game, named name: String) -> GameLibrary.Entry {
        var pgn = PGN(game: game)
        pgn.setTag("White", to: Controller.hand.playerName)
        pgn.setTag("Black", to: Controller.engine.playerName)
        pgn.setTag(GameLibrary.nameTag, to: name)
        return GameLibrary.Entry(
            url: URL(filePath: "/games/\(name).pgn"), pgn: pgn, modified: Date()
        )
    }

    /// Scores that drift the way two people who can both play make them drift: a worst three
    /// exists, and none of the three threw anything away.
    private static func drifting(_ game: Game, plies: Int) -> Game {
        var game = game
        game.applyReview(
            (0..<plies).map { .centipawns(20 + ($0.isMultiple(of: 2) ? 15 : -10)) },
            startEvaluation: .centipawns(10),
            depth: 18
        )
        return game
    }

    /// 1.e4 e5 2.Nf3 Nc6 3.Nxe5 — a knight on a square nothing of White's defends. The sixth ply
    /// decides whether the opponent took it, which is the whole difference between the two modes.
    private static func thrownAway(answeredWith reply: String) throws -> Game {
        var game = try played(["e2e4", "e7e5", "g1f3", "b8c6", "f3e5", reply])
        game.applyReview(
            [
                .centipawns(30), .centipawns(25), .centipawns(35), .centipawns(30),
                .centipawns(-300),  // 3. Nxe5?? — the worst move in the game
                .centipawns(-290),
            ],
            startEvaluation: .centipawns(20),
            depth: 18
        )
        return game
    }

    /// A library with one game per mode, so one picture shows all five.
    private static func fiveModes() throws -> [GameLibrary.Entry] {
        var untrue = drifting(try played(["e2e4", "e7e5", "g1f3", "b8c6", "f1c4"]), plies: 5)
        untrue.setIntent(.claim(.defend, try square("e4")), atPly: 5)

        var unclear = drifting(
            try played(["e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "a7a6"]), plies: 6
        )
        unclear.setIntent(.unclear, atPly: 5)

        var attacking = drifting(
            try played(["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6", "f3g5"]), plies: 7
        )
        attacking.setIntent(.claim(.attack, try square("f7")), atPly: 7)

        return [
            entry(try thrownAway(answeredWith: "c6e5"), named: "周二那局"),
            entry(try thrownAway(answeredWith: "d7d6"), named: "周三那局"),
            entry(untrue, named: "俱乐部第一轮"),
            entry(unclear, named: "俱乐部第二轮"),
            entry(attacking, named: "线上快棋"),
        ]
    }

    private func screen(_ habits: Habits) -> some View {
        NavigationStack {
            HabitsView(habits: habits) { _ in }
        }
    }

    @Test("every mode the library produced is named, counted, and pointed back at a move")
    func theTally() async throws {
        let habits = Habits.over(try Self.fiveModes())

        let rendered = await ScreenImage.write("habits") { screen(habits) }

        #expect(rendered.says("老毛病"))
        for mode in Habit.Mode.allCases {
            #expect(rendered.says(mode.label), "\(mode.label) is on the screen")
        }
        #expect(rendered.count(of: "1 次") == 5, "each of the five happened once, and says so")
        #expect(rendered.says("第 3 回合"), "and the move it happened on")
        #expect(rendered.says("Nxe5"))
        #expect(rendered.says("周二那局"), "named so the row is a way back to the game")
        #expect(rendered.says("数了 5 局"))
    }

    @Test("the same tally in the dark")
    func theTallyInTheDark() async throws {
        let habits = Habits.over(try Self.fiveModes())

        let rendered = await ScreenImage.write("habits-dark", style: .dark) { screen(habits) }

        #expect(rendered.says("送子"))
        #expect(rendered.says("没算对手那一步"))
    }

    @Test("no rating and no percentage appears anywhere on it")
    func noFakeNumbers() async throws {
        let habits = Habits.over(try Self.fiveModes())

        let rendered = await ScreenImage.write("habits") { screen(habits) }

        // SwiftUI gives the scroll view itself a value — "0%", how far down it is — so a word
        // that is nothing but a percentage is the harness talking. Anything else carrying one
        // would be this app inventing a number, which is the thing being forbidden.
        let ours = rendered.words.filter {
            $0.range(of: "^[0-9]+%$", options: .regularExpression) == nil
        }
        for word in ours {
            #expect(!word.contains("%"), "not a percentage: \(word)")
            #expect(!word.contains("准确率"), "not an accuracy: \(word)")
            #expect(!word.contains("等级分"), "not a rating: \(word)")
            #expect(!word.contains("分数"), "not a score: \(word)")
        }
    }

    @Test("a library with nothing to count says so instead of showing five zeros")
    func nothingToCount() async throws {
        let unreviewed = Self.entry(
            try Self.played(["e2e4", "e7e5", "g1f3", "b8c6", "f3e5", "c6e5"]), named: "没打分那局"
        )
        let habits = Habits.over([unreviewed])

        let rendered = await ScreenImage.write("habits-empty") { screen(habits) }

        #expect(rendered.says("还没有能数的对局"))
        #expect(rendered.says("另外 1 局还没打过分，没算进去。"), "and why it was left out")
        #expect(!rendered.says("0 次"), "no row of zeros")
        for mode in Habit.Mode.allCases {
            #expect(!rendered.says(mode.label), "\(mode.label) has no row at all")
        }
    }

    @Test("a library that was read and had nothing to confess says that instead")
    func nothingFound() async throws {
        let quiet = Self.drifting(
            try Self.played(["e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "a7a6"]), plies: 6
        )
        let habits = Habits.over([Self.entry(quiet, named: "平稳那局")])

        let rendered = await ScreenImage.write("habits-clean") { screen(habits) }

        #expect(rendered.says("数了 1 局，没找到老毛病。"))
        #expect(!rendered.says("还没有能数的对局"), "which is a different statement")
    }
}
