/// A rectangular array, indexed `[x, y]` with y counting down from the top of the image —
/// the same convention the pixels arrive in.
public struct Grid<Element>: Sendable where Element: Sendable {
    public let width: Int
    public let height: Int
    public private(set) var values: [Element]

    public init(width: Int, height: Int, repeating value: Element) {
        self.width = width
        self.height = height
        self.values = [Element](repeating: value, count: max(0, width * height))
    }

    public init(width: Int, height: Int, values: [Element]) {
        precondition(values.count == width * height)
        self.width = width
        self.height = height
        self.values = values
    }

    @inline(__always)
    public subscript(x: Int, y: Int) -> Element {
        get { values[y * width + x] }
        set { values[y * width + x] = newValue }
    }

    public var isEmpty: Bool { width == 0 || height == 0 }

    @inline(__always)
    public func contains(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    public func map<Other>(_ transform: (Element) -> Other) -> Grid<Other> {
        Grid<Other>(width: width, height: height, values: values.map(transform))
    }

    /// The sub-rectangle, clamped to what exists.
    public func cropped(x: Int, y: Int, width cropWidth: Int, height cropHeight: Int) -> Grid {
        let left = max(0, x)
        let top = max(0, y)
        let right = min(width, x + cropWidth)
        let bottom = min(height, y + cropHeight)
        guard right > left, bottom > top else {
            return Grid(width: 0, height: 0, values: [])
        }
        var out = [Element]()
        out.reserveCapacity((right - left) * (bottom - top))
        for row in top..<bottom {
            out.append(contentsOf: values[(row * width + left)..<(row * width + right)])
        }
        return Grid(width: right - left, height: bottom - top, values: out)
    }
}

/// Perceived brightness, 0...255 per pixel.
public typealias LumaImage = Grid<Double>

/// A per-pixel yes/no: which pixels are Ink, which pixels a Silhouette covers.
public typealias Mask = Grid<Bool>

extension Grid where Element == Bool {
    public var count: Int { values.lazy.filter { $0 }.count }
    public var any: Bool { values.contains(true) }
    /// Fraction of the grid that is set.
    public var coverage: Double { isEmpty ? 0 : Double(count) / Double(values.count) }

    public mutating func formUnion(_ other: Grid) {
        precondition(width == other.width && height == other.height)
        for index in values.indices where other.values[index] { values[index] = true }
    }

    public func intersection(_ other: Grid) -> Grid {
        precondition(width == other.width && height == other.height)
        var out = self
        for index in out.values.indices where !other.values[index] {
            out.values[index] = false
        }
        return out
    }

    /// How many pixels the two have in common.
    public func overlap(_ other: Grid) -> Int {
        precondition(width == other.width && height == other.height)
        var total = 0
        for index in values.indices where values[index] && other.values[index] {
            total += 1
        }
        return total
    }

    /// The same mask flipped left to right — a piece drawing seen in a mirror.
    public var mirrored: Grid {
        var out = self
        for y in 0..<height {
            for x in 0..<width {
                out[x, y] = self[width - 1 - x, y]
            }
        }
        return out
    }
}

extension Grid where Element == Double {
    /// Median absolute deviation — a spread that ignores outliers.
    static func medianAbsoluteDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let middle = median(values)
        return median(values.map { abs($0 - middle) })
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
