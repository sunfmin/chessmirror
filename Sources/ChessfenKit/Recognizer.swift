/// Which side is at the bottom of the picture.
public enum Orientation: String, Hashable, Sendable, CaseIterable {
    case whiteAtBottom = "white"
    case blackAtBottom = "black"

    /// The board turned so `colour` faces the person looking at it.
    public static func facing(_ colour: PieceColour) -> Orientation {
        colour == .white ? .whiteAtBottom : .blackAtBottom
    }
}

/// How to fill in the castling field, which a picture cannot actually show.
public enum CastlingGuess: String, Hashable, Sendable, CaseIterable {
    /// Grant rights wherever a king and rook still sit on their home squares.
    case fromHomeSquares = "auto"
    case none = "none"
}

/// The recognised Position plus the evidence behind it.
public struct Recognition: Sendable {
    public let fen: String
    /// The picture the reading was actually taken from — rectified and scaled, if it had
    /// to be. `rect` and the Shaky Squares are in *its* coordinates, so an overlay drawn
    /// over this image lines up.
    public let image: RGBImage
    public let rect: BoardRect
    public let orientation: Orientation
    public let verdicts: [Square: SquareVerdict]
    /// How cleanly the two square colours separated — the same measure that decided the
    /// picture held a board at all.
    public let checkerScore: Double

    /// The Shaky Squares, in board order — the ones worth a human glance.
    public var shaky: [(square: Square, verdict: SquareVerdict)] {
        verdicts
            .filter { !$0.value.confident }
            .sorted { $0.key.index < $1.key.index }
            .map { (square: $0.key, verdict: $0.value) }
    }

    public func piece(at square: Square) -> Piece? { verdicts[square]?.piece }

    /// Just the board, cut out of the picture the reading was taken from.
    ///
    /// Square, and in the same coordinates the Cells were read in — row 0 is the top of the board
    /// as the camera saw it — so laying it under an eight-by-eight board puts each square of the
    /// photograph on the square it was read from. That is what lets the editor show the photograph
    /// *under* the pieces instead of beside them, and it is the only form of the picture worth
    /// keeping: the table around the board answers no question anybody has here.
    public var boardPicture: RGBImage {
        image.cropped(x: rect.left, y: rect.top, width: rect.size, height: rect.size)
    }
}

public enum Recognizer {

    /// Recognises the Position in a board image.
    ///
    /// `turn`, `orientation` and `castling` are Unknowable Fields as far as the picture is
    /// concerned: nothing in it can settle whose move it is. They are answered here so
    /// that the result is a complete FEN, and re-answered by the player at the Confirm
    /// Position screen.
    public static func recognise(
        _ source: RGBImage,
        turn: PieceColour = .white,
        orientation requested: Orientation? = nil,
        castling: CastlingGuess = .fromHomeSquares
    ) throws -> Recognition {
        let image = source.scaled(toLongestSide: Imaging.workingResolution)
        let rect = try BoardGeometry.findBoard(in: image)

        // Every Cell is read before any of them is judged, because what tells a white piece
        // from a black one is how its body compares to the light of the board around it,
        // and that is a fact about the other sixty-three squares.
        var readings: [[SquareReading]] = []
        var backgrounds = Grid<Double>(width: 8, height: 8, repeating: 0)
        for row in 0..<8 {
            var line: [SquareReading] = []
            for column in 0..<8 {
                let reading = SquareReader.read(rect.crop(image, row: row, column: column))
                backgrounds[column, row] = reading.backgroundLuma
                line.append(reading)
            }
            readings.append(line)
        }

        let lighting = BoardLighting(backgrounds: backgrounds)
        let grid = (0..<8).map { row in
            (0..<8).map { column in
                SquareClassifier.classify(
                    readings[row][column], light: lighting.light(row: row, column: column)
                )
            }
        }

        let orientation = requested ?? inferOrientation(grid)
        var verdicts: [Square: SquareVerdict] = [:]
        for row in 0..<8 {
            for column in 0..<8 {
                verdicts[square(row: row, column: column, orientation: orientation)] =
                    grid[row][column]
            }
        }
        return Recognition(
            fen: fen(verdicts, turn: turn, castling: castling),
            image: image,
            rect: rect,
            orientation: orientation,
            verdicts: verdicts,
            checkerScore: BoardGeometry.checkerScore(image.luma, rect)
        )
    }

    /// A checker score this good means the picture needs no straightening — a screenshot
    /// or a scan, where warping could only make things worse.
    public static let alreadyStraightScore = 6.0

    /// How many candidate quads earn a full refinement.
    public static let quadsRefined = 4

