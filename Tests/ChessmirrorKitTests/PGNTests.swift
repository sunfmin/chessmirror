import ChessmirrorKit
import Foundation
import Testing

private let start = PGN.standardStartFEN

@Test("a game written out and read back is the same game")
func pgnRoundTripsAStandardGame() throws {
    var game = try #require(
        Game(startFEN: start, uciMoves: ["e2e4", "e7e5", "g1f3", "b8c6", "f1b5"])
    )
    game.applyReview(
        [.centipawns(31), .centipawns(-12), nil, nil, .mate(in: 5)],
        startEvaluation: .centipawns(20),
        depth: 18
    )

    let written = PGN(game: game, tags: [.init("White", "Felix"), .init("Black", "Stockfish 18")])
    let read = try PGN(parsing: written.text)

    #expect(read.game.startFEN == game.startFEN)
    #expect(read.game.uciMoves == game.uciMoves)
    #expect(read.game.plies.map(\.san) == game.plies.map(\.san))
    #expect(read.game.plies.map(\.evaluation) == game.plies.map(\.evaluation))
    // The Depth and the starting Score are as much a part of a Review as its per-ply Scores:
    // without them nothing read back from a file can be compared with anything.
    #expect(read.game.reviewDepth == 18)
    #expect(read.game.startEvaluation == .centipawns(20))
    #expect(read.game.plies.allSatisfy { $0.importedEvaluation == nil })
    #expect(read.tag("White") == "Felix")
    #expect(read.tag("Black") == "Stockfish 18")
    #expect(read.tag("Result") == "*")
    // The standard start needs no FEN tag.
    #expect(read.tag("FEN") == nil)
    #expect(!written.text.contains("SetUp"))
}

@Test("a game recognised from a picture carries its position in the tags")
func pgnRoundTripsARecognisedPosition() throws {
    // Knight on c6, not c7: from c7 it would be attacking the black king while white is
    // to move, which is not a position that can exist.
    let recognised = "r3k3/8/2N5/8/8/8/8/4K3 w q - 0 1"
    var game = try #require(Game(startFEN: recognised))
    let played = game.apply(uci: "c6e5")
    #expect(played)

    let written = PGN(game: game)
    #expect(written.text.contains("[SetUp \"1\"]"))
    #expect(written.text.contains("[FEN \"\(recognised)\"]"))

    let read = try PGN(parsing: written.text)
    #expect(read.game.startFEN == recognised)
    #expect(read.game.uciMoves == ["c6e5"])
}

@Test("a game that starts with black to move numbers its first move correctly")
func pgnNumbersABlackFirstStart() throws {
    let position = "r3k3/2N5/8/8/8/8/8/4K3 b q - 0 17"
    var game = try #require(Game(startFEN: position))
    let kingMoved = game.apply(uci: "e8d8")
    let knightTook = game.apply(uci: "c7a8")
    #expect(kingMoved)
    #expect(knightTook)

    let text = PGN(game: game).text
    #expect(text.contains("17... Kd8 18. Nxa8"))

    let read = try PGN(parsing: text)
    #expect(read.game.uciMoves == ["e8d8", "c7a8"])
}

@Test("the result reflects how the game actually ended")
func pgnWritesTheResult() throws {
    let mated = try #require(
        Game(startFEN: start, uciMoves: ["f2f3", "e7e5", "g2g4", "d8h4"])
    )
    #expect(PGN(game: mated).text.contains("[Result \"0-1\"]"))
    #expect(PGN(game: mated).text.hasSuffix("Qh4# 0-1\n"))

    let drawn = try #require(Game(startFEN: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"))
    #expect(PGN(game: drawn).text.contains("[Result \"1/2-1/2\"]"))
}

