import ChessmirrorKit
import SwiftUI

/// The record: the strip, what the Review says, and the 错招 on it.
///
/// `GameScreen`'s own concern, split out for locality: the body composes these, and
/// what each one draws lives here so changing the record does not mean reading the
/// sides. They are extensions of `GameScreen` rather than types of their own because
/// they share its `@State` — a thumb's selection, a promotion being asked for — which
/// is the screen's, not a piece's.
extension GameScreen {
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
    var record: some View {
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
    @ViewBuilder var reviewRow: some View {
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
    @ViewBuilder var wrongMoves: some View {
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
    @ViewBuilder func punishRegister(exercise: Punishment?, answered: String?) -> some View {
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
    func slipTiles(_ tiles: [RecordReading.Tile]) -> some View {
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
    func slipTile(_ tile: RecordReading.Tile) -> some View {
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
    func slipCaption(_ tile: RecordReading.Tile) -> Text {
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
    func wrongTokens(_ wrongs: [RecordReading.WrongMove]) -> some View {
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
    func jumpTo(slip: Slip) {
        selected = nil
        session.jump(toPly: slip.positionPly)
    }

    /// The curve as a ground. It marks no cursor of its own — the card on the cursor is already
    /// filled, and a second mark is a second answer. History feedback is available in practice
    /// too: unknown positions remain unknown, and judgements and reviews supply the same curve.
    func curveGround(_ curve: ScoreCurve) -> some View {
        EvalCurve(curve: curve)
        .accessibilityLabel(localized("record.curve"))
        .accessibilityValue(localized("record.ply", curve.lastKnownPly ?? 0))
    }

    var moveStrip: some View {
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
    var forkSwipe: some Gesture {
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
    func openingCell(_ cell: RecordReading.Cell) -> some View {
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
    @ViewBuilder func slipMark(_ mark: RecordReading.Mark?) -> some View {
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
    func half(_ cell: RecordReading.Cell) -> some View {
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
    func costCaption(_ caption: RecordReading.Caption, on: Bool) -> some View {
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

}
