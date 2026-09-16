import Foundation

/// Pictures handed to the app by something outside its own process — the share sheet.
///
/// A Share Extension is a separate process with a separate sandbox: it can read the picture
/// somebody shared, and it cannot start the app, load Stockfish or push a screen. So it does
/// the one thing it can do and stops — it writes the bytes into a folder both processes can
/// see — and the app finds them the next time it comes forward. The folder is the whole
/// protocol. There is no message, no queue and no notification, which is what makes the
/// handoff survive the extension being killed the instant it returns.
///
/// Newest first, one at a time, and taken as they are read: somebody who shares three boards
/// in a row is going to look at the last one, and the other two are still in their album.
public struct SharedInbox: Sendable {
    /// The group both the app and the extension are entitled to. Named once here; the
    /// entitlements in `project.yml` are generated from the same string.
    public static let groupIdentifier = "group.com.sunfmin.chessmirror"

    /// Where the shared pictures wait.
    public let url: URL

    /// Opens on a folder. The argument is a seam rather than a feature — the real folder is
    /// the app group's, and a test hands over a temporary directory.
    public init(url: URL) {
        self.url = url
    }

    /// The app group's folder, or nil where there is no group container — the Simulator
    /// without the entitlement, a unit test, a command-line build.
    public static var shared: SharedInbox? {
        guard
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: groupIdentifier
            )
        else { return nil }
        let folder = container.appending(path: "Shared", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return SharedInbox(url: folder)
    }

    // ------------------------------------------------------------- the extension's half

    /// Writes one shared picture in, and answers where it landed.
    ///
    /// The name is the moment it arrived, so the listing sorts itself, plus a few random
    /// characters because two shares in the same second are a thing a person can do.
    @discardableResult
    public func deposit(_ data: Data, extension suffix: String = "png") throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let stamp = Self.stamp.string(from: Date())
        let salt = String(UUID().uuidString.prefix(4)).lowercased()
        let file = url.appending(path: "shared-\(stamp)-\(salt).\(suffix)")
        try data.write(to: file, options: .atomic)
        return file
    }

    // ------------------------------------------------------------------- the app's half

    /// What is waiting, newest first.
    public func waiting() -> [URL] {
        let found = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        )
        return (found ?? [])
            .filter { $0.lastPathComponent.hasPrefix("shared-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Reads the newest one and removes it, so a picture the app has looked at cannot arrive
    /// a second time. Nil when nothing is waiting.
    ///
    /// Removed before the read is over rather than after: a picture the app dies reading must
    /// not be the picture it dies reading again on every launch after that.
    public func takeNewest() -> Data? {
        guard let newest = waiting().first else { return nil }
        let data = try? Data(contentsOf: newest)
        try? FileManager.default.removeItem(at: newest)
        return data
    }

    /// Throws away everything waiting. For the case where the app has been away long enough
    /// that a stack of shares says nothing about what somebody wants now.
    public func empty() {
        for file in waiting() { try? FileManager.default.removeItem(at: file) }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()
}
