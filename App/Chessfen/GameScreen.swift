import ChessfenKit
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
/// No scrolling above the record: the board is the hero and it has to sit still under a navigation
/// bar, not slide beneath it. Everything above and below it is a strip of fixed height, and the
/// board takes whatever is left over — which on a small phone means a slightly smaller board
/// rather than a screen that has to be dragged. What scrolls is the card under the record, and only
/// when its body is longer than the room it is given.
struct GameScreen: View {
    let session: GameSession
    @Binding var path: [Step]
    /// Which card of the deck to open on. Nil means the position decides, which is what the app
    /// does; a screenshot test passes one in to photograph a card that is not the one on top.
    var opening: Card?

    @Environment(EngineHost.self) private var engine
    @Environment(GameLibrary.self) private var library
    /// The reader's text size, read for one thing only: how much the rows around the board are
    /// going to cost it (see `boardSide`).
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var selected: Square?
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
    /// Whether it was arriving at 杀 or 战术 that turned the finder on, rather than a person
    /// pressing its switch. Only what a swipe turned on does a swipe turn off again.
    @State private var finderIsOurs = false
    /// Whether the finder is off because somebody pressed it off, rather than because nobody has
    /// pressed it on. The card says different things about the two.
    @State private var finderClosedByHand = false
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
        unfolded = session.game.plies.isEmpty ? viewed.state.sideToMove : nil
    }

    /// Which card the deck opens on: the news when there is news, and the work this position is
    /// for otherwise.
    ///
    /// A mate is the one thing on this screen allowed to speak first, so 杀招 is where the deck
    /// opens when a search has already found one — a coloured tab is not a prompt (docs/adr/0025).
    private var opensOn: Card {
        if let opening { return opening }
        // News before work: a mate on the board is the reason 「直接给予提示」 was asked for.
        if session.mateNews != nil { return .mate }
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
        if opening != nil || card == .mate { arrive(at: card) }
    }

    var body: some View {
        GeometryReader { proxy in
            // The reader goes to the glass so the card can. The board is still sized for the
            // safe area — extra height at the bottom is the deck's, not a larger board.
            let side = Self.boardSide(
                in: CGSize(
                    width: proxy.size.width,
                    height: proxy.size.height - proxy.safeAreaInsets.bottom
                ),
                accessibilityText: typeSize.isAccessibilitySize
            )
            VStack(spacing: 0) {
                playerBar(topColour).chromeType()
                board.frame(width: side, height: side)
                standing.frame(width: side).padding(.vertical, 6).chromeType()
                playerBar(bottomColour).chromeType()
                record.chromeType()
                deck
            }
            .frame(maxWidth: .infinity)
        }
        .background(Palette.parchment)
        // The card stands on the glass. The home indicator is a mark on top of it, not a
        // margin that holds the deck off the bottom of the phone.
        .ignoresSafeArea(edges: .bottom)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { flip }
            ToolbarItem(placement: .topBarTrailing) {
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
                    // Time is the only dial (docs/adr/0009), and here it is spent per ply: a
                    // deeper pass is a better opinion and a longer wait, and nothing else changes.
                    // It used to be a 重算 menu on a row of its own under the report, next to a
                    // sentence naming the depth. The depth is said once now, beside the score it
                    // produced, and changing it is here with the other things done rarely.
                    Menu {
                        ForEach([10, 14, 18, 22], id: \.self) { depth in
                            Button(localized("game.depth", depth)) {
                                session.startReview(depth: depth)
                            }
                        }
                    } label: {
                        Label(localized("game.rescore"), systemImage: "arrow.clockwise")
                    }
                    .disabled(session.reviewPass?.isRunning == true || !engine.isReady)
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
                    // The order a collection is filed in is the order 练习 walks it, and going back
                    // to the library between two positions is the thing that makes anyone stop.
                    // 旁注 used to carry these and went with the ten-card deck, so they are here
                    // now, with the other things done rarely rather than often.
                    if let place = placeInSeries, let collection = session.collection {
                        Section("这一局在「\(collection)」里，第 \(place.index + 1)/\(place.entries.count)") {
                            Button {
                                guard let target = place.entries[safe: place.index - 1] else { return }
                                turnTo(target)
                            } label: {
                                Label("上一局", systemImage: "chevron.left")
                            }
                            .disabled(place.index - 1 < 0)
                            Button {
                                guard let target = place.entries[safe: place.index + 1] else { return }
                                turnTo(target)
                            } label: {
                                Label("下一局", systemImage: "chevron.right")
                            }
                            .disabled(place.index + 1 >= place.entries.count)
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
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(localized("game.more", session.startingSideToMove.label))
            }
        }
        .onAppear {
            guessUnfold()
            // The engine first, and then the deck: **dealing a card is an arrival**, and an arrival
            // spends a Stint. Attached after the deal, the dealt card is the one card on the screen
            // that cannot answer — 要害 is the default, so the state never changes, the swipe path
            // that would have asked again never runs, and the first card sat on its 「会算 10 秒」
            // line with the engine already there.
            //
            // Re-attached on every appearance: the engine may have finished starting while the
            // library was on screen, and coming back from a Review means the search this screen
            // wants is not the one that just ran. Retuned before the deal rather than after it, or
            // the Stint the deal just started would be cancelled a line later.
            session.attach(engine: engine.service, library: library)
            session.retune()
            deal()
        }
        .onDisappear { session.suspend() }
        .onChange(of: isSoundOn) { _, isOn in Sounds.current.isSoundOn = isOn }
        // The setting travels between devices (docs/adr/0012), so it can change while this
        // screen is the one on show — and a toggle that disagrees with the sound is worse than
        // no toggle.
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
            isSoundOn = Sounds.current.isSoundOn
        }
        .onChange(of: engine.isReady) { _, ready in
            guard ready else { return }
            session.attach(engine: engine.service, library: library)
            session.retune()
        }
        // The Analysis this screen wants is unbounded, and the engine will not start one while
        // the app is away — so leaving is a suspend and coming back is a fresh `retune`, not a
        // search that was left running underneath. `EngineHost.isActive` rather than the scene
        // phase, so there is one answer to when that is.
        .onChange(of: engine.isActive) { _, active in
            if active {
                session.retune()
            } else {
                session.suspend()
            }
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
    /// It used to be said twice: a number in a line above the board and a bar below it, with the
    /// engine's speed and depth between them. Two pictures of one fact cost a row each on a phone,
    /// and the row they cost came out of the report — which is the part of this screen anybody
    /// learns anything from. So the number moved down to the end of its own bar, and the speed and
    /// depth went altogether: they said what the phone was doing, never what the position was.
    ///
    /// Always here, whatever the switch is doing, so the board does not walk up the screen when
    /// the engine is asked to be quiet. What changes is what stands in it: a bar and a number when
    /// there is an opinion, the word 练习 when there is deliberately none.
    ///
    /// A finished game keeps its bar, and that is not a leak: what it carries then is the result,
    /// and who won is a fact about the game rather than the engine's opinion of it. Practice hides
    /// what the engine thinks, never what happened.
    ///
    /// **Everything the engine has to say is now in this one strip**, including the switch that
    /// decides whether it says anything — which used to live in the navigation bar, a screen away
    /// from the bar it governs. Four things that are one thought: whether it is talking, who is
    /// ahead, by how much, and how far it has got working it out. The last of those is new, and it
    /// is here because a search that stops after ten seconds (docs/adr/0020) has to be able to say
    /// so — a number that quietly stopped moving is indistinguishable from an engine that died.
    private var standing: some View {
        HStack(spacing: 8) {
            opinionSwitch

            if viewed.isOver {
                // Who won is not a fact about one side, so it is said here rather than in a bar.
                Text(viewed.turn)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.ink)
            } else if engine.unavailableReason != nil {
                Text(localized("game.noEngine")).font(.caption).foregroundStyle(Palette.alarm)
            }

            if !session.isPractising || finish != nil {
                evalTrack
            } else {
                Spacer(minLength: 0)
            }

            if let finish {
                // The number people have been watching, resolved: a finished game has no Score to
                // show, and what belongs in its place is the one it ended on.
                Text(finish.scoreline)
                    .clockFont(22)
                    .foregroundStyle(Palette.ink)
            } else if !session.isPractising {
                Text(session.analysis?.best?.score.displayText ?? "—")
                    .clockFont(22)
                    .foregroundStyle(session.analysis == nil ? Palette.inkSoft : Palette.analysis)
                    .contentTransition(.numericText())
                effort
            }
        }
        // A minimum rather than a height: the row used to be cut in half by its own frame the
        // moment the reader's text was bigger than the default, and the strip is the one place the
        // engine has to account for itself (docs/adr/0020).
        .frame(minHeight: 26)
    }

    /// The switch that used to sit in the navigation bar, brought down beside the bar it governs.
    ///
    /// Two shapes, because the two states are read for different reasons. Silent, it wears the
    /// word: 练习 is a thing to be *in*, and a strip with no number in it has the room to name it.
    /// Talking, the bar and the number have already said the engine is talking, so the control
    /// shrinks back to the eye that turns it off.
    ///
    /// One deliberate press either way, which is all ADR-0015 ever asked for: the engine's opinion
    /// is never found already on, and never lost by brushing past it.
    private var opinionSwitch: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { session.setPractising(!session.isPractising) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: session.isPractising ? "eye.slash" : "eye").font(.caption2)
                if session.isPractising {
                    Text("练习").font(.footnote.weight(.semibold))
                }
            }
            .foregroundStyle(session.isPractising ? Palette.inkSoft : Palette.analysis)
            .padding(.horizontal, session.isPractising ? 9 : 6)
            .padding(.vertical, 4)
            .background(Palette.chipRest, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!engine.isReady && session.isPractising)
        .accessibilityLabel("引擎意见")
        // The word the control is actually wearing, not a bare 关. A screen that draws 练习 and
        // reports "off" says two different things to two different readers, and the tree is the
        // one VoiceOver hears.
        .accessibilityValue(session.isPractising ? "练习" : "开")
    }

    /// Who is ahead, with how hard the engine is still working on that answer drawn underneath it.
    ///
    /// One control rather than a bar with a button next to it, because they are the same subject:
    /// the line is the search that produced the bar, and when the search has stopped the bar is
    /// what you press for more of it. The line fills with Depth — the same measure the hold button
    /// uses — so it is the picture of the number beside it rather than a second thing to read.
    ///
    /// It goes quiet rather than away when the Stint ends: how deep it got is worth keeping on
    /// screen, and a line that vanished would say the engine had never run.
    private var evalTrack: some View {
        VStack(spacing: 3) {
            EvalBar(
                score: session.analysis?.best?.score,
                orientation: session.orientation,
                finish: finish
            )
            if finish == nil, !session.isPractising {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Palette.analysis.opacity(session.isAdviceSpent ? 0.3 : 0.9))
                        .frame(width: proxy.size.width * depthFraction)
                        .animation(.easeOut(duration: 0.3), value: depthFraction)
                }
                .frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { session.adviseAgain() }
    }

    /// How far the search has got, 0...1, by the same reckoning the hold button uses.
    private var depthFraction: Double {
        min(Double(session.searchProgress?.depth ?? 0) / SearchDepth.deepEnough, 1)
    }

    /// What the engine has got to, and — once it has stopped — what to do about that.
    ///
    /// A search with no readout is a phone that might be working or might be broken, and the
    /// answer used to be "it is always working", which was the problem. Now it stops, so it has to
    /// account for itself: a Depth while it climbs, and an offer of another ten seconds when it
    /// has stopped climbing.
    @ViewBuilder private var effort: some View {
        if session.isAdviceSpent {
            Button { session.adviseAgain() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9))
                    Text("再算 10 秒").font(.caption.weight(.semibold))
                }
                .foregroundStyle(Palette.parchment)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Palette.analysis, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("再算 10 秒")
        } else if let depth = session.searchProgress?.depth, depth > 0 {
            Text("深 \(depth)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Palette.inkSoft)
                // It climbs several times a second, and a number that animates while it does is a
                // number nobody can read.
                .animation(.none, value: depth)
        }
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
        let live = isOnClock(colour)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Swatch(colour: colour)
                Text(colour.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text(session.controller(for: colour).label)
                    .font(.caption)
                    .foregroundStyle(Palette.inkSoft)
                // The engine's clock, and only where it decides something: how long this side's
                // next move takes. It is the only dial in the app (docs/adr/0009).
                if session.controller(for: colour) == .engine {
                    Text(session.thinkingTime.label)
                        .font(.caption)
                        .foregroundStyle(Palette.inkSoft)
                }
                if live, !viewed.isOver {
                    Text(localized("game.toPlay"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.analysis)
                    if viewed.state.inCheck {
                        Text(localized("game.inCheck"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.alarm)
                    }
                    advice(for: colour)
                }
                Spacer(minLength: 4)
                if live { action }
                unfoldButton(colour)
            }
            .frame(minHeight: 30)
            // One row of facts, and it stays one row. At an accessibility size the labels gave way
            // to each other by wrapping, so 「让引擎走」 stood in its capsule on two lines and the
            // bar grew a row taller — which is a row taken off the board for a button's label.
            .lineLimit(1)

            if unfolded == colour { chips(for: colour) }
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
            // Mirrored Time means the engine takes about as long as the player just did, which is
            // right most of the time and longer than anyone wants to sit through the rest of it.
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
        if isAsking {
            Text(askedReadout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Palette.analysis)
                .lineLimit(1)
        } else if session.isPractising {
            // Nothing. The header already wears 练习 with an eye struck through it, and a bar that
            // says "no opinion" every move is an opinion about how much you are missing.
            EmptyView()
        } else if let best = session.analysis?.best?.san.first {
            Text(
                localized(
                    session.controller(for: colour) == .engine
                        ? "game.willPlay" : "game.suggests",
                    best
                )
            )
                .font(.caption)
                .foregroundStyle(Palette.analysis)
                .lineLimit(1)
                // The recommendation changes several times a second as the search deepens, and
                // that is the point (docs/adr/0009) — so it must not animate while it does.
                .animation(.none, value: session.analysis?.depth)
        } else if let reason = engine.unavailableReason {
            Text(reason).font(.caption).foregroundStyle(Palette.alarm).lineLimit(1)
        } else {
            Text(localized("game.thinking")).font(.caption).foregroundStyle(Palette.inkSoft)
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
        VStack(alignment: .leading, spacing: 8) {
            ChipCluster(
                title: localized("game.who"),
                options: Controller.allCases.map {
                    .init(value: $0, label: $0.label, isEnabled: $0 == .hand || engine.isReady)
                },
                selection: session.controller(for: colour)
            ) { controller in
                session.setController(controller, for: colour)
            }

            // 跟着我 is Mirrored Time, and it stands down when the engine is playing itself: there
            // is no player's last move to mirror, so the game names a clock instead.
            if session.controller(for: colour) == .engine {
                ChipCluster(
                    title: localized("game.perMove"),
                    options: ThinkingTime.offered.map {
                        .init(
                            value: $0, label: $0.label,
                            isEnabled: $0 != .mirrored || !session.isSelfPlaying
                        )
                    },
                    selection: session.thinkingTime
                ) { time in
                    session.setThinkingTime(time)
                }
            }
        }
        .padding(.top, 1)
    }

    private func arrow(
        _ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
                // The 44 points a thumb is entitled to, at the two ends of the control it is used
                // on most.
                .frame(width: 38, height: 42)
                .background(Palette.chipRest, in: RoundedRectangle(cornerRadius: 9))
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
        HStack(spacing: 6) {
            arrow("chevron.left", label: localized("record.previous"), enabled: session.cursor > 0)
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
        .frame(minHeight: 42)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .simultaneousGesture(forkSwipe)
        .accessibilityHint(session.forkPly == nil ? "" : "上下滑动切换分支")
    }

    /// Vertical swipe on the one row walks the tree: up is the next sibling, down the previous.
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

    /// Whether there is a curve to draw at all: one is made of Scores, and Scores are the engine's
    /// opinion — which practice is the state of not being given (docs/adr/0015). So a practising
    /// board has a plain strip, and so does a game nobody has scored.
    private var canShowCurve: Bool {
        !session.isPractising && session.game.isReviewed
    }

    /// The curve as a ground. It marks no cursor of its own — the card on the cursor is already
    /// filled, and a second mark is a second answer.
    private var curveGround: some View {
        EvalCurve(
            plies: session.game.plies.count,
            score: { session.game.reviewScore(atPly: $0) }
        )
        .accessibilityLabel(localized("record.curve"))
        .accessibilityValue(localized("record.ply", session.cursor))
    }

    private var moveStrip: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    openingCell
                    ForEach(moveCards) { card in
                        HStack(spacing: 6) {
                            Text("\(card.number)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Palette.inkSoft)
                                .frame(minWidth: 13, alignment: .trailing)
                            if let white = card.white { half(white) }
                            if let black = card.black { half(black) }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Palette.chipRest, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                .padding(.horizontal, 2)
                .background {
                    if canShowCurve { curveGround }
                }
            }
            .scrollIndicators(.hidden)
            // Where the eye is, kept in the middle of the strip as it moves — a record that
            // has scrolled off the position on the board is a record of somebody else's game.
            .onChange(of: session.cursor, initial: true) { _, now in
                withAnimation(.snappy(duration: 0.2)) { scroller.scrollTo(now, anchor: .center) }
            }
        }
    }

    /// The position the game began in, at the head of its own record. It is a place in the game
    /// like any other, and without it there is no way back to it in one tap.
    private var openingCell: some View {
        Button { walk(to: 0) } label: {
            Text(localized(session.game.plies.isEmpty ? "record.startHere" : "record.opening"))
                .font(.caption)
                .foregroundStyle(session.cursor == 0 ? Palette.parchment : Palette.inkSoft)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    session.cursor == 0
                        ? AnyShapeStyle(Palette.analysis) : AnyShapeStyle(Palette.chipRest),
                    in: RoundedRectangle(cornerRadius: 9)
                )
        }
        .buttonStyle(.plain)
        .id(0)
    }

    private func half(_ cell: PlyCell) -> some View {
        let on = cell.cursor == session.cursor
        let forked = cell.siblingCount > 1
        let mark = cell.isTrunk ? Palette.ink : Palette.mine
        return HStack(spacing: 3) {
            if forked {
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        session.cycleFork(atPly: cell.cursor - 1, by: 1)
                    }
                } label: {
                    ForkRail(current: cell.branchNumber ?? 1, of: cell.siblingCount, tint: mark)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换分支")
                .accessibilityValue(cell.spoken)
                .accessibilityHint("点一下换到下一条线")
            }
            Button { walk(to: cell.cursor) } label: {
                Text(cell.san)
                    .font(on ? .notation.weight(.bold) : .notation)
                    .foregroundStyle(on && !forked ? Palette.parchment : mark)
                    .padding(.horizontal, forked ? 3 : 5)
                    .padding(.vertical, 2)
                    .background {
                        if on && !forked {
                            RoundedRectangle(cornerRadius: 5).fill(Palette.analysis)
                        } else if on && forked {
                            RoundedRectangle(cornerRadius: 5).stroke(mark, lineWidth: 1.2)
                        }
                    }
            }
            .buttonStyle(.plain)
        }
        .id(cell.cursor)
        .accessibilityElement(children: forked ? .contain : .combine)
        // Said the way somebody reading a game aloud says it. A bare "Nf6" out of VoiceOver is a
        // move with no place in the game, and place is the whole of what this strip is for.
        .accessibilityLabel(cell.spoken)
        .accessibilityHint(localized(forked ? "record.branch" : "record.jump"))
    }

    /// What a ranked move cost its mover, in pawns. A move that *gained* is ranked too and reads
    /// as a gain rather than a negative loss — "−0.30 丢分" is a sentence nobody parses.
    private static func cost(_ lost: Int) -> String {
        let pawns = String(format: "%.1f", Double(abs(lost)) / 100)
        return lost > 0 ? "−\(pawns)" : "+\(pawns)"
    }

    /// Same family as 问一格: a layer you turn on, not a twin of 练习. 练习 is the eval strip;
    /// this is a question about the position (docs/adr/0023).
    ///
    /// It says what the press *does*, not what the card is called: a chip labelled 战术 under a
    /// head that also says 战术 is a switch nobody can read (docs/adr/0025).
    private var finderChip: some View {
        CardButton(
            label: session.isFindingTactics ? "不找了" : "找一记",
            isOn: !session.isFindingTactics,
            isEnabled: engine.isReady || session.isFindingTactics
        ) {
            withAnimation(.snappy(duration: 0.2)) {
                finderClosedByHand = session.isFindingTactics
                session.setFindingTactics(!session.isFindingTactics)
            }
        }
        .accessibilityLabel("战术发现器")
        .accessibilityValue(session.isFindingTactics ? "开" : "关")
    }

    /// 战术 — the shot, named in the verbs a player declares in.
    ///
    /// **The switch did become the card.** 战术发现器 has a press of its own on the card, but
    /// arriving here is also a press: the swipe is the asking, and leaving turns it off again
    /// unless somebody flipped it by hand (docs/adr/0025). 杀招 shares the same probe, so swiping
    /// between the two does not stop it and start it again.
    @ViewBuilder private var tacticsBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                finderChip
                Spacer(minLength: 0)
            }
            if session.isFindingTactics {
                tacticAnswer
            } else {
                // Two silences, and they are not the same silence. The deck has to open on one of
                // its two cards and both of them are questions for the engine, so the card in
                // front is dealt at rest and nobody has asked anything yet. Saying 「你自己关掉的」
                // there accuses the reader of an act they did not commit, and the next thing they
                // look for is the switch they are told they threw.
                Text(
                    finderClosedByHand
                        ? "发现器是你自己关掉的。按「找一记」再算一次 —— 顺手也就看出来有没有杀。"
                        : "还没算。按「找一记」就找 —— 顺手也就看出来有没有杀。"
                )
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

    private func sentence(_ text: String, colour: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(colour).frame(width: 6, height: 6)
                .padding(.top, 5)
            Text(text)
                .font(.caption)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }



    /// The games in this one's collection, and which one this is. Nil for a game that is not in a
    /// collection, or one not yet written to disk — there is nothing to be next to.
    private var placeInSeries: (entries: [GameLibrary.Entry], index: Int)? {
        guard let collection = session.collection, let url = session.url,
            let entries = library.collections.first(where: { $0.name == collection })?.entries,
            let index = entries.firstIndex(where: { $0.url == url })
        else { return nil }
        return (entries, index)
    }

    // ------------------------------------------------------------------ the deck

    /// One card of the deck under the record (docs/adr/0025).
    ///
    /// A kind rather than an index, because which card is dealt comes from the position — a past
    /// Ply opens on 练习 where the latest one opens on 要害 — and a card that cannot answer here
    /// says so on its own face rather than disappearing. An index would point at a different card
    /// every time the position changed shape.
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

    /// The deck, and the row of dots that says how many cards there are.
    ///
    /// The dots are the point as much as the paging is: eleven sections in a scroll never said how
    /// many there were, and 「这么多一连串的功能」 is what a screen gets called when it cannot.
    private var deckView: some View {
        TabView(selection: $card) {
            ForEach(cards, id: \.self) { kind in
                body(of: kind).tag(kind)
            }
        }
        // The index view is ours and it is above, on the card's own edge: a mate's tab wears a
        // colour of its own, and the built-in dots have no opinion about which page is urgent.
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: card) { was, now in turn(to: now, from: was) }
        // The engine's own move takes the clock. When it puts it down, the card in front
        // still wants a Line, and nobody will swipe again to ask.
        .onChange(of: session.thinking) { _, now in
            guard now == nil, wantsAdvice(card) else { return }
            session.adviseForCard()
        }
        // And a mate that turns up mid-game takes the eye, which is the whole of 「直接给予提示」
        // on a deck (docs/adr/0025). On the way in only: a 2 步杀 becoming a 1 步杀 is the same
        // news twice, and would drag somebody back to a card they had deliberately swiped away.
        .onChange(of: session.mateNews == nil) { was, now in
            guard was, !now else { return }
            // Never off a card that is already showing it — swiping to 战术 makes the probe find
            // the mate, and being thrown to 杀招 for it would make 战术 unreachable. The news still
            // lights 杀招's tab, so it is one coloured pill away rather than nothing.
            guard !wantsFinder(card) else { return }
            card = .mate
        }
    }

    /// The five names, in a segmented row. The page still swipes; tapping a name is the other
    /// way to the same card.
    private var rail: some View {
        DeckRail(
            cards: cards,
            current: card,
            tint: tabColour,
            name: { $0.title },
            go: { card = $0 }
        )
    }

    /// One card at a time, the same five whatever the position (docs/adr/0025).
    ///
    /// A real child of the column rather than a card laid over a spacer that was measured to find
    /// out how much room there was. The board's frame is fixed and a scroll view accepts whatever it
    /// is given, so the deck *is* the room that is left, and there is no state in which "the room
    /// has not been measured yet" can draw it at nothing — which is what put the deck, names and
    /// all, off the screen on any pass that settled in one go. The measurement existed for one
    /// reason: so the cards could not push the board around. A child that takes the leftover does
    /// not push anything, because the card's own length never reaches the layout above it
    /// (docs/adr/0025).
    private var deck: some View {
        VStack(spacing: 0) {
            DeckSurface {
                EmptyView()
            } content: {
                deckView
            }
            rail
                .frame(maxWidth: .infinity)
        }
        // Bottom-aligned so that a screen too short for the card still stands its names on the
        // glass, and the card gives way upward over the record rather than the names going off the
        // bottom. Nothing the app can be held at is that short — `DeckFloor` holds every screen to
        // the room the board reserves — but the way it fails is the way it should fail.
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    /// A mate's tab wears whose it is, and only while there is a mate to be about. A tab that is
    /// red all game is not a warning, it is a decoration.
    private func tabColour(_ kind: Card) -> Color {
        if kind == .mate, let news = session.mateNews {
            return news.isOurs ? Palette.mine : Palette.alarm
        }
        return Palette.ink
    }

    @ViewBuilder private func body(of kind: Card) -> some View {
        switch kind {
        case .mate: cardFrame(kind) { mateBody }
        case .tactics: cardFrame(kind) { tacticsBody }
        }
    }

    /// One card: one line saying what it answers, and then the thing itself. The name is on the
    /// rail under the card, so it is not said again here.
    private func cardFrame<Content: View>(
        _ kind: Card, @ViewBuilder body: () -> Content
    ) -> some View {
        CardScroll {
            VStack(alignment: .leading, spacing: 0) {
                Text(kind.subtitle)
                    .font(.caption2)
                    .foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                if kind == card, wantsAdvice(kind) {
                    if isCardSearching(kind) {
                        CardSearching(
                            progress: session.searchProgress, phrase: "正在算"
                        )
                    } else if let progress = standingProgress {
                        CardSearching(
                            progress: progress, phrase: "正在算", isRunning: false
                        )
                    }
                }
                body()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
    /// A swipe therefore spends a Stint where the card reads a Line — 杀招, 战术, 要害, 五步 —
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
            if !wantsFinder(now) { closeFinder() }
        case .tactics: if !wantsFinder(now) { closeFinder() }
        }
    }

    private func arrive(at now: Card) {
        switch now {
        case .mate:
            showsMateLine = true
            openFinder()
        case .tactics: openFinder()
        }
        if wantsAdvice(now) { session.adviseForCard() }
    }

    /// Both cards read a Line, so both spend a Stint on arrival, even during Practice.
    private func wantsAdvice(_ kind: Card) -> Bool {
        switch kind {
        case .mate, .tactics: true
        }
    }

    /// Depth already paid for, once the Stint has stopped. The card still names it so a cache
    /// hit does not look like the engine never ran.
    private var standingProgress: GameSession.SearchProgress? {
        if let progress = session.searchProgress, progress.depth > 0 { return progress }
        guard let analysis = session.analysis, analysis.depth > 0 else { return nil }
        return GameSession.SearchProgress(
            depth: analysis.depth,
            selectiveDepth: analysis.selectiveDepth,
            milliseconds: analysis.timeMilliseconds
        )
    }

    /// Whether this card currently has a search in flight, so the frame can say 正在算 and the
    /// depth. Neighbouring pages stay alive in a paged TabView; only the card in front speaks.
    private func isCardSearching(_ kind: Card) -> Bool {
        wantsAdvice(kind) && session.thinking == nil && session.isSearching
            && !session.isAdviceSpent
    }



    /// The two cards the finder answers for: the shot, and the mate that falls out of the same
    /// probe. Swiping between them does not stop and restart it.
    private func wantsFinder(_ kind: Card) -> Bool { kind == .mate || kind == .tactics }

    private func openFinder() {
        guard !session.isFindingTactics else { return }
        finderIsOurs = true
        session.setFindingTactics(true)
    }

    /// Puts back only what the swipe turned on. A switch somebody flipped by hand is theirs and
    /// stays as they left it — including on the strip, where it goes on colouring the mate's dot
    /// for the rest of the game.
    private func closeFinder() {
        guard finderIsOurs else { return }
        finderIsOurs = false
        session.setFindingTactics(false)
    }

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
                Text(news.head)
                    .font(.cardName)
                    .foregroundStyle(mateInk)
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
                HStack(spacing: 9) {
                    CardButton(
                        label: showsMateLine ? "把箭头收起" : "画在棋盘上",
                        isOn: showsMateLine,
                        isEnabled: !news.arrows.isEmpty
                    ) {
                        withAnimation(.snappy(duration: 0.2)) { showsMateLine.toggle() }
                    }
                    Spacer(minLength: 0)
                }
                if !news.isFullyDrawn {
                    CardNote("线太长，棋盘上只画了前 \(MateNews.arrowLimit) 步 —— 再多，一盘棋上就是一团线。")
                }
                CardNote("这几步没有走进棋谱。这是引擎已经算出来的东西，不是又替你算了一遍。")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 10)
        } else {
            // No news is news, and it is three different pieces of it. A card that goes blank when
            // there is no mate is a card that looks broken (docs/adr/0025).
            VStack(alignment: .leading, spacing: 6) {
                if viewed.isOver {
                    Text("这局已经走完了，没有下一步可算。")
                } else if session.isProbingTactics || session.isSearching {
                    EmptyView()
                } else if session.isFindingTactics || session.analysis != nil {
                    Text("这个局面几步之内没有杀 —— 双方都还没有强制的将死。")
                } else {
                    Text("滑到这张卡会算 10 秒。有杀的话算完就会说。")
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
        let byWidth = size.width - 16
        // And at an accessibility text size it gives back what the rows above it cost when they
        // grow — capped growth, but growth (see `chromeType`). A board is a grid: 312pt of it is
        // still a board to look at, where a card squeezed by the labels to 104pt is two lines of
        // itself and nothing else. `DeckFloor` reads the largest text size back off the render.
        let byHeight =
            size.height - (chrome + railReserve + cardWanted)
            - (accessibilityText ? accessibilityChrome : 0)
        return (min(byWidth, max(minBoard, byHeight)) / 8).rounded(.down) * 8
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
            lastMove: session.boardLastMove,
            checks: viewed.state.checkSquares,
            // The doubtful squares stay ringed on the board being played on, right up until the
            // first move — which is what replaces the old gate: the reading's own uncertainty is
            // visible where it matters, and 改棋子 is one tap away (docs/adr/0011).
            suspects: session.unconfirmedSquares,
            selected: selected,
            destinations: Set(candidateMoves.map(\.to)),
            captures: Set(candidateMoves.filter(\.isCapture).map(\.to)),
            recommendation: recommendation,
            // Whichever card is in front of you, and only that one: arrows left over from a card
            // you swiped away from are arrows about a position nobody is looking at (docs/adr/0025).
            plan: mateArrows,
            isInteractive: session.isHandTurn,
            onTap: tap
        )
    }

    // ------------------------------------------------------------------ doing

    /// Opens the next game in the collection in place of this one.
    ///
    /// It replaces the top of the path rather than pushing, so working through fifty positions does
    /// not build a stack of fifty screens to come back through — and the way back is still the
    /// library, which is where it was. How you are working carries over — that is `session.next`.
    private func turnTo(_ entry: GameLibrary.Entry) {
        session.suspend()
        guard let next = session.next(entry) else { return }
        selected = nil
        path[path.count - 1] = .game(next)
    }

    private func tap(_ square: Square) {
        guard session.isHandTurn else { return }

        if let selected {
            let moves = viewed.state.moves(from: selected).filter { $0.to == square }
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
        if let piece = boardPieces[square], piece.colour == viewed.state.sideToMove {
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

    private func walk(to cursor: Int) {
        selected = nil
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
        return viewed.state.moves(from: selected)
    }

    /// The position a tap is read against — the plan's tip while one is being written, and the
    /// position being studied otherwise. Only moves go through this; everything the app *says*
    /// still comes from `viewed`.
    private var recommendation: MoveSquares? {
        // The shot is 战术's own drawing and is drawn while that card is up. The engine's
        // recommendation underneath it is the strip's — 引擎意见 is a switch on the board, not a
        // card — so it is not gated by the deck. Practice still hides it: a card's Stint may
        // have left an Analysis in hand, and that is for the card, not for the board.
        if card == .tactics, session.isFindingTactics, let tactic = session.tactic {
            return MoveSquares(from: tactic.move.from, to: tactic.move.to)
        }
        guard !session.isPractising else { return nil }
        return session.analysis?.bestMove.flatMap { MoveSquares(uci: $0) }
    }

    /// Whether the position on screen is one being studied rather than one about to be played
    /// into — the single gate both board layers hang off.
    ///
    /// The position and not the screen, and not the switch either: play and study share one board
    /// now (docs/adr/0015), so what decides whether the app is allowed to point at hanging pieces
    /// is whether the move in question has already been played. On the live position these layers
    /// would be the blunder-check performed on the player's behalf, which is precisely the habit
    /// they exist to build.
    private var isPast: Bool { !session.isAtLatest }

    /// How the game on screen ended, if it has.
    ///
    /// A finished game has no Score: there is nothing left to search, so the engine says nothing and
    /// the bar would sit exactly half and half — the same picture it shows for a position nobody has
    /// looked at yet, and the opposite of the truth when someone has just been mated.
    private var finish: EvalBar.Finish? {
        switch viewed.state.outcome {
        case .ongoing: nil
        case .checkmate: .won(viewed.state.sideToMove.opposite)
        default: .drawn
        }
    }

    /// The colour whose pieces stand at the top of the board, and so the colour whose controls
    /// belong above it. Flipping the board moves them, which is the whole idea.
    private var topColour: PieceColour {
        session.orientation == .whiteAtBottom ? .black : .white
    }

    private var bottomColour: PieceColour {
        session.orientation == .whiteAtBottom ? .white : .black
    }

    /// Whether this colour is the one to move in the position being looked at — which is where
    /// the mark down the bar, the action and the engine's line all go.
    private func isOnClock(_ colour: PieceColour) -> Bool {
        !viewed.isOver && viewed.state.sideToMove == colour
    }

    private var moveCards: [MoveCard] {
        var cards: [MoveCard] = []
        var number = session.game.startingFullmoveNumber
        var side = session.game.startingSideToMove

        for (index, ply) in session.game.plies.enumerated() {
            let siblings = session.game.siblings(atPly: index)
            let here = siblings.first { $0.variationIndex == nil }
            let cell = PlyCell(
                cursor: index + 1,
                san: ply.san,
                isTrunk: ply.isTrunk,
                branchNumber: here?.number,
                siblingCount: siblings.count
            )
            if side == .white {
                cards.append(MoveCard(number: number, white: cell, black: nil))
            } else if let last = cards.last, last.number == number, last.black == nil {
                cards[cards.count - 1] = MoveCard(number: number, white: last.white, black: cell)
            } else {
                // A game that begins with Black to move, which is most games read off a photograph.
                cards.append(MoveCard(number: number, white: nil, black: cell))
            }
            if side == .black { number += 1 }
            side = side.opposite
        }
        return cards
    }
}

/// One ply as the record draws it: the cursor that puts it on the board, what it is called, and
/// where it sits in the tree — trunk or a numbered branch.
struct PlyCell: Hashable {
    let cursor: Int
    let san: String
    let isTrunk: Bool
    let branchNumber: Int?
    let siblingCount: Int

    var spoken: String {
        let step = "第 \(cursor) 步 \(san)"
        guard siblingCount > 1, let branchNumber else { return step }
        let kind = isTrunk ? "树干" : "树枝"
        return "\(step)，\(kind) \(branchNumber)/\(siblingCount)"
    }
}

/// The tree, compressed to one column of ticks. PGN writes a fork as parentheses; this is
/// that crease, thin enough to live in the scoresheet's own row. Each sibling is a ring on
/// a spine, the current one filled — a number sitting after the SAN was being read as a
/// move, which is the one thing a scoresheet cannot afford.
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

    private func tickIndex(_ current: Int) -> Int {
        if of <= 4 { return min(max(current, 1), ticks) }
        if current <= 1 { return 1 }
        if current >= of { return ticks }
        return min(2, ticks)
    }
}

/// One move number and its two halves — the way a scoresheet is ruled, and the unit the record
/// is scrolled in.
struct MoveCard: Identifiable, Hashable {
    let number: Int
    let white: PlyCell?
    let black: PlyCell?
    var id: Int { number }
}

extension GameScreen.Card {
    var title: String {
        switch self {
        case .mate: "杀招"
        case .tactics: "战术"
        }
    }

    /// One line saying what the card answers, in the words of somebody who does not yet know the
    /// name above it.
    var subtitle: String {
        switch self {
        case .mate: "几步之内有人要被将死了"
        case .tactics: "这一步有没有一记赢子的"
        }
    }
}
