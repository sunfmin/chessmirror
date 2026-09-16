import Foundation

/// The 正着榜: the best the player has done at each 棋力, read out of the games (docs/adr/0038).
///
/// One row per rung the player has stood a move at, in ladder order. Each row holds the longest
/// 连正 and the longest 正着数 ever made at that rung, with the game they were made in, and how
/// many moves have stood there in all. Derived and never stored — a game's credits are facts
/// about that game, and the ladder is the sum of them.
public struct Ladder: Hashable, Sendable {
    /// A best, and the game it was made in.
    public struct Best: Hashable, Sendable {
        public let value: Int
        public let game: URL

        public init(value: Int, game: URL) {
            self.value = value
            self.game = game
        }
    }

    public struct Row: Hashable, Sendable, Identifiable {
        public let strength: Strength
        /// The longest 连正 at this rung, in any one game.
        public let longestRun: Best?
        /// The longest 正着数 at this rung, in any one game.
        public let longestDistance: Best?
        /// Every move that stood at this rung, across all games.
        public let stood: Int

        public var id: Strength { strength }

        public init(strength: Strength, longestRun: Best?, longestDistance: Best?, stood: Int) {
            self.strength = strength
            self.longestRun = longestRun
            self.longestDistance = longestDistance
            self.stood = stood
        }
    }

    /// The rows, ladder order, only the rungs with something on them.
    public let rows: [Row]

    public init(rows: [Row]) {
        self.rows = rows.sorted {
            (Strength.ladder.firstIndex(of: $0.strength) ?? .max)
                < (Strength.ladder.firstIndex(of: $1.strength) ?? .max)
        }
    }

    public var isEmpty: Bool { rows.isEmpty }

    public subscript(strength: Strength) -> Row? {
        rows.first { $0.strength == strength }
    }

    // ------------------------------------------------------------------ deriving

    /// What one game puts on one rung.
    public struct Credit: Hashable, Sendable {
        public let strength: Strength
        /// The moves that stood at this rung in this game — the game's 正着数 at the rung.
        public let distance: Int
        /// The longest 连正 at this rung in this game.
        public let longestRun: Int

        public init(strength: Strength, distance: Int, longestRun: Int) {
            self.strength = strength
            self.distance = distance
            self.longestRun = longestRun
        }
    }

    /// One game's credits, one per rung it was played at.
    ///
    /// The player's own moves that stood under 正着, each credited to the rung the engine was on
    /// when it was played (`Game.strength(ofPly:)`). A stretch against a human, or before any
    /// engine move has said what rung it was, is at no rung and is credited nowhere; so are moves
    /// played with 正着 off, which stood under nothing. A 连正 is broken by a 试招, as on the row,
    /// and by a change of rung: a run is a run *at* a 棋力, and a run that crossed from 1400 to
    /// 2800 would belong to neither.
    public static func credits(in entry: GameLibrary.Entry) -> [Credit] {
        guard let pgn = entry.pgn else { return [] }
        return credits(in: pgn.game, by: pgn.handColours)
    }

    public static func credits(in game: Game, by mine: Set<PieceColour>) -> [Credit] {
        var distance: [Strength: Int] = [:]
        var longest: [Strength: Int] = [:]
        var run = 0
        var last: Strength?
        let refusedAt = Set(game.pendingTried.filter { !$0.tries.isEmpty }.map(\.ply))
        for (index, ply) in game.plies.enumerated() where mine.contains(game.mover(ofPly: index + 1)) {
            let rung = game.strength(ofPly: index + 1)
            if rung != last { run = 0 }
            last = rung
            if refusedAt.contains(index) || !ply.tried.isEmpty { run = 0 }
            guard ply.judgement?.stoodUnderNoSlips == true, let rung else { continue }
            distance[rung, default: 0] += 1
            run += 1
            longest[rung] = max(longest[rung] ?? 0, run)
        }
        return distance.map {
            Credit(strength: $0.key, distance: $0.value, longestRun: longest[$0.key] ?? 0)
        }
    }

    /// The ladder from every game's credits, each set under the game it came from.
    public static func sum(_ credits: [(game: URL, credits: [Credit])]) -> Ladder {
        var runs: [Strength: Best] = [:]
        var distances: [Strength: Best] = [:]
        var stood: [Strength: Int] = [:]
        // Oldest URL first on a tie, so the same library gives the same ladder every time.
        for (game, earned) in credits.sorted(by: { $0.game.absoluteString < $1.game.absoluteString }) {
            for credit in earned {
                stood[credit.strength, default: 0] += credit.distance
                if credit.longestRun > (runs[credit.strength]?.value ?? 0) {
                    runs[credit.strength] = Best(value: credit.longestRun, game: game)
                }
                if credit.distance > (distances[credit.strength]?.value ?? 0) {
                    distances[credit.strength] = Best(value: credit.distance, game: game)
                }
            }
        }
        return Ladder(
            rows: stood.map {
                Row(
                    strength: $0.key, longestRun: runs[$0.key], longestDistance: distances[$0.key],
                    stood: $0.value
                )
            }
        )
    }

    public static func derive(from entries: [GameLibrary.Entry]) -> Ladder {
        sum(entries.map { (game: $0.url, credits: credits(in: $0)) })
    }
}
