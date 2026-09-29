import Foundation

/// One time a game reached a position a 收藏集 keeps: which game, and where in it.
///
/// A 藏局 is the position (docs/adr/0051), exactly as a 错题 is; this is an occasion of it, so a
/// position reached in three games is one 藏局 with three of these.
public struct Sighting: Hashable, Sendable, Identifiable {
    public let game: URL
    /// The position after this many moves — the Ply to open the game at to see it.
    public let ply: Int
    /// When the game was played, as the file says.
    public let when: Date
    /// Whether the side to move there was the player's own. 「你的机会」 when it was, 「对方的
    /// 机会」 when the shot was the opponent's; nil for a game with no side of the player's in it.
    public let isYours: Bool?

    public var id: String { "\(game.absoluteString)#\(ply)" }

    public init(game: URL, ply: Int, when: Date, isYours: Bool? = nil) {
        self.game = game
        self.ply = ply
        self.when = when
        self.isYours = isYours
    }
}

/// One position in a 收藏集, with the games it was reached in (CONTEXT.md, 藏局).
public struct Holding: Identifiable, Hashable, Sendable {
    public let position: PositionKey
    /// Every game it was reached in, newest first. Empty for a position a 自建集 was given from
    /// a board with no game behind it.
    public let sightings: [Sighting]
    /// When it came into the set: put there by the heart, or first found in a game. What the
    /// set's list is ordered by, newest first.
    public let added: Date

    public var id: String { position.text }

    public init(position: PositionKey, sightings: [Sighting], added: Date? = nil) {
        self.position = position
        self.sightings = sightings.sorted { $0.when > $1.when }
        self.added = added ?? sightings.map(\.when).max() ?? .distantPast
    }
}

/// Which 收藏集: one of the two the games fill, or one the player made (docs/adr/0051).
public enum CollectionKind: Hashable, Sendable {
    /// 自动集 — 杀招 or 战术, named after the deck's card of the same name.
    case found(Deck.Card)
    /// 自建集, by the name the player gave it.
    case player(String)

    /// 喜爱 — the 自建集 that is always there and where the heart puts a position.
    public static let favourites = CollectionKind.player(PlayerCollection.favouritesName)

    public var isFound: Bool { if case .found = self { true } else { false } }
    public var isFavourites: Bool { self == .favourites }

    /// The name on the row. A found set is called what its card is called; 喜爱 is spelt in the
    /// app's language, while every other name is the player's own and is not translated.
    public var title: String {
        switch self {
        case .found(let card): card.title
        case .player(let name):
            name == PlayerCollection.favouritesName ? localized("collection.favourites") : name
        }
    }
}

/// A 收藏集 as a screen reads it: which one, and its 藏局 newest first.
public struct PositionCollection: Identifiable, Hashable, Sendable {
    public let kind: CollectionKind
    public let holdings: [Holding]

    public var id: CollectionKind { kind }

    public init(kind: CollectionKind, holdings: [Holding]) {
        self.kind = kind
        self.holdings = holdings.sorted {
            $0.added == $1.added ? $0.position.text < $1.position.text : $0.added > $1.added
        }
    }

    public subscript(position: PositionKey) -> Holding? {
        holdings.first { $0.position == position }
    }

    /// The 藏局 after this one, round to the first: a pick from the list is 计划外 and walks the
    /// list, never a schedule (docs/adr/0032). Nil in a set of one.
    public func next(after position: PositionKey) -> PositionKey? {
        guard let here = holdings.firstIndex(where: { $0.position == position }),
            holdings.count > 1
        else { return holdings.first { $0.position != position }?.position }
        return holdings[(here + 1) % holdings.count].position
    }
}

// ---------------------------------------------------------------------- 自动集

/// 杀招 and 战术 as the games show them: where the side to move had a shot (docs/adr/0051).
///
/// **Read off what the app already wrote, and nothing else.** Every judged move carries the Score
/// of the position it made — a Review's, or the 细判 that weighed it as it landed — and that is
/// enough to tell where a shot appeared: no engine runs here, so a library is sorted into its sets
/// as cheaply as it is sorted into its 错题. A position nobody has scored is in neither set, which
/// is the same refusal the book makes about an unreviewed game (docs/adr/0044).
public enum FoundShots {
    /// How much 胜率 the move before has to have handed over for the position it made to count as
    /// a 战术: the band that names a move at all, which is also where the 记录线 ships — a move
    /// worth writing down is a gift worth keeping. Measured before it was set: forty games of the
    /// player's own kept eleven 战术 at this line and three at twenty, because a game under 把关
    /// gives little away on either side.
    public static let giftFrom = MoveQuality.inaccuracyFrom
    /// How well the side to move has to stand once the gift is in, in 胜率: a gift that only
    /// brings a lost game back to level is the opponent missing *their* shot, not this side having
    /// one.
    public static let standingFrom = 60.0
    /// The longest mate kept in 杀招, in moves. Past this an engine's mate is a calculation, not
    /// a pattern anybody is asked to see over the board.
    public static let mateWithin = 5

