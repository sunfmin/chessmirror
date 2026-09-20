import Foundation

/// The one way a PGN link becomes games in the library, whichever door it came in
/// through (docs/adr/0014).
///
/// A link — a lichess study page is the canonical case — is downloaded, the multi-game
/// PGN split into one block per chapter, and each chapter becomes one file in the
/// library, one file per game. The pure reading lives here as a caseless enum
/// and the one thing with state — where the download has got to — is `ImportSession`,
/// the same split `BoardIntake` and `GameSession` use.
public enum PGNImport {
    public enum Status: Equatable, Sendable {
        case notImported
        case awaitingReview
        /// In the library's review chain: waiting its turn while `total` is still zero, then
        /// being judged, `judged` of `total` positions settled.
        case scoring(ImportReview.Progress)
        case ready(Int)

        public var label: String {
            switch self {
            case .notImported: localized("import.status.new")
            case .awaitingReview: localized("import.status.pending")
            case .scoring(let progress):
                progress.total == 0
                    ? localized("import.status.queued")
                    : localized("import.status.scoring", progress.judged, progress.total)
            case .ready(let count): localized("import.status.ready", count)
            }
        }

        /// Where an imported game stands: being scored, waiting for its Review, or ready — with
        /// how many positions the 错题本 holds against it. The count is the book's own
        /// (`MistakeIndex.wrongByGame`), so the number a chapter reports and the number on the
        /// game's row in the library are one number, under the player's lines, less what has been
        /// struck off. The library used to keep a second count of its own here, under the default
        /// lines, and the two could disagree.
        @MainActor
        public init(_ entry: GameLibrary.Entry, in library: GameLibrary, book index: MistakeIndex) {
            if let progress = library.reviewing[entry.url] {
                self = .scoring(progress)
            } else if entry.pgn?.game.isReviewed != true {
                self = .awaitingReview
            } else {
                self = .ready(index.wrongByGame[entry.url] ?? 0)
            }
        }
    }
    // ----------------------------------------------------------------- sites

    /// Where games come from. Named here so an error can say which one it is talking about
    /// and a remembered username can say which one it belongs to (docs/adr/0045).
    ///
    /// Two of them hand over somebody's recent games by username; the third has no such door
    /// and shares one game at a time as a link that carries the whole game inside it.
    public enum Site: String, CaseIterable, Hashable, Sendable, Codable {
        case lichess
        case chessCom
        /// 国象联盟, the Chinese platform at chessease.net.
        case chessease

        /// The name the site goes by on its own front page, which is the only name anyone
        /// types it as. Not localised: a brand is the same word in every language.
        public var label: String {
            switch self {
            case .lichess: "lichess"
            case .chessCom: "chess.com"
            case .chessease: "国象联盟"
            }
        }

        /// The sites that answer to a username at all.
        public static let withPlayers: [Site] = [.lichess, .chessCom]

        /// A username somebody on this site would recognise as one, for the message that says
        /// what one looks like.
        public var exampleUser: String {
            switch self {
            case .lichess: "DrNykterstein"
            case .chessCom: "Hikaru"
            case .chessease: ""
            }
        }
    }

    // ---------------------------------------------------------------- errors

    /// What went wrong, one case per way an import can die. The wording of a failure
    /// follows from the case rather than from the call site, so every door shows the
    /// same message for the same failure (`BoardIntake.Intake.alert` convention).
    ///
    /// A failure about a person carries the site and the name as typed, so the message can
    /// say 「chess.com 上没有 sunfmn」 rather than 「没有这个用户」: the one thing the reader wants
    /// to check is the spelling, and the message shows them what they spelt.
    public enum Error: Swift.Error, Hashable, Sendable {
        /// The input is not a link at all.
        case notALink
        /// The server says this study is not public. Private and unlisted studies
        /// answer 403 to anyone who is not a member, and v1 only imports public ones.
        case privateStudy
        /// The game is there but not ours to read.
        case privateGame
        /// There is no such game. A mistyped id and a deleted game look the same from here,
        /// and the message says both rather than picking one.
        case missingGame
        /// The site has no player of that name.
        case unknownPlayer(Site, String)
        /// What was typed is not a username at all.
        case notAPlayer(Site)
        /// The player exists but the site holds no games of theirs to hand over.
        case noGames(Site, String)
        /// A 国象联盟 link that does not carry a game after all — cut short by whatever it was
        /// pasted through, or not a share link to begin with.
        case unreadableShare
        /// The link downloaded, but what came down is not a PGN.
        case notPGN
        /// It is a PGN, but not one game in it parses.
        case noReadableGames
        /// The server answered with an HTTP status that means no.
        case http(Int)
        /// The network itself failed.
        case network(String)

