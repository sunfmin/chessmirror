import Foundation

/// The 错题本, kept up to date without re-deriving the whole library every time a screen opens.
///
/// **A cache and never a third place where something is true** (docs/adr/0029). Everything in it
/// comes from the PGN files and the practice log; it can be thrown away at any moment and rebuilt
/// from those two, and nothing else in the app is allowed to depend on it having survived.
///
/// What it saves is the walk: deriving a game's Encounters means replaying it move by move, which
/// is a rules probe per ply (docs/adr/0003). A hundred games is a few thousand probes, and the
/// book is asked for every time a screen opens. So each game's Encounters are kept under its file
/// and its modification date, and a reload that changed one file re-walks one game.
@Observable @MainActor public final class MistakeIndex {
    /// The book as it stands. Rebuilt in place when the games change or a position is struck off.
    public private(set) var book = MistakeBook(mistakes: [])

    /// How many games the last update actually had to walk. Zero on a reload that changed
    /// nothing, which is the whole point of the cache and the thing a test can hold it to.
    public private(set) var walkedLastTime = 0

    private let log: PracticeLog
    private var lines: JudgementLines
    /// One game's findings, under the file it came from and the date it carried when they were
    /// taken. A file that has been written since is a different game and is walked again.
    private var cached: [URL: (modified: Date, found: [(PositionKey, Encounter)])] = [:]

    public init(log: PracticeLog = .standard, lines: JudgementLines = .standard) {
        self.log = log
        self.lines = lines
    }

    /// Brings the book into line with a set of games, walking only what has changed.
    public func update(from entries: [GameLibrary.Entry], lines: JudgementLines? = nil) {
        if let lines, lines != self.lines {
            // A moved line changes which moves count, so nothing cached under the old one is
            // usable. Cheaper to say so than to remember which findings were near the edge.
            self.lines = lines
            cached = [:]
        }
        var walked = 0
        var fresh: [URL: (modified: Date, found: [(PositionKey, Encounter)])] = [:]
        for entry in entries {
            if let known = cached[entry.url], known.modified == entry.modified {
                fresh[entry.url] = known
                continue
            }
            walked += 1
            fresh[entry.url] = (
                entry.modified, MistakeBook.encounters(in: entry, lines: self.lines)
            )
        }
        cached = fresh
        walkedLastTime = walked
        rebuild()
    }

    /// Strikes a position off. An append to the log, so it is a fact about what the player
    /// decided rather than an edit to anything (docs/adr/0029).
    public func dismiss(_ position: PositionKey) {
        log.append(.dismissed(position))
        rebuild()
    }

    /// Puts one back.
    public func restore(_ position: PositionKey) {
        log.append(.restored(position))
        rebuild()
    }

    /// The book from what is cached plus what the player has struck off. Cheap: no files are
    /// read except the log, and no game is walked.
    private func rebuild() {
        let dismissed = log.dismissed()
        var byPosition: [PositionKey: [Encounter]] = [:]
        for (_, entry) in cached {
            for (key, encounter) in entry.found where !dismissed.contains(key) {
                byPosition[key, default: []].append(encounter)
            }
        }
        book = MistakeBook(
            mistakes: byPosition.map { Mistake(position: $0.key, encounters: $0.value) }
        )
    }
}
