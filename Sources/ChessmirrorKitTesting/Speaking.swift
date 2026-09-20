import ChessmirrorKit
import Testing

/// A test whose assertions are about words: it names the language they are in.
///
/// The app speaks eight (docs/adr/0019) and picks one from the phone, so a test that expects a
/// Chinese sentence on an English simulator is a test that fails for a reason having nothing to
/// do with what it is testing.
///
/// **Two ways to name it, because a screen is not a string.** A test that only asks for words
/// scopes the language to its own task, so suites running side by side do not take it out from
/// under each other. A test that *draws* has to set the global as well: SwiftUI lays a window
/// out again on its own, from a run loop a task-local does not reach, and the labels computed in
/// that second pass came back in the simulator's language while the ones computed in the first
/// were Chinese — an accessibility tree holding both. That is why a screen test says
/// `.drawing(in:)` and is serialized, and why one trait with one meaning could not serve both.
///
/// It lives here rather than in either test target because it had been copied into both, and the
/// copies had drifted: the paragraph above was written in the app's copy and the kit's copy said
/// a shorter, different thing.
public struct Speaking: TestTrait, SuiteTrait, TestScoping {
    public let language: Language

    /// Whether the language is also set where a task-local does not reach. True for a test that
    /// renders; it is put back afterwards, and it is why such a suite is `.serialized`.
    public let draws: Bool

    public var isRecursive: Bool { true }

    // `nonisolated` because a trait scopes whatever thread its test runs on, not the main one.
    // Spelled out because the app's test bundle builds with approachable concurrency, under which
    // it is not the default; the closure keeps the type swift-testing declares.
    public nonisolated func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        guard draws else {
            return try await Speech.speaking(language) { try await function() }
        }
        let spoken = Speech.language
        Speech.language = language
        defer { Speech.language = spoken }
        try await Speech.speaking(language) { try await function() }
    }
}

extension Trait where Self == Speaking {
    /// The language this test's words are in, for its own task and nothing else.
    public static func speaking(_ language: Language) -> Self {
        Speaking(language: language, draws: false)
    }

    /// The language this test *draws* in: scoped as above, and set globally for the layout pass
    /// SwiftUI runs outside the task. For a suite that photographs a screen, which is serialized.
    public static func drawing(in language: Language) -> Self {
        Speaking(language: language, draws: true)
    }
}
