import ChessfenKit
import Foundation
import Testing

/// A position reached by random legal play — cheap, diverse, always legal.
func playout(seed: UInt64, plies: Int) -> String {
    var random = SplitMix64(seed: seed)
    var game = Game(startFEN: PGN.standardStartFEN)!
    for _ in 0..<plies {
        let moves = game.state.legalMoves
        guard !moves.isEmpty else { break }
        _ = game.apply(moves[Int(random.next(below: UInt64(moves.count)))])
    }
    // A recognised Position has no history, so the comparison must not have one either.
    return withoutHistory(game.state.fen)
}

/// The same FEN with the fields a picture cannot show reset to what the recogniser fills
/// in: no castling rights, clocks at the start.
func withoutHistory(_ fen: String) -> String {
    var fields = fen.split(separator: " ").map(String.init)
    guard fields.count == 6 else { return fen }
    fields[2] = "-"
    fields[3] = "-"
    fields[4] = "0"
    fields[5] = "1"
    return fields.joined(separator: " ")
}

/// Renders a position, recognises it back, and returns the FEN that came out.
func readBack(
    _ fen: String,
    options: BoardRenderer.Options = BoardRenderer.Options(),
    orientation: Orientation? = nil
) throws -> String {
    let image = try #require(BoardRenderer.image(fen: fen, options: options))
    let turn: PieceColour = fen.split(separator: " ").dropFirst().first == "b" ? .black : .white
    return try Recognizer.recognise(
        image, turn: turn, orientation: orientation, castling: .none
    ).fen
}

/// The reference screenshot, from the test bundle.
func referenceScreenshot() throws -> RGBImage {
    let url = try #require(
        Bundle.module.url(forResource: "reference_board", withExtension: "png")
    )
    return try #require(RGBImage(contentsOf: url))
}

/// A deterministic generator, so a failing case can be reproduced from its seed alone.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(below limit: UInt64) -> UInt64 {
        limit == 0 ? 0 : next() % limit
    }
}
