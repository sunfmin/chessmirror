import ChessfenKit
import CoreGraphics
import Testing

@Test("all twelve drawings parse into shapes that paint something")
func everyPieceDrawingParses() throws {
    for glyph in "PNBRQKpnbrqk" {
        let document = try #require(SVGDocument(glyph: glyph), "\(glyph)")
        #expect(!document.shapes.isEmpty, "\(glyph)")
        let mask = try #require(document.silhouette(size: 64), "\(glyph)")
        // A piece fills a good part of its square, but never all of it.
        #expect(mask.coverage > 0.2 && mask.coverage < 0.8, "\(glyph) covered \(mask.coverage)")
    }
}

@Test("a template matches itself and nothing else better")
func templatesAreDistinguishable() throws {
    for colour in [PieceColour.white, .black] {
        let shapes = PieceTemplates.shapes(for: colour)
        #expect(shapes.count == 6)
        for (kind, template) in shapes {
            let scored = shapes.map {
                (kind: $0.kind, score: Morphology.intersectionOverUnion(template, $0.mask))
            }
            let best = try #require(scored.max { $0.score < $1.score })
            #expect(best.kind == kind)
            #expect(best.score == 1)
        }
    }
}

@Test("presentation attributes are inherited from the enclosing groups")
func groupAttributesAreInherited() throws {
    let document = SVGDocument(
        parsing: """
            <g fill="#fff" stroke="#000" stroke-width="1.5" stroke-linecap="round">
              <path d="M0 0 L10 0"/>
              <g stroke-linecap="butt" fill="none">
                <path d="M0 0 L10 0" stroke-width="3"/>
              </g>
            </g>
            """
    )
    #expect(document.shapes.count == 2)
    let outer = document.shapes[0]
    #expect(outer.fill == SVGPaint("#fff"))
    #expect(outer.stroke == SVGPaint("#000"))
    #expect(outer.strokeWidth == 1.5)
    #expect(outer.lineCap == .round)

    let inner = document.shapes[1]
    #expect(inner.fill == SVGPaint.none)
    #expect(inner.stroke == SVGPaint("#000"))  // still inherited
    #expect(inner.strokeWidth == 3)
    #expect(inner.lineCap == .butt)
}

@Test("a style attribute is read the same way as the attributes it shadows")
func styleAttributeIsHonoured() throws {
    let document = SVGDocument(
        parsing: ##"<path d="M0 0 L1 1" fill="#000" style="fill:#ffffff; stroke:#123456"/>"##
    )
    #expect(document.shapes.count == 1)
    #expect(document.shapes[0].fill == SVGPaint("#ffffff"))
    #expect(document.shapes[0].stroke == SVGPaint("#123456"))
}

