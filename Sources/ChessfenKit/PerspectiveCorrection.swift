import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// Four corners of a board as it appears in a photograph, in image coordinates with y
/// counting down from the top — the same way `BoardRect` and `Grid` count.
public struct BoardQuad: Hashable, Sendable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public init(
        topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// The axis-aligned quad covering a rectangle.
    public init(rect: CGRect) {
        self.init(
            topLeft: CGPoint(x: rect.minX, y: rect.minY),
            topRight: CGPoint(x: rect.maxX, y: rect.minY),
            bottomRight: CGPoint(x: rect.maxX, y: rect.maxY),
            bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        )
    }

    public var corners: [CGPoint] {
        get { [topLeft, topRight, bottomRight, bottomLeft] }
        set {
            guard newValue.count == 4 else { return }
            topLeft = newValue[0]
            topRight = newValue[1]
            bottomRight = newValue[2]
            bottomLeft = newValue[3]
        }
    }

    /// True when the corners still form a sane, forward-facing quadrilateral. A descent
    /// step that folds a corner past its neighbours has to be rejected, not scored.
    public func isPlausible(in width: Int, height: Int) -> Bool {
        let slack = Double(max(width, height)) * 0.02
        for corner in corners {
            guard corner.x >= -slack, corner.y >= -slack,
                  corner.x <= Double(width) + slack, corner.y <= Double(height) + slack
            else { return false }
        }
        // Convex, and wound the same way all the way round.
        var sign = 0.0
        for index in 0..<4 {
            let a = corners[index]
            let b = corners[(index + 1) % 4]
            let c = corners[(index + 2) % 4]
            let cross =
                (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if sign == 0 {
                sign = cross
            } else if cross * sign < 0 {
                return false
            }
        }
        var shortest = Double.infinity
        for index in 0..<4 {
            let a = corners[index], b = corners[(index + 1) % 4]
            let dx = Double(a.x) - Double(b.x)
            let dy = Double(a.y) - Double(b.y)
            shortest = min(shortest, (dx * dx + dy * dy).squareRoot())
        }
        return shortest >= Double(8 * BoardGeometry.minimumCell)
    }
}

/// Straightens a board photographed from an angle, before the axis-aligned search runs.
///
/// Nothing here decides whether it worked: every candidate is rectified and handed to the
/// *same* checker score the recogniser already uses as its accept gate, and the highest
/// score wins (docs/adr/0007). A judge that the rest of the pipeline does not share would
/// be a second opinion about what a chessboard looks like, and the two would drift.
public enum PerspectiveCorrection {
    /// Quads worth trying, most promising first.
    ///
    /// Vision proposes; it never decides. Its rectangles come from edges, and a board's
    /// strongest edges may be its frame, the table it sits on, or the phone case beside
    /// it — so the content box and the whole frame are always in the list as well, and the
    /// refinement below can walk any of them onto the real board.
    public static func candidates(in image: RGBImage) async -> [BoardQuad] {
        var quads: [BoardQuad] = []
        if let source = image.cgImage {
            let size = CGSize(width: image.width, height: image.height)
            let handler = ImageRequestHandler(source)

            var rectangles = DetectRectanglesRequest()
            // A board is square; perspective can squash that a good way in either
            // direction before the search below stops being able to recover it.
            rectangles.minimumAspectRatio = 0.4
            rectangles.maximumAspectRatio = 1.0
            rectangles.minimumSize = 0.2
            rectangles.quadratureToleranceDegrees = 30
            rectangles.maximumObservations = 8
            if let found = try? await handler.perform(rectangles) {
                for observation in found.sorted(by: { $0.confidence > $1.confidence }) {
                    quads.append(BoardQuad(observation, in: size))
                }
            }

            let document = DetectDocumentSegmentationRequest()
            if let observation = try? await handler.perform(document) {
                quads.append(BoardQuad(observation, in: size))
            }
        }

        if let box = try? BoardGeometry.contentBox(image) {
            quads.append(
                BoardQuad(
                    rect: CGRect(
                        x: box.left, y: box.top,
                        width: box.right - box.left + 1, height: box.bottom - box.top + 1
                    )
                )
            )
        }
        quads.append(
            BoardQuad(rect: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        )
        return quads.filter { $0.isPlausible(in: image.width, height: image.height) }
    }

    /// How cleanly the quad's contents read as a checkerboard, once straightened.
    ///
    /// The whole rectified frame is scored as the board, with no search inside it: that is
    /// what makes this cheap enough to put a coordinate descent on top of, and it is also
    /// what gives the descent something to pull towards — a quad holding a margin scores
    /// worse than one landing on the squares themselves.
    ///
    /// Both of the pipeline's existing measures are used, and neither is new: the Cell-mean
    /// grid score is what the axis-aligned search maximises and is sharp about alignment,
    /// while the corner-patch checker score is the accept gate and is robust to pieces. A
    /// corner can sit forty pixels out with the robust measure barely noticing, so the
    /// sharp one has to be in the objective; the robust one keeps a quad that has slid onto
    /// the tablecloth from winning on texture alone.
    public static func score(
        _ quad: BoardQuad, in image: RGBImage, size: Int = Imaging.scoreSize
    ) -> Double {
        let measured = measure(quad, in: image, size: size)
        return measured.grid * measured.checker
    }

    /// The two measures behind `score`, kept apart for the one caller that needs to ask them
    /// different questions: the product ranks quads against each other, but only the checker
    /// score means anything on its own — it is a contrast ratio, so it does not move with the
    /// size the quad was rectified to, and it is already the pipeline's accept gate.
    static func measure(
        _ quad: BoardQuad, in image: RGBImage, size: Int
    ) -> (grid: Double, checker: Double) {
        guard quad.isPlausible(in: image.width, height: image.height),
              let rectified = rectified(image, quad: quad, size: size)
        else { return (0, 0) }
        let grey = rectified.luma
        let frame = BoardRect(left: 0, top: 0, size: size)
        return (BoardGeometry.gridScore(grey, frame), BoardGeometry.checkerScore(grey, frame))
    }

    /// The board in one camera frame, or nothing — the cheap half of the search.
    ///
    /// The same candidates and the same two measures as the full search, with the coordinate
    /// descent left out: a viewfinder needs an answer many times a second and the descent costs
    /// seconds, while what it buys — corners accurate to a few pixels — is worth nothing to a
    /// box drawn on a moving preview. The photograph that is eventually taken goes through the
    /// full search like any other, so nothing here decides how the board is read; it decides
    /// only what the person sees while aiming.
    ///
    /// Ranked by the product, accepted on the checker score alone, and the gap between a board
    /// and anything else is not close: measured on a rendered board photographed at an angle,
    /// the board's own quad scores in the tens and the frame around it, the half-board and the
    /// tablecloth all score under a quarter.
    public static func located(in image: RGBImage) async -> BoardQuad? {
        var best: (quad: BoardQuad, rank: Double)?
        for quad in await candidates(in: image) {
            let measured = measure(quad, in: image, size: Imaging.viewfinderSize)
            guard measured.checker >= BoardGeometry.minimumCheckerScore else { continue }
            let rank = measured.grid * measured.checker
            if rank > (best?.rank ?? 0) { best = (quad, rank) }
        }
        return best?.quad
    }

    /// Nudges one corner at a time, keeping whatever improves the score, with the step
    /// halving each time a full pass finds nothing.
    ///
    /// A descent, unlike the axis-aligned search, because eight coordinates cannot be
    /// enumerated. Vision's corners are already close, and the score's surface near a
    /// nearly-correct quad is smooth — it is the *far* field, where the search might have
    /// to cross a bad region, that exhaustiveness was needed for, and the candidate list
    /// is what covers that.
    public static func refined(
        _ quad: BoardQuad,
        in image: RGBImage,
        size: Int = Imaging.scoreSize,
        maximumPasses: Int = 40
    ) -> (quad: BoardQuad, score: Double) {
        var best = quad
        var bestScore = score(quad, in: image, size: size)
        var step = Double(max(image.width, image.height)) / 32

        for _ in 0..<maximumPasses {
            var improved = false
            for index in 0..<4 {
                for delta in [
                    CGPoint(x: step, y: 0), CGPoint(x: -step, y: 0),
                    CGPoint(x: 0, y: step), CGPoint(x: 0, y: -step),
                ] {
                    var trial = best
                    var corners = trial.corners
                    corners[index] = CGPoint(
                        x: corners[index].x + delta.x, y: corners[index].y + delta.y
                    )
                    trial.corners = corners
                    let trialScore = score(trial, in: image, size: size)
                    if trialScore > bestScore {
                        bestScore = trialScore
                        best = trial
                        improved = true
                    }
                }
            }
            // Halving only once a whole pass has found nothing means the coarse steps get
            // used up before the fine ones start, which is what lets a corner thirty
            // pixels out still walk home.
            guard !improved else { continue }
            step /= 2
            if step < 1 { break }
        }
        return (best, bestScore)
    }

    /// The quad's contents, straightened into a `size`-by-`size` picture.
    ///
    /// The render is pooled. Core Image's intermediates are autoreleased, and the descent
    /// calls here once per score — one synchronous loop, hundreds of renders, so without
    /// a pool per render those intermediates, megabytes per render, pile up until the
    /// loop ends; on a phone they reached three gigabytes and the system killed the app.
    /// The pool lives here rather than at each caller: this is the one place the render
    /// happens, and the callers used to take turns remembering it.
    public static func rectified(
        _ image: RGBImage, quad: BoardQuad, size: Int = Imaging.rectifiedSize
    ) -> RGBImage? {
        guard let source = image.cgImage else { return nil }
        let height = Double(image.height)
        // Core Image counts y up from the bottom.
        func flipped(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x, y: height - point.y)
        }

        let rendered: CGImage? = autoreleasepool {
            let filter = CIFilter.perspectiveCorrection()
            filter.inputImage = CIImage(cgImage: source)
            filter.topLeft = flipped(quad.topLeft)
            filter.topRight = flipped(quad.topRight)
            filter.bottomRight = flipped(quad.bottomRight)
            filter.bottomLeft = flipped(quad.bottomLeft)
            filter.crop = true
            guard let output = filter.outputImage, !output.extent.isInfinite,
                  output.extent.width >= 1, output.extent.height >= 1
            else { return nil }
            return Imaging.renderContext.createCGImage(output, from: output.extent)
        }
        guard let rendered, let straightened = RGBImage(cgImage: rendered) else { return nil }
        return straightened.resized(width: size, height: size)
    }
}

extension BoardQuad {
    /// A Vision observation's corners, in image coordinates. Vision normalises to the unit
    /// square with y up; everything here counts y down from the top.
    init(_ observation: some QuadrilateralProviding, in size: CGSize) {
        func point(_ normalised: NormalizedPoint) -> CGPoint {
            CGPoint(x: normalised.x * size.width, y: (1 - normalised.y) * size.height)
        }
        self.init(
            topLeft: point(observation.topLeft),
            topRight: point(observation.topRight),
            bottomRight: point(observation.bottomRight),
            bottomLeft: point(observation.bottomLeft)
        )
    }
}
