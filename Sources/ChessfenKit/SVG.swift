import CoreGraphics
import Foundation

/// A painted shape: geometry plus the handful of presentation attributes the piece
/// drawings actually use.
///
/// Unchecked because `CGPath` is not `Sendable`, though the paths here are built once
/// during parsing and never mutated afterwards.
public struct SVGShape: @unchecked Sendable {
    public var path: CGPath
    public var fill: SVGPaint
    public var stroke: SVGPaint
    public var strokeWidth: Double
    public var lineCap: CGLineCap
    public var lineJoin: CGLineJoin
    public var usesEvenOddFill: Bool
}

public enum SVGPaint: Equatable, Sendable {
    case none
    case colour(red: Double, green: Double, blue: Double, alpha: Double)

    /// `#rgb`, `#rrggbb`, `#rrggbbaa`, or `none`. Named colours are not supported,
    /// because the piece drawings do not use any.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "none" || trimmed == "transparent" {
            self = .none
            return
        }
        guard trimmed.hasPrefix("#") else { return nil }
        let digits = Array(trimmed.dropFirst())
        func value(_ characters: [Character]) -> Double? {
            guard let raw = UInt8(String(characters), radix: 16) else { return nil }
            return Double(raw) / 255
        }
        switch digits.count {
        case 3, 4:
            let doubled = digits.map { [$0, $0] }
            guard let red = value(doubled[0]), let green = value(doubled[1]),
                  let blue = value(doubled[2])
            else { return nil }
            let alpha = digits.count == 4 ? value(doubled[3]) ?? 1 : 1
            self = .colour(red: red, green: green, blue: blue, alpha: alpha)
        case 6, 8:
            let pairs = stride(from: 0, to: digits.count, by: 2).map {
                Array(digits[$0..<($0 + 2)])
            }
            guard let red = value(pairs[0]), let green = value(pairs[1]),
                  let blue = value(pairs[2])
            else { return nil }
            let alpha = pairs.count == 4 ? value(pairs[3]) ?? 1 : 1
            self = .colour(red: red, green: green, blue: blue, alpha: alpha)
        default:
            return nil
        }
    }

    public var cgColor: CGColor? {
        guard case .colour(let red, let green, let blue, let alpha) = self else { return nil }
        return CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [red, green, blue, alpha]
        )
    }
}

/// A parsed piece drawing: a flat list of shapes in the order they are painted.
///
/// This is deliberately not an SVG engine. It understands exactly what the twelve
/// drawings in `PiecePaths` use — nested `<g>` with inherited presentation attributes,
/// `<path>`, `<circle>`, a `matrix()` transform, and the path commands those `d`
/// strings contain. Anything else is ignored rather than guessed at.
public struct SVGDocument: @unchecked Sendable {
    public let shapes: [SVGShape]

    public init(parsing text: String) {
        var parser = Parser(text)
        shapes = parser.run()
    }

    /// The drawing for one piece, by FEN glyph.
    public init?(glyph: Character) {
        guard let text = PiecePaths.svg[glyph] else { return nil }
        self.init(parsing: text)
    }
}

// ------------------------------------------------------------------- rendering

extension SVGDocument {
    /// Everything the drawing paints, as a mask, in a `size`-by-`size` box.
    ///
    /// "Paints" includes strokes: an outline is as much part of what the eye sees as a
    /// fill, and the pieces would be unrecognisable without it (the knight is almost
    /// entirely outline). Matching the Python original, a pixel counts as covered once
    /// its coverage passes `tolerance` out of 255 — the drawing goes on white over a
    /// black page, so the pixel value *is* the coverage.
    public func silhouette(
        size: Int,
        unitSize: Double = PiecePaths.unitSize,
        tolerance: UInt8 = 96
    ) -> Mask? {
        var page = [UInt8](repeating: 0, count: size * size)
        let context = page.withUnsafeMutableBytes { bytes in
            CGContext(
                data: bytes.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }
        guard let context else { return nil }
        draw(in: context, scale: Double(size) / unitSize, silhouetteOnly: true)

        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let rowBytes = context.bytesPerRow
        var mask = Mask(width: size, height: size, repeating: false)
        for y in 0..<size {
            for x in 0..<size {
                mask[x, y] = bytes[y * rowBytes + x] > tolerance
            }
        }
        return mask
    }

    /// Paints the drawing into `context`, whose origin is the drawing's top left.
    ///
    /// `silhouetteOnly` paints every shape in flat white, which is what the matcher
    /// wants; otherwise the authored colours are used, which is what the player wants.
    public func draw(in context: CGContext, scale: Double, silhouetteOnly: Bool = false) {
        context.saveGState()
        // SVG's y axis points down, Core Graphics' points up.
        context.translateBy(x: 0, y: CGFloat(Double(context.height)))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))

