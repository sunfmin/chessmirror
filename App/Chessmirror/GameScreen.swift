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
    /// Which card of the deck to open on. Nil means the position decides, which is what the app
    /// does; a screenshot test passes one in to photograph a card that is not the one on top.
    var opening: Card?
    var practiceNext: (() -> Void)?

    @Environment(EngineHost.self) private var engine
    @Environment(GameLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Square?
    /// Set by a tap on a cell of the record strip, for the one cursor change that tap causes:
    /// the strip is not to move under the finger that is on it. A cell that was tapped was on
    /// the screen already, and sliding it to the middle is the record jumping away from where
    /// the eye just was. Every other way the cursor moves still centres.
    @State private var isTappingStrip = false
    @State private var promotion: PromotionRequest?
    @State private var isSoundOn = Sounds.current.isSoundOn
    /// Which side's own controls are open. Nobody's, unless somebody said otherwise — and then
    /// their answer stands for as long as the screen does. Never derived from the game: an unfold
    /// that answers to the moves is an unfold that opens and shuts under your thumb, and the board
    /// walks up and down the screen every time it does.
    @State private var unfolded: PieceColour?
    /// Whether the opening guess below has been made yet. Once, on the way in — not on every
    /// appearance, or coming back from a Review would shut what somebody had just opened.
    @State private var hasGuessedUnfold = false
    /// Whether the deck has been dealt yet. Once, for the same reason.
    @State private var hasDealt = false
    /// Whether a thumb is on 让引擎走 right now. The engine is thinking for exactly as long as it is —
    /// which is why this is read off the session rather than kept here as well. A screen holding
    /// its own copy of "a finger is down" is a screen that can be left holding it: a press that
    /// ends any way other than a release leaves the flag set, and the button then draws itself
    /// full and held with nobody touching it.
    private var isAsking: Bool { session.thinking == .asked }

    /// Which card of the deck under the record is showing.
    ///
    /// A kind rather than an index (see `Card`): the deck is dealt from the position, so an index
    /// would point at a different card every time the position changed shape.
    @State private var card: Card = .tactics
    /// Whether the mate line is drawn on the board. Set by arriving at the news, because a mate
    /// drawn is the whole of what the news is for, and cleared by leaving it.
    @State private var showsMateLine = false
    @State private var revealed: Set<Card> = []
    @State private var showsTacticLine = false
    struct PromotionRequest: Identifiable {
        let id = UUID()
        let moves: [Move]
    }

    /// A guess at what to open, made once and then never again.
    ///
    /// A board with nothing played on it opens the side to move, because that is the side every
    /// unanswered question is about — who is playing it, and whether it really is the one to move.
    /// A game already under way opens nothing. After this, only a thumb changes it.
    private func guessUnfold() {
        guard !hasGuessedUnfold else { return }
        hasGuessedUnfold = true
        unfolded = nil
    }

    /// Which card the deck opens on: the news when there is news, and the work this position is
    /// for otherwise.
    ///
    /// A mate is the one thing on this screen allowed to speak first, so 杀招 is where the deck
    /// opens when a search has already found one — a coloured tab is not a prompt (docs/adr/0025).
    private var opensOn: Card {
        if let opening { return opening }
        // News before work: a mate on the board is the reason 「直接给予提示」 was asked for.
        return .tactics
    }

    /// Deals the deck, once.
    ///
    /// Arriving is what asks the engine, and with both remaining cards being questions for it,
    /// dealing is no longer an arrival: the deck has to open on *something*, and a card that
    /// happened to be first is not somebody asking (docs/adr/0023). So the opening card is dealt
    /// at rest, with its own press on it, and only news arrives by itself — a mate is the one
    /// thing on this screen allowed to speak first, and a screen that was opened straight onto a
    /// card was opened there by somebody.
    private func deal() {
        guard !hasDealt else { return }
        hasDealt = true
        card = opensOn
        if session.dealsCards { arrive(at: card) }
    }

    var body: some View {
        GeometryReader { proxy in
            // The reader goes to the glass so the card can. The board is still sized for the
            // safe area — extra height at the bottom is the deck's, not a larger board.
            let side = Self.boardSide(in: proxy.size)
            VStack(spacing: 0) {
              ScrollView {
              VStack(spacing: 0) {
                playerBar(topColour).chromeType()
                board.frame(width: side, height: side)
                standing.padding(.horizontal, 12).frame(width: side).padding(.vertical, 6).chromeType()
                playerBar(bottomColour).chromeType()
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

                if session.dealsCards, !findings.isEmpty { deck }
              }
              .frame(width: proxy.size.width)
              }
            }
            .frame(maxWidth: .infinity)
        }
        .background(Palette.parchment)
        // A game opened from the 错题本 is opened *at* a mistake, and the arriving is the point:
        // the record walks to that Ply rather than being cut to it. Nothing happens for a game
        // opened any other way — there is no Ply to walk to.
        .task { await session.walkToArrival() }
        .onChange(of: viewed.state.fen) { _, _ in
            revealed.removeAll()
            showsMateLine = false
            showsTacticLine = false
        }
        .onChange(of: session.thinking) { _, now in
            guard now == nil, session.dealsCards else { return }
            session.adviseForCard()
        }
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
                    .disabled(!session.isAtLatest || session.game.plies.isEmpty)
                    Button {
                        path.append(.confirm(PositionProposal(reopening: session)))
                    } label: {
                        Label(localized("edit.title"), systemImage: "hand.point.up.left")
                    }
                    Toggle(isOn: $isSoundOn) {
                        Label(
                            localized("game.sound"),
                            systemImage: isSoundOn ? "speaker.wave.2" : "speaker.slash"
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
        .onAppear {
            guessUnfold()
            // The engine first, and then the deck: **dealing a card is an arrival**, and an arrival
            // spends a Stint. The session retunes before it returns, so the Stint the deal starts
            // is not cancelled a line later. From here the session follows the engine host itself —
            // the engine arriving, the app leaving and coming back — and this screen wires nothing.
            session.appear(on: engine, library: library)
            deal()
        }
        .onDisappear { session.disappear() }
        .onChange(of: isSoundOn) { _, isOn in Sounds.current.isSoundOn = isOn }
        // The setting travels between devices (docs/adr/0012), so it can change while this
        // screen is the one on show — and a toggle that disagrees with the sound is worse than
        // no toggle.
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
            isSoundOn = Sounds.current.isSoundOn
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

    // ------------------------------------------------------------------ the standing

    /// Who is ahead, said once, along the foot of the board.
    ///
    /// Controls and depth share a single-line header; the balance gets the full width below.
    /// Temporary explanations get their own space instead of squeezing either label into two
    /// lines. Interception can be switched off without hiding the position's assessment.
    private var standing: some View {
        // What the strip says, shows and accounts for is the session's to decide, as one value
        // (`Strip`); this draws it. The one thing the session cannot know is *why* it has no
        // engine — that is the host's fact — and with no engine there is nothing else it could
        // be saying, short of a game that is over.
        let strip = session.strip
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                noSlipsSwitch
                    .fixedSize(horizontal: true, vertical: false)
                // How far the game has gone without a slip, and how far since the last one:
                // 连正, read off the game rather than counted (CONTEXT.md). On the row that
                // names 把关 and on no row of its own.
                if let tally = strip.tally {
                    Text(localized("noSlips.tally", tally.run))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: true, vertical: false)
                        .contentTransition(.numericText())
                        .accessibilityLabel(localized("noSlips.tally", tally.run))
                }
                Spacer(minLength: 8)
                if engine.unavailableReason != nil, !viewed.isOver {
                    Text(localized("game.noEngine")).font(.caption).foregroundStyle(Palette.alarm)
                } else {
                    switch strip.voice {
                    case .finished(let line):
                        Text(line)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Palette.ink)
                    case .weighing:
                        Text(localized("noSlips.judging")).font(.caption).foregroundStyle(Palette.inkSoft)
                    case .refused(let refusal):
                        // What the take-back has to say, in the one place the eye is already
                        // reading: what the move cost and that it is not standing. The sentence
                        // was written for this and never read out — a piece came back and the app
                        // said nothing about why, which is indistinguishable from a dropped tap.
                        Text(refusal.sentence)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Palette.alarm)
                            .contentTransition(.opacity)
                            .accessibilityLabel(refusal.sentence)
                    case .best:
                        // The word, and for VoiceOver the number it stands for as well.
                        Text(localized("standing.best"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Palette.analysis)
                            .contentTransition(.opacity)
                            .accessibilityLabel(
                                localized("standing.best") + localized("clause.separator")
                                    + localized("standing.change", Standing.changeLabel(0))
                            )
                    case .change(let value):
                        let label = Standing.changeLabel(value)
                        Text(label)
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(value > 0 ? Palette.analysis : value < 0 ? Palette.alarm : Palette.inkSoft)
                            .contentTransition(.numericText())
                            .accessibilityLabel(localized("standing.change", label))
                    case .quiet:
                        EmptyView()
                    }
                }
                // The search has to account for itself (docs/adr/0020).
                if let depth = strip.depth {
                    Text(localized("game.depth", depth))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.inkSoft)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)

            if let bar = strip.bar {
                EvalBar(score: bar.score, orientation: session.orientation, finish: bar.finish)
            }

        }
        // A minimum rather than a height: the row used to be cut in half by its own frame the
        // moment the reader's text was bigger than the default, and the strip is the one place the
        // engine has to account for itself (docs/adr/0020).
        .frame(minHeight: 26)
        .animation(.easeInOut(duration: 0.35), value: session.moveChange)
    }

    /// One wrong move: the move, and what it cost. Pressing it is how the player asks what the
    /// move was asking for — the 应招 is nobody's business until somebody asks, which is the same
    /// rule every other answer on this screen is under (docs/adr/0034, docs/adr/0031).
    ///
    /// A 试招 wears the pale alarm rule at its foot that says 「已退回」; the move that stood wears
    /// the alarm tint instead, because it was not taken back — it is the move in the record, and
    /// this chip is the one place it can be asked about. Same chip otherwise: an imported game's
    /// 错招 all stood, and they want the same answer a refusal's chip gives.
    ///
    /// Shut while a 惩罚 exercise is open. That exercise is the same answer with the finding left
    /// to the player, and a chip that would hand it over is the exercise not being one.
    private func wrongToken(_ wrong: GameSession.WrongMove, index: Int) -> some View {
        let isOn = session.replyReading?.index == index
        let rest = wrong.stood ? AnyShapeStyle(Palette.alarm.opacity(0.12)) : AnyShapeStyle(Palette.chipRest)
        return Button {
            selected = nil
            session.readReply(at: index)
        } label: {
            HStack(spacing: 6) {
                Text(wrong.san).font(.notation)
                    .foregroundStyle(isOn ? Palette.parchment : Palette.ink)
                Text(Drop.figure(wrong.drop))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(isOn ? Palette.parchment : Palette.alarm)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(isOn ? AnyShapeStyle(Palette.analysis) : rest, in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottom) {
                if !isOn, !wrong.stood {
                    UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2)
                        .fill(Palette.alarm.opacity(0.35)).frame(height: 2)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .disabled(session.activePunishment != nil)
        .accessibilityLabel(wrong.san)
        .accessibilityValue(Drop.figure(wrong.drop))
        .accessibilityHint(localized("tried.reply.hint"))
    }

    /// The 应招 the move earned: the same numbered chips the cards use, numbered against the
    /// arrows on the board. One move is the refused one and the rest are the answers to it, so
    /// the row begins with the move the player made and not with what happened to it.
    @ViewBuilder private func replyRow(_ reading: GameSession.ReplyReading) -> some View {
        let chips = reading.steps.map { CardMoves.Move(step: $0.step, san: $0.san, isYours: $0.isYours) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(localized("tried.reply")).font(.caption).foregroundStyle(Palette.inkSoft)
                if reading.isAsking {
                    ProgressView().controlSize(.mini)
                    Text(localized("noSlips.judging")).font(.caption).foregroundStyle(Palette.inkSoft)
                }
                Spacer(minLength: 0)
                rejudgeControl(reading)
            }
            .frame(minHeight: 22)
            if !chips.isEmpty {
                CardMoves(moves: chips)
            } else if !reading.isAsking {
                Text(localized("tried.reply.none")).font(.caption).foregroundStyle(Palette.inkSoft)
            }
        }
        .padding(.leading, 2)
        .padding(.bottom, 4)
    }

    /// 复判, on the reading's own line (CONTEXT.md, 复判; docs/adr/0041): the depth the 试招 was
    /// judged at, when it carries one, and the one more thing the reading offers — the move judged
    /// again, deeper. While that runs, the button's place shows the depth climbing; when the
    /// number lands, the chip and the line change together and the depth here says how deep.
    /// Greyed while the engine is spoken for, and gone once the move is judged at 28.
    @ViewBuilder private func rejudgeControl(_ reading: GameSession.ReplyReading) -> some View {
        if let running = session.rejudging, running.index == reading.index {
            ProgressView().controlSize(.mini)
            Text(running.depth > 0 ? localized("game.depth", running.depth) : localized("noSlips.judging"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Palette.inkSoft)
        } else {
            if let depth = reading.move.depth {
                Text(localized("game.depth", depth))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.inkSoft)
            }
            let offer = session.rejudgeOffer(at: reading.index)
            if offer != .none {
                Button { session.rejudge(at: reading.index) } label: {
                    Text(localized("tried.rejudge", PositionSearches.deeperDepth))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(offer == .ready ? Palette.analysis : Palette.inkSoft.opacity(0.6))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Palette.chipRest, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(offer != .ready)
                .accessibilityHint(localized("tried.rejudge.hint"))
            }
        }
    }

    /// Interception is the page's only mode switch. Assessment and explicit answers are separate.
    private var noSlipsSwitch: some View {
        Button { session.setNoSlips(!session.isNoSlipsOn) } label: {
            HStack(spacing: 4) {
                Image(systemName: session.isNoSlipsOn ? "checkmark.shield" : "shield")
                Text(localized("noSlips.name"))
                Text(localized(session.isNoSlipsOn ? "screen.on" : "noSlips.off"))
            }
            .font(.caption)
            .foregroundStyle(session.isNoSlipsOn ? Palette.analysis : Palette.inkSoft)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized("noSlips.name"))
        .accessibilityValue(localized(session.isNoSlipsOn ? "screen.on" : "noSlips.off"))
        .disabled(session.isOccupied || (!engine.isReady && !session.isNoSlipsOn))
    }

    // ------------------------------------------------------------------ the two sides

    /// One colour's whole hand, on that colour's side of the board.
    ///
    /// Folded, it states two facts that used to be a line of prose under a chevron: who is playing
    /// this side, and how long they get. Unfolded, it is where those two are changed — and only
    /// one side unfolds at a time, because ten pills standing under a board for an hour is a
    /// settings panel where a game should be.
    ///
    /// The side on the clock gets two more things, and they are the reason the controls are here
    /// rather than in a deck: the button that plays a move, and the move it would play.
    private func playerBar(_ colour: PieceColour) -> some View {
        let live = session.isOnClock(colour)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Swatch(colour: colour)
                Text(colour.label)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.ink)
                if session.controller(for: colour) == .engine {
                    // The engine by name, with the rung it is on — 「Stockfish 18 · 1800」, or
                    // the name alone at 满力 — and pressing it is how another rung is picked
                    // (docs/adr/0038). On the bar rather than among the chips, because the rung
                    // is a fact about the opponent the way the clock is, and it changes mid-game
                    // the way a Controller does.
                    rungMenu
                    // What the engine gets over a move: the 搜索预算 every live position search
                    // gets, said so nobody waits for a clock that does not exist (docs/adr/0039).
                    Text(SearchSetting.shared.limit.label)
                        .font(.caption)
                        .foregroundStyle(Palette.inkSoft)
                } else {
                    Text(session.controller(for: colour).label)
                        .font(.caption)
                        .foregroundStyle(Palette.inkSoft)
                }
                if live {
                    Text(localized("game.toPlay"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.analysis)
                        .accessibilityLabel("\(colour.label) · \(localized("game.toPlay"))")
                    if session.board.state.inCheck {
                        Text(localized("game.inCheck"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.alarm)
                    }
                    if session.activePunishment == nil { advice(for: colour) }
                }
                Spacer(minLength: 4)
                if live, session.activePunishment == nil { action }
                unfoldButton(colour)
            }
            .frame(minHeight: 30)
            // One row of facts, and it stays one row. At an accessibility size the labels gave way
            // to each other by wrapping, so 「让引擎走」 stood in its capsule on two lines and the
            // bar grew a row taller — which is a row taken off the board for a button's label.
            .lineLimit(1)

            if unfolded == colour {
                chips(for: colour)
                    .padding(.top, 2)
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(live ? Palette.raised : Palette.parchment)
        // The side on the clock, said as a mark down the edge of its own bar rather than as a
        // word: it is the one thing on this screen that changes every single move.
        .overlay(alignment: .leading) {
            Rectangle().fill(live ? Palette.analysis : .clear).frame(width: 3)
        }
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
    }

    /// The one button down here that plays a move, in the bar of the side it would play for.
    ///
    /// Two states and they are not the same act: while the engine holds this colour's Controller
    /// it is already walking the move and the only thing left to do is stop waiting; the rest of
    /// the time it is an Asked Move, and how long the button is held is the time the engine gets.
    ///
    /// Which one is on screen turns on *whose* move the engine is walking, never on whether it is
    /// searching at all. An Asked Move searches too, and choosing on that swapped this button for
    /// the other one on the first instant of a press — which took the button out from under the
    /// finger, so it was never let go of and the move it was asked for was never played.
    @ViewBuilder private var action: some View {
        if session.thinking == .own {
            // Ten seconds or depth twenty is longer than anyone wants to sit through every move.
            // Stopping the search does not change which move it picks; it just stops waiting.
            Button { session.moveNow() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "forward.fill").font(.system(size: 9))
                    Text(localized("game.moveNow")).font(.caption.weight(.semibold))
                }
                .foregroundStyle(Palette.parchment)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Palette.analysis, in: Capsule())
            }
            .buttonStyle(.plain)
        } else if session.canPlayBestMove {
            HoldButton(
                label: localized("game.letEngine"),
                symbol: "cpu",
                isHeld: isAsking,
                fill: Double(session.searchProgress?.depth ?? 0) / SearchDepth.deepEnough,
                onPress: {
                    selected = nil
                    session.beginAskedMove()
                },
                onRelease: { session.endAskedMove() }
            )
            .accessibilityLabel(localized("game.letEngine"))
            .accessibilityHint(localized("game.letEngine.hint"))
        }
    }

    /// The engine's answer, in the row that already exists, for the side on the clock.
    ///
    /// **One move, not a line.** It used to be six of them — `d4 exd4 cxd4 Bb6 e5 d5` — which is a
    /// sentence in a language most people playing this have not learnt, spelling out a future
    /// nobody is obliged to walk into. What is useful is the move it would play now, which the
    /// board is already drawing as a teal arrow; this names the arrow. The number lives in the
    /// header, where it is one big figure instead of two small ones.
    ///
    /// A row of its own is what this cost before, in both bars, whether or not either had anything
    /// to say — fifty points of a phone, to keep the board from walking when the clock changed
    /// sides. In the row it needs no height of its own, and the board stands just as still.
    @ViewBuilder private func advice(for colour: PieceColour) -> some View {
        // Only what a thumb on 让引擎走 is being told. Nothing otherwise: a bar that said "no
        // opinion" every move would be an opinion about how much you are missing (docs/adr/0040).
        if isAsking {
            Text(askedReadout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Palette.analysis)
                .lineLimit(1)
        }
    }

    /// What a thumb on 让引擎走 is being told: how long the engine has had and how deep it has got.
    /// Before the first snapshot lands there is nothing to report but the bargain. How to finish is
    /// not said here — it is the button under the thumb, and it says it itself.
    private var askedReadout: String {
        guard let progress = session.searchProgress, progress.depth > 0 else {
            return localized("game.hold.deeper")
        }
        return localized("game.hold.progress", progress.seconds, progress.depth)
    }

    /// The ladder, behind the engine's name on its own bar. The rung picked is the game's at once
    /// — mid-move, if the engine is thinking — and the rung the next game starts at.
    private var rungMenu: some View {
        Menu {
            ForEach(Strength.ladder, id: \.self) { rung in
                Button {
                    session.setStrength(rung)
                    StrengthSetting.shared.strength = rung
                } label: {
                    if rung == session.strength {
                        Label(rung.label, systemImage: "checkmark")
                    } else {
                        Text(rung.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(rungTitle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.caption)
            .foregroundStyle(Palette.inkSoft)
            .contentShape(Rectangle())
        }
        .disabled(session.isOccupied)
        .accessibilityLabel(localized("strength"))
        .accessibilityValue(rungTitle)
    }

    /// 「Stockfish 18 · 1800」, or the name alone at 满力.
    private var rungTitle: String {
        let name = Controller.engine.playerName
        return session.strength == .full ? name : "\(name) · \(session.strength.label)"
    }

    private func unfoldButton(_ colour: PieceColour) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                unfolded = unfolded == colour ? nil : colour
            }
        } label: {
            Image(systemName: unfolded == colour ? "chevron.up" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(Palette.inkSoft)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            localized(
                unfolded == colour ? "game.settings.collapse" : "game.settings.expand",
                colour.label
            )
        )
    }

    /// Who plays this colour, and how long they get if it is the engine.
    private func chips(for colour: PieceColour) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(localized("game.who")).foregroundStyle(Palette.inkSoft)
                Spacer(minLength: 12)
                ForEach(Controller.allCases, id: \.self) { controller in
                    Button { session.setController(controller, for: colour) } label: {
                        Text(controller.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(session.controller(for: colour) == controller ? Palette.analysis : Palette.inkSoft)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(session.controller(for: colour) == controller
                                        ? Palette.analysis.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(controller == .engine && !engine.isReady)
                }
            }
            .frame(minHeight: 36)

            if session.controller(for: colour) == .engine {
                HStack(spacing: 8) {
                    Text(localized("game.perMove")).foregroundStyle(Palette.inkSoft)
                    Spacer()
                    Text(SearchSetting.shared.limit.label).foregroundStyle(Palette.ink)
                }
                .padding(.vertical, 5)
            }

            Rectangle().fill(Palette.hairline).frame(height: 0.5).padding(.vertical, 5)
            Toggle(localized("noSlips.name"), isOn: Binding(
                get: { session.isNoSlipsOn },
                set: { session.setNoSlips($0) }
            ))
            .toggleStyle(SettingToggleStyle(label: localized("noSlips.name")))
            .disabled(session.isOccupied || (!engine.isReady && !session.isNoSlipsOn))
            Toggle(localized("punish.toggle"), isOn: Binding(
                get: { session.findsPunishment }, set: { session.findsPunishment = $0 }
            ))
            .toggleStyle(SettingToggleStyle(label: localized("punish.toggle")))
            .disabled(session.activePunishment != nil)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.hairline, lineWidth: 0.5))
        .padding(.bottom, 3)
    }

    private struct SettingToggleStyle: ToggleStyle {
        let label: String
        func makeBody(configuration: Configuration) -> some View {
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 10) {
                    configuration.label
                        .font(.caption)
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        Circle().fill(configuration.isOn ? Palette.analysis : Palette.inkSoft.opacity(0.45))
                            .frame(width: 5, height: 5)
                        Text(localized(configuration.isOn ? "screen.on" : "noSlips.off"))
                    }
                    .font(.caption)
                    .foregroundStyle(configuration.isOn ? Palette.analysis : Palette.inkSoft)
                    .frame(width: 42, height: 24)
                    .background(configuration.isOn ? Palette.analysis.opacity(0.10) : Palette.chipRest,
                                in: RoundedRectangle(cornerRadius: 6))
                }
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(localized(configuration.isOn ? "screen.on" : "noSlips.off"))
        }
    }

    private func arrow(
        _ symbol: String, label: String, enabled: Bool, width: CGFloat = 30,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(Palette.inkSoft)
                .frame(width: width, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    // ------------------------------------------------------------------ the record

    /// The moves, as one line you push sideways, over the shape of the game.
    ///
    /// A game is read a move at a time, so it is ruled a move at a time: one card per move number
    /// with both halves in it, the way a scoresheet is. Tapping a half is how you go back to it —
    /// which is browsing and not undoing, so the game is untouched and every move is still there.
    /// The arrows walk it a ply at a time for the times when the eye is following rather than
    /// looking something up.
    ///
    /// Behind the cards, when there is a Review to draw one from, is the curve — as a ground and
    /// not as a second control. It used to be 110 points of the reading below, which on a phone is
    /// most of the window a question has to fit in; here it costs nothing, because the strip was
    /// already saying where in the game the eye is and the curve says the same thing in a shape.
    /// It scrolls with the cards, and spans exactly what they span, so the dip under a card is the
    /// dip that card's move caused. A chart behind moves it does not describe would be worse than
    /// no chart — and the correspondence is only as exact as the cards are even, which is why this
    /// is a ground and the numbers are said in words underneath.
    private var record: some View {
        HStack(spacing: 8) {
            arrow("chevron.left", label: localized("record.previous"), enabled: session.cursor > 0, width: 14)
            { walk(-1) }
            moveStrip
            arrow(
                "chevron.right", label: localized("record.next"), enabled: !session.isAtLatest
            ) { walk(1) }
            // The way back to the present, beside the arrows that walked away from it. It used to
            // be a sentence above the board — "在看第 7/8 步 · 回到最新" — which spent a row saying
            // where the eye was, and where the eye is is what this whole strip is drawing.
            if !session.isAtLatest {
                arrow("forward.end.fill", label: localized("record.latest"), enabled: true) {
                    selected = nil
                    session.jumpToLatest()
                }
            }
        }
        .frame(minHeight: 30)
        .padding(.leading, 13)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(Palette.analysis.opacity(0.06))
        .overlay(alignment: .leading) {
            Rectangle().fill(Palette.analysis).frame(width: 3)
        }
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
        .padding(.top, 8)
    }

    /// The Review an imported game is still owed, in one row under the record (docs/adr/0016).
    ///
    /// An imported game arrives with no cost on any of its moves: it has no 错招 to mark and puts
    /// nothing in the 错题本, and a game like that must not look like a clean one. So the row says
    /// it has not been looked at and offers the look — a press, not something that starts itself,
    /// because it is seconds of engine per move. While it runs the row is the count of positions
    /// settled; when it lands the row says what it found and that the book has it, and the 错招
    /// row below fills in on its own, because it reads the same game. Absent for every game that
    /// is not an unreviewed import, which is every game the player played here.
    @ViewBuilder private var reviewRow: some View {
        if let progress = session.reviewProgress {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    progress.total > 0
                        ? localized("review.progress", progress.judged, progress.total)
                        : localized("import.status.queued")
                )
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Palette.ink)
                ProgressView(value: progress.fraction)
                    .tint(Palette.analysis)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .reviewChrome()
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        } else if session.awaitsReview {
            let failed = session.reviewNews == .failed
            HStack(spacing: 10) {
                Text(localized(failed ? "review.failed" : "review.offer"))
                    .font(.footnote)
                    .foregroundStyle(failed ? Palette.alarm : Palette.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { session.review() } label: {
                    Text(localized(session.canReview ? "review.start" : "review.waiting"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(session.canReview ? Palette.raised : Palette.inkSoft)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            session.canReview ? Palette.analysis : Palette.chipRest, in: Capsule()
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!session.canReview)
            }
            .reviewChrome()
        } else if case .done(let count) = session.reviewNews {
            Label(
                count > 0 ? localized("review.done", count) : localized("review.done.clean"),
                systemImage: "checkmark.circle.fill"
            )
            .font(.footnote)
            .foregroundStyle(Palette.analysis)
            .frame(maxWidth: .infinity, alignment: .leading)
            .reviewChrome()
        }
    }

    /// The game's own 错招, in one row under the record (docs/adr/0036).
    ///
    /// The record strip marks them, which is enough to find one while reading a game. This is for
    /// the other errand — 「这一局我哪儿走错了」 asked as a question — where what is wanted is the
    /// stops in order and a way to be taken to each. A chip walks the board to its position; 下一处
    /// is the whole of the reading.
    ///
    /// Absent when there is nothing to say. A game nobody got anything wrong in has no row, and
    /// neither has a game that has not been measured at all.
    /// This game's 错题, and the 试招 tried at the position the eye is on — **one framed strip**,
    /// because they are one subject seen at two scopes: where in this game the player went wrong,
    /// and what they reached for when they got there (docs/adr/0036, docs/adr/0037).
    ///
    /// The frame is the app's own rail rather than a new idiom: an alarm edge down the left, which
    /// is what the record's teal edge and a player bar's edge already say — 「this row is about
    /// this」 — with the words kept for VoiceOver rather than spent on a phone's width. The two
    /// registers share that edge and one corner radius, so they read as one object; the lower one
    /// is not a second list but the upper one *at the position on the board*, so walking to a 错题
    /// slides its moves out, and a position where nothing was refused has none to show.
    @ViewBuilder private var wrongMoves: some View {
        let slips = session.slips
        let attempts = session.visibleWrongs
        let exercise = session.activePunishment
        let answered = session.punishment?.revealedMove
        if !slips.isEmpty || !attempts.isEmpty || exercise != nil || answered != nil {
            VStack(spacing: 0) {
                if !slips.isEmpty { slipTiles(slips) }
                if !slips.isEmpty, !attempts.isEmpty {
                    Rectangle().fill(Palette.hairline).frame(height: 0.5).padding(.leading, 13)
                }
                if !attempts.isEmpty { wrongTokens(attempts) }
                // And the 应招, when one of those attempts has been asked about: the same frame,
                // because it is the answer to the same question (docs/adr/0034).
                if !attempts.isEmpty, session.activePunishment == nil,
                    let reading = session.replyReading {
                    Rectangle().fill(Palette.hairline).frame(height: 0.5).padding(.leading, 13)
                    replyRow(reading)
                        .padding(.leading, 13)
                        .padding(.trailing, 8)
                }
                if exercise != nil || answered != nil {
                    Rectangle().fill(Palette.hairline).frame(height: 0.5).padding(.leading, 13)
                    punishRegister(exercise: exercise, answered: answered)
                }
            }
            // The same shape as the rows above and below it — full width, square corners, a bar
            // down the leading edge and a hairline at each end — because it is a row of the same
            // page and not a card of its own. It is the record row's twin: that one is tinted teal
            // and edged teal for the eye, this one alarm for the mistakes.
            .background(Palette.alarm.opacity(0.06))
            .overlay(alignment: .leading) { Rectangle().fill(Palette.alarm).frame(width: 3) }
            .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
            .animation(.snappy(duration: 0.22), value: attempts.count)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(localized("slips.here", slips.count))
        }
    }

    /// The 惩罚 exercise, when one is open — the same subject one step further on: not what
    /// happened here but what the position you are standing on has to answer. Last, because it is
    /// the only thing in the strip that asks something of the player (docs/adr/0031, issue 38).
    @ViewBuilder private func punishRegister(exercise: Punishment?, answered: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let exercise {
                Text(localized(exercise.wasIncorrect ? "punish.again" : "punish.prompt"))
                if exercise.isJudging { ProgressView() }
                HStack(spacing: 10) {
                    Button(localized("noSlips.reveal")) { exercise.reveal() }
                    Button(localized("punish.skip")) { exercise.skip() }
                }
            }
            if let answered { Text(localized("punish.answer", answered)) }
        }
        .font(.footnote)
        .padding(.leading, 13)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The positions this game has something wrong at, in the order they happen, with 下一处 to be
    /// walked to the next one.
    private func slipTiles(_ slips: [Slip]) -> some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(slips) { slip in slipTile(slip) }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            if let next = session.nextSlip {
                Button {
                    jumpTo(slip: next)
                } label: {
                    Image(systemName: "arrow.right.to.line")
                        .font(.caption2)
                        .foregroundStyle(Palette.analysis)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localized("slips.next"))
                .accessibilityHint(localized("slips.next.hint"))
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 8)
    }

    /// One 错题: the board that was on the screen, and the two figures that say whether to stop —
    /// where in the game it is, and what it cost.
    ///
    /// **The picture is the name**, which is the answer this app already gave for the 错题本: a FEN
    /// is not a name anybody recognises and neither is "Sicilian, Najdorf", and what a person
    /// recognises is the board they were looking at when they got it wrong. The number is the
    /// scoresheet's — the same figure the cell above carries — because that is the one thing that
    /// separates two positions of the same game. The cost is full strength when the 入列线 says the
    /// player still owes it and held back when it is only written down (docs/adr/0027), and `×N` is
    /// the fact that one position takes N wrong moves — which is why the entry is not named after
    /// one of them.
    ///
    /// **The figures sit under the board, not beside it.** They are a caption on the picture they
    /// belong to, and a tile no wider than its own board is one the row fits nearly twice as many
    /// of — which is the errand: seeing the whole game's worth of wrong places at once, and
    /// pressing the one you mean.
    private func slipTile(_ slip: Slip) -> some View {
        let on = session.cursor == slip.positionPly
        let owed = slip.isWorthDrilling(session.lines)
        return Button {
            jumpTo(slip: slip)
        } label: {
            VStack(spacing: 3) {
                // Sixty-four points, which is the size the 错题本 already uses for the same job:
                // the board is the name of a position, and a name has to be legible.
                thumbnail(slip.position, side: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(
                                on ? Palette.analysis : Palette.hairline,
                                lineWidth: on ? 1.5 : 0.5
                            )
                    )
                // One Text and not three in a row, because the line has to shrink as a line:
                // laid out as separate views the longest of them — 「现在 ×2 −30%」 — spent the
                // width on the first two figures and truncated the cost, which is the one figure
                // that says whether to stop. Squeezed rather than wrapped or cut: none of the
                // three parts is decoration.
                slipCaption(slip, owed: owed)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(width: 64)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(slipSpoken(slip))\(localized("clause.separator"))\(Drop.cost(slip.drop))\(slip.wrong.count > 1 ? localized("clause.separator") + localized("slips.wrong", slip.wrong.count) : "")"
        )
        .accessibilityHint(localized("slips.hint"))
    }

    /// The caption under a 错题's board: where in the game, how many wrong moves were tried there,
    /// and what the worst of them cost — as one Text, so it is one thing that shrinks to the
    /// board's width rather than three that fight over it.
    private func slipCaption(_ slip: Slip, owed: Bool) -> Text {
        var line = Text(slipNumber(slip))
            .font(.caption2.monospacedDigit().weight(.medium))
            .foregroundStyle(Palette.ink)
        if slip.wrong.count > 1 {
            line = line
                + Text(" ×\(slip.wrong.count)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(Palette.alarm)
        }
        return line
            + Text(" " + Drop.figure(slip.drop))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(owed ? Palette.alarm : Palette.inkSoft)
    }

    /// The wrong moves made at the position on the board, newest first, under the positions
    /// they belong to — the lower register of the same strip.
    private func wrongTokens(_ wrongs: [GameSession.WrongMove]) -> some View {
        // Whether anything here was taken back. A row of refusals is led by an ✕; a row that is
        // only the move that stood — an imported game's — by a mark that says it was played.
        let returned = wrongs.contains { !$0.stood }
        return HStack(spacing: 8) {
            // A mark and nothing else: the word — 「已退回」 or 「走了的错招」 — is what VoiceOver reads
            // out for it rather than sixty points of the row.
            Image(systemName: returned ? "xmark" : "exclamationmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Palette.alarm)
                .frame(width: 18)
                .accessibilityLabel(localized(returned ? "noSlips.returned" : "wrong.stood"))
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(wrongs.reversed().enumerated()), id: \.offset) { offset, wrong in
                        wrongToken(wrong, index: wrongs.count - 1 - offset)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.leading, 13)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// A position in the words a scoresheet gives it: the move number and whose move it is — the
    /// same figure the cell above carries, so the eye can match a tile to the strip.
    ///
    /// **Including the position the game stops on**, which said 「现在」 and now says the number of
    /// the move nobody has played there yet. It has one: a 错招 at the end of a game sits at the Ply
    /// one past the last move (docs/adr/0037), and when a move is finally played there that is the
    /// Ply it takes. Every tile in the row is then the same kind of label — 「1.」「2…」「3.」 — which
    /// is what a row of tiles wants, rather than one of them being a word in the middle of figures.
    private func slipNumber(_ slip: Slip) -> String {
        session.game.moveLabel(ofPly: slip.ply)
    }

    /// The same place said out loud, in the number the record counts in.
    private func slipSpoken(_ slip: Slip) -> String {
        slip.ply > session.game.plies.count
            ? localized("record.now")
            : localized("record.ply", slip.ply)
    }

    /// Takes the board to a 错题 and leaves the eye on the position the move was played from — the
    /// one to try again from.
    ///
    /// Straight there, not walked there: the walk belongs to *opening* a game at a mistake, where
    /// the arriving is the point. Pressing a tile is looking something up in a game already on the
    /// screen, and a player who has picked a position out of a list has already said which one.
    private func jumpTo(slip: Slip) {
        selected = nil
        session.jump(toPly: slip.positionPly)
    }

    /// The curve as a ground. It marks no cursor of its own — the card on the cursor is already
    /// filled, and a second mark is a second answer. History feedback is available in practice
    /// too: unknown positions remain unknown, and judgements and reviews supply the same curve.
    private func curveGround(_ curve: ScoreCurve) -> some View {
        EvalCurve(curve: curve)
        .accessibilityLabel(localized("record.curve"))
        .accessibilityValue(localized("record.ply", curve.lastKnownPly ?? 0))
    }

    private var moveStrip: some View {
        // Walked once for the whole strip: the marks are a lookup per half, and the walk behind
        // them is a rules probe per Ply.
        let slips = session.slipByPosition
        // Whether the record has a line of costs to draw at all: none when nothing in the game
        // has been measured, so a game nobody judged is the strip exactly as it was.
        let costs = session.game.hasCosts
        return ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    openingCell
                    ForEach(session.game.scoresheet) { card in
                        HStack(spacing: 6) {
                            Text("\(card.number)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Palette.inkSoft)
                                .frame(minWidth: 13, alignment: .trailing)
                            if let white = card.white { half(white, slips[white.ply], costs: costs) }
                            if let black = card.black { half(black, slips[black.ply], costs: costs) }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Palette.chipRest, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                .padding(.horizontal, 2)
                .background {
                    let curve = session.curve
                    if curve.isDrawable { curveGround(curve) }
                }
            }
            .scrollIndicators(.hidden)
            // Where the eye is, kept in the middle of the strip as it moves — a record that
            // has scrolled off the position on the board is a record of somebody else's game.
            // Not when the move was a tap on the strip itself: that cell is under the finger,
            // and the record stays where the finger found it.
            .onChange(of: session.cursor, initial: true) { _, now in
                if isTappingStrip {
                    isTappingStrip = false
                    return
                }
                withAnimation(.snappy(duration: 0.2)) { scroller.scrollTo(now, anchor: .center) }
            }
            .simultaneousGesture(forkSwipe)
            .accessibilityHint(session.forkPly == nil ? "" : localized("record.branch"))
        }
    }

    /// Vertical swipe on the strip walks the tree: up is the next sibling, down the previous
    /// (docs/adr/0043). The strip scrolls sideways, so a swipe up or down is free for this.
    private var forkSwipe: some Gesture {
        DragGesture(minimumDistance: 24).onEnded { value in
            let dy = value.translation.height
            let dx = value.translation.width
            guard abs(dy) > abs(dx) * 1.2, abs(dy) > 28 else { return }
            selected = nil
            withAnimation(.snappy(duration: 0.22)) {
                session.cycleFork(by: dy < 0 ? 1 : -1)
            }
        }
    }

    /// The position the game began in, at the head of its own record. It is a place in the game
    /// like any other, and without it there is no way back to it in one tap.
    private var openingCell: some View {
        let slip = session.slipByPosition[0]
        let on = session.cursor == 0
        // One name for one place. It used to say 「从这里开始走」 while the game had no moves in it,
        // which is an instruction standing where every other cell in the strip names a place.
        let name = localized("record.opening")
        return Button { walk(to: 0) } label: {
            Text(name)
                .font(.caption)
                .foregroundStyle(on ? Palette.parchment : Palette.inkSoft)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    on ? AnyShapeStyle(Palette.analysis) : AnyShapeStyle(Palette.chipRest),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay(alignment: .bottom) { slipMark(slip, on: on) }
        }
        .buttonStyle(.plain)
        .id(0)
        .accessibilityLabel(spoken(name, cost: nil, slip: slip))
    }

    /// What a cell says out loud: its name, what the move cost if it has been measured, and —
    /// when the mark at its foot is there — that the player went wrong from this position.
    private func spoken(_ name: String, cost: Double?, best: Bool = false, slip: Slip?) -> String {
        var clauses = [name]
        if best {
            clauses.append(localized("standing.best"))
        } else if let cost {
            clauses.append(Drop.cost(max(0, cost)))
        }
        if let slip { clauses.append(localized("record.slipMark", Drop.points(slip.drop))) }
        return clauses.joined(separator: localized("clause.separator"))
    }

    /// The mark a 错招 leaves at the foot of the position it was made at.
    ///
    /// An overlay rather than a row, so a card with a mistake in it is exactly as tall as one
    /// without: the curve behind the strip is drawn against these cards being even. Two weights on
    /// the one scale the app already has (docs/adr/0027): pale is what the 记录线 put in the file,
    /// the alarm colour is what the 入列线 says the player still owes.
    @ViewBuilder private func slipMark(_ slip: Slip?, on: Bool) -> some View {
        if let slip {
            UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2)
                .fill(Palette.alarm.opacity(slip.isWorthDrilling(session.lines) ? 1 : 0.5))
                .frame(height: 3)
        }
    }

    /// One half of a move, and — when the player got a position wrong here — a mark at its foot.
    ///
    /// The `slip` passed in is the one whose *position* this cell is, which is the position before
    /// the next move rather than after this one (see `slipByPosition`).
    ///
    /// With `costs`, every cell carries a second line — what the move cost, by whatever number the
    /// game holds for it (`Game.cost(atPly:)`) — so the whole row grows together and the curve
    /// behind it is drawn against cells that are still even.
    private func half(_ cell: Game.Half, _ slip: Slip?, costs: Bool) -> some View {
        let on = cell.ply == session.cursor
        let cost = costs ? session.game.cost(atPly: cell.ply) : nil
        let best = costs && session.game.isBest(atPly: cell.ply)
        // A 树枝 is inked in its own colour, so a line tried from an earlier position cannot be
        // mistaken for the game (docs/adr/0043). A cell on a fork is outlined rather than filled
        // when the eye is on it, so the rail beside it reads as part of the same cell.
        let mark = cell.isTrunk ? Palette.ink : Palette.mine
        let filled = on && !cell.isFork
        return HStack(spacing: 3) {
            if cell.isFork {
                Button {
                    selected = nil
                    withAnimation(.snappy(duration: 0.22)) {
                        session.cycleFork(atPly: cell.ply - 1, by: 1)
                    }
                } label: {
                    ForkRail(current: cell.branchNumber, of: cell.siblingCount, tint: mark)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localized("record.fork"))
                .accessibilityValue(cell.spoken)
                .accessibilityHint(localized("record.fork.hint"))
            }
            Button { walk(to: cell.ply) } label: {
                VStack(spacing: 1) {
                    Text(cell.san)
                        .font(.footnote.weight(on ? .medium : .regular))
                        .foregroundStyle(filled ? Palette.parchment : mark)
                    if costs { costCaption(cost, best: best, on: filled) }
                }
                .padding(.horizontal, cell.isFork ? 3 : 5)
                .padding(.vertical, 2)
                .background {
                    if filled {
                        RoundedRectangle(cornerRadius: 5).fill(Palette.analysis)
                    } else if on {
                        RoundedRectangle(cornerRadius: 5).stroke(mark, lineWidth: 1.2)
                    }
                }
                .overlay(alignment: .bottom) { slipMark(slip, on: on) }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            // Said the way somebody reading a game aloud says it. A bare "Nf6" out of VoiceOver
            // is a move with no place in the game, and place is the whole of what this strip is
            // for — and what it cost, and a mistake made from here, are worth saying out loud too.
            .accessibilityLabel(spoken(cell.spoken, cost: cost, best: best, slip: slip))
            .accessibilityHint(localized("record.jump"))
        }
        .id(cell.ply)
    }

    /// The move's 掉幅 under it, in the app's one figure. 「最佳」 for the engine's own first
    /// choice, a muted 「0」 for another move that cost nothing — that is information: the move
    /// was right — and a blank of the same height under a move nobody has measured, which is
    /// not the same thing as zero.
    private func costCaption(_ cost: Double?, best: Bool, on: Bool) -> some View {
        let points = cost.map { Drop.points(max(0, $0)) }
        let figure: String
        switch points {
        case nil: figure = " "
        case 0: figure = best ? localized("record.best") : "0"
        case let points?: figure = "−\(points)%"
        }
        let ink = on ? Palette.parchment : Palette.inkSoft
        let colour: Color = best ? (on ? Palette.parchment : Palette.analysis)
            : points == 0 ? ink.opacity(0.55) : ink
        return Text(verbatim: figure)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(colour)
    }

    /// 战术 — the shot, named in the verbs a player declares in.
    ///
    /// **The switch did become the card.** 战术发现器 has a press of its own on the card, but
    /// arriving here is also a press: the swipe is the asking, and leaving turns it off again
    /// unless somebody flipped it by hand (docs/adr/0025). 杀招 shares the same probe, so swiping
    /// between the two does not stop it and start it again.
    @ViewBuilder private var tacticsBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.isFindingTactics {
                HStack(alignment: .top, spacing: 8) {
                    tacticAnswer
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { showsTacticLine.toggle() }
                    } label: {
                        Image(systemName: showsTacticLine ? "arrow.up.right.circle.fill" : "arrow.up.right.circle")
                            .font(.subheadline)
                            .foregroundStyle(showsTacticLine ? Palette.analysis : Palette.inkSoft)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(localized(showsTacticLine ? "screen.hideArrows" : "screen.showArrows"))
                }
                if let tactic = session.tactic {
                    CardMoves(moves: tactic.line.enumerated().map { index, san in
                        CardMoves.Move(step: index + 1, san: san,
                            isYours: session.tacticArrows.first { $0.step == index + 1 }?.isYours ?? index.isMultiple(of: 2))
                    })
                    if tactic.line.count > MateNews.arrowLimit {
                        CardNote(localized("screen.arrowLimit", MateNews.arrowLimit))
                    }
                }
            } else {
                // The deck has to open on one of its two cards and both of them are questions for
                // the engine, so the card in front is dealt at rest and nobody has asked anything
                // yet. It used to be able to say 「你自己关掉的」 as well, off a flag nothing ever
                // set: a silence with one cause has one sentence (docs/adr/0040).
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

    // ------------------------------------------------------------------ the deck

    /// One card of the deck under the record (docs/adr/0025).
    ///
    /// A kind rather than an index, because which card is dealt comes from the position — news
    /// opens on 杀招 and everything else on 战术 — and a card that cannot answer here says so on
    /// its own face rather than disappearing. An index would point at a different card every time
    /// the position changed shape.
    enum Card: Hashable {
        case mate, tactics
    }

    /// Every card, in one order, whatever the position.
    ///
    /// **The deck does not change shape.** Two cards that never move can be learnt; a card that
    /// cannot answer here says so on its own face.
    private var cards: [Card] {
        [.mate, .tactics]
    }

    /// Findings are invitations, never navigation: absent results occupy no space.
    private var findings: [Card] {
        cards.filter { $0 == .mate ? session.mateNews != nil : session.tactic != nil }
    }

    private var deck: some View {
        VStack(spacing: 8) {
            ForEach(findings, id: \.self) { kind in
                VStack(spacing: 0) {
                    discovery(kind)
                    if kind == card, revealed.contains(kind) {
                        body(of: kind)
                    }
                }
                .background(Palette.analysis.opacity(0.06))
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private func body(of kind: Card) -> some View {
        if !revealed.contains(kind) {
            discovery(kind)
        } else {
            switch kind {
            case .mate: cardFrame(kind) { mateBody }
            case .tactics: cardFrame(kind) { tacticsBody }
            }
        }
    }

    private func discovery(_ kind: Card) -> some View {
        let found = kind == .mate ? session.mateNews != nil : session.tactic != nil
        let searching = session.isSearching || session.isProbingTactics
        let title = found
            ? localized(kind == .mate ? "discovery.mateFound" : "discovery.tacticFound")
            : "\(kind.title) · \(localized(searching ? "discovery.checking" : "discovery.none"))"
        return Button {
            guard found else { return }
            withAnimation(.snappy(duration: 0.22)) {
                let wasExpanded = kind == card && revealed.contains(kind)
                card = kind
                revealed.removeAll()
                if !wasExpanded {
                    session.notePracticeHelp()
                    revealed.insert(kind)
                }
                showsMateLine = kind == .mate && revealed.contains(kind)
                showsTacticLine = kind == .tactics && revealed.contains(kind)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: kind == .mate ? "flag.fill" : "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.analysis)
                    .frame(width: 14)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 4)
                if found {
                    Image(systemName: kind == card && revealed.contains(kind) ? "chevron.up" : "chevron.down")
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
        _ kind: Card, @ViewBuilder body: () -> Content
    ) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                body()
                if revealed.contains(kind), kind == card, wantsAdvice(kind) {
                    if let progress = session.standingProgress {
                        HStack(spacing: 6) {
                            if isCardSearching(kind) { ProgressView().controlSize(.mini) }
                            Text(localized(isCardSearching(kind) ? "noSlips.judging" : "search.reached"))
                            Text(localized("game.depth", progress.depth))
                        }
                        .font(.caption2)
                        .foregroundStyle(Palette.inkSoft)
                        .padding(.horizontal, 16)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
    }

    /// A card's body: a scrolling column that fades at the bottom exactly when there is more of it
    /// than fits.
    ///
    /// The fade used to be unconditional and was painted on the scroll view rather than in it, so
    /// it never moved: the last line of the tallest cards stayed washed out even scrolled all the
    /// way down, and a card whose whole body fitted wore a fade promising a paragraph that was not
    /// there. So the viewport is asked instead — content against offset — and the column ends with
    /// the fade's own height of padding, so nothing anybody has to read is ever under it.
    private struct CardScroll<Content: View>: View {
        private let content: Content
        @State private var hasMore = false

        init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        var body: some View {
            ScrollView {
                content
                    .padding(.bottom, CardFade.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y
                    - geometry.containerSize.height > 1
            } action: { _, more in
                hasMore = more
            }
            .overlay(alignment: .bottom) { if hasMore { CardFade() } }
        }
    }

    private var mateInk: Color {
        guard let news = session.mateNews else { return Palette.ink }
        return news.isOurs ? Palette.mine : Palette.alarm
    }

    /// What arriving at a card does, and what leaving one undoes.
    ///
    /// **The card you are on is the card that acts.** Arriving turns its layer on — the scan, the
    /// walk, the squares, the mate's arrows, the finder — and leaving turns that layer off again,
    /// so the board is only ever drawing the one card in front of you and never the leftovers of
    /// three you swiped past (docs/adr/0025).
    ///
    /// A swipe therefore spends a Stint where the card reads a Line — 杀招, 战术, 五步 —
    /// the first time this position is asked about, even during Practice. What that search found
    /// is kept, so paging to another card of the same Ply does not wind the clock again.
    private func turn(to now: Card, from was: Card) {
        selected = nil
        leave(was, for: now)
        arrive(at: now)
    }

    private func leave(_ was: Card, for now: Card) {
        switch was {
        case .mate:
            showsMateLine = false
            if !wantsFinder(now) { session.leaveFinder() }
        case .tactics: if !wantsFinder(now) { session.leaveFinder() }
        }
    }

    private func arrive(at now: Card) {
        switch now {
        case .mate:
            showsMateLine = revealed.contains(.mate)
            session.arriveAtFinder()
        case .tactics: session.arriveAtFinder()
        }
        if wantsAdvice(now) { session.adviseForCard() }
    }

    /// Both cards read a Line, so both spend a Stint on arrival, even during Practice.
    private func wantsAdvice(_ kind: Card) -> Bool {
        switch kind {
        case .mate, .tactics: true
        }
    }

    /// Whether this card currently has a search in flight, so the frame can say 正在算 and the
    /// depth. Neighbouring pages stay alive in a paged TabView; only the card in front speaks.
    private func isCardSearching(_ kind: Card) -> Bool {
        wantsAdvice(kind) && session.isAdvising
    }

    /// The two cards the finder answers for: the shot, and the mate that falls out of the same
    /// probe. Swiping between them does not stop and restart it.
    private func wantsFinder(_ kind: Card) -> Bool { kind == .mate || kind == .tactics }

    // ------------------------------------------------------------------ 杀

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
                        withAnimation(.snappy(duration: 0.2)) { showsMateLine.toggle() }
                    } label: {
                        Image(systemName: showsMateLine ? "arrow.up.right.circle.fill" : "arrow.up.right.circle")
                            .font(.subheadline)
                            .foregroundStyle(showsMateLine ? mateInk : Palette.inkSoft)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(news.arrows.isEmpty)
                    .accessibilityLabel(localized(showsMateLine ? "screen.hideArrows" : "screen.showArrows"))
                    .accessibilityHint(localized("screen.arrowsExplained"))
                }
                CardLede(news.sentence)
                if !news.san.isEmpty {
                    // The numbers are the join: the figure on a chip is the figure on its arrow.
                    CardMoves(
                        moves: news.san.enumerated().map { index, san in
                            CardMoves.Move(
                                step: index + 1,
                                san: san,
                                isYours: news.arrows.first { $0.step == index + 1 }?.isYours ?? false
                            )
                        }
                    )
                }
                if !news.isFullyDrawn {
                    CardNote(localized("screen.arrowLimit", MateNews.arrowLimit))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 10)
        } else {
            // No news is news, and it is three different pieces of it. A card that goes blank when
            // there is no mate is a card that looks broken (docs/adr/0025).
            VStack(alignment: .leading, spacing: 6) {
                if viewed.isOver {
                    Text(localized("screen.finished"))
                } else if session.isProbingTactics || session.isSearching {
                    EmptyView()
                } else if session.isFindingTactics || session.analysis != nil {
                    Text(localized("screen.noMate"))
                } else {
                    Text(localized("screen.mateIdle"))
                }
            }
            .font(.caption)
            .foregroundStyle(Palette.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    /// The mate line as numbered arrows, while its own card is the one on show.
    private var mateArrows: [MoveArrow] {
        guard showsMateLine, card == .mate, let news = session.mateNews else { return [] }
        return news.arrows
    }

    // ------------------------------------------------------------------ the bar at the top

    /// Turns the board round — and with it, which side's controls are above and which below. The
    /// state it is in is the board, so it needs no label saying so.
    private var flip: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                session.orientation =
                    session.orientation == .whiteAtBottom ? .blackAtBottom : .whiteAtBottom
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .foregroundStyle(Palette.ink)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized("game.flip"))
    }

    // ------------------------------------------------------------------ the board

    // The deck's room, as named numbers rather than one unexplained `388`.

    /// The most a card is ever asked for: what `boardSide` holds back for the deck, so that the
    /// card is this big before the board takes another eight points of width.
    ///
    /// Measured rather than chosen — 164pt is what a card on a 402×874 phone came out at when the
    /// screen was laid out by hand, and `DeckFloorTests` reads the same figure back off the picture.
    static let cardWanted: CGFloat = 162

    /// The least a card may be and still be a card: the bound `DeckFloor` holds every screen the app
    /// runs on to, and the reason the board reserves `cardWanted` rather than this.
    ///
    /// A bound rather than a clamp in the layout itself: the room the deck gets is whatever the
    /// board leaves, and the board's own budget is what keeps that above this (docs/adr/0025). The
    /// shortest screen the app runs on leaves 137pt, so this is a number nothing reaches — which is
    /// the shape to keep it in. A floor that is doing work is a floor that has been hit.
    static let cardFloor: CGFloat = 120

    /// What the five names take. The rail measures itself and corrects this; it is here so the
    /// board can be sized before anything has been laid out.
    static let railReserve: CGFloat = 48

    /// Everything above the deck: two player bars, the standing strip, the record row.
    static let chrome: CGFloat = 178

    /// Below this a board is not a board. It is the one thing that can still win an argument with
    /// the deck, and it only wins one on a screen with no business running this app.
    static let minBoard: CGFloat = 240

    /// How big the board is, and it depends on the screen and nothing else.
    ///
    /// It used to take whatever height was left over, which meant the board changed size when the
    /// engine found a third line to show — the one thing on this screen that must never move. So
    /// it is sized from the width, all but full bleed, and shrinks to leave the rest of the screen
    /// what it needs. Rounded to a multiple of eight so every square is a whole number of points
    /// and no grid line lands on a half pixel.
    ///
    /// Two bars and a record cost more than the deck they replaced, and the difference comes off
    /// the board rather than off the reading: a board forty points wider is not worth a 改棋子 row
    /// cut in half by the footer on the one screen — a board straight off a photograph — where
    /// that row is the whole job.
    ///
    /// **The board yields to the deck, not the other way round.** The height it may take is the
    /// screen less the chrome, less the names, less the card the deck wants. It used to be
    /// `max(240, size.height - 388)`, and the `max` was the bug: on a screen shorter than that sum
    /// the board kept its 240 and the deck paid the difference — on a phone on its side, all of it,
    /// silently, `opacity(0)`, with every action on the cards gone (docs/adr/0025). `minBoard` is
    /// still the floor for a screen too short for a board at all; what changed is that the deck's
    /// room is now part of the sum rather than what was left after it.
    static func boardSide(in size: CGSize, accessibilityText: Bool = false) -> CGFloat {
        let byWidth = max(0, size.width)
        // And at an accessibility text size it gives back what the rows above it cost when they
        // grow — capped growth, but growth (see `chromeType`). A board is a grid: 312pt of it is
        // still a board to look at, where a card squeezed by the labels to 104pt is two lines of
        // itself and nothing else. `DeckFloor` reads the largest text size back off the render.
        return byWidth
    }

    /// What the rows above the board take when the reader's text is at an accessibility size: the
    /// capped growth of two player bars, the standing strip and the record, measured at the largest
    /// size the system offers (240pt of chrome against 178 at the default), rounded to a whole
    /// number of board squares.
    static let accessibilityChrome: CGFloat = 64

    /// What the deck is left under the record on a screen the layout has been handed this much
    /// height — the sum the column comes to, written out so a test can hold it without a window.
    /// The deck takes exactly this by being the one flexible child of a column whose other children
    /// are fixed, which is why `deck` needs no measurement of its own (docs/adr/0025).
    ///
    /// That height is what `proxy.size.height` is: the glass less the status bar and the navigation
    /// bar, and including the home-indicator band, because the deck is drawn down to the glass
    /// (`.ignoresSafeArea(edges: .bottom)`). On a 402×874 phone it is 758, which is the figure
    /// `DeckFloor` measures back off `game-in-play.png`: 368 of board, 212 of deck.
    static func deckRoom(readerHeight: CGFloat, width: CGFloat) -> CGFloat {
        readerHeight - chrome - boardSide(in: CGSize(width: width, height: readerHeight))
    }

    private var board: some View {
        BoardView(
            pieces: boardPieces,
            orientation: session.orientation,
            isFaceToFace: session.isFaceToFace,
            lastMove: session.boardLastMove,
            checks: session.board.state.checkSquares,
            // The doubtful squares stay ringed on the board being played on, right up until the
            // first move — which is what replaces the old gate: the reading's own uncertainty is
            // visible where it matters, and 改棋子 is one tap away (docs/adr/0011).
            suspects: session.unconfirmedSquares,
            selected: selected,
            destinations: Set(candidateMoves.map(\.to)),
            captures: Set(candidateMoves.filter(\.isCapture).map(\.to)),
            recommendation: nil,
            // Whichever card is in front of you, and only that one: arrows left over from a card
            // you swiped away from are arrows about a position nobody is looking at (docs/adr/0025).
            // A 应招 beats all of them while it is being read: it is the one line somebody has
            // just asked for, and the board can only carry one at a time.
            plan: session.replyReading.map(\.arrows).flatMap { $0.isEmpty ? nil : $0 }
                ?? (card == .tactics && revealed.contains(.tactics) && showsTacticLine && session.dealsCards
                    ? session.tacticArrows : mateArrows),
            isInteractive: session.isHandTurn,
            onTap: tap
        )
    }

    // ------------------------------------------------------------------ doing

    private func tap(_ square: Square) {
        guard session.isHandTurn else { return }

        if let selected {
            let moves = session.board.state.moves(from: selected).filter { $0.to == square }
            // More than one move to the same square means a promotion, and only a promotion.
            if moves.count > 1 {
                promotion = PromotionRequest(moves: moves)
                self.selected = nil
                return
            }
            if let move = moves.first {
                session.play(move)
                self.selected = nil
                return
            }
        }

        // Not a destination, so it is either a new selection or a deselection.
        if let piece = boardPieces[square], piece.colour == session.board.state.sideToMove {
            selected = square
        } else {
            if selected != nil { Sounds.current.play(.refused) }
            selected = nil
        }
    }

    private func walk(_ delta: Int) {
        selected = nil
        session.step(by: delta)
    }

    /// A tap on a cell of the record strip. The strip holds still for it (see `isTappingStrip`);
    /// the flag is raised only when the cursor is actually going to move, so a tap on the cell
    /// already on the cursor — which changes nothing — cannot leave it raised for the next arrow.
    private func walk(to cursor: Int) {
        selected = nil
        guard session.canBrowse, cursor != session.cursor else { return }
        isTappingStrip = true
        session.step(by: cursor - session.cursor)
    }

    // ------------------------------------------------------------------ reading the game

    /// The game where the player is looking, which is what everything on this screen is about.
    private var viewed: Game { session.viewed }

    private var pieces: [Square: Piece] {
        BoardRenderer.placement(viewed.state.fen) ?? [:]
    }

    /// What the board draws — the trial's position when one is being tried out, and the studied
    /// one otherwise. Only the board reads this: the engine, the record and the Review all go on
    /// seeing the real position, which is what keeps a trial a hypothesis (docs/adr/0021).
    private var boardPieces: [Square: Piece] {
        BoardRenderer.placement(session.board.state.fen) ?? [:]
    }

    private var candidateMoves: [Move] {
        guard let selected, session.isHandTurn else { return [] }
        return session.board.state.moves(from: selected)
    }

    /// The colour whose pieces stand at the top of the board, and so the colour whose controls
    /// belong above it. Flipping the board moves them, which is the whole idea.
    private var topColour: PieceColour {
        session.orientation == .whiteAtBottom ? .black : .white
    }

    private var bottomColour: PieceColour {
        session.orientation == .whiteAtBottom ? .white : .black
    }

}

private extension View {
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

extension Game.Half {
    /// Said the way somebody reading a game aloud says it: a bare "Nf6" out of VoiceOver is a
    /// move with no place in the game, and place is the whole of what the record strip is for —
    /// and on a fork, which line this is of the ones played from here (docs/adr/0043).
    var spoken: String {
        let step = localized("screen.spokenMove", ply, san)
        guard isFork else { return step }
        let place = localized(isTrunk ? "record.trunk" : "record.twig", branchNumber, siblingCount)
        return step + localized("clause.separator") + place
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

extension GameScreen.Card {
    var title: String {
        switch self {
        case .mate: localized("screen.mate")
        case .tactics: localized("screen.tactics")
        }
    }

    /// One line saying what the card answers, in the words of somebody who does not yet know the
    /// name above it.
    var subtitle: String {
        switch self {
        case .mate: localized("screen.mateSubtitle")
        case .tactics: localized("screen.tacticsSubtitle")
        }
    }
}
