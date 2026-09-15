import ChessfenKit
import Testing

/// The six standard perft positions. If the vendored engine were misconfigured — wrong
/// defines, a half-linked target, a broken bitboard table — these numbers would not come
/// out, so this file is the proof that Stockfish is really in the build.
private struct PerftCase {
    let name: String
    let fen: String
    /// Expected leaf counts for depth 1, 2, 3, …
    let counts: [UInt64]
}

private let perftCases: [PerftCase] = [
    PerftCase(
        name: "starting position",
        fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        counts: [20, 400, 8902, 197_281, 4_865_609]
    ),
    PerftCase(
        name: "kiwipete",
        fen: "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        counts: [48, 2039, 97_862, 4_085_603]
    ),
    PerftCase(
        name: "endgame with promotions and pins",
        fen: "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        counts: [14, 191, 2812, 43_238, 674_624]
    ),
    PerftCase(
        name: "castling and promotion tangle",
        fen: "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
        counts: [6, 264, 9467, 422_333]
    ),
    PerftCase(
        name: "no castling rights, sharp middlegame",
        fen: "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
        counts: [44, 1486, 62_379, 2_103_487]
    ),
    PerftCase(
        name: "symmetrical middlegame",
        fen: "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
        counts: [46, 2079, 89_890, 3_894_594]
    ),
]

@Test("Stockfish generates exactly the standard perft counts", arguments: perftCases.indices)
func perftMatchesTheStandardCounts(index: Int) {
    let testCase = perftCases[index]
    for (offset, expected) in testCase.counts.enumerated() {
        let depth = offset + 1
        #expect(
            Rules.perft(fen: testCase.fen, depth: depth) == expected,
            "\(testCase.name) at depth \(depth)"
        )
    }
}

@Test("depth zero is the position itself")
func perftAtDepthZeroIsOne() {
    #expect(Rules.perft(fen: perftCases[0].fen, depth: 0) == 1)
}

@Test("an unusable FEN counts nothing rather than crashing")
func perftRefusesAnUnusableFen() {
    #expect(Rules.perft(fen: "8/8/8/8/8/8/8/8 w - - 0 1", depth: 1) == 0)
}
