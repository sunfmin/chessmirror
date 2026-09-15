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
    public init(backgrounds: Grid<Double>) {
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
}
