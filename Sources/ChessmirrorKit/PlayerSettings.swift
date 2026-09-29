import Foundation
import Observation

/// Where the player's settings are kept (docs/adr/0012): a key and a property-list value.
///
/// A seam because there are two adapters. The app's keeps every value in two places at once
/// (`TravellingSettings`); a test's keeps them in a dictionary for as long as the test runs
/// (`InMemorySettings`), which is what lets a setting be asked about without a simulator, a
/// phone's `UserDefaults` or an iCloud account.
@MainActor public protocol SettingsStore: AnyObject {
    /// The value last written under the key here or on another device, or nil for a key nobody
    /// has written — which is not the same as a zero somebody chose.
    func object(forKey key: String) -> Any?
    /// Writes the value, or takes the key out for nil.
    func set(_ value: Any?, forKey key: String)
    /// Called when the values changed under the app — another device had its say.
    var onChange: (() -> Void)? { get set }
}

/// Both stores, always. iCloud's is the one that travels; `UserDefaults` is the one that answers
/// at launch before iCloud's has been read back off the network, and the only one on a device
/// with no account. iCloud wins when both have an answer: disagreement means another device has
/// since had a say.
@MainActor public final class TravellingSettings: SettingsStore {
    private let defaults: UserDefaults
    private let cloud = NSUbiquitousKeyValueStore.default
    public var onChange: (() -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        cloud.synchronize()
    }

    public func object(forKey key: String) -> Any? {
        cloud.object(forKey: key) ?? defaults.object(forKey: key)
    }

    public func set(_ value: Any?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
            cloud.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
            cloud.removeObject(forKey: key)
        }
        cloud.synchronize()
    }
}

/// A store that lasts as long as the object: what a test hands in.
@MainActor public final class InMemorySettings: SettingsStore {
    public private(set) var values: [String: Any]
    public var onChange: (() -> Void)?

    public init(_ values: [String: Any] = [:]) {
        self.values = values
    }

    public func object(forKey key: String) -> Any? { values[key] }

    public func set(_ value: Any?, forKey key: String) { values[key] = value }

    /// Another device writing: the value changes under the app, and the app is told.
    public func arrive(_ value: Any?, forKey key: String) {
        values[key] = value
        onChange?()
    }
}

/// Everything the player has set, remembered across launches and devices (docs/adr/0012).
///
/// The kit holds what each of these *means* — `JudgementLines`, `Strength`, `SearchLimit`,
/// `Language` — and this is where they are kept. It was five classes in the app and a switch on
/// the speaker, each spelling the same two stores, the same "iCloud first" read, the same
/// notification and the same reach for its own `shared` from inside it; so whether 入列线 was
/// dragged up with 记录线 on the next launch was a thing only a phone could say.
///
/// Values are written through the properties and nowhere else, so what is in the store and what
/// is on screen are one thing. A value another device writes arrives through the store
/// (`SettingsStore.onChange`) and is set through the same properties.
@MainActor @Observable public final class PlayerSettings {
    private let store: any SettingsStore
    /// Whether these are the settings the kit runs on (`install()`).
    @ObservationIgnored private var isInstalled = false

    // ------------------------------------------------------------------ 线

    /// 记录线: what a move has to cost before it is written into the game as a mistake
    /// (docs/adr/0027, 0046). Raising it drags 入列线 up with it.
    public var record: Double {
        didSet {
            guard record != oldValue else { return }
            store.set(record, forKey: Keys.record)
            if enqueue < record { enqueue = record }
        }
    }

    /// 入列线: what it has to cost before it also takes practice time. Never below 记录线.
    public var enqueue: Double {
        didSet {
            if enqueue < record { enqueue = record }
            guard enqueue != oldValue else { return }
            store.set(enqueue, forKey: Keys.enqueue)
        }
    }

    /// The two lines as the kit reads them, with 把关 off — which is what an ordinary game is. A
    /// 把关 game takes this and switches `noSlips` on; the switch is per game, so it is not here.
    public var lines: JudgementLines {
        JudgementLines(noSlips: false, record: record, enqueue: enqueue)
    }

    // ------------------------------------------------------------------ 棋力

    /// The rung the next game starts at (docs/adr/0038). A game's own rung is written into the
    /// game; this is which one to offer the next. The bottom rung until somebody picks one.
    public var strength: Strength {
        didSet {
            guard strength != oldValue else { return }
            store.set(strength.text, forKey: Keys.strength)
        }
    }

    // ------------------------------------------------------------------ 搜索预算