    /// Every shot in one game, as the card it belongs under, the position, and the occasion.
    ///
    /// Walked forward once, like the book's own walk, rather than rewound per position.
    public static func sightings(
        in entry: GameLibrary.Entry
    ) -> [(card: Deck.Card, position: PositionKey, sighting: Sighting)] {
        guard let pgn = entry.pgn else { return [] }
        let game = pgn.game
        let hands = pgn.handColours
        guard var walked = game.rewound(to: 0) else { return [] }
        var found: [(Deck.Card, PositionKey, Sighting)] = []
        for (index, ply) in game.plies.enumerated() {
            guard walked.apply(uci: ply.uci) else { break }
            let number = index + 1
            guard let card = shot(in: game, atPly: number, reached: walked),
                let key = PositionKey(fen: walked.state.fen)
            else { continue }
            let side = walked.state.sideToMove
            found.append(
                (
                    card, key,
                    Sighting(
                        game: entry.url, ply: number, when: entry.when,
                        isYours: hands.isEmpty ? nil : hands.contains(side)
                    )
                )
            )
        }
        return found
    }

    /// Which card the position after `ply` moves is dealt, if either.
    ///
    /// - **杀招**: the side to move mates within `mateWithin`, and could not already before the
    ///   move that led here — a mating attack is one 杀招, where the mate first became there, and
    ///   not one per move of it.
    /// - **战术**: the move before handed over at least `giftFrom`, the side to move now stands at
    ///   `standingFrom` or better, and the win is not simply taking something loose: a position
    ///   where a capture already wins material by exchange is 「白吃」, and not kept.
    static func shot(in game: Game, atPly ply: Int, reached: Game) -> Deck.Card? {
        guard !reached.state.outcome.isOver, let score = score(of: game, atPly: ply) else {
            return nil
        }
        let side = reached.state.sideToMove
        if let moves = mate(for: side, in: score) {
            guard moves <= mateWithin else { return nil }
            if let before = self.score(of: game, atPly: ply - 1), mate(for: side, in: before) != nil {
                return nil
            }
            return .mate
        }
        guard let gift = game.cost(atPly: ply), gift >= giftFrom else { return nil }
        let standing = side == .white ? score.winPercent : 100 - score.winPercent
        guard standing >= standingFrom, !hasFreeCapture(in: reached) else { return nil }
        return .tactics
    }

    /// The Score of the position after `ply` moves, by whatever measured it: the Review's number
    /// when there is one, else the judgement written on the move that made it.
    static func score(of game: Game, atPly ply: Int) -> Score? {
        if let reviewed = game.reviewScore(atPly: ply) { return reviewed }
        guard ply > 0, game.plies.indices.contains(ply - 1) else { return nil }
        return game.plies[ply - 1].judgement?.score
    }

    /// In how many moves `side` mates, when the Score says it does.
    static func mate(for side: PieceColour, in score: Score) -> Int? {
        guard case .mate(let moves) = score else { return nil }
        let mine = side == .white ? moves : -moves
        return mine > 0 ? mine : nil
    }

    /// Whether some capture for the side to move wins material by exchange on its own square.
    static func hasFreeCapture(in game: Game) -> Bool {
        let moves = game.uciMoves
        return game.state.legalMoves.contains { move in
            move.isCapture
                && Rules.exchangeValue(startFEN: game.startFEN, moves: moves, uci: move.uci)
                    == .winning
        }
    }

    /// The two 自动集 from shots already walked, the taken-out left out. A set with nothing in it
    /// is still returned — whether an empty one is shown is the screen's question.
    public static func collections(
        of found: [(card: Deck.Card, position: PositionKey, sighting: Sighting)],
        takenOut: Set<PositionKey> = []
    ) -> [PositionCollection] {
        Deck.Card.catalogue.map { card in
            var byPosition: [PositionKey: [Sighting]] = [:]
            for shot in found where shot.card == card && !takenOut.contains(shot.position) {
                byPosition[shot.position, default: []].append(shot.sighting)
            }
            return PositionCollection(
                kind: .found(card),
                holdings: byPosition.map { Holding(position: $0.key, sightings: $0.value) }
            )
        }
    }
}

// ---------------------------------------------------------------------- 自建集