        for shape in shapes {
            if silhouetteOnly {
                context.setFillColor(gray: 1, alpha: 1)
                context.setStrokeColor(gray: 1, alpha: 1)
            }
            context.setLineWidth(CGFloat(shape.strokeWidth))
            context.setLineCap(shape.lineCap)
            context.setLineJoin(shape.lineJoin)

            let fills = silhouetteOnly ? shape.fill != .none : shape.fill.cgColor != nil
            if fills {
                if !silhouetteOnly, let colour = shape.fill.cgColor {
                    context.setFillColor(colour)
                }
                context.addPath(shape.path)
                context.fillPath(using: shape.usesEvenOddFill ? .evenOdd : .winding)
            }
            let strokes = silhouetteOnly ? shape.stroke != .none : shape.stroke.cgColor != nil
            if strokes, shape.strokeWidth > 0 {
                if !silhouetteOnly, let colour = shape.stroke.cgColor {
                    context.setStrokeColor(colour)
                }
                context.addPath(shape.path)
                context.strokePath()
            }
        }
        context.restoreGState()
    }
}

// --------------------------------------------------------------------- parsing

/// Presentation attributes, all optional so that a group can leave them to its parent.
private struct SVGStyle {
    var fill: SVGPaint?
    var stroke: SVGPaint?
    var strokeWidth: Double?
    var lineCap: CGLineCap?
    var lineJoin: CGLineJoin?
    var evenOdd: Bool?
    var transform: CGAffineTransform = .identity

    /// `child` wins wherever it says anything; transforms compose.
    func inherited(by child: SVGStyle) -> SVGStyle {
        var out = self
        out.fill = child.fill ?? fill
        out.stroke = child.stroke ?? stroke
        out.strokeWidth = child.strokeWidth ?? strokeWidth
        out.lineCap = child.lineCap ?? lineCap
        out.lineJoin = child.lineJoin ?? lineJoin
        out.evenOdd = child.evenOdd ?? evenOdd
        out.transform = child.transform.concatenating(transform)
        return out
    }

    init() {}

    init(attributes: [String: String]) {
        // `style` is applied first so that a presentation attribute can be overridden by
        // it, which is the CSS cascade the drawings were authored against.
        var merged = attributes
        if let style = attributes["style"] {
            for declaration in style.split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                merged[parts[0].trimmingCharacters(in: .whitespaces)] =
                    parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        fill = merged["fill"].flatMap(SVGPaint.init)
        stroke = merged["stroke"].flatMap(SVGPaint.init)
        strokeWidth = merged["stroke-width"].flatMap(Double.init)
        switch merged["stroke-linecap"] {
        case "round": lineCap = .round
        case "square": lineCap = .square
        case "butt": lineCap = .butt
        default: lineCap = nil
        }
        switch merged["stroke-linejoin"] {
        case "round": lineJoin = .round
        case "bevel": lineJoin = .bevel
        case "miter": lineJoin = .miter
        default: lineJoin = nil
        }
        switch merged["fill-rule"] {
        case "evenodd": evenOdd = true
        case "nonzero": evenOdd = false
        default: evenOdd = nil
        }
        if let text = merged["transform"] { transform = Self.matrix(text) }
    }

    /// Only `matrix(a,b,c,d,e,f)`, which is the only transform the drawings use.
    private static func matrix(_ text: String) -> CGAffineTransform {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"),
              text[..<open].trimmingCharacters(in: .whitespaces) == "matrix"
        else { return .identity }
        let numbers = SVGNumbers.all(in: String(text[text.index(after: open)..<close]))
        guard numbers.count == 6 else { return .identity }
        return CGAffineTransform(
            a: numbers[0], b: numbers[1], c: numbers[2],
            d: numbers[3], tx: numbers[4], ty: numbers[5]
        )
    }
}

/// A tag-and-attribute scanner. XML in general needs a real parser; these twelve strings
/// are well-formed markup with no entities, comments, CDATA or namespaces in them.
private struct Parser {
    private let characters: [Character]
    private var index = 0
    private var stack: [SVGStyle] = [SVGStyle()]

