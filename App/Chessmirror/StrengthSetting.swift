import ChessmirrorKit
import Foundation

/// The rung the player last put the engine on, remembered across games (docs/adr/0038).
///
/// The kit's `GameSession` holds a game's 棋力, which is a fact about that game and is written
/// into it; this is the app's half — which rung to offer the *next* game. Unlike the clock, which
/// ADR 0009 keeps as a way of playing, a rung somebody has climbed to is where they want to be
/// found tomorrow, so it is kept the way the lines are (`JudgementSetting`): both stores, always
/// — iCloud's is the one that travels, `UserDefaults` is the one that answers at launch.
@MainActor @Observable final class StrengthSetting {
    static let shared = StrengthSetting()

    /// The rung to start the next game at. 满力 until somebody picks one.
    var strength: Strength {
        didSet {
            guard strength != oldValue else { return }
            Self.remember(strength)
        }
    }

    private static let key = "chessmirror.strength"

    private init() {
        strength = Self.remembered() ?? .full
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let setting = StrengthSetting.shared
                setting.strength = Self.remembered() ?? setting.strength
            }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    private static func remember(_ strength: Strength) {
        UserDefaults.standard.set(strength.text, forKey: key)
        NSUbiquitousKeyValueStore.default.set(strength.text, forKey: key)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    private static func remembered() -> Strength? {
        if let travelled = NSUbiquitousKeyValueStore.default.string(forKey: key) {
            return Strength(text: travelled)
        }
        return UserDefaults.standard.string(forKey: key).flatMap(Strength.init(text:))
    }
}
