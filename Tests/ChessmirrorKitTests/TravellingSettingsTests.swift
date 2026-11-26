import ChessmirrorKit
import Foundation
import Testing

/// Contract: the app's settings store keeps every value in both places — `UserDefaults`, which
/// answers at launch and on a device with no account, and iCloud's, which travels — and a key
/// iCloud has no answer for is answered from `UserDefaults` (docs/adr/0012).
///
/// A test process has no iCloud entitlement, so iCloud's store holds nothing here (measured: what
/// one store sets, another never reads back): that iCloud's answer wins when both have one is the
/// phone's to show, not this suite's. Each test hands in a `UserDefaults` that lives in memory,
/// since a suite's writes reach the machine's own preferences after the process has gone.
@MainActor
@Suite struct TravellingSettingsTests {
    @Test("a value set is kept in UserDefaults too, and taken out of both by nil")
    func aValueIsKeptInBoth() {
        let defaults = MemoryDefaults()
        let key = Self.key()
        let store = TravellingSettings(defaults: defaults)
        store.set(15.0, forKey: key)
        #expect(defaults.values[key] as? Double == 15, "the copy that answers at launch")
        #expect(store.object(forKey: key) as? Double == 15)
        store.set(nil, forKey: key)
        #expect(defaults.values[key] == nil)
        #expect(store.object(forKey: key) == nil)
    }

    @Test("a key iCloud has no answer for is answered from UserDefaults")
    func userDefaultsAnswersWhenICloudHasNothing() {
        let defaults = MemoryDefaults()
        let key = Self.key()
        defaults.values[key] = "elo 1800"
        let store = TravellingSettings(defaults: defaults)
        #expect(store.object(forKey: key) as? String == "elo 1800")
    }

    /// A key nobody else writes: iCloud's store is the process's one.
    private static func key() -> String { "chessmirror.test.\(UUID().uuidString)" }
}

/// `UserDefaults` kept in a dictionary, written nowhere.
private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    var values: [String: Any] = [:]

    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}