    init(_ text: String) { characters = Array(text) }

    mutating func run() -> [SVGShape] {
        var shapes: [SVGShape] = []
        while let position = characters[index...].firstIndex(of: "<") {
            index = position + 1
            if peek() == "/" {
                advance()
                let name = readName()
                if name == "g", stack.count > 1 { stack.removeLast() }
                skipPastTagEnd()
                continue
            }
            if peek() == "?" || peek() == "!" {
                skipPastTagEnd()
                continue
            }
            let name = readName()
            let attributes = readAttributes()
            let selfClosing = characters[max(0, index - 2)] == "/"
            let style = (stack.last ?? SVGStyle()).inherited(by: SVGStyle(attributes: attributes))

            switch name {
            case "g", "svg":
                if !selfClosing { stack.append(style) }
            case "path":
                if let text = attributes["d"], let path = SVGPathBuilder.path(from: text) {
                    shapes.append(Self.shape(path, style))
                }
            case "circle":
                let cx = attributes["cx"].flatMap(Double.init) ?? 0
                let cy = attributes["cy"].flatMap(Double.init) ?? 0
                let radius = attributes["r"].flatMap(Double.init) ?? 0
                guard radius > 0 else { break }
                let box = CGRect(
                    x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2
                )
                shapes.append(Self.shape(CGPath(ellipseIn: box, transform: nil), style))
            default:
                break
            }
        }
        return shapes
    }

    private static func shape(_ path: CGPath, _ style: SVGStyle) -> SVGShape {
        var transform = style.transform
        let transformed =
            transform.isIdentity ? path : (path.copy(using: &transform) ?? path)
        return SVGShape(
            path: transformed,
            // SVG's initial fill is black; its initial stroke is none.
            fill: style.fill ?? .colour(red: 0, green: 0, blue: 0, alpha: 1),
            stroke: style.stroke ?? .none,
            strokeWidth: style.strokeWidth ?? 1,
            lineCap: style.lineCap ?? .butt,
            lineJoin: style.lineJoin ?? .miter,
            usesEvenOddFill: style.evenOdd ?? false
        )
    }

    private func peek() -> Character? {
        index < characters.count ? characters[index] : nil
    }

    private mutating func advance() { index += 1 }

    private mutating func readName() -> String {
        var name = ""
        while let character = peek(), character.isLetter || character.isNumber
            || character == "-" || character == ":"
        {
            name.append(character)
            advance()
        }
        return name
    }

    private mutating func readAttributes() -> [String: String] {
        var attributes: [String: String] = [:]
        while let character = peek() {
            if character == ">" {
                advance()
                return attributes
            }
            if character.isWhitespace || character == "/" {
                advance()
                continue
            }
            let name = readName()
            guard !name.isEmpty else {
                advance()
                continue
            }
            while let character = peek(), character.isWhitespace { advance() }
            guard peek() == "=" else {
                attributes[name] = ""
                continue
            }
            advance()
            while let character = peek(), character.isWhitespace { advance() }
            guard let quote = peek(), quote == "\"" || quote == "'" else { continue }
            advance()
            var value = ""
            while let character = peek(), character != quote {
                value.append(character)
                advance()
            }
            advance()
            attributes[name] = value
        }
        return attributes
    }

    private mutating func skipPastTagEnd() {
        while let character = peek() {
            advance()
            if character == ">" { return }
        }
    }
}

/// SVG's number lists, where separators are optional: `10-5.5` is two numbers, `.5.5`
/// is two more, and `1e-3` is one.
public enum SVGNumbers {
    public static func all(in text: String) -> [Double] {
        var scanner = Scanner(text)
        var numbers: [Double] = []
        while let number = scanner.next() { numbers.append(number) }
        return numbers
    }

    public struct Scanner {
        private let characters: [Character]
        private var index = 0

        init(_ text: String) { characters = Array(text) }

        var atEnd: Bool {
            var probe = self
            probe.skipSeparators()
            return probe.index >= probe.characters.count
        }

        /// The next command letter, without consuming it.
        mutating func peekCommand() -> Character? {
            skipSeparators()
            guard index < characters.count else { return nil }
            let character = characters[index]
            return character.isLetter && character != "e" && character != "E"
                ? character : nil
        }

        mutating func takeCommand() -> Character? {
            guard let command = peekCommand() else { return nil }
            index += 1
            return command
        }

