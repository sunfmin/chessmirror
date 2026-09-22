import Foundation

/// This test process, exclusively — for as long as the body runs.
///
/// Wall-clock budgets, `phys_footprint` peaks and a real Stockfish's speed are facts about
/// the whole test process. A test that asserts any of them cannot share the machine with the
/// rest of the suite and still say something true. `RecognitionMemoryTests` learned this once
/// when twelve unrelated tests joined the process and a 108 MB net landed in a recognition's
/// "peak"; the full run learned it again when four such tests failed together and each passed
/// alone in under five seconds.
///
/// One lock, taken by every test that **measures** the process or **loads** it (a real
/// `EngineService`, a recognition of a photograph). Everything else stays free to run
/// alongside everything else — those tests assert on values, not on the machine.
///
/// ```swift
/// try await Quietly.alone {
///     let engine = try EngineService(...)
///     ...
/// }
/// ```
enum Quietly: Sendable {
    private actor Gate {
        private var isHeld = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func enter() async {
            while isHeld {
                await withCheckedContinuation { waiting.append($0) }
            }
            isHeld = true
        }

        func leave() {
            isHeld = false
            let pending = waiting
            waiting = []
            for continuation in pending { continuation.resume() }
        }
    }

    private static let gate = Gate()

    /// Runs `body` with this process to itself. The caller's isolation is kept, so a
    /// `@MainActor` test stays on the main actor inside the body.
    static func alone<T: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        await gate.enter()
        do {
            let value = try await body()
            await gate.leave()
            return value
        } catch {
            await gate.leave()
            throw error
        }
    }
}
