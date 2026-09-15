import ChessfenKit
import Foundation
import Testing

/// The 错题本: one position, many 遭遇 (docs/adr/0028).

/// A saved game the way this app writes one: both sides moved by hand, reviewed at one depth.
@MainActor
private func saved(
    _ ucis: [String],
    scores: [Int],
    at when: Date,
    named name: String,
    hands: (white: Controller, black: Controller) = (.hand, .hand),
    start: Int = 0
) throws -> GameLibrary.Entry {
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ucis))
    game.applyReview(
        scores.map { Score.centipawns($0) }, startEvaluation: .centipawns(start), depth: 16
    )
    let pgn = PGN(
        game: game,
        tags: [
            PGN.Tag("White", hands.white.playerName),
            PGN.Tag("Black", hands.black.playerName),
        ]
    )
    return GameLibrary.Entry(url: URL(filePath: "/games/\(name).pgn"), pgn: pgn, modified: when)
}

private let day = 86_400.0
private let now = Date(timeIntervalSince1970: 1_790_000_000)

// ------------------------------------------------------------------- identity

@Test("a position is its placement, its side to move, its rights and its en passant square")
func aPositionKeyIsTheFirstFourFields() {
    let key = PositionKey(fen: "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 2 3")
    #expect(key?.text == "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq -")
    #expect(key?.sideToMove == .black)
    #expect(PositionKey(fen: "8/8/8") == nil)
}

@Test("the clocks are not part of what a position is")
func clocksDoNotSplitAPosition() {
    let early = PositionKey(fen: "8/8/8/8/8/8/8/K6k w - - 0 1")
    let later = PositionKey(fen: "8/8/8/8/8/8/8/K6k w - - 47 90")
    #expect(early == later, "the same position reached by a longer road is the same position")
}

// -------------------------------------------------------------------- merging

@MainActor
@Test("the same position blundered in two games is one 错题 with two 遭遇")
func twoGamesOneMistake() throws {
    // 1. e4 e5 2. Nf3 and then Black throws it away, twice, in two different files.
    let first = try saved(
        ["e2e4", "e7e5", "g1f3", "d8h4"],
        scores: [20, 20, 20, 400],
        at: now.addingTimeInterval(-3 * day),
        named: "one"
    )
    let second = try saved(
        ["e2e4", "e7e5", "g1f3", "b8a6"],
        scores: [20, 20, 20, 380],
        at: now.addingTimeInterval(-1 * day),
        named: "two"
    )

    let book = MistakeBook.derive(from: [first, second])
    #expect(book.mistakes.count == 1, "one position, however many games it was lost in")
    let mistake = try #require(book.mistakes.first)
    #expect(mistake.recurrence == 2)
    #expect(mistake.encounters.map(\.played).sorted() == ["Na6", "Qh4"])
    #expect(mistake.lastSeen == now.addingTimeInterval(-1 * day), "newest first")
    #expect(mistake.firstSeen == now.addingTimeInterval(-3 * day))
}

@MainActor
@Test("the same position reached by a different move order merges")
func transpositionsMerge() throws {
    // 1. e4 e5 2. Nf3 Nc6 3. Bc4 and 1. e4 e5 2. Bc4 Nc6 3. Nf3 are the same position, and the
    // move that loses it is the same move.
    let direct = try saved(
        ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6", "f3g5", "d7d5"],
        scores: [20, 20, 20, 20, 20, 20, 20, 400],
        at: now.addingTimeInterval(-2 * day),
        named: "direct"
    )
    let transposed = try saved(
        ["e2e4", "e7e5", "f1c4", "b8c6", "g1f3", "g8f6", "f3g5", "d7d5"],
        scores: [20, 20, 20, 20, 20, 20, 20, 400],
        at: now.addingTimeInterval(-1 * day),
        named: "transposed"
    )

    let book = MistakeBook.derive(from: [direct, transposed])
    #expect(book.mistakes.count == 1, "different roads, one position")
    #expect(book.mistakes.first?.recurrence == 2)
}