        public var alert: (title: String, message: String) {
            switch self {
            case .notALink:
                (localized("import.notALink.title"), localized("import.notALink.message"))
            case .privateStudy:
                (localized("import.privateStudy.title"), localized("import.privateStudy.message"))
            case .privateGame:
                (localized("import.privateGame.title"), localized("import.privateGame.message"))
            case .missingGame:
                (localized("import.missingGame.title"), localized("import.missingGame.message"))
            case .unknownPlayer(let site, let name):
                (
                    localized("import.unknownPlayer.title", site.label, name),
                    localized("import.unknownPlayer.message", site.label, name)
                )
            case .notAPlayer(let site):
                (
                    localized("import.notAPlayer.title"),
                    localized("import.notAPlayer.message", site.label, site.exampleUser)
                )
            case .noGames(let site, let name):
                (
                    localized("import.noGames.title", site.label, name),
                    localized("import.noGames.message", site.label, name)
                )
            case .unreadableShare:
                (
                    localized("import.unreadableShare.title"),
                    localized("import.unreadableShare.message")
                )
            case .notPGN:
                (localized("import.notPGN.title"), localized("import.notPGN.message"))
            case .noReadableGames:
                (
                    localized("import.noReadableGames.title"),
                    localized("import.noReadableGames.message")
                )
            case .http(let code):
                (localized("import.http.title"), localized("import.http.message", code))
            case .network(let detail):
                (localized("import.network.title"), localized("import.network.message", detail))
            }
        }

        /// Which failure an HTTP status means, given the URL it came from.
        ///
        /// Pure, and here rather than inside the fetcher, because "what does a 403 mean" is a
        /// statement about lichess and not about `URLSession`: 403 on a study is a study nobody
        /// outside it may read, 404 on a game export is a game that is not there, and 404 on the
        /// user endpoint is a person who does not exist. chess.com answers 404 for a player it
        /// has never heard of, on any of that player's pages. Anything else is the status
        /// itself, said plainly.
        public static func from(status: Int, url: URL) -> Self {
            let path = url.path
            if let name = chessComPlayer(in: url) {
                switch status {
                case 404: return .unknownPlayer(.chessCom, name)
                default: return .http(status)
                }
            }
            guard isLichess(url) else { return .http(status) }
            switch status {
            case 403: return path.contains("/study/") ? .privateStudy : .privateGame
            case 404 where path.contains("/api/games/user/"):
                let name = url.pathComponents.drop { $0 != "user" }.dropFirst().first ?? ""
                return .unknownPlayer(.lichess, name)
            case 404 where path.contains("/game/export/"): return .missingGame
            default: return .http(status)
            }
        }
    }

    // ------------------------------------------------------------- fetching

    /// One game downloaded and read, written under its chapter's name.
    public struct ImportChapter: Hashable, Sendable, Identifiable {
        /// Position in the study, one-based — the last-resort name falls back on it.
        public let id: Int
        public let name: String
        public let pgn: PGN

        public init(id: Int, name: String, pgn: PGN) {
            self.id = id
            self.name = name
            self.pgn = pgn
        }

        /// What dedup compares this against — see `PGNImport.identity(of:named:)`.
        public var identity: String { PGNImport.identity(of: pgn, named: name) }
    }

    /// Everything the download found, ready to be applied.
    public struct ImportPlan: Hashable, Sendable {
        public let chapters: [ImportChapter]
        /// Chapters that were there but would not parse. Counted rather than fatal —
        /// one broken chapter must not take the whole study down, and the count is
        /// the report (`GameLibrary.Entry` lists unreadable files for the same reason).
        public let unreadable: Int

        public init(chapters: [ImportChapter], unreadable: Int) {
            self.chapters = chapters
            self.unreadable = unreadable
        }
    }

    /// What applying a plan did, once it is a matter of record.
    public struct ImportOutcome: Hashable, Sendable {
        public let imported: Int
        /// Chapters skipped because that game was already in the library.
        public let skipped: Int
        public let unreadable: Int

        public init(imported: Int, skipped: Int, unreadable: Int) {
            self.imported = imported
            self.skipped = skipped
            self.unreadable = unreadable
        }

