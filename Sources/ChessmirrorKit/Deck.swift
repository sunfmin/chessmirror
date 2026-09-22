import Foundation

/// 牌堆 — what the deck under the record has to show about the position on screen (docs/adr/0025).
///
/// Two cards, always in the same order, and a card with nothing behind it takes up no room: the
/// deck does not change shape, but a finding that is not there is not dealt (docs/adr/0023).
/// Which cards exist, when one may be dealt at all, what its row says while the finder is still
/// looking and what pressing it means are facts about the game rather than about the layout —
/// they were the view's for a year, which is why the only way to ask them was to photograph a
/// simulator.
///
/// The room a card takes on the glass is still the screen's (docs/adr/0025); this says what is
/// on the table and what each one is called.
public struct Deck: Sendable, Equatable {
    /// One finding of the deck. A kind rather than an index, because what the deck has to show
    /// comes from the position — an index would point at a different card every time the
    /// position changed shape.
    public enum Card: String, Hashable, Sendable, CaseIterable {
        case mate, tactics

        /// Every card, in one order, whatever the position. **The deck does not change shape**:
        /// two cards that never move can be learnt.
        public static var catalogue: [Card] { [.mate, .tactics] }

        /// The name on the card's rail.
        public var title: String {
            switch self {
            case .mate: localized("screen.mate")
            case .tactics: localized("screen.tactics")
            }
        }

        /// One line saying what the card answers, in the words of somebody who does not yet know
        /// the name above it.
        public var subtitle: String {
            switch self {
            case .mate: localized("screen.mateSubtitle")
            case .tactics: localized("screen.tacticsSubtitle")
            }
        }

        public var symbol: String {
            switch self {
            case .mate: "flag.fill"
            case .tactics: "bolt.fill"
            }
        }
    }

    /// One card as its row reads it: whether the finding is in, what the row says either way,
    /// and where it stands in front of the player (`Findings`).
    public struct Row: Hashable, Sendable {
        public let card: Card
        /// Whether there is something to open. A row with nothing behind it is not pressable, and
        /// pressing it is not help.
        public let isFound: Bool
        /// What the row says: 「发现杀招」 for a finding, else the card's name and what the finder
        /// is doing about it — 在算 while a search is running, 没算出来 when it has finished with
        /// nothing.
        public let title: String
        /// Whether this is the card open in front of the player (docs/adr/0025). The eye moving
        /// to another position puts it away, so this is as much about where the board is as
        /// about which card was pressed.
        public let isOpen: Bool
        /// Whether its line is the one on the board. Only an open card can draw, and the arrow
        /// on the card takes the line off and leaves the card open.
        public let drawsLine: Bool
    }

    /// The rows the deck has, in the catalogue's order. Empty when the deck is not dealt at all
    /// (`GameSession.dealsCards`): a 把关 game says nothing about what to play (docs/adr/0031).
    public let rows: [Row]

    /// Whether anything is still being looked for. The two searches are one answer here: a person
    /// watching a spinner does not care which of them is spinning.
    public let isSearching: Bool

    public init(rows: [Row], isSearching: Bool) {
        self.rows = rows
        self.isSearching = isSearching
    }

    /// The cards with a finding behind them, which are the ones that take up room.
    public var dealt: [Row] { rows.filter(\.isFound) }

    public var isEmpty: Bool { dealt.isEmpty }

    public func row(_ card: Card) -> Row? { rows.first { $0.card == card } }

    /// Whether this card has something to open.
    public func has(_ card: Card) -> Bool { row(card)?.isFound ?? false }

    // ------------------------------------------------------------------ dealing

    /// The deck for a position: which findings are in, what each row says, and which one is
    /// open in front of the player.
    ///
    /// `isDealt` is the session's rule about whether cards are on the table at all
    /// (`GameSession.dealsCards`), passed in rather than read here so this stays a reading of
    /// findings and the rule keeps one home. `open` is the same for `Findings`: the deck reads
    /// what the state machine says and does not keep a second copy of it.
    public static func dealt(
        isDealt: Bool, mate: Bool, tactic: Bool, isSearching: Bool,
        open opened: Card? = nil, drawsLine: Bool = false
    ) -> Deck {
        guard isDealt else { return Deck(rows: [], isSearching: false) }
        let rows = Card.catalogue.map { card in
            let found = card == .mate ? mate : tactic
            let open = card == opened
            return Row(
                card: card,
                isFound: found,
                title: found
                    ? localized(card == .mate ? "discovery.mateFound" : "discovery.tacticFound")
                    : "\(card.title) · \(localized(isSearching ? "discovery.checking" : "discovery.none"))",
                isOpen: open,
                drawsLine: open && drawsLine
            )
        }
        return Deck(rows: rows, isSearching: isSearching)
    }
}
