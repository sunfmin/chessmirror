/// One principal variation: the moves the engine expects and the Score they lead to.
public struct Line: Hashable, Sendable, Codable {
    /// White-relative, like every Score in this package.
    public let score: Score
    /// UCI moves from the analysed Position onwards. Never empty for a real Line.
    public let uciMoves: [String]
    /// The same moves in SAN, for showing to a player.
    public let san: [String]

    public var bestMove: String? { uciMoves.first }

    public init(score: Score, uciMoves: [String], san: [String]) {
        self.score = score
        self.uciMoves = uciMoves
        self.san = san
    }
}

/// What the engine reports about a Position at one Depth.
///
/// A snapshot, never a verdict: an Analysis runs unbounded, so a later one at a greater
/// Depth may say something different, and often does. The UI is expected to replace what
/// it is showing each time one of these arrives.
public struct Analysis: Hashable, Sendable, Codable {
    public let depth: Int
    /// How far the search looked down the most forcing lines.
    public let selectiveDepth: Int
    /// Best first. As many as `multiPV` asked for, when the position has that many moves.
    public let lines: [Line]
    public let nodes: UInt64
    public let nodesPerSecond: UInt64
    public let timeMilliseconds: UInt64
    /// Fraction of the transposition table in use, per mille.
    public let hashFull: Int
    /// True when the Depth's search was cut off before its Score was proven, so the
    /// numbers are bounds rather than values. Worth showing, worth not trusting.
    public let isPartial: Bool

    public var best: Line? { lines.first }
    public var bestMove: String? { best?.bestMove }

    /// Everything but the Lines has a default, because everything but the Lines is telemetry.
    /// What builds one of these by hand is a test putting a screen into a state — and a screen
    /// that needed the node count to render would be a screen with a bug in it.
    public init(
        depth: Int,
        selectiveDepth: Int = 0,
        lines: [Line],
        nodes: UInt64 = 0,
        nodesPerSecond: UInt64 = 0,
        timeMilliseconds: UInt64 = 0,
        hashFull: Int = 0,
        isPartial: Bool = false
    ) {
        self.depth = depth
        self.selectiveDepth = max(selectiveDepth, depth)
        self.lines = lines
        self.nodes = nodes
        self.nodesPerSecond = nodesPerSecond
        self.timeMilliseconds = timeMilliseconds
        self.hashFull = hashFull
        self.isPartial = isPartial
    }
}

/// The Analyses a session has already paid for, kept by the position they answer.
///
/// A swipe onto another card of the same position is not a new question, and walking back to a
/// Ply that has already been asked about is not one either — so what a search found is handed
/// back rather than searched for again.
///
/// **Bounded.** It used to be a plain dictionary that grew one entry per position looked at and
/// was never pruned: a long game, or an afternoon of walking a record back and forth, left an
/// Analysis and its candidate Lines in memory for every position the eye had ever been on, for
/// as long as the session lived. Nothing about what the app shows depends on the bound — a miss
/// is a search that runs again, which is what a position nobody has asked about already gets.
struct RecentAnalyses {
    /// How many positions are kept.
    ///
    /// A game's own line is usually shorter than this, so the ordinary case — walking a record
    /// through and back — never evicts anything. It is also small enough that the whole cache is
    /// a few hundred kilobytes: an Analysis is two Lines and their moves.
    static let capacity = 64

    private var byPosition: [String: Analysis] = [:]
    /// The positions held, least recently used first. What goes when the cache is full is the
    /// front of this — the position longest since read or written, which is the one least likely
    /// to be come back to. Walking back and forth over the last few moves, the case the cache
    /// exists for, keeps touching the same few and so keeps all of them.
    private var order: [String] = []

    var count: Int { byPosition.count }

    subscript(fen: String) -> Analysis? {
        mutating get {
            guard let found = byPosition[fen] else { return nil }
            touch(fen)
            return found
        }
        set {
            guard let newValue else {
                byPosition[fen] = nil
                order.removeAll { $0 == fen }
                return
            }
            byPosition[fen] = newValue
            touch(fen)
            while order.count > Self.capacity {
                byPosition[order.removeFirst()] = nil
            }
        }
    }

    private mutating func touch(_ fen: String) {
        order.removeAll { $0 == fen }
        order.append(fen)
    }
}