        mutating func next() -> Double? {
            skipSeparators()
            var text = ""
            if let character = peekCharacter(), character == "+" || character == "-" {
                text.append(character)
                index += 1
            }
            var sawDigit = false
            while let character = peekCharacter(), character.isNumber {
                text.append(character)
                index += 1
                sawDigit = true
            }
            if peekCharacter() == "." {
                text.append(".")
                index += 1
                while let character = peekCharacter(), character.isNumber {
                    text.append(character)
                    index += 1
                    sawDigit = true
                }
            }
            guard sawDigit else { return nil }
            if let character = peekCharacter(), character == "e" || character == "E" {
                var exponent = String(character)
                var probe = index + 1
                if probe < characters.count,
                   characters[probe] == "+" || characters[probe] == "-"
                {
                    exponent.append(characters[probe])
                    probe += 1
                }
                var sawExponentDigit = false
                while probe < characters.count, characters[probe].isNumber {
                    exponent.append(characters[probe])
                    probe += 1
                    sawExponentDigit = true
                }
                if sawExponentDigit {
                    text += exponent
                    index = probe
                }
            }
            return Double(text)
        }

        /// A flag is a single `0` or `1`, with no separator needed after it.
        mutating func nextFlag() -> Bool? {
            skipSeparators()
            guard let character = peekCharacter(), character == "0" || character == "1"
            else { return nil }
            index += 1
            return character == "1"
        }

        private func peekCharacter() -> Character? {
            index < characters.count ? characters[index] : nil
        }

        private mutating func skipSeparators() {
            while let character = peekCharacter(),
                  character.isWhitespace || character == ","
            {
                index += 1
            }
        }
    }
}

/// Turns a `d` string into a `CGPath`.
public enum SVGPathBuilder {
    public static func path(from text: String) -> CGPath? {
        var scanner = SVGNumbers.Scanner(text)
        let path = CGMutablePath()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        /// The reflection point for `S`/`s` and `T`/`t`, when the previous command was a
        /// curve of the matching kind.
        var lastCubicControl: CGPoint?
        var lastQuadraticControl: CGPoint?
        var command: Character?

        while !scanner.atEnd {
            if let next = scanner.takeCommand() { command = next }
            guard let active = command else { return path.isEmpty ? nil : path }
            let relative = active.isLowercase
            let base = relative ? current : .zero

            func point() -> CGPoint? {
                guard let x = scanner.next(), let y = scanner.next() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }

            switch active.lowercased().first! {
            case "m":
                guard let target = point() else { return path.isEmpty ? nil : path }
                path.move(to: target)
                current = target
                subpathStart = target
                // A repeated coordinate pair after a moveto is a lineto.
                command = relative ? "l" : "L"
                lastCubicControl = nil
                lastQuadraticControl = nil
            case "l":
                guard let target = point() else { return path.isEmpty ? nil : path }
                path.addLine(to: target)
                current = target
                lastCubicControl = nil
                lastQuadraticControl = nil
            case "h":
                guard let x = scanner.next() else { return path.isEmpty ? nil : path }
                current = CGPoint(x: base.x + x, y: current.y)
                path.addLine(to: current)
                lastCubicControl = nil
                lastQuadraticControl = nil
            case "v":
                guard let y = scanner.next() else { return path.isEmpty ? nil : path }
                current = CGPoint(x: current.x, y: base.y + y)
                path.addLine(to: current)
                lastCubicControl = nil
                lastQuadraticControl = nil
            case "c":
                guard let first = point(), let second = point(), let target = point()
                else { return path.isEmpty ? nil : path }
                path.addCurve(to: target, control1: first, control2: second)
                current = target
                lastCubicControl = second
                lastQuadraticControl = nil
            case "s":
                guard let second = point(), let target = point()
                else { return path.isEmpty ? nil : path }
                let first = reflect(lastCubicControl, about: current)
                path.addCurve(to: target, control1: first, control2: second)
                current = target
                lastCubicControl = second
                lastQuadraticControl = nil
            case "q":
                guard let control = point(), let target = point()
                else { return path.isEmpty ? nil : path }
                path.addQuadCurve(to: target, control: control)
                current = target
                lastQuadraticControl = control
                lastCubicControl = nil
            case "t":
                guard let target = point() else { return path.isEmpty ? nil : path }
                let control = reflect(lastQuadraticControl, about: current)
                path.addQuadCurve(to: target, control: control)
                current = target
                lastQuadraticControl = control
                lastCubicControl = nil
            case "a":
                guard let radiusX = scanner.next(), let radiusY = scanner.next(),
                      let rotation = scanner.next(), let largeArc = scanner.nextFlag(),
                      let sweep = scanner.nextFlag(), let target = point()
                else { return path.isEmpty ? nil : path }
                appendArc(
                    to: path, from: current, to: target,
                    radiusX: radiusX, radiusY: radiusY, rotation: rotation,
                    largeArc: largeArc, sweep: sweep
                )
                current = target
                lastCubicControl = nil
                lastQuadraticControl = nil
            case "z":
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil
                lastQuadraticControl = nil
            default:
                return path.isEmpty ? nil : path
            }
        }
        return path.isEmpty ? nil : path
    }