@Test("the noise real PGN files carry is skipped")
func pgnSkipsCommentsVariationsAndAnnotations() throws {
    let text = """
        [Event "Something"]
        [Site "Somewhere"]
        [Date "2026.08.12"]
        [Round "3"]
        [White "A"]
        [Black "B"]
        [Result "1-0"]

        1. e4 $1 {a comment with [%eval 0.25] inside} e5!? (1... c5 2. Nf3 {sicilian}
        (2... d6 3. d4)) 2. Nf3 ; a line comment
        Nc6 3. Bb5 1-0
        """

    let read = try PGN(parsing: text)
    #expect(read.game.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6", "Bb5"])
    // This file carries no Review Depth, so its `[%eval]` came from somebody else's engine at
    // a Depth nobody wrote down. It is kept — as theirs — and the Review's field stays empty,
    // which is what stops it from being ranked or called a mistake (docs/adr/0016).
    #expect(read.game.plies[0].importedEvaluation == .centipawns(25))
    #expect(read.game.plies[0].evaluation == nil)
    #expect(!read.game.isReviewed)
    #expect(read.game.reviewScore(atPly: 1) == nil)
    #expect(read.game.plies[1].importedEvaluation == nil)
    #expect(read.tag("Round") == "3")
    // The Sicilian aside, and the bracket nested inside it, are kept as a 分支 of the move they
    // stand in for, and the mainline above is what is on the board (docs/adr/0043).
    #expect(read.game.plies.count == 5, "and not one ply of the aside is in the line")
    #expect(read.game.variations(atPly: 1).map { $0.map(\.san) } == [["c5", "Nf3"]])
    // The bracket nested inside it opens with Black's move where White is to move, so it will
    // not read — and is dropped whole, without taking the aside or the game with it.
    #expect(read.game.variations(atPly: 1).first?[1].variations.isEmpty == true)
}

@Test("a PGN with no FEN tag starts from the standard position")
func pgnWithoutFenStartsFromScratch() throws {
    let read = try PGN(parsing: "1. d4 d5 *")
    #expect(read.game.startFEN == start)
    #expect(read.game.uciMoves == ["d2d4", "d7d5"])
}

@Test("an impossible move stops the parse instead of being ignored")
func pgnRejectsAnIllegalMove() throws {
    #expect(throws: PGN.ParseError.illegalMove("Qh5", afterPlies: 1)) {
        try PGN(parsing: "1. e4 Qh5 *")
    }
}

@Test("an unusable starting position stops the parse and says why")
func pgnRejectsAnUnusableStartingPosition() throws {
    let text = "[FEN \"8/8/8/8/8/8/8/8 w - - 0 1\"]\n\n*"
    #expect(throws: PGN.ParseError.unusableStartingPosition(.missingKing)) {
        try PGN(parsing: text)
    }
}