@Test("fill-rule evenodd survives into the shape")
func fillRuleIsCarried() {
    let evenOdd = SVGDocument(parsing: #"<path d="M0 0 L1 1" fill-rule="evenodd"/>"#)
    let winding = SVGDocument(parsing: #"<path d="M0 0 L1 1"/>"#)
    #expect(evenOdd.shapes.first?.usesEvenOddFill == true)
    #expect(winding.shapes.first?.usesEvenOddFill == false)
}

@Test("colours come in every notation the drawings use")
func coloursParse() {
    #expect(SVGPaint("#fff") == .colour(red: 1, green: 1, blue: 1, alpha: 1))
    #expect(SVGPaint("#ffffff") == .colour(red: 1, green: 1, blue: 1, alpha: 1))
    #expect(SVGPaint("none") == SVGPaint.none)
    #expect(SVGPaint("#000") == .colour(red: 0, green: 0, blue: 0, alpha: 1))
    #expect(SVGPaint("#ff000000")?.cgColor?.alpha == 0)
    #expect(SVGPaint("rebeccapurple") == nil)
    #expect(SVGPaint("") == nil)
}

@Test("SVG's optional separators do not swallow numbers")
func numbersScanWithoutSeparators() {
    #expect(SVGNumbers.all(in: "10-5.5") == [10, -5.5])
    #expect(SVGNumbers.all(in: ".5.5") == [0.5, 0.5])
    #expect(SVGNumbers.all(in: "1 2,3  -4") == [1, 2, 3, -4])
    #expect(SVGNumbers.all(in: "1e-3 2E2") == [0.001, 200])
    #expect(SVGNumbers.all(in: "") == [])
}

@Test("relative and absolute path commands describe the same shape")
func relativeAndAbsolutePathsAgree() throws {
    let absolute = try #require(SVGPathBuilder.path(from: "M 10 10 L 20 10 L 20 20 Z"))
    let relative = try #require(SVGPathBuilder.path(from: "m10 10l10 0l0 10z"))
    #expect(absolute.boundingBox == relative.boundingBox)
    #expect(absolute.boundingBox == CGRect(x: 10, y: 10, width: 10, height: 10))
}

@Test("a coordinate pair after a moveto continues as a lineto")
func repeatedMovetoPairsAreLines() throws {
    let implicit = try #require(SVGPathBuilder.path(from: "M0 0 10 0 10 10"))
    #expect(implicit.boundingBox == CGRect(x: 0, y: 0, width: 10, height: 10))
}

@Test("shorthand and vertical commands land where they should")
func shorthandCommandsWork() throws {
    let horizontal = try #require(SVGPathBuilder.path(from: "M0 0 H20 V10 h-5 v-5"))
    #expect(horizontal.boundingBox == CGRect(x: 0, y: 0, width: 20, height: 10))

    // `s` reflects the previous cubic's second control point, which keeps the curve
    // smooth — a shape that would bulge the wrong way if the reflection were dropped.
    let smooth = try #require(SVGPathBuilder.path(from: "M0 0 c0 10 10 10 10 0 s10 -10 10 0"))
    #expect(smooth.boundingBox.width == 20)
    #expect(smooth.boundingBox.minY < 0)
}

@Test("an arc becomes a curve of about the right size")
func arcsAreApproximated() throws {
    // The knight's eye: a half turn each way makes a circle of radius 0.5.
    let circle = try #require(
        SVGPathBuilder.path(from: "M 9.5 25.5 A 0.5 0.5 0 1 1 8.5,25.5 A 0.5 0.5 0 1 1 9.5 25.5 z")
    )
    let box = circle.boundingBox
    #expect(abs(box.width - 1) < 0.05, "width \(box.width)")
    #expect(abs(box.height - 1) < 0.05, "height \(box.height)")
    #expect(abs(box.midX - 9) < 0.01)
    #expect(abs(box.midY - 25.5) < 0.01)
}

@Test("a transform moves the geometry, not just the paint")
func transformsApplyToTheGeometry() throws {
    let document = SVGDocument(
        parsing: #"<path d="M0 0 L10 0 L10 10 Z" transform="matrix(1,0,0,1,5,7)"/>"#
    )
    let shape = try #require(document.shapes.first)
    #expect(shape.path.boundingBox == CGRect(x: 5, y: 7, width: 10, height: 10))
}

@Test("a circle element is geometry too")
func circleElementsAreShapes() throws {
    let document = SVGDocument(parsing: ##"<circle cx="10" cy="20" r="4" fill="#fff"/>"##)
    let shape = try #require(document.shapes.first)
    #expect(shape.path.boundingBox == CGRect(x: 6, y: 16, width: 8, height: 8))
    #expect(shape.fill == SVGPaint("#fff"))
}

@Test("markup this parser is not meant to understand is ignored, not guessed at")
func unknownMarkupIsIgnored() {
    let document = SVGDocument(
        parsing: """
            <?xml version="1.0"?>
            <svg viewBox="0 0 45 45"><defs><linearGradient id="g"/></defs>
            <text x="1" y="2">a</text><path d="M0 0 L1 1"/></svg>
            """
    )
    #expect(document.shapes.count == 1)
}
