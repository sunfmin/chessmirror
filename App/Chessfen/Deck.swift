import ChessfenKit
import SwiftUI

// ===================================================================== the card

/// The surface the cards are dealt onto: a raised card with four rounded corners, a hairline
/// edge, and a shadow that lifts it off the page. It fills the room the parent gives it — the
/// space under the record, down to the names. A body longer than that scrolls inside it.
struct DeckSurface<Head: View, Content: View>: View {
    @ViewBuilder var head: () -> Head
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(spacing: 0) {
            content()
            head()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(shape)
        .background {
            shape
                .fill(Palette.raised)
                .overlay { shape.stroke(Palette.hairline, lineWidth: 0.5) }
                .shadow(color: Palette.lift, radius: 9, x: 0, y: -3)
        }
    }
}

/// How far the engine has got on this card: the word, and the Depth as a figure of its own.
///
/// A caption that swallowed the number ("正在算 · 深 26") read as a spinner with no account of
/// itself. The Depth is the account (docs/adr/0020) — while it climbs, and still after it
/// has stopped, so a cache hit does not look like the engine never ran.
struct CardSearching: View {
    let progress: GameSession.SearchProgress?
    var phrase: String = "正在算"
    var isRunning: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isRunning {
                ProgressView().controlSize(.mini)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                Text(phrase)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.ink)
            } else {
                Text("算到")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSoft)
            }
            Spacer(minLength: 0)
            Text(depthLabel)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(depthTint)
                .animation(.none, value: progress?.depth)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityLabel(isRunning ? phrase : "算到")
        .accessibilityValue(depthValue)
    }

    private var depthLabel: String {
        if let depth = progress?.depth, depth > 0 { return "层级 \(depth)" }
        return isRunning ? "层级" : ""
    }

    private var depthValue: String {
        if let depth = progress?.depth, depth > 0 { return "层级 \(depth)" }
        return isRunning ? "开始" : ""
    }

    private var depthTint: Color {
        if let depth = progress?.depth, depth > 0 {
            return isRunning ? Palette.analysis : Palette.ink
        }
        return Palette.inkSoft
    }
}

// ====================================================================== the rail

/// The five names in a segmented row, on the page, hugging the card's outside bottom.
/// Tapping one turns the card; swiping the page still does.
///
/// The names used to live inside each card, under a row of dots that did not say which card was
/// which — and there were ten of them, grouped in four clusters with the group named at the end of
/// the rail. Five two-character titles fit in one capsule, and then the card can start with its
/// answer rather than with its own name again.
struct DeckRail<Card: Hashable>: View {
    let cards: [Card]
    let current: Card
    /// The colour of the selected segment. The screen decides: 杀招 wears whose mate it is.
    let tint: (Card) -> Color
    let name: (Card) -> String
    let go: (Card) -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                ForEach(cards, id: \.self) { card in segment(card) }
            }
            .padding(3)
            .background(Palette.chipRest, in: Capsule())
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        // The five names are a label like the rows above them, and a capped one: an index that runs
        // off both edges of the phone is not an index, and 练习 is the name it loses (see
        // `chromeType`).
        .chromeType()
    }

    private func segment(_ card: Card) -> some View {
        let isOn = card == current
        return Button {
            withAnimation(.snappy(duration: 0.22)) { go(card) }
        } label: {
            Text(name(card))
                .font(.footnote.weight(isOn ? .semibold : .medium))
                .foregroundStyle(isOn ? Palette.parchment : tint(card))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(isOn ? tint(card) : Color.clear, in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name(card))
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

// ================================================================= what is on it

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

/// One numbered row: a badge, and a sentence about the thing it is numbered on the board.
///
/// The badge's colour is the same violet-and-red the arrows and the ringed squares use — yours
/// near, theirs far — so a row needs no swatch and no legend beside it.
struct CardRow: View {
    /// What stands at the head of a row. Three kinds and no more: the figure that is also on the
    /// board, a mark that says which way this reading went, or nothing at all.
    enum Badge: Hashable {
        /// Numbered to match an arrow or a ring on the board.
        case step(Int, isYours: Bool)
        /// A gain or a cost — the scanner's two readings, and anything else that is one or the
        /// other without being part of a sequence.
        case mark(isGain: Bool)
        case none
    }

    let badge: Badge
    /// The move this row is about, set in the notation face. Above the sentence rather than
    /// inside it: a move is a name, and a name that has to be picked out of prose is a name
    /// nobody picks out.
    var move: String?
    /// One word qualifying the move — 对方, when a row of a line is a reply rather than a plan.
    var tag: String?
    var tagTint: Color = Palette.alarm
    let text: String
    /// A second line, in the small voice: what the move gives away, what the square costs.
    var under: String?
    var underTint: Color = Palette.alarm
    /// A row whose first line is the name of something rather than a sentence about it.
    var isNamed = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            mark
            VStack(alignment: .leading, spacing: 2) {
                if move != nil || tag != nil {
                    HStack(spacing: 6) {
                        if let move {
                            Text(move).font(.notation).foregroundStyle(Palette.ink)
                        }
                        if let tag {
                            Text(tag).font(.caption2).foregroundStyle(tagTint)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if !text.isEmpty {
                    Text(text)
                        .font(isNamed ? .footnote : .caption)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let under {
                    Text(under)
                        .font(.caption2)
                        .foregroundStyle(underTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var mark: some View {
        switch badge {
        case .step(let step, let isYours):
            Text("\(step)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(isYours ? Palette.mine : Palette.alarm, in: Circle())
        case .mark(let isGain):
            Circle()
                .fill(isGain ? Palette.mine : Palette.alarm)
                .frame(width: 6, height: 6)
                .frame(width: 16, height: 16)
        case .none:
            EmptyView()
        }
    }
}

/// Named figures, in one column of labels and one of numbers.
///
/// The numbers are set in the clock face the big Score uses and they are monospaced, so three
/// rows of them line up on the decimal point and can be compared by eye rather than read one at
/// a time. Every place in the app that puts a move beside what it is worth uses this.
struct CardFigures: View {
    struct Row: Hashable {
        let label: String
        let move: String?
        let value: String?
        var tint: Color = Palette.inkSoft
        var isProminent = false
    }

    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows, id: \.self) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(Palette.inkSoft)
                        .frame(width: 34, alignment: .leading)
                    if let move = row.move {
                        Text(move).font(.notation).foregroundStyle(Palette.ink)
                    }
                    Spacer(minLength: 6)
                    if let value = row.value {
                        Text(value)
                            .clockFont(row.isProminent ? 15 : 14, weight: row.isProminent ? .semibold : .regular)
                            .foregroundStyle(row.tint)
                    }
                }
            }
        }
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

/// The things you can press, in one row, in the same place on every card: last.
///
/// Explain, then offer. A card that opens with a button is a card that asks before it has said
/// what it is asking about.
struct CardActions<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
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
