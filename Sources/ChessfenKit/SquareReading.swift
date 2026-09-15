/// Separates "what is drawn on this square" from "what colour the square is".
///
/// Three ideas carry this stage:
///
/// * The background is the square's *modal* colour, not its border or its median. A
///   square is the largest flat-coloured region in the Cell, so the mode survives a piece
///   covering more than half the square and survives a highlight frame drawn inside the
///   square edge.
/// * The piece is the connected blob that covers the *centre* of the square. Highlight
///   frames, borders and rank/file labels all live at the edges, and no shape heuristic
///   is needed to reject them — they simply are not in the middle.
/// * Holes get filled, so a piece whose fill matches its square (white on white) still
///   yields a Silhouette rather than a ring.
public struct SquareReading: Sendable {
    /// The square's own colour, as an RGB triple.
    public let background: (red: Double, green: Double, blue: Double)
    public let ink: Mask
    /// Median brightness of the piece body with its outline eroded away, else nil.
    public let bodyLuma: Double?

    /// The square's own colour as one brightness — what a piece body standing on it, and
    /// the squares around it, are measured against.
    public var backgroundLuma: Double {
        0.299 * background.red + 0.587 * background.green + 0.114 * background.blue
    }

    public var coverage: Double { ink.coverage }
    public var occupied: Bool { coverage >= SquareReader.minimumInkFraction }
}

public enum SquareReader {
    /// Channel distances from the background that count as Ink, tried in order.
    /// Escalating rescues squares whose background is not flat at all (gradients, JPEG
    /// mush).
    static let inkTolerances = [32.0, 48.0, 64.0, 80.0]
    /// Coverage above which the background estimate is deemed to have failed.
    static let implausibleCoverage = 0.55
    /// Blobs smaller than this fraction of the square are noise.
    static let minimumBlobFraction = 0.01
    /// The piece must own at least this fraction of the centred box below.
    static let minimumCentreFraction = 0.05
    /// Hairline gaps up to this fraction of the square are bridged when grouping Ink.
    static let bridgeFraction = 0.025
    /// The centred box, as an inset fraction on each side.
    static let centreInset = 0.3
    /// Below this total Ink fraction the square is called empty.
    static let minimumInkFraction = 0.04
    /// Bits dropped per channel when histogramming for the modal colour.
    static let quantiseBits = 3

    /// Estimates the square colour and extracts the piece Silhouette, if any.
    public static func read(_ cell: RGBImage) -> SquareReading {
        let background = modalColour(cell)
        var distance = LumaImage(width: cell.width, height: cell.height, repeating: 0)
        for y in 0..<cell.height {
            for x in 0..<cell.width {
                let (red, green, blue) = cell.channels(x, y)
                distance[x, y] = max(
                    abs(red - background.red), abs(green - background.green),
                    abs(blue - background.blue)
                )
            }
        }

        var ink = Mask(width: cell.width, height: cell.height, repeating: false)
        for tolerance in inkTolerances {
            ink = selectPiece(distance.map { $0 > tolerance })
            if ink.coverage <= implausibleCoverage { break }
        }
        return SquareReading(
            background: background, ink: ink, bodyLuma: bodyLuma(cell, ink)
        )
    }

