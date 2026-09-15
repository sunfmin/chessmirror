import Foundation

/// The stored form of a Game, which is also its exported form and its imported form —
/// there is deliberately only one (docs/adr/0010). `[FEN]` carries the recognised
/// starting Position and `{[%eval …]}` / `{[%line …]}` carry a Review's scores and the lines
/// they came out of, all being conventions
/// PGN already has.
public struct PGN: Hashable, Sendable {
    /// Tag pairs in the order they will be written. PGN wants the seven-tag roster first.
    public var tags: [Tag]
    public var game: Game

    public struct Tag: Hashable, Sendable {
        public let name: String
        public var value: String

        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    public static let standardStartFEN =
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    private static let rosterOrder = ["Event", "Site", "Date", "Round", "White", "Black", "Result"]

    public init(game: Game, tags: [Tag] = []) {
        self.game = game
        self.tags = tags
    }

    public func tag(_ name: String) -> String? {
        tags.first { $0.name == name }?.value
    }

    /// The colours the player moved themselves, read off the roster.
    ///
    /// What the 错题本 is counted over: a game where the engine had Black is a game where Black's
    /// mistakes belong to Stockfish (docs/adr/0028). `Controller.hand.playerName` is written into
    /// the file rather than localized for exactly this — a game saved in one language has to
    /// still be readable in another.
    ///
    /// An imported game names two real people and so has no hand here. Which of those two is the
    /// person holding the phone is a question the import knows the answer to and this does not,
    /// and answering it by guessing would fill the book with somebody else's blunders.
    public var handColours: Set<PieceColour> {
        if let tracked = tag("TrackedSide") {
            switch tracked {
            case "white": return [.white]
            case "black": return [.black]
            default: return []
            }
        }
        var found: Set<PieceColour> = []
        if tag("White") == Controller.hand.playerName { found.insert(.white) }
        if tag("Black") == Controller.hand.playerName { found.insert(.black) }
        return found
    }

    /// Sets a tag, adds it if it was not there, and removes it for nil.
    ///
    /// In place where it already sits, because the order tags are written in is part of the file:
    /// the roster comes first and re-adding a tag at the end would move it out of its place.
    public mutating func setTag(_ name: String, to value: String?) {
        guard let value else {
            tags.removeAll { $0.name == name }
            return
        }
        if let index = tags.firstIndex(where: { $0.name == name }) {
            tags[index].value = value
        } else {
            tags.append(Tag(name, value))
        }
    }

    // ------------------------------------------------------------------ writing

    public var text: String {
        var lines: [String] = []

        var written = Set<String>()
        var roster = tags
        for name in Self.rosterOrder {
            let value = roster.first { $0.name == name }?.value ?? Self.rosterDefault(name, game)
            lines.append("[\(name) \"\(Self.escaped(value))\"]")
            written.insert(name)
        }
        if game.startFEN != Self.standardStartFEN {
            lines.append("[SetUp \"1\"]")
            lines.append("[FEN \"\(game.startFEN)\"]")
            written.formUnion(["SetUp", "FEN"])
        }
        // Derived from the Game, never carried in `tags`, so there is one home for the fact
        // (docs/adr/0016). Its presence is also what tells a reader whose engine the
        // `[%eval]` comments below came from: with the tag they are this app's Review, at
        // this Depth; without it they are somebody else's, at a Depth nobody wrote down.
        if let depth = game.reviewDepth {
            lines.append("[ReviewDepth \"\(depth)\"]")
            written.insert("ReviewDepth")
        }
        roster.removeAll { written.contains($0.name) }
        for tag in roster {
            lines.append("[\(tag.name) \"\(Self.escaped(tag.value))\"]")
        }

        lines.append("")
        lines.append(contentsOf: Self.wrap(movetextTokens, at: 80))
        return lines.joined(separator: "\n") + "\n"
    }

    private var movetextTokens: [String] {
        // The starting position's Score goes before the first move, which is where PGN puts a
        // comment about the position a game begins in. Without it the first move's quality
        // cannot be recomputed from the file, because there is nothing to compare it against.
        let baseline = game.startEvaluation.map { ["{[%eval \($0.pgnText)]}"] } ?? []
        // A Game recognised from a picture usually starts mid-game, and may start with black
        // to move — in which case PGN wants "12... Nf6" before the first white move.
        return baseline
            + Self.tokens(
                for: game.plies,
                from: game.startingFullmoveNumber,
                sideToMove: game.startingSideToMove
            ) + [game.resultToken]
    }

