import ChessfenKit
import Testing

/// A suite whose assertions are about words: it names the language they are in.
///
/// The app speaks eight (docs/adr/0019) and picks one from the phone, so a test that expects a
/// Chinese sentence on an English simulator is a test that fails for a reason having nothing to
/// do with what it is testing. Scoped rather than set, so suites running side by side do not take
/// the language out from under each other — every one of these tests asks for its words on the
/// thread it is running on, and nothing here draws. The app's copy of this trait has to set the
/// global as well, because SwiftUI lays a window out from a run loop the task-local cannot reach.
struct Speaking: TestTrait, SuiteTrait, TestScoping {
    let language: Language

    var isRecursive: Bool { true }

    // `nonisolated` because a trait scopes whatever thread its test runs on, not the main one.
    nonisolated func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await Speech.speaking(language) { try await function() }
    }
}

extension Trait where Self == Speaking {
    static func speaking(_ language: Language) -> Self { Speaking(language: language) }
}
