import ChessfenKit
import Testing

private let start = PGN.standardStartFEN

/// Sixteen plies of the Italian, which gives every test a real game to hang declarations on.
private let italian = [
    "e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6",
    "d2d3", "d7d6", "e1g1", "e8g8", "b1d2", "c8e6", "f1e1", "d8d7",
]

private func played(_ moves: [String] = italian) throws -> Game {
    try #require(Game(startFEN: start, uciMoves: moves))
}

private func square(_ name: String) throws -> Square {
    try #require(Square(name))
}

/// Declares an Intent and checks it was accepted. A function because `#expect` cannot hold a
/// mutating call: the value inside the macro's closure is immutable.
private func declare(_ intent: Intent, atPly ply: Int, in game: inout Game) {
    let recorded = game.setIntent(intent, atPly: ply)
    #expect(recorded, "ply \(ply) should have accepted an Intent")
}

@Test("every verb goes out and comes back as itself, on every square of the board")
func everyVerbOnEverySquare() throws {
    for verb in Intent.Verb.allCases {
        for index in 0..<64 {
            let target = Square(file: index % 8, rank: index / 8)
            let intent = Intent.claim(verb, target)
            let read = try #require(Intent(pgnText: intent.pgnText))
            #expect(read == intent, "\(intent.pgnText) did not survive the wire")
        }
    }
    // Which is 7 × 64 claims and one 说不清 — the whole vocabulary, and no way to say anything
    // else, which is the point of it being a vocabulary.
    #expect(Intent.Verb.allCases.count == 7)
    #expect(Intent(pgnText: "?") == .unclear)
}

@Test("an Intent is written into the file and read back off it")
func intentRoundTripsThroughPGN() throws {
    var game = try played()
    declare(.claim(.defend, try square("f7")), atPly: 3, in: &game)

    let text = PGN(game: game).text
    #expect(text.contains("{[%int def f7]}"))

    let reread = try PGN(parsing: text).game
    #expect(reread.intent(atPly: 3) == .claim(.defend, try square("f7")))
    #expect(reread.plies.map(\.san) == game.plies.map(\.san))
    // And a second trip changes nothing, which is what "unchanged" has to mean for a file.
    #expect(PGN(game: reread).text == text)
}

@Test("a game carries Intents on the moves that have them and nothing on the moves that do not")
func someMovesAndNotOthers() throws {
    var game = try played()
    // Eight declarations over sixteen moves, all on White's: every verb at least once, and
    // targets covering all eight files and all eight ranks.
    let targets = ["a1", "b2", "c3", "d4", "e5", "f6", "g7", "h8"]
    let verbs = Intent.Verb.allCases
    let declared = targets.indices.map { index in
        (ply: index * 2 + 1, intent: Intent.claim(verbs[index % verbs.count], Square(targets[index])!))
    }
    for entry in declared {
        declare(entry.intent, atPly: entry.ply, in: &game)
    }
    // And the eighth button on the last move, so all eight are exercised in one file.
    declare(.unclear, atPly: 16, in: &game)

    let reread = try PGN(parsing: PGN(game: game).text).game
    for entry in declared {
        #expect(reread.intent(atPly: entry.ply) == entry.intent)
    }
    #expect(reread.intent(atPly: 16) == .unclear)
    // Black was never asked about a single move, and the file says so by having nothing there.
    for ply in stride(from: 2, through: 14, by: 2) {
        #expect(reread.intent(atPly: ply) == nil, "ply \(ply) was never asked about")
    }
    #expect(reread.plies.filter { $0.intent != nil }.count == 9)
    #expect(Set(reread.plies.compactMap { $0.intent?.verb }) == Set(verbs))

    // Every file and every rank appeared as a target, so nothing about the notation is
    // accidentally right for the middle of the board only.
    let squares = reread.plies.compactMap { $0.intent?.target }
    #expect(Set(squares.map(\.file)) == Set(0..<8))
    #expect(Set(squares.map(\.rank)) == Set(0..<8))
}

@Test("说不清 is a declaration, and not the same thing as never having been asked")
func unclearIsNotAbsence() throws {
    var game = try played()
    declare(.unclear, atPly: 1, in: &game)

    let text = PGN(game: game).text
    #expect(text.contains("{[%int ?]}"))

    let reread = try PGN(parsing: text).game
    #expect(reread.intent(atPly: 1) == .unclear)
    #expect(reread.intent(atPly: 2) == nil)
    #expect(reread.intent(atPly: 1) != nil, "a recorded shrug is a record")
    // The distinction the diagnosis is made of: a Game of shrugs and a Game nobody was asked
    // about are different Games.
    #expect(Intent.unclear.verb == nil)
    #expect(Intent.unclear.target == nil)
}