    /// One line of moves, with its Variations in brackets after the moves they replace —
    /// which is where PGN has always put them, and why a game written here opens in anything
    /// else with its branches intact.
    private static func tokens(
        for plies: [Game.Ply], from moveNumber: Int, sideToMove: PieceColour
    ) -> [String] {
        var written: [String] = []
        var moveNumber = moveNumber
        var sideToMove = sideToMove

        for (index, ply) in plies.enumerated() {
            if sideToMove == .white {
                written.append("\(moveNumber).")
            } else if index == 0 {
                written.append("\(moveNumber)...")
            }
            written.append(ply.san)
            // One or the other, never both: which slot a file's Scores landed in was decided
            // once by whether it carried a Review Depth, so writing either back out under
            // the same tag is what makes the round trip exact.
            var comment: [String] = []
            if let judgement = ply.judgement {
                comment.append("[%judged \(judgement.depth) \(judgement.drop) \(judgement.score.pgnText)]")
            }
            if let evaluation = ply.evaluation ?? ply.importedEvaluation {
                comment.append("[%eval \(evaluation.pgnText)]")
            }
            // The Line the same search produced, in the same braced convention. SAN rather than
            // UCI: it is read back by replaying it, so either would do, and only one of the two
            // is a thing a person opening the file in anything else can read (docs/adr/0021).
            if !ply.line.isEmpty {
                comment.append("[%line \(ply.line.joined(separator: " "))]")
            }
            // What 耕棋 took back here, and how many hints were open when the move that stands
            // was finally played (docs/adr/0027). One `[%tried]` per refused move, in the order
            // they were played, because a reader that only knows `[%eval]` skips them the same
            // way it already skips everything else in a comment.
            for attempt in ply.tried {
                var body = "\(attempt.san) \(Self.percent(attempt.drop))"
                if attempt.notFound { body += " notfound" }
                // The 应招 follows a bar (docs/adr/0034). A bar and not a word, because what
                // comes after it is a line of moves and a token of its own would need a second
                // delimiter inside a comment that already ends at the first `]`.
                if !attempt.line.isEmpty {
                    body += " | " + attempt.line.joined(separator: " ")
                }
                comment.append("[%tried \(body)]")
            }
            if ply.hints > 0 {
                comment.append("[%hint \(ply.hints)]")
            }
            if !comment.isEmpty {
                written.append("{" + comment.joined(separator: " ") + "}")
            }
            if sideToMove == .black { moveNumber += 1 }
            sideToMove = sideToMove.opposite
        }
        return written
    }

    /// A drop, as the file says it: `-23%`, the sign saying it is what the move *cost*.
    static func percent(_ drop: Double) -> String { "-\(drop)%" }

    private static func rosterDefault(_ name: String, _ game: Game) -> String {
        switch name {
        case "Event": "chessfen"
        case "Site": "chessfen"
        case "Date": "????.??.??"
        case "Round": "-"
        case "White": "?"
        case "Black": "?"
        case "Result": game.resultToken
        default: "?"
        }
    }

    private static func escaped(_ value: String) -> String {
        String(value.flatMap { character -> [Character] in
            character == "\"" || character == "\\" ? ["\\", character] : [character]
        })
    }

