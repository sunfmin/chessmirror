import Foundation

/// 记录读数 — what one game's record says about the player's 错招, read at one position.
///
/// A game plus whose moves are the player's plus the 判决线 is enough to answer every question
/// the record strip asks: which moves were 错招 (docs/adr/0036), which of them belong to the
/// position the eye is on, and which 试招 were refused there (docs/adr/0037). None of it needs
/// an engine, a library, a screen or a live search — the answers are in the Game — so none of it
/// needs a session either. It lived in `GameSession` for a year, where reading it in a test meant
/// standing up a session, scripting an engine and suspending it afterwards.
///
/// The walk is the expensive half (`Game.slips`), so a reading holds it: moving the eye with
/// `moved(to:)` keeps the walk and re-answers the cheap questions.
public struct RecordReading: Sendable {
    /// Where the eye is: the number of moves before the position being read.
    public let cursor: Int

    /// Every 错招 in this Game, oldest first (docs/adr/0036).
    ///
    /// The player's own moves that cost at or over the 记录线, each carrying the position it was
    /// played from. This is the list the record strip marks and the strip under it walks: the
    /// answer to 「这一局我哪儿走错了」，which is a question about one game and not about the
    /// schedule.
    public let slips: [Slip]

    private let game: Game
    private let lines: JudgementLines
    /// Whether anything in the game has been measured: a record with nothing measured in it has
    /// no line of costs to draw (`Game.hasCosts`). Held, because it is a walk of its own.
    private let hasCosts: Bool

    /// A reading of `game` at `cursor`, by the 判决线 in force and the sides the player moved.
    public init(game: Game, mine: Set<PieceColour>, lines: JudgementLines, cursor: Int) {
        self.init(
            game: game, lines: lines, cursor: cursor, slips: game.slips(by: mine, lines: lines),
            hasCosts: game.hasCosts
        )
    }

    private init(game: Game, lines: JudgementLines, cursor: Int, slips: [Slip], hasCosts: Bool) {
        self.game = game
        self.lines = lines
        self.cursor = cursor
        self.slips = slips
        self.hasCosts = hasCosts
    }

    /// The same game read at another position. The walk is not repeated: nothing about which
    /// moves were 错招 depends on where the eye is.
    public func moved(to cursor: Int) -> RecordReading {
        RecordReading(game: game, lines: lines, cursor: cursor, slips: slips, hasCosts: hasCosts)
    }