    private static func reflect(_ control: CGPoint?, about current: CGPoint) -> CGPoint {
        guard let control else { return current }
        return CGPoint(x: 2 * current.x - control.x, y: 2 * current.y - control.y)
    }

    /// SVG's endpoint arc, converted to centre form and emitted as cubic segments
    /// (appendix F.6 of the SVG 1.1 specification).
    private static func appendArc(
        to path: CGMutablePath,
        from start: CGPoint,
        to end: CGPoint,
        radiusX: Double,
        radiusY: Double,
        rotation degrees: Double,
        largeArc: Bool,
        sweep: Bool
    ) {
        var rx = abs(radiusX)
        var ry = abs(radiusY)
        guard rx > 0, ry > 0 else {
            path.addLine(to: end)
            return
        }
        if start == end { return }

        let phi = degrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (Double(start.x) - Double(end.x)) / 2
        let dy = (Double(start.y) - Double(end.y)) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        // Radii too small to span the chord get scaled up until they just reach.
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            let scale = lambda.squareRoot()
            rx *= scale
            ry *= scale
        }

        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1)
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coefficient = denominator > 0 ? (numerator / denominator).squareRoot() : 0
        if largeArc == sweep { coefficient = -coefficient }
        let cx1 = coefficient * rx * y1 / ry
        let cy1 = -coefficient * ry * x1 / rx
        let centreX = cosPhi * cx1 - sinPhi * cy1 + (Double(start.x) + Double(end.x)) / 2
        let centreY = sinPhi * cx1 + cosPhi * cy1 + (Double(start.y) + Double(end.y)) / 2

        func angle(_ x: Double, _ y: Double) -> Double { atan2(y, x) }
        let startAngle = angle((x1 - cx1) / rx, (y1 - cy1) / ry)
        var sweepAngle =
            angle((-x1 - cx1) / rx, (-y1 - cy1) / ry) - startAngle
        if !sweep, sweepAngle > 0 { sweepAngle -= 2 * .pi }
        if sweep, sweepAngle < 0 { sweepAngle += 2 * .pi }

        // A cubic approximates a circular arc well up to a quarter turn.
        let segments = max(1, Int(ceil(abs(sweepAngle) / (.pi / 2))))
        let step = sweepAngle / Double(segments)
        let alpha = 4.0 / 3.0 * tan(step / 4)
        var theta = startAngle
        for _ in 0..<segments {
            let next = theta + step
            func onArc(_ angle: Double) -> CGPoint {
                let ex = rx * cos(angle), ey = ry * sin(angle)
                return CGPoint(
                    x: centreX + cosPhi * ex - sinPhi * ey,
                    y: centreY + sinPhi * ex + cosPhi * ey
                )
            }
            func tangent(_ angle: Double) -> CGPoint {
                let ex = -rx * sin(angle), ey = ry * cos(angle)
                return CGPoint(
                    x: cosPhi * ex - sinPhi * ey,
                    y: sinPhi * ex + cosPhi * ey
                )
            }
            let from = onArc(theta), to = onArc(next)
            let fromTangent = tangent(theta), toTangent = tangent(next)
            path.addCurve(
                to: to,
                control1: CGPoint(
                    x: from.x + CGFloat(alpha) * fromTangent.x,
                    y: from.y + CGFloat(alpha) * fromTangent.y
                ),
                control2: CGPoint(
                    x: to.x - CGFloat(alpha) * toTangent.x,
                    y: to.y - CGFloat(alpha) * toTangent.y
                )
            )
            theta = next
        }
    }
}
