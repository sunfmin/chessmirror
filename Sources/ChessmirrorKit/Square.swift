/// A board square, numbered the way Stockfish numbers them: a1 = 0, h1 = 7, a8 = 56.
///
/// The recogniser thinks in image rows and columns, the engine thinks in squares, and
/// keeping the two apart is what stops an Orientation mistake from hiding. Rows and
/// columns belong to `BoardRect`; squares belong here.
public struct Square: Hashable, Sendable, CustomStringConvertible {
    public let index: Int

    public init?(index: Int) {
        guard (0..<64).contains(index) else { return nil }
        self.index = index
    }

    public init(file: Int, rank: Int) {
        precondition((0..<8).contains(file) && (0..<8).contains(rank))
        self.index = rank * 8 + file
    }

    /// Parses algebraic notation, `"e4"`.
    public init?(_ name: String) {
        let characters = Array(name.lowercased().utf8)
        guard characters.count == 2,
              let file = Int(exactly: characters[0]).map({ $0 - 97 }), (0..<8).contains(file),
              let rank = Int(exactly: characters[1]).map({ $0 - 49 }), (0..<8).contains(rank)
        else { return nil }
        self.index = rank * 8 + file
    }

    public var file: Int { index % 8 }
    public var rank: Int { index / 8 }

    public var description: String {
        let fileName = String(UnicodeScalar(UInt8(97 + file)))
        return "\(fileName)\(rank + 1)"
    }
}

/// Which army a piece belongs to, or which side a rule is about.
public enum PieceColour: Hashable, Sendable {
    case white
    case black

    public var opposite: PieceColour { self == .white ? .black : .white }
}
