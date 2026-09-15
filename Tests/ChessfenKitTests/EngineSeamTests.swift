// Testable for the seams themselves: `DepthGroup` and `SearchGate` are the engine's
// insides, and these tests are where they are asked directly.
@testable import ChessfenKit
import CStockfish
import Foundation
import Testing

/// The seams under the engine, asked directly — the pause rule and the frame-to-Analysis
/// conversion — instead of being reached through a running search.
///
/// These are what the hang-shaped gate tests used to drive a real search to find: a paused
/// engine's answer to each kind of budget, and what a batch of Stockfish info frames becomes.
/// Neither needs the engine, so neither can hang, and both run in the same breath as the
/// rest of the suite.
@Suite("engine seams")
struct EngineSeamTests {

    // --------------------------------------------------------------- the gate

    @Test("a paused engine refuses a standing analysis and admits bounded ones")
    func theGateAdmitsByBudget() {
        #expect(!EngineService.SearchGate.admits(.untilStopped))
        #expect(EngineService.SearchGate.admits(.time(.seconds(1))))
        #expect(EngineService.SearchGate.admits(.depth(12)))
        #expect(EngineService.SearchGate.admits(.nodes(10_000)))
    }

    // -------------------------------------------------------------- the frames

    /// One raw info frame, the way Stockfish hands one over.
    private func frame(
        depth: Int32, multiPv: Int32,
        centipawns: Int32 = 0, matePlies: Int32 = 0,
        isBound: Bool = false, pv: String = "e2e4"
    ) -> CfSearchInfo {
        var info = CfSearchInfo()
        info.depth = depth
        info.selectiveDepth = depth
        info.multiPvIndex = multiPv
        info.centipawns = centipawns
        info.matePlies = matePlies
        info.isMate = matePlies != 0
        info.isBound = isBound
        info.nodes = 1000
        info.nodesPerSecond = 50_000
        info.timeMs = 20
        info.hashFull = 500
        withUnsafeMutableBytes(of: &info.pv) { bytes in
            bytes.copyBytes(from: pv.utf8.prefix(1023))
        }
        return info
    }

    private func group(_ fen: String = PGN.standardStartFEN, perspective: PieceColour)
        throws -> DepthGroup
    {
        let game = try #require(Game(startFEN: fen))
        return DepthGroup(state: game.state, perspective: perspective)
    }

    // Both `absorb` and `take` are mutating, and the `#expect`/`#require` macros capture
    // their argument in an escaping closure — so every one of them is read out into a `let`
    // before anything is asserted on it.

    @Test("one depth is held until all its lines are in")
    func aDepthWaitsForItsLines() throws {
        var group = try group(perspective: .white)

        let first = group.absorb(frame(depth: 5, multiPv: 1, centipawns: 12))
        let second = group.absorb(frame(depth: 5, multiPv: 2, centipawns: 8))
        let third = group.absorb(frame(depth: 5, multiPv: 3, centipawns: 4))
        #expect(!first)
        #expect(!second)
        #expect(!third)

        let taken = group.take()
        let ready = try #require(taken)
        #expect(ready.depth == 5)
        #expect(ready.lines.count == 3)
        #expect(ready.lines.map(\.uciMoves.first) == ["e2e4", "e2e4", "e2e4"])
        #expect(!ready.isPartial)
    }

    @Test("a new depth pushes the finished one out")
    func theNextDepthEmitsTheLast() throws {
        var group = try group(perspective: .white)
        _ = group.absorb(frame(depth: 4, multiPv: 1, centipawns: 10))
        _ = group.absorb(frame(depth: 4, multiPv: 2, centipawns: 6))
        _ = group.absorb(frame(depth: 4, multiPv: 3, centipawns: 2))

        // The first frame of depth 5 completes depth 4 and starts depth 5.
        let flush = group.absorb(frame(depth: 5, multiPv: 1, centipawns: 14))
        #expect(flush)
        let taken = group.take()
        let ready = try #require(taken)
        #expect(ready.depth == 4)
        #expect(ready.lines.count == 3)
    }

    @Test("a cut-off line marks the snapshot partial")
    func aBoundLineIsPartial() throws {
        var group = try group(perspective: .white)
        _ = group.absorb(frame(depth: 3, multiPv: 1, centipawns: 9, isBound: true))
        let partial = group.take()?.isPartial
        #expect(partial == true)
    }

    @Test("scores come back White-relative whichever side is to move")
    func scoresAreWhiteRelative() throws {
        // Stockfish reports from the searching side's point of view; the flip must not
        // depend on whose turn it is.
        var white = try group(perspective: .white)
        _ = white.absorb(frame(depth: 2, multiPv: 1, centipawns: 300))
        let whiteScore = white.take()?.best?.score
        #expect(whiteScore == .centipawns(300))

        var black = try group(perspective: .black)
        _ = black.absorb(frame(depth: 2, multiPv: 1, centipawns: 300))
        let blackScore = black.take()?.best?.score
        #expect(blackScore == .centipawns(-300))
    }

    @Test("mate plies become mate moves, and flip with the side to move")
    func matePliesFlipToo() throws {
        // Stockfish counts plies from the searching side: 3 plies is a mate in 2, and from
        // the black side of the board the White-relative flip makes it White's mate.
        var black = try group(perspective: .black)
        _ = black.absorb(frame(depth: 2, multiPv: 1, matePlies: 3))
        let blackMate = black.take()?.best?.score
        #expect(blackMate == .mate(in: -2))

        var white = try group(perspective: .white)
        _ = white.absorb(frame(depth: 2, multiPv: 1, matePlies: 1))
        let whiteMate = white.take()?.best?.score
        #expect(whiteMate == .mate(in: 1))
    }

    @Test("the line is replayed into SAN a player can read")
    func theLineIsReplayedIntoSan() throws {
        var group = try group(perspective: .white)
        _ = group.absorb(frame(depth: 2, multiPv: 1, centipawns: 15, pv: "e2e4 e7e5 g1f3"))
        let san = group.take()?.best?.san
        #expect(san == ["e4", "e5", "Nf3"])
    }
}
