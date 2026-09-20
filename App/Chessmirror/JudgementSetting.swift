import ChessmirrorKit
import Foundation

/// Where the player's two standing lines are kept (docs/adr/0027).
///
/// The kit's `JudgementLines` holds them beside 把关's switch; this is the app's half, the two
/// numbers that belong to the *player* rather than to a game — 记录线, what gets written down and
/// what 把关 stops the player for (docs/adr/0046), and 入列线, what earns a place in future
/// practice time. The switch is set per game, so it is not here.
///
/// Modelled on `LanguageSetting` for the same reason (docs/adr/0012): a line that has to be drawn
/// again on every device is a line that is only half drawn. Both stores, always — iCloud's is the
/// one that travels, `UserDefaults` is the one that answers at launch before the network has.
@MainActor @Observable final class JudgementSetting {
    static let shared = JudgementSetting()

    /// What a move has to cost before it is written into the game as a mistake.
    var record: Double {
        didSet {
            guard record != oldValue else { return }
            Self.remember(record, forKey: Self.recordKey)
        }
    }

    /// What it has to cost on top of that before it also takes practice time.
    var enqueue: Double {
        didSet {
            guard enqueue != oldValue else { return }
            Self.remember(enqueue, forKey: Self.enqueueKey)
        }
    }

    /// The two of them as the kit reads them, with 把关 off — which is what an ordinary game is.
    /// A 把关 game takes this and switches `noSlips` on.
    var lines: JudgementLines {
        JudgementLines(noSlips: false, record: record, enqueue: enqueue)
    }

    /// The values either line is offered, because tenths of a percent are not a thing anybody
    /// can feel and a slider would suggest they are.
    static let choices: [Double] = [5, 10, 15, 20, 25, 30]

    private static let recordKey = "chessmirror.line.record"
    private static let enqueueKey = "chessmirror.line.enqueue"

    private init() {
        record = Self.remembered(Self.recordKey) ?? JudgementLines.standard.record
        enqueue = Self.remembered(Self.enqueueKey) ?? JudgementLines.standard.enqueue
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let setting = JudgementSetting.shared
                setting.record = Self.remembered(Self.recordKey) ?? setting.record
                setting.enqueue = Self.remembered(Self.enqueueKey) ?? setting.enqueue
            }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    private static func remember(_ value: Double, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        NSUbiquitousKeyValueStore.default.set(value, forKey: key)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    /// Nil for a key nobody has written, which is not the same as a zero somebody chose —
    /// `double(forKey:)` cannot tell those apart, so the object form is asked first.
    private static func remembered(_ key: String) -> Double? {
        if let travelled = NSUbiquitousKeyValueStore.default.object(forKey: key) as? Double {
            return travelled
        }
        return UserDefaults.standard.object(forKey: key) as? Double
    }
}