/// One 自建集 as it is kept: a name and the positions in it, in one PGN file (docs/adr/0051).
///
/// A PGN because the library is PGN (docs/adr/0010): one entry per position, each a game that
/// starts from it and has no moves, so any chess program opens the file as a list of positions.
/// Where the position came from rides in tags of this app's own, which PGN allows.
public struct PlayerCollection: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public let position: PositionKey
        public let added: Date
        /// The game the position was taken from and the Ply it stood at, when it came from one.
        public let game: String?
        public let ply: Int?

        public init(position: PositionKey, added: Date, game: String? = nil, ply: Int? = nil) {
            self.position = position
            self.added = added
            self.game = game
            self.ply = ply
        }
    }

    public var name: String
    public var entries: [Entry]

    /// The file name 喜爱 is kept under. Not the word on the screen, which follows the language:
    /// the file has to be the same file whatever the app is speaking.
    public static let favouritesName = "Favourites"

    public init(name: String, entries: [Entry] = []) {
        self.name = name
        self.entries = entries
    }

    public func contains(_ position: PositionKey) -> Bool {
        entries.contains { $0.position == position }
    }

    // ------------------------------------------------------------------ the file

    static let addedTag = "Added"
    static let gameTag = "SourceGame"
    static let plyTag = "SourcePly"

    /// The file's text: one moveless game per position, oldest first.
    public var pgnText: String {
        entries.map { entry in
            var tags: [(String, String)] = [
                ("Event", name),
                ("SetUp", "1"),
                ("FEN", entry.position.text + " 0 1"),
                (Self.addedTag, entry.added.ISO8601Format()),
            ]
            if let game = entry.game { tags.append((Self.gameTag, game)) }
            if let ply = entry.ply { tags.append((Self.plyTag, String(ply))) }
            let head = tags.map { "[\($0.0) \"\(Self.escaped($0.1))\"]" }.joined(separator: "\n")
            return head + "\n\n*\n"
        }.joined(separator: "\n")
    }

    /// Reads a file written by `pgnText`, or any PGN whose games carry a `[FEN]`: each game is
    /// one position, and a game without one is skipped rather than failing the file.
    public init(name: String, pgnText: String) {
        self.name = name
        var entries: [Entry] = []
        var tags: [String: String] = [:]
        func close() {
            if let fen = tags["FEN"], let key = PositionKey(fen: fen),
                !entries.contains(where: { $0.position == key })
            {
                entries.append(
                    Entry(
                        position: key,
                        added: tags[Self.addedTag].flatMap { try? Date($0, strategy: .iso8601) }
                            ?? .distantPast,
                        game: tags[Self.gameTag],
                        ply: tags[Self.plyTag].flatMap { Int($0) }
                    )
                )
            }
            tags = [:]
        }
        for raw in pgnText.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]"),
                let space = line.firstIndex(of: " ")
            {
                let key = String(line[line.index(after: line.startIndex)..<space])
                var value = line[line.index(after: space)..<line.index(before: line.endIndex)]
                    .trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                if key == "Event", !tags.isEmpty { close() }
                tags[key] = value.replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            } else if !line.isEmpty, !tags.isEmpty {
                close()
            }
        }
        if !tags.isEmpty { close() }
        self.entries = entries
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

}

/// The 自建集 on disk: a folder of PGN files beside the games, one per set (docs/adr/0051).
///
/// Its own folder so the library, which lists the PGNs directly in its folder, never mistakes a
/// set for a game; and inside the library's folder, so it goes to iCloud with the games. 喜爱 is
/// always there: read as empty when its file is not, and written the first time something is put
/// in it.
@Observable @MainActor public final class CollectionShelf {
    public private(set) var collections: [PlayerCollection] = [
        PlayerCollection(name: PlayerCollection.favouritesName)
    ]
    /// Sets iCloud has named but not handed over yet. Not written to until they arrive: a set
    /// written from what this device does not have is a set whose positions are lost.
    public private(set) var arriving: Set<String> = []
    private let folder: GameFolder

    /// The folder under the library's own that the sets are kept in.
    public nonisolated static let folderName = "收藏集"

    public init(folder: GameFolder) {
        self.folder = folder
        reload()
    }

    public convenience init(library: GameLibrary) {
        self.init(folder: library.folder)
    }

    /// Where the sets are, which moves with the library when it moves into iCloud.
    public var directory: URL { folder.url.appending(path: Self.folderName, directoryHint: .isDirectory) }

