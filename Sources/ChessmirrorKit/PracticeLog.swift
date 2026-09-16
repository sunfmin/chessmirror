import Foundation

/// The one store in this app that is not a game (docs/adr/0029).
///
/// **Append-only, and facts only.** One line per thing that happened, and nothing that was
/// computed from those things: no due date, no interval, no difficulty, no mastered flag. When a
/// position is due is worked out from this log every time it is asked, and that rule is the whole
/// value of the decision — the moment a scheduler's output is written down, changing the
/// scheduler means migrating every row and the app stops being able to change its mind.
///
/// JSON lines rather than a database, for the reason 0029 gives: we do not yet know what the
/// fields are, and a schema committed now would freeze a design that has never run. Two devices
/// append independently and the merge is union, which is only true because there is no state here
/// to disagree about.
public struct PracticeLog: Sendable {
    /// One thing that happened. The kinds grow as the app learns what to record; the rule is that
    /// every one of them is something a person *did*, at a time, and never a conclusion drawn
    /// from what they did.
    public enum Fact: Hashable, Sendable, Codable {
        /// The player struck a position off the book. Not a judgement about the position — a
        /// decision about their own time, and the one thing in the book that is not derived from
        /// the games (docs/adr/0028). No reason is asked for: the app does not get to interrogate
        /// somebody about what they want to practise.
        case dismissed(PositionKey)
        /// The player put one back.
        case restored(PositionKey)
        /// The player practised a position and the app judged the move.
        case drilled(Attempt)
    }

    /// One go at one position (docs/adr/0029).
    ///
    /// **Everything here happened.** Which position, how long it took, whether the move held,
    /// what was played, what it cost, how many hints were open, and where the drill came from.
    /// What is deliberately absent is every field a scheduler would want to cache — no due date,
    /// no interval, no ease, no mastered flag — because the moment one of those is written down,
    /// changing the scheduler means migrating every row a person has ever written.
    public struct Attempt: Hashable, Sendable, Codable {
        public let position: PositionKey
        /// How long the player took over the move. Thinking time, not judging time: the engine's
        /// wait is the app's, not theirs.
        public let seconds: Double
        public let passed: Bool
        /// What was played, in SAN — so a run of attempts reads as what somebody keeps trying.
        public let played: String
        /// What it cost, in percentage points of win probability (docs/adr/0027).
        public let cost: Double
        /// How many rungs of the hint ladder were open when they moved (docs/adr/0031).
        public let hints: Int
        public let source: Drill.Source

        public init(
            position: PositionKey, seconds: Double, passed: Bool, played: String, cost: Double,
            hints: Int, source: Drill.Source
        ) {
            self.position = position
            self.seconds = seconds
            self.passed = passed
            self.played = played
            self.cost = cost
            self.hints = hints
            self.source = source
        }
    }

    public struct Entry: Hashable, Sendable, Codable, Identifiable {
        public let at: Date
        public let fact: Fact

        public var id: String { "\(at.timeIntervalSince1970)-\(fact)" }

        public init(at: Date, fact: Fact) {
            self.at = at
            self.fact = fact
        }
    }

    /// The file. One JSON object per line, so an append is a write to the end and a corrupt line
    /// costs that line rather than the log.
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The app's own log, beside the games. In the container rather than in iCloud's Documents,
    /// because it is not a document: nobody drags this out and reads it.
    public static var standard: PracticeLog {
        PracticeLog(url: URL.documentsDirectory.appending(path: "practice.jsonl"))
    }

    // ----------------------------------------------------------------- appending

    /// Adds one fact. Never rewrites what is already there.
    public func append(_ fact: Fact, at moment: Date = Date()) {
        guard let line = try? Self.encoder.encode(Entry(at: moment, fact: fact)),
            let text = String(data: line, encoding: .utf8)
        else { return }
        let row = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: row)
        } else {
            try? row.write(to: url, options: .atomic)
        }
    }

    // ------------------------------------------------------------------ reading

    /// Every entry, oldest first. A line that will not decode is skipped rather than throwing:
    /// one bad row must not cost the history.
    public func entries() -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? Self.decoder.decode(Entry.self, from: data)
        }
    }

    /// The positions the player has struck off and not put back.
    ///
    /// Computed from the log rather than stored, like everything else here: the last word about a
    /// position wins, so restoring one is an append and never an edit.
    public func dismissed() -> Set<PositionKey> { Self.dismissed(in: entries()) }

    /// The same, over entries already read. The index reads the file once and asks both
    /// questions of what came back, rather than parsing it twice on every rebuild.
    public static func dismissed(in entries: [Entry]) -> Set<PositionKey> {
        var standing: [PositionKey: Bool] = [:]
        for entry in entries {
            switch entry.fact {
            case .dismissed(let key): standing[key] = true
            case .restored(let key): standing[key] = false
            case .drilled: continue
            }
        }
        return Set(standing.filter(\.value).keys)
    }

    /// Every go at every position, oldest first.
    ///
    /// Read out of the log each time rather than counted up and stored, which is the rule the
    /// whole file is built on: a total is a conclusion, and conclusions are what this refuses to
    /// keep (docs/adr/0029).
    public func attempts() -> [(at: Date, attempt: Attempt)] { Self.attempts(in: entries()) }

    public static func attempts(in entries: [Entry]) -> [(at: Date, attempt: Attempt)] {
        entries.compactMap { entry in
            guard case .drilled(let attempt) = entry.fact else { return nil }
            return (entry.at, attempt)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // One line per entry, so the file stays appendable.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
