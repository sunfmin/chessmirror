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

    /// The scoreline of a finished game, as it is printed rather than as PGN writes it
    /// (`resultToken`): `1-0`, `0-1`, `½-½`. Empty while the game is being played.
    public var scoreline: String {
        switch state.outcome {
        case .ongoing: ""
        case .checkmate: state.sideToMove == .white ? "0-1" : "1-0"
        default: "½-½"
        }
    }
}

/// 掉幅 — what a move cost, in percentage points of win probability from the mover's own side
/// (docs/adr/0027) — said the one way the app says it everywhere.
///
/// Whole points, because tenths of a chance are not something a player feels, and the same
/// rounding in a figure and in a sentence, so a tile and the words read out for it never
/// disagree. It used to be spelled at every site: three format strings for the figure, and each
/// sentence rounding for itself.
public enum Drop {
    /// The whole points a 掉幅 rounds to: the number every sentence about it takes.
    public static func points(_ drop: Double) -> Int { Int(drop.rounded()) }

    /// The figure on a chip or a tile: `−25%`.
    public static func figure(_ drop: Double) -> String { "−\(points(drop))%" }

    /// The cost as a clause — 「掉 25%」 — for a sentence about a position or a move.
    public static func cost(_ drop: Double) -> String { localized("book.cost", points(drop)) }
}

/// How deep a search has got, said the one way (docs/adr/0020): 「深度 18」, and 「在算」 while it
/// has reported nothing yet — a depth of nought is not a report. It was spelled at three sites.
public enum Depth {
    public static func label(_ depth: Int) -> String {
        depth > 0 ? localized("game.depth", depth) : localized("noSlips.judging")
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
