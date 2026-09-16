import CStockfish

/// What kind of piece, using Stockfish's own numbering so nothing is renumbered at the
/// bridge.
public enum PieceKind: Int32, Hashable, Sendable, CaseIterable {
    case pawn = 1, knight, bishop, rook, queen, king

    /// What this piece is called, for a sentence with a piece in it. In the package rather than
    /// in the app because the package writes those sentences — an Intent's verdict, a square's
    /// reading — and two copies of six words are two copies that drift.
    public var name: String {
        switch self {
        case .pawn: "兵"
        case .knight: "马"
        case .bishop: "象"
        case .rook: "车"
        case .queen: "后"
        case .king: "王"
        }
    }

    /// The letter SAN and FEN use for a white piece of this kind.
    public var letter: Character {
        switch self {
        case .pawn: "P"
        case .knight: "N"
        case .bishop: "B"
        case .rook: "R"
        case .queen: "Q"
        case .king: "K"
        }
    }
}

public struct Piece: Hashable, Sendable {
    public let colour: PieceColour
    public let kind: PieceKind

    public init(colour: PieceColour, kind: PieceKind) {
        self.colour = colour
        self.kind = kind
    }

    /// FEN glyph: uppercase for white, lowercase for black.
    public var glyph: Character {
        colour == .white ? kind.letter : Character(kind.letter.lowercased())
    }

    public init?(glyph: Character) {
        let colour: PieceColour = glyph.isLowercase ? .black : .white
        switch Character(glyph.uppercased()) {
        case "P": self.init(colour: colour, kind: .pawn)
        case "N": self.init(colour: colour, kind: .knight)
        case "B": self.init(colour: colour, kind: .bishop)
        case "R": self.init(colour: colour, kind: .rook)
        case "Q": self.init(colour: colour, kind: .queen)
        case "K": self.init(colour: colour, kind: .king)
        default: return nil
        }
    }
}

/// A legal move in some position, with everything SAN and the board view need to know
/// about it already answered by the engine.
///
/// `to` is where the piece lands *as the player sees it* — g1 for a short castle, not the
/// rook's square Stockfish encodes internally — so a tap on the board can be matched
/// against it directly.
public struct Move: Hashable, Sendable {
    public let from: Square
    public let to: Square
    public let piece: PieceKind
    public let promotion: PieceKind?
    public let isCapture: Bool
    public let isEnPassant: Bool
    public let isCastling: Bool
    public let givesCheck: Bool
    public let isCheckmate: Bool
    /// The move in UCI notation, which is the only form the bridge accepts back.
    public let uci: String

    init?(_ raw: CfMove) {
        guard let from = Square(index: Int(raw.from)),
              let to = Square(index: Int(raw.to)),
              let piece = PieceKind(rawValue: raw.piece)
        else { return nil }
        self.from = from
        self.to = to
        self.piece = piece
        self.promotion = PieceKind(rawValue: raw.promotion)
        self.isCapture = raw.isCapture
        self.isEnPassant = raw.isEnPassant
        self.isCastling = raw.isCastling
        self.givesCheck = raw.givesCheck
        self.isCheckmate = raw.isCheckmate
        self.uci = withUnsafeBytes(of: raw.uci) { bytes in
            String(decoding: Array(bytes.prefix(while: { $0 != 0 })), as: UTF8.self)
        }
    }

    /// True when the move castles towards the h-file.
    public var isShortCastling: Bool { isCastling && to.file > from.file }
}
