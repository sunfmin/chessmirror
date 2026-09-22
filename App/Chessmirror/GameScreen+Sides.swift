import ChessmirrorKit
import SwiftUI

/// The two sides of the board: who plays each colour, and its one button.
///
/// `GameScreen`'s own concern, split out for locality: the body composes these, and
/// what each one draws lives here so changing the record does not mean reading the
/// sides. They are extensions of `GameScreen` rather than types of their own because
/// they share its `@State` — a thumb's selection, a promotion being asked for — which
/// is the screen's, not a piece's.
extension GameScreen {
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
    func playerBar(_ colour: PieceColour) -> some View {
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
    @ViewBuilder var action: some View {
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
    @ViewBuilder func advice(for colour: PieceColour) -> some View {
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
    var askedReadout: String {
        guard let progress = session.searchProgress, progress.depth > 0 else {
            return localized("game.hold.deeper")
        }
        return localized("game.hold.progress", progress.seconds, progress.depth)
    }

    /// The ladder, behind the engine's name on its own bar. The rung picked is the game's at once
    /// — mid-move, if the engine is thinking — and the rung the next game starts at.
    var rungMenu: some View {
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

    func unfoldButton(_ colour: PieceColour) -> some View {
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
    func chips(for colour: PieceColour) -> some View {
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

    func arrow(
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

}
