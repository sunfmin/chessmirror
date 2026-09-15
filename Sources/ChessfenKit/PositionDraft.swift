import Foundation

/// A Position being edited, rather than one being played from.
///
/// This is what the Confirm Position gate hands the player (docs/adr/0008): a recognised
/// placement they can correct square by square, plus the Unknowable Fields no picture
/// could have shown them. It exists because a FEN string is a terrible thing to edit and a
/// half-edited one is often invalid — a draft is always well formed, even when the
/// position it describes is not yet legal, and says so through `verdict`.
///
/// Edits are kept coherent as they happen. Lift the white king off e1 and the castling
/// rights that depended on it go with it; move a pawn and an en passant square that could
/// no longer have arisen is dropped. The alternative is a gate that accepts an edit and
/// then refuses the position for a reason the player did not cause.
public struct PositionDraft: Hashable, Sendable {
    public var pieces: [Square: Piece]
    /// Changing this tidies as an edit does: an en passant square belongs to one side's
    /// last move, so handing the move to the other side takes the claim with it.
    public var sideToMove: PieceColour {
        didSet { tidy() }
    }
    /// FEN's castling letters: `K`, `Q`, `k`, `q`.
    public var castling: Set<Character>
    public var enPassant: Square?
    public var halfmoveClock: Int
    public var fullmoveNumber: Int

    public init(
        pieces: [Square: Piece],
        sideToMove: PieceColour = .white,
        castling: Set<Character> = [],
        enPassant: Square? = nil,
        halfmoveClock: Int = 0,
        fullmoveNumber: Int = 1
    ) {
        self.pieces = pieces
        self.sideToMove = sideToMove
        self.castling = castling
        self.enPassant = enPassant
        self.halfmoveClock = halfmoveClock
        self.fullmoveNumber = fullmoveNumber
    }

    /// Reads a FEN into a draft. Only the placement field has to make sense; the rest is
    /// taken as far as it parses and defaulted after that, because a draft's job is to be
    /// editable and a stricter reading here would only mean refusing to show the player
    /// the thing they came to fix.
    public init?(fen: String) {
        let fields = fen.split(separator: " ", omittingEmptySubsequences: true)
        guard let placement = fields.first,
              let pieces = BoardRenderer.placement(String(placement))
        else { return nil }

        self.pieces = pieces
        sideToMove = fields.count > 1 && fields[1] == "b" ? .black : .white
        castling = fields.count > 2 ? Set(fields[2]).intersection(["K", "Q", "k", "q"]) : []
        enPassant = fields.count > 3 ? Square(String(fields[3])) : nil
        halfmoveClock = fields.count > 4 ? Int(fields[4]) ?? 0 : 0
        fullmoveNumber = fields.count > 5 ? Int(fields[5]) ?? 1 : 1
        tidy()
    }

    public var fen: String {
        var ranks: [String] = []
        for rank in stride(from: 7, through: 0, by: -1) {
            var text = ""
            var empty = 0
            for file in 0..<8 {
                if let piece = pieces[Square(file: file, rank: rank)] {
                    if empty > 0 {
                        text += String(empty)
                        empty = 0
                    }
                    text.append(piece.glyph)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { text += String(empty) }
            ranks.append(text)
        }
        let rights = ["K", "Q", "k", "q"].filter { castling.contains(Character($0)) }.joined()
        return [
            ranks.joined(separator: "/"),
            sideToMove == .white ? "w" : "b",
            rights.isEmpty ? "-" : rights,
            enPassant?.description ?? "-",
            String(halfmoveClock),
            String(fullmoveNumber),
        ].joined(separator: " ")
    }

    /// What the engine makes of the draft as it stands — the gate's own answer to "may I
    /// play from this?".
    public var verdict: FENVerdict { Rules.validate(fen: fen) }

    public var isPlayable: Bool { verdict.isUsable }

    /// The Game this draft starts, or nil while it is not yet legal.
    public var game: Game? { Game(startFEN: fen) }

    public mutating func setPiece(_ piece: Piece?, at square: Square) {
        pieces[square] = piece
        tidy()
    }

    public func piece(at square: Square) -> Piece? { pieces[square] }

    /// The castling rights the placement could possibly support: a king at home with a
    /// rook of its own colour on the corner the right names.
    public var possibleCastling: Set<Character> {
        var rights: Set<Character> = []
        for colour in [PieceColour.white, .black] {
            let rank = colour == .white ? 0 : 7
            guard pieces[Square(file: 4, rank: rank)] == Piece(colour: colour, kind: .king)
            else { continue }
            let rook = Piece(colour: colour, kind: .rook)
            if pieces[Square(file: 7, rank: rank)] == rook {
                rights.insert(colour == .white ? "K" : "k")
            }
            if pieces[Square(file: 0, rank: rank)] == rook {
                rights.insert(colour == .white ? "Q" : "q")
            }
        }
        return rights
    }

    /// Every square that could stand as the en passant target, given who is to move and
    /// where the pawns are: the mover's opponent must have just double-stepped a pawn
    /// through it, which means the square and the one behind it are empty and their pawn
    /// stands in front of it.
    ///
    /// Whether anyone can actually make the capture is left to validation. This answers
    /// the narrower question the gate needs: which squares are worth offering at all.
    public var possibleEnPassantSquares: [Square] {
        let opponent = sideToMove.opposite
        // White to move: Black just stepped a pawn from rank 7 to rank 5, so the target
        // sits on rank 6 — rank index 5 — and the pawn is one rank below it.
        let targetRank = opponent == .black ? 5 : 2
        let pawnRank = opponent == .black ? 4 : 3
        let steppedFrom = opponent == .black ? 6 : 1

        return (0..<8).compactMap { file in
            let target = Square(file: file, rank: targetRank)
            guard pieces[target] == nil,
                  pieces[Square(file: file, rank: steppedFrom)] == nil,
                  pieces[Square(file: file, rank: pawnRank)]
                    == Piece(colour: opponent, kind: .pawn)
            else { return nil }
            return target
        }
    }

    /// Grants every castling right the placement supports — the same guess recognition
    /// makes, offered again here because an edit can make a right possible that was not.
    public mutating func grantCastlingFromHomeSquares() {
        castling = possibleCastling
    }

    public mutating func clear() {
        pieces = [:]
        tidy()
    }

    public mutating func reset() {
        self = PositionDraft(fen: PGN.standardStartFEN) ?? self
    }

    /// Drops whatever the placement no longer supports. Called after every edit.
    private mutating func tidy() {
        castling.formIntersection(possibleCastling)
        if let enPassant, !possibleEnPassantSquares.contains(enPassant) {
            self.enPassant = nil
        }
    }
}
