@testable import ChessmirrorKit
import Foundation
import Testing

/// Contract: the 入列线 is one rule on one line, asked of two objects, and the two are named
/// apart (`Enrolment`). A 错题 is owed practice time when the worst 遭遇 it has ever had crosses
/// the line — that is what puts it in 日课. A 错招 is what *earned* that when its own cost crosses
/// — that is what a mark on a record weighs. They can answer differently for one position, and
/// both are right; the point of the seam is that neither module can quietly answer the other's
/// question under the one word 「欠」.
@Suite struct EnrolmentTests {
    private let lines = JudgementLines(noSlips: true, record: 5, enqueue: 10)

    private func mistake(_ costs: [Double]) -> Mistake {
        Mistake(
            position: PositionKey("4k3/8/8/8/8/8/8/4K3 w - -"),
            encounters: costs.enumerated().map { index, cost in
                Encounter(
                    game: URL(string: "https://example.com/\(index)")!,
                    ply: index + 1, when: Date(timeIntervalSince1970: Double(index)),
                    played: "e4", wanted: nil, cost: cost, origin: .fresh
                )
            }
        )
    }

    private func slip(_ cost: Double) -> Slip {
        Slip(
            ply: 1, position: PositionKey("4k3/8/8/8/8/8/8/4K3 w - -"),
            wrong: [.init(san: "e4", drop: cost, wasTried: true)], wanted: nil
        )
    }

    /// The two questions, asked of the two objects, at one position whose 遭遇 crossed the line
    /// once and fell short of it once. This is the disagreement the seam exists to name: the
    /// position is in 日课 on the strength of its worst, and the lesser 遭遇's mark stays held
    /// back. Before, both were `lines.enqueues(someDrop)` under 「还欠不欠」 and which drop was
    /// passed decided the answer.
    @Test func aPositionsWorthAndOneOccasionsCostAreTwoQuestions() {
        let position = mistake([30, 8])
        #expect(Enrolment(mistake: position, lines: lines) == .owed, "the worst 遭遇 crossed 10")
        #expect(Enrolment(slip: slip(30), lines: lines) == .owed, "and so does its own cost")
        #expect(Enrolment(slip: slip(8), lines: lines) == .written, "the lesser one only got written down")
    }

    /// A position nobody has ever crossed the line on is not owed, whatever the 记录线 wrote down.
    @Test func betweenTheTwoLinesIsWrittenAndNotOwed() {
        #expect(Enrolment(mistake: mistake([7, 6]), lines: lines) == .written)
        #expect(Enrolment(slip: slip(7), lines: lines) == .written)
        #expect(Enrolment(slip: slip(7), lines: lines).isOwed == false)
        #expect(Enrolment(slip: slip(10), lines: lines).isOwed, "at the line is over it")
        #expect(Enrolment(slip: slip(10.5), lines: lines).isOwed)
    }

    /// Raising the 入列线 above the 记录线 is the wide-book / narrow-queue dial (docs/adr/0027):
    /// everything still gets written down, and less of it earns practice time.
    @Test func aRaisedEnrolLineKeepsTheBookWideAndTheQueueNarrow() {
        let wide = JudgementLines(noSlips: true, record: 5, enqueue: 5)
        let narrow = JudgementLines(noSlips: true, record: 5, enqueue: 25)
        let position = mistake([30, 12, 8])
        #expect(Enrolment(mistake: position, lines: wide) == .owed)
        #expect(Enrolment(mistake: position, lines: narrow) == .owed, "30 is over even a raised line")
        #expect(Enrolment(mistake: mistake([12]), lines: narrow) == .written, "12 is not")
        #expect(Enrolment(mistake: mistake([12]), lines: wide) == .owed)
    }

    /// The mark on a record and `Slip.isWorthDrilling` are one fact under two names.
    @Test func theMarkIsTheSlipsOwnEnrolment() {
        #expect(RecordReading.Mark(Enrolment(slip: slip(30), lines: lines)) == .owed)
        #expect(RecordReading.Mark(Enrolment(slip: slip(8), lines: lines)) == .written)
        #expect(RecordReading.Mark.owed.enrolment == .owed)
        #expect(RecordReading.Mark.written.enrolment == .written)
        #expect(slip(30).isWorthDrilling(lines))
        #expect(!slip(8).isWorthDrilling(lines))
    }
}