    /// The 错招 by the *position* they were made at, which is what the record strip's cells are:
    /// a cell's cursor is the position it takes the board to, so a mistake at Ply `n` is marked on
    /// the cell at `n - 1` (docs/adr/0036). Zero is the opening cell.
    public var slipByPosition: [Int: Slip] {
        Dictionary(slips.map { ($0.positionPly, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The next 错招 from where the eye is: the one after it when it is standing on one, the
    /// first at or after it otherwise. Nil at the end of the game.
    public var next: Slip? {
        if let here = slips.firstIndex(where: { $0.ply - 1 == cursor }) {
            return slips.dropFirst(here + 1).first
        }
        return slips.first { $0.ply - 1 >= cursor }
    }

    // ------------------------------------------------------- the position being read

    /// Where the wrong moves on the strip are read from: the position on the board first — what
    /// is still pending there, else what the move played *from* it took with it — and only when
    /// the position has nothing of its own, the move that has just landed on it, which is the one
    /// the eye is on at the end of a live game. Never a whole-game list.
    ///
    /// The position first, because a position is what the strip's cells, its marks and the 错题
    /// tiles all count (docs/adr/0036, 0037): walking to a 错题 puts the board on the position
    /// the move was played from, and the moves listed under it have to be that position's. They
    /// used to be read one Ply behind — off the move that had landed — so a tile walked to showed
    /// nothing, and the next arrow showed what the tile had promised.
    public enum Place: Equatable, Sendable {
        /// Refusals still pending at the cursor.
        case pending
        /// The move at this index of `plies`: its 试招, and itself when it stood too expensively.
        case ply(Int)
        case nothing
    }

    /// Which position the strip's wrong moves belong to, and how they are held there: still
    /// pending at the cursor, carried by a move that stood, or nothing to show.
    public var place: Place {
        if !game.pendingTries(atPly: cursor).isEmpty { return .pending }
        if game.plies.indices.contains(cursor),
            !game.plies[cursor].tried.isEmpty || stoodWrong(atPly: cursor) != nil
        {
            return .ply(cursor)
        }
        if cursor > 0, game.plies.indices.contains(cursor - 1) { return .ply(cursor - 1) }
        return .nothing
    }

    /// Which Ply's position the wrong moves on show were played in — the one their 应招 is drawn
    /// from. Nil when there is nothing to show. A caller that already has that position rewound
    /// (a session has: `viewed`) can use it when this is the cursor rather than rewinding again.
    public var wrongsPly: Int? {
        switch place {
        case .pending: return cursor
        case .ply(let index): return index
        case .nothing: return nil
        }
    }

    /// Only the attempts relevant to the position being read (`wrongsPly`): what is still pending
    /// here, else the 试招 the move played from here took with it, else what the move that has
    /// just landed took with it.
    public var attempts: [Game.Ply.Tried] {
        switch place {
        case .pending: return game.pendingTries(atPly: cursor)
        case .ply(let index): return game.plies[index].tried
        case .nothing: return []
        }
    }

    /// Every wrong move at the position being read, oldest first: the 试招 in the order they were
    /// refused, then the move that finally stood if it was too expensive too — the list a 错题
    /// tile counts (`Slip.wrong`), for the position the board is on. The move that stood is
    /// listed only at its own position: at the position after it, the badge already says what
    /// it cost.
    public var wrongs: [WrongMove] {
        var found = attempts.enumerated().map { WrongMove($1, at: $0) }
        switch place {
        case .pending:
            if let stood = stoodWrong(atPly: cursor) { found.append(stood) }
        case .ply(let index) where index == cursor:
            if let stood = stoodWrong(atPly: cursor) { found.append(stood) }
        default:
            break
        }
        return found
    }

    /// The move that stood at `index` of `plies`, when it was the player's own and cost at or
    /// over the 记录线 — the 错招 an imported game is made of, since nothing was refused in it.
    /// By the same rule the 错题 tiles use (`slips`), so the chip and the tile never disagree
    /// about whether a move was wrong.
    private func stoodWrong(atPly index: Int) -> WrongMove? {
        guard game.plies.indices.contains(index), let slip = slipByPosition[index],
            let wrong = slip.wrong.first(where: { !$0.wasTried })
        else { return nil }
        return WrongMove(
            source: .stood(ply: index + 1), san: wrong.san, drop: wrong.drop,
            depth: game.plies[index].judgement?.depth ?? game.reviewDepth,
            line: game.reviewLine(atPly: index + 1)
        )
    }

    // ------------------------------------------------------------------ what the record says
    //
    // Every word and figure the record strip puts on the glass, decided here and only drawn by the
    // screen. They were the screen's, which is why the way a 掉幅 is said had a second spelling
    // beside `Drop`, and why every one of these rules could only be asked of a simulator.

    /// The line under a move on the record (docs/adr/0027).
    public enum Caption: Hashable, Sendable {
        /// Nobody measured this move: a blank of the same height, which is not the same as zero.
        case unmeasured
        /// The engine's own first choice (CONTEXT.md: 最佳). A fact about which move it was, so it
        /// wins over a cost that did not round to nought — two searches disagree by a point.
        case best
        /// Another move that cost nothing: information — the move was right — and not 最佳.
        case free
        /// What it cost, in percentage points.
        case cost(Double)

        /// What the cell shows under the move: a blank, 「最佳」, 「0」, or `−25%`.
        public var figure: String {
            switch self {
            case .unmeasured: " "
            case .best: localized("record.best")
            case .free: "0"
            case .cost(let drop): Drop.figure(drop)
            }
        }

        /// The clause said out loud for it, nil for a move nobody measured.
        public var spoken: String? {
            switch self {
            case .unmeasured: nil
            case .best: localized("standing.best")
            case .free: Drop.cost(0)
            case .cost(let drop): Drop.cost(drop)
            }
        }
    }

    /// The mark a 错招 leaves at the foot of the position it was made at, in two weights on the one
    /// scale (docs/adr/0027): what the 记录线 wrote down, and what the 入列线 says is still owed.
    public enum Mark: Hashable, Sendable {
        case written
        case owed

        /// How hard the mark is pressed on the glass: what the 入列线 still owes is full weight,
        /// what is only written down is held back (docs/adr/0027). The meaning of the mark, said
        /// here once, so a screen does not re-derive which weight is which.
        public var weight: Double {
            self == .owed ? 1 : 0.5
        }
    }

    /// One place on the record, as the strip shows it and says it — **and draws it.** Everything
    /// one cell of the strip needs is here: what it reads, its caption, its mark, the 分支 ticks
    /// beside it (docs/adr/0043), how it is said out loud, and whether the eye is on it. The
    /// screen paints this; it does not re-assemble what any of it means.
    public struct Cell: Hashable, Sendable {
        /// The cursor it takes the board to.
        public let ply: Int
        /// What the cell reads: the move, or 「开局」 for the position the game began in.
        public let name: String
        /// The line under it — nil when nothing in the game has been measured, so a game nobody
        /// judged is the strip exactly as it was.
        public let caption: Caption?
        /// The mark at its foot when the player went wrong *from* this position.
        public let mark: Mark?
        /// Said the way somebody reading a game aloud says it: where it is, what it cost, and that
        /// a mistake was made from here. On a fork, which line it is of the ones played from here.
        public let spoken: String
        /// Whether the eye is on this cell — the reading's own cursor, not a comparison the
        /// screen makes.
        public let isCursor: Bool
        /// 树干 rather than a numbered 树枝 (docs/adr/0043). A cell nobody forked at is its own trunk.
        public let isTrunk: Bool
        /// This cell's number among the lines played from its position, 树干 first.
        public let branchNumber: Int
        /// How many lines were played from its position; one for a position nobody forked at.
        public let siblingCount: Int

        /// Whether the position this cell was played from has more than one line out of it —
        /// the crease the strip draws as ticks (docs/adr/0043).
        public var isFork: Bool { siblingCount > 1 }

        /// Whether the cell is drawn filled. A cell on a fork is outlined instead when the eye is
        /// on it, so the rail beside it reads as part of the same cell.
        public var isFilled: Bool { isCursor && !isFork }
    }

    /// One scoresheet row as the strip draws it: the move number and its one or two halves, each
    /// already a Cell. Gluing the halves under their number belongs here — the same walk that
    /// knows which mark goes on which half also knows which two share a number.
    public struct Row: Hashable, Sendable, Identifiable {
        /// 「1」「2」 — the figure the card is ruled under.
        public let number: Int
        public let white: Cell?
        public let black: Cell?

        public var id: Int { number }
    }

    /// The strip, ready to draw: one row per move number, opening first (`opening`) and then
    /// every half already carrying its caption, mark, 分支 ticks, spoken string and cursor.
    /// The screen lays these out and nothing else.
    public var rows: [Row] {
        game.scoresheet.map { card in
            Row(
                number: card.number,
                white: card.white.map { cell($0) },
                black: card.black.map { cell($0) }
            )
        }
    }

    /// The position the game began in, at the head of its own record. One name for one place: it
    /// is a place in the game like any other, not an instruction.
    public var opening: Cell {
        cell(ply: 0, name: localized("record.opening"), said: localized("record.opening"))
    }

    /// One half of a move on the record, ready to draw: the mark is the one whose *position* this
    /// cell is — the position before the next move, not after this one (`slipByPosition`) — and
    /// the 分支 ticks come with it (docs/adr/0043).
    public func cell(_ half: Game.Half) -> Cell {
        cell(
            ply: half.ply, name: half.san, said: half.spoken,
            isTrunk: half.isTrunk, branchNumber: half.branchNumber, siblingCount: half.siblingCount
        )
    }

    private func cell(
        ply: Int, name: String, said: String,
        isTrunk: Bool = true, branchNumber: Int = 1, siblingCount: Int = 1
    ) -> Cell {
        let caption = hasCosts && ply > 0 ? caption(atPly: ply) : nil
        let mark = slipByPosition[ply].map(mark(of:))
        var clauses = [said]
        if let spoken = caption?.spoken { clauses.append(spoken) }
        if let slip = slipByPosition[ply] {
            clauses.append(localized("record.slipMark", Drop.points(slip.drop)))
        }
        return Cell(
            ply: ply, name: name, caption: caption, mark: mark,
            spoken: clauses.joined(separator: localized("clause.separator")),
            isCursor: ply == cursor, isTrunk: isTrunk,
            branchNumber: branchNumber, siblingCount: siblingCount
        )
    }

    private func caption(atPly ply: Int) -> Caption {
        if game.isBest(atPly: ply) { return .best }
        guard let drop = game.cost(atPly: ply) else { return .unmeasured }
        return Drop.points(max(0, drop)) == 0 ? .free : .cost(max(0, drop))
    }

    private func mark(of slip: Slip) -> Mark {
        slip.isWorthDrilling(lines) ? .owed : .written
    }

    /// One 错题 of this game as its tile under the strip says it: where in the game, how many wrong
    /// moves were tried there, what the worst of them cost, and whether it is still owed.
    public struct Tile: Hashable, Sendable, Identifiable {
        public let slip: Slip
        /// The scoresheet's figure — 「1.」「2…」 — the same one the cell above carries, including
        /// for the position the game stops on: a 错招 there sits at the Ply one past the last
        /// move (docs/adr/0037), and that move has a number even before it is played.
        public let number: String
        /// `×N` when one position took more than one wrong move, which is why the tile is not
        /// named after any one of them. Nil for one.
        public let times: Int?
        /// What the worst of them cost, as a figure.
        public let figure: String
        /// Whether the 入列线 says the player still owes it: full strength, else held back.
        public let isOwed: Bool
        /// The whole tile, said out loud.
        public let spoken: String

        public var id: Slip.ID { slip.id }
    }

    /// The tiles, one per 错题 of this game, in the order they happen.
    public var tiles: [Tile] { slips.map(tile(for:)) }

    public func tile(for slip: Slip) -> Tile {
        let times = slip.wrong.count > 1 ? slip.wrong.count : nil
        let separator = localized("clause.separator")
        // Out loud the position the game stops on is 「现在」: a number a finger can match to the
        // strip is what a row of tiles wants, and a word is what an ear wants.
        let place = slip.ply > game.plies.count
            ? localized("record.now") : localized("record.ply", slip.ply)
        var spoken = place + separator + Drop.cost(slip.drop)
        if let times { spoken += separator + localized("slips.wrong", times) }
        return Tile(
            slip: slip, number: game.moveLabel(ofPly: slip.ply), times: times,
            figure: Drop.figure(slip.drop), isOwed: slip.isWorthDrilling(lines), spoken: spoken
        )
    }

    /// What leads the row of wrong moves at the position being read: an ✕ when anything there was
    /// taken back, and a mark that says it was played when the row is only the move that stood —
    /// an imported game's, where nothing was ever refused (docs/adr/0034, 0036).
    public enum Lead: Hashable, Sendable {
        case returned
        case stood

        /// The word the mark is read out as, instead of spending the row's width on it.
        public var spoken: String {
            localized(self == .returned ? "noSlips.returned" : "wrong.stood")
        }
    }

    /// Nil when there are no wrong moves to lead.
    public var lead: Lead? {
        guard !wrongs.isEmpty else { return nil }
        return wrongs.contains { !$0.stood } ? .returned : .stood
    }

    // ------------------------------------------------------------------ one wrong move

    /// One wrong move at the position on the board, as the strip lists it: a 试招 把关 took
    /// back, or the move that stood there too expensively. Two kinds under one chip, because an
    /// imported game has only the second — nothing was ever refused in it — and its 错招 want the
    /// same chip and the same 应招 as a refusal's (docs/adr/0034, 0036).
    public struct WrongMove: Hashable, Sendable {
        public enum Source: Hashable, Sendable {
            /// Which of `attempts`.
            case tried(Int)
            /// The move that stood, at the Ply it took, counting from one.
            case stood(ply: Int)
        }

        public let source: Source
        public let san: String
        /// What it cost, in percentage points of win probability (docs/adr/0027).
        public let drop: Double
        /// The Depth it was judged at, when one was written down.
        public let depth: Int?
        /// The 应招 kept for it: a 试招's own, or the Review's Line from the position the move
        /// that stood made. Empty when nothing was written down, and then asked for
        /// (`reply(for:)`).
        public let line: [String]

        public init(source: Source, san: String, drop: Double, depth: Int?, line: [String]) {
            self.source = source
            self.san = san
            self.drop = drop
            self.depth = depth
            self.line = Array(line.prefix(Reply.limit))
        }

        public init(_ tried: Game.Ply.Tried, at index: Int) {
            self.init(
                source: .tried(index), san: tried.san, drop: tried.drop, depth: tried.depth,
                line: tried.line
            )
        }

        /// True for the move that stood, rather than one taken back.
        public var stood: Bool {
            if case .stood = source { return true }
            return false
        }

        /// Which of `attempts` this is, for a 试招.
        public var triedIndex: Int? {
            if case .tried(let index) = source { return index }
            return nil
        }
    }
}
