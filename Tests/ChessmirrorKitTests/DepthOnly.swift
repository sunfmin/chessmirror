@testable import ChessmirrorKit

/// The real engine, searched to one fixed depth with no clock: a time bound makes the depth a
/// search reaches a fact about the machine's load, and so its verdict (chessmirror#12, #13: a
/// depth-twenty judgement read nineteen under a loaded gate). Everything else is the engine's own.
final class DepthOnly: Engine {
    let depth: Int
    let engine: EngineService
    let positionSearches = PositionSearches()
    init(_ engine: EngineService, depth: Int) {
        self.engine = engine
        self.depth = depth
    }
    var isPaused: Bool { engine.isPaused }
    func analyse(
        _ game: Game, budget: SearchBudget, lines: Int, strength: Strength
    ) -> AsyncStream<Analysis> {
        engine.analyse(game, budget: .depth(depth), lines: lines, strength: strength)
    }
    func pause() { engine.pause() }
    func resume() { engine.resume() }
}
