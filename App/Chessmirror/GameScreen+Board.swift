import ChessmirrorKit
import SwiftUI

/// The board itself, and what a finger on it means.
///
/// `GameScreen`'s own concern, split out for locality: the body composes these, and
/// what each one draws lives here so changing the record does not mean reading the
/// sides. They are extensions of `GameScreen` rather than types of their own because
/// they share its `@State` — a thumb's selection, a promotion being asked for — which
/// is the screen's, not a piece's.
extension GameScreen {
    // ------------------------------------------------------------------ the bar at the top

    /// Turns the board round — and with it, which side's controls are above and which below. The
    /// state it is in is the board, so it needs no label saying so.
    var flip: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                session.orientation = .facing(session.orientation.top)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .foregroundStyle(Palette.ink)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized("game.flip"))
    }

    // ------------------------------------------------------------------ the board

    /// Where the board goes and how big it is. It depends on the window and nothing else, so it
    /// never changes size because the engine found a third line to show — the one thing on this
    /// screen that must never move.
    ///
    /// On a phone the answer is always the same: full width, one column, and the page scrolls for
    /// the rest (docs/adr/0025). An iPad is a window of any shape, and the phone's answer is wrong
    /// for most of them — a board as wide as a landscape screen is taller than the screen, and the
    /// part under the fold is half the game. So the board is held to the height left once its two
    /// player bars and the standing line are counted, and a window wide enough to spare a column
    /// beside that puts the record and the cards in it.
    struct Arrangement: Equatable {
        /// The board's side, in points.
        let side: CGFloat
        /// Whether the record and the cards stand beside the board rather than under it.
        let isBeside: Bool

        /// What the two player bars and the standing line take, above and below the board, at the
        /// text sizes the chrome is capped to.
        static let chrome: CGFloat = 150
        /// The narrowest the column beside the board may be: a record strip and a card's sentence.
        static let column: CGFloat = 320

        init(in size: CGSize) {
            let tallest = max(0, size.height - Self.chrome)
            if size.width > size.height, size.width >= 2 * Self.column {
                // Wider than tall: the board as tall as the window allows, and where that would
                // not leave a column beside it, the board gives way to the column.
                side = min(tallest, size.width - Self.column)
                isBeside = true
            } else {
                // A phone, a portrait iPad or a narrow Split View window: one column, the board
                // as wide as it can be without pushing its own bars off the screen.
                side = max(0, min(size.width, max(tallest, size.width * 0.5)))
                isBeside = false
            }
        }
    }

    var board: some View {
        // One reading of the board (`BoardReading`): the pieces, whose they are, the marks
        // around them and the one line on it. What is picked up and where it may go is the
        // finger's — a session cannot know it.
        let reading = session.boardReading
        return BoardView(
            pieces: reading.pieces,
            orientation: reading.orientation,
            isFaceToFace: reading.isFaceToFace,
            lastMove: reading.lastMove,
            checks: reading.checks,
            suspects: reading.suspects,
            selected: selected,
            destinations: Set(session.moves(holding: selected).map(\.to)),
            captures: Set(session.moves(holding: selected).filter(\.isCapture).map(\.to)),
            recommendation: nil,
            plan: reading.plan,
            isInteractive: reading.isInteractive,
            onTap: tap
        )
    }

    // ------------------------------------------------------------------ doing

    /// What the tap means is the session's (`GameSession.tap`); what is left here is holding the
    /// picked-up square and asking for the promotion piece.
    func tap(_ square: Square) {
        switch session.tap(square, holding: selected) {
        case .ignored:
            return
        case .pick(let square):
            selected = square
        case .play(let move):
            session.play(move)
            selected = nil
        case .promote(let moves):
            promotion = PromotionRequest(moves: moves)
            selected = nil
        case .drop:
            // A tap that was meant as a move and was not one has already been said, as
            // `Event.refused`, through the one noise path (`session.hear`).
            selected = nil
        }
    }

    func walk(_ delta: Int) {
        selected = nil
        session.step(by: delta)
    }

    /// A tap on a cell of the record strip. The strip holds still for it (see `isTappingStrip`);
    /// the flag is raised only when the cursor is actually going to move, so a tap on the cell
    /// already on the cursor — which changes nothing — cannot leave it raised for the next arrow.
    func walk(to cursor: Int) {
        selected = nil
        guard session.canBrowse, cursor != session.cursor else { return }
        isTappingStrip = true
        session.step(by: cursor - session.cursor)
    }

}
