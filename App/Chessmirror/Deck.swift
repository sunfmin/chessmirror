import ChessmirrorKit
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
    let moves: [LineStep]
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

// ===================================================================== the deck

/// The findings under the record: what the engine and the rules noticed about the position on
/// screen, each shut until it is pressed (docs/adr/0025).
///
/// It deals itself. Dealing is an arrival and an arrival spends a Stint, so it has to happen
/// after the session has appeared — which used to be a comment over two lines in the screen's
/// own `onAppear`, in the right order because somebody had read the comment. A view cannot
/// appear before the view that contains it, so putting the deal here is the order.
struct DeckView: View {
    let session: GameSession
    /// The board's selection, which reading the finder's answer puts down: the answer is about
    /// the position, not about the piece somebody happened to have picked up.
    @Binding var selected: Square?

    /// Findings are invitations, never navigation: absent results occupy no space. Which they
    /// are is the session's to say (`GameSession.deck`), not this view's.
    private var findings: [GameScreen.Card] { session.deck.dealt.map(\.card) }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(findings, id: \.self) { kind in
                VStack(spacing: 0) {
                    discovery(kind)
                    if session.isOpen(kind) {
                        body(of: kind)
                    }
                }
                .background(Palette.analysis.opacity(0.06))
            }
        }
        .padding(.vertical, findings.isEmpty ? 0 : 8)
        .onAppear { session.dealDeck() }
    }

    @ViewBuilder private func body(of kind: GameScreen.Card) -> some View {
        switch kind {
        case .mate: cardFrame(kind) { mateBody }
        case .tactics: cardFrame(kind) { tacticsBody }
        }
    }

    private func discovery(_ kind: GameScreen.Card) -> some View {
        let row = session.deck.row(kind)
        let found = row?.isFound ?? false
        let searching = session.deck.isSearching
        let title = row?.title ?? kind.title
        return Button {
            withAnimation(.snappy(duration: 0.22)) { session.press(kind) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: kind.symbol)
                    .font(.caption)
                    .foregroundStyle(Palette.analysis)
                    .frame(width: 14)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 4)
                if found {
                    Image(systemName: session.isOpen(kind) ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Palette.inkSoft)
                        .frame(width: 30, height: 30)
                } else if searching {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(minHeight: 30)
            .lineLimit(1)
            .padding(.leading, 13)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle().fill(Palette.analysis).frame(width: 3)
            }
            .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!found)
        .accessibilityLabel(found ? localized("discovery.view") : title)
        .accessibilityValue(title)
        .chromeType()
    }

    /// One card: one line saying what it answers, and then the thing itself. The name is on the
    /// rail under the card, so it is not said again here.
    private func cardFrame<Content: View>(
        _ kind: GameScreen.Card, @ViewBuilder body: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            body()
            if session.isOpen(kind), let progress = session.standingProgress {
                HStack(spacing: 6) {
                    if session.isAdvising { ProgressView().controlSize(.mini) }
                    Text(localized(session.isAdvising ? "noSlips.judging" : "search.reached"))
                    Text(localized("game.depth", progress.depth))
                }
                .font(.caption2)
                .foregroundStyle(Palette.inkSoft)
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 12)
    }

    // ------------------------------------------------------------------ 杀招

    private var mateInk: Color {
        guard let news = session.mateNews else { return Palette.ink }
        return news.isOurs ? Palette.mine : Palette.alarm
    }

    /// The news: a mate somebody can already see, whoever it belongs to (docs/adr/0025).
    ///
    /// Not a switch and not an answer to anything — the one thing on this screen that arrives
    /// unbidden. It says how forced it is because that is the difference between a mate a person
    /// can follow and one they have to take on trust, and every clause of it was counted by the
    /// rules code rather than asserted.
    @ViewBuilder private var mateBody: some View {
        if let news = session.mateNews {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(news.head)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(mateInk)
                    Spacer(minLength: 4)
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { session.toggleLine() }
                    } label: {
                        Image(systemName: session.draws(.mate) ? "arrow.up.right.circle.fill" : "arrow.up.right.circle")
                            .font(.subheadline)
                            .foregroundStyle(session.draws(.mate) ? mateInk : Palette.inkSoft)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(news.arrows.isEmpty)
                    .accessibilityLabel(localized(session.draws(.mate) ? "screen.hideArrows" : "screen.showArrows"))
                    .accessibilityHint(localized("screen.arrowsExplained"))
                }
                CardLede(news.sentence)
                if !news.steps.isEmpty {
                    // The numbers are the join: the figure on a chip is the figure on its arrow.
                    CardMoves(moves: news.steps)
                }
                if !news.isFullyDrawn {
                    CardNote(localized("screen.arrowLimit", MateNews.arrowLimit))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 10)
        } else {
            // No news is news, and which piece of it is the session's (`mateQuiet`).
            VStack(alignment: .leading, spacing: 6) {
                if let quiet = session.mateQuiet { Text(quiet) }
            }
            .font(.caption)
            .foregroundStyle(Palette.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    // ------------------------------------------------------------------ 战术

    /// 战术 — the shot, named in the verbs a player declares in.
    ///
    /// **The switch did become the card.** 战术发现器 has a press of its own on the card, but
    /// arriving here is also a press: the swipe is the asking (docs/adr/0025). 杀招 shares the
    /// same probe, so opening one after the other does not stop it and start it again.
    @ViewBuilder private var tacticsBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.isFindingTactics {
                HStack(alignment: .top, spacing: 8) {
                    tacticAnswer
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { session.toggleLine() }
                    } label: {
                        Image(systemName: session.draws(.tactics) ? "arrow.up.right.circle.fill" : "arrow.up.right.circle")
                            .font(.subheadline)
                            .foregroundStyle(session.draws(.tactics) ? Palette.analysis : Palette.inkSoft)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(localized(session.draws(.tactics) ? "screen.hideArrows" : "screen.showArrows"))
                }
                if let tactic = session.tactic {
                    CardMoves(moves: session.steps(on: .tactics))
                    if tactic.line.count > MateNews.arrowLimit {
                        CardNote(localized("screen.arrowLimit", MateNews.arrowLimit))
                    }
                }
            } else {
                // Both findings are questions for the finder, so a deck with the finder off is a
                // deck nobody has asked anything yet. It used to be able to say 「你自己关掉的」
                // as well, off a flag nothing ever set: a silence with one cause has one
                // sentence (docs/adr/0040).
                Text(localized("screen.finderIdle"))
                    .font(.caption)
                    .foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    /// The finder's answer, under the chip that asked — the same place a scan writes.
    @ViewBuilder private var tacticAnswer: some View {
        if let prompt = session.tacticPrompt {
            Button {
                selected = nil
            } label: {
                Text(prompt)
                    .font(.caption)
                    .foregroundStyle(session.tactic == nil ? Palette.inkSoft : Palette.analysis)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .disabled(session.tactic?.line.isEmpty != false)
            .accessibilityLabel(prompt)
        }
    }
}
