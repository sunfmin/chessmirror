import CStockfish
import ChessmirrorKit
import Foundation
import Synchronization
import Testing

/// What sf_19 refuses never reaches it (chessmirror#15). Its UCI loop answers a refused FEN,
/// position or move with `info string CRITICAL ERROR` and `exit(1)`, and the engine is in the
/// app's own process: one such input would close the app. So a real engine — both builds — is
/// handed every input `sf19Refusals` lists, and an illegal move besides, at the bridge's own door;
/// each is refused there, nothing is searched, and the same engine then searches as if nothing
/// had happened. That the test is still running to check the last line is the process surviving.
@Suite("Engine refusals", .serialized)
struct EngineRefusalTests {
    /// What a search said, gathered from Stockfish's threads.
    final class Heard: Sendable {
        let bestMoves = Mutex<[String]>([])
    }

    @Test(
        "an input sf_19 would refuse is refused at the bridge, and the engine searches on",
        arguments: [CF_BUILD_ARMV8, CF_BUILD_DOTPROD]
    )
    func refusedInputsNeverReachTheEngine(build: CfEngineBuild) async throws {
        try #require(Nets.arePresent, "the NNUE weights are missing — see README.md")
        if build == CF_BUILD_DOTPROD {
            try #require(CPUFeatures.current.hasDotProd, "this Mac cannot run the dotprod build")
        }
        var status = CF_ENGINE_OK
        let engine = try #require(
            Nets.net.withUnsafeFileSystemRepresentation { cf_engine_create(build, $0, &status) }
        )
        defer { cf_engine_destroy(engine) }

        let heard = Heard()
        let context = Unmanaged.passUnretained(heard).toOpaque()
        let onBest: CfBestMoveCallback = { context, best, _ in
            let heard = Unmanaged<Heard>.fromOpaque(context!).takeUnretainedValue()
            heard.bestMoves.withLock { $0.append(String(cString: best!)) }
        }
        var limits = CfSearchLimits(movetimeMs: 0, depth: 6, nodes: 0)

        func go(_ fen: String, _ moves: [String] = []) -> Bool {
            var pointers = moves.map { strdup($0) }
            defer { pointers.forEach { free($0) } }
            return pointers.withUnsafeMutableBufferPointer { buffer in
                buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: max(buffer.count, 1)) {
                    cf_engine_go(engine, fen, $0, Int32(moves.count), &limits, context, nil, onBest)
                }
            }
        }

        for (fen, _) in sf19Refusals {
            #expect(!go(fen), "\(fen) was handed to the engine")
            cf_engine_wait(engine)
        }
        // A legal start and a move that is not legal in it: sf_19's set_position refuses that
        // too ("Illegal move"), so it is stopped at the replay before the engine is asked.
        #expect(!go(PGN.standardStartFEN, ["e2e5"]))
        cf_engine_wait(engine)
        #expect(heard.bestMoves.withLock { $0.isEmpty }, "nothing refused was searched")

        #expect(go(PGN.standardStartFEN, ["e2e4"]))
        cf_engine_wait(engine)
        let best = heard.bestMoves.withLock { $0 }
        #expect(best.count == 1 && best.first != "(none)", "the engine searched on: \(best)")
    }
}