        /// The one sentence the screen shows. Each clause only when it happened — a
        /// clean import should say one thing and stop.
        public var message: String {
            var parts = [localized("import.done", plural: imported)]
            if skipped > 0 { parts.append(localized("import.done.skipped", plural: skipped)) }
            if unreadable > 0 {
                parts.append(localized("import.done.unreadable", plural: unreadable))
            }
            return parts.joined(separator: localized("clause.separator"))
                + localized("sentence.end")
        }
    }

    // ------------------------------------------------------------ candidates

    /// The URLs to try, in order, for a pasted link.
    ///
    /// Nil for input that is not a link at all. A lichess study page exports its whole
    /// study one suffix away — the site URL plus `.pgn` is the documented endpoint —
    /// so a study URL that is not already the export gets two candidates: itself
    /// (which works when it is already a PGN wearing a study's URL, e.g. a chapter
    /// export) and the study-level `.pgn`, which is what actually holds every chapter.
    /// A chapter *page* URL falls through its HTML to the study export, which is what
    /// pasting a chapter link out of a browser should do: import the whole study.
    ///
    /// The scheme is added when a paste drops it, because "lichess.org/study/x" is
    /// what a person copies and it is not this function's business to make them type
    /// `https://`.
    public static func candidateURLs(for input: String) -> [URL]? {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme), url.host != nil
        else { return nil }
        if let studyID = lichessStudyID(from: url) {
            return [url, URL(string: "https://lichess.org/study/\(studyID).pgn")!]
        }
        // A game page holds no PGN at all, so there is nothing to fall through from: the
        // export is the only candidate, and if the guess at the id was wrong the 404 says so.
        if let gameID = lichessGameID(from: url) { return [gameExportURL(gameID)] }
        return [url]
    }

    /// The export endpoint for one lichess game.
    public static func gameExportURL(_ id: String) -> URL {
        URL(string: "https://lichess.org/game/export/\(id)?evals=true&clocks=false")!
    }

    /// A player's recent games on lichess, most recent first — nil for anything that is not a
    /// username.
    ///
    /// The count is clamped rather than refused: a number nobody would type on purpose is a
    /// slip, and the useful answer to a slip is the nearest thing that works.
    public static func recentGamesURL(user: String, count: Int) -> URL? {
        guard let name = username(user, on: .lichess) else { return nil }
        let many = min(max(count, 1), maxRecentGames)
        return URL(
            string: "https://lichess.org/api/games/user/\(name)?max=\(many)"
                + "&evals=true&clocks=false&sort=dateDesc"
        )
    }

    /// The list of a chess.com player's monthly archives — nil for anything that is not a
    /// username. chess.com hands games over a month at a time, so "the last few" is a walk
    /// back from the newest month (`ImportSession.recent`), and this is where the walk starts.
    public static func chessComArchivesURL(user: String) -> URL? {
        guard let name = username(user, on: .chessCom) else { return nil }
        return URL(string: "https://api.chess.com/pub/player/\(name.lowercased())/games/archives")
    }

    /// The PGN of one monthly archive, given the archive's own URL from the list.
    public static func chessComMonthURL(archive: URL) -> URL {
        archive.appending(path: "pgn")
    }

    /// The archive URLs in the list chess.com answers with, newest first — nil when what came
    /// down is not that list.
    public static func chessComArchives(in text: String) -> [URL]? {
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let archives = object["archives"] as? [String]
        else { return nil }
        return archives.compactMap { URL(string: $0) }.reversed()
    }

    /// How many months back a chess.com import looks. A player who has not played in three
    /// months has no recent games in any sense worth a fourth request.
    public static let chessComMonthsBack = 3

    /// The name as the site would accept it — nil when what was typed is not a username there.
    ///
    /// The `@` people type in front of a handle is not part of it. Beyond that: letters,
    /// digits, underscores and hyphens, which is what both sites allow. Anything else — a
    /// space, a slash, a whole URL pasted into the wrong field — is not one.
    public static func username(_ typed: String, on site: Site) -> String? {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("@") { name.removeFirst() }
        guard site != .chessease, !name.isEmpty, name.count <= 30,
            name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { return nil }
        return name
    }

    /// The player a chess.com API URL is about, nil for any other URL.
    static func chessComPlayer(in url: URL) -> String? {
        guard url.host?.lowercased() == "api.chess.com" else { return nil }
        let parts = url.pathComponents
        guard parts.count >= 4, parts[1] == "pub", parts[2] == "player" else { return nil }
        return parts[3]
    }

    static func isLichess(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "lichess.org" || host.hasSuffix(".lichess.org")
    }

    // ------------------------------------------------------------- 国象联盟

    /// The game a 国象联盟 share link carries — nil for a link that is not one.
    ///
    /// 国象联盟 has no export endpoint. What it has is a share link whose fragment *is* the
    /// game: `app.chessease.net/pgn/#…`, the part after the `#` being a JSON object, brotli
    /// compressed and base64url encoded, whose `p` is the PGN. Nothing is fetched; the link is
    /// read the way the site's own viewer reads it. A link that has the shape but will not
    /// decode is a share link cut short, and `.unreadableShare` says so.
    public static func chesseaseGame(in input: String) -> Result<String, Error>? {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), let host = url.host?.lowercased(),
            host == "chessease.net" || host.hasSuffix(".chessease.net")
        else { return nil }
        guard let fragment = url.fragment, !fragment.isEmpty else { return .failure(.unreadableShare) }
        var padded = fragment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        guard let packed = Data(base64Encoded: padded),
            let unpacked = Brotli.decode(packed),
            let object = try? JSONSerialization.jsonObject(with: unpacked) as? [String: Any],
            let pgn = object["p"] as? String, !pgn.isEmpty
        else { return .failure(.unreadableShare) }
        return .success(pgn)
    }

    /// How many recent games one import may ask for. A ceiling because this is the thing you
    /// do before getting on a plane, not a way to mirror an account: lichess streams these one
    /// at a time and a library is a folder of files somebody has to be able to look at.
    public static let maxRecentGames = 100

    /// The default count offered, which is about a session's worth of games.
    public static let recentGames = 10

    /// The study a lichess URL names, nil for anything else or for a URL that is
    /// already an export. The study id is the first path component after `/study/`;
    /// anything after it is a chapter, and anything before the study id is a
    /// different page.
    private static func lichessStudyID(from url: URL) -> String? {
        guard isLichess(url) else { return nil }
        let parts = url.pathComponents
        guard parts.count >= 3, parts[1] == "study", !parts[2].isEmpty else { return nil }
        let studyID = parts[2]
        guard !studyID.hasSuffix(".pgn") else { return nil }
        return studyID
    }

    /// The game a lichess URL names, nil for anything else.
    ///
    /// A game lives at the root of the site — `lichess.org/hf3Zpe5R` — optionally with the
    /// colour it was watched as on the end, and the id is eight characters (twelve when the
    /// link is a player's own, where the extra four are their private token). That shape is the
    /// whole test, plus a short list of the site's own pages that happen to be eight letters
    /// long. A page this misreads as a game costs one 404 and an honest error, which is why a
    /// list of a dozen names is enough and a list of every page lichess has is not needed.
    private static func lichessGameID(from url: URL) -> String? {
        guard isLichess(url) else { return nil }
        let parts = url.pathComponents.dropFirst()  // the leading "/"
        guard let first = parts.first, !first.isEmpty else { return nil }
        guard parts.count == 1 || (parts.count == 2 && ["white", "black"].contains(parts.last!))
        else { return nil }
        guard first.count == 8 || first.count == 12,
            first.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
            !reservedPaths.contains(first.lowercased())
        else { return nil }
        return String(first.prefix(8))
    }

    /// The site's own pages that are eight or twelve characters of letters, and so would
    /// otherwise read as game ids.
    private static let reservedPaths: Set<String> = [
        "training", "analysis", "practice", "streamer", "insights", "features", "download",
        "password", "openings", "timeline", "tournament", "broadcast", "puzzletheme",
    ]

    // -------------------------------------------------------------- splitting

    // --------------------------------------------------------------- reading

    /// Every game in a multi-game PGN, parsed, with the chapters that would not
    /// parse counted alongside (`ImportPlan.unreadable`).
    public static func chapters(in text: String) -> (chapters: [ImportChapter], unreadable: Int) {
        var chapters: [ImportChapter] = []
        var unreadable = 0
        for (index, block) in PGN.split(text).enumerated() {
            guard let pgn = try? PGN(parsing: block) else {
                unreadable += 1
                continue
            }
            chapters.append(
                ImportChapter(id: index + 1, name: name(for: pgn, chapter: index + 1), pgn: pgn)
            )
        }
        return (chapters, unreadable)
    }

    /// The name one chapter is written under — what the list shows and what dedup
    /// runs on. Never empty and never a shared placeholder: rows that all read the
    /// same cannot be told apart, and a dedup that cannot tell them apart skips
    /// chapters that are not duplicates.
    ///
    /// Each step only when it says something: `ChapterName` is the lichess name for
    /// exactly this; `Event` names the study the chapter belongs to; the players are
    /// only a name when at least one of them is known (a whole study of `? 对 ?`
    /// would dedup into one game); `Date` skips PGN's `????.??.??`. Whatever is
    /// left, the chapter's position in the study is its name — "第 N 章" is true
    /// even when nothing else is.
    ///
    /// `Event` values that name nothing: this app's own name, which every game it has ever
    /// written carries, and PGN's two ways of saying it does not know.
    static let namelessEvents: Set<String> = ["Chessmirror", "?", ""]

    public static func name(for pgn: PGN, chapter ordinal: Int) -> String {
        if let chapterName = pgn.tag(PGN.Tags.chapterName), !chapterName.isEmpty { return chapterName }
        // A lichess or chess.com game before the Event check, because its Event is "Rated Blitz
        // game" or "Live Chess" — true of a million of them, and a name every game in an
        // import would share. Who played and when is what tells one of somebody's Tuesday
        // games from the next.
        if siteGameID(of: pgn) != nil, let played = playersAndDate(of: pgn) { return played }
        if let event = pgn.tag(PGN.Tags.event), !event.isEmpty, !Self.namelessEvents.contains(event) {
            return event
        }
        let white = pgn.playerName(.white) ?? "?"
        let black = pgn.playerName(.black) ?? "?"
        if white != "?" || black != "?" { return localized("import.name.players", white, black) }
        if let date = PGN.playedOn(pgn.tag(PGN.Tags.date)) { return date }
        return localized("import.name.chapter", ordinal)
    }

    /// The side a named account played in a game — nil when it played neither. Case does not
    /// count, because the sites' URLs lowercase a name their pages spell with capitals, and the
    /// `@` people type in front of a handle is not part of it.
    public static func side(of player: String, in pgn: PGN) -> PieceColour? {
        var name = player.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("@") { name.removeFirst() }
        guard !name.isEmpty else { return nil }
        if pgn.playerName(.white)?.caseInsensitiveCompare(name) == .orderedSame { return .white }
        if pgn.playerName(.black)?.caseInsensitiveCompare(name) == .orderedSame { return .black }
        return nil
    }

    /// How a game went for one side, in a word — nil for a game with no result yet.
    public static func verdict(for side: PieceColour, in pgn: PGN) -> String? {
        switch pgn.tag(PGN.Tags.result) {
        case "1-0": localized(side == .white ? "import.row.won" : "import.row.lost")
        case "0-1": localized(side == .black ? "import.row.won" : "import.row.lost")
        case "1/2-1/2": localized("import.row.drawn")
        default: nil
        }
    }

    /// When a game was played, as the file says it: the day, and the time when there is one.
    public static func playedAt(_ pgn: PGN) -> String? {
        let date = [pgn.tag(PGN.Tags.utcDate), pgn.tag(PGN.Tags.date)]
            .compactMap { $0 }
            .first { !$0.isEmpty && $0 != "????.??.??" }
        guard var when = date else { return nil }
        if let time = pgn.tag(PGN.Tags.utcTime), time.count >= 5 { when += " \(time.prefix(5))" }
        return when
    }

    /// A game named by who played it and when — nil when the file does not say who.
    ///
    /// The time as well as the day when there is one, because two people who play each other
    /// play each other more than once an evening, and two rows a person cannot tell apart are
    /// two rows they cannot choose between.
    private static func playersAndDate(of pgn: PGN) -> String? {
        let white = pgn.playerName(.white) ?? "?"
        let black = pgn.playerName(.black) ?? "?"
        guard white != "?" || black != "?" else { return nil }
        var name = localized("import.name.players", white, black)
        let date = [pgn.tag(PGN.Tags.utcDate), pgn.tag(PGN.Tags.date)]
            .compactMap { $0 }
            .first { !$0.isEmpty && $0 != "????.??.??" }
        if let date { name += " · \(date)" }
        if let time = pgn.tag(PGN.Tags.utcTime), time.count >= 5 { name += " \(time.prefix(5))" }
        return name
    }

    /// What dedup compares one game against another by.
    ///
    /// A lichess or chess.com game has a canonical URL of its own, which is the one true
    /// answer to "is this the same game": the same game imported twice, under two names, from
    /// two doors, is one game. Everything else falls back to the name, which is what a study
    /// chapter is told apart by — a chapter is named by the person who owns it and has no id
    /// of its own.
    public static func identity(of pgn: PGN, named name: String) -> String {
        siteGameID(of: pgn) ?? name
    }

    /// The game this file is on the site it came from, as `site:id` — nil for a file no site
    /// gave an id to. lichess writes its URL into `Site`; chess.com writes it into `Link`.
    private static func siteGameID(of pgn: PGN) -> String? {
        if let site = pgn.tag(PGN.Tags.site), let url = URL(string: site),
            let id = lichessGameID(from: url)
        {
            return "lichess:\(id)"
        }
        if let link = pgn.tag(PGN.Tags.link), let url = URL(string: link),
            let host = url.host?.lowercased(),
            host == "chess.com" || host.hasSuffix(".chess.com"),
            let id = url.pathComponents.last, id.allSatisfy(\.isNumber), !id.isEmpty
        {
            return "chesscom:\(id)"
        }
        return nil
    }

    // -------------------------------------------------------------- applying

    /// The chapters to write, minus any the library already holds.
    ///
    /// Keyed on `ImportChapter.identity`: a lichess game is the game its own URL names, and
    /// everything else is its name. Importing the same study or the same twenty games again
    /// must add nothing, and a chapter twice over inside one study — lichess lets chapters
    /// share a name — cannot produce two files that read identically. Skipped rather than
    /// renamed, because two chapters with one name have to be told apart by the person who
    /// owns them, and the report says how many were skipped.
    public static func toWrite(
        _ chapters: [ImportChapter], avoiding existing: Set<String>
    ) -> (chapters: [ImportChapter], skipped: Int) {
        var taken = existing
        var kept: [ImportChapter] = []
        var skipped = 0
        for chapter in chapters {
            guard taken.insert(chapter.identity).inserted else {
                skipped += 1
                continue
            }
            kept.append(chapter)
        }
        return (kept, skipped)
    }
}

