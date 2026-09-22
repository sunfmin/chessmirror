import Foundation

/// 盘面读数 — what the board shows, already assembled (`BoardReading`).
///
/// The screen used to walk `GameSession → Game → GameState` to draw: `board.state.fen`,
/// `checkSquares`, `inCheck`, `boardLastMove` — four reaches through two modules to get a
/// frame's worth of pieces and marks. `GameState` is the rules' **implementation**; a screen
/// that knows its fields cannot be told "the board changed shape" without being told which
/// fields of which struct to stop reading.
///
/// The session already hands over ready-to-draw values for the strip (`Strip`) and the record
/// (`RecordReading`). This is the same thing for the board: the pieces, whose they are to the
/// player, the marks around them, and the one line being drawn on it. Gesture state — what is
/// picked up, where it may go — stays with the finger, which is the one thing a session cannot
/// know.
public struct BoardReading: Hashable, Sendable {
    /// Where every piece stands, by square. Empty rather than optional: a board with nothing on
    /// it is a board, and `BoardRenderer.placement` failing is not something a screen can draw.
    public let pieces: [Square: Piece]
    /// Which way up the board is.
    public let orientation: Orientation
    /// Two manual sides, facing each other (docs/adr/0025).
    public let isFaceToFace: Bool
    /// The move that was just played, for its two squares. Nil when a 惩罚 exercise has the
    /// board — the game's last move is not what the player is looking at.
    public let lastMove: MoveSquares?
    /// The squares in check.
    public let checks: Set<Square>
    /// Recognition's doubtful squares, while they are still worth pointing at (docs/adr/0011).
    public let suspects: Set<Square>
    /// Whether the board is for touching.
    public let isInteractive: Bool
    /// The one line drawn on it: a 应招 being read, else the card in front of the player
    /// (docs/adr/0025). Empty when neither.
    public let plan: [MoveArrow]

    public init(
        pieces: [Square: Piece], orientation: Orientation, isFaceToFace: Bool,
        lastMove: MoveSquares?, checks: Set<Square>, suspects: Set<Square>,
        isInteractive: Bool, plan: [MoveArrow]
    ) {
        self.pieces = pieces
        self.orientation = orientation
        self.isFaceToFace = isFaceToFace
        self.lastMove = lastMove
        self.checks = checks
        self.suspects = suspects
        self.isInteractive = isInteractive
        self.plan = plan
    }
}

extension GameSession {
    /// 盘面读数 — the board as the screen draws it (`BoardReading`), assembled once here.
    ///
    /// `BoardRenderer.placement` is called once per reading rather than once per reach. The
    /// plan is whichever card is in front of the player, and only that one: arrows left over
    /// from a card swiped away are arrows about a position nobody is looking at (docs/adr/0025).
    /// A 应招 beats all of them while it is being read: it is the one line somebody has just
    /// asked for, and the board can only carry one at a time.
    public var boardReading: BoardReading {
        let fen = board.state.fen
        let plan =
            replyReading.map(\.arrows).flatMap { $0.isEmpty ? nil : $0 } ?? deckArrows
        return BoardReading(
            pieces: BoardRenderer.placement(fen) ?? [:],
            orientation: orientation,
            isFaceToFace: isFaceToFace,
            lastMove: boardLastMove,
            checks: board.state.checkSquares,
            suspects: unconfirmedSquares,
            isInteractive: isHandTurn,
            plan: plan
        )
    }
}
