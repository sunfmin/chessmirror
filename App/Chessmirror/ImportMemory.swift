import ChessmirrorKit
import Foundation

/// What the import sheet remembers between openings: the accounts games have been fetched
/// for, how many were asked for, and which door was used last (docs/adr/0045).
///
/// An account name is typed once. After that it is the name in the field when the sheet opens,
/// and a chip to tap when there is more than one — the sheet is the thing done before a flight,
/// and a flight is not the moment to remember how a handle was spelt. A name is kept only once
/// it has fetched something: a misspelling that failed is not an account, and offering it back
/// as one would be offering the mistake back.
///
/// Kept the way the lines are (`JudgementSetting`): both stores, always — iCloud's is the one
/// that travels, `UserDefaults` is the one that answers at launch. Tests hand in a suite of
/// their own and keep the cloud out of it.
@MainActor @Observable final class ImportMemory {
    static let shared = ImportMemory(defaults: .standard, travels: true)

    /// The names that have fetched games, per site, newest first.
    private(set) var names: [PGNImport.Site: [String]]

    /// How many recent games were asked for last time.
    var count: Int {
        didSet {
            guard count != oldValue else { return }
            remember(count, forKey: Self.countKey)
        }
    }

    /// The door the sheet was last on, by its raw name; the sheet decides what that means.
    var door: String {
        didSet {
            guard door != oldValue else { return }
            remember(door, forKey: Self.doorKey)
        }
    }

    /// How many names one site keeps. A person has an account, sometimes two, and a chip row
    /// that has to wrap is a chip row nobody reads.
    static let keeps = 4

    private static let namesKey = "chessmirror.import.names"
    private static let countKey = "chessmirror.import.count"
    private static let doorKey = "chessmirror.import.door"

    private let defaults: UserDefaults
    private let travels: Bool

    init(defaults: UserDefaults, travels: Bool) {
        self.defaults = defaults
        self.travels = travels
        names = Self.remembered(names: defaults, travels: travels)
        count = Self.remembered(int: Self.countKey, defaults, travels) ?? PGNImport.recentGames
        door = Self.remembered(string: Self.doorKey, defaults, travels) ?? ""
        guard travels else { return }
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let memory = ImportMemory.shared
                memory.names = Self.remembered(names: memory.defaults, travels: true)
                memory.count = Self.remembered(int: Self.countKey, memory.defaults, true) ?? memory.count
                memory.door = Self.remembered(string: Self.doorKey, memory.defaults, true) ?? memory.door
            }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    /// The name to put in the field when a site's door opens: the one that fetched last.
    func latest(on site: PGNImport.Site) -> String? {
        names[site]?.first
    }

    /// A name that has just fetched games moves to the front of its site's list.
    func remember(_ name: String, on site: PGNImport.Site) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var list = names[site] ?? []
        list.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        list.insert(name, at: 0)
        names[site] = Array(list.prefix(Self.keeps))
        rememberNames()
    }

    /// A name struck off its chip.
    func forget(_ name: String, on site: PGNImport.Site) {
        names[site]?.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        rememberNames()
    }

    // ------------------------------------------------------------------ stores

    private func rememberNames() {
        let raw = Dictionary(uniqueKeysWithValues: names.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        defaults.set(data, forKey: Self.namesKey)
        guard travels else { return }
        NSUbiquitousKeyValueStore.default.set(data, forKey: Self.namesKey)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    private func remember(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
        guard travels else { return }
        NSUbiquitousKeyValueStore.default.set(value, forKey: key)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    private static func remembered(names defaults: UserDefaults, travels: Bool)
        -> [PGNImport.Site: [String]]
    {
        let data = (travels ? NSUbiquitousKeyValueStore.default.data(forKey: namesKey) : nil)
            ?? defaults.data(forKey: namesKey)
        guard let data, let raw = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        var names: [PGNImport.Site: [String]] = [:]
        for (key, list) in raw {
            if let site = PGNImport.Site(rawValue: key) { names[site] = list }
        }
        return names
    }

    private static func remembered(int key: String, _ defaults: UserDefaults, _ travels: Bool) -> Int? {
        if travels, let travelled = NSUbiquitousKeyValueStore.default.object(forKey: key) as? Int {
            return travelled
        }
        return defaults.object(forKey: key) as? Int
    }

    private static func remembered(string key: String, _ defaults: UserDefaults, _ travels: Bool)
        -> String?
    {
        if travels, let travelled = NSUbiquitousKeyValueStore.default.string(forKey: key) {
            return travelled
        }
        return defaults.string(forKey: key)
    }
}
