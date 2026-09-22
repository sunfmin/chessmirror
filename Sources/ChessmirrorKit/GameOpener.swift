import Foundation

/// What every game is opened with: the engine it plays against, the library it is kept in, and
/// the rung and lines the player has set (docs/adr/0038, 0046).
///
/// Six places open a game — a photograph, a corrected photograph, a new game, a game off the
/// shelf, a best on the ladder, a 错题's encounter — and each of them used to hand the four over
/// one by one. Two of them forgot the rung, and a game read off the camera played at 满力
/// whatever the player had picked. Now there is one thing to hand over, and it cannot forget a
/// part of itself.
@MainActor public struct GameOpener {
    public let engine: (any Engine)?
    public let library: GameLibrary?
    public let strength: Strength
    public let lines: JudgementLines

    public init(
        engine: (any Engine)?, library: GameLibrary?,
        strength: Strength = .full, lines: JudgementLines = .standard
    ) {
        self.engine = engine
        self.library = library
        self.strength = strength
        self.lines = lines
    }

    /// Opens under what the player has set right now.
    public init(engine: (any Engine)?, library: GameLibrary?, settings: PlayerSettings) {
        self.init(engine: engine, library: library, strength: settings.strength, lines: settings.lines)
    }

    /// A new game with the engine seated opposite, from the position given — under 把关 when
    /// asked, which is the one line a game may be opened with that the player's settings do not
    /// hold (docs/adr/0046).
    public func play(_ game: Game, noSlips: Bool = false) -> GameSession {
        var lines = lines
        lines.noSlips = noSlips
        return .playing(game, engine: engine, library: library, strength: strength, lines: lines)
    }

    public func open(_ entry: GameLibrary.Entry) -> GameSession.Opening {
        GameSession.opened(entry, engine: engine, library: library, strength: strength, lines: lines)
    }

    /// The game kept at this file, walked to a ply when one is given — a 错题's encounter is
    /// opened *at* the move, and the moves land one after another on the way there. `.notArrived`
    /// when the library has no such game, or it has not arrived.
    public func open(_ url: URL, walkingTo ply: Int? = nil) -> GameSession.Opening {
        guard let entry = library?.entry(at: url) else { return .notArrived }
        guard case .ready(let session) = open(entry) else { return .notArrived }
        if let ply { session.walkOnArrival(toPly: ply) }
        return .ready(session)
    }

    /// A game read off a photograph.
    public func recognised(
        _ game: Game, orientation: Orientation, picture: RGBImage?, shaky: Set<Square>
    ) -> GameSession {
        .recognised(
            game, orientation: orientation, picture: picture, shaky: shaky,
            engine: engine, library: library, strength: strength, lines: lines
        )
    }

    /// A game from a position somebody put right by hand, as a game of its own.
    public func corrected(
        _ game: Game, controllers: [PieceColour: Controller], orientation: Orientation,
        origin: GameOrigin, picture: RGBImage?, shaky: Set<Square>
    ) -> GameSession {
        .corrected(
            game, controllers: controllers, orientation: orientation, origin: origin,
            picture: picture, shaky: shaky, engine: engine, library: library,
            strength: strength, lines: lines
        )
    }
}
