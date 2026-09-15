import CStockfish

/// Who attacks each of the 64 squares, per colour.
///
/// The map a move's purpose is made of. "Defended" and "hanging" and "this square is mine"
/// are all statements about this and nothing else, so every screen and every check that
/// needs one of them asks here rather than counting pieces its own way.
///
/// A piece standing on a square does not attack it. Pinned pieces do count: a pinned
/// defender still answers a capture on the square it covers, because the recapture happens
/// before the pin could ever be cashed.
public struct SquareControl: Hashable, Sendable {
    /// Attacker counts by square index, 0...63.
    private let white: [Int]
    private let black: [Int]

    init(white: [Int], black: [Int]) {
        precondition(white.count == 64 && black.count == 64)
        self.white = white
        self.black = black
    }

    public func attackers(of square: Square, by colour: PieceColour) -> Int {
        colour == .white ? white[square.index] : black[square.index]
    }

    /// Which colour attacks this square more often, or nil when they are level — including
    /// level at nothing, which is much the commonest case.
    public func holder(of square: Square) -> PieceColour? {
        let mine = white[square.index]
        let theirs = black[square.index]
        if mine == theirs { return nil }
        return mine > theirs ? .white : .black
    }

    /// How firmly one colour holds a square, as an order rather than a count: theirs, nobody's,
    /// mine. Two maps compared through this say which way a square went for that colour, which a
    /// pair of `holder` answers cannot — a square that fell from held to contested and one that
    /// rose from contested to held are both "the holder changed".
    public func grip(on square: Square, for colour: PieceColour) -> Int {
        switch holder(of: square) {
        case colour: 1
        case nil: 0
        default: -1
        }
    }

    /// The squares where this map and another disagree about who holds them — what a move
    /// changed, when the two maps are the positions either side of it.
    public func squaresDiffering(from other: SquareControl) -> Set<Square> {
        var changed: Set<Square> = []
        for index in 0..<64 {
            guard let square = Square(index: index) else { continue }
            if holder(of: square) != other.holder(of: square) { changed.insert(square) }
        }
        return changed
    }
}

/// What a move is worth in material once both sides have taken everything worth taking on
/// the square it lands on.
///
/// The difference between 吃 and 换 — "I win a piece here" against "this is an even trade" —
/// which is the pair a player confuses most often. For a quiet move it answers a different
/// and just as useful question: whether the piece is walking somewhere it can simply be
/// taken.
public enum ExchangeValue: Hashable, Sendable {
    case losing
    case level
    case winning
}

extension Rules {
    /// The control map of the position `moves` leads to, or nil if the FEN fails validation
    /// or some move is not legal where it is played.
    public static func control(startFEN: String, moves: [String] = []) -> SquareControl? {
        withCStrings(moves) { pointers in
            var raw = CfControl()
            guard cf_square_control(startFEN, pointers, Int32(moves.count), &raw) else {
                return nil
            }
            return SquareControl(
                white: counts(of: raw.white),
                black: counts(of: raw.black)
            )
        }
    }

    /// What `uci` is worth in material in the position `moves` leads to. Nil when the
    /// position does not validate or the move is not legal in it.
    public static func exchangeValue(
        startFEN: String, moves: [String] = [], uci: String
    ) -> ExchangeValue? {
        withCStrings(moves) { pointers in
            var raw = Int32(0)
            guard cf_exchange_value(startFEN, pointers, Int32(moves.count), uci, &raw) else {
                return nil
            }
            switch raw {
            case Int32(CF_EXCHANGE_WINNING.rawValue): return .winning
            case Int32(CF_EXCHANGE_LOSING.rawValue): return .losing
            default: return .level
            }
        }
    }

    /// A fixed-size C array of 64 counts as a Swift array. Imported as a tuple, so the
    /// bytes are read rather than the tuple walked — the same way a FEN verdict's squares are.
    private static func counts(of raw: some Any) -> [Int] {
        withUnsafeBytes(of: raw) { bytes in
            bytes.bindMemory(to: Int32.self).map(Int.init)
        }
    }
}

extension SquareControl {
    /// Every piece standing on a square its own side does not hold — attacked more often than it
    /// is defended.
    ///
    /// The checklist item that decides the most amateur games, and the reason this map exists at
    /// all. Kings are left out: a king attacked is a check, which the board already says in red,
    /// and a king is never *defended* in the sense this counts.
    public func loosePieces(among pieces: [Square: Piece]) -> Set<Square> {
        var loose: Set<Square> = []
        for (square, piece) in pieces where piece.kind != .king {
            let mine = attackers(of: square, by: piece.colour)
            let theirs = attackers(of: square, by: piece.colour.opposite)
            if theirs > mine { loose.insert(square) }
        }
        return loose
    }
}

extension Game {
    /// The pieces hanging in this position — attacked more often than defended, either colour's
    /// (docs/adr/0018). Nil when the position could not be read.
    ///
    /// Computed rather than stored, and cheap enough to be: replaying the moves and asking who
    /// attacks each of the sixty-four squares is the same work a perft node does.
    public var loosePieces: Set<Square>? {
        guard let control = Rules.control(startFEN: startFEN, moves: uciMoves),
            let pieces = BoardRenderer.placement(state.fen)
        else { return nil }
        return control.loosePieces(among: pieces)
    }