    /// The budget every live search runs on (CONTEXT.md). The standard one until somebody moves
    /// a dial. Installed settings hand it to `PositionSearches.limit` as it changes.
    public var searchLimit: SearchLimit {
        didSet {
            guard searchLimit != oldValue else { return }
            store.set(searchLimit.text, forKey: Keys.search)
            if isInstalled { PositionSearches.limit = searchLimit }
        }
    }

    // ------------------------------------------------------------------ 语言

    /// The language a person picked, or nil to follow the phone — which is not the same as
    /// storing the language the phone happens to be in today: a person who changes their phone
    /// to Japanese should get a Japanese app, not the French one they were handed on the plane.
    public var language: Language? {
        didSet {
            guard language != oldValue else { return }
            store.set(language?.rawValue, forKey: Keys.language)
            if isInstalled { Speech.chosen = language }
        }
    }

    /// What the app is actually speaking, chosen or followed — what the root view is keyed on,
    /// so every screen is rebuilt in the new language the moment it changes. Read off `language`
    /// rather than `Speech.language`: only the first is a stored property of an `@Observable`,
    /// and a view that reads the second is never told it changed.
    public var currentLanguage: Language { language ?? Speech.followingSystem }

    // ------------------------------------------------------------------ 音效

    /// Whether the app makes a noise. On until somebody turns it off, and off on every device
    /// they own once they have.
    public var isSoundOn: Bool {
        didSet {
            guard isSoundOn != oldValue else { return }
            store.set(isSoundOn, forKey: Keys.sound)
        }
    }

    // ------------------------------------------------------------------ 门

    /// What the import sheet remembers between openings (docs/adr/0045).
    public let imports: ImportMemory

    // ------------------------------------------------------------------ keeping

    public init(store: any SettingsStore) {
        self.store = store
        record = Self.double(Keys.record, in: store) ?? JudgementLines.standard.record
        enqueue = Self.double(Keys.enqueue, in: store) ?? JudgementLines.standard.enqueue
        strength = Self.string(Keys.strength, in: store).flatMap(Strength.init(text:)) ?? .standard
        searchLimit = Self.string(Keys.search, in: store).flatMap(SearchLimit.init(text:)) ?? .standard
        language = Self.string(Keys.language, in: store).flatMap(Language.init(rawValue:))
        isSoundOn = store.object(forKey: Keys.sound) as? Bool ?? true
        imports = ImportMemory(store: store)
        enqueue = max(enqueue, record)
        store.onChange = { [weak self] in self?.arrived() }
    }

    /// Makes these the settings the kit runs on: the budget every search reads and the language
    /// every word comes out in, now and as they change. The app's own settings, once, on the way
    /// up; a test's settings are not installed and move nothing global.
    public func install() {
        isInstalled = true
        PositionSearches.limit = searchLimit
        Speech.chosen = language
    }

    /// Another device had its say: every value is set again through its property, so the store's
    /// two copies and the kit are brought into line with it. A key the other device never wrote
    /// leaves the value where it is — except the language, whose absence *is* a choice.
    private func arrived() {
        record = Self.double(Keys.record, in: store) ?? record
        enqueue = Self.double(Keys.enqueue, in: store) ?? enqueue
        strength = Self.string(Keys.strength, in: store).flatMap(Strength.init(text:)) ?? strength
        searchLimit = Self.string(Keys.search, in: store).flatMap(SearchLimit.init(text:)) ?? searchLimit
        language = Self.string(Keys.language, in: store).flatMap(Language.init(rawValue:))
        isSoundOn = store.object(forKey: Keys.sound) as? Bool ?? isSoundOn
        imports.arrived()
    }

    /// The keys, which are the ones the app has always written: a phone that updates keeps what
    /// it had.
    enum Keys {
        static let record = "chessmirror.line.record"
        static let enqueue = "chessmirror.line.enqueue"
        static let strength = "chessmirror.strength"
        static let search = "chessmirror.search"
        static let language = "chessmirror.language"
        static let sound = "chessmirror.sound"
        static let importNames = "chessmirror.import.names"
        static let importCount = "chessmirror.import.count"
        static let importDoor = "chessmirror.import.door"
        static let importReached = "chessmirror.import.reached"
        static let importLastPull = "chessmirror.import.lastPull"
    }

    fileprivate static func double(_ key: String, in store: any SettingsStore) -> Double? {
        store.object(forKey: key) as? Double
    }

    fileprivate static func string(_ key: String, in store: any SettingsStore) -> String? {
        store.object(forKey: key) as? String
    }
}

/// What the import sheet remembers between openings: the accounts games have been fetched for,
/// how many were asked for, and which door was used last (docs/adr/0045).
///
/// An account name is typed once. After that it is the name in the field when the sheet opens,
/// and a chip to tap when there is more than one — the sheet is the thing done before a flight,
/// and a flight is not the moment to remember how a handle was spelt. A name is kept only once
/// it has fetched something: a misspelling that failed is not an account, and offering it back
/// as one would be offering the mistake back.
@MainActor @Observable public final class ImportMemory {
    private let store: any SettingsStore

