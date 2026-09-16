import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// The palette a board is painted in. Defaults are python-chess's, so a board rendered
/// here looks like the boards the recogniser was tuned against.
public struct BoardStyle: Sendable {
    public var lightSquare: String
    public var darkSquare: String
    public var lightLastMove: String
    public var darkLastMove: String
    public var margin: String
    public var coordinate: String
    public var innerBorder: String

    public init(
        lightSquare: String = "#ffce9e",
        darkSquare: String = "#d18b47",
        lightLastMove: String = "#cdd16a",
        darkLastMove: String = "#aaa23b",
        margin: String = "#212121",
        coordinate: String = "#e5e5e5",
        innerBorder: String = "#111"
    ) {
        self.lightSquare = lightSquare
        self.darkSquare = darkSquare
        self.lightLastMove = lightLastMove
        self.darkLastMove = darkLastMove
        self.margin = margin
        self.coordinate = coordinate
        self.innerBorder = innerBorder
    }

    public static let `default` = BoardStyle()
}

/// A marked square.
public struct BoardHighlight: Hashable, Sendable {
    public enum Style: Hashable, Sendable {
        /// A solid tint, as used for the last move or a selected square.
        case flat
        /// A radial halo, as used for a king in check.
        case halo
    }

    public let square: Square
    public let style: Style

    public init(square: Square, style: Style = .flat) {
        self.square = square
        self.style = style
    }
}

/// FEN in, board picture out.
///
/// The inverse of `Recognizer`, and its test rig: render a Position, recognise it back,
/// demand the same FEN. Both sides read their shapes from `PiecePaths`, so what the
/// matcher scores against is what a player would have been looking at.
public enum BoardRenderer {
    /// Side of one square in the drawings' own coordinate space.
    static let squareUnits = PiecePaths.unitSize
    /// Coordinate margin, in the same space.
    static let marginUnits = 20.0

    public struct Options: Sendable {
        public var size: Int
        public var coordinates: Bool
        public var orientation: Orientation
        public var style: BoardStyle
        public var highlights: [BoardHighlight]

        public init(
            size: Int = 480,
            coordinates: Bool = false,
            orientation: Orientation = .whiteAtBottom,
            style: BoardStyle = .default,
            highlights: [BoardHighlight] = []
        ) {
            self.size = size
            self.coordinates = coordinates
            self.orientation = orientation
            self.style = style
            self.highlights = highlights
        }
    }

    /// Renders the placement part of `fen`. Returns nil only if the FEN's placement field
    /// cannot be read at all.
    public static func image(fen: String, options: Options = Options()) -> RGBImage? {
        guard let pieces = placement(fen) else { return nil }

        let margin = options.coordinates ? marginUnits : 0
        let units = 8 * squareUnits + 2 * margin
        let scale = Double(options.size) / units
        let side = options.size

        var rgba = [UInt8](repeating: 255, count: side * side * 4)
        let context = rgba.withUnsafeMutableBytes { bytes in
            CGContext(
                data: bytes.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        }
        guard let context else { return nil }

        // Work in SVG's coordinates: origin top left, y downwards.
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))

        if margin > 0, let colour = SVGPaint(options.style.margin)?.cgColor {
            context.setFillColor(colour)
            context.fill(CGRect(x: 0, y: 0, width: units, height: units))
        }
        context.saveGState()
        context.translateBy(x: CGFloat(margin), y: CGFloat(margin))

        for row in 0..<8 {
            for column in 0..<8 {
                let square = Recognizer.square(
                    row: row, column: column, orientation: options.orientation
                )
                let isLight = (row + column).isMultiple(of: 2)
                let flat = options.highlights.contains {
                    $0.square == square && $0.style == .flat
                }
                let name =
                    switch (isLight, flat) {
                    case (true, false): options.style.lightSquare
                    case (false, false): options.style.darkSquare
                    case (true, true): options.style.lightLastMove
                    case (false, true): options.style.darkLastMove
                    }
                let box = CGRect(
                    x: Double(column) * squareUnits, y: Double(row) * squareUnits,
                    width: squareUnits, height: squareUnits
                )
                if let colour = SVGPaint(name)?.cgColor {
                    context.setFillColor(colour)
                    context.fill(box)
                }
                if options.highlights.contains(where: {
                    $0.square == square && $0.style == .halo
                }) {
                    drawHalo(in: context, box: box)
                }
                if let piece = pieces[square] {
                    draw(piece: piece, in: context, box: box, scale: scale)
                }
            }
        }
        context.restoreGState()