@Test("an Intent and a Score share one comment without either losing the other")
func intentSitsBesideAnEvaluation() throws {
    var game = try played(["e2e4", "e7e5", "g1f3"])
    game.applyReview(
        [.centipawns(30), .centipawns(25), .centipawns(35)],
        startEvaluation: .centipawns(20),
        depth: 18
    )
    declare(.claim(.hold, try square("d5")), atPly: 3, in: &game)

    let text = PGN(game: game).text
    #expect(text.contains("{[%eval 0.35] [%int hold d5]}"))

    let reread = try PGN(parsing: text).game
    #expect(reread.reviewScore(atPly: 3) == .centipawns(35))
    #expect(reread.intent(atPly: 3) == .claim(.hold, try square("d5")))
}

@Test("an Intent on the first move of a Variation comes back with the Variation")
func intentInsideAVariation() throws {
    let text = """
        [Event "chessfen"]
        [Result "*"]

        1. e4 {[%int hold d5]} e5 2. Nf3 {[%int attack e5]} (2. Bc4 {[%int def f7]} Nf6
        {[%int ?]}) Nc6 *
        """
    let read = try PGN(parsing: text)

    let variation = read.game.variations(atPly: 2)
    #expect(variation.count == 1)
    #expect(variation.first?.first?.san == "Bc4")
    #expect(variation.first?.first?.intent == .claim(.defend, try square("f7")))
    #expect(variation.first?.last?.intent == .unclear)
    // The mainline's own declarations are untouched by the bracket beside them.
    #expect(read.game.intent(atPly: 1) == .claim(.hold, try square("d5")))
    #expect(read.game.intent(atPly: 3) == .claim(.attack, try square("e5")))

    // Out and back in again, brackets and all.
    let again = try PGN(parsing: read.text)
    #expect(again.game.variations(atPly: 2).first?.first?.intent == .claim(.defend, try square("f7")))
    #expect(again.game.variations(atPly: 2).first?.last?.intent == .unclear)
    #expect(again.text == read.text)
}

@Test("a promoted Variation keeps the Intents that were declared inside it")
func promotingKeepsIntents() throws {
    let read = try PGN(
        parsing: """
            [Event "chessfen"]
            [Result "*"]

            1. e4 e5 2. Nf3 (2. Bc4 {[%int def f7]}) Nc6 *
            """
    )
    var game = read.game
    let promoted = game.promoteVariation(0, atPly: 2)
    #expect(promoted)
    #expect(game.plies[2].san == "Bc4")
    #expect(game.intent(atPly: 3) == .claim(.defend, try square("f7")))
}

@Test("a token this app does not understand is dropped, and the game still opens")
func malformedTokensAreIgnored() throws {
    let text = """
        [Event "Somebody else's export"]
        [Result "*"]

        1. e4 {[%int 将 e5]} e5 {[%int take]} 2. Nf3 {[%int take zz]} Nc6 {[%int]}
        3. Bc4 {[%clk 0:04:37] [%int def f7]} Bc5 {a comment in words, with [%int nonsense here]} *
        """
    let read = try PGN(parsing: text)

    // The game itself is fine, which is the whole requirement: a file this app did not write
    // must open.
    #expect(read.game.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6", "Bc4", "Bc5"])
    // A verb outside the vocabulary, a verb with no target, a target that is not a square, and
    // an empty token: all nothing.
    for ply in [1, 2, 3, 4, 6] {
        #expect(read.game.intent(atPly: ply) == nil, "ply \(ply) should carry no Intent")
    }
    // And the one well-formed declaration in that mess is still read, even sharing its comment
    // with a token from another tool.
    #expect(read.game.intent(atPly: 5) == .claim(.defend, try square("f7")))
}

@Test("a file carrying Intents is an ordinary PGN with comments in it")
func intentsAreJustComments() throws {
    var game = try played(["e2e4", "e7e5"])
    declare(.claim(.take, try square("e5")), atPly: 1, in: &game)
    declare(.unclear, atPly: 2, in: &game)
    let text = PGN(game: game).text

    // Every `%int` in the file is inside braces — which is what makes it a comment to every
    // other tool, rather than something they have to know about.
    for line in text.split(separator: "\n") {
        var depth = 0
        for (offset, character) in line.enumerated() {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if character == "%" {
                let isIntent = line.dropFirst(offset).hasPrefix("%int")
                #expect(!isIntent || depth > 0, "an [%int] escaped its braces: \(line)")
            }
        }
        #expect(depth == 0, "a comment was left open: \(line)")
    }
    // And a reader that throws comments away is left with a legal game.
    let stripped = text.split(separator: "\n").map { line -> String in
        var kept = ""
        var depth = 0
        for character in line {
            if character == "{" { depth += 1; continue }
            if character == "}" { depth -= 1; continue }
            if depth == 0 { kept.append(character) }
        }
        return kept
    }.joined(separator: "\n")
    #expect(!stripped.contains("%int"))
    #expect(try PGN(parsing: stripped).game.plies.map(\.san) == ["e4", "e5"])
}
