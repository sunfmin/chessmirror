import Foundation

/// 今天的练习 — where the day stands, what comes next, and what the door reads
/// (docs/adr/0030, 0032).
///
/// One reading of one day and the book it is carved out of. Which question comes next and what
/// the 日课 door says used to be asked of `MistakeIndex` — a walk cache — and the library screen
/// re-derived the door's state from `left > 0` three times over while also reading a label from
/// the cache. Both are readings of the day, so they are here; the cache keeps only the walk.
///
/// The screen's only verb is 下一道 (`Daily`): there is no filter, no sort and no list to pick
/// from. This is the whole of what a screen may ask about the queue.
public struct PracticeDay: Sendable {
    public let daily: Daily
    public let book: MistakeBook

    public init(daily: Daily, book: MistakeBook) {
        self.daily = daily
        self.book = book
    }

    /// The question after this one.
    ///
    /// From 日课, the next card of today's queue that is not this position — a 计划外 go is not
    /// in the queue and so never comes next from it (docs/adr/0032). Picked off the book, the
    /// next 错题 in the book's order, round to the first. Nil when there is nothing else to ask:
    /// the end of the queue, or a book of one.
    public func next(after mistake: Mistake, source: Drill.Source) -> Mistake? {
        switch source {
        case .daily:
            return daily.cards.first { $0.position != mistake.position && $0.mistake != nil }?
                .mistake
        case .picked:
            let mistakes = book.mistakes
            guard let here = mistakes.firstIndex(where: { $0.position == mistake.position }),
                mistakes.count > 1
            else { return nil }
            return mistakes[(here + 1) % mistakes.count]
        }
    }

    /// The position after this one in today's queue, whichever kind it is (docs/adr/0051). Nil at
    /// the end of the queue.
    public func next(after position: PositionKey) -> PositionKey? {
        daily.cards.first { $0.position != position }?.position
    }

    /// What the 日课 door is: how much of the day is left, and what it reads.
    ///
    /// **The door stays on the screen with nothing due.** A door that disappears once it is done
    /// is a door nobody learns is there, and 「今天的练完了」 is the whole of what a day's work
    /// buys. `isOpen` is therefore about whether there is anything to open, not about whether the
    /// door is drawn.
    public struct Door: Hashable, Sendable {
        public let left: Int
        /// Whether the book has anything in it at all, which decides between 「还没有错题」 and
        /// 「今天的练完了」 — two different silences.
        public let bookIsEmpty: Bool

        public init(left: Int, bookIsEmpty: Bool) {
            self.left = left
            self.bookIsEmpty = bookIsEmpty
        }

        /// Whether there is a question behind it today. The only thing a screen may derive from
        /// `left` — the colour, the chevron and the disabled state were three separate `left > 0`
        /// checks in the view, any of which could have drifted.
        public var isOpen: Bool { left > 0 }

        public var label: String {
            if left > 0 { return localized("daily.left", plural: left) }
            return localized(bookIsEmpty ? "daily.none" : "daily.done")
        }
    }

    public var door: Door {
        Door(
            left: daily.remaining,
            bookIsEmpty: book.isEmpty && !daily.all.contains { $0.holding != nil }
        )
    }
}