    /// The squares whose holder the last Ply changed — what that move did to the board, as
    /// against what it did to the Score.
    ///
    /// Nil for a Game with no moves in it, and for one that cannot be replayed.
    public var squaresLastMoveChanged: Set<Square>? {
        guard !plies.isEmpty,
            let before = rewound(to: plies.count - 1),
            let beforeControl = Rules.control(startFEN: before.startFEN, moves: before.uciMoves),
            let afterControl = Rules.control(startFEN: startFEN, moves: uciMoves)
        else { return nil }
        return afterControl.squaresDiffering(from: beforeControl)
    }

    /// The same squares, told apart by which way they went for the side that just moved.
    ///
    /// One set was not enough to look at. A move takes a grip on some squares and lets go of
    /// others, and those are opposite facts about it — drawn in one colour they are nine squares
    /// scattered over a board with nothing to say about any of them. Told apart they are the move's
    /// gains and the move's costs, which is a thing a person can read.
    ///
    /// Nil under the same conditions as `squaresLastMoveChanged`.
    public var lastMoveControlChange: ControlChange? {
        guard !plies.isEmpty,
            let before = rewound(to: plies.count - 1),
            let beforeControl = Rules.control(startFEN: before.startFEN, moves: before.uciMoves),
            let afterControl = Rules.control(startFEN: startFEN, moves: uciMoves)
        else { return nil }
        // Whoever is *not* to move now is the one who just moved.
        let mover = state.sideToMove.opposite
        var change = ControlChange(mover: mover)
        for square in afterControl.squaresDiffering(from: beforeControl) {
            let was = beforeControl.grip(on: square, for: mover)
            let now = afterControl.grip(on: square, for: mover)
            if now > was {
                change.gained.insert(square)
            } else if now < was {
                change.lost.insert(square)
            }
        }
        change.nearKing = change.lost.intersection(kingRing(of: mover))
        return change
    }

    /// The eight squares round a colour's own king, and the square it stands on.
    ///
    /// The one place on the board where letting go of a square is not a matter of taste. A square
    /// given up in the middle is a square somebody else might use; a square given up next to your
    /// own king is where the attack goes.
    func kingRing(of colour: PieceColour) -> Set<Square> {
        guard let pieces = BoardRenderer.placement(state.fen),
            let king = pieces.first(where: { $0.value.kind == .king && $0.value.colour == colour })?
                .key
        else { return [] }
        var ring: Set<Square> = [king]
        for file in (king.file - 1)...(king.file + 1) where (0..<8).contains(file) {
            for rank in (king.rank - 1)...(king.rank + 1) where (0..<8).contains(rank) {
                ring.insert(Square(file: file, rank: rank))
            }
        }
        return ring
    }
}

/// What one move did to the map of who holds what, from the point of view of whoever played it.
///
/// A square can only be in one of the two: the holder changed, so the mover's grip on it either
/// tightened or loosened, and there is no third way for it to have changed at all.
public struct ControlChange: Hashable, Sendable {
    /// The side that played the move both sets are about. Neither set means anything without it —
    /// "gained" is somebody's gain.
    public let mover: PieceColour
    /// Squares the mover holds more firmly than before: taken outright, or wrested off the other
    /// side into a stand-off.
    public var gained: Set<Square> = []
    /// Squares it holds less firmly: given away outright, or let go into a stand-off.
    public var lost: Set<Square> = []
    /// The subset of `lost` that touches the mover's own king — a square given up in the middle of
    /// the board is a matter of taste, and one given up beside your own king is where the attack
    /// goes. Always a subset, so a screen can name it without counting anything twice.
    public var nearKing: Set<Square> = []

    public init(
        mover: PieceColour,
        gained: Set<Square> = [],
        lost: Set<Square> = [],
        nearKing: Set<Square> = []
    ) {
        self.mover = mover
        self.gained = gained
        self.lost = lost
        self.nearKing = nearKing
    }

    public var isEmpty: Bool { gained.isEmpty && lost.isEmpty }
    public var count: Int { gained.count + lost.count }
}

extension Game {
    /// One colour's pieces hanging in this position — attacked more often than defended.
    ///
    /// Whose they are is the whole question a tally over a library asks: a piece of the
    /// opponent's left loose is a chance, and one of your own left loose is the thing you keep
    /// doing (docs/adr/0018). Nil when the position could not be read.
    public func loosePieces(of colour: PieceColour) -> Set<Square>? {
        guard let control = Rules.control(startFEN: startFEN, moves: uciMoves),
            let pieces = BoardRenderer.placement(state.fen)
        else { return nil }
        let mine = pieces.filter { $0.value.colour == colour }
        return control.loosePieces(among: mine)
    }

    /// Whether taking on `square` would win material for the side to move.
    public func winningCapture(on square: Square) -> Bool {
        state.legalMoves.contains { move in
            guard move.isCapture, move.to == square else { return false }
            return Rules.exchangeValue(
                startFEN: startFEN, moves: uciMoves, uci: move.uci
            ) == .winning
        }
    }

    /// Whether the piece on `square` cannot hold against `colour` on this map.
    ///
    /// Either it is outnumbered, or taking it would still win material. The second half is
    /// why a pawn looking at a queen is 攻: one attacker, one defender, and a queen for a pawn.
    /// The count is a fact about the map; the exchange is a fact about the position, so the
    /// taker has to be on the clock — `passed()` when it is not yet their turn.
    public func cannotHold(
        _ square: Square, against colour: PieceColour, control: SquareControl
    ) -> Bool {
        let now = control.attackers(of: square, by: colour)
        if now > control.attackers(of: square, by: colour.opposite) { return true }
        let taking = state.sideToMove == colour ? self : passed()
        return taking?.winningCapture(on: square) == true
    }
}
