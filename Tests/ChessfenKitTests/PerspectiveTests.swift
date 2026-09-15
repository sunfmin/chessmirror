import ChessfenKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Testing

/// A board photographed from an angle is a projection of the board plus whatever the table
/// contributes. These tests build that on purpose: warp a rendered board onto a page, then
/// ask for the FEN back.

/// Paints `image` onto a `width`-by-`height` page, projected onto `quad`.
private func photographed(
    _ image: RGBImage,
    onto quad: BoardQuad,
    width: Int,
    height: Int,
    page: (Double, Double, Double) = (150, 148, 143)
) throws -> RGBImage {
    let source = try #require(image.cgImage)
    let pageHeight = Double(height)
    func flipped(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: pageHeight - point.y) }

    let transform = CIFilter.perspectiveTransform()
    transform.inputImage = CIImage(cgImage: source)
    transform.topLeft = flipped(quad.topLeft)
    transform.topRight = flipped(quad.topRight)
    transform.bottomRight = flipped(quad.bottomRight)
    transform.bottomLeft = flipped(quad.bottomLeft)
    let warped = try #require(transform.outputImage)

    let background = CIImage(
        color: CIColor(red: page.0 / 255, green: page.1 / 255, blue: page.2 / 255)
    )
    .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    let composed = warped.composited(over: background)
        .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

    let context = CIContext()
    let rendered = try #require(
        context.createCGImage(composed, from: CGRect(x: 0, y: 0, width: width, height: height))
    )
    return try #require(RGBImage(cgImage: rendered))
}

@Test("a board photographed from an angle is straightened and read")
func aSkewedBoardIsRectified() async throws {
    let fen = "r3k3/2N5/8/8/8/8/8/4K3 w - - 0 1"
    let board = try #require(BoardRenderer.image(fen: fen, options: .init(size: 640)))
    // Looking down at the board from above and to the left: the far edge is shorter and
    // the whole thing leans.
    let quad = BoardQuad(
        topLeft: CGPoint(x: 210, y: 120),
        topRight: CGPoint(x: 690, y: 175),
        bottomRight: CGPoint(x: 745, y: 690),
        bottomLeft: CGPoint(x: 130, y: 640)
    )
    let photo = try photographed(board, onto: quad, width: 900, height: 820)

    let result = try await Recognizer.recognise(
        photograph: photo, orientation: .whiteAtBottom, castling: .none
    )
    #expect(result.fen == fen)
}

@Test("a straight screenshot is read without being warped")
func aStraightPictureIsLeftAlone() async throws {
    let screenshot = try referenceScreenshot()
    let through = try await Recognizer.recognise(
        photograph: screenshot, turn: .black, castling: .none
    )
    let direct = try Recognizer.recognise(screenshot, turn: .black, castling: .none)
    #expect(through.fen == direct.fen)
    #expect(through.rect == direct.rect)
    #expect(through.image.width == direct.image.width)
    #expect(through.checkerScore >= Recognizer.alreadyStraightScore)
}

@Test("the quad refinement walks a loose rectangle onto the board")
func refinementFindsTheBoardEdges() throws {
    let fen = PGN.standardStartFEN
    let board = try #require(BoardRenderer.image(fen: fen, options: .init(size: 480)))
    let quad = BoardQuad(
        topLeft: CGPoint(x: 100, y: 60),
        topRight: CGPoint(x: 580, y: 110),
        bottomRight: CGPoint(x: 620, y: 570),
        bottomLeft: CGPoint(x: 70, y: 540)
    )
    let photo = try photographed(board, onto: quad, width: 700, height: 660)

    // Deliberately loose: every corner is thirty pixels out.
    var loose = quad
    loose.corners = [
        CGPoint(x: 70, y: 30), CGPoint(x: 610, y: 80),
        CGPoint(x: 650, y: 600), CGPoint(x: 40, y: 570),
    ]
    let before = PerspectiveCorrection.score(loose, in: photo)
    let after = PerspectiveCorrection.refined(loose, in: photo)
    #expect(after.score > before)

    // The claim is about the corners: the descent's job is to find the board's edges, and
    // whether the pieces on it then read is the rest of the pipeline's business.
    for (found, truth) in zip(after.quad.corners, quad.corners) {
        let distance = (
            (found.x - truth.x) * (found.x - truth.x)
            + (found.y - truth.y) * (found.y - truth.y)
        ).squareRoot()
        #expect(distance < 8, "corner \(found) should be near \(truth)")
    }
}

