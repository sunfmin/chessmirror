import ChessfenKit
import SwiftUI
import UIKit

/// The app's colours, and they are the board's colours.
///
/// The board is drawn from a palette that predates the app — the renderer's squares and the
/// piece artwork. Anything around it that reaches for the system's greys and blues instead ends
/// up looking like two designs stapled together, which is exactly what happens when a warm
/// wooden board sits inside stock iOS chrome. So the chrome is derived from the wood: the page
/// is a lift of the light square, the ink is a deepening of the dark one.
///
/// One colour is not wood, on purpose. Teal is what the wood cannot say: the engine's voice —
/// the recommendation arrow, the live score, the depth gauge — and the two squares of the move
/// just played. Those are the marks that have to win against the board rather than sit inside
/// it, and nothing in the wood's own range can.
/// Nonisolated, and it has to be. This target defaults every declaration to the main actor, which
/// is right for view code and wrong for a palette: SwiftUI resolves a colour on whichever thread
/// is drawing, and a dynamic provider closure that insists on the main actor traps the process the
/// first time the render thread asks it what colour it is.
nonisolated enum Palette {
    static let boardLight = Color(hex: 0xFFCE9E)
    static let boardDark = Color(hex: 0xD18B47)

    static let parchment = dynamic(light: 0xF7EDE1, dark: 0x17110C)
    /// One step up from the page, for the panels that hold data.
    static let raised = dynamic(light: 0xFFF7EE, dark: 0x241A12)
    static let ink = dynamic(light: 0x241A12, dark: 0xF2E4D5)
    static let inkSoft = dynamic(light: 0x7A6350, dark: 0xB09880)
    static let walnut = Color(hex: 0x6B4522)
    static let analysis = dynamic(light: 0x2E7D6E, dark: 0x4FB8A4)
    static let alarm = dynamic(light: 0xB3402A, dark: 0xE87A62)
    /// The player's own voice, as against the engine's teal: their arrow on the board, and the
    /// layer they turned on to look at it. Violet is nowhere in the wood and nowhere near teal,
    /// so two arrows in the two colours can never be mistaken for each other — which is the whole
    /// point of drawing them both (docs/adr/0018).
    static let mine = dynamic(light: 0x6C4AB6, dark: 0xA78BFA)

    /// The two ends of the advantage bar. The pieces' own colours by day; by night the black end is
    /// lifted off the page, because a bar drawn in the page's own colour is not a bar, it is a hole
    /// — and the end of a lost game would read as an empty gauge.
    static let barBlack = dynamic(light: 0x241A12, dark: 0x4A3A2C)
    static let barWhite = dynamic(light: 0xFFFCF7, dark: 0xF2E4D5)

    /// A line and a resting chip, borrowed from whatever the page is made of: wood over paper,
    /// light over night. Tinted wood on a dark page is very nearly the dark page, which is how a
    /// deck of chips turns into an empty strip after sunset.
    static var hairline: Color { dynamic(light: walnut.opacity(0.18), dark: .white.opacity(0.16)) }
    /// The shadow that lifts the deck's card off the page. Wood-coloured by day, because a grey
    /// drop shadow on parchment is the one thing that would make this look like a web page; by
    /// night a shadow has to be darker than the page it is on, and nothing in the wood is.
    static var lift: Color { dynamic(light: walnut.opacity(0.22), dark: .black.opacity(0.55)) }
    static var chipRest: Color { dynamic(light: walnut.opacity(0.10), dark: .white.opacity(0.10)) }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        dynamic(light: Color(hex: light), dark: Color(hex: dark))
    }

    private static func dynamic(light: Color, dark: Color) -> Color {
        Color(
            uiColor: UIColor { traits in
                UIColor(traits.userInterfaceStyle == .dark ? dark : light)
            }
        )
    }
}

extension Color {
    nonisolated fileprivate init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// ---------------------------------------------------------------------- type

extension View {
    /// A short label, letter-spaced. Chinese has no small caps to reach for, but 疏排 does the
    /// same work: it marks a handful of characters as a label rather than as prose.
    func eyebrow() -> some View {
        font(.caption.weight(.medium))
            .tracking(2)
            .foregroundStyle(Palette.inkSoft)
    }
}

extension Font {
    /// A move, in the face a scoresheet is set in.
    static let notation = Font.system(.footnote, design: .monospaced)

    /// The name on a card. Serif, and it is the only serif in the app: chess is written down in
    /// tournament books and 棋谱, both of which are set in serif, and a deck of five cards named in
    /// the same face as their own body text is a deck of five paragraphs. In Chinese it resolves to
    /// 宋体, which is exactly the book voice this is borrowing.
    static let cardName = Font.system(.subheadline, design: .serif).weight(.semibold)
}

extension View {
    /// Numbers that change while you watch them, at the reader's own text size.
    ///
    /// Rounded digits read as the numerals on a chess clock, and monospaced ones do not shuffle the
    /// layout as they tick. The size used to be fixed, which was a quiet lie on a card: the
    /// sentences beside a 层级 or a Score grow with the reader and the number did not, so the
    /// biggest thing on the card stayed the size it happened to be designed at while everything it
    /// is compared against moved away from it. Growth is capped at 1.4× — a number is a number,
    /// and the rows it sits in are a strip under a board and rows of a card, which stop fitting
    /// before a hedge-fund-sized digit stops being readable.
    func clockFont(_ size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        modifier(ClockFont(size: size, weight: weight))
    }