// ------------------------------------------------------------------ fetching

/// Downloads one URL into its text. A protocol rather than a straight call because
/// it is the one thing in an import that cannot be asked twice for the same answer —
/// the network is out there, and tests need a scripted one (`ScriptedEngine`
/// convention).
public protocol PGNFetching: Sendable {
    func fetch(_ url: URL) async throws -> String
}

/// The real fetcher. A `URLSession` call, no state, safe from anywhere.
///
/// The failures are translated into `PGNImport.Error` cases here rather than at each
/// call site: a 403 from lichess *is* the private-study story, and a download that
/// will not decode as UTF-8 was never a PGN.
public struct URLSessionPGNFetcher: PGNFetching, Sendable {
    public init() {}

    public func fetch(_ url: URL) async throws -> String {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw PGNImport.Error.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PGNImport.Error.network(localized("import.network.notHTTP"))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PGNImport.Error.from(status: http.statusCode, url: url)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw PGNImport.Error.notPGN
        }
        return text
    }
}

// ------------------------------------------------------------------ session

/// One import, from a pasted link to games on disk. The state is the phase; the
/// reading happens off the main thread and comes back as a `PGNImport.ImportPlan`,
/// which is when it stops being about the network and starts being about the library.
@Observable @MainActor public final class ImportSession {
    public enum Phase: Equatable, Sendable {
        case idle
        case fetching
        case ready(PGNImport.ImportPlan)
        case failed(PGNImport.Error)
    }

