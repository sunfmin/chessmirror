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
    /// Which side's own controls are open. Nobody's, unless somebody said otherwise — and then
    /// their answer stands for as long as the screen does. Never derived from the game: an unfold
    /// that answers to the moves is an unfold that opens and shuts under your thumb, and the board
    /// walks up and down the screen every time it does.
    ///
    /// That includes the way in. There used to be a guess made here on appearing — a board with
    /// nothing played on it was to open the side to move — and what it had come to do was set
    /// this to nil, which it already was. A fresh board and a game under way both open with every
    /// strip shut, and only a thumb opens one.
    @State private var unfolded: PieceColour?
    /// The one hold on 让引擎走, if a thumb is on it. Its lifetime *is* the press: cancelled
    /// here on release and on the way off the screen, which is what makes the hold one call
    /// (`holdForMove`) that cannot run on with nobody holding it.
    @State private var hold: Task<Move?, Never>?
    /// Whether a thumb is on 让引擎走 right now. The engine is thinking for exactly as long as it is —
    /// which is why this is read off the session rather than kept here as well. A screen holding
    /// its own copy of "a finger is down" is a screen that can be left holding it: a press that
    /// ends any way other than a release leaves the flag set, and the button then draws itself
    /// full and held with nobody touching it.
    private var isAsking: Bool { session.thinking == .asked }

    struct PromotionRequest: Identifiable {
        let id = UUID()
        let moves: [Move]
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

                if session.dealsCards {
                    DeckView(session: session, selected: $selected)
                }
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
                // The search has to account for itself (docs/adr/0020) — and one that has said
                // nothing yet accounts for itself in words: a depth of nought is not a report.
                // The width is the depth label's either way, so the row does not jump when the
                // first depth lands.
                if let depth = strip.depth {
                    Text(Depth.label(depth))
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
    private func wrongToken(_ wrong: RecordReading.WrongMove, index: Int) -> some View {
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
        .disabled(!session.canReadReply)
        .accessibilityLabel(wrong.san)
        .accessibilityValue(Drop.figure(wrong.drop))
        .accessibilityHint(localized("tried.reply.hint"))
    }

    /// The 应招 the move earned: the same numbered chips the cards use, numbered against the
    /// arrows on the board. One move is the refused one and the rest are the answers to it, so
    /// the row begins with the move the player made and not with what happened to it.
    @ViewBuilder private func replyRow(_ reading: ReplyReading) -> some View {
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
            if !reading.steps.isEmpty {
                CardMoves(moves: reading.steps)
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
    @ViewBuilder private func rejudgeControl(_ reading: ReplyReading) -> some View {
        if let running = session.rejudging, running.index == reading.index {
            ProgressView().controlSize(.mini)
            Text(Depth.label(running.depth))
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
                    Text(PlayerSettings.shared.searchLimit.label)
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
                    hold = Task { await session.holdForMove() }
                },
                onRelease: { hold?.cancel() }
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
                    session.setStrength(rung, in: PlayerSettings.shared)
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
                Text(session.strength.engineName)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.caption)
            .foregroundStyle(Palette.inkSoft)
            .contentShape(Rectangle())
        }
        .disabled(session.isOccupied)
        .accessibilityLabel(localized("strength"))
        .accessibilityValue(session.strength.engineName)
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
                    .disabled(!session.canSeat(controller))
                }
            }
            .frame(minHeight: 36)

            if session.controller(for: colour) == .engine {
                HStack(spacing: 8) {
                    Text(localized("game.perMove")).foregroundStyle(Palette.inkSoft)
                    Spacer()
                    Text(PlayerSettings.shared.searchLimit.label).foregroundStyle(Palette.ink)
                }
                .padding(.vertical, 5)
            }

            Rectangle().fill(Palette.hairline).frame(height: 0.5).padding(.vertical, 5)
            Toggle(localized("noSlips.name"), isOn: Binding(
                get: { session.isNoSlipsOn },
                set: { session.setNoSlips($0) }
            ))
            .toggleStyle(SettingToggleStyle(label: localized("noSlips.name")))
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
        switch session.reviewRow {
        case .running(let progress)?:
            VStack(alignment: .leading, spacing: 6) {
                Text(GameSession.ReviewRow.running(progress).text)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Palette.ink)
                ProgressView(value: progress.fraction)
                    .tint(Palette.analysis)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .reviewChrome()
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        case .offered(let failed, let canStart)?:
            let row = GameSession.ReviewRow.offered(failed: failed, canStart: canStart)
            HStack(spacing: 10) {
                Text(row.text)
                    .font(.footnote)
                    .foregroundStyle(failed ? Palette.alarm : Palette.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { session.review() } label: {
                    Text(row.action ?? "")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(canStart ? Palette.raised : Palette.inkSoft)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(canStart ? Palette.analysis : Palette.chipRest, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
            }
            .reviewChrome()
        case .done(let slips)?:
            Label(GameSession.ReviewRow.done(slips: slips).text, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(Palette.analysis)
                .frame(maxWidth: .infinity, alignment: .leading)
                .reviewChrome()
        case nil:
            EmptyView()
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
        let slips = session.reading.slips
        let attempts = session.reading.wrongs
        let exercise = session.activePunishment
        let answered = session.punishment?.revealedMove
        if !slips.isEmpty || !attempts.isEmpty || exercise != nil || answered != nil {
            VStack(spacing: 0) {
                if !slips.isEmpty { slipTiles(session.reading.tiles) }
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
    private func slipTiles(_ tiles: [RecordReading.Tile]) -> some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(tiles) { tile in slipTile(tile) }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            if let next = session.reading.next {
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
    private func slipTile(_ tile: RecordReading.Tile) -> some View {
        let on = session.cursor == tile.slip.positionPly
        return Button {
            jumpTo(slip: tile.slip)
        } label: {
            VStack(spacing: 3) {
                // Sixty-four points, which is the size the 错题本 already uses for the same job:
                // the board is the name of a position, and a name has to be legible.
                thumbnail(tile.slip.position, side: 64)
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
                slipCaption(tile)
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
        .accessibilityLabel(tile.spoken)
        .accessibilityHint(localized("slips.hint"))
    }

    /// The caption under a 错题's board: where in the game, how many wrong moves were tried there,
    /// and what the worst of them cost — as one Text, so it is one thing that shrinks to the
    /// board's width rather than three that fight over it.
    private func slipCaption(_ tile: RecordReading.Tile) -> Text {
        var line = Text(tile.number)
            .font(.caption2.monospacedDigit().weight(.medium))
            .foregroundStyle(Palette.ink)
        if let times = tile.times {
            line = line
                + Text(" ×\(times)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(Palette.alarm)
        }
        return line
            + Text(" " + tile.figure)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(tile.isOwed ? Palette.alarm : Palette.inkSoft)
    }

    /// The wrong moves made at the position on the board, newest first, under the positions
    /// they belong to — the lower register of the same strip.
    private func wrongTokens(_ wrongs: [RecordReading.WrongMove]) -> some View {
        // A row of refusals is led by an ✕; a row that is only the move that stood — an imported
        // game's — by a mark that says it was played (`RecordReading.lead`).
        let lead = session.reading.lead ?? .stood
        return HStack(spacing: 8) {
            // A mark and nothing else: the word — 「已退回」 or 「走了的错招」 — is what VoiceOver reads
            // out for it rather than sixty points of the row.
            Image(systemName: lead == .returned ? "xmark" : "exclamationmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Palette.alarm)
                .frame(width: 18)
                .accessibilityLabel(lead.spoken)
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
        // Read once for the whole strip: the reading hands every cell ready to draw — its caption,
        // its mark, its 分支 ticks, its spoken string and whether the eye is on it — and the
        // screen paints what it is given (`RecordReading.rows`).
        let reading = session.reading
        return ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    openingCell(reading.opening)
                    ForEach(reading.rows) { row in
                        HStack(spacing: 6) {
                            Text("\(row.number)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Palette.inkSoft)
                                .frame(minWidth: 13, alignment: .trailing)
                            if let white = row.white { half(white) }
                            if let black = row.black { half(black) }
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
    private func openingCell(_ cell: RecordReading.Cell) -> some View {
        return Button { walk(to: 0) } label: {
            Text(cell.name)
                .font(.caption)
                .foregroundStyle(cell.isCursor ? Palette.parchment : Palette.inkSoft)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    cell.isCursor ? AnyShapeStyle(Palette.analysis) : AnyShapeStyle(Palette.chipRest),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay(alignment: .bottom) { slipMark(cell.mark) }
        }
        .buttonStyle(.plain)
        .id(0)
        .accessibilityLabel(cell.spoken)
    }

    /// The mark a 错招 leaves at the foot of the position it was made at.
    ///
    /// An overlay rather than a row, so a card with a mistake in it is exactly as tall as one
    /// without: the curve behind the strip is drawn against these cards being even. Two weights on
    /// the one scale the app already has (docs/adr/0027): pale is what the 记录线 put in the file,
    /// the alarm colour is what the 入列线 says the player still owes. Which weight is which is
    /// the mark's own (`Mark.weight`).
    @ViewBuilder private func slipMark(_ mark: RecordReading.Mark?) -> some View {
        if let mark {
            UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2)
                .fill(Palette.alarm.opacity(mark.weight))
                .frame(height: 3)
        }
    }

    /// One half of a move, and — when the player got a position wrong here — a mark at its foot.
    /// What it reads, says, is marked with, sits on a fork with, and whether the eye is on it is
    /// the record's (`RecordReading.Cell`); the screen only paints it.
    ///
    /// With a caption, every cell carries a second line, so the whole row grows together and the
    /// curve behind it is drawn against cells that are still even.
    private func half(_ cell: RecordReading.Cell) -> some View {
        // A 树枝 is inked in its own colour, so a line tried from an earlier position cannot be
        // mistaken for the game (docs/adr/0043). A cell on a fork is outlined rather than filled
        // when the eye is on it (`cell.isFilled`), so the rail beside it reads as part of the
        // same cell.
        let mark = cell.isTrunk ? Palette.ink : Palette.mine
        let filled = cell.isFilled
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
                    Text(cell.name)
                        .font(.footnote.weight(cell.isCursor ? .medium : .regular))
                        .foregroundStyle(filled ? Palette.parchment : mark)
                    if let caption = cell.caption { costCaption(caption, on: filled) }
                }
                .padding(.horizontal, cell.isFork ? 3 : 5)
                .padding(.vertical, 2)
                .background {
                    if filled {
                        RoundedRectangle(cornerRadius: 5).fill(Palette.analysis)
                    } else if cell.isCursor {
                        RoundedRectangle(cornerRadius: 5).stroke(mark, lineWidth: 1.2)
                    }
                }
                .overlay(alignment: .bottom) { slipMark(cell.mark) }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            // Said the way somebody reading a game aloud says it. A bare "Nf6" out of VoiceOver
            // is a move with no place in the game, and place is the whole of what this strip is
            // for — and what it cost, and a mistake made from here, are worth saying out loud too.
            .accessibilityLabel(cell.spoken)
            .accessibilityHint(localized("record.jump"))
        }
        .id(cell.ply)
    }

    /// The move's 掉幅 under it, in the app's one figure. 「最佳」 for the engine's own first
    /// choice, a muted 「0」 for another move that cost nothing — that is information: the move
    /// was right — and a blank of the same height under a move nobody has measured, which is
    /// not the same thing as zero.
    private func costCaption(_ caption: RecordReading.Caption, on: Bool) -> some View {
        let ink = on ? Palette.parchment : Palette.inkSoft
        let colour: Color = switch caption {
        case .best: on ? Palette.parchment : Palette.analysis
        case .free: ink.opacity(0.55)
        case .unmeasured, .cost: ink
        }
        return Text(verbatim: caption.figure)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(colour)
    }

    // ------------------------------------------------------------------ the deck

    /// One finding of the deck under the record — the kit's (`Deck.Card`, docs/adr/0025). The
    /// name stays here because the screen's open card, its animations and its tests all spell it
    /// `GameScreen.Card`; what a card *is* is not the screen's to say.
    typealias Card = Deck.Card

    // ------------------------------------------------------------------ the bar at the top

    /// Turns the board round — and with it, which side's controls are above and which below. The
    /// state it is in is the board, so it needs no label saying so.
    private var flip: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                session.orientation = .facing(session.orientation.top)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .foregroundStyle(Palette.ink)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized("game.flip"))
    }

    // ------------------------------------------------------------------ the board

    /// How big the board is, and it depends on the screen and nothing else: the full width.
    ///
    /// It used to take whatever height was left over, which meant the board changed size when the
    /// engine found a third line to show — the one thing on this screen that must never move. It
    /// then went through a height budget against the deck (docs/adr/0025), and that budget is gone
    /// with the deck's fixed floor: the board is full bleed at every size and every text size, and
    /// the deck is the one flexible child under it.
    static func boardSide(in size: CGSize) -> CGFloat {
        max(0, size.width)
    }

    private var board: some View {
        // One reading of the board (`BoardReading`): the pieces, whose they are, the marks
        // around them and the one line on it. What is picked up and where it may go is the
        // finger's — a session cannot know it.
        let reading = session.boardReading
        return BoardView(
            pieces: reading.pieces,
            orientation: reading.orientation,
            isFaceToFace: reading.isFaceToFace,
            lastMove: reading.lastMove,
            checks: reading.checks,
            suspects: reading.suspects,
            selected: selected,
            destinations: Set(session.moves(holding: selected).map(\.to)),
            captures: Set(session.moves(holding: selected).filter(\.isCapture).map(\.to)),
            recommendation: nil,
            plan: reading.plan,
            isInteractive: reading.isInteractive,
            onTap: tap
        )
    }

    // ------------------------------------------------------------------ doing

    /// What the tap means is the session's (`GameSession.tap`); what is left here is holding the
    /// picked-up square and asking for the promotion piece.
    private func tap(_ square: Square) {
        switch session.tap(square, holding: selected) {
        case .ignored:
            return
        case .pick(let square):
            selected = square
        case .play(let move):
            session.play(move)
            selected = nil
        case .promote(let moves):
            promotion = PromotionRequest(moves: moves)
            selected = nil
        case .drop:
            // A tap that was meant as a move and was not one has already been said, as
            // `Event.refused`, through the one noise path (`session.hear`).
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
    /// The colour whose pieces stand at the top of the board, and so the colour whose controls
    /// belong above it. Flipping the board moves them, which is the whole idea.
    private var topColour: PieceColour { session.orientation.top }

    private var bottomColour: PieceColour { session.orientation.bottom }

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
