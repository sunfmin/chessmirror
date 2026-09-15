import ChessfenKit
import Foundation
import Testing

/// 老毛病 — the tally over a library, and the five things it can say.
///
/// The library here is a handful of values rather than a folder, because `Habits.over` takes the
/// entries: nothing about the tally touches a disk, a clock or a schedule (docs/adr/0018).

private let start = PGN.standardStartFEN

private func played(_ moves: [String]) throws -> Game {
    try #require(Game(startFEN: start, uciMoves: moves))
}

private func square(_ name: String) throws -> Square {
    try #require(Square(name))
}

/// A game as it would sit in the library: named, and with the tags that say who moved which side.
private func entry(
    _ game: Game,
    named name: String,
    white: Controller = .hand,
    black: Controller = .engine,
    at path: String? = nil
) -> GameLibrary.Entry {
    var pgn = PGN(game: game)
    pgn.setTag("White", to: white.playerName)
    pgn.setTag("Black", to: black.playerName)
    pgn.setTag(GameLibrary.nameTag, to: name)
    return GameLibrary.Entry(
        url: URL(filePath: "/games/\(path ?? name).pgn"), pgn: pgn, modified: Date()
    )
}

/// Six ordinary moves and nothing hanging: the shape a game has when it has nothing to say.
private let quiet = ["e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "a7a6"]

/// Scores that drift by tenths the way two people who can both play make them drift. White's
/// worst three moves are still ranked — every game has a worst three — and none of them hung
/// anything, which is how a ranked move ends up with no mode at all.
private func drifting(_ game: Game, plies: Int) -> Game {
    var game = game
    game.applyReview(
        (0..<plies).map { .centipawns(20 + ($0.isMultiple(of: 2) ? 15 : -10)) },
        startEvaluation: .centipawns(10),
        depth: 18
    )
    return game
}

/// 1.e4 e5 2.Nf3 Nc6 3.Nxe5 — the knight goes to a square nothing of White's defends, which is
/// the whole of what 送子 means. The sixth ply decides whether they took it.
private func thrownAway(answeredWith reply: String) throws -> Game {
    var game = try played(["e2e4", "e7e5", "g1f3", "b8c6", "f3e5", reply])
    game.applyReview(
        [
            .centipawns(30),  // 1. e4
            .centipawns(25),  // 1… e5
            .centipawns(35),  // 2. Nf3
            .centipawns(30),  // 2… Nc6
            .centipawns(-300),  // 3. Nxe5??  white lost 330 — the worst move in the game
            .centipawns(-290),  // 3… the answer
        ],
        startEvaluation: .centipawns(20),
        depth: 18
    )
    return game
}

/// The five games, one per mode, each shaped so that only its own mode can come out of it.
private func fiveModes() throws -> [GameLibrary.Entry] {
    // 没算对手那一步 — hung on e5 and taken off e5 on the very next move.
    let missed = try thrownAway(answeredWith: "c6e5")
    // 送子 — hung on e5 and got away with it: Black answers with d6 instead.
    let given = try thrownAway(answeredWith: "d7d6")

    // 理由不成立 — 3.Bc4 declared as 护 e4, which the bishop does not defend.
    var untrue = drifting(try played(["e2e4", "e7e5", "g1f3", "b8c6", "f1c4"]), plies: 5)
    untrue.setIntent(.claim(.defend, try square("e4")), atPly: 5)

    // 说不清 — a move with the question mark recorded rather than skipped.
    var unclear = drifting(try played(quiet), plies: 6)
    unclear.setIntent(.unclear, atPly: 5)

    // 只顾进攻 — 4.Ng5 really does attack f7, and White's e4 pawn has been hanging since Nf6.
    var attacking = drifting(
        try played(["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6", "f3g5"]), plies: 7
    )
    attacking.setIntent(.claim(.attack, try square("f7")), atPly: 7)

    return [
        entry(missed, named: "没算"),
        entry(given, named: "送子"),
        entry(untrue, named: "理由"),
        entry(unclear, named: "说不清"),
        entry(attacking, named: "只顾进攻"),
    ]
}

@Test("a library shaped to produce each failure mode produces each failure mode")
func everyModeIsFound() throws {
    let habits = Habits.over(try fiveModes())

    #expect(habits.gamesCounted == 5)
    #expect(habits.excludedCount == 0)
    for mode in Habit.Mode.allCases {
        let habit = try #require(habits.habit(mode), "\(mode.label) should have been found")
        #expect(habit.count == 1, "\(mode.label) happened once in this library")
    }
}

@Test("each mode says how many times it happened and where")
func eachOccurrenceIsTheWayBackToTheMove() throws {
    let habits = Habits.over(try fiveModes())
    let missed = try #require(habits.habit(.missedReply))
    let where_ = try #require(missed.occurrences.first)

    #expect(where_.ply == 5)
    #expect(where_.moveNumber == 3, "written as 3. Nxe5, which is what a person would look for")
    #expect(where_.mover == .white)
    #expect(where_.san == "Nxe5")
    #expect(where_.title == "没算")
    #expect(where_.game.lastPathComponent == "没算.pgn", "the file is the way back to it")
    #expect(where_.note?.contains("e5") == true, "and it names the square")
}

@Test("hanging a piece and having it taken is the sharper diagnosis, not both of them")
func takenAndNotTakenAreDifferentModes() throws {
    let taken = Habits.over([entry(try thrownAway(answeredWith: "c6e5"), named: "吃了")])
    #expect(taken.habit(.missedReply)?.count == 1)
    #expect(taken.habit(.giveaway) == nil, "one move, one diagnosis")

    let spared = Habits.over([entry(try thrownAway(answeredWith: "d7d6"), named: "没吃")])
    #expect(spared.habit(.giveaway)?.count == 1)
    #expect(spared.habit(.missedReply) == nil)
}

@Test("a ranked move that hung nothing gets no mode, so a clean library is not an empty one")
func aCleanLibraryIsNotAnEmptyOne() throws {
    let habits = Habits.over([entry(drifting(try played(quiet), plies: 6), named: "平稳")])

    #expect(habits.gamesCounted == 1)
    #expect(habits.habits.isEmpty)
    #expect(habits.isClean)
    #expect(!habits.hasNothingToCount, "one game was read; it just had nothing to confess")
}

@Test("an empty library says so instead of showing five zeros")
func anEmptyLibrarySaysSo() {
    let habits = Habits.over([])

    #expect(habits.hasNothingToCount)
    #expect(!habits.isClean, "nothing was counted, which is not the same as nothing was found")
    #expect(habits.habits.isEmpty)
    for mode in Habit.Mode.allCases {
        #expect(habits.habit(mode) == nil, "\(mode.label) has no row at all, not a row of zero")
    }
}

@Test("games no review has been over are excluded, and said to be excluded")
func unreviewedGamesAreSaidToBeExcluded() throws {
    // The same giveaway three times over, reviewed once. An unreviewed copy cannot be ranked at
    // all, so counting it would be counting it as clean (docs/adr/0016).
    let reviewed = entry(try thrownAway(answeredWith: "c6e5"), named: "打过分")
    let raw = entry(try played(["e2e4", "e7e5", "g1f3", "b8c6", "f3e5", "c6e5"]), named: "没打分")
    let alsoRaw = entry(try played(quiet), named: "也没打分")

    let habits = Habits.over([reviewed, raw, alsoRaw])

    #expect(habits.gamesCounted == 1)
    #expect(habits.excluded[.unreviewed] == 2)
    #expect(habits.habit(.missedReply)?.count == 1, "one, not three")
    #expect(habits.exclusions.contains { $0.reason == .unreviewed && $0.count == 2 })
    #expect(Habits.Exclusion.unreviewed.label.isEmpty == false, "and it has words to say it in")
}

@Test("a file that will not read and one still coming down from iCloud are counted apart")
func theOtherTwoExclusions() throws {
    let broken = GameLibrary.Entry(
        url: URL(filePath: "/games/broken.pgn"), pgn: nil, modified: Date()
    )
    let coming = GameLibrary.Entry(
        url: URL(filePath: "/games/coming.pgn"), pgn: nil, modified: Date(), isDownloading: true
    )

    let habits = Habits.over([broken, coming])

    #expect(habits.gamesCounted == 0)
    #expect(habits.excluded[.unreadable] == 1)
    #expect(habits.excluded[.waiting] == 1)
    #expect(habits.exclusions.count == 2, "two different reasons, said as two")
}

@Test("only the side the file says a person moved is counted")
func somebodyElsesMistakesStayTheirs() throws {
    // Black threw the knight away on ply 6, which is the engine's move in this file.
    var game = try played(["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "c6d4", "f3d4"])
    game.applyReview(
        [
            .centipawns(30), .centipawns(25), .centipawns(35), .centipawns(30),
            .centipawns(25),
            .centipawns(320),  // 3… Nd4?? black lost 295
            .centipawns(330),
        ],
        startEvaluation: .centipawns(20),
        depth: 18
    )

    let engineIsBlack = Habits.over([entry(game, named: "我执白", white: .hand, black: .engine)])
    #expect(engineIsBlack.habits.isEmpty, "the engine's blunder is not the player's 老毛病")

    let engineIsWhite = Habits.over([entry(game, named: "我执黑", white: .engine, black: .hand)])
    #expect(engineIsWhite.habits.isEmpty == false, "the same file, read from the other side")
    #expect(engineIsWhite.habits.first?.occurrences.first?.mover == .black)
}

@Test("modes are listed most times first")
func mostTimesFirst() throws {
    let entries = try [
        entry(thrownAway(answeredWith: "c6e5"), named: "一", at: "1"),
        entry(thrownAway(answeredWith: "c6e5"), named: "二", at: "2"),
        entry(thrownAway(answeredWith: "d7d6"), named: "三", at: "3"),
    ]
    let habits = Habits.over(entries)

    #expect(habits.habits.map(\.mode) == [.missedReply, .giveaway])
    #expect(habits.habits.map(\.count) == [2, 1])
}

@Test("counting changes nothing, so asking twice gives the same answer")
func nothingIsStored() throws {
    let entries = try fiveModes()
    let texts = entries.map(\.pgn!.text)

    let first = Habits.over(entries)
    let second = Habits.over(entries)

    #expect(first == second)
    #expect(entries.map(\.pgn!.text) == texts, "no file was rewritten to hold a tally")
}

@Test("a game corrected or deleted outside the app changes the answer, with nothing to reconcile")
func theFilesAreTheTruth() throws {
    var entries = try fiveModes()
    #expect(Habits.over(entries).habit(.missedReply)?.count == 1)

    // Deleted in the Files app: the entry is simply gone the next time the folder is listed.
    entries.removeAll { $0.pgn?.tag(GameLibrary.nameTag) == "没算" }
    #expect(Habits.over(entries).habit(.missedReply) == nil)
    #expect(Habits.over(entries).gamesCounted == 4)

    // Corrected in the Files app: the reason taken back out of the file takes the mode with it.
    var fixed = try #require(entries.first { $0.pgn?.tag(GameLibrary.nameTag) == "说不清" })
    var pgn = try #require(fixed.pgn)
    pgn.game.setIntent(nil, atPly: 5)
    fixed.pgn = pgn
    entries = entries.map { $0.url == fixed.url ? fixed : $0 }
    #expect(Habits.over(entries).habit(.noReason) == nil)
}

@Test("nothing in the tally is a rating or a percentage", .speaking(.chinese))
func noFakeNumbers() throws {
    let habits = Habits.over(try fiveModes())
    let words =
        habits.habits.flatMap { habit in
            [habit.mode.label, habit.mode.explanation]
                + habit.occurrences.compactMap(\.note)
        } + Habits.Exclusion.allCases.map(\.label)

    for word in words {
        #expect(!word.contains("%"))
        #expect(!word.contains("准确率"))
        #expect(!word.contains("等级分"))
    }
}

@Test("an occurrence points at the position the move was made in, not the one after it")
func theWayBackIsThePositionBeforeTheMove() throws {
    let entries = try fiveModes()
    let habits = Habits.over(entries)
    let where_ = try #require(habits.habit(.missedReply)?.occurrences.first)
    let game = try #require(entries.first { $0.url == where_.game }?.pgn?.game)

    // What a screen does with an Occurrence is jump one ply short of it, so the board stands
    // where the player stood — which is exactly where a Drill asks its question.
    let asked = try #require(game.rewound(to: where_.ply - 1))
    #expect(asked.plies.count == where_.ply - 1)
    #expect(asked.state.sideToMove == where_.mover, "and it is their move again")
    #expect(asked.state.move(matching: game.plies[where_.ply - 1].uci) != nil)
}