// ------------------------------------------------------------------ the lines

@MainActor
@Test("only moves over the 记录线 get into the book")
func onlyRecordedMovesCount() throws {
    let entry = try saved(
        ["e2e4", "e7e5", "g1f3"],
        scores: [20, 100, 90],
        at: now,
        named: "quiet"
    )
    // Black's e5 gives away 20 → 100, which is eight points: under the line.
    #expect(MistakeBook.derive(from: [entry]).isEmpty)

    // The same game judged by somebody who wants everything written down.
    let fussy = MistakeBook.derive(from: [entry], lines: JudgementLines(record: 5, enqueue: 20))
    #expect(fussy.mistakes.count == 1)
}

@MainActor
@Test("a game nobody has reviewed contributes nothing, which is not the same as nothing wrong")
func unreviewedGamesAreNotJudged() throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
    #expect(!game.isReviewed, "nobody has run a pass over it")
    let entry = GameLibrary.Entry(
        url: URL(filePath: "/games/unseen.pgn"),
        pgn: PGN(game: game, tags: [PGN.Tag("White", "手动"), PGN.Tag("Black", "手动")]),
        modified: now
    )
    #expect(MistakeBook.derive(from: [entry]).isEmpty)
}

@MainActor
@Test("the engine's blunders are the engine's")
func onlyTheHandsMistakesCount() throws {
    let entry = try saved(
        ["e2e4", "e7e5", "g1f3", "d8h4"],
        scores: [20, 20, 20, 400],
        at: now,
        named: "vs-engine",
        hands: (white: .hand, black: .engine)
    )
    #expect(
        MistakeBook.derive(from: [entry]).isEmpty,
        "Black was Stockfish, so Black's move is not the player's mistake"
    )
}

// ------------------------------------------------------------------ the sentence

@MainActor
@Test("the book can say the one sentence no other identity could")
func theSentenceAboutRecurrence() throws {
    var entries: [GameLibrary.Entry] = []
    for (index, uci) in ["d8h4", "b8a6", "d8h4", "d8h4"].enumerated() {
        entries.append(
            try saved(
                ["e2e4", "e7e5", "g1f3", uci],
                scores: [20, 20, 20, 400],
                at: now.addingTimeInterval(-Double(3 - index) * day),
                named: "game-\(index)"
            )
        )
    }
    let mistake = try #require(MistakeBook.derive(from: entries).mistakes.first)
    #expect(mistake.recurrence == 4)
    #expect(mistake.attempts.map(\.move) == ["Qh4", "Na6"])
    #expect(mistake.attempts.map(\.times) == [3, 1])

    let said = Speech.speaking(.chinese) { mistake.sentence(now: now) }
    #expect(said.contains("栽过 4 次"))
    #expect(said.contains("3 次走 Qh4"))
    #expect(said.contains("1 次走 Na6"))
    #expect(said.contains("最近一次是刚刚"))
}

// ------------------------------------------------------------------- ordering

@Test("recurrence jumps the queue, whatever any single occasion cost")
func recurrenceOutranksSeverity() {
    let key = PositionKey("8/8/8/8/8/8/8/K6k w - -")
    let other = PositionKey("8/8/8/8/8/8/8/K5k1 w - -")
    func encounter(_ cost: Double, _ offset: Double) -> Encounter {
        Encounter(
            game: URL(filePath: "/games/x.pgn"), ply: 1, when: now.addingTimeInterval(offset),
            played: "Ka1", wanted: nil, cost: cost, origin: .fresh
        )
    }
    let often = Mistake(
        position: key, encounters: [encounter(12, -3 * day), encounter(12, -2 * day), encounter(12, -day)]
    )
    let once = Mistake(position: other, encounters: [encounter(40, -day)])
    #expect(often.isMorePressing(than: once))
    #expect(MistakeBook(mistakes: [once, often]).mistakes.first?.position == key)
}
