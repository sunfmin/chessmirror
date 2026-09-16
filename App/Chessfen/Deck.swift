import ChessfenKit
import SwiftUI

// ===================================================================== the card

/// The answer, in one sentence, and it is the first thing on every card.
///
/// Ten cards used to open ten different ways — a chip here, a heading there, a bare paragraph on a
/// third — so a person swiping through them had to work out the shape of each one before they
/// could read it. Now the first line is always the answer and everything else is under it.
struct CardLede: View {
    let text: String
    var tint: Color = Palette.ink

    init(_ text: String, tint: Color = Palette.ink) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A line of moves, numbered to match the arrows on the board.
///
/// The number is the join and the whole reason a line is drawn at all: the figure on the chip is
/// the figure on the arrow. Horizontal, because a sequence of moves is a sequence — six of them
/// down the card would be six paragraphs of nothing.
struct CardMoves: View {
    struct Move: Hashable {
        let step: Int
        let san: String
        let isYours: Bool
    }

    let moves: [Move]
    /// Which step the eye is on, when one of them is being walked.
    var standing: Int?
    var tap: ((Int) -> Void)?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(moves, id: \.self) { move in
                    let chip = HStack(spacing: 5) {
                        Text("\(move.step)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(move.isYours ? Palette.mine : Palette.alarm, in: Circle())
                        Text(move.san).font(.notation).foregroundStyle(Palette.ink)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        standing == move.step ? Palette.chipRest.opacity(2) : Palette.chipRest,
                        in: Capsule()
                    )
                    .overlay {
                        if standing == move.step {
                            Capsule().stroke(Palette.ink.opacity(0.5), lineWidth: 1)
                        }
                    }
                    if let tap {
                        Button { tap(move.step) } label: { chip }.buttonStyle(.plain)
                    } else {
                        chip
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

/// The small print: what did not happen, what is not written down, why there is nothing here.
///
/// A voice of its own because it is a different kind of statement from the answer above it — and
/// having one means the answer never has to be shrunk to make room for a caveat.
struct CardNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(Palette.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The bottom edge of a card with more on it than fits: the last line fades out instead of being
/// chopped. A cut sentence looks like a bug; a fading one looks like a card that can be pulled up,
/// which is exactly what it is.
struct CardFade: View {
    /// How tall it is, and that is not a matter of taste: a card's column ends with this much
    /// padding, so nothing readable is ever underneath. Shorter than a line of text and the fade
    /// does the opposite of its job — a cut line shows through it with its bottom missing, which
    /// is exactly what it is here to stop looking like.
    static let height: CGFloat = 22

    var body: some View {
        LinearGradient(
            colors: [Palette.raised.opacity(0), Palette.raised],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: Self.height)
        .allowsHitTesting(false)
    }
}

/// A chip that presses. The one control idiom on the screen (`Chip`), wired to an action, so a
/// card never has to reach for a bordered button and look like a form.
struct CardButton: View {
    let label: String
    var isOn = false
    var isEnabled = true
    let act: () -> Void

    var body: some View {
        Button(action: act) {
            Chip(label: label, isOn: isOn, isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
