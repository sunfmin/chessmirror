import ChessfenKit
import CoreGraphics
import Foundation
import ImageIO
import Testing

/// Screenshots in the wild are recompressed, rescaled and pasted onto pages.

private let expected = "r3k3/2N5/8/8/8/8/8/8 w - - 0 1"

/// Re-encodes as JPEG at `quality` and decodes what comes back — the artefacts are the
/// point, so the round trip through the codec has to be real.
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

private func rescaled(_ image: RGBImage, by scale: Double) -> RGBImage {
    image.scaled(toLongestSide: Int((Double(max(image.width, image.height)) * scale).rounded()))
}

@Test("JPEG artefacts are tolerated", arguments: [0.85, 0.55, 0.30])
func jpegArtefactsAreTolerated(quality: Double) throws {
    let image = try recompressed(referenceScreenshot(), quality: quality)
    let result = try Recognizer.recognise(image, castling: .none)
    #expect(result.fen == expected)
}

@Test("small renderings are tolerated", arguments: [0.5, 0.35])
func smallRenderingsAreTolerated(scale: Double) throws {
    let image = rescaled(try referenceScreenshot(), by: scale)
    let result = try Recognizer.recognise(image, castling: .none)
    #expect(result.fen == expected)
}

@Test("below about thirty pixel squares it says so rather than inventing pieces")
func tinySquaresAreAdmitted() throws {
    // Shape matching against another piece set needs roughly 35 px squares. Past that the
    // answer degrades, and the point of the confidence numbers is to admit it.
    let image = rescaled(try referenceScreenshot(), by: 0.25)
    let result = try Recognizer.recognise(image, castling: .none)
    #expect(result.fen != expected)
    #expect(!result.shaky.isEmpty)
}

/// Multiplies brightness by a ramp across the picture, left to right — which is what a
/// lamp to one side of a page, or a window behind a screen, does to the pixels. Squares and
/// pieces darken together, so nothing about the board changes except how much light fell on
/// it.
private func shaded(_ image: RGBImage, from: Double, to: Double) -> RGBImage {
    var pixels = image.pixels
    for y in 0..<image.height {
        for x in 0..<image.width {
            let factor = from + (to - from) * Double(x) / Double(max(1, image.width - 1))
            let base = (y * image.width + x) * 3
            for channel in 0..<3 {
                pixels[base + channel] = UInt8((Double(pixels[base + channel]) * factor).rounded())
            }
        }
    }
    return RGBImage(width: image.width, height: image.height, pixels: pixels)
}

@Test("a board lit from one side is read at the dark end too")
func unevenLightingIsRead() throws {
    // The position, and the ramp, of a photograph of a book page taken under a lamp: the
    // paper reads 230 at the lit edge and 110 at the other, and the white king and rook at
    // the dark end came back black. Anything absolute cuts a board like this in half —
    // 0.45 × 255 is 115, below any fixed line drawn between white pieces and black ones.
    let fen = "r4rk1/pp3ppp/8/2p2p2/4Pq2/NP1Pn2P/PBP1Q3/R5KR w - - 0 1"
    var style = BoardStyle()
    style.lightSquare = "#ffffff"
    style.darkSquare = "#808080"
    let board = try #require(
        BoardRenderer.image(fen: fen, options: BoardRenderer.Options(size: 640, style: style))
    )
    let result = try Recognizer.recognise(shaded(board, from: 1, to: 0.45), castling: .none)
    #expect(result.fen == fen)
    #expect(result.shaky.map(\.square.description) == [])
}

