/// 牌堆's open card (docs/adr/0025): which one, on which position, and whether its line is
/// drawn. One small state machine behind one seam — the session asks it to press, toggle and
/// forget, and reads back what the screen may show.
struct Findings: Equatable, Sendable {
    struct Opened: Equatable, Sendable {
        let card: Deck.Card
        let position: String
        var drawsLine: Bool
    }

    private var opened: Opened?
    /// Whether the deck has been dealt: once per game on screen, not on every appearance, or
    /// coming back from a Review would ask the engine again for what is already on the table.
    var isDealt = false

    /// The card that is open on this position, if one is. Nothing opened on one position is
    /// open on another — the eye moving is the card being put away.
    func openCard(on fen: String) -> Deck.Card? {
        guard let opened, opened.position == fen else { return nil }
        return opened.card
    }

    func isOpen(_ card: Deck.Card, on fen: String) -> Bool {
        openCard(on: fen) == card
    }

    /// Whether this card's line is the one on the board.
    func draws(_ card: Deck.Card, on fen: String) -> Bool {
        isOpen(card, on: fen) && opened?.drawsLine == true
    }

    /// Whether the card open on `fen` has its line on the board. What `Deck` is handed: the
    /// deck is a reading of this state machine, not a second copy of it.
    func drawsLine(on fen: String) -> Bool {
        openCard(on: fen) != nil && opened?.drawsLine == true
    }

    /// Pressing a finding. The one pressed opens with its line drawn; pressing the open one
    /// shuts it. Returns whether something was opened (so a 练习 can count help).
    @discardableResult
    mutating func press(_ card: Deck.Card, on fen: String) -> Bool {
        if isOpen(card, on: fen) {
            opened = nil
            return false
        }
        opened = Opened(card: card, position: fen, drawsLine: true)
        return true
    }

    /// The arrow on the open card: its line on the board, or off it.
    mutating func toggleLine() {
        guard opened != nil else { return }
        opened?.drawsLine.toggle()
    }

    /// The eye has moved to another position. Nothing opened about the one it left still stands.
    mutating func forget() {
        opened = nil
    }
}
