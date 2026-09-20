@testable import ChessmirrorKit
import Foundation
import Testing
import ChessmirrorKitTesting

@Suite(.speaking(.chinese)) struct TacticsFinderTests {
    /// White queen on d1, black rook hanging on d5: a shot the rules can name unaided.
    private static let hangingRook = "4k3/8/8/3r4/8/8/8/3QK3 w - - 0 1"

    private func game(_ fen: String) throws -> Game {
        try #require(Game(startFEN: fen))
    }

}
