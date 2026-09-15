import ChessfenKit
import Testing

/// The end-to-end case that matters: a real screenshot, not something we rendered.
///
/// Different piece artwork, coordinate labels drawn *inside* the board, a highlighted
/// square with a frame around it, and a rounded, padded board edge.

private let expectedPlacement = "r3k3/2N5/8/8/8/8/8/8"

@Test("the reference screenshot gives the right FEN")
func referenceScreenshotIsRead() throws {
    let result = try Recognizer.recognise(
        referenceScreenshot(), turn: .black, castling: .none
    )
    #expect(result.fen == "\(expectedPlacement) b - - 0 1")
}

@Test("castling rights are inferred from the home squares")
func castlingIsInferredFromHomeSquares() throws {
    // The black king and the a8 rook are untouched, so queenside stays available.
    let result = try Recognizer.recognise(
        referenceScreenshot(), castling: .fromHomeSquares
    )
    #expect(result.fen == "\(expectedPlacement) w q - 0 1")
}

@Test("every square of the reference is matched confidently")
func referenceHasNoShakySquares() throws {
    let result = try Recognizer.recognise(referenceScreenshot())
    #expect(result.shaky.map(\.square.description) == [])
}

@Test("the board is found despite the padding around it")
func referenceBoardIsFoundThroughPadding() throws {
    let result = try Recognizer.recognise(referenceScreenshot())
    let cell = Double(result.rect.size) / 8
    #expect(cell > 90 && cell < 105, "~98 px squares in this screenshot, got \(cell)")
}

@Test("a picture with no board in it is rejected rather than guessed at")
func aPictureWithNoBoardIsRejected() throws {
    var pixels = [UInt8](repeating: 200, count: 300 * 300 * 3)
    for y in 100..<200 {
        for x in 100..<200 {
            let base = (y * 300 + x) * 3
            pixels[base] = 40
            pixels[base + 1] = 40
            pixels[base + 2] = 40
        }
    }
    let noise = RGBImage(width: 300, height: 300, pixels: pixels)
    #expect(throws: RecognitionError.boardNotFound) {
        try Recognizer.recognise(noise)
    }
}

@Test("an image too small to hold a board says so")
func aTinyImageIsRejected() throws {
    let tiny = RGBImage(width: 40, height: 40, pixels: [UInt8](repeating: 128, count: 40 * 40 * 3))
    #expect(throws: RecognitionError.imageTooSmall(width: 40, height: 40)) {
        try Recognizer.recognise(tiny)
    }
}
