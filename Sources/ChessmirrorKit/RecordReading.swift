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

    /// A reading of `game` at `cursor`, by the 判决线 in force and the sides the player moved.
    public init(game: Game, mine: Set<PieceColour>, lines: JudgementLines, cursor: Int) {
        self.init(game: game, cursor: cursor, slips: game.slips(by: mine, lines: lines))
    }

    private init(game: Game, cursor: Int, slips: [Slip]) {
        self.game = game
        self.cursor = cursor
        self.slips = slips
    }

    /// The same game read at another position. The walk is not repeated: nothing about which
    /// moves were 错招 depends on where the eye is.
    public func moved(to cursor: Int) -> RecordReading {
        RecordReading(game: game, cursor: cursor, slips: slips)
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
