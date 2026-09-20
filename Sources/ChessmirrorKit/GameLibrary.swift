import Foundation

/// The games on disk, which is to say a folder of PGN files (docs/adr/0010).
///
/// There is no database and no model layer: a Game is its PGN text, the library is the
/// directory listing, and anything that can read a PGN can read everything this app has
/// ever saved. The cost is re-parsing on launch, which for text files of a few kilobytes
/// is not a cost.
@Observable @MainActor public final class GameLibrary {
    public struct Entry: Identifiable, Hashable, Sendable {
        public let url: URL
        public var id: URL { url }
        /// Nil when the file is there but will not parse — listed rather than hidden,
        /// because a file the app cannot read is exactly what a person needs to be told.
        public var pgn: PGN?
        public var modified: Date
        /// A game iCloud has told this device about but not yet handed over. Listed with the
        /// rest, because it is a game that exists; it just cannot be opened for a moment.
        public var isDownloading = false

        public init(url: URL, pgn: PGN?, modified: Date, isDownloading: Bool = false) {
            self.url = url
            self.pgn = pgn
            self.modified = modified
            self.isDownloading = isDownloading
        }

        /// Where this game came from, as the file says (`PGN.origin`). A file that will not
        /// parse is a fresh one for the list's purposes.
        public var origin: GameOrigin { pgn?.origin ?? .fresh }

        /// What this game is called, if anybody has said (`PGN.name`).
        public var name: String? { pgn?.name }

        /// The name to show, which is the given one or one made from when the game was saved. Never
        /// a shared placeholder: rows that all read "未命名" cannot be told apart or sorted.
        public var title: String {
            if let name { return name }
            return GameLibrary.fallbackName(for: url)
        }

        public var detail: String {
            if isDownloading { return localized("library.entry.downloading") }
            guard let pgn else { return localized("library.entry.unreadable") }
            let result = pgn.game.resultToken
            let moves = (pgn.game.plies.count + 1) / 2
            // As much of the date as the file knows, and nothing where it knows none
            // (`PGN.playedOn`).
            var parts = [origin.label]
            if let played = PGN.playedOn(pgn.tag("Date")) { parts.append(played) }
            parts.append(localized("library.entry.moves", plural: moves))
            parts.append(result == "*" ? localized("library.entry.unfinished") : result)
            return parts.joined(separator: " · ")
        }
    }

    public private(set) var entries: [Entry] = []

    /// The tag a game's own name lives in.
    public nonisolated static let nameTag = "Name"

    public func sortedByName(_ list: [Entry]) -> [Entry] {
        list.sorted { Self.reads($0.title, before: $1.title) }
    }

    /// Numeric-aware, locale-aware, and case-insensitive — `localizedStandardCompare` is the same
    /// comparison the Files app sorts by, which is the one a person expects to see.
    public static func reads(_ left: String, before right: String) -> Bool {
        left.localizedStandardCompare(right) == .orderedAscending
    }

    /// A name for a game nobody has named: when it was saved, read out of its own file name. Unique
    /// per game and sorts chronologically, which is what the flat list used to give for free.
    public nonisolated static func fallbackName(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let stamp = stem.hasPrefix("chessmirror-") ? String(stem.dropFirst("chessmirror-".count)) : stem
        guard let date = stampFormatter.date(from: stamp) else { return stem }
        return readable(date)
    }

    // ------------------------------------------------------------------ naming

    /// Renames a game, or takes its name away again with nil.
    @discardableResult
    public func rename(_ entry: Entry, to name: String?) -> Bool {
        setTags([(Self.nameTag, name)], on: entry)
    }

    /// Rewrites any number of a game's tags, in one read and one write.
    ///
    /// Through the PGN rather than around it: the file is the game (docs/adr/0010), so naming one is
    /// re-writing it with a tag changed, and there is no second place a name could disagree with. A
    /// game whose PGN will not parse cannot be named, which is the honest answer — there is nothing
    /// there to put a name in.
    ///
    /// However many tags, one pass — because an `Entry` carries the PGN as it was parsed, so two
    /// calls in a row would both start from that same snapshot and the second would write the first
    /// one's change back out. That is not hypothetical: filing a game and naming it were two calls,
    /// and the name landed while the collection quietly reverted.
    @discardableResult
    public func setTags(_ changes: [(name: String, value: String?)], on entry: Entry) -> Bool {
        guard var pgn = entry.pgn else { return false }
        for change in changes {
            pgn.setTag(change.name, to: change.value)
        }
        return write(pgn, to: entry.url)
    }

    /// The folder the games are in, which is iCloud's when there is an iCloud (docs/adr/0012).
    /// Everything that touches the disk goes through it, because a file in iCloud has to be
    /// asked for before it can be read and coordinated before it can be written.
    public let folder: GameFolder

