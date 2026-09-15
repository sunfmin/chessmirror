import Foundation

/// Where the games are kept — iCloud Drive when there is an iCloud to keep them in, and this
/// device's own Documents folder when there is not.
///
/// A game is a file (docs/adr/0010), so the library is a directory listing, and putting the
/// library in iCloud is a question of which directory to open rather than of a sync layer over
/// a store. The directory is the app's ubiquity container's `Documents`, which is the one iOS
/// shows in the Files app under 棋镜, so the files a phone writes are the files a Mac can drag
/// out — the same property the local folder already had, kept.
///
/// The local folder is where this starts either way. Asking iCloud where its container is can
/// take as long as it likes, and a library that cannot list itself until an account server has
/// answered is a library that cannot be opened on a plane. `connect()` does the asking, moves
/// whatever was kept locally up into iCloud once, and switches the folder over.
@MainActor public final class GameFolder {
    /// The folder to read and write right now.
    public private(set) var url: URL

    /// Whether that folder is iCloud's. What it decides is not where files go — `url` has
    /// already said that — but whether reading and writing them has to be coordinated with the
    /// sync daemon, and whether a file that is listed is necessarily a file that is here.
    public private(set) var isCloud: Bool

    /// Open on a folder, iCloud's by default. The arguments are a seam rather than a
    /// feature: the real folder is found by `connect()`, but a test hands over a
    /// temporary directory and never touches the real Documents.
    public init(url: URL = GameFolder.local, isCloud: Bool = false) {
        self.url = url
        self.isCloud = isCloud
    }

