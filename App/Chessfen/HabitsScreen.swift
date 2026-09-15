import ChessfenKit
import SwiftUI

/// 老毛病 — the one honest statement about what the player keeps doing.
///
/// Counted from the saved games every time it is opened and stored nowhere (docs/adr/0018), so a
/// game corrected or deleted in the Files app changes what this says the next time it is asked.
///
/// There is no rating here and no accuracy percentage, on purpose. A number would be a fake one —
/// no opponents, no pool — and it would compete with the real rating the player already has
/// somewhere else. What this can honestly give is a count and a way back to the moves.
struct HabitsScreen: View {
    @Environment(GameLibrary.self) private var library
    @Environment(EngineHost.self) private var engine
    @Binding var path: [Step]

    /// Nil while it is still being counted, which is a moment rather than a state worth naming.
    @State private var habits: Habits?

    var body: some View {
        Group {
            if let habits {
                HabitsView(habits: habits) { open($0) }
            } else {
                counting
            }
        }
        .background(Palette.parchment)
        .navigationTitle(localized("habits"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.parchment, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await count() }
    }

    private var counting: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(localized("habits.counting")).font(.footnote).foregroundStyle(Palette.inkSoft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Off the main thread, because it replays a few plies of every game in the library and the
    /// list it reads is plain values.
    private func count() async {
        let entries = library.entries
        habits = await Task.detached(priority: .userInitiated) { Habits.over(entries) }.value
    }

    /// The way back to the move: the game it happened in, standing in the position it was made
    /// in — not after it. The board is then exactly where the Drill asks its question, which is
    /// the whole point of coming here.
    private func open(_ occurrence: Habit.Occurrence) {
        guard let entry = library.entries.first(where: { $0.url == occurrence.game }),
            let session = GameSession.opened(entry, engine: engine.service, library: library)
        else { return }
        session.jump(toPly: occurrence.ply - 1)
        path.append(.game(session))
    }
}

/// The tally, drawn. Given its answer rather than reading the library, so a screenshot of every
/// state it has is a value away.
struct HabitsView: View {
    let habits: Habits
    let open: (Habit.Occurrence) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                masthead

                if habits.hasNothingToCount {
                    note(localized("habits.nothing"))
                } else if habits.isClean {
                    note(localized("habits.clean", plural: habits.gamesCounted))
                } else {
                    ForEach(habits.habits) { habit in
                        card(habit)
                    }
                }

                footer
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Palette.parchment)
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localized("habits")).font(.title2.weight(.bold)).foregroundStyle(Palette.ink)
            Text(localized("habits.subtitle"))
                .font(.footnote)
                .foregroundStyle(Palette.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    private func card(_ habit: Habit) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(habit.mode.label)
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                Text(localized("habits.times", plural: habit.count))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.alarm)
                Spacer(minLength: 0)
            }
            Text(habit.mode.explanation)
                .font(.footnote)
                .foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(habit.occurrences) { occurrence in
                    Button {
                        open(occurrence)
                    } label: {
                        row(occurrence)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ occurrence: Habit.Occurrence) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(localized("move.number", occurrence.moveNumber))
                        .font(.caption)
                        .foregroundStyle(Palette.inkSoft)
                    Text("\(occurrence.mover.label) \(occurrence.san)")
                        .font(.notation)
                        .foregroundStyle(Palette.ink)
                }
                if let note = occurrence.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(occurrence.title)
                    .font(.caption2)
                    .foregroundStyle(Palette.inkSoft.opacity(0.8))
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(Palette.inkSoft)
                .padding(.top, 2)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.inkSoft.opacity(0.15)).frame(height: 0.5)
        }
        .contentShape(Rectangle())
    }

    /// How much was read, and what was left out. Said even when nothing was left out, because a
    /// count means nothing without the number of games behind it.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localized("habits.counted", plural: habits.gamesCounted))
                .font(.caption)
                .foregroundStyle(Palette.inkSoft)
            ForEach(habits.exclusions, id: \.reason) { exclusion in
                Text(
                    localized(
                        "habits.excluded", plural: exclusion.count, exclusion.reason.label
                    )
                )
                    .font(.caption)
                    .foregroundStyle(Palette.inkSoft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Palette.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12))
    }
}
