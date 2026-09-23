import ChessmirrorKit
import SwiftUI

/// Who is ahead, and the 把关 switch that shares its row.
///
/// `GameScreen`'s own concern, split out for locality: the body composes these, and
/// what each one draws lives here so changing the record does not mean reading the
/// sides. They are extensions of `GameScreen` rather than types of their own because
/// they share its `@State` — a thumb's selection, a promotion being asked for — which
/// is the screen's, not a piece's.
extension GameScreen {
    // ------------------------------------------------------------------ the standing

    /// Who is ahead, said once, along the foot of the board.
    ///
    /// Controls and depth share a single-line header; the balance gets the full width below.
    /// Temporary explanations get their own space instead of squeezing either label into two
    /// lines. Interception can be switched off without hiding the position's assessment.
    var standing: some View {
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
    func wrongToken(_ wrong: RecordReading.WrongMove, index: Int) -> some View {
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
    @ViewBuilder func replyRow(_ reading: ReplyReading) -> some View {
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
    @ViewBuilder func rejudgeControl(_ reading: ReplyReading) -> some View {
        switch session.rejudgeOffer(at: reading.index) {
        case .running(let depth):
            ProgressView().controlSize(.mini)
            Text(Depth.label(depth))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Palette.inkSoft)
        case .none:
            if let depth = reading.move.depth {
                Text(localized("game.depth", depth))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.inkSoft)
            }
        case .waiting, .ready:
            if let depth = reading.move.depth {
                Text(localized("game.depth", depth))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.inkSoft)
            }
            let offer = session.rejudgeOffer(at: reading.index)
            Button { session.rejudge(at: reading.index) } label: {
                Text(localized("tried.rejudge", RejudgeOffer.depth))
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

    /// Interception is the page's only mode switch. Assessment and explicit answers are separate.
    var noSlipsSwitch: some View {
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

}