    /// The folder the app has always used, and the one it falls back to. Kept even after the
    /// move to iCloud: signing out of an account must leave somewhere to play.
    public nonisolated static let local: URL = {
        let games = URL.documentsDirectory.appending(path: "Games", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
        return games
    }()

    private var query: NSMetadataQuery?
    private var changed: (() -> Void)?
    private var isWatchingAccount = false

    // --------------------------------------------------------------- connecting

    /// Opens the iCloud folder if there is one, having first moved anything kept locally into
    /// it. Answers whether the folder changed, which is the library's cue to list it again.
    ///
    /// Safe to call more than once: signing into an account after launch is a thing people do,
    /// and the second call is what notices.
    @discardableResult
    public func connect() async -> Bool {
        let opened = await Task.detached(priority: .utility) { Self.openCloudFolder() }.value
        watchAccount()
        guard let opened, opened != url else { return false }
        url = opened
        isCloud = true
        startQuery()
        return true
    }

    /// Resolving the container, making the folder and moving the old games up, all off the main
    /// thread — every line of it can block on the account, the disk or both.
    private nonisolated static func openCloudFolder() -> URL? {
        let manager = FileManager.default
        // Nil rather than the identifier: it means "the first container this app is entitled
        // to", so the entitlement stays the one place the container is named.
        guard let container = manager.url(forUbiquityContainerIdentifier: nil) else { return nil }
        // `Documents` and not the container root, because that is the folder iOS publishes to
        // the Files app; anything beside it is the app's own business and stays hidden.
        let documents = container.appending(path: "Documents", directoryHint: .isDirectory)
        do {
            try manager.createDirectory(at: documents, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        moveLocalGames(into: documents, using: manager)
        return documents
    }

    /// Moves the games that were saved before there was an iCloud to save them to.
    ///
    /// Everything in the folder, not only the PGNs: a recognised game keeps its photograph
    /// beside it under the same name, and a game that arrives on another device without its
    /// picture is a game that cannot be checked against the board it came from.
    ///
    /// Nothing is overwritten. A name that is taken in iCloud — the same game already up there
    /// from another device, most likely — makes the local copy land beside it under a new name
    /// rather than on top of it. Two copies of one game is a thing a person can sort out; the
    /// game they lost is not.
    private nonisolated static func moveLocalGames(into cloud: URL, using manager: FileManager) {
        let local = (try? manager.contentsOfDirectory(
            at: Self.local,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for file in local {
            var destination = cloud.appending(path: file.lastPathComponent)
            var suffix = 2
            while manager.fileExists(atPath: destination.path) {
                let stem = file.deletingPathExtension().lastPathComponent
                destination = cloud
                    .appending(path: "\(stem)-\(suffix)")
                    .appendingPathExtension(file.pathExtension)
                suffix += 1
            }
            try? manager.setUbiquitous(true, itemAt: file, destinationURL: destination)
        }
    }

    // ---------------------------------------------------------------- listening

    /// Calls back whenever a game arrives, changes or disappears in iCloud — which is to say,
    /// whenever another device has been played on.
    public func onChange(_ handler: @escaping () -> Void) {
        changed = handler
        startQuery()
    }

    /// Coalesced: the query reports this device's own writes among the rest, and a save that
    /// writes a game and its picture is one change, not a rescan per file.
    private var pendingChange: Task<Void, Never>?

    private func dispatchChange() {
        pendingChange?.cancel()
        pendingChange = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            changed?()
        }
    }

    /// A metadata query rather than a directory watch: files in iCloud change without anything
    /// touching this device's disk, and this is the only thing that hears about that.
    private func startQuery() {
        guard isCloud, query == nil, changed != nil else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*.pgn'", NSMetadataItemFSNameKey)
        for name in [
            NSNotification.Name.NSMetadataQueryDidFinishGathering,
            NSNotification.Name.NSMetadataQueryDidUpdate,
        ] {
            observe(name, from: query) { folder in folder.dispatchChange() }
        }
        query.start()
        self.query = query
    }

    /// Signing in or out of iCloud swaps the folder under a running app, so the app asks again.
    private func watchAccount() {
        guard !isWatchingAccount else { return }
        isWatchingAccount = true
        observe(.NSUbiquityIdentityDidChange, from: nil) { folder in
            Task { if await folder.connect() { folder.dispatchChange() } }
        }
    }

    private func observe(
        _ name: NSNotification.Name,
        from object: Any?,
        handler: @escaping @MainActor (GameFolder) -> Void
    ) {
        NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
    }

    // ------------------------------------------------------------------ reading

    /// Whether a file's contents are on this device.
    ///
    /// In iCloud a file is a name long before it is bytes: it appears in the listing the moment
    /// another device saves it, and arrives when it arrives. Everything that reads has to be
    /// able to say "not yet" rather than "broken".
    public func isHere(_ url: URL) -> Bool {
        Self.isHere(url, isCloud: isCloud)
    }

    nonisolated static func isHere(_ url: URL, isCloud: Bool) -> Bool {
        guard isCloud else { return true }
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        // A file that is downloaded but out of date reads as here — the copy on this device is
        // a real game, and a newer one landing is what the metadata query is for.
        return status != .notDownloaded
    }

    /// Asks iCloud for a file this device only knows the name of. Returns immediately; the
    /// query says when it has landed.
    public func fetch(_ url: URL) {
        guard isCloud else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// Reads a file, or answers nil when it is not on this device yet.
    ///
    /// Through a coordinator when the folder is iCloud's, so that a file being written by the
    /// sync daemon is never read halfway through. `.withoutChanges` and the `isHere` guard keep
    /// this from ever being the thing that waits on the network: a coordinated read of a file
    /// that has not arrived blocks until it does, which on the main thread is a hang.
    public func read<T: Sendable>(at url: URL, _ body: @Sendable (URL) -> T?) -> T? {
        if isCloud && !Self.isHere(url, isCloud: true) {
            fetch(url)
            return nil
        }
        return Self.read(at: url, isCloud: isCloud, body)
    }

    nonisolated static func read<T: Sendable>(
        at url: URL, isCloud: Bool, _ body: @Sendable (URL) -> T?
    ) -> T? {
        guard isCloud else { return body(url) }
        guard isHere(url, isCloud: isCloud) else { return nil }
        var out: T?
        var failure: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &failure) { url in
            out = body(url)
        }
        return out
    }

    // ------------------------------------------------------------------ writing

    /// Writes a file, atomically, and coordinated when it is iCloud's to look after.
    ///
    /// Last writer wins. Two devices moving in the same game at the same second is the only way
    /// to lose a move here, and the alternative — conflict versions, a UI to resolve them — is
    /// a lot of machinery for a person working through positions alone.
    @discardableResult
    public func write(_ data: Data, to url: URL) -> Bool {
        Self.write(data, to: url, isCloud: isCloud)
    }

    /// The same write, callable from anywhere. The coordinator is the point of this split: in
    /// iCloud a write is a conversation with the sync daemon, and the main thread is no place
    /// for a conversation that can take as long as a sync.
    nonisolated static func write(_ data: Data, to url: URL, isCloud: Bool) -> Bool {
        guard isCloud else { return write(data, directlyTo: url) }
        var written = false
        var failure: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [.forReplacing], error: &failure) { url in
            written = write(data, directlyTo: url)
        }
        return written
    }

    nonisolated private static func write(_ data: Data, directlyTo url: URL) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public func remove(_ url: URL) {
        guard isCloud else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        var failure: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [.forDeleting], error: &failure) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }
}