    public private(set) var phase: Phase = .idle

    /// What the last `apply` did to the plan on screen, for the sheet to report under the list.
    /// The plan stays: applying it is not the end of it, since every game in it can still be
    /// opened, and now has a standing in the library to show.
    public private(set) var applied: PGNImport.ImportOutcome?

    private let fetcher: any PGNFetching

    public init(fetcher: any PGNFetching = URLSessionPGNFetcher()) {
        self.fetcher = fetcher
    }

    /// Downloads the link and reads what comes down.
    ///
    /// The candidates are tried in order — the study's `.pgn` variant is what a page
    /// link falls through to — and a candidate that downloads but yields no readable
    /// game fails the way a fetch does: an HTML page is not the wrong answer to stop
    /// at when the same URL plus `.pgn` is the right one. The last failure is the
    /// one shown, because it is the one that would have succeeded.
    public func run(_ input: String) async {
        // A 国象联盟 share link carries its game with it: nothing to download, and the reading
        // is the same reading a downloaded PGN gets.
        if let shared = PGNImport.chesseaseGame(in: input) {
            switch shared {
            case .success(let pgn): await read { pgn }
            case .failure(let failure): phase = .failed(failure)
            }
            return
        }
        guard let candidates = PGNImport.candidateURLs(for: input) else {
            phase = .failed(.notALink)
            return
        }
        await run(candidates)
    }

