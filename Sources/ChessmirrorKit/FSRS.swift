import Foundation

/// FSRS-4.5, ported (docs/adr/0030).
///
/// **A port, not a design.** Every formula and every default weight here is the published
/// algorithm's; what this file adds is nothing, and that is the point — spaced repetition is a
/// solved problem and the app that reinvents it is an app that has to defend its own arithmetic
/// forever after.
///
/// Two things about how it is *used* are this app's own, and both are written down in 0030:
///
/// - **Grading is binary.** Passed or not, which is FSRS's Again and Good. Anki's two-button and
///   four-button users get statistically indistinguishable accuracy out of FSRS, and this app has
///   no self-assessment to take four answers from: the verdict is the engine's.
/// - **`desiredRetention` stays at 0.90.** The advice to lower it to 0.85 came from Anki's
///   retention optimiser, which was removed in 25.07 after a modelling bug; the workload curve is
///   roughly exponential either way, so this is a dial to leave alone until there is a reason.
///
/// Every function here is pure. Nothing is stored: a schedule is computed from the practice log
/// every time it is asked for, so refitting the weights or replacing the scheduler outright
/// reschedules the whole history on the next launch and migrates nothing (docs/adr/0029).
public struct FSRS: Sendable {
    /// What FSRS knows about one item: how long the memory lasts, and how hard the item is.
    ///
    /// Both are *computed* from the log every time. This type is a value passing through a fold,
    /// not a record anybody writes down.
    public struct Memory: Hashable, Sendable {
        /// Days until retrievability falls to 0.9 — which is why the interval at the default
        /// retention is exactly this number.
        public let stability: Double
        /// 1 to 10, and it moves slowly.
        public let difficulty: Double

        public init(stability: Double, difficulty: Double) {
            self.stability = stability
            self.difficulty = difficulty
        }
    }

    /// The published FSRS-4.5 defaults. Not tuned, not guessed at, and not this project's to
    /// invent: a personal fit is a later feature and it reads the same log (docs/adr/0030).
    public static let defaultWeights: [Double] = [
        0.4872, 1.4003, 3.7145, 13.8206, 5.1618, 1.2298, 0.8975, 0.0310, 1.6474, 0.1367,
        1.0461, 2.1072, 0.0793, 0.3246, 1.5870, 0.2272, 2.8755,
    ]

    /// The forgetting curve's shape, fixed by the algorithm.
    public static let decay = -0.5
    /// `0.9 ^ (1 / decay) - 1`, the constant that makes the curve pass through 0.9 at t = S.
    public static let factor = 19.0 / 81.0

    public var weights: [Double]
    public var desiredRetention: Double

    public init(weights: [Double] = FSRS.defaultWeights, desiredRetention: Double = 0.90) {
        self.weights = weights.count >= 17 ? weights : FSRS.defaultWeights
        self.desiredRetention = desiredRetention
    }

    // --------------------------------------------------------------- the curve

    /// How likely the player is to get it right after this many days.
    public func retrievability(_ memory: Memory, after days: Double) -> Double {
        pow(1 + Self.factor * max(0, days) / max(0.1, memory.stability), Self.decay)
    }

    /// How many days until retrievability falls to `desiredRetention`. At 0.90 this is exactly
    /// the stability, which is what stability means.
    public func interval(_ memory: Memory) -> Double {
        memory.stability / Self.factor * (pow(desiredRetention, 1 / Self.decay) - 1)
    }

    /// When this item should come back.
    public func due(_ memory: Memory, after review: Date) -> Date {
        review.addingTimeInterval(interval(memory) * 86_400)
    }

    // -------------------------------------------------------------- the update

    /// The memory an item has after its very first go.
    public func first(passed: Bool) -> Memory {
        let rating = Self.rating(passed)
        return Memory(
            stability: max(0.1, weights[rating - 1]),
            difficulty: clampDifficulty(initialDifficulty(rating))
        )
    }

    /// The memory after another go, `days` after the one before it.
    public func next(_ memory: Memory, passed: Bool, after days: Double) -> Memory {
        let rating = Self.rating(passed)
        let recalled = retrievability(memory, after: days)
        let difficulty = clampDifficulty(
            meanReverted(memory.difficulty - weights[6] * Double(rating - 3))
        )
        let stability =
            passed
            ? recallStability(difficulty: memory.difficulty, stability: memory.stability, recalled: recalled)
            : forgetStability(difficulty: memory.difficulty, stability: memory.stability, recalled: recalled)
        return Memory(stability: max(0.1, stability), difficulty: difficulty)
    }

    /// Passed is Good, failed is Again. The two ratings in between are what a person says about
    /// themselves, and nobody here is asked (docs/adr/0030).
    private static func rating(_ passed: Bool) -> Int { passed ? 3 : 1 }

    private func initialDifficulty(_ rating: Int) -> Double {
        weights[4] - Double(rating - 3) * weights[5]
    }

    /// Difficulty is pulled a little way back towards the easy end on every review, so that one
    /// bad day does not brand an item hard for ever.
    private func meanReverted(_ difficulty: Double) -> Double {
        weights[7] * initialDifficulty(4) + (1 - weights[7]) * difficulty
    }

    private func clampDifficulty(_ difficulty: Double) -> Double {
        min(10, max(1, difficulty))
    }

    private func recallStability(difficulty: Double, stability: Double, recalled: Double) -> Double {
        stability
            * (1 + exp(weights[8]) * (11 - difficulty) * pow(stability, -weights[9])
                * (exp((1 - recalled) * weights[10]) - 1))
    }

    private func forgetStability(difficulty: Double, stability: Double, recalled: Double) -> Double {
        // Never above where it already was: forgetting an item does not make its memory stronger.
        min(
            stability,
            weights[11] * pow(difficulty, -weights[12]) * (pow(stability + 1, weights[13]) - 1)
                * exp((1 - recalled) * weights[14])
        )
    }
}