    /// The names that have fetched games, per site, newest first.
    public private(set) var names: [PGNImport.Site: [String]]

    /// How many recent games were asked for last time.
    public var count: Int {
        didSet {
            guard count != oldValue else { return }
            store.set(count, forKey: PlayerSettings.Keys.importCount)
        }
    }

    /// The door the sheet was last on, by its raw name; the sheet decides what that means.
    public var door: String {
        didSet {
            guard door != oldValue else { return }
            store.set(door, forKey: PlayerSettings.Keys.importDoor)
        }
    }

    /// How many names one site keeps. A person has an account, sometimes two, and a chip row
    /// that has to wrap is a chip row nobody reads.
    public static let keeps = 4

    /// Per 本人账号, the start time of the newest game 自动拉局 has seen from it — where the next
    /// pull carries on from. Kept, and synced, beside the names rather than read off the library,
    /// so a game once pulled and then deleted is not pulled again (docs/adr/0045).
    public private(set) var reached: [String: Date]

    /// When 自动拉局 last finished without a failure, on any device.
    public private(set) var lastPull: Date? {
        didSet {
            guard lastPull != oldValue else { return }
            store.set(lastPull?.timeIntervalSince1970, forKey: PlayerSettings.Keys.importLastPull)
        }
    }

    init(store: any SettingsStore) {
        self.store = store
        names = Self.names(in: store)
        reached = Self.reached(in: store)
        lastPull = (store.object(forKey: PlayerSettings.Keys.importLastPull) as? Double)
            .map(Date.init(timeIntervalSince1970:))
        count = store.object(forKey: PlayerSettings.Keys.importCount) as? Int ?? PGNImport.recentGames
        door = PlayerSettings.string(PlayerSettings.Keys.importDoor, in: store) ?? ""
    }

    /// The name to put in the field when a site's door opens: the one that fetched last.
    public func latest(on site: PGNImport.Site) -> String? {
        names[site]?.first
    }

    /// A name that has just fetched games moves to the front of its site's list.
    public func remember(_ name: String, on site: PGNImport.Site) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var list = names[site] ?? []
        list.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        list.insert(name, at: 0)
        names[site] = Array(list.prefix(Self.keeps))
        rememberNames()
    }

    /// A name struck off its chip.
    public func forget(_ name: String, on site: PGNImport.Site) {
        names[site]?.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        rememberNames()
    }

    /// Where the last pull from an account reached, nil before its first.
    public func reached(_ name: String, on site: PGNImport.Site) -> Date? {
        reached[Self.key(name, on: site)]
    }

    /// A pull from an account has seen games up to this start time. Never moves back.
    public func reach(_ date: Date, for name: String, on site: PGNImport.Site) {
        let key = Self.key(name, on: site)
        guard date > reached[key] ?? .distantPast else { return }
        reached[key] = date
        let raw = reached.mapValues(\.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(raw) else { return }
        store.set(data, forKey: PlayerSettings.Keys.importReached)
    }

    /// 自动拉局 finished without a failure.
    public func pulled(at date: Date) { lastPull = date }

    private static func key(_ name: String, on site: PGNImport.Site) -> String {
        "\(site.rawValue):\(name.lowercased())"
    }

    private static func reached(in store: any SettingsStore) -> [String: Date] {
        guard let data = store.object(forKey: PlayerSettings.Keys.importReached) as? Data,
              let raw = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return raw.mapValues(Date.init(timeIntervalSince1970:))
    }

    fileprivate func arrived() {
        names = Self.names(in: store)
        reached = Self.reached(in: store)
        lastPull = (store.object(forKey: PlayerSettings.Keys.importLastPull) as? Double)
            .map(Date.init(timeIntervalSince1970:)) ?? lastPull
        count = store.object(forKey: PlayerSettings.Keys.importCount) as? Int ?? count
        door = PlayerSettings.string(PlayerSettings.Keys.importDoor, in: store) ?? door
    }

    private func rememberNames() {
        let raw = Dictionary(uniqueKeysWithValues: names.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        store.set(data, forKey: PlayerSettings.Keys.importNames)
    }

    private static func names(in store: any SettingsStore) -> [PGNImport.Site: [String]] {
        guard let data = store.object(forKey: PlayerSettings.Keys.importNames) as? Data,
              let raw = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        var names: [PGNImport.Site: [String]] = [:]
        for (key, list) in raw {
            if let site = PGNImport.Site(rawValue: key) { names[site] = list }
        }
        return names
    }
}