    /// The other door: somebody's recent games, newest first.
    ///
    /// The same pipeline — one download, split, one file per game — because a multi-game PGN
    /// is a multi-game PGN whether lichess calls it a study or an account's history. chess.com
    /// keeps that history a month to a file, so its door is a short walk back through the
    /// newest months until there are enough games or the months run out
    /// (`PGNImport.chessComMonthsBack`).
    public func recent(
        of user: String, count: Int = PGNImport.recentGames, on site: PGNImport.Site = .lichess
    ) async {
        let typed = user.trimmingCharacters(in: .whitespacesAndNewlines)
        switch site {
        case .lichess:
            guard let url = PGNImport.recentGamesURL(user: typed, count: count) else {
                phase = .failed(.notAPlayer(.lichess))
                return
            }
            await run([url], asked: typed)
        case .chessCom:
            guard let archives = PGNImport.chessComArchivesURL(user: typed) else {
                phase = .failed(.notAPlayer(.chessCom))
                return
            }
            let fetching = fetcher
            let many = min(max(count, 1), PGNImport.maxRecentGames)
            await read(asked: typed) {
                let list = try await fetching.fetch(archives)
                guard let months = PGNImport.chessComArchives(in: list) else {
                    throw PGNImport.Error.notPGN
                }
                guard !months.isEmpty else { throw PGNImport.Error.noGames(.chessCom, typed) }
                // Newest month first, and each month's games newest first: chess.com lists a
                // month oldest-game-first, and "the last ten" are the ten at its end.
                var text = ""
                var gathered = 0
                for month in months.prefix(PGNImport.chessComMonthsBack) {
                    let pgn = try await fetching.fetch(PGNImport.chessComMonthURL(archive: month))
                    let blocks = PGN.split(pgn).reversed()
                    text += blocks.joined(separator: "\n\n") + "\n\n"
                    gathered += blocks.count
                    if gathered >= many { break }
                }
                guard gathered > 0 else { throw PGNImport.Error.noGames(.chessCom, typed) }
                return PGN.split(text).prefix(many).joined(separator: "\n\n")
            }
        case .chessease:
            phase = .failed(.notAPlayer(.chessease))
        }
    }

