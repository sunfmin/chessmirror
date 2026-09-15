import Foundation

// What the domain's own values are called on screen. The values live in this package's types and
// in CONTEXT.md; this is only how each of them is said — in whichever language the app is
// currently speaking (docs/adr/0019).
//
// One file rather than one extension per type, and in the package rather than in the app,
// because several of these are said by the package itself: a library row names where its game
// came from, a habit names the move quality behind it, and a screen would have no way to ask.

extension PieceColour {
    public var label: String { localized(self == .white ? "colour.white" : "colour.black") }
}

extension PieceKind {
    public var label: String {
        switch self {
        case .pawn: localized("piece.pawn")
        case .knight: localized("piece.knight")
        case .bishop: localized("piece.bishop")
        case .rook: localized("piece.rook")
        case .queen: localized("piece.queen")
        case .king: localized("piece.king")
        }
    }
}

extension Controller {
    public var label: String { localized(self == .hand ? "controller.hand" : "controller.engine") }
}

extension Outcome {
    public var label: String {
        switch self {
        case .ongoing: localized("outcome.ongoing")
        case .checkmate: localized("outcome.checkmate")
        case .stalemate: localized("outcome.stalemate")
        case .fiftyMoveRule: localized("outcome.fiftyMove")
        case .threefoldRepetition: localized("outcome.threefold")
        case .insufficientMaterial: localized("outcome.insufficientMaterial")
        }
    }
}

extension ThinkingTime {
    /// On a chip, under a row whose title already says what the number is about.
    public var label: String {
        switch self {
        case .mirrored: localized("time.mirrored")
        case .fixed(let seconds): localized("time.fixed", plural: seconds)
        }
    }
}

extension FENIssue {
    /// Said as advice rather than as a diagnosis: the player is looking at a board they can fix,
    /// so each of these should name the fix.
    public var label: String {
        switch self {
        case .malformed: localized("fen.malformed")
        case .badPieceCharacter: localized("fen.badPieceCharacter")
        case .badRankWidth: localized("fen.badRankWidth")
        case .badRankCount: localized("fen.badRankCount")
        case .tooManyPieces: localized("fen.tooManyPieces")
        case .tooManyPawns: localized("fen.tooManyPawns")
        case .missingKing: localized("fen.missingKing")
        case .extraKing: localized("fen.extraKing")
        case .pawnOnBackRank: localized("fen.pawnOnBackRank")
        case .badSideToMove: localized("fen.badSideToMove")
        case .badCastling: localized("fen.badCastling")
        case .castlingWithoutRook: localized("fen.castlingWithoutRook")
        case .castlingWithoutKing: localized("fen.castlingWithoutKing")
        case .badEnPassant: localized("fen.badEnPassant")
        case .badClock: localized("fen.badClock")
        case .sideNotToMoveInCheck: localized("fen.sideNotToMoveInCheck")
        }
    }
}

extension Game {
    /// Who is on the clock, said as a state rather than as an instruction.
    public var turn: String {
        switch state.outcome {
        case .ongoing: localized("game.toMove", state.sideToMove.label)
        case .checkmate: localized("game.checkmated", state.sideToMove.opposite.label)
        default: state.outcome.label
        }
    }
}

extension Set where Element == Square {
    /// The one line the app says about squares the camera was not sure of — nil when it was sure
    /// of every square it read. The game screen and the editor used to each own this line, byte
    /// for byte.
    public var shakySummary: String? {
        isEmpty ? nil : localized("board.shaky", plural: count)
    }
}

extension Sequence where Element == Square {
    /// A few squares, listed the way the language being spoken lists things.
    var listed: String {
        map(\.description).joined(separator: localized("list.separator"))
    }
}