    private static func wrap(_ tokens: [String], at width: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for token in tokens {
            if line.isEmpty {
                line = token
            } else if line.count + 1 + token.count <= width {
                line += " " + token
            } else {
                lines.append(line)
                line = token
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    /// Today in PGN's `YYYY.MM.DD`.
    public static func dateTag(_ date: Date = Date(), calendar: Calendar = .current) -> Tag {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let text = String(
            format: "%04d.%02d.%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
        return Tag("Date", text)
    }

    // ------------------------------------------------------------------ reading

    public enum ParseError: Error, Hashable, Sendable {
        case unusableStartingPosition(FENIssue?)
        /// A SAN token that is not a legal move in the position it was reached in.
        case illegalMove(String, afterPlies: Int)
    }

    public init(parsing text: String) throws {
        var scanner = Scanner(text)
        let tags = scanner.readTags()

        let startFEN = tags.first { $0.name == "FEN" }?.value ?? Self.standardStartFEN
        guard var game = Game(startFEN: startFEN) else {
            throw ParseError.unusableStartingPosition(Rules.validate(fen: startFEN).issue)
        }

        // Provenance, decided once for the whole file before a single move is read: with a
        // Review Depth the `[%eval]` comments are this app's own uniform pass and may be
        // compared with each other; without one they came from somewhere else at a Depth
        // nobody recorded, and are kept only to be shown as somebody else's number
        // (docs/adr/0016). A file this app wrote before the tag existed therefore reads as
        // unreviewed, which is the honest answer rather than the convenient one.
        let reviewDepth = (tags.first { $0.name == "ReviewDepth" }?.value).flatMap { Int($0) }
        let isReviewed = reviewDepth != nil
        game.setReviewDepth(reviewDepth)
        // Brackets are skipped whole. PGN has written alternatives in parentheses since 1994 and
        // files in the wild are full of them — this app does not write one any more (docs/adr/0028)
        // and has nowhere to put one it reads, so the mainline is read out and the asides are
        // stepped over. Counted rather than flagged, because they nest.
        var insideVariation = 0

        // Evaluations arrive in comments *after* the move they belong to.
        for token in scanner.readMovetext() {
            if insideVariation > 0 {
                switch token {
                case .variationStart: insideVariation += 1
                case .variationEnd: insideVariation -= 1
                default: break
                }
                continue
            }
            switch token {
            case .move(let san):
                guard game.apply(san: san) else {
                    throw ParseError.illegalMove(san, afterPlies: game.plies.count)
                }
            case .evaluation(let score):
                // A ply index of -1 is a comment standing before the first move, which is
                // the starting position's Score.
                game.setEvaluation(score, atPly: game.plies.count - 1, reviewed: isReviewed)
            case .tried(let attempt):
                game.addTried(attempt, atPly: game.plies.count - 1)
            case .hint(let rungs):
                game.setHints(rungs, atPly: game.plies.count - 1)
            case .judgement(let judgement):
                game.setJudgement(judgement, atPly: game.plies.count - 1)
            case .line(let line):
                // A Line standing before the first move belongs to the starting position and has
                // nowhere to go: what reads it is a move's own consequences, and there is no move.
                game.setLine(line, atPly: game.plies.count - 1, reviewed: isReviewed)
            case .variationStart:
                insideVariation = 1
            case .variationEnd:
                // A stray closing bracket. Nothing opened, so nothing closes: files in the wild
                // carry worse than this, and losing a game to save a footnote is the wrong trade.
                continue
            }
        }

        // ReviewDepth does not stay in `tags`: it lives on the Game and `text` writes it back
        // from there, so the fact has one home and cannot be written twice or drift.
        self.tags = tags.filter { $0.name != "ReviewDepth" }
        self.game = game
    }
}

/// A hand-rolled scanner: PGN's movetext is a handful of token shapes, and pulling in a
/// parser generator to skip nested variations would cost more than it explains.
private struct Scanner {
    private let characters: [Character]
    private var index = 0

    init(_ text: String) { characters = Array(text) }

    enum MovetextToken {
        case move(String)
        case evaluation(Score)
        case line([String])
        case tried(Game.Ply.Tried)
        case hint(Int)
        case judgement(Game.Ply.Judgement)
        case variationStart
        case variationEnd
    }

    mutating func readTags() -> [PGN.Tag] {
        var tags: [PGN.Tag] = []
        while true {
            skipWhitespace()
            guard peek() == "[" else { break }
            advance()
            let name = read(while: { !$0.isWhitespace && $0 != "\"" })
            skipWhitespace()
            guard peek() == "\"" else { skipPast("]"); continue }
            advance()
            var value = ""
            while let character = peek(), character != "\"" {
                if character == "\\", let next = peek(offset: 1), next == "\"" || next == "\\" {
                    advance()
                    value.append(next)
                } else {
                    value.append(character)
                }
                advance()
            }
            advance()  // closing quote
            skipPast("]")
            if !name.isEmpty { tags.append(PGN.Tag(name, value)) }
        }
        return tags
    }

    mutating func readMovetext() -> [MovetextToken] {
        var tokens: [MovetextToken] = []
        while let character = peek() {
            switch character {
            case _ where character.isWhitespace:
                advance()
            case "{":
                advance()
                let comment = read(while: { $0 != "}" })
                advance()
                // Everything else in a comment is dropped, which is what it was before there was
                // anything to keep: an unknown `[%…]`, a malformed one, or somebody's prose all
                // read the same way to a file that must still open.
                if let score = Self.evaluation(in: comment) { tokens.append(.evaluation(score)) }
                if let line = Self.line(in: comment) { tokens.append(.line(line)) }
                tokens.append(contentsOf: Self.tried(in: comment).map { .tried($0) })
                if let hints = Self.hint(in: comment) { tokens.append(.hint(hints)) }
                if let judgement = Self.judgement(in: comment) { tokens.append(.judgement(judgement)) }
            case ";":
                _ = read(while: { !$0.isNewline })
            case "(":
                advance()
                tokens.append(.variationStart)
            case ")":
                advance()
                tokens.append(.variationEnd)
            case "$":
                advance()
                _ = read(while: { $0.isNumber })
            case _ where character.isNumber:
                // A move number, or a result token like "1-0" / "1/2-1/2".
                let word = read(while: { !$0.isWhitespace })
                if word.contains("-") || word.contains("/") { return tokens }
            case "*":
                return tokens
            default:
                let word = read(while: {
                    !$0.isWhitespace && $0 != "{" && $0 != "(" && $0 != ")"
                })
                if !word.isEmpty { tokens.append(.move(word)) }
            }
        }
        return tokens
    }

    private static func evaluation(in comment: String) -> Score? {
        Self.body(of: "eval", in: comment).flatMap { Score(pgnText: $0) }
    }

    /// Every `[%tried San -23%]` in one comment, in the order they were written. All of them
    /// rather than the first, which is the one way this differs from every other token here: a
    /// position 耕棋 stopped somebody at three times has three of them. The 应招 rides after a bar
    /// in the same token, so the two can never be read apart from each other (docs/adr/0034).
    private static func tried(in comment: String) -> [Game.Ply.Tried] {
        bodies(of: "tried", in: comment).compactMap { body in
            let halves = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let parts = halves[0].split(separator: " ")
            guard let san = parts.first,
                parts.count == 2 || (parts.count == 3 && parts[2] == "notfound"),
                parts[1].hasPrefix("-"), parts[1].hasSuffix("%"),
                let drop = Double(parts[1].dropFirst().dropLast()),
                drop.isFinite, (0...100).contains(drop)
            else { return nil }
            let line = halves.count > 1 ? halves[1].split(separator: " ").map(String.init) : []
            return Game.Ply.Tried(
                san: String(san), drop: drop, notFound: parts.count == 3, line: line
            )
        }
    }

    private static func hint(in comment: String) -> Int? {
        body(of: "hint", in: comment).flatMap { Int($0) }
    }

    private static func judgement(in comment: String) -> Game.Ply.Judgement? {
        guard let body = body(of: "judged", in: comment) else { return nil }
        let parts = body.split(separator: " ")
        guard parts.count == 3, let depth = Int(parts[0]), depth > 0,
              let drop = Double(parts[1]), drop.isFinite, drop >= 0,
              let score = Score(pgnText: String(parts[2])) else { return nil }
        return .init(drop: drop, score: score, depth: depth)
    }

    private static func line(in comment: String) -> [String]? {
        Self.body(of: "line", in: comment).map { $0.split(separator: " ").map(String.init) }
    }

    /// Every `[%name …]` in one comment, in order. `body` is this asking for the first one.
    private static func bodies(of name: String, in comment: String) -> [String] {
        var found: [String] = []
        var rest = Substring(comment)
        while let start = rest.range(of: "[%\(name) ") {
            let after = rest[start.upperBound...]
            guard let end = after.firstIndex(of: "]") else { break }
            let body = String(after[..<end]).trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { found.append(body) }
            rest = after[after.index(after: end)...]
        }
        return found
    }

    /// What is between `[%name ` and the next `]`, trimmed. Nil when the token is not there at
    /// all, or is there with nothing in it.
    private static func body(of name: String, in comment: String) -> String? {
        guard let start = comment.range(of: "[%\(name) ") else { return nil }
        let rest = comment[start.upperBound...]
        guard let end = rest.firstIndex(of: "]") else { return nil }
        let body = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    private func peek(offset: Int = 0) -> Character? {
        let wanted = index + offset
        return wanted < characters.count ? characters[wanted] : nil
    }

    private mutating func advance() { index += 1 }

    private mutating func skipWhitespace() {
        while let character = peek(), character.isWhitespace { advance() }
    }

    private mutating func skipPast(_ target: Character) {
        while let character = peek() {
            advance()
            if character == target { return }
        }
    }

    private mutating func read(while predicate: (Character) -> Bool) -> String {
        var text = ""
        while let character = peek(), predicate(character) {
            text.append(character)
            advance()
        }
        return text
    }
}
