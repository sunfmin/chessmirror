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

    private static let rosterOrder = [Tags.event, Tags.site, Tags.date, Tags.round, Tags.white, Tags.black, Tags.result]

    public init(game: Game, tags: [Tag] = []) {
        self.game = game
        self.tags = tags
    }

    public func tag(_ name: String) -> String? {
        tags.first { $0.name == name }?.value
    }

    // ------------------------------------------- the facts a game carries in its tags
    //
    // The one place a fact about a game is given its tag name. A session writes its game through
    // `init(game:seats:origin:lines:carrying:)` and reads the facts back
    // through the properties below, and never names a tag itself; the library's list, the 错题本
    // and the 连正榜 read the same properties off the same file, which is how the row under the
    // board and the ladder come to agree about whose moves are whose.

    /// The tag names this app knows by name.
    ///
    /// **The one place a fact gets its tag name.** The claim was half true for a year: the facts
    /// a session writes came through here, while the importer spelled `"White"`, `"Event"`,
    /// `"UTCDate"` and seven more of its own, and the app spelled two. A tag misspelt in one of
    /// those places is a game this app writes and cannot read back (docs/adr/0010).
    public enum Tags {
        public static let event = "Event"
        public static let site = "Site"
        public static let date = "Date"
        public static let round = "Round"
        public static let white = "White"
        public static let black = "Black"
        public static let result = "Result"
        /// Where an imported game came from, and when, as its site recorded it.
        public static let link = "Link"
        public static let utcDate = "UTCDate"
        public static let utcTime = "UTCTime"
        /// A study's own name for one chapter (docs/adr/0014).
        public static let chapterName = "ChapterName"
        /// How an import's Review was run (docs/adr/0044).
        public static let reviewSift = "ReviewSift"
        /// What the player called this game (`GameLibrary.rename`).
        public static let name = "Name"
        /// Whose moves are whose, for an import: the roster names two real people, so the file
        /// says which of them the player is (docs/adr/0028).
        public static let trackedSide = "TrackedSide"
        /// Where the position came from (`GameOrigin`).
        public static let source = "Source"
        /// The 记录线 把关 stopped the player at (docs/adr/0046).
        public static let intercept = "Intercept"

        /// The roster name for one colour.
        public static func player(_ colour: PieceColour) -> String {
            colour == .white ? white : black
        }
    }

    static let interceptTag = Tags.intercept
    static let interceptPreferenceTag = "InterceptPreference"
    static let trackedSideTag = Tags.trackedSide

    /// The file this app writes for a game it holds: the Game, and the facts about the game that
    /// are not moves — who sat at each side, where it came from, the lines it is judged by —
    /// each in the tag it lives in, over whatever the file carried before (`carrying`).
    public init(
        game: Game, seats: [PieceColour: Controller], origin: GameOrigin,
        lines: JudgementLines, carrying tags: [Tag] = []
    ) {
        var written = PGN(game: game, tags: tags)
        // Event carries the app's name, which is what PGN's "which set of games is this" tag is
        // worth saying now that there are no collections (docs/adr/0028). Written unconditionally:
        // an Event an import brought in names somebody else's tournament, and the file this app
        // writes is this app's.
        written.setTag(Tags.event, to: "Chessmirror")
        // An imported game keeps the two real people in its roster; which of them is the player
        // is `trackedSide`, said by the import (docs/adr/0028).
        if origin != .imported {
            written.setTag(Tags.white, to: (seats[.white] ?? .hand).playerName)
            written.setTag(Tags.black, to: (seats[.black] ?? .hand).playerName)
            // The standard Elo tags, for other tools, when the whole game was at one rung; a game
            // that changed rung says so per move and nowhere else (docs/adr/0038).
            written.setTag("WhiteElo", to: game.constantElo(of: .white).map(String.init))
            written.setTag("BlackElo", to: game.constantElo(of: .black).map(String.init))
        }
        written.setTag(Tags.result, to: game.resultToken)
        written.setTag(Self.interceptTag, to: lines.intercept.map(String.init(describing:)))
        // The line 把关 would come back on at, from when it had a dial of its own. It has none
        // now (docs/adr/0046), so a file that carried one stops carrying it.
        written.setTag(Self.interceptPreferenceTag, to: nil)
        written.setTag(GameOrigin.tagName, to: origin.tagValue)
        if written.tag(Tags.date) == nil {
            written.tags.append(Self.dateTag())
        }
        self = written
    }

    /// The 拦截线 the game was saved under: 把关 was on, stopping the player at this line. A game
    /// reopened comes back with 把关 on and stops at the player's 记录线 as it is now; the number
    /// here is the account of the moves already played (docs/adr/0046).
    public var intercept: Double? {
        guard let value = tag(Self.interceptTag).flatMap(Double.init), value.isFinite,
              JudgementLines.scale.contains(value) else { return nil }
        return value
    }

    /// Where the game came from. Not a standard tag; readers that do not know it ignore it.
    public var origin: GameOrigin {
        GameOrigin(rawValue: tag(GameOrigin.tagName) ?? "") ?? .fresh
    }

    /// What the game is called, if anybody has said. Its own tag rather than `Event`: PGN has no
    /// tag for the name of a single game, and the precedent for adding one is `Source`.
    public var name: String? {
        tag(GameLibrary.nameTag).flatMap { $0.isEmpty ? nil : $0 }
    }

    public mutating func setName(_ name: String?) {
        setTag(GameLibrary.nameTag, to: name)
    }

    /// Which side of an imported game is the player's, said by the import (docs/adr/0028).
    public var trackedSide: PieceColour? {
        switch tag(Self.trackedSideTag) {
        case "white": .white
        case "black": .black
        default: nil
        }
    }

    public mutating func track(_ side: PieceColour?) {
        setTag(Self.trackedSideTag, to: side.map { $0 == .white ? "white" : "black" })
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
        if tag(Self.trackedSideTag) != nil {
            return trackedSide.map { [$0] } ?? []
        }
        var found: Set<PieceColour> = []
        if playerName(.white) == Controller.hand.playerName { found.insert(.white) }
        if playerName(.black) == Controller.hand.playerName { found.insert(.black) }
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
            ) + pendingComments + [game.resultToken]
    }

    /// The 试招 no move has carried yet, with the position each belongs to.
    ///
    /// Before the result token and not after it, which is not a matter of taste: the reader stops
    /// at the result, so a comment written past it is a comment nothing will ever read.
    ///
    /// `%pending <plies> …` rather than `%tried`, because a `%tried` rides on a move and belongs to
    /// the position *before* it, and one of these belongs to a position nothing else in the file
    /// names. The Ply count is that name: the reader needs it, because a refusal the player walked
    /// away from can be anywhere in the game, not only at the end of it (docs/adr/0037).
    private var pendingComments: [String] {
        guard !game.pendingTried.isEmpty else { return [] }
        let body = game.pendingTried
            .flatMap { pending in
                pending.tries.map { Self.attempt($0, named: "pending", at: pending.ply) }
            }
            .joined(separator: " ")
        return ["{\(body)}"]
    }

    /// One refused move, as a token — a 试招, or one at a position no move has carried yet, which
    /// differs in the name and in carrying the position with it.
    private static func attempt(_ attempt: Game.Ply.Tried, named name: String, at ply: Int? = nil) -> String {
        var body = "\(attempt.san) \(percent(attempt.drop))"
        if attempt.notFound { body += " notfound" }
        // The Depth after the flag, so a reader that knows only the older forms still sees them
        // as a prefix (docs/adr/0041). Absent when unknown, never written as a guess.
        if let depth = attempt.depth { body += " \(depth)" }
        // The 应招 follows a bar (docs/adr/0034). A bar and not a word, because what comes after it
        // is a line of moves and a token of its own would need a second delimiter inside a comment
        // that already ends at the first `]`.
        if !attempt.line.isEmpty {
            body += " | " + attempt.line.joined(separator: " ")
        }
        return "[%\(name) \(ply.map { "\($0) " } ?? "")\(body)]"
    }

    /// One line of moves, with its Variations in brackets after the moves they replace —
    /// which is where PGN has always put them, and why a game written here opens in anything
    /// else with its branches intact.
    private static func tokens(
        for plies: [Game.Ply], from moveNumber: Int, sideToMove: PieceColour,
        afterTrunk: Bool = true, isVariation: Bool = false
    ) -> [String] {
        var written: [String] = []
        var moveNumber = moveNumber
        var sideToMove = sideToMove
        // Whether the Ply before the one being written was 树干 — the first Ply of a line
        // follows the Ply the line branches from, which is what the caller says.
        var afterTrunk = afterTrunk

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
                // With the 拦截线 the move stood under after `under`, when it stood under one: a
                // reader that knows only the three-part form reads the three parts it knows.
                var judged = "[%judged \(judgement.depth) \(judgement.drop) \(judgement.score.pgnText)"
                if let intercept = judgement.intercept { judged += " under \(intercept)" }
                if judgement.best { judged += " best" }
                comment.append(judged + "]")
            }
            // The 棋力 the engine played this move at (docs/adr/0038). Only on the engine's own
            // moves, and 满力 written as `full` rather than left off: a hand move has no token.
            if let strength = ply.strength {
                comment.append("[%strength \(strength.text)]")
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
            // What 把关 took back here, and how many hints were open when the move that stands
            // was finally played (docs/adr/0027). One `[%tried]` per refused move, in the order
            // they were played, because a reader that only knows `[%eval]` skips them the same
            // way it already skips everything else in a comment.
            for attempt in ply.tried {
                comment.append(Self.attempt(attempt, named: "tried"))
            }
            if ply.hints > 0 {
                comment.append("[%hint \(ply.hints)]")
            }
            // Which line is the 树干 (docs/adr/0043). The line a file is written as is the 树干
            // and a bracketed line is a 树枝 unless the file says otherwise, and it says so only
            // where that default is wrong: `[%trunk]` on the head of a bracketed line that is
            // the 树干, `[%branch]` on the Ply where the written line leaves it. Everything after
            // either inherits, and a reader that knows only the mainline reads a marker it does
            // not know as nothing, the same as every other comment here.
            if isVariation, index == 0 {
                if ply.isTrunk { comment.append("[%trunk]") }
            } else if !ply.isTrunk, afterTrunk {
                comment.append("[%branch]")
            }
            if !comment.isEmpty {
                written.append("{" + comment.joined(separator: " ") + "}")
            }
            for variation in ply.variations {
                // A 分支 stands in for this move, so it is numbered as this move — and it
                // follows the same Ply this move does.
                var inner = tokens(
                    for: variation, from: moveNumber, sideToMove: sideToMove,
                    afterTrunk: afterTrunk, isVariation: true
                )
                guard !inner.isEmpty else { continue }
                inner[0] = "(" + inner[0]
                inner[inner.count - 1] += ")"
                written.append(contentsOf: inner)
            }
            afterTrunk = ply.isTrunk
            if sideToMove == .black { moveNumber += 1 }
            sideToMove = sideToMove.opposite
        }
        return written
    }

    /// A drop, as the file says it: `-23%`, the sign saying it is what the move *cost*.
    static func percent(_ drop: Double) -> String { "-\(drop)%" }

    private static func rosterDefault(_ name: String, _ game: Game) -> String {
        switch name {
        case "Event": "chessmirror"
        case "Site": "chessmirror"
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

    /// As much of a PGN `Date` as the file actually knows, for a screen to show.
    ///
    /// PGN writes `????.??.??` for a date nobody recorded — it is this format's own way of
    /// saying nothing, and `rosterDefault` writes it into every game saved without one — and a
    /// partial date for one only half known. A row that prints the tag verbatim prints the
    /// question marks: 「手摆 · ????.??.?? · 2 回合 · 未结束」.
    ///
    /// What is known is kept, from the year down, and the first unknown field ends it; nothing
    /// known is lost, and nothing unknown is drawn. Nil when not even the year is known — and
    /// the file's own modification date is **not** offered in its place, because for an imported
    /// game that is when it was downloaded rather than when it was played, and a row showing one
    /// as the other cannot be told from a row showing the truth.
    public static func playedOn(_ tag: String?) -> String? {
        guard let tag, !tag.isEmpty else { return nil }
        var known: [Substring] = []
        for field in tag.split(separator: ".", omittingEmptySubsequences: false) {
            guard !field.isEmpty, !field.contains("?") else { break }
            known.append(field)
        }
        return known.isEmpty ? nil : known.joined(separator: ".")
    }

    /// The day a game was played, as a Date, from the same tag `playedOn` reads for the screen.
    ///
    /// Nil for a file that does not say, or says only a year or a month: a 遭遇 dated 「2026 年的
    /// 某一天」 would sort and read worse than the honest fallback its caller has. PGN has no
    /// clock in this tag, so this is the day at midnight — the resolution the format offers.
    public static func playedDay(_ tag: String?, calendar: Calendar = .current) -> Date? {
        guard let text = playedOn(tag) else { return nil }
        let parts = text.split(separator: ".").map(String.init)
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// The name in the roster for one colour, as the file has it.
    public func playerName(_ colour: PieceColour) -> String? { tag(Tags.player(colour)) }

    /// Today in PGN's `YYYY.MM.DD`.
    public static func dateTag(_ date: Date = Date(), calendar: Calendar = .current) -> Tag {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let text = String(
            format: "%04d.%02d.%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
        return Tag(Tags.date, text)
    }

    // ------------------------------------------------------- one file, many games

    /// Cuts a multi-game PGN into one block of text per game.
    ///
    /// Here rather than in the importer, where it lived: deciding what a `[` means is this
    /// file's job, and two modules deciding it separately is two things that must agree about
    /// the format the whole app stores its games in (docs/adr/0010). The parser reads one game;
    /// this says where one game ends.
    /// One block per game in a multi-game PGN, each kept byte-for-byte so the
    /// single-game parser can have it whole.
    ///
    /// The split point is a tag line — a line starting `[` — that comes after the
    /// current game's tags have ended. Two things end them: movetext, which is every
    /// non-tag line, and a blank line following the tags (a chapter with no moves is
    /// just tags, then the next chapter's tags). A `[` inside a comment or a
    /// variation must never split: `{[%cal …]}` keeps its brackets, so the `()` and
    /// `{}` depths are tracked and only a `[` at depth zero can start a game.
    /// Blank lines are kept — they are the whitespace the parser already skips — but
    /// blocks that end up empty are dropped.
    public static func split(_ text: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        var seenTag = false
        var tagsClosed = false
        var hasMovetext = false
        var parens = 0
        var braces = 0

        func closeBlock() {
            let block = current.joined(separator: "\n")
            if !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(block)
            }
            current = []
            seenTag = false
            tagsClosed = false
            hasMovetext = false
            parens = 0
            braces = 0
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if seenTag { tagsClosed = true }
                current.append(String(rawLine))
                continue
            }
            if line.first == "[", parens == 0, braces == 0, hasMovetext || tagsClosed {
                closeBlock()
            }
            // Depth first or after the split test? Before: the `(` of this line is
            // this game's, and a `[` deeper into the line is this game's too.
            let effects = bracketEffects(in: line)
            parens += effects.parens
            braces += effects.braces
            if line.first == "[" {
                seenTag = true
            } else {
                hasMovetext = true
            }
            current.append(String(rawLine))
        }
        closeBlock()
        return blocks
    }

    /// How a line changes the `()` and `{}` depths, which is all the splitter needs
    /// to know about it.
    ///
    /// Quote- and comment-aware, because both happily contain the brackets that would
    /// fool it: a tag value like `[White "De La Bourdonnais (1834)"]` must not open a
    /// variation, and a comment is where lichess puts arrows — `{[%cal Gd2d4]}` — so
    /// everything inside `{…}` is dead to the counters except the closing brace.
    private static func bracketEffects(in line: String) -> (parens: Int, braces: Int) {
        var parens = 0
        var braces = 0
        var inQuotes = false
        var previous: Character?
        for character in line {
            if braces > 0 {
                if character == "}" { braces -= 1 }
            } else if inQuotes {
                if character == "\"", previous != "\\" { inQuotes = false }
            } else {
                switch character {
                case "\"":
                    inQuotes = true
                case "(":
                    parens += 1
                case ")":
                    parens -= 1
                case "{":
                    braces += 1
                case "}":
                    braces -= 1
                default:
                    break
                }
            }
            previous = character
        }
        return (parens, braces)
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
        // One frame per open bracket (docs/adr/0043). Moves always go to the innermost one,
        // which is what makes a 分支 inside a 分支 work without any special handling: it is the
        // same rule applied one level further in. A frame goes `dead` when something in it will
        // not read, and a dead frame is dropped whole at its closing bracket: a 分支 is an aside,
        // and files in the wild carry asides that are not moves at all — refusing to open a game
        // over one would lose the game to save the footnote.
        var frames: [(game: Game, branchPoint: Int, dead: Bool)] = [(game, -1, false)]

        // Evaluations arrive in comments *after* the move they belong to.
        for token in scanner.readMovetext() {
            let last = frames.count - 1
            switch token {
            case .move(let san):
                guard !frames[last].dead else { continue }
                // The first move of a bracketed line is a 树枝 unless the file says `[%trunk]`
                // after it; the line the file is written as is the 树干 unless it says
                // `[%branch]` (docs/adr/0043).
                let head = last > 0 && frames[last].game.plies.count == frames[last].branchPoint
                guard frames[last].game.apply(san: san) else {
                    guard last > 0 else {
                        throw ParseError.illegalMove(san, afterPlies: frames[last].game.plies.count)
                    }
                    frames[last].dead = true
                    continue
                }
                if head { frames[last].game.setBranch(atPly: frames[last].branchPoint) }
            case .evaluation(let score):
                guard !frames[last].dead else { continue }
                // A ply index of -1 is a comment standing before the first move, which is
                // the starting position's Score.
                frames[last].game.setEvaluation(
                    score, atPly: frames[last].game.plies.count - 1, reviewed: isReviewed
                )
            case .tried(let attempt):
                guard !frames[last].dead else { continue }
                frames[last].game.addTried(attempt, atPly: frames[last].game.plies.count - 1)
            case .pending(let ply, let attempt):
                // The position is the token's own, because nothing else in the file names it —
                // and it names a position on the line the file is written as, whichever bracket
                // the comment happens to sit in.
                var tries = frames[0].game.pendingTried.first { $0.ply == ply }?.tries ?? []
                tries.append(attempt)
                frames[0].game.setPendingTried(tries, atPly: ply)
            case .hint(let rungs):
                guard !frames[last].dead else { continue }
                frames[last].game.setHints(rungs, atPly: frames[last].game.plies.count - 1)
            case .judgement(let judgement):
                guard !frames[last].dead else { continue }
                frames[last].game.setJudgement(judgement, atPly: frames[last].game.plies.count - 1)
            case .strength(let strength):
                guard !frames[last].dead else { continue }
                frames[last].game.setStrength(strength, atPly: frames[last].game.plies.count - 1)
            case .line(let line):
                guard !frames[last].dead else { continue }
                // A Line standing before the first move belongs to the starting position and has
                // nowhere to go: what reads it is a move's own consequences, and there is no move.
                frames[last].game.setLine(
                    line, atPly: frames[last].game.plies.count - 1, reviewed: isReviewed
                )
            case .branch:
                guard !frames[last].dead else { continue }
                frames[last].game.setBranch(atPly: frames[last].game.plies.count - 1)
            case .trunk:
                guard !frames[last].dead else { continue }
                frames[last].game.setTrunk(atPly: frames[last].game.plies.count - 1)
            case .variationStart:
                // A 分支 is an alternative to the move just read, so it starts from the position
                // that move was played in.
                let branchPoint = frames[last].game.plies.count - 1
                guard !frames[last].dead, branchPoint >= 0,
                    let rewound = frames[last].game.rewound(to: branchPoint)
                else {
                    // Brackets before any move have nothing to be an alternative to. Read them
                    // into a frame that gets thrown away rather than refusing the file.
                    frames.append((frames[last].game, -1, true))
                    continue
                }
                frames.append((rewound, branchPoint, false))
            case .variationEnd:
                // A stray closing bracket closes nothing: files in the wild carry worse than
                // this, and losing a game to save a footnote is the wrong trade.
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
        game = frames[0].game

        // A file written before 棋力 existed says who the engine was only in the roster, and says
        // nothing per move. Its engine moves were at 满力 — that was the only opponent there was
        // (docs/adr/0009) — so they are read as such, and only when no move in the file carries a
        // rung of its own: a file that writes rungs writes one on every engine move, and a move
        // without one there is a hand's.
        if !game.plies.contains(where: { $0.strength != nil }) {
            let engine = Controller.engine.playerName
            for colour in [PieceColour.white, .black]
            where tags.first(where: { $0.name == Tags.player(colour) })?.value == engine {
                for index in game.plies.indices where game.mover(ofPly: index + 1) == colour {
                    game.setStrength(.full, atPly: index)
                }
            }
        }
        // And a judgement written before the 拦截线 travelled with it stood under the file's
        // 拦截线, when the file has one: 把关 was on when the game was saved, which is the best
        // account there is of whether it was on when the move was played.
        if let intercept = (tags.first { $0.name == Self.interceptTag }?.value).flatMap(Double.init) {
            for index in game.plies.indices {
                guard let judgement = game.plies[index].judgement, judgement.intercept == nil else { continue }
                game.setJudgement(
                    .init(drop: judgement.drop, score: judgement.score, depth: judgement.depth, intercept: intercept),
                    atPly: index
                )
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
        case pending(Int, Game.Ply.Tried)
        case hint(Int)
        case judgement(Game.Ply.Judgement)
        case strength(Strength)
        /// `[%branch]`: the move just read leaves the 树干; `[%trunk]`: the bracketed line just
        /// opened is the 树干 (docs/adr/0043).
        case branch
        case trunk
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
                tokens.append(contentsOf: Self.pending(in: comment).map { .pending($0.ply, $0.tried) })
                if let hints = Self.hint(in: comment) { tokens.append(.hint(hints)) }
                if let judgement = Self.judgement(in: comment) { tokens.append(.judgement(judgement)) }
                if let strength = Self.strength(in: comment) { tokens.append(.strength(strength)) }
                if comment.contains("[%branch]") { tokens.append(.branch) }
                if comment.contains("[%trunk]") { tokens.append(.trunk) }
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
    /// position 把关 stopped somebody at three times has three of them. The 应招 rides after a bar
    /// in the same token, so the two can never be read apart from each other (docs/adr/0034).
    private static func tried(in comment: String) -> [Game.Ply.Tried] {
        attempts(of: "tried", in: comment).map(\.tried)
    }

    /// The 试招 at a position nothing has carried yet (docs/adr/0037). One move, what it cost and
    /// the 应招 it earned — the same grammar as a `tried` token — led by the Ply count that names
    /// the position it happened at.
    private static func pending(in comment: String) -> [(ply: Int, tried: Game.Ply.Tried)] {
        attempts(of: "pending", in: comment, at: true).compactMap { body in
            guard let ply = body.ply else { return nil }
            return (ply, body.tried)
        }
    }

    private static func attempts(
        of name: String, in comment: String, at hasPly: Bool = false
    ) -> [(ply: Int?, tried: Game.Ply.Tried)] {
        bodies(of: name, in: comment).compactMap { body in
            var rest = Substring(body)
            var ply: Int?
            if hasPly {
                let head = rest.prefix { $0 != " " }
                guard let value = Int(head), value >= 0 else { return nil }
                ply = value
                rest = rest.dropFirst(head.count)
            }
            let halves = rest.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let parts = halves[0].split(separator: " ")
            guard let san = parts.first, parts.count >= 2,
                parts[1].hasPrefix("-"), parts[1].hasSuffix("%"),
                let drop = Double(parts[1].dropFirst().dropLast()),
                drop.isFinite, (0...100).contains(drop)
            else { return nil }
            // After the cost: a `notfound` flag, then the Depth it was judged at, each at most
            // once and in that order (docs/adr/0041). Anything else is a token nobody wrote.
            var notFound = false
            var depth: Int?
            for part in parts.dropFirst(2) {
                if part == "notfound", !notFound, depth == nil {
                    notFound = true
                } else if depth == nil, let value = Int(part), value > 0 {
                    depth = value
                } else {
                    return nil
                }
            }
            let line = halves.count > 1 ? halves[1].split(separator: " ").map(String.init) : []
            return (
                ply,
                Game.Ply.Tried(san: String(san), drop: drop, notFound: notFound, depth: depth, line: line)
            )
        }
    }

    private static func hint(in comment: String) -> Int? {
        body(of: "hint", in: comment).flatMap { Int($0) }
    }

    /// `[%judged 20 3.2 +0.35]`, or the same with ` under 10.0` after it for a move that stood
    /// under 把关 at that 拦截线, and ` best` last for the engine's own first choice.
    private static func judgement(in comment: String) -> Game.Ply.Judgement? {
        guard let body = body(of: "judged", in: comment) else { return nil }
        var parts = body.split(separator: " ")
        let best = parts.last == "best"
        if best { parts.removeLast() }
        guard parts.count == 3 || (parts.count == 5 && parts[3] == "under"),
              let depth = Int(parts[0]), depth > 0,
              let drop = Double(parts[1]), drop.isFinite, drop >= 0,
              let score = Score(pgnText: String(parts[2])) else { return nil }
        var intercept: Double?
        if parts.count == 5 {
            guard let line = Double(parts[4]), line.isFinite, line >= 0 else { return nil }
            intercept = line
        }
        return .init(drop: drop, score: score, depth: depth, intercept: intercept, best: best)
    }

    /// `[%strength 1800]` or `[%strength full]` (docs/adr/0038).
    private static func strength(in comment: String) -> Strength? {
        body(of: "strength", in: comment).flatMap(Strength.init(text:))
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