    /// Recognises the Position in a photograph, straightening it first if it needs it.
    ///
    /// The axis-aligned reading is tried first and kept as the thing to beat: a screenshot
    /// arriving through this door is read exactly as it would have been through the other
    /// one, and never rectified on spec. Only a picture that reads poorly — or not at all —
    /// pays for the search over quads.
    public static func recognise(
        photograph source: RGBImage,
        turn: PieceColour = .white,
        orientation requested: Orientation? = nil,
        castling: CastlingGuess = .fromHomeSquares
    ) async throws -> Recognition {
        let image = source.scaled(toLongestSide: Imaging.workingResolution)
        let direct = try? recognise(
            image, turn: turn, orientation: requested, castling: castling
        )
        if let direct, direct.checkerScore >= alreadyStraightScore { return direct }

        // Refining is a descent per quad, so only the most promising few earn one. Their
        // unrefined scores are cheap and rank them well enough to choose.
        let candidates = await PerspectiveCorrection.candidates(in: image)
            .map { (quad: $0, score: PerspectiveCorrection.score($0, in: image)) }
            .sorted { $0.score > $1.score }
            .prefix(quadsRefined)

        var best = direct
        for candidate in candidates {
            let refined = PerspectiveCorrection.refined(candidate.quad, in: image)
            guard refined.score > (best?.checkerScore ?? 0),
                  let rectified = PerspectiveCorrection.rectified(image, quad: refined.quad),
                  let candidate = try? recognise(
                      rectified, turn: turn, orientation: requested, castling: castling
                  ),
                  candidate.checkerScore > (best?.checkerScore ?? 0)
            else { continue }
            best = candidate
        }
        guard let best else { throw RecognitionError.boardNotFound }
        return best
    }

    /// Maps a grid Cell (row 0 = top of the picture) to a board square.
    public static func square(row: Int, column: Int, orientation: Orientation) -> Square {
        switch orientation {
        case .whiteAtBottom: Square(file: column, rank: 7 - row)
        case .blackAtBottom: Square(file: 7 - column, rank: row)
        }
    }

    /// Guesses which side is at the bottom from where each colour's pieces sit.
    ///
    /// A flip is a point reflection, so it preserves every rule of chess — no legality
    /// check can tell the two readings apart. What does lean one way is that armies
    /// advance from their own side: the colour whose pieces sit lower in the picture is
    /// almost always the colour playing up the board. Ties go to white at the bottom, by
    /// far the common case, and the player can say otherwise at the Confirm Position
    /// screen.
    static func inferOrientation(_ grid: [[SquareVerdict]]) -> Orientation {
        var whiteRows: [Int] = [], blackRows: [Int] = []
        for row in 0..<8 {
            for column in 0..<8 {
                guard let piece = grid[row][column].piece else { continue }
                if piece.colour == .white {
                    whiteRows.append(row)
                } else {
                    blackRows.append(row)
                }
            }
        }
        guard !whiteRows.isEmpty, !blackRows.isEmpty else { return .whiteAtBottom }
        let whiteDepth = Double(whiteRows.reduce(0, +)) / Double(whiteRows.count)
        let blackDepth = Double(blackRows.reduce(0, +)) / Double(blackRows.count)
        return whiteDepth >= blackDepth ? .whiteAtBottom : .blackAtBottom
    }

    /// Assembles a FEN from the 64 verdicts.
    ///
    /// The clocks are reset rather than guessed: a picture shows no history, and pretending
    /// otherwise would put a fifty-move draw in reach of a position that never played a
    /// move.
    static func fen(
        _ verdicts: [Square: SquareVerdict],
        turn: PieceColour,
        castling: CastlingGuess
    ) -> String {
        var placement: [String] = []
        for rank in stride(from: 7, through: 0, by: -1) {
            var line = ""
            var empties = 0
            for file in 0..<8 {
                let square = Square(file: file, rank: rank)
                if let piece = verdicts[square]?.piece {
                    if empties > 0 {
                        line += "\(empties)"
                        empties = 0
                    }
                    line.append(piece.glyph)
                } else {
                    empties += 1
                }
            }
            if empties > 0 { line += "\(empties)" }
            placement.append(line)
        }
        let rights = castlingField(verdicts, castling)
        return "\(placement.joined(separator: "/")) \(turn == .white ? "w" : "b") \(rights) - 0 1"
    }

    private static func castlingField(
        _ verdicts: [Square: SquareVerdict], _ castling: CastlingGuess
    ) -> String {
        guard castling == .fromHomeSquares else { return "-" }
        let rights: [(flag: Character, king: String, rook: String, colour: PieceColour)] = [
            ("K", "e1", "h1", .white), ("Q", "e1", "a1", .white),
            ("k", "e8", "h8", .black), ("q", "e8", "a8", .black),
        ]
        let granted = rights.filter { right in
            guard let kingSquare = Square(right.king), let rookSquare = Square(right.rook)
            else { return false }
            return verdicts[kingSquare]?.piece == Piece(colour: right.colour, kind: .king)
                && verdicts[rookSquare]?.piece == Piece(colour: right.colour, kind: .rook)
        }
        return granted.isEmpty ? "-" : String(granted.map(\.flag))
    }
}