    /// The words that are labels — who is playing, what the clock is, the record's chips, the five
    /// names — stop growing at the first accessibility size. The card under the board grows all the
    /// way to the last one.
    ///
    /// Not a quiet override of the reader's setting: the card is what the app is for, and its
    /// sentences are the only text on this screen anybody has to *read*. The rows above it are
    /// status, and they are also the only rows whose growth is not paid for by anything — the board
    /// is sized from a budget (`GameScreen.boardSide`) and the deck takes what is left. At the
    /// largest size those four rows took a hundred points off the deck to say 「黑方 引擎 跟着我」
    /// at 40pt, and left the card 42pt tall. Capped, they still grow by a fifth and the card keeps
    /// the room it was designed with.
    func chromeType() -> some View {
        dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

private struct ClockFont: ViewModifier {
    // The default is the wrapper's own syntax saying which argument is which; every use of this
    // modifier states the size it was designed at, and the environment scales it from there.
    @ScaledMetric(relativeTo: .body) private var grown: CGFloat = 0
    private let cap: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight) {
        _grown = ScaledMetric(wrappedValue: size, relativeTo: .body)
        cap = size * 1.4
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(
            .system(size: min(grown, cap), weight: weight, design: .rounded).monospacedDigit()
        )
    }
}

// ------------------------------------------------------------------ controls

/// The one control idiom on the screen: a wooden chip, either resting or chosen.
///
/// Before this there were four — capsules, a segmented picker, bordered buttons and plain
/// links — which is three too many for a screen whose whole job is a board and a number.
struct Chip: View {
    let label: String
    var isOn = false
    var isEnabled = true

    var body: some View {
        Text(label)
            .font(.footnote.weight(isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? Palette.parchment : Palette.ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(isOn ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(Palette.chipRest))
            .clipShape(Capsule())
            .opacity(isEnabled ? 1 : 0.35)
    }
}

/// One colour, as the thing itself.
///
/// A disc of the piece colour beside the word does in a glance what 白方 does in two characters,
/// and it is what ties a bar to its own half of the board.
struct Swatch: View {
    let colour: PieceColour
    var size: CGFloat = 14

    var body: some View {
        Circle()
            .fill(colour == .white ? Palette.barWhite : Palette.barBlack)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Palette.walnut.opacity(0.45), lineWidth: 0.8))
    }
}

/// A label and its chips, hugging its content so two of them fit on one line. Kept on screen
/// rather than tucked into a menu, because what these say — which way up the board is, who
/// started, who is playing each side — are facts about the game in front of you, not settings.
struct ChipCluster<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let label: String
        var isEnabled = true
        var id: Value { value }
    }

    let title: String
    let options: [Option]
    let selection: Value
    let pick: (Value) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title).eyebrow()
            ForEach(options) { option in
                Button {
                    pick(option.value)
                } label: {
                    Chip(
                        label: option.label,
                        isOn: selection == option.value,
                        isEnabled: option.isEnabled
                    )
                }
                .buttonStyle(.plain)
                .disabled(!option.isEnabled)
            }
        }
        .fixedSize()
    }
}

/// A button whose work happens while it is held down: pressing starts it, letting go finishes it.
///
/// The only one in the app, and it belongs to the engine. How long it is held is how long the engine
/// thinks (Mirrored Time, docs/adr/0009 — it is never handicapped, and time is the only dial), so
/// the control has to *be* the dial rather than a switch beside one. It fills as the search deepens,
/// which is the same gauge the header draws, under the thumb that is filling it.
///
/// Sized to sit in the bar of the side on the clock rather than to span the screen: it plays a move
/// for one colour, so it stands on that colour's side of the board.
struct HoldButton: View {
    let label: String
    let symbol: String
    /// Whether it is being held right now. Passed in rather than kept here, because the screen has
    /// to say what the deck reads while it is — and it should be the same thing `onPress` starts
    /// and `onRelease` ends, so that a press which never gets its release cannot leave this true.
    let isHeld: Bool
    /// How far the search has got, 0...1. Drawn only while the button is held: a search is running
    /// under this screen most of the time, and a meter standing at three quarters with nobody's
    /// thumb on it says the button is busy when it is waiting.
    var fill: Double = 0
    var isEnabled = true
    let onPress: () -> Void
    let onRelease: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(label)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isHeld ? Palette.parchment : Palette.ink)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background {
            ZStack(alignment: .leading) {
                Palette.chipRest
                GeometryReader { proxy in
                    Palette.analysis
                        .frame(width: proxy.size.width * (isHeld ? min(max(fill, 0), 1) : 0))
                        .animation(.easeOut(duration: 0.3), value: fill)
                        .animation(.easeOut(duration: 0.2), value: isHeld)
                }
            }
            .clipShape(Capsule())
        }
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Capsule())
        // A drag of no distance, which is a press: `onEnded` arrives wherever the finger lifts, so
        // sliding off the button still plays the move rather than leaving a search running.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isEnabled, !isHeld else { return }
                    onPress()
                }
                .onEnded { _ in
                    guard isHeld else { return }
                    onRelease()
                }
        )
    }
}

