import CStockfish

/// Why a FEN cannot be used, in the terms the Confirm Position screen needs to explain
/// it — an issue, whose side it is, and which squares to point at.
///
/// This is not a nicety. Stockfish 18 validates nothing: its asserts are compiled out,
/// `square<KING>()` is undefined without exactly one king, and the castling parser hunts
/// for a rook in a loop with no lower bound, walking off the board when the FEN claims a
/// right no rook can support. Nothing reaches the engine unvetted.
public enum FENIssue: Hashable, Sendable {
    case malformed
    case badPieceCharacter
    case badRankWidth
    case badRankCount
    case tooManyPieces
    case tooManyPawns
    case missingKing
    case extraKing
    case pawnOnBackRank
    case badSideToMove
    case badCastling
    case castlingWithoutRook
    case castlingWithoutKing
    case badEnPassant
    case badClock
    /// The side that is *not* to move is in check — which also catches adjacent kings.
    case sideNotToMoveInCheck
}

/// What validation found: `nil` issue means the FEN is usable.
public struct FENVerdict: Hashable, Sendable {
    public let issue: FENIssue?
    public let colour: PieceColour?
    public let squares: [Square]

    public var isUsable: Bool { issue == nil }

    static let usable = FENVerdict(issue: nil, colour: nil, squares: [])
}

public enum Rules {
    /// Vets a FEN before anything is allowed to act on it.
    public static func validate(fen: String) -> FENVerdict {
        let verdict = cf_validate_fen(fen)
        guard let issue = FENIssue(verdict.issue) else { return .usable }

        var squares: [Square] = []
        withUnsafeBytes(of: verdict.squares) { raw in
            for value in raw.bindMemory(to: Int32.self) where value != Int32(CF_NO_SQUARE) {
                if let square = Square(index: Int(value)) { squares.append(square) }
            }
        }
        return FENVerdict(issue: issue, colour: PieceColour(verdict.colour), squares: squares)
    }

    /// Leaf count of the legal move tree `depth` plies below `fen`; 0 if it fails validation.
    ///
    /// Kept in the shipped surface rather than the tests because it is the one number that
    /// proves the vendored engine is linked and generating moves correctly.
    public static func perft(fen: String, depth: Int) -> UInt64 {
        cf_perft(fen, Int32(depth))
    }
}

extension FENIssue {
    init?(_ raw: CfFenIssue) {
        switch raw {
        case CF_FEN_OK: return nil
        case CF_FEN_MALFORMED: self = .malformed
        case CF_FEN_BAD_PIECE_CHAR: self = .badPieceCharacter
        case CF_FEN_BAD_RANK_WIDTH: self = .badRankWidth
        case CF_FEN_BAD_RANK_COUNT: self = .badRankCount
        case CF_FEN_TOO_MANY_PIECES: self = .tooManyPieces
        case CF_FEN_TOO_MANY_PAWNS: self = .tooManyPawns
        case CF_FEN_MISSING_KING: self = .missingKing
        case CF_FEN_EXTRA_KING: self = .extraKing
        case CF_FEN_PAWN_ON_BACK_RANK: self = .pawnOnBackRank
        case CF_FEN_BAD_SIDE_TO_MOVE: self = .badSideToMove
        case CF_FEN_BAD_CASTLING: self = .badCastling
        case CF_FEN_CASTLING_WITHOUT_ROOK: self = .castlingWithoutRook
        case CF_FEN_CASTLING_WITHOUT_KING: self = .castlingWithoutKing
        case CF_FEN_BAD_EN_PASSANT: self = .badEnPassant
        case CF_FEN_BAD_CLOCK: self = .badClock
        case CF_FEN_SIDE_NOT_TO_MOVE_IN_CHECK: self = .sideNotToMoveInCheck
        default: self = .malformed
        }
    }
}

extension PieceColour {
    init?(_ raw: Int32) {
        switch raw {
        case 0: self = .white
        case 1: self = .black
        default: return nil
        }
    }
}
