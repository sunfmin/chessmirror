import Foundation

/// 自动拉局 — the 本人账号's new games, pulled into the library without being asked
/// (CONTEXT.md, docs/adr/0045).
///
/// Once a day, the first time the app comes forward on that day (`pullIfDue`), and again
/// whenever the player presses for it (`pull`). Each 本人账号 — per site, the account that last
/// fetched through its 门 — carries on from where its last pull reached (`ImportMemory.reached`),
/// at most `cap` games at a time, and the first pull, with nowhere reached yet, takes the count
/// the sheet remembers. What comes down is written the way 入库 writes it and judged at once.
@MainActor @Observable public final class AutoFetch {
    public enum Phase: Equatable, Sendable {
        case idle
        case pulling
        /// The last pull this session finished, and how many games it added.
        case pulled(added: Int)
        /// The last pull failed at one account: the site's door is where it is put right.
        case failed(PGNImport.Site, PGNImport.Error)
    }

    public private(set) var phase: Phase = .idle

    /// The most games one pull writes per account. A player back from three weeks away gets
    /// their last fifty, not a queue that has the engine running until the battery is gone.
    public static let cap = 50

    public let memory: ImportMemory
    private let fetcher: any PGNFetching
    private let now: () -> Date
    private let calendar: Calendar

    public init(
        memory: ImportMemory, fetcher: any PGNFetching = URLSessionPGNFetcher(),
        now: @escaping () -> Date = Date.init, calendar: Calendar = .current
    ) {
        self.memory = memory
        self.fetcher = fetcher
        self.now = now
        self.calendar = calendar
    }

    /// The 本人账号, one per site that has one.
    public var accounts: [(site: PGNImport.Site, name: String)] {
        PGNImport.Site.withPlayers.compactMap { site in memory.latest(on: site).map { (site, $0) } }
    }

    /// Whether today's pull is still owed: nothing has finished today, on any device.
    public var isDue: Bool {
        guard let last = memory.lastPull else { return true }
        return !calendar.isDate(last, inSameDayAs: now())
    }

    /// Today's pull, if it has not happened yet.
    public func pullIfDue(into library: GameLibrary, reviewingWith engine: (any Engine)?) async {
        guard isDue else { return }
        await pull(into: library, reviewingWith: engine)
    }

    /// Pulls every 本人账号's new games now. A failure at one account does not stop the next;
    /// the day counts as pulled only when none failed, so a pull the network let down is asked
    /// again the next time the app comes forward.
    public func pull(into library: GameLibrary, reviewingWith engine: (any Engine)?) async {
        guard phase != .pulling, !accounts.isEmpty else { return }
        phase = .pulling
        var added = 0
        var failure: (PGNImport.Site, PGNImport.Error)?
        for (site, name) in accounts {
            switch await pull(name, on: site, into: library, reviewingWith: engine) {
            case .success(let count): added += count
            case .failure(let error): failure = failure ?? (site, error)
            }
        }
        if let failure {
            phase = .failed(failure.0, failure.1)
        } else {
            memory.pulled(at: now())
            phase = .pulled(added: added)
        }
    }

    private func pull(
        _ name: String, on site: PGNImport.Site, into library: GameLibrary,
        reviewingWith engine: (any Engine)?
    ) async -> Result<Int, PGNImport.Error> {
        let since = memory.reached(name, on: site)
        let many = since == nil ? memory.count : Self.cap
        let plan: FetchPlan
        switch site {
        case .lichess:
            guard let url = PGNImport.recentGamesURL(user: name, count: many, since: since) else {
                return .failure(.notAPlayer(site))
            }
            plan = .recentLichess(url)
        case .chessCom:
            guard let archives = PGNImport.chessComArchivesURL(user: name) else {
                return .failure(.notAPlayer(site))
            }
            plan = .recentChessCom(archives: archives, many: many, since: since)
        case .chessease:
            return .success(0)
        }
        let fetching = fetcher
        let text: String
        do {
            text = try await Task.detached(priority: .utility) {
                try await plan.text(fetching: fetching, asked: name)
            }.value
        } catch let error as PGNImport.Error {
            if case .unknownPlayer(let site, _) = error { return .failure(.unknownPlayer(site, name)) }
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
        // Newest first as the sites hand them over. A game that says when it began is kept only
        // if it began after the point reached; one that does not say is left to the dedup.
        let (chapters, unreadable) = PGNImport.chapters(in: text)
        let fresh = chapters
            .filter { chapter in
                guard let since, let started = PGNImport.startedAt(chapter.pgn) else { return true }
                return started > since
            }
            .prefix(many)
        if let newest = fresh.compactMap({ PGNImport.startedAt($0.pgn) }).max() {
            memory.reach(newest, for: name, on: site)
        }
        // Oldest first, so the newest game is the last written and the top of the list.
        let outcome = PGNImport.write(
            PGNImport.ImportPlan(chapters: fresh.reversed(), unreadable: unreadable),
            into: library, as: name, reviewingWith: engine
        )
        return .success(outcome.imported)
    }

    // ------------------------------------------------------------------ what the list says

    /// The one line under the list's title: what the last pull did, or why it did not, or how to
    /// give it an account. Nil when there is nothing worth saying.
    public struct Reading: Equatable, Sendable {
        public let text: String
        /// A failure, drawn in the alarm colour; pressing it opens the door to put it right.
        public let isAlarm: Bool
    }

    public var reading: Reading? {
        switch phase {
        case .pulling:
            return Reading(text: localized("autoFetch.pulling"), isAlarm: false)
        case .failed(_, let error):
            return Reading(text: error.alert.title, isAlarm: true)
        case .idle, .pulled:
            guard !accounts.isEmpty else {
                return Reading(text: localized("autoFetch.noAccount"), isAlarm: false)
            }
            guard let last = memory.lastPull else { return nil }
            var text = localized("autoFetch.pulledAt", when(last))
            if case .pulled(let added) = phase {
                text += localized("clause.separator")
                    + (added == 0
                        ? localized("autoFetch.nothingNew")
                        : localized("autoFetch.added", plural: added))
            }
            return Reading(text: text, isAlarm: false)
        }
    }

    /// 「今天 8:02」, 「昨天 21:40」, or the day itself further back.
    private func when(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute, .month, .day], from: date)
        let time = String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now()) { return localized("autoFetch.today", time) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now()),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return localized("autoFetch.yesterday", time)
        }
        return localized("autoFetch.onDay", parts.month ?? 0, parts.day ?? 0, time)
    }
}