// ------------------------------------------------------------------- numbers

/// How far a search has to run before another ply stops being news.
///
/// There used to be a meter on the game screen wearing this number — a speed, a depth, and a
/// filling hairline. It said what the phone was doing rather than what the position was, and on a
/// screen with one board and a report to fit under it that is a row somebody else needed. The
/// number stays, because the hold button still draws how far its own search has got.
enum SearchDepth {
    /// Full depth as far as a gauge is concerned. Searches run deeper, and a gauge simply sits
    /// full when they do — past this point another ply is not news.
    static let deepEnough = 34.0
}

/// Who is ahead, as a length. Laid along the bottom edge of the board rather than beside it:
/// a phone has width to spare under a square and none at all next to one, and the board is the
/// thing this screen is for.
///
/// Centipawns are unbounded and a bar is not, so the mapping squashes. A logistic curve is the
/// honest squash — it is roughly how a score turns into a winning chance, so equal-looking bars
/// mean equally close games rather than equal pawn counts.
struct EvalBar: View {
    let score: Score?
    /// The side at the left of the bar is the side at the bottom of the board.
    var orientation: Orientation = .whiteAtBottom
    /// Set once the game has ended, and then the bar reads the result instead of a Score. A
    /// finished game gives the engine nothing to search, so the number goes away — and a bar left
    /// to draw a missing number sits exactly half and half, which is the picture of a level game.
    /// Somebody who has just been mated is not level.
    var finish: Finish?

    /// How a game ended, as far as a bar is concerned.
    enum Finish: Hashable {
        case won(PieceColour)
        case drawn
    }

    var body: some View {
        let white = finish?.whiteShare ?? advantageFraction(score)
        // The side at the bottom of the board is the side at the left of the bar — and its colour,
        // because the bar's two ends are the pieces' colours and not "the left one and the right
        // one". The growing end used to be White whatever way up the board was, so with Black at the
        // bottom the bar said the exact opposite of the number printed beside it, to the only person
        // who could see either (docs/adr/0024).
        let bottomIsWhite = orientation == .whiteAtBottom
        let share = bottomIsWhite ? white : 1 - white
        let bottomTint = bottomIsWhite ? Palette.barWhite : Palette.barBlack
        let topTint = bottomIsWhite ? Palette.barBlack : Palette.barWhite
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(topTint)
                Rectangle()
                    .fill(bottomTint)
                    .frame(width: proxy.size.width * share)
                // A draw is the one result that is genuinely half and half, so it cannot be said
                // with a length: it is said by taking both colours off the bar. Nobody won it.
                if finish == .drawn {
                    Rectangle().fill(Palette.walnut.opacity(0.45))
                }
            }
            // The balance point, and only while there is still a balance to be off.
            .overlay(alignment: .center) {
                if finish == nil {
                    Rectangle().fill(Palette.analysis).frame(width: 1)
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        // Outlined, or the white half vanishes into the page and an even position reads as a bar
        // that is only half there.
        .overlay(Capsule().stroke(Palette.walnut.opacity(0.35), lineWidth: 0.5))
        .animation(.easeOut(duration: 0.35), value: share)
        .accessibilityLabel(localized("standing.bar"))
        .accessibilityValue(finish?.label ?? score?.displayText ?? localized("standing.unknown"))
    }
}

extension EvalBar.Finish {
    /// How much of the bar White holds at the end: all of it, none of it, or a bar that is neither.
    var whiteShare: Double {
        switch self {
        case .won(let colour): colour == .white ? 1 : 0
        case .drawn: 0.5
        }
    }

    var label: String {
        switch self {
        case .won(let colour): localized("standing.won", colour.label)
        case .drawn: localized("standing.drawn")
        }
    }

    /// The result in the numerals a scoresheet uses, set to be read in the clock face the Score was
    /// read in — so "1/2-1/2" is written the way it is printed rather than as five characters.
    var scoreline: String {
        switch self {
        case .won(let colour): colour == .white ? "1-0" : "0-1"
        case .drawn: "½-½"
        }
    }
}

func advantageFraction(_ score: Score?) -> Double {
    guard let score else { return 0.5 }
    switch score {
    case .centipawns(let value):
        return 1 / (1 + pow(10, -Double(value) / 400))
    case .mate(let moves):
        return moves > 0 ? 1 : 0
    }
}

/// A score in a list of engine lines, in the same numerals as the big one so the eye can carry
/// a value from one to the other.
struct ScoreCell: View {
    let score: Score?
    var prominent = false

    var body: some View {
        Text(score?.displayText ?? "—")
            .clockFont(prominent ? 15 : 14, weight: prominent ? .semibold : .regular)
            .foregroundStyle(prominent ? Palette.analysis : Palette.inkSoft)
    }
}
