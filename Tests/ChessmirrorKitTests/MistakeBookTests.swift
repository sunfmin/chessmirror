import ChessmirrorKit
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
    // Black's e5 gives away 20 → 100, which is seven points: under a 10-point 记录线.
    let relaxed = MistakeBook.derive(from: [entry], lines: JudgementLines(record: 10, enqueue: 20))
    #expect(relaxed.isEmpty)

    // Which is what the phone ships with: a seven-point slip is not a 错题 for the book.
    #expect(MistakeBook.derive(from: [entry], lines: .standard).isEmpty)

    // The same game judged by somebody who wants everything written down, from where 正着
    // already stops you.
    let fussy = MistakeBook.derive(from: [entry], lines: JudgementLines(record: 5, enqueue: 5))
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

// ------------------------------------------------- refusals nothing absorbed

/// Contract: a 试招 that no move came along to carry is a 遭遇 like any other (docs/adr/0037).
///
/// The text is a game off the phone, unedited: 正着 refused Be3 at the position after twelve
/// Plies, the player put the phone down, and the refusal was written where it happened — with no
/// move to ride on. The book read every move in the file and nothing at the end of it, so the one
/// position the session actually stopped at was the one position it did not record.
@MainActor
@Test("a refusal at the position a game stops on is a 遭遇")
func aRefusalNothingAbsorbedEntersTheBook() throws {
    let text = """
        [Event "Chessmirror"]
        [Site "chessmirror"]
        [Date "2026.09.16"]
        [Round "-"]
        [White "手动"]
        [Black "Stockfish 18"]
        [Result "*"]
        [Intercept "5.0"]
        [Source "fresh"]

        1. e4 {[%judged 20 0.0 0.33]} e5 2. Nf3 {[%judged 20 0.7345862071151075 0.23]}
        Nc6 3. Bc4 {[%judged 20 0.36748842712031404 0.22]} Nf6 4. d3
        {[%judged 20 0.0 0.30]} Bc5 5. O-O {[%judged 20 0.18350542345834242 0.30]} d6 6.
        Re1 {[%judged 20 1.3781115723684891 0.16]} Be6
        {[%pending 12 Be3 -16.064889506354888% | Bxc4 dxc4 Nxe4 Nbd2 Bxe3]} *
        """
    let pgn = try PGN(parsing: text)
    #expect(pgn.game.plies.count == 12, "the refused move is not one of them")
    #expect(!pgn.game.isReviewed, "and nobody has reviewed the game — this is a live 正着 file")

    let entry = GameLibrary.Entry(
        url: URL(filePath: "/games/be3.pgn"), pgn: pgn, modified: now
    )
    let book = MistakeBook.derive(from: [entry])
    let mistake = try #require(book.mistakes.first, "the position Be3 was refused at")
    #expect(book.mistakes.count == 1)
    #expect(mistake.encounters.map(\.played) == ["Be3"])
    #expect(mistake.worstCost > 16 && mistake.worstCost < 17)
    // The day the game says it was played, not the day the file was last written: a re-save or
    // a Review landing is not another time the player fell for this.
    #expect(mistake.lastSeen == PGN.playedDay("2026.09.16"))
    #expect(mistake.encounters.first?.wanted == nil, "no Review, so nothing is claimed about it")
    // The position is the one the refused move was played from — White to move, twelve Plies in,
    // which is the board that was on the screen when 正着 gave the move back.
    #expect(mistake.position.sideToMove == .white)
    let after = try #require(pgn.game.rewound(to: 12))
    #expect(mistake.position == PositionKey(fen: after.state.fen))
}

/// And the same refusal keeps its name once a move is finally played there: the Ply it is filed
/// under is the one that move takes, so it is the same 遭遇 rather than a second one.
@MainActor
@Test("an absorbed refusal and a pending one are the same occasion, not two")
func aRefusalKeepsItsIdentityWhenAMoveAbsorbsIt() throws {
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
    game.setPendingTried([.init(san: "Nh3", drop: 30)], atPly: 2)
    let waiting = GameLibrary.Entry(
        url: URL(filePath: "/games/one.pgn"),
        pgn: PGN(game: game, tags: [PGN.Tag("White", Controller.hand.playerName)]),
        modified: now
    )
    let pending = try #require(MistakeBook.derive(from: [waiting]).mistakes.first)
    #expect(pending.encounters.map(\.played) == ["Nh3"])

    // The player comes back and plays something else from that position; the refusal rides onto
    // the move, which is where a 试招 normally lives.
    var carried = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6"]))
    carried.setTried([.init(san: "Nh3", drop: 30)], atPly: 2)
    let absorbed = GameLibrary.Entry(
        url: URL(filePath: "/games/one.pgn"),
        pgn: PGN(game: carried, tags: [PGN.Tag("White", Controller.hand.playerName)]),
        modified: now
    )
    let moved = try #require(MistakeBook.derive(from: [absorbed]).mistakes.first)
    #expect(moved.encounters.map(\.id) == pending.encounters.map(\.id), "one occasion, not two")
}
