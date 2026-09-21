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
    /// A transient receipt for newly recorded occasions, never replayed on initial loading.
    public struct Recording: Equatable, Sendable {
        public let id: UUID
        public let count: Int
    }
    public private(set) var recording: Recording?
    private var hasLoaded = false

    /// How many games the last update actually had to walk. Zero on a reload that changed
    /// nothing, which is the whole point of the cache and the thing a test can hold it to.
    public private(set) var walkedLastTime = 0

    /// The 连正榜 (docs/adr/0038). Derived from the same walk as the book, and cached with it:
    /// a game's credits are read once, under its file and date, and summed on every rebuild.
    public private(set) var ladder = Ladder(rows: [])

    /// How many positions each game holds something wrong at, by the file it is in — the number
    /// on a game's row in the library, and the number an imported chapter reports as ready.
    ///
    /// Counted by Ply and not by 遭遇: a position tried three times in one game is one place to
    /// stop at, which is the same rule the game's own list uses (docs/adr/0036). Read from the
    /// book rather than from the walk, so a position struck off is not counted against its game.
    /// A game with nothing wrong in it is absent rather than zero.
    public private(set) var wrongByGame: [URL: Int] = [:]

    /// Today's queue (docs/adr/0030). Derived like everything else here — from the book and the
    /// practice log — and recomputed whenever either could have changed.
    public private(set) var daily = Daily(cards: [])

    /// The practice log the book is read against, and the one a drill writes its attempts to:
    /// one log, because a dismissal and an attempt are the same kind of thing (docs/adr/0029).
    public let log: PracticeLog
    private var lines: JudgementLines
    /// One game's findings, under the file it came from and the date it carried when they were
    /// taken. A file that has been written since is a different game and is walked again.
    private var cached: [URL: Walked] = [:]

    /// What one walk of one game turned up: its Encounters for the book, its credits for the
    /// ladder.
    private struct Walked {
        let modified: Date
        let found: [(PositionKey, Encounter)]
        let credits: [Ladder.Credit]
    }

    public init(log: PracticeLog = .standard, lines: JudgementLines = .standard) {
        self.log = log
        self.lines = lines
    }

    /// How many chains of following have been started. A library followed twice leaves the first
    /// chain stale, and this is how it knows to stop.
    private var following = 0

    /// Follows a library: the book is brought up to date now, and again whenever the games
    /// change.
    ///
    /// **Freshness belongs to the index.** It used to belong to a view modifier on the library
    /// screen, which meant the book was as current as that screen was recent: an app that opened
    /// somewhere else — a drill, a game, a shared file — read a book nobody had rebuilt, and
    /// nothing in `book`'s type said so. Following is idempotent; the last call wins.
    public func follow(_ library: GameLibrary) {
        following += 1
        let registration = following
        update(from: library.entries)
        withObservationTracking {
            _ = library.entries
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, registration == following else { return }
                follow(library)
            }
        }
    }

    /// Follows a library *and* the player's lines: a moved 记录线 or 入列线 changes which moves
    /// count, so the book follows the settings the way it follows the games. The library screen
    /// used to watch the lines itself and hand them in.
    public func follow(_ library: GameLibrary, settings: PlayerSettings) {
        following += 1
        let registration = following
        update(from: library.entries, lines: settings.lines)
        withObservationTracking {
            _ = library.entries
            _ = settings.lines
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, registration == following else { return }
                follow(library, settings: settings)
            }
        }
    }

    // ------------------------------------------------------------------ practising

    /// A drill of one 错题, written into this index's log under its lines — and when its attempt
    /// is settled, today's queue is worked out again, because the log it is read from has just
    /// grown. The drill screen used to watch for that itself. Nil for a position that will not
    /// parse.
    public func practise(
        _ mistake: Mistake, engine: (any Engine)?, source: Drill.Source = .picked
    ) -> Drill? {
        guard let drill = Drill(
            position: mistake.position, engine: engine, log: log, lines: lines, source: source
        ) else { return nil }
        refresh(whenSettled: drill)
        return drill
    }

    private func refresh(whenSettled drill: Drill) {
        withObservationTracking {
            _ = drill.isSettled
        } onChange: { [weak self, weak drill] in
            Task { @MainActor [weak self, weak drill] in
                guard let self, let drill else { return }
                if drill.isSettled { refresh() } else { refresh(whenSettled: drill) }
            }
        }
    }

    /// The question after this one. From 日课, the next card of today's queue that is not this
    /// position; picked off the book, the next 错题 in the book's order, round to the first.
    /// Nil when there is nothing else to ask — the end of the queue, or a book of one.
    public func next(after mistake: Mistake, source: Drill.Source) -> Mistake? {
        switch source {
        case .daily:
            return daily.cards.first { $0.position != mistake.position }?.mistake
        case .picked:
            let mistakes = book.mistakes
            guard let here = mistakes.firstIndex(where: { $0.position == mistake.position }),
                  mistakes.count > 1 else { return nil }
            return mistakes[(here + 1) % mistakes.count]
        }
    }

    /// What the 日课 door says: how many are left today, that today's are done, or that there is
    /// nothing in the book to practise yet. The door stays on the screen with nothing due — a
    /// door that disappears once it is done is a door nobody learns is there.
    public var dailyLabel: String {
        let left = daily.remaining
        if left > 0 { return localized("daily.left", plural: left) }
        return localized(book.isEmpty ? "daily.none" : "daily.done")
    }

    /// Stops following, for a caller that wants the book to stand still.
    public func unfollow() { following += 1 }

    /// Brings the book into line with a set of games, walking only what has changed.
    public func update(from entries: [GameLibrary.Entry], lines: JudgementLines? = nil) {
        let changedLines = lines.map { $0 != self.lines } ?? false
        let previous = Set(book.mistakes.flatMap { $0.encounters.map(\.id) })
        if let lines, lines != self.lines {
            // A moved line changes which moves count, so nothing cached under the old one is
            // usable. Cheaper to say so than to remember which findings were near the edge.
            self.lines = lines
            cached = [:]
        }
        var walked = 0
        var fresh: [URL: Walked] = [:]
        for entry in entries {
            if let known = cached[entry.url], known.modified == entry.modified {
                fresh[entry.url] = known
                continue
            }
            walked += 1
            fresh[entry.url] = Walked(
                modified: entry.modified,
                found: MistakeBook.encounters(in: entry, lines: self.lines),
                credits: Ladder.credits(in: entry)
            )
        }
        cached = fresh
        walkedLastTime = walked
        rebuild()
        let current = Set(book.mistakes.flatMap { $0.encounters.map(\.id) })
        let added = current.subtracting(previous).count
        if hasLoaded, !changedLines, added > 0 {
            recording = Recording(id: UUID(), count: added)
        }
        hasLoaded = true
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

    /// Works today's queue out again, for after a drill has been practised — the attempt is a new
    /// line in the log and the schedule is a function of the log (docs/adr/0029).
    public func refresh(now: Date = Date()) {
        daily = Daily.forToday(
            book: book, attempts: log.attempts(), lines: lines, now: now
        )
    }

    /// The book from what is cached plus what the player has struck off, and the day that falls
    /// out of it. Cheap: no files are read except the log, and no game is walked.
    private func rebuild(now: Date = Date()) {
        // One read of the log for both questions: what has been struck off, and what has been
        // practised.
        let entries = log.entries()
        let dismissed = PracticeLog.dismissed(in: entries)
        // Assembled where every book is assembled (`MistakeBook.book`): this used to be a second
        // copy of the same loop, and the one the app actually ran.
        book = MistakeBook.book(of: cached.values.flatMap(\.found), dismissed: dismissed)
        var plies: [URL: Set<Int>] = [:]
        for mistake in book.mistakes {
            for encounter in mistake.encounters {
                plies[encounter.game, default: []].insert(encounter.ply)
            }
        }
        wrongByGame = plies.mapValues(\.count)
        ladder = Ladder.sum(cached.map { (game: $0.key, credits: $0.value.credits) })
        daily = Daily.forToday(
            book: book, attempts: PracticeLog.attempts(in: entries), lines: lines, now: now
        )
    }
}