    private func run(_ candidates: [URL], asked: String? = nil) async {
        let fetching = fetcher
        await read(asked: asked) {
            var lastError: PGNImport.Error = .notPGN
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
                guard PGNImport.chapters(in: text).0.first != nil else {
                    lastError = PGNImport.chapters(in: text).1 > 0 ? .noReadableGames : .notPGN
                    continue
                }
                return text
            }
            throw lastError
        }
    }

    /// The one pipeline behind every door: get the text, split it, and the plan is what was
    /// readable. What differs between doors is only how the text is got, which is `source`.
    ///
    /// A failure about a player comes back naming the player as typed, not as the URL spelt
    /// them — chess.com lowercases its URLs — so the message shows the reader their own
    /// spelling, which is the thing they are about to check.
    private func read(asked: String? = nil, _ source: @escaping @Sendable () async throws -> String) async {
        phase = .fetching
        applied = nil
        // The language goes with it. What comes back off this task is not only a download: it
        // names the games, and a detached task starts outside whatever
        // language was scoped around this one (docs/adr/0019).
        let language = Speech.language
        phase = await Task.detached(priority: .userInitiated) { () -> Phase in
            await Speech.speaking(language) { () -> Phase in
                let text: String
                do {
                    text = try await source()
                } catch let failure as PGNImport.Error {
                    if case .unknownPlayer(let site, _) = failure, let asked {
                        return .failed(.unknownPlayer(site, asked))
                    }
                    return .failed(failure)
                } catch {
                    return .failed(.network(error.localizedDescription))
                }
                let (chapters, unreadable) = PGNImport.chapters(in: text)
                guard !chapters.isEmpty else {
                    return .failed(unreadable > 0 ? .noReadableGames : .notPGN)
                }
                return .ready(PGNImport.ImportPlan(chapters: chapters, unreadable: unreadable))
            }
        }.value
    }

    /// Writes the plan's chapters into the library, one file per game — the same write path a
    /// game played by hand takes (`GameLibrary.write`), so an imported game is a game like any
    /// other.
    ///
    /// Synchronous because it is file writes, which are fast and belong where the
    /// library already is; the download was the part worth taking off the main
    /// thread.
    ///
    /// With an engine, every game written is put in the library's review chain at once
    /// (`GameLibrary.reviewImported`), one after another, so a batch pulled before a flight is
    /// judged by the time the plane is up. A game opened on its own is still analysed on a press
    /// (docs/adr/0044): here the player pressed 入库 for the lot, and that press is the ask.
    ///
    /// With an account, every game is written tracking the side that account played
    /// (docs/adr/0045): the 错题 of a batch pulled by username are that person's, and nobody is
    /// asked ten times what the field already says.
    @discardableResult
    public func apply(
        into library: GameLibrary, as account: String? = nil,
        reviewingWith engine: (any Engine)? = nil
    ) -> PGNImport.ImportOutcome? {
        guard case let .ready(plan) = phase else { return nil }
        // What is already there, by the same identity the incoming games are compared by: a
        // lichess game the library holds is that game whatever it has since been renamed to.
        let existing = Set(
            library.entries.compactMap { entry -> String? in
                guard let pgn = entry.pgn else { return nil }
                return PGNImport.identity(of: pgn, named: entry.name ?? entry.title)
            }
        )
        let (chapters, skipped) = PGNImport.toWrite(plan.chapters, avoiding: existing)
        var imported = 0
        for chapter in chapters {
            var pgn = chapter.pgn
            pgn.setTag(GameLibrary.nameTag, to: chapter.name)
            pgn.setTag(GameOrigin.tagName, to: GameOrigin.imported.tagValue)
            if let account, let side = PGNImport.side(of: account, in: pgn) { pgn.track(side) }
            // A fresh name per chapter, asked right before the write so two chapters
            // landing in one second cannot collide (`GameLibrary.newURL` logic).
            let url = library.newURL()
            guard library.write(pgn, to: url) else { continue }
            imported += 1
            // The entry as just written rather than looked up: an iCloud write lands in the
            // list a hop later, and the review chain waits for the write itself.
            if let engine {
                library.reviewImported(
                    GameLibrary.Entry(url: url, pgn: pgn, modified: Date()), using: engine
                )
            }
        }
        let outcome = PGNImport.ImportOutcome(
            imported: imported, skipped: skipped, unreadable: plan.unreadable
        )
        applied = outcome
        return outcome
    }

    public func open(
        _ chapter: PGNImport.ImportChapter, into library: GameLibrary,
        tracking side: PieceColour? = nil
    ) -> GameLibrary.Entry? {
        if let existing = library.entries.first(where: { entry in
            guard let pgn = entry.pgn else { return false }
            return PGNImport.identity(of: pgn, named: entry.name ?? entry.title) == chapter.identity
        }) {
            guard let side, var pgn = existing.pgn else { return existing }
            pgn.track(side)
            guard library.write(pgn, to: existing.url) else { return nil }
            return GameLibrary.Entry(url: existing.url, pgn: pgn, modified: Date())
        }
        var pgn = chapter.pgn
        if let side { pgn.track(side) }
        pgn.setName(chapter.name)
        pgn.setTag(GameOrigin.tagName, to: GameOrigin.imported.tagValue)
        let url = library.newURL()
        guard library.write(pgn, to: url) else { return nil }
        return GameLibrary.Entry(url: url, pgn: pgn, modified: Date())
    }

    public func status(
        of chapter: PGNImport.ImportChapter, in library: GameLibrary, book index: MistakeIndex
    ) -> PGNImport.Status {
        guard let entry = library.entries.first(where: { entry in
            guard let pgn = entry.pgn else { return false }
            return PGNImport.identity(of: pgn, named: entry.name ?? entry.title) == chapter.identity
        }) else { return .notImported }
        return PGNImport.Status(entry, in: library, book: index)
    }

    /// Back to a blank slate, for the "再导入一个" that follows a done import.
    public func reset() {
        phase = .idle
        applied = nil
    }
}
