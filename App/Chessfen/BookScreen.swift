import ChessfenKit
import SwiftUI

/// 错题本: every position this player keeps getting wrong, flat and in one order (docs/adr/0028).
///
/// **Flat, and not filed.** There are no openings here, no tactical themes, no folders — an
/// opening name is a thing a player would have to know before they could find their own mistake,
/// and a theme is the engine's word for it rather than theirs. One list, most pressing first, and
/// the sort is 复发 before cost: twelve percent three times is a hole in someone's understanding
/// and forty percent once may only mean they were tired.
struct BookScreen: View {
    @Environment(GameLibrary.self) private var library
    @Environment(MistakeIndex.self) private var index
    @Binding var path: [Step]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if index.book.isEmpty {
                    Text(localized("book.empty"))
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                }
                ForEach(index.book.mistakes) { mistake in
                    Button {
                        path.append(.mistake(mistake))
                    } label: {
                        BookRow(mistake: mistake)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Palette.parchment)
        .navigationTitle(localized("book"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.parchment, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

/// One 错题, as a row: the position, and the sentence about it.
///
/// The board is the title. A FEN is not a name a person recognises and neither is "Sicilian,
/// Najdorf" — what they recognise is the picture they were looking at when they got it wrong.
struct BookRow: View {
    let mistake: Mistake

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail(mistake.position, side: 64)
            VStack(alignment: .leading, spacing: 5) {
                Text(mistake.sentence())
                    .font(.footnote)
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    badge(localized("book.cost", Int(mistake.worstCost.rounded())), Palette.alarm)
                    badge(localized("book.times", mistake.recurrence), Palette.analysis)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(Palette.inkSoft)
        }
        .padding(12)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12))
    }

    private func badge(_ text: String, _ colour: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(colour)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(colour.opacity(0.12), in: Capsule())
    }
}

/// One 错题 opened: the position, its history, and the two things that can be done with it.
struct BookEntryScreen: View {
    let mistake: Mistake

    @Environment(GameLibrary.self) private var library
    @Environment(MistakeIndex.self) private var index
    @Environment(EngineHost.self) private var engine
    @Binding var path: [Step]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                board
                Text(mistake.sentence())
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink)

                Text(localized("book.encounters")).eyebrow().padding(.top, 4)
                ForEach(mistake.encounters) { encounter in
                    Button {
                        open(encounter)
                    } label: {
                        row(encounter)
                    }
                    .buttonStyle(.plain)
                    .disabled(entry(for: encounter) == nil)
                }

                // No reason is asked for. The app does not get to interrogate somebody about
                // what they want to spend their own time on (docs/adr/0028); the striking-off is
                // written to the practice log as a thing they did, and can be undone by nothing
                // more than the game turning up again.
                Button(role: .destructive) {
                    index.dismiss(mistake.position)
                    path.removeLast()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                        Text(localized("book.remove")).font(.subheadline.weight(.medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Palette.alarm)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(Palette.alarm.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Palette.parchment)
        .navigationTitle(localized("book"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.parchment, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    /// Drawn from the player's own side, because that is the side that has to find the move.
    ///
    /// Squared by an empty layer rather than by `aspectRatio` on the board itself: `BoardView` is
    /// a `GeometryReader` and takes whatever it is offered, so it has no shape of its own to keep.
    private var board: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                BoardView(
                    pieces: PositionDraft(fen: mistake.position.text)?.pieces ?? [:],
                    orientation: mistake.position.sideToMove == .white
                        ? .whiteAtBottom : .blackAtBottom,
                    isInteractive: false
                )
            }
            .frame(maxWidth: 340)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func row(_ encounter: Encounter) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(localized("book.yourMove")).font(.caption).foregroundStyle(Palette.inkSoft)
                    Text(encounter.played).font(.notation).foregroundStyle(Palette.alarm)
                    if let wanted = encounter.wanted {
                        Text(localized("book.better")).font(.caption).foregroundStyle(Palette.inkSoft)
                        Text(wanted).font(.notation).foregroundStyle(Palette.analysis)
                    }
                }
                Text(detail(encounter))
                    .font(.caption)
                    .foregroundStyle(Palette.inkSoft)
            }
            Spacer(minLength: 0)
            Text(localized("book.cost", Int(encounter.cost.rounded())))
                .font(.caption2.weight(.medium))
                .foregroundStyle(Palette.alarm)
            // Only when there is a game to go to: a row that offers to open a file iCloud has
            // not handed over yet is a row that does nothing when it is tapped.
            if entry(for: encounter) != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Palette.inkSoft)
            }
        }
        .padding(12)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12))
    }

    /// When, and which game — with the file's own name rather than the position's, because the
    /// thing a person is trying to find here is the evening they played it.
    private func detail(_ encounter: Encounter) -> String {
        let when = Mistake.ago(from: encounter.when, to: Date())
        guard let entry = entry(for: encounter) else { return when }
        return entry.title + localized("clause.separator") + when
    }

    private func entry(for encounter: Encounter) -> GameLibrary.Entry? {
        library.entries.first { $0.url == encounter.game }
    }

    /// Straight to the move itself, so the board shows what was played rather than the moment
    /// before it — the position is already on the screen above.
    private func open(_ encounter: Encounter) {
        guard let entry = entry(for: encounter),
            let session = GameSession.opened(entry, engine: engine.service, library: library)
        else { return }
        session.jump(toPly: encounter.ply)
        path.append(.game(session))
    }
}

/// A small board, for a list. Non-interactive and without coordinates: at this size the letters
/// are noise and the squares are too small to hit anyway.
@ViewBuilder
func thumbnail(_ position: PositionKey, side: CGFloat) -> some View {
    BoardView(
        pieces: PositionDraft(fen: position.text)?.pieces ?? [:],
        orientation: position.sideToMove == .white ? .whiteAtBottom : .blackAtBottom,
        coordinates: false,
        isInteractive: false
    )
    .frame(width: side, height: side)
    .clipShape(RoundedRectangle(cornerRadius: 6))
}