    /// The most common colour in the Cell, refined to the median of the pixels around it.
    ///
    /// The histogram is scored two bins at a time on each axis rather than one. A bin edge
    /// must not be allowed to decide the answer: `#c0805e`, a perfectly ordinary square
    /// colour, has its red channel sitting exactly on a boundary, so the faintest JPEG
    /// noise splits that one flat colour into two half-sized bins and hands the square to
    /// the piece standing on it — whereupon the piece becomes the background, the
    /// background becomes the Ink, and a knight is read as a rook. Scoring a 2×2×2 block
    /// puts the split back together.
    public static func modalColour(
        _ cell: RGBImage
    ) -> (red: Double, green: Double, blue: Double) {
        guard cell.width > 0, cell.height > 0 else { return (0, 0, 0) }
        let levels = 1 << (8 - quantiseBits)
        var counts = [Int](repeating: 0, count: levels * levels * levels)
        var keys = [Int](repeating: 0, count: cell.width * cell.height)
        var occupied: [Int] = []
        for y in 0..<cell.height {
            for x in 0..<cell.width {
                let key =
                    (Int(cell.red(x, y)) >> quantiseBits) * levels * levels
                    + (Int(cell.green(x, y)) >> quantiseBits) * levels
                    + (Int(cell.blue(x, y)) >> quantiseBits)
                keys[y * cell.width + x] = key
                if counts[key] == 0 { occupied.append(key) }
                counts[key] += 1
            }
        }

        var bestTotal = -1
        var winner = (red: 0, green: 0, blue: 0)
        for key in occupied {
            let corner = (
                red: key / (levels * levels),
                green: (key / levels) % levels,
                blue: key % levels
            )
            var total = 0
            for redOffset in 0...1 {
                for greenOffset in 0...1 {
                    for blueOffset in 0...1 {
                        let red = corner.red + redOffset
                        let green = corner.green + greenOffset
                        let blue = corner.blue + blueOffset
                        guard red < levels, green < levels, blue < levels else { continue }
                        total += counts[(red * levels + green) * levels + blue]
                    }
                }
            }
            if total > bestTotal {
                bestTotal = total
                winner = corner
            }
        }

        var reds: [Double] = [], greens: [Double] = [], blues: [Double] = []
        reds.reserveCapacity(bestTotal)
        greens.reserveCapacity(bestTotal)
        blues.reserveCapacity(bestTotal)
        for y in 0..<cell.height {
            for x in 0..<cell.width {
                let key = keys[y * cell.width + x]
                let red = key / (levels * levels)
                let green = (key / levels) % levels
                let blue = key % levels
                guard (winner.red...winner.red + 1).contains(red),
                      (winner.green...winner.green + 1).contains(green),
                      (winner.blue...winner.blue + 1).contains(blue)
                else { continue }
                let (sampleRed, sampleGreen, sampleBlue) = cell.channels(x, y)
                reds.append(sampleRed)
                greens.append(sampleGreen)
                blues.append(sampleBlue)
            }
        }
        return (
            LumaImage.median(reds), LumaImage.median(greens), LumaImage.median(blues)
        )
    }

    /// Keeps the Ink belonging to the object that covers the centre of the square.
    ///
    /// Connectivity is decided on a *closed* copy of the mask: a piece's internal detail
    /// lines pass through the background colour where they are anti-aliased against the
    /// fill, which cuts a one-pixel gap through the Silhouette and would otherwise leave
    /// the matcher looking at a rook's shaft with no crenellations. The gap is bridged for
    /// the purpose of grouping, then the original Ink is kept for the shape itself.
    static func selectPiece(_ ink: Mask) -> Mask {
        let empty = Mask(width: ink.width, height: ink.height, repeating: false)
        guard !ink.isEmpty else { return empty }

        var centre = empty
        let y0 = BoardGeometry.rounded(Double(ink.height) * centreInset)
        let y1 = BoardGeometry.rounded(Double(ink.height) * (1 - centreInset))
        let x0 = BoardGeometry.rounded(Double(ink.width) * centreInset)
        let x1 = BoardGeometry.rounded(Double(ink.width) * (1 - centreInset))
        for y in y0..<max(y0, y1) {
            for x in x0..<max(x0, x1) { centre[x, y] = true }
        }
        let centreArea = max(1, centre.count)

        let bridged = Morphology.close(
            ink,
            radius: max(1, BoardGeometry.rounded(Double(min(ink.height, ink.width)) * bridgeFraction))
        )
        let blobs = Morphology.components(
            bridged,
            minimumArea: max(
                4, BoardGeometry.rounded(Double(ink.height * ink.width) * minimumBlobFraction)
            )
        )
        guard let body = blobs.max(by: { $0.overlap(centre) < $1.overlap(centre) }) else {
            return empty
        }
        guard Double(body.overlap(centre)) / Double(centreArea) >= minimumCentreFraction else {
            return empty
        }
        return Morphology.fillHoles(ink.intersection(body))
    }

    /// Brightness of the piece body, with the dark outline stripped off.
    ///
    /// Eroding is what makes this piece-set independent: whether the outline is black on
    /// a white piece or white on a black piece, the body wins once the outline is gone.
    static func bodyLuma(_ cell: RGBImage, _ ink: Mask) -> Double? {
        guard ink.any else { return nil }
        let brightness = cell.luma
        var body = ink
        let widest = max(1, BoardGeometry.rounded(Double(min(cell.width, cell.height)) * 0.05))
        for radius in stride(from: widest, through: 1, by: -1) {
            let eroded = Morphology.erode(ink, radius: radius)
            if Double(eroded.count) >= max(8, 0.2 * Double(ink.count)) {
                body = eroded
                break
            }
        }
        var samples: [Double] = []
        for index in body.values.indices where body.values[index] {
            samples.append(brightness.values[index])
        }
        return samples.isEmpty ? nil : LumaImage.median(samples)
    }
}
