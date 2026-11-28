import Foundation

/// How one 门 turns what was typed into PGN text (docs/adr/0014, 0045).
///
/// **One plan per door.** The pipeline behind them (`ImportSession.read`) has been the same
/// since the doors were named — text in, chapters out — but *how the text is got* was a
/// `switch` over site names in three places: `ImportSession.run`, `ImportSession.recent`, and
/// `ImportDoors.fetch`, which decided which of the two to call. The 国象联盟 sniff ran twice,
/// at the session and at the sheet. chess.com's month walk was inlined into the session beside
/// lichess's single URL.
///
/// A door now says what it needs and the session only fetches. This is the shape
/// codebase-design calls a real seam — one **adapter** per door, not one `switch` per fact.
/// The four doors are a fixed set and stay an enum; what changed is that every door-shaped
/// fact has one home, so a fifth door is one new case and its members rather than a sixth
/// edit to six switches.
public enum FetchPlan: Equatable, Sendable {
    /// A 国象联盟 share link carries its game in its own fragment (docs/adr/0045). Nothing is
    /// fetched; the link is read the way the site's own viewer reads it.
    case carried(pgn: String)
    /// Any other link: try each candidate in order, and the first one that parses as PGN wins.
    /// A game page falls through to its export; a study falls through to its `.pgn`.
    case links([URL])
    /// A player's recent games on lichess: one download, newest first.
    case recentLichess(URL)
    /// A player's monthly archives on chess.com: fetch the list, then walk the newest months
    /// back until there are enough games or the months run out.
    /// With `since`, the walk stops at the month it falls in, and a player with nothing newer is
    /// not a failure: nothing new is the answer 自动拉局 asks for most days.
    case recentChessCom(archives: URL, many: Int, since: Date? = nil)
}

extension FetchPlan {
    /// A player's recent games on a site — the one plan the 门 and 自动拉局 both ask for — nil
    /// when what was typed is not a username there, or the site has no players to ask about.
    ///
    /// The count is clamped here, once, for both sites alike: a number nobody would type on
    /// purpose is a slip, and the useful answer to a slip is the nearest thing that works. With
    /// `since`, only the games begun after it, which is where 自动拉局 carries on from.
    public static func recent(
        of name: String, on site: PGNImport.Site, count: Int, since: Date? = nil
    ) -> FetchPlan? {
        let many = min(max(count, 1), PGNImport.maxRecentGames)
        switch site {
        case .lichess:
            return PGNImport.recentGamesURL(user: name, count: many, since: since)
                .map { .recentLichess($0) }
        case .chessCom:
            return PGNImport.chessComArchivesURL(user: name)
                .map { .recentChessCom(archives: $0, many: many, since: since) }
        case .chessease:
            return nil
        }
    }
}

extension PGNImport.Site {
    /// How this site's door turns typed input into a plan: a username is the player's recent
    /// games (`FetchPlan.recent`), and anything else may still be a link. A failure when it is
    /// neither — the wrong kind of thing typed into the wrong field.
    public func fetchPlan(for input: String, count: Int) -> Result<FetchPlan, PGNImport.Error> {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if self == .chessease { return Self.chesseasePlan(typed) }
        if let recent = FetchPlan.recent(of: typed, on: self, count: count) {
            return .success(recent)
        }
        guard let candidates = PGNImport.candidateURLs(for: typed) else {
            return .failure(.notAPlayer(self))
        }
        return .success(.links(candidates))
    }

    /// A 国象联盟 share link's plan: the game is in the fragment, or the link is cut short.
    private static func chesseasePlan(_ typed: String) -> Result<FetchPlan, PGNImport.Error> {
        guard let shared = PGNImport.chesseaseGame(in: typed) else {
            return .failure(.notAPlayer(.chessease))
        }
        switch shared {
        case .success(let pgn): return .success(.carried(pgn: pgn))
        case .failure(let failure): return .failure(failure)
        }
    }
}

extension ImportDoors.Door {
    /// How the door open now turns what is in its field into a plan.
    ///
    /// **The one place a 国象联盟 share link is recognised.** It used to be sniffed twice — at
    /// `ImportDoors.init` to pick the door, and again at `ImportSession.run` to skip the
    /// download — so a fifth door that recognised its own input would have needed a third sniff.
    public func fetchPlan(
        for input: String, count: Int
    ) -> Result<FetchPlan, PGNImport.Error> {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let site else {
            // The plain link door takes any link at all — and a 国象联盟 share link *is* a link,
            // it just carries its game with it. `recognising` is the one sniff; this door uses
            // it rather than keeping a second one of its own.
            if Self.recognising(typed) == .chessease {
                return PGNImport.Site.chessease.fetchPlan(for: typed, count: count)
            }
            guard let candidates = PGNImport.candidateURLs(for: typed) else {
                return .failure(.notALink)
            }
            return .success(.links(candidates))
        }
        return site.fetchPlan(for: typed, count: count)
    }


