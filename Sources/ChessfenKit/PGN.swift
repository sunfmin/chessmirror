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
            if let evaluation = ply.evaluation ?? ply.importedEvaluation {
                comment.append("[%eval \(evaluation.pgnText)]")
            }
            // The Line the same search produced, in the same braced convention. SAN rather than
            // UCI: it is read back by replaying it, so either would do, and only one of the two
            // is a thing a person opening the file in anything else can read (docs/adr/0021).
            if !ply.line.isEmpty {
                comment.append("[%line \(ply.line.joined(separator: " "))]")
            }
            // The player's own words about the move, in the same braced convention as the
            // engine's (docs/adr/0018). One comment carrying both rather than two, which is how
            // every other tool that writes these writes them.
            if let intent = ply.intent {
                comment.append("[%int \(intent.pgnText)]")
            }
            // How far that claim reaches, when it reaches past this move. Written beside the Intent
            // rather than inside it so a reader that knows nothing about plans still gets the verb
            // and the target, which is the whole reason these live in `[%…]` tokens (docs/adr/0017).
            if let span = ply.intentSpan {
                comment.append("[%plan \(span)]")
            }
            if !comment.isEmpty {
                written.append("{" + comment.joined(separator: " ") + "}")
            }
            for variation in ply.variations {
                // A Variation stands in for this move, so it is numbered as this move.
                var inner = tokens(for: variation, from: moveNumber, sideToMove: sideToMove)
                guard !inner.isEmpty else { continue }
                inner[0] = "(" + inner[0]
                inner[inner.count - 1] += ")"
                written.append(contentsOf: inner)
            }
            if sideToMove == .black { moveNumber += 1 }
            sideToMove = sideToMove.opposite
        }
        return written
    }

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

        // One frame per open bracket. Moves always go to the innermost one, which is what
        // makes a Variation inside a Variation work without any special handling: it is the
        // same rule applied one level further in. A frame goes `dead` when something in it
        // will not read, and a dead frame is dropped whole at its closing bracket: a
        // Variation is an aside, and files in the wild carry asides that are not moves at
        // all — refusing to open a game over one would lose the game to save the footnote.
        var frames: [(game: Game, branchPoint: Int, dead: Bool)] = [(game, -1, false)]

        // Evaluations arrive in comments *after* the move they belong to.
        for token in scanner.readMovetext() {
            let last = frames.count - 1
            switch token {
            case .move(let san):
                guard !frames[last].dead else { continue }
                guard frames[last].game.apply(san: san) else {
                    guard last > 0 else {
                        throw ParseError.illegalMove(
                            san, afterPlies: frames[last].game.plies.count
                        )
                    }
                    frames[last].dead = true
                    continue
                }
            case .evaluation(let score):
                guard !frames[last].dead else { continue }
                // A ply index of -1 is a comment standing before the first move, which is
                // the starting position's Score.
                frames[last].game.setEvaluation(
                    score, atPly: frames[last].game.plies.count - 1, reviewed: isReviewed
                )
            case .line(let line):
                guard !frames[last].dead else { continue }
                // A Line standing before the first move belongs to the starting position and has
                // nowhere to go: what reads it is a move's own consequences, and there is no move.
                frames[last].game.setLine(
                    line, atPly: frames[last].game.plies.count - 1, reviewed: isReviewed
                )
            case .intent(let intent):
                guard !frames[last].dead else { continue }
                // An Intent belongs to a move, so one standing before the first move has
                // nothing to belong to — `setIntent` says so by refusing ply 0.
                frames[last].game.setIntent(intent, atPly: frames[last].game.plies.count)
            case .plan(let span):
                guard !frames[last].dead else { continue }
                frames[last].game.setIntentSpan(span, atPly: frames[last].game.plies.count)
            case .variationStart:
                // A Variation is an alternative to the move just read, so it starts from the
                // position that move was played in.
                let branchPoint = frames[last].game.plies.count - 1
                guard !frames[last].dead, branchPoint >= 0,
                      let rewound = frames[last].game.rewound(to: branchPoint)
                else {
                    // Brackets before any move have nothing to be an alternative to. Read
                    // them into a frame that gets thrown away rather than refusing the file.
                    frames.append((frames[last].game, -1, true))
                    continue
                }
                frames.append((rewound, branchPoint, false))
            case .variationEnd:
                guard frames.count > 1 else { continue }
                let frame = frames.removeLast()
                guard !frame.dead, frame.branchPoint >= 0,
                      frame.game.plies.count > frame.branchPoint
                else { continue }
                frames[frames.count - 1].game.addVariation(
                    Array(frame.game.plies[frame.branchPoint...]), atPly: frame.branchPoint
                )
            }
        }

        // ReviewDepth does not stay in `tags`: it lives on the Game and `text` writes it back
        // from there, so the fact has one home and cannot be written twice or drift.
        self.tags = tags.filter { $0.name != "ReviewDepth" }
        self.game = frames[0].game
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
        case intent(Intent)
        case plan(Int)
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
                if let intent = Self.intent(in: comment) { tokens.append(.intent(intent)) }
                if let span = Self.plan(in: comment) { tokens.append(.plan(span)) }
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

    private static func line(in comment: String) -> [String]? {
        Self.body(of: "line", in: comment).map { $0.split(separator: " ").map(String.init) }
    }

    private static func intent(in comment: String) -> Intent? {
        Self.body(of: "int", in: comment).flatMap { Intent(pgnText: $0) }
    }

    private static func plan(in comment: String) -> Int? {
        Self.body(of: "plan", in: comment).flatMap { Int($0) }
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
