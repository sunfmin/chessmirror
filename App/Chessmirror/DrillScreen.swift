import ChessmirrorKit
import SwiftUI

/// Practice uses the game's board, controls, findings and history. Only its first move
/// is a practice attempt; moving on never requires a navigation transition.
struct DrillScreen: View {
    let drill: Drill
    let position: PositionKey
    var queue: DrillQueue = .book
    @Binding var path: [Step]
    @Environment(MistakeIndex.self) private var index
    @Environment(CollectionShelf.self) private var shelf
    @Environment(GameLibrary.self) private var library
    @State private var session: GameSession

    init(drill: Drill, position: PositionKey, queue: DrillQueue = .book, path: Binding<[Step]>) {
        self.drill = drill
        self.position = position
        self.queue = queue
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
        path[path.count - 1] = .drill(next, queue)
    }

    private var nextAction: (() -> Void)? {
        guard next != nil else { return nil }
        return { goToNext() }
    }

    /// 下一道, by the queue this one came from: today's, the book's order, or the set's list.
    private var next: PositionKey? {
        switch queue {
        case .daily:
            return index.practiceDay.next(after: position)
        case .book:
            guard let mistake = index.book[position] else { return nil }
            return index.practiceDay.next(after: mistake, source: .picked)?.position
        case .collection(let kind):
            return positionCollection(kind, index: index, shelf: shelf, library: library)?
                .next(after: position)
        }
    }
}

/// Owns the attempt for one navigation destination, keeping its clock stable on redraws.
struct DrillHost: View {
    let position: PositionKey
    let queue: DrillQueue
    @Binding var path: [Step]
    @State private var drill: Drill?

    init(
        position: PositionKey,
        index: MistakeIndex,
        engine: (any Engine)?,
        queue: DrillQueue = .book,
        path: Binding<[Step]>
    ) {
        self.position = position
        self.queue = queue
        _path = path
        // Which door it came through decides which verb: 日课's queue moves the schedule, a
        // pick off the book or a 收藏集 does not (计划外, docs/adr/0032). A book drill tagged
        // `.daily` would quietly train FSRS.
        _drill = State(initialValue: index.practise(position, engine: engine, source: queue.source))
    }

    var body: some View {
        if let drill {
            DrillScreen(drill: drill, position: position, queue: queue, path: $path)
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