@Test("quotes and backslashes in tag values survive the round trip")
func pgnEscapesTagValues() throws {
    let game = try #require(Game(startFEN: start))
    let written = PGN(game: game, tags: [.init("Event", #"a "quoted" \ event"#)])
    let read = try PGN(parsing: written.text)
    #expect(read.tag("Event") == #"a "quoted" \ event"#)
}

@Test("scores survive the trip through PGN's eval comments")
func evaluationTextRoundTrips() {
    let scores: [Score] = [
        .centipawns(0), .centipawns(31), .centipawns(-250), .centipawns(1234),
        .mate(in: 3), .mate(in: -2),
    ]
    for score in scores {
        #expect(Score(pgnText: score.pgnText) == score, "\(score.pgnText)")
    }
}

@Test("setting a tag keeps its place, and nil takes it away")
func setTagKeepsOrder() throws {
    let game = try #require(Game(startFEN: start))
    var pgn = PGN(
        game: game,
        tags: [.init("Event", "Chessmirror"), .init("Name", "第 002 题"), .init("Source", "识别")]
    )

    // A collection is written into the tag it already occupies. Re-adding it at the end would put
    // it after the movetext-adjacent tags and out of PGN's roster order, which is part of the file.
    pgn.setTag("Event", to: "啄木鸟全集")
    #expect(pgn.tags.map(\.name) == ["Event", "Name", "Source"])
    #expect(pgn.tag("Event") == "啄木鸟全集")

    pgn.setTag("Round", to: "7")
    #expect(pgn.tags.last?.name == "Round", "a tag that was not there goes on the end")

    pgn.setTag("Name", to: nil)
    #expect(pgn.tag("Name") == nil, "a name can be taken back off")
    #expect(pgn.tags.map(\.name) == ["Event", "Source", "Round"])

    // And all of it survives being written out and read back, which is the only claim that matters.
    let read = try PGN(parsing: pgn.text)
    #expect(read.tag("Event") == "啄木鸟全集")
    #expect(read.tag("Name") == nil)
}

// ---------------------------------------------------- the lines a Review kept

/// The Line the Review's own search produced, kept because it is the only free copy of it there
/// will ever be: asking again later would cost a Stint (docs/adr/0020, 0021).
@Test("the lines a Review kept survive being written out and read back")
func pgnRoundTripsTheReviewsLines() throws {
    var game = try #require(Game(startFEN: start, uciMoves: ["e2e4", "e7e5", "g1f3"]))
    game.applyReview(
        [
            ReviewedPly(score: .centipawns(31), line: ["e5", "Nf3", "Nc6"]),
            ReviewedPly(score: .centipawns(-12), line: ["Nf3", "Nc6", "Bb5"]),
            ReviewedPly(score: .centipawns(24), line: ["Nc6", "Bb5", "a6"]),
        ],
        startEvaluation: .centipawns(20),
        depth: 18
    )

    let written = PGN(game: game, tags: []).text
    #expect(written.contains("[%line e5 Nf3 Nc6]"), "SAN, in the braces, beside the eval")

    let read = try PGN(parsing: written).game
    #expect(read.plies.map(\.line) == game.plies.map(\.line))
    #expect(read.reviewLine(atPly: 1) == ["e5", "Nf3", "Nc6"])
    #expect(read.reviewLine(atPly: 3) == ["Nc6", "Bb5", "a6"])
    // The eval and the line share one comment, the way every other tool writes these.
    #expect(written.contains("{[%eval 0.31] [%line e5 Nf3 Nc6]}"))
}

@Test("a Ply with no line writes no line token, and a file written before them still opens")
func pgnWithoutLinesStillReads() throws {
    var game = try #require(Game(startFEN: start, uciMoves: ["e2e4", "e7e5"]))
    game.applyReview([.centipawns(31), .centipawns(-12)], startEvaluation: nil, depth: 18)
    let written = PGN(game: game, tags: []).text
    #expect(!written.contains("[%line"))

    // The same shape as a file this app wrote before the field existed: evals, a Review Depth,
    // and nothing else. It opens as a reviewed game whose lines are simply not there.
    let old = """
        [ReviewDepth "18"]

        1. e4 {[%eval +0.31]} e5 {[%eval -0.12]} *
        """
    let read = try PGN(parsing: old).game
    #expect(read.isReviewed)
    #expect(read.plies.map(\.evaluation) == [.centipawns(31), .centipawns(-12)])
    #expect(read.plies.allSatisfy { $0.line.isEmpty })
    #expect(read.reviewLine(atPly: 1).isEmpty)
}

/// Somebody else's engine at a Depth nobody wrote down. The Scores are kept to be shown as
/// theirs; a Line has no such reader, so it goes the way it always went (docs/adr/0016).
@Test("a line in a file with no Review Depth is dropped rather than believed")
func importedLinesAreDropped() throws {
    let theirs = """
        1. e4 {[%eval +0.31] [%line e5 Nf3]} e5 *
        """
    let read = try PGN(parsing: theirs).game
    #expect(read.plies[0].importedEvaluation == .centipawns(31))
    #expect(read.plies[0].evaluation == nil)
    #expect(read.plies[0].line.isEmpty, "not this app's line, and nothing here may compare it")
    #expect(read.reviewLine(atPly: 1).isEmpty)
}

/// A cap, not a suggestion: a line is written into every copy of every file for as long as the
/// file exists, and a Review's line stops being worth much long before it stops being long.
@Test("a line longer than the cap is cut, wherever it comes in")
func linesAreCapped() throws {
    let long = (1...20).map { "N\($0)" }
    var game = try #require(Game(startFEN: start, uciMoves: ["e2e4"]))
    game.applyReview(
        [ReviewedPly(score: .centipawns(31), line: long)], startEvaluation: nil, depth: 18
    )
    #expect(game.plies[0].line.count == Game.Ply.lineLimit)
    #expect(game.plies[0].line.first == "N1")

    let read = try PGN(parsing: """
        [ReviewDepth "18"]

        1. e4 {[%line \(long.joined(separator: " "))]} *
        """).game
    #expect(read.plies[0].line.count == Game.Ply.lineLimit)
}

/// Replaying a line loses everything that is *said about* a move, so every replayer puts it back
/// through one list. A field added and only two of three call sites remembering it is exactly how
/// this goes wrong.
@Test("rewinding a game keeps the lines a Review wrote")
func rewindingKeepsTheLines() throws {
    var game = try #require(Game(startFEN: start, uciMoves: ["e2e4", "e7e5", "g1f3"]))
    game.applyReview(
        [
            ReviewedPly(score: .centipawns(31), line: ["e5"]),
            ReviewedPly(score: .centipawns(-12), line: ["Nf3"]),
            ReviewedPly(score: .centipawns(24), line: ["Nc6"]),
        ],
        startEvaluation: nil,
        depth: 18
    )
    let back = try #require(game.rewound(to: 2))
    #expect(back.plies.map(\.line) == [["e5"], ["Nf3"]])
}

/// A file this app wrote before the player stopped being asked why (docs/adr/0031). The verbs are
/// gone from the code and the files are still on the disk, so `[%int]` and `[%plan]` are now two
/// more tokens this reader does not know — and a token it does not know has always been dropped
/// on the floor rather than refused, which is the whole reason they were written as `[%…]`.
@Test("a file carrying the old declarations opens, and nothing of the game is lost to them")
func theOldDeclarationsAreJustUnknownTokens() throws {
    let pgn = try PGN(parsing: """
        [Event "?"]
        [White "我"]
        [ReviewDepth "18"]

        1. e4 {[%eval +0.31] [%int def e4] [%plan 3]} e5 {[%int ?]}
        2. Nf3 {[%line Nc6 Bc4] [%int hold d5]} 1/2-1/2
        """)
    let game = pgn.game

    #expect(game.plies.map(\.san) == ["e4", "e5", "Nf3"])
    #expect(game.plies[0].evaluation == .centipawns(31))
    #expect(game.plies[2].line == ["Nc6", "Bc4"])
    #expect(pgn.tag("White") == "我")

    // And writing it back out drops them for good: nothing in the app can produce one any more.
    let written = PGN(game: game, tags: pgn.tags).text
    #expect(!written.contains("%int"))
    #expect(!written.contains("%plan"))
    #expect(written.contains("[%eval 0.31]"), "and the tokens it does know come back out")
}

/// Contract: the facts about a game that are not moves — who sat at each side, where it came
/// from, the lines it is judged by — go into the file through one door and come back out through
/// its inverse, on the PGN value alone, with no session in the room. The session names no tag.
@Test("the facts of a game round-trip through their tags")
func theFactsOfAGameRoundTripThroughTheirTags() throws {
    let game = try #require(Game(startFEN: start, uciMoves: ["e2e4", "e7e5"]))

    let on = PGN(
        game: game, seats: [.white: .hand, .black: .engine], origin: .recognised,
        lines: JudgementLines(noSlips: true, record: 7, enqueue: 7),
        carrying: [.init("Date", "2026.09.16")]
    )
    let readOn = try PGN(parsing: on.text)
    #expect(readOn.intercept == 7, "把关 on, stopping the player at the 记录线")
    #expect(readOn.origin == .recognised)
    #expect(readOn.handColours == [.white])
    #expect(readOn.tag("Date") == "2026.09.16", "what the file carried is kept")
    #expect(readOn.tag("Event") == "Chessmirror")

    let off = PGN(
        game: game, seats: [.white: .engine, .black: .hand], origin: .fresh,
        lines: .standard, carrying: [.init("InterceptPreference", "37.0")]
    )
    let readOff = try PGN(parsing: off.text)
    #expect(readOff.intercept == nil)
    #expect(readOff.tag("InterceptPreference") == nil, "把关 has no line of its own to come back on at")
    #expect(readOff.origin == .fresh)
    #expect(readOff.handColours == [.black])
    #expect(readOff.tag("Date") != nil, "a date is written when none was carried")

    // An imported game keeps its two real people, and the tracked side says which is the player.
    var imported = PGN(game: game, tags: [.init("White", "Carlsen"), .init("Black", "Nakamura")])
    imported.track(.black)
    imported.setName("Round 3")
    let written = PGN(
        game: game, seats: [.white: .hand, .black: .engine], origin: .imported,
        lines: .standard, carrying: imported.tags
    )
    let readImported = try PGN(parsing: written.text)
    #expect(readImported.tag("White") == "Carlsen")
    #expect(readImported.tag("Black") == "Nakamura")
    #expect(readImported.trackedSide == .black)
    #expect(readImported.handColours == [.black], "the seats do not say whose moves are whose here")
    #expect(readImported.name == "Round 3")
    #expect(readImported.origin == .imported)
}

// ------------------------------------------------------------------ the date a row shows
//
// Contract: a row shows as much of the date as the file knows and no question marks. PGN's own
// way of saying "nobody recorded this" is `????.??.??`, and it is written into every game saved
// without a date — so the row that printed the tag verbatim printed that.

@Test func aDateNobodyRecordedIsNotShown() {
    #expect(PGN.playedOn("????.??.??") == nil)
    #expect(PGN.playedOn(nil) == nil)
    #expect(PGN.playedOn("") == nil)
}

@Test func aKnownDateIsShownWhole() {
    #expect(PGN.playedOn("2026.09.20") == "2026.09.20")
}

@Test func aHalfKnownDateShowsOnlyWhatIsKnown() {
    #expect(PGN.playedOn("2026.09.??") == "2026.09")
    #expect(PGN.playedOn("2026.??.??") == "2026")
    #expect(PGN.playedOn("????.09.20") == nil, "a month with no year is not a date to show")
}

/// The row itself: a game saved with no date says what it is and how long it is, and says
/// nothing where the date would be.
@MainActor
@Test func aRowWithNoDateShowsNoQuestionMarks() throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
    let undated = PGN(game: game, tags: [PGN.Tag("Date", "????.??.??")])
    let entry = GameLibrary.Entry(url: URL(filePath: "/games/monday.pgn"), pgn: undated, modified: Date())

    #expect(!entry.detail.contains("?"))
    #expect(entry.detail.contains(localized("library.entry.moves", plural: 1)))

    let dated = PGN(game: game, tags: [PGN.Tag("Date", "2026.09.20")])
    let known = GameLibrary.Entry(url: URL(filePath: "/games/monday.pgn"), pgn: dated, modified: Date())
    #expect(known.detail.contains("2026.09.20"))
}

/// A 练习 row draws the 错题 it was asked about, not where the drill ended up: the 错题 is the
/// position, and a drill answered right has walked two moves away from it (docs/adr/0047).
@MainActor
@Test func aPractisedRowDrawsTheQuestionRatherThanTheAnswer() throws {
    let question = "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 0 1"
    let answered = try #require(Game(startFEN: question, uciMoves: ["b8c6", "f1b5"]))
    let drill = PGN(
        game: answered, seats: [.black: .hand, .white: .engine], origin: .practised,
        lines: JudgementLines(noSlips: true)
    )
    let row = GameLibrary.Entry(url: URL(filePath: "/games/drill.pgn"), pgn: drill, modified: Date())
    #expect(row.shownFEN == question, "the board on the row is the question that was asked")
    #expect(row.detail.contains(GameOrigin.practised.label))

    let played = try #require(Game(startFEN: question, uciMoves: ["b8c6", "f1b5"]))
    let ordinary = PGN(
        game: played, seats: [.black: .hand, .white: .engine], origin: .fresh,
        lines: JudgementLines(noSlips: true)
    )
    let other = GameLibrary.Entry(url: URL(filePath: "/games/monday.pgn"), pgn: ordinary, modified: Date())
    #expect(other.shownFEN == played.state.fen, "an ordinary game still draws where it stands")
}

/// The file a wrong answer leaves has no move in it (docs/adr/0047). The row says what was
/// played and taken back, rather than counting to zero.
@MainActor
@Test func aPractisedRowWithNoMoveSaysWhatWasTried() throws {
    let question = "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 0 1"
    var refused = try #require(Game(startFEN: question))
    refused.recordTried(Game.Ply.Tried(san: "Qh4", drop: 12.4, depth: 20), atPly: 0)
    let drill = PGN(
        game: refused, seats: [.black: .hand, .white: .engine], origin: .practised,
        lines: JudgementLines(noSlips: true)
    )
    let row = GameLibrary.Entry(url: URL(filePath: "/games/drill.pgn"), pgn: drill, modified: Date())

    #expect(row.detail.contains("Qh4"))
    #expect(row.detail.contains(GameOrigin.practised.label))
    #expect(!row.detail.contains(localized("library.entry.moves", plural: 0)), "and does not count to zero")
    #expect(!row.detail.contains(localized("library.entry.unfinished")))
    #expect(row.shownFEN == question)
}

/// Contract: what this app writes, this app can cut apart and read back.
///
/// Where one game ends used to be decided in the importer and what a tag is called in four
/// places; both are here now, and this holds them to each other — a file with a bracket inside a
/// tag value and arrows inside a comment, which is what the two lexers used to disagree about.
@MainActor
@Test func filesThisAppWritesSurviveBeingCutApart() throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
    // Imported, because that is the game whose roster names a real person — the app writes its
    // own two names for a game it seated itself.
    let first = PGN(
        game: game, seats: [.white: .hand, .black: .engine], origin: .imported,
        lines: JudgementLines(noSlips: true),
        carrying: [
            PGN.Tag(PGN.Tags.white, "De La Bourdonnais (1834)"),
            PGN.Tag(PGN.Tags.name, "带括号的一局"),
        ]
    )
    let second = PGN(
        game: game, seats: [.black: .hand, .white: .engine], origin: .practised,
        lines: JudgementLines(noSlips: true),
        carrying: [PGN.Tag(PGN.Tags.chapterName, "第二章 {不是注释}")]
    )

    let blocks = PGN.split(first.text + "\n\n" + second.text)
    #expect(blocks.count == 2, "a bracket in a tag value does not start a game")

    let readBack = try blocks.map { try PGN(parsing: $0) }
    #expect(readBack[0].playerName(.white) == "De La Bourdonnais (1834)")
    #expect(readBack[0].name == "带括号的一局")
    #expect(readBack[0].origin == .imported)
    #expect(readBack[1].origin == .practised)
    #expect(readBack[1].tag(PGN.Tags.chapterName) == "第二章 {不是注释}")
    #expect(readBack[0].game.uciMoves == game.uciMoves)
    #expect(readBack[1].intercept != nil, "把关 was on, and the file still says so")
}

/// The roster is read through one door, so nobody picks between White and Black by hand.
@Test func theRosterIsReadByColour() throws {
    let game = try #require(Game(startFEN: PGN.standardStartFEN))
    let pgn = PGN(
        game: game,
        tags: [PGN.Tag(PGN.Tags.white, "手动"), PGN.Tag(PGN.Tags.black, "Stockfish 18")]
    )
    #expect(pgn.playerName(.white) == "手动")
    #expect(pgn.playerName(.black) == "Stockfish 18")
    #expect(pgn.handColours == [.white])
}
