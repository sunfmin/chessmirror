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

    var body: some View {
        GameScreen(session: session, path: $path, practiceNext: nextAction)
        .onChange(of: drill.isSettled) { _, settled in
            if settled { index.refresh() }
        }
    }

    private func goToNext() {
        guard let next, !path.isEmpty else { return }
        path[path.count - 1] = .drill(next, source)
    }

    private var nextAction: (() -> Void)? {
        guard next != nil else { return nil }
        return { goToNext() }
    }

    private var next: Mistake? {
        switch source {
        case .daily:
            return index.daily.cards.first { $0.position != mistake.position }?.mistake
        case .picked:
            let book = index.book.mistakes
            guard let here = book.firstIndex(where: { $0.position == mistake.position }),
                  book.count > 1 else { return nil }
            return book[(here + 1) % book.count]
        }
    }
}

/// Owns the attempt for one navigation destination, keeping its clock stable on redraws.
struct DrillHost: View {
    let mistake: Mistake
    let source: Drill.Source
    @Binding var path: [Step]
    @State private var drill: Drill?

    init(
        mistake: Mistake,
        engine: (any Engine)?,
        lines: JudgementLines,
        log: PracticeLog,
        source: Drill.Source = .picked,
        path: Binding<[Step]>
    ) {
        self.mistake = mistake
        self.source = source
        _path = path
        _drill = State(initialValue: Drill(
            position: mistake.position, engine: engine, log: log, lines: lines, source: source
        ))
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