    /// The door a pasted input belongs to. One sniff, shared by the sheet picking its door and
    /// anything else that has text and no door.
    public static func recognising(_ input: String) -> ImportDoors.Door {
        PGNImport.chesseaseGame(in: input) != nil ? .chessease : .link
    }
}

extension FetchPlan {
    /// The text of every game this plan holds, in the order the player should see them.
    ///
    /// One walk per plan. A link plan tries its candidates in order and keeps the first that
    /// parses; a chess.com plan walks the newest months back. Everything downstream — split,
    /// name, write — is the same for all four doors (`ImportSession.read`).
    public func text(fetching: any PGNFetching, asked: String?) async throws -> String {
        switch self {
        case .carried(let pgn):
            return pgn
        case .links(let candidates):
            var lastError = PGNImport.Error.notPGN
            for candidate in candidates {
                let text: String
                do {
                    text = try await fetching.fetch(candidate)
                } catch let failure as PGNImport.Error {
                    lastError = failure
                    continue
                } catch {
                    lastError = .network(error.localizedDescription)
                    continue
                }
                // Split and parse once. This used to call `chapters(in:)` twice on the same text
                // to choose between `.notPGN` and `.noReadableGames`, before `read` ran the cut
                // a third time.
                let (found, unreadable) = PGNImport.chapters(in: text)
                guard found.first != nil else {
                    lastError = unreadable > 0 ? .noReadableGames : .notPGN
                    continue
                }
                return text
            }
            throw lastError
        case .recentLichess(let url):
            return try await fetching.fetch(url)
        case .recentChessCom(let archives, let many, let since):
            let name = asked ?? ""
            let list = try await fetching.fetch(archives)
            // A JSON list that will not parse is the site handing back something we cannot read
            // as a list of games — not "what came down is not a PGN", which is what this used to
            // say and what the player had no way to act on.
            guard let months = Self.archives(in: list) else {
                throw PGNImport.Error.unreadableArchives(.chessCom, name)
            }
            guard !months.isEmpty else {
                if since != nil { return "" }
                throw PGNImport.Error.noGames(.chessCom, name)
            }
            // Newest month first, and each month's games newest first: chess.com lists a month
            // oldest-game-first, and "the last ten" are the ten at its end.
            var text = ""
            var gathered = 0
            for month in months.prefix(Self.monthsBack) {
                if let since, !Self.month(month, reaches: since) { break }
                let pgn = try await fetching.fetch(month.appending(path: "pgn"))
                let blocks = PGN.split(pgn).reversed()
                text += blocks.joined(separator: "\n\n") + "\n\n"
                gathered += blocks.count
                if gathered >= many { break }
            }
            guard gathered > 0 else {
                if since != nil { return "" }
                throw PGNImport.Error.noGames(.chessCom, name)
            }
            return PGN.split(text).prefix(many).joined(separator: "\n\n")
        }
    }

    // ------------------------------------------------- the chess.com month walk

    /// How many months back a chess.com import looks. A player who has not played in three
    /// months has no recent games in any sense worth a fourth request.
    private static let monthsBack = 3

    /// The archive URLs in the list chess.com answers with, newest first — nil when what came
    /// down is not that list.
    private static func archives(in text: String) -> [URL]? {
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let archives = object["archives"] as? [String]
        else { return nil }
        return archives.compactMap { URL(string: $0) }.reversed()
    }

    /// Whether a chess.com monthly archive — `…/games/2026/09` — holds any day on or after
    /// `since`. An archive URL that does not end in a year and month is kept: better one request
    /// too many than a month of games skipped.
    private static func month(_ archive: URL, reaches since: Date) -> Bool {
        let parts = archive.pathComponents
        guard parts.count >= 2, let year = Int(parts[parts.count - 2]),
            let month = Int(parts[parts.count - 1])
        else { return true }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let reached = utc.dateComponents([.year, .month], from: since)
        return (year, month) >= (reached.year ?? 0, reached.month ?? 0)
    }
}
