import ChessfenKit
import SwiftUI

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// The Review's scores as a ground for the record: a level per ply, high where White is doing
/// well and low where Black is.
///
/// Shaded, never stroked. It stands behind the move cards, and the middle of that strip is
/// exactly where the moves' text sits — so a stroked line through a near-equal opening comes out
/// as a strikethrough across the words, and a chart that defaces what it stands behind is worse
/// than no chart at all. A shaded level says the same thing, by how far it has risen, and crosses
/// nothing. It is deaf, too: every tap in that strip already means "take me to that move", and a
/// second answer to one tap is a bug.
///
/// Drawn in the engine's own colour, because that is whose opinion it is — the two-voice rule
/// this app holds everywhere else (teal is the engine, violet is the player). A Canvas does not
/// inherit the screen's tint, so the colour is named here rather than left to `.accentColor`,
/// which resolved to a blue belonging to nobody.
struct EvalCurve: View {
    let plies: Int
    let score: (Int) -> Score?

    var body: some View {
        Canvas { context, size in draw(into: &context, size: size) }
            .allowsHitTesting(false)
    }

    private func draw(into context: inout GraphicsContext, size: CGSize) {
        guard plies > 0 else { return }

        // Only as far as the Review has actually got: a level carried across positions nobody has
        // scored yet would be a flat half-full pretending to be a finding.
        let known = (0...plies).filter { score($0) != nil }
        guard let first = known.first, known.count > 1, let last = known.last else { return }

        let step = size.width / CGFloat(plies)
        func point(_ ply: Int) -> CGPoint {
            CGPoint(
                x: CGFloat(ply) * step,
                y: size.height * (1 - advantageFraction(score(ply)))
            )
        }

        var level = Path()
        level.move(to: CGPoint(x: point(first).x, y: size.height))
        for ply in known { level.addLine(to: point(ply)) }
        level.addLine(to: CGPoint(x: point(last).x, y: size.height))
        level.closeSubpath()
        context.fill(level, with: .color(Palette.analysis.opacity(0.20)))
    }
}
