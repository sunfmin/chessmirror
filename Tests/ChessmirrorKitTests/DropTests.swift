@testable import ChessmirrorKit
import Testing

/// Contract: a 掉幅 is said one way everywhere — whole points, the same rounding in a figure and in
/// a sentence — so a tile and the words read out for it never disagree (docs/adr/0027).
@Suite struct DropTests {
    @Test func aDropIsWholePointsRoundedAwayFromZero() {
        #expect(Drop.points(24.4) == 24)
        #expect(Drop.points(24.5) == 25)
        #expect(Drop.points(0.3) == 0)
    }

    @Test func theFigureAndTheClauseAgreeOnTheNumber() {
        #expect(Drop.figure(24.5) == "−25%")
        #expect(Drop.cost(24.5) == localized("book.cost", 25))
        #expect(Drop.figure(7) == "−7%")
    }

    /// The sentences that say a cost take the same number the figure shows.
    @MainActor
    @Test func aRefusalSaysTheSamePointsItsChipShows() {
        let refusal = Game.Ply.Tried(san: "Qh4", drop: 22.5)
        #expect(refusal.sentence == localized("till.refused", "Qh4", 23))
        #expect(Drop.figure(refusal.drop) == "−23%")
    }
}
