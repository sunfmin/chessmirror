import ChessfenKit
import CoreGraphics
import Foundation
import ImageIO
import Testing

/// Which of the two preparations a picture is given, and the fact that the pixels are what
/// decide it (docs/adr/0033).

/// A photograph of a real board on a table, and a photograph of a printed book diagram —
/// the two hardest cases on the photograph side, because the second is flat, square on and
/// blown out to paper white, which is most of what a screenshot looks like.
private func fixture(_ name: String) throws -> RGBImage {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "png"))
    return try #require(RGBImage(contentsOf: url))
}

/// Re-encodes as JPEG, which is what a screenshot sent through a chat app comes back as.
private func recompressed(_ image: RGBImage, quality: Double) throws -> RGBImage {
    let source = try #require(image.cgImage)
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(
            data as CFMutableData, "public.jpeg" as CFString, 1, nil
        )
    )
    CGImageDestinationAddImage(
        destination, source,
        [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
    )
    #expect(CGImageDestinationFinalize(destination))
    return try #require(RGBImage(data: data as Data))
}

@Test("a real lichess screenshot is read as one")
func theReferenceScreenshotKnowsItIsDrawn() throws {
    let result = try Recognizer.recognise(referenceScreenshot(), castling: .none)
    #expect(result.provenance == .screenshot)
}

@Test("a screenshot still reads right after a chat app has recompressed it")
func aRecompressedScreenshotIsStillDrawn() throws {
    let squashed = try recompressed(referenceScreenshot(), quality: 0.30)
    let result = try Recognizer.recognise(squashed, castling: .none)
    #expect(result.provenance == .screenshot, "JPEG blur does not make a photograph of it")
    #expect(result.fen == "r3k3/2N5/8/8/8/8/8/8 w - - 0 1")
    #expect(result.shaky.isEmpty, "and no orange rings on a picture nothing was unsure of")
}

@Test(
    "a photographed board is read as a photograph, printed diagrams included",
    arguments: ["board_photograph", "killer_photograph"]
)
func aPhotographKnowsItWasLit(name: String) throws {
    let result = try Recognizer.recognise(fixture(name), castling: .none)
    #expect(result.provenance == .photograph)
}

@Test("a board a computer drew is drawn, whatever position is on it")
func renderedBoardsAreDrawn() throws {
    for seed in UInt64(1)...6 {
        let fen = playout(seed: seed, plies: 24)
        let image = try #require(BoardRenderer.image(fen: fen, options: BoardRenderer.Options()))
        let result = try Recognizer.recognise(image, castling: .none)
        #expect(result.provenance == .screenshot, "seed \(seed)")
    }
}

@Test("a screenshot's light is one level, and a photograph's follows the lamp")
func onlyAPhotographFollowsTheLight() throws {
    let drawn = try Recognizer.recognise(referenceScreenshot(), castling: .none)
    #expect(drawn.lighting.spread == 0, "one value for the whole board, not sixty-four")

    let photographed = try Recognizer.recognise(fixture("board_photograph"), castling: .none)
    #expect(photographed.lighting.spread > 0.02, "the table's lamp is in the numbers")
}

@Test("the flat light really is skipped work, not the same work reaching the same answer")
func aFlatLightIsNotTheLocalMedian() {
    // A board lit from one side: the light squares run from 120 at the left to 240 at the
    // right. Following it gives each Cell its own level; not following it gives them all the
    // brightest, which is the answer a drawn board wants and the wrong one here.
    var backgrounds = Grid<Double>(width: 8, height: 8, repeating: 0)
    for row in 0..<8 {
        for column in 0..<8 {
            backgrounds[column, row] = 120 + Double(column) * 120 / 7
        }
    }
    #expect(BoardLighting(backgrounds: backgrounds).spread > 0.3)
    #expect(BoardLighting(backgrounds: backgrounds, followingTheLight: false).spread == 0)
}

@Test("a screenshot never pays for the search over quads")
func aScreenshotIsNotRectified() async throws {
    // Through the photograph door, which is the one that can rectify. What comes back is
    // the axis-aligned reading itself — same FEN, same score — rather than a warped one.
    let straight = try Recognizer.recognise(referenceScreenshot(), castling: .none)
    let throughTheDoor = try await Recognizer.recognise(
        photograph: referenceScreenshot(), castling: .none
    )
    #expect(throughTheDoor.provenance == .screenshot)
    #expect(throughTheDoor.fen == straight.fen)
    #expect(throughTheDoor.checkerScore == straight.checkerScore, "not resampled on the way")
}