    public var directory: URL { folder.url }
    /// The imported games whose Review is running, and how far each has got. A game is here
    /// from the moment its Review is asked for until it lands or fails, so a second ask while one
    /// is running is refused rather than queued twice.
    public private(set) var reviewing: [URL: ImportReview.Progress] = [:]
    public var reviewingURLs: Set<URL> { Set(reviewing.keys) }
    private var importReviewChain: Task<Void, Never>?
    func waitForImportReviews() async { await importReviewChain?.value }

    /// How a Review of an imported game ended.
    public enum ReviewOutcome: Sendable {
        /// The Review landed and was written: the entry as it now is.
        case reviewed(PGN)
        /// The game changed while the Review was running, and the Review was thrown away.
        case superseded
        /// The engine could not settle every position (`ImportReview.Failure`) or the write
        /// failed. Nothing is saved; asking again starts over.
        case failed
    }

    /// Runs the Review of an imported game (docs/adr/0016) and writes it into the file. Asked for,
    /// never started on its own: it is a few seconds of engine per move, and the player says when.
    /// Refused — with no callback — for a game that is not imported, is already reviewed, or is
    /// being reviewed now.
    public func reviewImported(_ entry: Entry, using engine: any Engine,
                               completed: @escaping @MainActor (ReviewOutcome) -> Void = { _ in }) {
        guard entry.origin == .imported, let original = entry.pgn, !original.game.isReviewed,
            reviewing[entry.url] == nil else { return }
        reviewing[entry.url] = ImportReview.Progress(judged: 0, total: 0)
        let previous = importReviewChain
        importReviewChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { reviewing[entry.url] = nil }
            do {
                await writeChain?.value
                let judged = try await ImportReview.judge(original, using: engine) { [weak self] progress in
                    self?.reviewing[entry.url] = progress
                }
                guard let current = entries.first(where: { $0.url == entry.url })?.pgn,
                    current.game == original.game else { return completed(.superseded) }
                var result = current
                result.game = judged.game
                result.setTag("ReviewSift", to: judged.tag("ReviewSift"))
                completed(write(result, to: entry.url) ? .reviewed(result) : .failed)
            } catch {
                // No partial scores are saved; asking again starts the job over.
                completed(.failed)
            }
        }
    }

    public init(folder: GameFolder = GameFolder()) {
        self.folder = folder
        reload()
    }

    /// Moves the library into iCloud and keeps it listening for the other devices.
    ///
    /// Separate from `init` and asynchronous because finding the iCloud folder can take as long
    /// as an account server takes: the library lists the local folder first so that the app
    /// opens at once, and swaps to the iCloud one — with everything local moved up into it —
    /// when the answer arrives. Nothing else in the app knows this happened.
    public func connect() async {
        guard await folder.connect() else { return }
        reload()
        folder.onChange { [weak self] in self?.reloadQuietly() }
    }

    public func reload() {
        entries = Self.gather(in: directory, isCloud: folder.isCloud)
        fetchMissing()
    }

    /// The metadata query's `reload`: the scan runs off the main thread, because a directory
    /// full of games read and parsed on the main actor is a hang per save. The query reports
    /// this device's own writes among the rest, so `GameFolder` coalesces the burst before
    /// this is even called.
    private func reloadQuietly() {
        let directory = directory
        let isCloud = folder.isCloud
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            let gathered = await Task.detached(priority: .utility) {
                Self.gather(in: directory, isCloud: isCloud)
            }.value
            guard let self, !Task.isCancelled else { return }
            entries = gathered
            fetchMissing()
        }
    }

    private var reloadTask: Task<Void, Never>?

    /// The directory listing, read off the main thread when asked to be. In iCloud every file
    /// here costs a round trip to the sync daemon — its download status and a coordinated read
    /// each — and the only thing that gets back is `Entry` values, which are plain data.
    private nonisolated static func gather(in directory: URL, isCloud: Bool) -> [Entry] {
        let manager = FileManager.default
        let urls =
            (try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        return urls
            .filter { $0.pathExtension.lowercased() == "pgn" }
            .map { url in
                // A game another device saved is a name here before it is bytes. Asking for it
                // is enough — the folder says when it has landed, and the list is built again.
                let isHere = GameFolder.isHere(url, isCloud: isCloud)
                let text = GameFolder.read(at: url, isCloud: isCloud) {
                    try? String(contentsOf: $0, encoding: .utf8)
                }
                let modified =
                    (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
                return Entry(
                    url: url,
                    pgn: text.flatMap { try? PGN(parsing: $0) },
                    modified: modified,
                    isDownloading: !isHere
                )
            }
            .sorted { $0.modified > $1.modified }
    }

    /// Asks iCloud for the games this device only knows the name of.
    private func fetchMissing() {
        for entry in entries where entry.isDownloading {
            folder.fetch(entry.url)
        }
    }

    /// A file name that reads as what it is in any file browser, and sorts by when it was
    /// played.
    public func newURL(now: Date = Date()) -> URL {
        let stamp = Self.stampFormatter.string(from: now)
        var url = directory.appending(path: "chessmirror-\(stamp).pgn")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: "chessmirror-\(stamp)-\(suffix).pgn")
            suffix += 1
        }
        return url
    }

    @discardableResult
    public func write(_ pgn: PGN, to url: URL) -> Bool {
        guard let data = pgn.text.data(using: .utf8) else { return false }
        if folder.isCloud {
            // A coordinated write is a conversation with iCloud's daemon, and the main thread
            // is no place for a conversation that can take as long as a sync. Chained so the
            // saves land in the order they were made: the newest state is the last write,
            // whatever order the detached work finishes in.
            let previous = writeChain
            writeChain = Task { [weak self] in
                await previous?.value
                let written = await Task.detached(priority: .utility) {
                    GameFolder.write(data, to: url, isCloud: true)
                }.value
                guard written, let self else { return }
                self.refreshEntry(at: url, with: pgn)
            }
            return true
        }
        guard folder.write(data, to: url) else { return false }
        refreshEntry(at: url, with: pgn)
        return true
    }

    /// Saves in flight, in order. Nil once the chain has drained.
    private var writeChain: Task<Void, Never>?

    public func delete(_ entry: Entry) {
        folder.remove(entry.url)
        folder.remove(Self.pictureURL(for: entry.url))
        entries.removeAll { $0.url == entry.url }
    }

    // ---------------------------------------------------------------- pictures

    /// The photograph a recognised game was read from, stored beside its PGN under the same
    /// name. A sidecar rather than something embedded: the PGN stays a PGN that any other
    /// program can read, and a game that loses its picture still opens.
    public static func pictureURL(for game: URL) -> URL {
        game.deletingPathExtension().appendingPathExtension("png")
    }

    /// Keeps a photograph the moment it is taken, before anything has tried to read it.
    ///
    /// Recognition is where the app is most likely to die — it is the only thing it does
    /// that can cost minutes and gigabytes — and a picture that died with it cannot be
    /// taken again. The file lives beside the games under its own name, distinct from a
    /// game's sidecar, and it never shows up as an entry: the library lists PGNs only.
    @discardableResult
    public func keepPhotograph(_ image: RGBImage) -> URL? {
        guard let data = image.pngData else { return nil }
        let stamp = Self.stampFormatter.string(from: Date())
        var url = directory.appending(path: "chessmirror-photo-\(stamp).png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: "chessmirror-photo-\(stamp)-\(suffix).png")
            suffix += 1
        }
        guard folder.write(data, to: url) else { return nil }
        return url
    }

    public func writePicture(_ image: RGBImage, for game: URL) {
        let url = Self.pictureURL(for: game)
        if folder.isCloud {
            // Encoding a photograph is the expensive half; the coordinated write is the slow
            // one. Both happen off the main thread, where a save belongs.
            Task.detached(priority: .utility) {
                guard let data = image.pngData else { return }
                GameFolder.write(data, to: url, isCloud: true)
            }
            return
        }
        guard let data = image.pngData else { return }
        folder.write(data, to: url)
    }

    /// Nil for a game with no picture, and also for one whose picture is still coming down from
    /// iCloud — the screens that show it already have to cope with a game that never had one.
    public func picture(for game: URL) -> RGBImage? {
        folder.read(at: Self.pictureURL(for: game)) { RGBImage(contentsOf: $0) }
    }

    /// Updates one row in place rather than re-reading the folder, so that autosaving after
    /// every move does not turn into a directory scan after every move.
    private func refreshEntry(at url: URL, with pgn: PGN) {
        let entry = Entry(url: url, pgn: pgn, modified: Date())
        if let index = entries.firstIndex(where: { $0.url == url }) {
            entries[index] = entry
        } else {
            entries.insert(entry, at: 0)
        }
        entries.sort { $0.modified > $1.modified }
    }

    private nonisolated static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    /// The same instant as something to read in a list.
    ///
    /// Built per call rather than kept, because it is spelt in whatever language the app is
    /// currently speaking — and asked for as a template, so each language puts the day, the month
    /// and the hour in its own order: 8月30日 21:14, Aug 30 at 21:14, 30 août 21:14.
    nonisolated static func readable(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Speech.locale
        formatter.setLocalizedDateFormatFromTemplate("Md HH:mm")
        return formatter.string(from: date)
    }
}
