import ChessfenKit
import Foundation
import Synchronization

/// A fetcher that returns what it was told to return.
///
/// The seam is the download and nothing above it: a session driven by this one runs the real
/// candidate walk, the real parse, the real write — what is faked is only the one thing in an
/// import that cannot be asked twice for the same answer (`ScriptedEngine` convention).
final class ScriptedFetcher: PGNFetching {
    /// The text to hand back per URL, or the failure to throw for it. Anything not scripted
    /// fails with a 404.
    private let results: [String: Result<String, PGNImport.Error>]
    /// Every URL asked for so far, in order. Order is the one thing about a session's
    /// fetching that matters beyond what came back: candidates are tried in a prescribed
    /// order, and a test asserts it.
    private let asked = Mutex<[URL]>([])

    var askedURLs: [URL] { asked.withLock { $0 } }

    init(_ results: [String: Result<String, PGNImport.Error>] = [:]) {
        self.results = results
    }

    func fetch(_ url: URL) async throws -> String {
        asked.withLock { $0.append(url) }
        guard let result = results[url.absoluteString] else {
            throw PGNImport.Error.http(404)
        }
        return try result.get()
    }
}
