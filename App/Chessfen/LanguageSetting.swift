import ChessfenKit
import Foundation

/// What language the app speaks, as a thing a person can change and the phone remembers.
///
/// The kit's `Speech` holds the answer; this is the app's half of it — the choice, where it is
/// kept, and the fact that it travels. Modelled on `SystemFeedback`'s sound switch for exactly
/// the same reason (docs/adr/0012): a setting that has to be set again on every device is a
/// setting that is only half kept.
///
/// Nil means "whatever the phone is set to", which is what everyone gets until they say
/// otherwise — and which is not the same as storing the language the phone happens to be in
/// today: a person who changes their phone to Japanese should get a Japanese app, not the
/// French one they were handed on the plane.
@MainActor @Observable final class LanguageSetting {
    static let shared = LanguageSetting()

    /// The language a person picked, or nil to follow the phone.
    var chosen: Language? {
        didSet {
            guard chosen != oldValue else { return }
            Speech.chosen = chosen
            Self.remember(chosen)
        }
    }

    /// What the app is actually speaking, chosen or followed. What the root view is keyed on, so
    /// every screen is rebuilt in the new language the moment this changes.
    ///
    /// Reads `chosen` rather than `Speech.language`, which is the same answer by a different
    /// route — but only the first route is a stored property of an `@Observable`, and a view
    /// that reads the second one registers no dependency on anything and is never invalidated.
    /// The screens would have gone on speaking the old language until something else redrew them.
    var current: Language { chosen ?? Speech.followingSystem }

    private static let key = "chessfen.language"

    private init() {
        chosen = Self.remembered()
        Speech.chosen = chosen
        // The travelled copy arrives whenever it arrives, including while the app is open. Set
        // through the property, so the local copy and the kit are brought into line with it.
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                LanguageSetting.shared.chosen = Self.remembered()
            }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    /// Both stores, always. iCloud's is the one that travels; `UserDefaults` is the one that
    /// answers at launch before iCloud's has been read back off the network.
    private static func remember(_ language: Language?) {
        UserDefaults.standard.set(language?.rawValue, forKey: key)
        if let language {
            NSUbiquitousKeyValueStore.default.set(language.rawValue, forKey: key)
        } else {
            NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
        }
    }

    private static func remembered() -> Language? {
        if let travelled = NSUbiquitousKeyValueStore.default.string(forKey: key) {
            return Language(rawValue: travelled)
        }
        return UserDefaults.standard.string(forKey: key).flatMap(Language.init(rawValue:))
    }
}
