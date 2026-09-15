/// The two squares a move went between, which is all a board needs to know about it to
/// show it: which square to light up, and which piece travelled where.
public struct MoveSquares: Hashable, Sendable {
    public let from: Square
    public let to: Square

    public init(from: Square, to: Square) {
        self.from = from
        self.to = to
    }

    /// Reads the first four characters of a UCI move, which is the only part that says
    /// where the piece went.
    public init?(uci: String) {
        let characters = Array(uci)
        guard characters.count >= 4,
              let from = Square(String(characters[0...1])),
              let to = Square(String(characters[2...3]))
        else { return nil }
        self.init(from: from, to: to)
    }

    public var squares: Set<Square> { [from, to] }
}

/// A placement whose pieces keep their identity from one position to the next.
///
/// A FEN says which pieces stand where and nothing about which piece is which, so a board
/// drawn straight from one can only ever cut to the next position: the knight that moved
/// did not move, it stopped existing on one square and started existing on another. To
/// animate a move, each piece needs to be a thing that persists — and working out which
/// piece is which is where the chess creeps in. A castle moves two pieces at once. A
/// promotion is the same piece arriving as a different one. A capture is two pieces on one
/// square, one of which is leaving for good.
///
/// So this is told the move as well as the new placement, and the new placement always
/// wins: identities are a way of getting from one truth to the next, never a truth of their
/// own. Anything the reconciliation cannot account for is simply replaced, which shows up
/// as a piece appearing rather than as a wrong piece sliding.
public struct TrackedPlacement: Hashable, Sendable {
    public struct Item: Hashable, Sendable, Identifiable {
        public let id: Int
        public internal(set) var piece: Piece
        public internal(set) var square: Square
    }

    public private(set) var items: [Item] = []
    private var nextID = 0

    public init() {}

    public init(_ placement: [Square: Piece]) {
        settle(to: placement)
    }

    /// The pieces indexed by where they stand, for anything that wants the plain answer.
    public var placement: [Square: Piece] {
        Dictionary(items.map { ($0.square, $0.piece) }, uniquingKeysWith: { first, _ in first })
    }

    /// Replaces everything, keeping no identities — for a board that has just appeared, or
    /// one that has jumped somewhere unrelated.
    public mutating func settle(to placement: [Square: Piece]) {
        items = []
        for square in placement.keys.sorted(by: { $0.index < $1.index }) {
            guard let piece = placement[square] else { continue }
            items.append(Item(id: claimID(), piece: piece, square: square))
        }
    }

    /// Moves what can be moved, and creates only what has to be created.
    public mutating func update(to placement: [Square: Piece], moved: MoveSquares? = nil) {
        var working = items

        if let moved, moved.from != moved.to,
            let moverID = working.first(where: { $0.square == moved.from })?.id
        {
            // Whatever stood on the destination has been taken, and must go before the
            // mover arrives — otherwise two pieces claim one square and the reconciliation
            // below has to guess which is real.
            working.removeAll { $0.square == moved.to }

            // The mover is found again afterwards, and by identity rather than by position:
            // taking a piece off shifts everything tracked after it along, so an index from
            // before the removal can be pointing at the wrong piece by now — or past the end,
            // which is a crash rather than a wrong animation. Pieces are tracked in the order
            // they were first seen, so this happens whenever the captured piece was seen
            // first, which is most of the time for one side and none of it for the other.
            if let index = working.firstIndex(where: { $0.id == moverID }) {
                let mover = working[index].piece
                working[index].square = moved.to
                // A promotion is the same piece arriving as a different one, so the identity
                // travels and only the drawing changes.
                if let arrived = placement[moved.to], arrived.colour == mover.colour {
                    working[index].piece = arrived
                }

                // Castling moves two pieces, and only the king's half is in the UCI move. The
                // rook is wherever it has to have come from for the placement to be true.
                if mover.kind == .king, abs(moved.to.file - moved.from.file) > 1 {
                    let isShort = moved.to.file > moved.from.file
                    let rookFrom = Square(file: isShort ? 7 : 0, rank: moved.from.rank)
                    let rookTo = Square(file: isShort ? 5 : 3, rank: moved.from.rank)
                    if let rook = working.firstIndex(where: { $0.square == rookFrom }) {
                        working[rook].square = rookTo
                    }
                }
            }
        }

        // The placement is the truth; these identities are only a way of reaching it.
        var leftover = working
        var kept: [Item] = []
        var unmatched: [(square: Square, piece: Piece)] = []

        for square in placement.keys.sorted(by: { $0.index < $1.index }) {
            guard let piece = placement[square] else { continue }
            if let index = leftover.firstIndex(where: { $0.square == square && $0.piece == piece }) {
                kept.append(leftover.remove(at: index))
            } else {
                unmatched.append((square: square, piece: piece))
            }
        }

        // Anything left unaccounted for takes the nearest spare piece of its own kind. This
        // is what makes stepping backwards through a game animate instead of flickering: the
        // pieces that have to move are matched to the ones that did.
        for entry in unmatched {
            let candidates = leftover.indices.filter { leftover[$0].piece == entry.piece }
            if let index = candidates.min(by: {
                distance(leftover[$0].square, entry.square) < distance(leftover[$1].square, entry.square)
            }) {
                var item = leftover.remove(at: index)
                item.square = entry.square
                kept.append(item)
            } else {
                kept.append(Item(id: claimID(), piece: entry.piece, square: entry.square))
            }
        }

        // Whatever is still in `leftover` has been captured or edited away, and is dropped.
        items = kept.sorted { $0.id < $1.id }
    }

    private func distance(_ one: Square, _ other: Square) -> Int {
        max(abs(one.file - other.file), abs(one.rank - other.rank))
    }

    private mutating func claimID() -> Int {
        defer { nextID += 1 }
        return nextID
    }
}
