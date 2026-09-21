import Foundation

extension GameSession {
    /// What a tap on the board means, given the square already picked up.
    ///
    /// Tap-to-move was the screen's for a year — which square picks a piece up, which one puts
    /// it down, when two moves to one square mean a promotion to choose, and when putting a piece
    /// down is a refusal worth a noise — so the rules of touching the board were a thing only a
    /// finger on a simulator could check.
    public enum Tap: Equatable, Sendable {
        /// Not the hand's turn: the board is not for touching.
        case ignored
        /// A piece of the side to move, picked up.
        case pick(Square)
        /// The move the held piece makes to this square.
        case play(Move)
        /// Several moves to one square, which is a promotion and only a promotion: the piece to
        /// become is asked for.
        case promote([Move])
        /// Whatever was held is put down. `refused` when something was held and the tap was
        /// nowhere it could go — the tap that was meant as a move and was not one.
        case drop(refused: Bool)
    }

    /// Resolves a tap on `square` with `held` already picked up. Nothing is played here: a
    /// promotion needs a choice first, and the screen that holds the choice plays the move.
    public func tap(_ square: Square, holding held: Square?) -> Tap {
        guard isHandTurn else { return .ignored }
        if held != nil {
            let moves = moves(holding: held).filter { $0.to == square }
            if moves.count > 1 { return .promote(moves) }
            if let move = moves.first { return .play(move) }
        }
        // Not a destination, so it is either a new pick or a put-down.
        let position = board.state
        if let piece = BoardRenderer.placement(position.fen)?[square], piece.colour == position.sideToMove {
            return .pick(square)
        }
        return .drop(refused: held != nil)
    }

    /// The moves the held piece has, which is where the board rings its destinations. None when
    /// nothing is held, or the board is not the hand's.
    public func moves(holding held: Square?) -> [Move] {
        guard let held, isHandTurn else { return [] }
        return board.state.moves(from: held)
    }
}