        if margin > 0 {
            drawBorder(in: context, margin: margin, units: units, style: options.style)
            drawCoordinates(
                in: context, margin: margin, units: units,
                orientation: options.orientation, style: options.style
            )
        }

        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: side * side * 3)
        for index in 0..<(side * side) {
            out[index * 3] = bytes[index * 4]
            out[index * 3 + 1] = bytes[index * 4 + 1]
            out[index * 3 + 2] = bytes[index * 4 + 2]
        }
        return RGBImage(width: side, height: side, pixels: out)
    }

    /// PNG bytes of the position, for callers that want to share or store the picture.
    public static func png(fen: String, options: Options = Options()) -> Data? {
        guard let image = image(fen: fen, options: options)?.cgImage else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, "public.png" as CFString, 1, nil
            )
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The board part of a FEN, as pieces by square. Only the first field is read: the
    /// rest of a FEN says nothing about what is drawn.
    public static func placement(_ fen: String) -> [Square: Piece]? {
        guard let field = fen.split(separator: " ").first else { return nil }
        var pieces: [Square: Piece] = [:]
        let ranks = field.split(separator: "/", omittingEmptySubsequences: false)
        guard ranks.count == 8 else { return nil }
        for (offset, line) in ranks.enumerated() {
            let rank = 7 - offset
            var file = 0
            for character in line {
                if let skip = character.wholeNumberValue, (1...8).contains(skip) {
                    file += skip
                } else if let piece = Piece(glyph: character) {
                    guard file < 8 else { return nil }
                    pieces[Square(file: file, rank: rank)] = piece
                    file += 1
                } else {
                    return nil
                }
            }
            guard file == 8 else { return nil }
        }
        return pieces
    }

    private static func draw(
        piece: Piece, in context: CGContext, box: CGRect, scale: Double
    ) {
        guard let document = SVGDocument(glyph: piece.glyph) else { return }
        context.saveGState()
        // The context is already in SVG's own coordinates, so the drawing only needs
        // moving to its square — flipping it again would stand the piece on its head.
        context.translateBy(x: box.minX, y: box.minY)
        for shape in document.shapes {
            context.setLineWidth(CGFloat(shape.strokeWidth))
            context.setLineCap(shape.lineCap)
            context.setLineJoin(shape.lineJoin)
            if let colour = shape.fill.cgColor {
                context.setFillColor(colour)
                context.addPath(shape.path)
                context.fillPath(using: shape.usesEvenOddFill ? .evenOdd : .winding)
            }
            if let colour = shape.stroke.cgColor, shape.strokeWidth > 0 {
                context.setStrokeColor(colour)
                context.addPath(shape.path)
                context.strokePath()
            }
        }
        context.restoreGState()
    }

    /// The radial check halo, which is the one overlay that breaks the flat-background
    /// assumption the square reader makes — deliberately reproduced so that the reader's
    /// admission of doubt can be tested.
    private static func drawHalo(in context: CGContext, box: CGRect) {
        let stops: [CGFloat] = [0, 0.5, 1]
        let components: [CGFloat] = [
            1, 0, 0, 1,
            0xE7 / 255, 0, 0, 1,
            0x9E / 255, 0, 0, 0,
        ]
        guard
            let gradient = CGGradient(
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                colorComponents: components,
                locations: stops,
                count: stops.count
            )
        else { return }
        context.saveGState()
        context.clip(to: box)
        context.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: box.midX, y: box.midY), startRadius: 0,
            endCenter: CGPoint(x: box.midX, y: box.midY),
            endRadius: CGFloat(squareUnits) / 2,
            options: []
        )
        context.restoreGState()
    }

    private static func drawBorder(
        in context: CGContext, margin: Double, units: Double, style: BoardStyle
    ) {
        guard let colour = SVGPaint(style.innerBorder)?.cgColor else { return }
        context.setStrokeColor(colour)
        context.setLineWidth(1)
        context.stroke(
            CGRect(
                x: margin - 0.5, y: margin - 0.5,
                width: units - 2 * margin + 1, height: units - 2 * margin + 1
            )
        )
    }

    private static func drawCoordinates(
        in context: CGContext,
        margin: Double,
        units: Double,
        orientation: Orientation,
        style: BoardStyle
    ) {
        guard let colour = SVGPaint(style.coordinate)?.cgColor else { return }
        let font = CTFontCreateWithName("Helvetica" as CFString, CGFloat(margin * 0.6), nil)
        let files = orientation == .whiteAtBottom ? "abcdefgh" : "hgfedcba"
        let ranks = orientation == .whiteAtBottom ? "87654321" : "12345678"

        for (index, character) in files.enumerated() {
            let centre = margin + (Double(index) + 0.5) * squareUnits
            drawText(
                String(character), in: context, font: font, colour: colour,
                centredAt: CGPoint(x: centre, y: units - margin / 2)
            )
        }
        for (index, character) in ranks.enumerated() {
            let centre = margin + (Double(index) + 0.5) * squareUnits
            drawText(
                String(character), in: context, font: font, colour: colour,
                centredAt: CGPoint(x: margin / 2, y: centre)
            )
        }
    }

    private static func drawText(
        _ text: String,
        in context: CGContext,
        font: CTFont,
        colour: CGColor,
        centredAt centre: CGPoint
    ) {
        // Core Text's own attribute names, so this file needs neither AppKit nor UIKit.
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
        context.saveGState()
        // Text draws in its own upright space, so the board's y-flip is undone locally.
        context.translateBy(x: centre.x, y: centre.y)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(
            x: -bounds.width / 2 - bounds.minX, y: -bounds.height / 2 - bounds.minY
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