@Test("a board pasted off centre onto a page is still found")
func boardPastedOntoAPageIsFound() throws {
    let screenshot = try referenceScreenshot()
    var pixels = [UInt8](repeating: 0, count: 1100 * 950 * 3)
    for index in 0..<(1100 * 950) {
        pixels[index * 3] = 245
        pixels[index * 3 + 1] = 245
        pixels[index * 3 + 2] = 247
    }
    for y in 0..<screenshot.height {
        for x in 0..<screenshot.width {
            let (red, green, blue) = screenshot.channels(x, y)
            let base = ((y + 120) * 1100 + x + 60) * 3
            pixels[base] = UInt8(red)
            pixels[base + 1] = UInt8(green)
            pixels[base + 2] = UInt8(blue)
        }
    }
    let page = RGBImage(width: 1100, height: 950, pixels: pixels)

    let result = try Recognizer.recognise(page, castling: .none)
    #expect(result.fen == expected)
    // The screenshot carries ~15 px of its own padding, which the search sees through.
    #expect(abs(result.rect.left - 75) <= 4, "left was \(result.rect.left)")
    #expect(abs(result.rect.top - 129) <= 4, "top was \(result.rect.top)")
}

/// Paints `patch` onto `page` with its top left corner at `x`, `y`, clipped to the page.
private func paste(_ patch: RGBImage, onto page: inout [UInt8], width: Int, height: Int, x: Int, y: Int) {
    for row in 0..<patch.height where y + row >= 0 && y + row < height {
        for column in 0..<patch.width where x + column >= 0 && x + column < width {
            let (red, green, blue) = patch.channels(column, row)
            let base = ((y + row) * width + x + column) * 3
            page[base] = UInt8(red)
            page[base + 1] = UInt8(green)
            page[base + 2] = UInt8(blue)
        }
    }
}

@Test("a diagram on a page of other diagrams and text is found")
func aDiagramAmongOthersIsFound() throws {
    // The page from the puzzle book that started this: the diagram to read sits in the middle,
    // the one above it is cut off by the top of the frame, and there is print all round. The
    // board is about half the page across.
    //
    // What makes it hard is not the neighbours themselves but what they do to the content box:
    // print in the corners of the page makes that box the whole page, and the window search
    // only ever tries boards between three quarters and one-and-a-bit times the box. A board
    // half the page across is not in that window, so before the whole-frame sweep existed this
    // page came back as "no board in this picture" with the board sitting sharp in the middle
    // of it.
    let fen = "r2q2k1/p1p2rpp/3b1p2/2nQ4/4p1PN/PPB1P2P/5P2/R4RK1 w - - 0 1"
    // The page as the recogniser will hold it — a photograph is scaled to 1200 on its longest
    // side before anything looks at it, so building it at that size keeps the coordinates
    // asserted below the same ones the search works in.
    let width = 900, height = 1200
    var pixels = [UInt8](repeating: 246, count: width * height * 3)

    let board = try #require(BoardRenderer.image(fen: fen, options: .init(size: 464)))
    paste(board, onto: &pixels, width: width, height: height, x: 240, y: 300)

    // The diagram above, with all but its last rank off the top of the frame.
    let neighbour = try #require(
        BoardRenderer.image(fen: PGN.standardStartFEN, options: .init(size: 464))
    )
    paste(neighbour, onto: &pixels, width: width, height: height, x: 240, y: -405)

    // Print: headings, answer lines, and the marks down both margins. This is the part that
    // matters — it is what stretches the content box to the edges of the page.
    func ink(x: Range<Int>, y: Range<Int>) {
        for row in y {
            for column in x {
                let base = (row * width + column) * 3
                pixels[base] = 40
                pixels[base + 1] = 40
                pixels[base + 2] = 40
            }
        }
    }
    for band in [(90, 30), (840, 22), (900, 18), (1035, 18), (1125, 30)] {
        ink(x: 225..<675, y: band.0..<(band.0 + band.1))
    }
    for margin in [37, 832] {
        ink(x: margin..<(margin + 30), y: 420..<615)
    }

    let page = RGBImage(width: width, height: height, pixels: pixels)
    let result = try Recognizer.recognise(page, castling: .none)
    #expect(result.fen == fen)
    #expect(abs(result.rect.left - 240) <= 4, "left was \(result.rect.left)")
    #expect(abs(result.rect.top - 300) <= 4, "top was \(result.rect.top)")
    #expect(abs(result.rect.size - 464) <= 6, "size was \(result.rect.size)")
}
