import ChessmirrorKit
import SwiftUI

/// Practice uses the game's board, controls, findings and history. Only its first move
/// is a practice attempt; moving on never requires a navigation transition.
struct DrillScreen: View {
    let drill: Drill
    let mistake: Mistake
    var source: Drill.Source = .picked
    @Binding var path: [Step]
    @Environment(MistakeIndex.self) private var index
    @State private var session: GameSession

    init(drill: Drill, mistake: Mistake, source: Drill.Source = .picked, path: Binding<[Step]>) {
        self.drill = drill
        self.mistake = mistake
        self.source = source
        _path = path
        _session = State(initialValue: GameSession.practising(drill))
    }

    /// Today's queue follows the attempt on its own: the drill came from the index
    /// (`MistakeIndex.practise`), which works the day out again when it settles.
    var body: some View {
        GameScreen(session: session, path: $path, practiceNext: nextAction)
    }

    private func goToNext() {
        guard let next, !path.isEmpty else { return }
        path[path.count - 1] = .drill(next, source)
    }

    private var nextAction: (() -> Void)? {
        guard next != nil else { return nil }
        return { goToNext() }
    }

    private var next: Mistake? { index.practiceDay.next(after: mistake, source: source) }
}

/// Owns the attempt for one navigation destination, keeping its clock stable on redraws.
struct DrillHost: View {
    let mistake: Mistake
    let source: Drill.Source
    @Binding var path: [Step]
    @State private var drill: Drill?

    init(
        mistake: Mistake,
        index: MistakeIndex,
        engine: (any Engine)?,
        source: Drill.Source = .picked,
        path: Binding<[Step]>
    ) {
        self.mistake = mistake
        self.source = source
        _path = path
        // Which door it came through decides which verb: 日课's queue moves the schedule, a
        // pick off the book does not (计划外, docs/adr/0032). Two verbs rather than a tag to
        // remember, because a book drill tagged `.daily` quietly trains FSRS.
        _drill = State(
            initialValue: source == .daily
                ? index.practise(mistake, engine: engine)
                : index.practiseOnPurpose(mistake, engine: engine)
        )
    }

    var body: some View {
        if let drill {
            DrillScreen(drill: drill, mistake: mistake, source: source, path: $path)
        } else {
            Text(localized("book.empty"))
                .font(.footnote)
                .foregroundStyle(Palette.inkSoft)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.parchment)
        }
    }
}