    /// Reads the folder again: 喜爱 first, then the rest in the order they were made.
    public func reload() {
        let manager = FileManager.default
        let urls = (try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var read: [(PlayerCollection, Date)] = []
        var missing: Set<String> = []
        for url in urls where url.pathExtension.lowercased() == "pgn" {
            let name = url.deletingPathExtension().lastPathComponent
            guard let text = folder.read(at: url, { try? String(contentsOf: $0, encoding: .utf8) })
            else {
                missing.insert(name)
                continue
            }
            let made = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? .distantPast
            read.append((PlayerCollection(name: name, pgnText: text), made))
        }
        arriving = missing
        let favourites = read.first { $0.0.name == PlayerCollection.favouritesName }?.0
            ?? PlayerCollection(name: PlayerCollection.favouritesName)
        let rest = read
            .filter { $0.0.name != PlayerCollection.favouritesName }
            .sorted { $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 < $1.1 }
            .map(\.0)
        collections = [favourites] + rest
    }

    public var names: [String] { collections.map(\.name) }

    public func collection(named name: String) -> PlayerCollection? {
        collections.first { $0.name == name }
    }

    /// Every set the position is in. The heart is filled when this is not empty.
    public func names(holding position: PositionKey) -> Set<String> {
        Set(collections.filter { $0.contains(position) }.map(\.name))
    }

    public func isKept(_ position: PositionKey) -> Bool {
        collections.contains { $0.contains(position) }
    }

    /// Puts a position in a set, remembering the game and Ply it was taken from. Nothing happens
    /// when it is already there, or when the set is still on its way down from iCloud.
    @discardableResult
    public func add(
        _ position: PositionKey, to name: String, game: URL? = nil, ply: Int? = nil,
        now: Date = Date()
    ) -> Bool {
        guard !arriving.contains(name), var set = collection(named: name), !set.contains(position)
        else { return false }
        set.entries.append(
            .init(position: position, added: now, game: game?.lastPathComponent, ply: ply)
        )
        return save(set)
    }

    /// Takes a position out of one set.
    @discardableResult
    public func remove(_ position: PositionKey, from name: String) -> Bool {
        guard !arriving.contains(name), var set = collection(named: name), set.contains(position)
        else { return false }
        set.entries.removeAll { $0.position == position }
        return save(set)
    }

    /// Makes a new, empty set. False for a name that is empty, taken, or cannot be a file name.
    @discardableResult
    public func create(_ name: String) -> Bool {
        let name = Self.cleaned(name)
        guard Self.isUsable(name), collection(named: name) == nil, !arriving.contains(name) else {
            return false
        }
        return save(PlayerCollection(name: name))
    }

    /// Renames a set. 喜爱 cannot be renamed; nor can a set take a name already in use.
    @discardableResult
    public func rename(_ name: String, to newName: String) -> Bool {
        let newName = Self.cleaned(newName)
        guard name != PlayerCollection.favouritesName, Self.isUsable(newName),
            collection(named: newName) == nil, !arriving.contains(newName),
            var set = collection(named: name)
        else { return false }
        set.name = newName
        guard save(set) else { return false }
        folder.remove(url(for: name))
        reload()
        return true
    }

    /// Deletes a set. 喜爱 cannot be deleted. The positions go with it; the games and the 错题
    /// they are do not.
    @discardableResult
    public func delete(_ name: String) -> Bool {
        guard name != PlayerCollection.favouritesName, collection(named: name) != nil else {
            return false
        }
        folder.remove(url(for: name))
        reload()
        return true
    }

    /// The set as a screen reads it, with the game each position was taken from.
    public func positionCollection(named name: String, in library: GameLibrary) -> PositionCollection? {
        guard let set = collection(named: name) else { return nil }
        return PositionCollection(
            kind: .player(name),
            holdings: set.entries.map { entry in
                let sighting = entry.game.flatMap { file -> Sighting? in
                    guard let ply = entry.ply else { return nil }
                    let url = library.directory.appending(path: file).resolvingSymlinksInPath()
                    let game = library.entry(at: url)
                    let hands = game?.pgn?.handColours ?? []
                    return Sighting(
                        game: url, ply: ply, when: game?.when ?? entry.added,
                        isYours: hands.isEmpty ? nil : hands.contains(entry.position.sideToMove)
                    )
                }
                return Holding(
                    position: entry.position, sightings: sighting.map { [$0] } ?? [],
                    added: entry.added
                )
            }
        )
    }

    private func url(for name: String) -> URL {
        directory.appending(path: name + ".pgn")
    }

    private func save(_ set: PlayerCollection) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard folder.write(Data(set.pgnText.utf8), to: url(for: set.name)) else { return false }
        reload()
        return true
    }

    static func cleaned(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A name a set can have: something, short enough for a row, and a file name on every system
    /// the library travels to. The file name 喜爱 is kept under is not free for another set.
    static func isUsable(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40 && !name.contains("/") && !name.contains(":")
            && !name.hasPrefix(".") && name != PlayerCollection.favouritesName
    }
}
