import ChessfenKit
import CoreGraphics
import Foundation
import ImageIO

/// Draws the app icon.
///
/// The icon is generated rather than drawn by hand, and generated from the same knight the
/// app itself puts on the board: the piece drawings and the board's two colours are already
/// in the package, so the thing on the home screen is made of the thing inside the app. It
/// also means the icon is a file anyone can rebuild instead of a binary nobody can edit.
enum AppIconArt {
    /// The board's own wood, deepened. Light and dark are the renderer's square colours; the
    /// gradient runs between a lift of the light one and a shadow of the dark one, so the
    /// icon reads as the same set of pieces on the same board.
    private static let topLeft = CGColor(red: 0.87, green: 0.63, blue: 0.34, alpha: 1)
    private static let bottomRight = CGColor(red: 0.22, green: 0.12, blue: 0.05, alpha: 1)

    static func image(side: Int) -> CGImage? {
        let size = CGFloat(side)
        guard side > 0,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        // Origin at the top left with y pointing down, which is what the piece drawings use
        // and what everything below is easier to reason about in.
        context.translateBy(x: 0, y: size)
        context.scaleBy(x: 1, y: -1)

        wood(in: context, size: size)
        checkers(in: context, size: size)
        vignette(in: context, size: size)
        glow(in: context, size: size)
        knight(in: context, size: size)

        return context.makeImage()
    }

    // ------------------------------------------------------------------ parts

    private static func wood(in context: CGContext, size: CGFloat) {
        guard
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [topLeft, bottomRight] as CFArray,
                locations: [0, 1]
            )
        else { return }
        // Corner to corner: the light falls across the icon the way it falls across a board
        // on a table, rather than straight down like a button.
        context.drawLinearGradient(
            gradient,
            start: .zero,
            end: CGPoint(x: size, y: size),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    /// Eight ranks and eight files of it, at an opacity that is texture up close and nothing
    /// at all in a home screen grid — which is the right amount of detail for both.
    private static func checkers(in context: CGContext, size: CGFloat) {
        let cell = size / 8
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.045))
        for row in 0..<8 {
            for column in 0..<8 where !(row + column).isMultiple(of: 2) {
                context.fill(
                    CGRect(
                        x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                        width: cell, height: cell
                    )
                )
            }
        }
    }

    /// Darkens the corners. Without it the checkers run to the edge and the icon reads as a
    /// pattern; with it they fall away and the piece is what the eye lands on.
    private static func vignette(in context: CGContext, size: CGFloat) {
        guard
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [
                    CGColor(red: 0.08, green: 0.04, blue: 0.01, alpha: 0),
                    CGColor(red: 0.08, green: 0.04, blue: 0.01, alpha: 0.42),
                ] as CFArray,
                locations: [0.45, 1]
            )
        else { return }
        let centre = CGPoint(x: size * 0.5, y: size * 0.5)
        context.drawRadialGradient(
            gradient,
            startCenter: centre, startRadius: 0,
            endCenter: centre, endRadius: size * 0.78,
            options: [.drawsAfterEndLocation]
        )
    }

    /// A soft light behind the piece, so a white knight has something to stand out of.
    private static func glow(in context: CGContext, size: CGFloat) {
        guard
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [
                    CGColor(red: 1, green: 0.93, blue: 0.82, alpha: 0.26),
                    CGColor(red: 1, green: 0.93, blue: 0.82, alpha: 0),
                ] as CFArray,
                locations: [0, 1]
            )
        else { return }
        let centre = CGPoint(x: size * 0.5, y: size * 0.46)
        context.drawRadialGradient(
            gradient,
            startCenter: centre, startRadius: 0,
            endCenter: centre, endRadius: size * 0.44,
            options: []
        )
    }

    private static func knight(in context: CGContext, size: CGFloat) {
        guard let document = SVGDocument(glyph: "N") else { return }

        // Fitted by its own outline rather than by the 45-unit square it was drawn in. A piece
        // does not fill that square evenly — it is drawn to stand on a rank, with room above
        // it — so scaling the square leaves the knight sitting low and off to one side.
        var bounds = CGRect.null
        for shape in document.shapes {
            let inset = shape.strokeWidth / 2
            bounds = bounds.union(shape.path.boundingBox.insetBy(dx: -inset, dy: -inset))
        }
        guard bounds.width > 0, bounds.height > 0 else { return }

        let scale = size * 0.60 / max(bounds.width, bounds.height)
        let transform = CGAffineTransform(
            translationX: size / 2 - bounds.midX * scale,
            y: size / 2 - bounds.midY * scale
        ).scaledBy(x: scale, y: scale)

        // One shadow under the whole piece rather than one under each of its shapes: a
        // transparency layer composites the knight first and shades the result, so the
        // drawing's inner lines do not each cast their own.
        context.setShadow(
            offset: CGSize(width: 0, height: -size * 0.022),
            blur: size * 0.05,
            color: CGColor(red: 0.12, green: 0.06, blue: 0.02, alpha: 0.45)
        )
        context.beginTransparencyLayer(auxiliaryInfo: nil)

        for shape in document.shapes {
            let path = shape.path.copy(using: [transform]) ?? shape.path
            if let fill = shape.fill.cgColor {
                context.addPath(path)
                context.setFillColor(fill)
                context.fillPath(using: shape.usesEvenOddFill ? .evenOdd : .winding)
            }
            if let stroke = shape.stroke.cgColor, shape.strokeWidth > 0 {
                context.addPath(path)
                context.setStrokeColor(stroke)
                context.setLineWidth(shape.strokeWidth * scale)
                context.setLineCap(shape.lineCap)
                context.setLineJoin(shape.lineJoin)
                context.strokePath()
            }
        }

        context.endTransparencyLayer()
    }

    // ----------------------------------------------------------------- output

    @discardableResult
    static func write(to url: URL, side: Int) -> Bool {
        guard let image = image(side: side),
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil
            )
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}

extension CGPath {
    /// `applying` for a CGPath, which only has the mutable-copy spelling.
    fileprivate func copy(using transforms: [CGAffineTransform]) -> CGPath? {
        var transform = transforms.reduce(CGAffineTransform.identity) { $0.concatenating($1) }
        return copy(using: &transform)
    }
}
