import ChessfenKit
import Testing

/// A suite whose assertions are about words: it names the language they are in.
///
/// The app speaks eight (docs/adr/0019) and picks one from the phone, so a test that expects a
/// Chinese sentence on an English simulator is a test that fails for a reason having nothing to
/// do with what it is testing.
///
/// Both settings, on purpose. The scoped one is what a test should need — two suites open at
/// once do not take the language out from under each other — but a screenshot test is not the
/// only thing evaluating the view. SwiftUI lays a window out again on its own, from a run loop
/// rather than from this task, and a task-local does not reach there: the labels computed in
/// that second pass came back in the simulator's language while the ones computed in the first
/// were Chinese, and the accessibility tree ended up holding both. So the global is set too,
/// and put back afterwards.
struct Speaking: TestTrait, SuiteTrait, TestScoping {
    let language: Language

    var isRecursive: Bool { true }

    // Spelled out in full because the app target builds with approachable concurrency, under
    // which neither of these is the default: `nonisolated`, since a trait scopes whatever
    // thread its test runs on rather than the main one, and `@concurrent` on the closure,
    // since that is the type swift-testing declares.
    nonisolated func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        let spoken = Speech.language
        Speech.language = language
        defer { Speech.language = spoken }
        try await Speech.speaking(language) { try await function() }
    }
}

extension Trait where Self == Speaking {
    static func speaking(_ language: Language) -> Self { Speaking(language: language) }
}
