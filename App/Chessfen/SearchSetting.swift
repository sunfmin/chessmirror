import ChessfenKit
import Foundation

/// The player's 搜索预算, remembered across launches and devices (CONTEXT.md).
///
/// The kit holds the value — `SearchLimit`, and `PositionSearches.limit` as the one every live
/// search reads — and this is the app's half: where it is kept, and that it is put back into the
/// kit at launch and whenever it changes. Kept the way the lines and the rung are
/// (`JudgementSetting`, `StrengthSetting`): both stores, always — iCloud's is the one that
/// travels, `UserDefaults` is the one that answers at launch before the network has.
@MainActor @Observable final class SearchSetting {
    static let shared = SearchSetting()

    /// The budget every live search runs on. The standard one until somebody moves a dial.
    var limit: SearchLimit {
        didSet {
            guard limit != oldValue else { return }
            PositionSearches.limit = limit
            Self.remember(limit)
        }
    }

    /// The three dials, one each, for a picker to bind to.
    var seconds: Int {
        get { limit.seconds }
        set { limit.seconds = newValue }
    }

    var depth: Int {
        get { limit.depth }
        set { limit.depth = newValue }
    }

    var stop: SearchLimit.Stop {
        get { limit.stop }
        set { limit.stop = newValue }
    }

    private static let key = "chessfen.search"

    private init() {
        limit = Self.remembered() ?? .standard
        PositionSearches.limit = limit
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let setting = SearchSetting.shared
                setting.limit = Self.remembered() ?? setting.limit
            }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    private static func remember(_ limit: SearchLimit) {
        UserDefaults.standard.set(limit.text, forKey: key)
        NSUbiquitousKeyValueStore.default.set(limit.text, forKey: key)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    private static func remembered() -> SearchLimit? {
        if let travelled = NSUbiquitousKeyValueStore.default.string(forKey: key) {
            return SearchLimit(text: travelled)
        }
        return UserDefaults.standard.string(forKey: key).flatMap(SearchLimit.init(text:))
    }
}
