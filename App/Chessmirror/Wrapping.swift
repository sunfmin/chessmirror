import SwiftUI

/// A row that becomes two rows when the words are too long for one.
///
/// Written for the eight answers to 为什么 under the board. In Chinese every verb is one
/// character and all eight sit in a single line, which is what that control was drawn for and
/// what its screenshots still show. In French the same eight are Attaquer, Échanger, Défendre —
/// four times the width, and an `HStack` answers that by squeezing every chip until the words
/// inside them are ellipses. A chip reading "Att…" is not an answer anybody can pick.
///
/// So: place what fits, then start another line. The height it asks for is the height it needs,
/// no more — one line of chips in Chinese and Japanese, two or three in the Latin languages,
/// decided by measuring rather than by a language check (docs/adr/0019).
struct Wrapping: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(subviews, within: proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height =
            lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for line in lines(subviews, within: bounds.width) {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (line.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    /// One pass over the subviews at their natural size, breaking whenever the next one would
    /// cross the right edge. A subview wider than the whole width still gets its own line rather
    /// than an empty one before it.
    private func lines(_ subviews: Subviews, within width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !line.items.isEmpty, line.width + spacing + size.width > width {
                lines.append(line)
                line = Line()
            }
            line.add(Item(index: index, size: size), spacing: spacing)
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }

    private struct Item {
        let index: Int
        let size: CGSize
    }

    private struct Line {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        mutating func add(_ item: Item, spacing: CGFloat) {
            width += items.isEmpty ? item.size.width : spacing + item.size.width
            height = max(height, item.size.height)
            items.append(item)
        }
    }
}
