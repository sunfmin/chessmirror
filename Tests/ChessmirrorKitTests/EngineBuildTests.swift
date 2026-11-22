import ChessmirrorKit
import Foundation
import Testing

/// Which Stockfish build an engine is started on (docs/adr/0052). The armv8 build is the one
/// an A12 can run; the dotprod build is an illegal instruction there, so the choice is the
/// difference between a faster engine and an app that dies at its first evaluation.
@Suite("Engine build", .serialized)
struct EngineBuildTests {
    @Test("a CPU without dotprod gets the armv8 build, and one with it gets dotprod")
    func theBuildFollowsTheCPU() {
        #expect(EngineBuild(for: CPUFeatures(hasDotProd: false)) == .armv8)
        #expect(EngineBuild(for: CPUFeatures(hasDotProd: true)) == .dotprod)
    }

    @Test("given a CPU without dotprod, the engine started is the armv8 one")
    func aCPUWithoutDotprodStartsTheArmv8Engine() async throws {
        try await Quietly.alone {
            try #require(Nets.arePresent, "the NNUE weights are missing — see README.md")
            let engine = try EngineService(
                bigNetURL: Nets.big, smallNetURL: Nets.small,
                configuration: .init(threads: 1, hashMegabytes: 16, multiPV: 1),
                cpu: CPUFeatures(hasDotProd: false)
            )
            // What the bridge says it created, not what was asked for.
            #expect(engine.build == .armv8)
            let game = try #require(Game(startFEN: PGN.standardStartFEN))
            #expect(await engine.evaluate(game, budget: .depth(4)) != nil)
        }
    }

    /// The two builds are one engine: dotprod changes how the NNUE layers multiply, not what
    /// they answer, so one thread to a fixed depth walks the same tree in both. A dotprod
    /// build that searched a different number of nodes would be a different engine, and its
    /// speed would not be the armv8 build's speed bought cheaper.
    @Test("both builds search the same tree, node for node")
    func bothBuildsSearchTheSameTree() async throws {
        try await Quietly.alone {
            try #require(Nets.arePresent, "the NNUE weights are missing — see README.md")
            let game = try #require(
                Game(startFEN: "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4"))
            var nodes: [EngineBuild: UInt64] = [:]
            for hasDotProd in [false, true] {
                // Only where this machine can run dotprod; elsewhere one build is all there is.
                guard !hasDotProd || CPUFeatures.current.hasDotProd else { continue }
                let engine = try EngineService(
                    bigNetURL: Nets.big, smallNetURL: Nets.small,
                    configuration: .init(threads: 1, hashMegabytes: 16, multiPV: 1),
                    cpu: CPUFeatures(hasDotProd: hasDotProd)
                )
                var last: Analysis?
                for await analysis in engine.analyse(game, budget: .depth(10), lines: 1) {
                    last = analysis
                }
                nodes[engine.build] = try #require(last).nodes
            }
            if CPUFeatures.current.hasDotProd {
                #expect(nodes[.armv8] != nil && nodes[.armv8] == nodes[.dotprod])
            }
            // And the same tree as the engine has always searched: the count Stockfish sf_18
            // reaches here, which a compiler flag (chessmirror#13) or a define that changed the
            // search, rather than how fast it runs, would move.
            #expect(nodes[.armv8] == 12507)
        }
    }
}
