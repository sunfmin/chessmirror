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
    case recentChessCom(archives: URL, many: Int)
}

extension PGNImport.Site {
    /// How this site's door turns typed input into a plan. Nil when the input is not this door's
    /// — the wrong kind of thing typed into the wrong field.
    ///
    /// `asked` is the name as typed, which is what a failure about a person names — not as the
    /// URL spelt them (chess.com lowercases its URLs), so the message shows the reader their own
    /// spelling, which is the thing they are about to check.
    public func fetchPlan(
        for input: String, count: Int, asked: String? = nil
    ) -> Result<FetchPlan, PGNImport.Error> {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .lichess:
            if let url = PGNImport.recentGamesURL(user: typed, count: count) {
                return .success(.recentLichess(url))
            }
            // Not a username: maybe a link.
            guard let candidates = PGNImport.candidateURLs(for: typed) else {
                return .failure(.notAPlayer(.lichess))
            }
            return .success(.links(candidates))
        case .chessCom:
            if let archives = PGNImport.chessComArchivesURL(user: typed) {
                let many = min(max(count, 1), PGNImport.maxRecentGames)
                return .success(.recentChessCom(archives: archives, many: many))
            }
            guard let candidates = PGNImport.candidateURLs(for: typed) else {
                return .failure(.notAPlayer(.chessCom))
            }
            return .success(.links(candidates))
        case .chessease:
            return Self.chesseasePlan(typed)
        }
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
        case .recentChessCom(let archives, let many):
            let name = asked ?? ""
            let list = try await fetching.fetch(archives)
            // A JSON list that will not parse is the site handing back something we cannot read
            // as a list of games — not "what came down is not a PGN", which is what this used to
            // say and what the player had no way to act on.
            guard let months = PGNImport.chessComArchives(in: list) else {
                throw PGNImport.Error.unreadableArchives(.chessCom, name)
            }
            guard !months.isEmpty else { throw PGNImport.Error.noGames(.chessCom, name) }
            // Newest month first, and each month's games newest first: chess.com lists a month
            // oldest-game-first, and "the last ten" are the ten at its end.
            var text = ""
            var gathered = 0
            for month in months.prefix(PGNImport.chessComMonthsBack) {
                let pgn = try await fetching.fetch(PGNImport.chessComMonthURL(archive: month))
                let blocks = PGN.split(pgn).reversed()
                text += blocks.joined(separator: "\n\n") + "\n\n"
                gathered += blocks.count
                if gathered >= many { break }
            }
            guard gathered > 0 else { throw PGNImport.Error.noGames(.chessCom, name) }
            return PGN.split(text).prefix(many).joined(separator: "\n\n")
        }
    }
}
