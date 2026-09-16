/// How bright the board's own light squares are, Cell by Cell.
///
/// A piece body's brightness says nothing on its own. Photograph a printed diagram and the
/// paper runs from 230 at the lit edge of the page down to 110 in the shade at the other
/// end, all in one picture — so a white rook standing in the shade comes out darker than a
/// black rook standing in the light, and no fixed brightness can be the line between the
/// two colours. Measured against the light squares *beside* it, though, a white body sits
/// around three quarters of its Local Light and a black one around a third, wherever on
/// the board it stands and whatever the camera did.
///
/// Light squares rather than dark ones because light is the end that carries the answer: a
/// board's dark squares are only a little darker than its light ones, while black pieces
/// are darker than everything.
public struct BoardLighting: Sendable {
    /// How many Cells away still counts as beside. Two rings in from a corner is nine
    /// light squares to take a median of — enough that a piece with an unusually flat
    /// square, or a highlight frame, cannot move the answer — and close enough that a
    /// gradient across the board is followed rather than averaged away.
    static let neighbourhood = 2

    private let level: Grid<Double>

    /// Takes the 64 square backgrounds, in the picture's own row order.
    ///
    /// `followingTheLight` is what a photograph needs and a screenshot does not: a lamp to one
    /// side makes the answer a different number at each end of the board, and only a median of
    /// the light squares *beside* a Cell follows that. A computer-drawn board has one light
    /// value everywhere, so the whole grid is that value — which is not merely cheaper but
    /// steadier, because the local median is the thing a highlighted square or a move arrow
    /// can pull off (docs/adr/0033).
    public init(backgrounds: Grid<Double>, followingTheLight: Bool = true) {
        precondition(backgrounds.width == 8 && backgrounds.height == 8)

        // Which of the two colourings is the light one is a question about this board, not
        // about chess: nothing says a1 is dark in a photograph that may be seen from either
        // side, or in a diagram drawn either way round.
        var colouring: [[Double]] = [[], []]
        for row in 0..<8 {
            for column in 0..<8 {
                colouring[(row + column).isMultiple(of: 2) ? 0 : 1]
                    .append(backgrounds[column, row])
            }
        }
        let medians = colouring.map { LumaImage.median($0) }
        let lightIsEven = medians[0] >= medians[1]
        let overall = max(medians[0], medians[1])

        var level = Grid<Double>(width: 8, height: 8, repeating: overall)
        guard followingTheLight else {
            self.level = level
            return
        }
        for row in 0..<8 {
            for column in 0..<8 {
                var nearby: [Double] = []
                for y in max(0, row - Self.neighbourhood)...min(7, row + Self.neighbourhood) {
                    for x in max(0, column - Self.neighbourhood)...min(7, column + Self.neighbourhood)
                    where (y + x).isMultiple(of: 2) == lightIsEven {
                        nearby.append(backgrounds[x, y])
                    }
                }
                level[column, row] = nearby.isEmpty ? overall : LumaImage.median(nearby)
            }
        }
        self.level = level
    }

    /// The light-square level beside one Cell.
    public func light(row: Int, column: Int) -> Double {
        level.contains(x: column, y: row) ? level[column, row] : 0
    }

    /// How much the light varies across the board, as a fraction of its brightest corner.
    ///
    /// Zero on a picture a computer drew: every light square of a screenshot is the same
    /// value, so the whole grid is one number and there is nothing for the local median to
    /// follow. A photograph of a real board is never zero — a lamp on one side, a hand's
    /// shadow, the page curving away — and the ones this app has been handed run from
    /// about a tenth to a third.
    public var spread: Double {
        var lowest = Double.greatestFiniteMagnitude
        var highest = 0.0
        for row in 0..<8 {
            for column in 0..<8 {
                let value = level[column, row]
                lowest = min(lowest, value)
                highest = max(highest, value)
            }
        }
        guard highest > 0 else { return 0 }
        return (highest - lowest) / highest
    }
}