/// A picture that has already been through a document scanner — Notes, or any of the scanning
/// apps, and then 从相册选 — is not a photograph. It is the board already straightened, cropped
/// to the very edge of the scanner's guess at the quad, and stretched to the aspect ratio it
/// inferred for that quad. Both are unusual here: every other way in gives a board with
/// something around it. And the aspect is an estimate, so a board scanned from a low angle
/// comes back a few percent off square, which over eight ranks is a fraction of a square by the
/// far edge.
///
/// Which of the two stages absorbs that is the thing worth pinning down, because it decides
/// what a bad estimate costs: a small error goes through the axis-aligned reading untouched,
/// and one big enough to break that reading is recovered by the quad stage rectifying the whole
/// frame back to square. So there is no aspect ratio at which the scanner's guess strands the
/// recogniser — only one where it stops being free.
@Test("a scan cropped to the board's edge and out of square is still read")
func aScannedBoardIsRead() async throws {
    let fen = "r3k3/2N5/8/8/8/8/8/4K3 w - - 0 1"
    let board = try #require(BoardRenderer.image(fen: fen, options: .init(size: 320)))

    // Three percent out, which is about as wrong as the scanner's estimate gets.
    let slight = try await Recognizer.recognise(
        photograph: board.resized(width: 310, height: 320),
        orientation: .whiteAtBottom, castling: .none
    )
    #expect(slight.fen == fen)
    #expect(slight.image.width != slight.image.height, "read as it arrived, not rectified")

    // Far past that, and past where the axis-aligned reading gives up: the grid it would lay
    // down drifts most of a square by the eighth rank.
    let stretched = try await Recognizer.recognise(
        photograph: board.resized(width: 310, height: 360),
        orientation: .whiteAtBottom, castling: .none
    )
    #expect(stretched.fen == fen)
    #expect(stretched.image.width == stretched.image.height, "squared up by the quad stage")
}

/// The viewfinder's job is not to be right about the corners — the photograph goes through the
/// full search afterwards — it is to be right about *whether there is a board*, many times a
/// second, so that the box drawn on the preview means something.
@Test("the viewfinder finds a board in a frame, and finds nothing in a frame without one")
func theViewfinderLocatesABoard() async throws {
    let board = try #require(
        BoardRenderer.image(fen: PGN.standardStartFEN, options: .init(size: 480))
    )
    let quad = BoardQuad(
        topLeft: CGPoint(x: 100, y: 60),
        topRight: CGPoint(x: 580, y: 110),
        bottomRight: CGPoint(x: 620, y: 570),
        bottomLeft: CGPoint(x: 70, y: 540)
    )
    let frame = try photographed(board, onto: quad, width: 700, height: 660)
        .scaled(toLongestSide: 384)
    let scale = 384.0 / 700

    let found = try #require(await PerspectiveCorrection.located(in: frame))
    // Loosely: these corners have had no descent run on them, and a box on a moving preview
    // does not need better than "that is the board and not the table".
    for (corner, truth) in zip(found.corners, quad.corners) {
        let distance = (
            (corner.x - truth.x * scale) * (corner.x - truth.x * scale)
            + (corner.y - truth.y * scale) * (corner.y - truth.y * scale)
        ).squareRoot()
        #expect(distance < 30, "corner \(corner) should be near \(truth.applying(.init(scaleX: scale, y: scale)))")
    }

    // A dark slab on a light table: rectangular, and not a board.
    var pixels = [UInt8](repeating: 190, count: 384 * 384 * 3)
    for y in 90..<300 {
        for x in 70..<310 {
            let base = (y * 384 + x) * 3
            pixels[base] = 60
            pixels[base + 1] = 70
            pixels[base + 2] = 90
        }
    }
    let table = RGBImage(width: 384, height: 384, pixels: pixels)
    #expect(await PerspectiveCorrection.located(in: table) == nil)
}

@Test("a quad that has folded over itself is refused rather than scored")
func implausibleQuadsAreRefused() {
    let inside = BoardQuad(rect: CGRect(x: 10, y: 10, width: 200, height: 200))
    #expect(inside.isPlausible(in: 300, height: 300))

    // Corners swapped left for right, so the quad crosses itself.
    var crossed = inside
    crossed.corners = [
        CGPoint(x: 210, y: 10), CGPoint(x: 10, y: 10),
        CGPoint(x: 210, y: 210), CGPoint(x: 10, y: 210),
    ]
    #expect(!crossed.isPlausible(in: 300, height: 300))

    // Too small to hold eight squares.
    let tiny = BoardQuad(rect: CGRect(x: 0, y: 0, width: 40, height: 40))
    #expect(!tiny.isPlausible(in: 300, height: 300))

    // Well outside the picture.
    let escaped = BoardQuad(rect: CGRect(x: -400, y: 0, width: 200, height: 200))
    #expect(!escaped.isPlausible(in: 300, height: 300))
}

@Test("a photograph with no board in it is still rejected")
func aPhotographWithNoBoardIsRejected() async throws {
    var pixels = [UInt8](repeating: 190, count: 400 * 400 * 3)
    for y in 150..<250 {
        for x in 120..<300 {
            let base = (y * 400 + x) * 3
            pixels[base] = 60
            pixels[base + 1] = 70
            pixels[base + 2] = 90
        }
    }
    let noise = RGBImage(width: 400, height: 400, pixels: pixels)
    await #expect(throws: RecognitionError.boardNotFound) {
        try await Recognizer.recognise(photograph: noise)
    }
}
