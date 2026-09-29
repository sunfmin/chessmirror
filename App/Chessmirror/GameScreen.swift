import ChessmirrorKit
// For `onReceive` only: the sound setting travels through iCloud, and a notification is how a
// device hears that another one has changed it.
import Combine
import SwiftUI

/// The board, who is playing each colour, and what there is to do about it.
///
/// Each colour's controls sit on that colour's own side of the board: who is playing it, how long
/// the engine gets over a move, and — for whoever is on the clock — the one button that plays a
/// move and the line the engine would play. Turn the board round and they change places with it,
/// because they belong to the pieces and not to the screen. It also answers the question a fixed
/// deck could not: the button that plays a move is beside the half of the board it plays into.
///
/// The board always fills the screen's width. Settings expand inside their player's strip;
/// the page scrolls to accommodate them instead of shrinking the board or presenting a sheet.
struct GameScreen: View {
    let session: GameSession
    @Binding var path: [Step]
    var practiceNext: (() -> Void)?

    @Environment(EngineHost.self) var engine
    @Environment(GameLibrary.self) var library
    @Environment(\.dismiss) var dismiss
    @State var selected: Square?
    /// Set by a tap on a cell of the record strip, for the one cursor change that tap causes:
    /// the strip is not to move under the finger that is on it. A cell that was tapped was on
    /// the screen already, and sliding it to the middle is the record jumping away from where
    /// the eye just was. Every other way the cursor moves still centres.
    @State var isTappingStrip = false
    @State var promotion: PromotionRequest?
    /// The 收藏集 the heart just put the position in, for the line at the foot of the screen.
    @State var keptNotice: String?
    /// Whether the sets are open over the board — a long press on the heart, or a tap on a full
    /// one.
    @State var isChoosingSet = false
    /// Which side's own controls are open. Nobody's, unless somebody said otherwise — and then
    /// their answer stands for as long as the screen does. Never derived from the game: an unfold
    /// that answers to the moves is an unfold that opens and shuts under your thumb, and the board
    /// walks up and down the screen every time it does.
    ///
    /// That includes the way in. There used to be a guess made here on appearing — a board with
    /// nothing played on it was to open the side to move — and what it had come to do was set
    /// this to nil, which it already was. A fresh board and a game under way both open with every
    /// strip shut, and only a thumb opens one.
    @State var unfolded: PieceColour?
    /// The one hold on 让引擎走, if a thumb is on it. Its lifetime *is* the press: cancelled
    /// here on release and on the way off the screen, which is what makes the hold one call
    /// (`holdForMove`) that cannot run on with nobody holding it.
    @State var hold: Task<Move?, Never>?
    /// Whether a thumb is on 让引擎走 right now. The engine is thinking for exactly as long as it is —
    /// which is why this is read off the session rather than kept here as well. A screen holding
    /// its own copy of "a finger is down" is a screen that can be left holding it: a press that
    /// ends any way other than a release leaves the flag set, and the button then draws itself
    /// full and held with nobody touching it.
    var isAsking: Bool { session.thinking == .asked }

    struct PromotionRequest: Identifiable {
        let id = UUID()
        let moves: [Move]
    }

