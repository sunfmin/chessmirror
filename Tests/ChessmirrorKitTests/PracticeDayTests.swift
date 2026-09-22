@testable import ChessmirrorKit
import Foundation
import Testing

/// Contract: the day is one reading (`PracticeDay`) — which question comes next, and what the
/// 日课 door says. Both used to be asked of `MistakeIndex`, a walk cache, and the door's state
/// was re-derived in the view from `left > 0` three times while the label came from somewhere
/// else. The screen's only verb is 下一道 (docs/adr/0032).
@MainActor
@Suite(.speaking(.chinese)) struct PracticeDayTests {
    private func mistake(_ id: String, cost: Double = 30) -> Mistake {
        Mistake(
            position: PositionKey(id),
            encounters: [
                Encounter(
                    game: URL(string: "https://example.com/\(id)")!,
                    ply: 1, when: Date(timeIntervalSince1970: 0),
                    played: "e4", wanted: nil, cost: cost, origin: .fresh
                )
            ]
        )
    }

    private func card(_ m: Mistake) -> Daily.Card {
        Daily.Card(mistake: m, memory: nil, dueAt: Date(timeIntervalSince1970: 0), lapses: 0)
    }

    // ------------------------------------------------------------------ the door

    /// The door's label, its openness and its colour are one decision. It stays on the screen
    /// with nothing due — a door that disappears once it is done is a door nobody learns is
    /// there — and two silences are told apart: an empty book, and a day finished.
    @Test func theDoorIsOneDecisionAndBothSilencesAreNamed() {
        let first = mistake("4k3/8/8/8/8/8/8/4K3 w - -")
        let second = mistake("4k3/8/8/8/8/8/8/3K4 w - -")

        let open = PracticeDay(
            daily: Daily(cards: [card(first), card(second)]),
            book: MistakeBook(mistakes: [first, second])
        ).door
        #expect(open.isOpen)
        #expect(open.left == 2)
        #expect(open.label == localized("daily.left", plural: 2))

        let done = PracticeDay(
            daily: Daily(cards: []),
            book: MistakeBook(mistakes: [first])
        ).door
        #expect(!done.isOpen, "nothing left today, but the door is still drawn")
        #expect(done.label == localized("daily.done"), "「今天的练完了」")

        let none = PracticeDay(
            daily: Daily(cards: []),
            book: MistakeBook(mistakes: [])
        ).door
        #expect(!none.isOpen)
        #expect(none.label == localized("daily.none"), "an empty book is a different silence")
    }

    // ------------------------------------------------------------------ the next question

    /// From 日课, the next card of today's queue that is not this position. A 计划外 go is not
    /// in the queue and so never comes next from it (docs/adr/0032). A queue of one has nowhere
    /// to go — its only card *is* this position.
    @Test func fromTheQueueTheNextIsAnotherCardOfTheQueue() {
        let first = mistake("4k3/8/8/8/8/8/8/4K3 w - -", cost: 30)
        let second = mistake("4k3/8/8/8/8/8/8/3K4 w - -", cost: 20)
        let day = PracticeDay(
            daily: Daily(cards: [card(first), card(second)]),
            book: MistakeBook(mistakes: [first, second])
        )
        #expect(day.next(after: first, source: .daily) == second, "the next card that is not this one")
        #expect(day.next(after: second, source: .daily) == first, "and round it goes while both are up")

        let alone = PracticeDay(
            daily: Daily(cards: [card(first)]),
            book: MistakeBook(mistakes: [first])
        )
        #expect(alone.next(after: first, source: .daily) == nil, "a queue of one has nowhere to go")
    }

    /// Picked off the book, the next 错题 in the book's order, round to the first — and a book
    /// of one has nowhere to go.
    @Test func offTheBookTheNextGoesRoundAndStopsAtOne() {
        let first = mistake("4k3/8/8/8/8/8/8/4K3 w - -", cost: 30)
        let second = mistake("4k3/8/8/8/8/8/8/3K4 w - -", cost: 20)
        let third = mistake("4k3/8/8/8/8/8/8/2K5 w - -", cost: 10)
        let three = PracticeDay(
            daily: Daily(cards: []),
            book: MistakeBook(mistakes: [first, second, third])
        )
        // Worst cost first: 30, 20, 10 — so the book's order is deterministic.
        let order = three.book.mistakes
        #expect(order.map { $0.position.text.hasPrefix("4k3/8/8/8/8/8/8/4K3") } == [true, false, false])
        #expect(three.next(after: order[0], source: .picked) == order[1])
        #expect(three.next(after: order[2], source: .picked) == order[0], "round to the first")

        let alone = PracticeDay(
            daily: Daily(cards: []),
            book: MistakeBook(mistakes: [first])
        )
        #expect(alone.next(after: first, source: .picked) == nil, "a book of one has nowhere to go")
    }

    /// The two doors are not interchangeable. The book is ordered by how pressing each 错题 is;
    /// the queue is ordered by ARTS (docs/adr/0030). A card sitting at the front of one and the
    /// middle of the other is the ordinary case, and each door answers from its own list.
    @Test func theTwoDoorsDoNotAnswerEachOther() {
        let a = mistake("4k3/8/8/8/8/8/8/4K3 w - -", cost: 30)
        let b = mistake("4k3/8/8/8/8/8/8/3K4 w - -", cost: 20)
        let c = mistake("4k3/8/8/8/8/8/8/2K5 w - -", cost: 10)
        // Book order is a, b, c. The queue has b at the front — ARTS's order, not the book's.
        let day = PracticeDay(
            daily: Daily(cards: [card(b), card(a)]),
            book: MistakeBook(mistakes: [a, b, c])
        )
        #expect(day.next(after: b, source: .daily) == a, "from the queue: the next card that is not b")
        #expect(day.next(after: b, source: .picked) == c, "off the book: b's neighbour in the book's order")
    }
}
