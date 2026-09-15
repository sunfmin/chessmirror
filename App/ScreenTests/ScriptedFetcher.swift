import ChessfenKit
import Foundation
import Synchronization

/// A fetcher that returns what it was told to return — the local copy of the kit tests' one,
/// because this bundle cannot see the kit's test fixtures (`ScriptedEngine` is doubled the
/// same way).
final class ScriptedFetcher: PGNFetching {
    private let results: [String: Result<String, PGNImport.Error>]
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
