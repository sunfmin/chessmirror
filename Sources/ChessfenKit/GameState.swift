import CStockfish

/// How a Game ended, or that it has not.
public enum Outcome: Hashable, Sendable {
    case ongoing
    case checkmate
    case stalemate
    case fiftyMoveRule
    case threefoldRepetition
    /// Insufficient *mating* material — the practical rule, not FIDE's full
    /// dead-position rule: bare kings, king and one minor, or a bishop each with both
    /// bishops on the same colour.
    case insufficientMaterial

    public var isOver: Bool { self != .ongoing }
    public var isDraw: Bool {
        switch self {
        case .stalemate, .fiftyMoveRule, .threefoldRepetition, .insufficientMaterial: true
        case .ongoing, .checkmate: false
        }
    }
}

/// Everything true of a Game at one moment: the Position it stands in, whether it is
/// over, and every move that may be played.
///
/// Derived, never stored — a Game is its starting FEN plus its moves, and this is what
/// replaying them says (docs/adr/0003).
public struct GameState: Hashable, Sendable {
    public let fen: String
    public let sideToMove: PieceColour
    public let inCheck: Bool
    /// The squares the checking pieces stand on, for the board view to mark.
    public let checkers: [Square]
    public let outcome: Outcome
    public let halfmoveClock: Int
    public let fullmoveNumber: Int
    public let legalMoves: [Move]

    /// The squares the board view marks when the position is in check: every checker, and
    /// the king standing in it — the square a player looks for, which `checkers` does not
    /// name. One answer for every board that shows it, where the Review used to leave the
    /// king unmarked and the game screen marked it.
    public var checkSquares: Set<Square> {
        guard inCheck else { return [] }
        var squares = Set(checkers)
        for (square, piece) in BoardRenderer.placement(fen) ?? [:]
        where piece.kind == .king && piece.colour == sideToMove {
            squares.insert(square)
        }
        return squares
    }

    public func moves(from square: Square) -> [Move] {
        legalMoves.filter { $0.from == square }
    }

    public func move(matching uci: String) -> Move? {
        legalMoves.first { $0.uci == uci }
    }
}

extension Rules {
    /// The position `moves` leads to from `startFEN`, or nil if the FEN fails validation
    /// or some move is not legal where it is played.
    public static func probe(startFEN: String, moves: [String] = []) -> GameState? {
        withCStrings(moves) { pointers in
            var raw = CfGameState()
            guard cf_game_state(startFEN, pointers, Int32(moves.count), &raw) else { return nil }

            // 218 is the most moves any legal position can offer, so one pass suffices.
            var buffer = [CfMove](repeating: CfMove(), count: 218)
            let count = cf_legal_moves(
                startFEN, pointers, Int32(moves.count), &buffer, Int32(buffer.count)
            )
            guard count >= 0 else { return nil }

            let fen = withUnsafeBytes(of: raw.fen) { bytes in
                String(decoding: Array(bytes.prefix(while: { $0 != 0 })), as: UTF8.self)
            }
            var checkers: [Square] = []
            withUnsafeBytes(of: raw.checkers) { bytes in
                for value in bytes.bindMemory(to: Int32.self)
                where value != Int32(CF_NO_SQUARE) {
                    if let square = Square(index: Int(value)) { checkers.append(square) }
                }
            }

            return GameState(
                fen: fen,
                sideToMove: raw.sideToMove == 0 ? .white : .black,
                inCheck: raw.inCheck,
                checkers: checkers,
                outcome: Outcome(raw.outcome),
                halfmoveClock: Int(raw.halfmoveClock),
                fullmoveNumber: Int(raw.fullmoveNumber),
                legalMoves: buffer.prefix(Int(count)).compactMap(Move.init)
            )
        }
    }
}

extension Outcome {
    init(_ raw: Int32) {
        switch raw {
        case Int32(CF_CHECKMATE.rawValue): self = .checkmate
        case Int32(CF_STALEMATE.rawValue): self = .stalemate
        case Int32(CF_DRAW_FIFTY_MOVE.rawValue): self = .fiftyMoveRule
        case Int32(CF_DRAW_REPETITION.rawValue): self = .threefoldRepetition
        case Int32(CF_DRAW_INSUFFICIENT_MATERIAL.rawValue): self = .insufficientMaterial
        default: self = .ongoing
        }
    }
}

/// Lends an array of Swift strings to C as a `const char *const *` for one call.
func withCStrings<Result>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafePointer<CChar>?>?) -> Result
) -> Result {
    func recurse(
        _ index: Int, _ collected: inout [UnsafePointer<CChar>?]
    ) -> Result {
        if index == strings.count {
            return collected.withUnsafeBufferPointer { body($0.baseAddress) }
        }
        return strings[index].withCString { pointer in
            collected.append(pointer)
            return recurse(index + 1, &collected)
        }
    }
    var collected: [UnsafePointer<CChar>?] = []
    collected.reserveCapacity(strings.count)
    return recurse(0, &collected)
}
