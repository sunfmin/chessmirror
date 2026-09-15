import ChessfenKit
import Foundation
import Testing

/// The one way a picture becomes a game, whichever door it came in through. The screens
/// switch on the outcome, so the outcome is what is checked: the cases and the routing
/// between them (docs/adr/0011).
struct BoardIntakeTests {
    @Test("a source that is not a picture is unreadable")
    func garbageIsUnreadable() async {
        let intake = await BoardIntake.read(.data(Data("not a picture".utf8)))
        guard case .unreadable = intake else {
            Issue.record("expected .unreadable")
            return
        }
    }

    @Test("a picture without a board says so")
    func blankIsNoBoard() async {
        let blank = RGBImage(
            width: 480, height: 360,
            pixels: [UInt8](repeating: 245, count: 480 * 360 * 3)
        )
        let intake = await BoardIntake.read(.image(blank))
        guard case .noBoard = intake else {
            Issue.record("expected .noBoard")
            return
        }
    }

    /// The routing 0011 hangs on: a legal reading is a game, never an editor.
    @Test("a legal reading opens as a game")
    func renderedBoardPlays() async throws {
        let image = try #require(BoardRenderer.image(fen: PGN.standardStartFEN))
        let intake = await BoardIntake.read(.image(image))
        guard case .played(let game, _, _, let picture) = intake else {
            Issue.record("expected .played")
            return
        }
        #expect(game.state.fen == PGN.standardStartFEN)
        #expect(picture.width > 0, "the board is cut out of the frame")
    }
}