    var body: some View {
        GeometryReader { proxy in
            // The reader goes to the glass so the card can. The board is still sized for the
            // safe area — extra height at the bottom is the deck's, not a larger board.
            let arrangement = Arrangement(in: proxy.size)
            let side = arrangement.side
            if arrangement.isBeside {
                // The board with its own two bars on one side, everything about the game on the
                // other. Each scrolls on its own: a side's controls unfolding pushes its bar down
                // and not the record out of reach.
                HStack(spacing: 0) {
                    ScrollView {
                        boardColumn(side: side)
                            .frame(minHeight: proxy.size.height, alignment: .center)
                    }
                    .frame(width: side)
                    .scrollBounceBehavior(.basedOnSize)
                    Rectangle().fill(Palette.hairline).frame(width: 0.5)
                    ScrollView {
                        gameColumn
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        boardColumn(side: side)
                        gameColumn
                    }
                    .frame(width: side)
                    .frame(width: proxy.size.width)
                }
            }
        }
        .background(Palette.parchment)
        // A game opened from the 错题本 is opened *at* a mistake, and the arriving is the point:
        // the record walks to that Ply rather than being cut to it. Nothing happens for a game
        // opened any other way — there is no Ply to walk to.
        .task { await session.walkToArrival() }
        // The card stands on the glass. The home indicator is a mark on top of it, not a
        // margin that holds the deck off the bottom of the phone.
        // No title, and now nothing in its place either. The screen is a board; a word saying
        // "game" over the top of one is a row of a phone spent on something nobody was in any
        // doubt about. The engine's switch stood here for a while, which was better than the strip
        // of its own it had before — but a switch in the navigation bar is still a long way from
        // the bar it governs, and it has gone down to join it under the board.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.parchment, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(Palette.analysis)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 4) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }
                .accessibilityLabel(localized("library.games"))
                Spacer(minLength: 0)
                HeartButton(session: session, notice: $keptNotice, isChoosing: $isChoosingSet)
                Button { session.isFaceToFace.toggle() } label: {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(session.isFaceToFace ? Palette.analysis : Palette.inkSoft)
                        .frame(width: 44, height: 44)
                        .background(session.isFaceToFace ? Palette.analysis.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel(localized("board.faceToFace"))
                .accessibilityValue(localized(session.isFaceToFace ? "screen.on" : "noSlips.off"))
                flip.frame(width: 44, height: 44)
                Menu {
                    // 复盘 is not here. It was a destination, then a switch in the navigation bar,
                    // and it is a press on 重新打分 below; what it leaves is the curve behind the
                    // record and a Score on every Ply the eye can walk to (docs/adr/0015, 0016).
                    //
                    // Here rather than under the board, where it used to be the widest button on
                    // the screen. Taking a move off is not how a game is read — the record goes
                    // back through it without touching it, and playing something else from where
                    // you stopped keeps what it replaced (a Variation). What is left for this is
                    // the honest case: a move played by mistake, which is rare and belongs here.
                    Button {
                        selected = nil
                        session.undo()
                    } label: {
                        Label(localized("game.undo"), systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!session.canUndo)
                    Button {
                        path.append(.confirm(PositionProposal(reopening: session)))
                    } label: {
                        Label(localized("edit.title"), systemImage: "hand.point.up.left")
                    }
                    Toggle(isOn: Bindable(PlayerSettings.shared).isSoundOn) {
                        Label(
                            localized("game.sound"),
                            systemImage: PlayerSettings.shared.isSoundOn ? "speaker.wave.2" : "speaker.slash"
                        )
                    }
                    if let url = session.url {
                        ShareLink(item: url) {
                            Label(localized("game.exportPGN"), systemImage: "square.and.arrow.up")
                        }
                    }
                    // 先走 throws a game away, and it stays on offer for as long as the game lasts,
                    // because whose move it was is a field no photograph could settle and finding
                    // out it was guessed wrong three moves later is the normal way to find out.
                    // What it does is said where it is about to matter, rather than in a chip
                    // standing under the board for the rest of the game.
                    Section(localized("game.restart.explained")) {
                        Button(localized("game.whiteFirst")) {
                            selected = nil
                            session.restart(withSideToMove: .white)
                        }
                        .disabled(!session.canStart(withSideToMove: .white))
                        Button(localized("game.blackFirst")) {
                            selected = nil
                            session.restart(withSideToMove: .black)
                        }
                        .disabled(!session.canStart(withSideToMove: .black))
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .accessibilityLabel(localized("game.more", session.startingSideToMove.label))
            }
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(Palette.ink)
            .frame(height: 44)
            .background(Palette.parchment)
        }
        .sheet(isPresented: $isChoosingSet) {
            CollectionChooser(session: session)
                .presentationDetents([.medium, .large])
        }
        .overlay(alignment: .bottom) {
            if let kept = keptNotice {
                keptLine(kept)
            }
        }
        .task(id: keptNotice) {
            guard keptNotice != nil else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            keptNotice = nil
        }
        .onAppear {
            // From here the session follows the engine host itself — the engine arriving, the app
            // leaving and coming back — and this screen wires nothing. The deck deals itself when
            // it appears, which is after this: a view cannot appear before the one containing it.
            // What happens on the board is the session's to say and this screen's to make a noise
            // about. Read off `Sounds.current` when the event arrives rather than now, so whichever
            // Feedback is installed at that moment is the one that plays. `disappear` takes both
            // away, so neither can outlive this screen.
            session.appear(on: engine, library: library, hearing: { Sounds.current.hear($0) })
        }
        .onDisappear {
            hold?.cancel()
            session.disappear()
        }
        .confirmationDialog(
            localized("game.promotion"), isPresented: .constant(promotion != nil),
            titleVisibility: .visible
        ) {
            ForEach(promotion?.moves ?? [], id: \.uci) { move in
                Button(move.promotion?.label ?? move.uci) {
                    session.play(move)
                    promotion = nil
                }
            }
            Button(localized("cancel"), role: .cancel) { promotion = nil }
        }
    }


    /// 「已收藏到「喜爱」 · 换一个」: what the heart did, and the way to put it somewhere else.
    private func keptLine(_ name: String) -> some View {
        HStack(spacing: 10) {
            Label(localized("collection.kept", name), systemImage: "heart.fill")
                .font(.caption)
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
            Button(localized("collection.change")) {
                keptNotice = nil
                isChoosingSet = true
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Palette.analysis)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // ------------------------------------------------------------------ the two columns

    /// The board and what belongs to its two edges: each side's bar, and the standing line.
    func boardColumn(side: CGFloat) -> some View {
        VStack(spacing: 0) {
            playerBar(topColour).chromeType()
            board.frame(width: side, height: side)
            standing.padding(.horizontal, 12).frame(width: side).padding(.vertical, 6).chromeType()
            playerBar(bottomColour).chromeType()
        }
        .frame(width: side)
    }

    /// Everything about the game that is not the board: the drill's verdict, the record and what
    /// hangs off it, and the deck. Under the board on a phone, beside it on a wide window.
    var gameColumn: some View {
        VStack(spacing: 0) {
            if let practice = session.practice {
                DrillVerdictRow(drill: practice, next: practiceNext, leave: { path.removeAll() })
                    .chromeType()
            }
            VStack(spacing: 0) {
                record
                reviewRow
                wrongMoves
            }
            .chromeType()

            if session.dealsCards {
                DeckView(session: session, selected: $selected)
            }
        }
    }

    // ------------------------------------------------------------------ the deck

    /// One finding of the deck under the record — the kit's (`Deck.Card`, docs/adr/0025). The
    /// name stays here because the screen's open card, its animations and its tests all spell it
    /// `GameScreen.Card`; what a card *is* is not the screen's to say.
    typealias Card = Deck.Card

    // ------------------------------------------------------------------ reading the game


    /// The game where the player is looking, which is what everything on this screen is about.
    var viewed: Game { session.viewed }

    /// What the board draws — the trial's position when one is being tried out, and the studied
    /// The colour whose pieces stand at the top of the board, and so the colour whose controls
    /// belong above it. Flipping the board moves them, which is the whole idea.
    var topColour: PieceColour { session.orientation.top }

    var bottomColour: PieceColour { session.orientation.bottom }

}

extension View {
    /// The record row's frame — tinted and edged teal, a hairline at each end — for the rows about
    /// the Review, which are about the record: they say what its numbers are worth.
    func reviewChrome() -> some View {
        padding(.leading, 13)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(Palette.analysis.opacity(0.06))
            .overlay(alignment: .leading) { Rectangle().fill(Palette.analysis).frame(width: 3) }
            .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
    }
}

/// The tree, compressed to one column of ticks (docs/adr/0043). PGN writes a fork as
/// parentheses; this is that crease, thin enough to live in the scoresheet's own row. Each
/// sibling is a ring on a spine, the current one filled — a number sitting after the SAN was
/// being read as a move, which is the one thing a scoresheet cannot afford.
struct ForkRail: View {
    let current: Int
    let of: Int
    var tint: Color

    private var ticks: Int { min(max(of, 2), 4) }

    var body: some View {
        let shown = tickIndex(current)
        ZStack {
            Capsule().fill(tint.opacity(0.3)).frame(width: 1.5)
            VStack(spacing: ticks == 2 ? 7 : 3) {
                ForEach(1...ticks, id: \.self) { n in
                    let on = n == shown
                    Circle()
                        .strokeBorder(tint.opacity(on ? 1 : 0.38), lineWidth: 1.2)
                        .background(Circle().fill(on ? tint : Color.clear))
                        .frame(width: on ? 6 : 4.5, height: on ? 6 : 4.5)
                }
            }
        }
        .frame(width: 11, height: 28)
        .contentShape(Rectangle())
    }

    /// Which tick is lit: one per sibling up to four, and past four the ends stay the ends and
    /// everything between lights the second.
    private func tickIndex(_ current: Int) -> Int {
        if of <= 4 { return min(max(current, 1), ticks) }
        if current <= 1 { return 1 }
        if current >= of { return ticks }
        return min(2, ticks)
    }
}
