import ChessmirrorKit
import SwiftUI

/// The 收藏集 a kind names, as it stands: a 自动集 from the index, a 自建集 from the shelf.
@MainActor
func positionCollection(
    _ kind: CollectionKind, index: MistakeIndex, shelf: CollectionShelf, library: GameLibrary
) -> PositionCollection? {
    switch kind {
    case .found: index.found.first { $0.kind == kind }
    case .player(let name): shelf.positionCollection(named: name, in: library)
    }
}

// ---------------------------------------------------------------------- 首页 rows

/// The 收藏集 on 首页, one row each, under the 错题本's door (docs/adr/0051): 杀招 and 战术 when
/// the games have put something in them, then 喜爱 — always, because a door nobody sees is a door
/// nobody learns about — then the player's own sets in the order they were made.
struct CollectionRows: View {
    @Binding var path: [Step]
    @Environment(MistakeIndex.self) private var index
    @Environment(CollectionShelf.self) private var shelf
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: String?
    @State private var refused = false

    private var kinds: [(kind: CollectionKind, count: Int)] {
        let found = index.found
            .filter { !$0.holdings.isEmpty }
            .map { (kind: $0.kind, count: $0.holdings.count) }
        let mine = shelf.collections.map { (kind: CollectionKind.player($0.name), count: $0.entries.count) }
        return found + mine
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(kinds.enumerated()), id: \.element.kind) { offset, row in
                if offset > 0 { Divider().padding(.leading, 18) }
                Button {
                    path.append(.collection(row.kind))
                } label: {
                    label(row.kind, count: row.count)
                }
                .buttonStyle(.plain)
                .contextMenu { menu(row.kind) }
            }
        }
        .background(Palette.chipRest, in: RoundedRectangle(cornerRadius: 14))
        .alert(
            localized("collection.rename"),
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField(localized("collection.name"), text: $newName)
            Button(localized("cancel"), role: .cancel) { renaming = nil }
            Button(localized("ok")) {
                if let name = renaming, !shelf.rename(name, to: newName) { refused = true }
                renaming = nil
            }
        }
        .confirmationDialog(
            localized("collection.deleteConfirm", deleting ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button(localized("collection.delete"), role: .destructive) {
                if let name = deleting { shelf.delete(name) }
                deleting = nil
            }
            Button(localized("cancel"), role: .cancel) { deleting = nil }
        } message: {
            Text(localized("collection.deleteExplained"))
        }
        .alert(localized("collection.nameUnusable"), isPresented: $refused) {
            Button(localized("ok")) { refused = false }
        }
    }

    private func label(_ kind: CollectionKind, count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(kind))
                .foregroundStyle(kind.isFound ? Palette.analysis : Palette.alarm)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.subheadline.weight(.medium))
                if kind.isFavourites, count == 0 {
                    Text(localized("collection.favouritesEmpty"))
                        .font(.caption)
                        .foregroundStyle(Palette.inkSoft)
                }
            }
            Spacer(minLength: 0)
            if count > 0 {
                Text(localized("collection.items", plural: count))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.inkSoft)
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Palette.inkSoft)
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// Only a set the player made, and not 喜爱, can be renamed or deleted.
    @ViewBuilder private func menu(_ kind: CollectionKind) -> some View {
        if case .player(let name) = kind, !kind.isFavourites {
            Button {
                newName = name
                renaming = name
            } label: {
                Label(localized("collection.rename"), systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleting = name
            } label: {
                Label(localized("collection.delete"), systemImage: "trash")
            }
        }
    }

    private func symbol(_ kind: CollectionKind) -> String {
        switch kind {
        case .found(let card): card.symbol
        case .player: kind.isFavourites ? "heart.fill" : "folder.fill"
        }
    }
}

// ---------------------------------------------------------------------- one set

/// One 收藏集 opened: its 藏局, the most recently kept first (docs/adr/0051).
///
/// There is no 「练这一组」. A set of 杀招 practised as a block tells the player the answer is a
/// mate before they look (docs/adr/0032); the 自动集 are in the 日课 already, shuffled in with the
/// 错题, and a pick from here is 计划外 and moves nothing.
struct CollectionScreen: View {
    let kind: CollectionKind
    @Binding var path: [Step]
    @Environment(MistakeIndex.self) private var index
    @Environment(CollectionShelf.self) private var shelf
    @Environment(GameLibrary.self) private var library
    @Environment(EngineHost.self) private var engine

    private var collection: PositionCollection? {
        positionCollection(kind, index: index, shelf: shelf, library: library)
    }

    var body: some View {
        List {
            let holdings = collection?.holdings ?? []
            if holdings.isEmpty {
                Text(localized(kind.isFavourites ? "collection.favouritesEmpty" : "collection.empty"))
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSoft)
                    .listRowBackground(Palette.parchment)
                    .listRowSeparator(.hidden)
            }
            ForEach(holdings) { holding in
                Button {
                    path.append(.drill(holding.position, .collection(kind)))
                } label: {
                    HoldingRow(holding: holding, isFound: kind.isFound)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        remove(holding)
                    } label: {
                        Label(localized(kind.isFound ? "collection.takeOut" : "collection.remove"),
                              systemImage: "minus.circle")
                    }
                }
                .swipeActions(edge: .leading) {
                    if let sighting = openable(holding) {
                        Button {
                            open(sighting)
                        } label: {
                            Label(localized("collection.openGame"), systemImage: "arrow.uturn.backward")
                        }
                        .tint(Palette.analysis)
                    }
                }
                .contextMenu {
                    if let sighting = openable(holding) {
                        Button {
                            open(sighting)
                        } label: {
                            Label(localized("collection.openGame"), systemImage: "arrow.uturn.backward")
                        }
                    }
                    Button(role: .destructive) {
                        remove(holding)
                    } label: {
                        Label(localized(kind.isFound ? "collection.takeOut" : "collection.remove"),
                              systemImage: "minus.circle")
                    }
                }
                .listRowBackground(Palette.parchment)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.parchment)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.parchment, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar(.visible, for: .navigationBar)
    }

    /// 移出 for a 自动集 — written to the log, for good — and a plain removal from a 自建集.
    private func remove(_ holding: Holding) {
        switch kind {
        case .found: index.takeOut(holding.position)
        case .player(let name): shelf.remove(holding.position, from: name)
        }
    }

    /// The game to go back to, when it is on this device to be opened.
    private func openable(_ holding: Holding) -> Sighting? {
        holding.sightings.first { library.entry(at: $0.game)?.pgn != nil }
    }

    private func open(_ sighting: Sighting) {
        let opener = GameOpener(engine: engine.service, library: library, settings: .shared)
        guard let session = opener.open(sighting.game, walkingTo: sighting.ply).session else { return }
        path.append(.game(session))
    }
}

/// One 藏局 as a row: the board from the side to move, whose move it is, where it came from, and
/// — in a 自动集 — whether the shot was the player's or the opponent's.
struct HoldingRow: View {
    let holding: Holding
    let isFound: Bool
    @Environment(GameLibrary.self) private var library

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail(holding.position, side: 96)
            VStack(alignment: .leading, spacing: 5) {
                Text(localized(holding.position.sideToMove == .white
                               ? "collection.whiteToMove" : "collection.blackToMove"))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.ink)
                if let source {
                    Text(source)
                        .font(.caption)
                        .foregroundStyle(Palette.inkSoft)
                        .multilineTextAlignment(.leading)
                }
                if isFound, let yours = holding.sightings.first?.isYours {
                    Text(localized(yours ? "collection.yours" : "collection.theirs"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(yours ? Palette.analysis : Palette.alarm)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background((yours ? Palette.analysis : Palette.alarm).opacity(0.12), in: Capsule())
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(Palette.inkSoft)
        }
        .padding(12)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    /// 「出自 某局，第 23 手」: the game's own name and the move about to be played there.
    private var source: String? {
        guard let sighting = holding.sightings.first,
            let entry = library.entry(at: sighting.game), let game = entry.pgn?.game
        else { return nil }
        return localized("collection.from", entry.title, game.moveNumber(ofPly: sighting.ply + 1))
    }
}

// ---------------------------------------------------------------------- the heart

/// ♡ over the board: keeps the position on the board (docs/adr/0051).
///
/// A tap on an empty heart puts the position in 喜爱 and says so, with a way to pick another set.
/// A tap on a full one opens the sets instead of emptying it — the position may be in several,
/// and one tap throwing all of them away is too much for one tap. A long press opens the sets
/// either way.
struct HeartButton: View {
    let session: GameSession
    /// What was just kept, for the line at the foot of the screen.
    @Binding var notice: String?
    @Binding var isChoosing: Bool
    @Environment(CollectionShelf.self) private var shelf

    private var position: PositionKey? { PositionKey(fen: session.viewed.state.fen) }
    private var isKept: Bool { position.map(shelf.isKept) ?? false }

    var body: some View {
        Image(systemName: isKept ? "heart.fill" : "heart")
            .foregroundStyle(isKept ? Palette.alarm : Palette.inkSoft)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.4) { isChoosing = true }
            .onTapGesture { tap() }
            .accessibilityElement()
            .accessibilityLabel(localized("collection.heart"))
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isKept ? localized("screen.on") : localized("noSlips.off"))
            .accessibilityAction { tap() }
            .accessibilityAction(named: localized("collection.choose")) { isChoosing = true }
    }

    private func tap() {
        guard let position else { return }
        if isKept {
            isChoosing = true
            return
        }
        if shelf.add(
            position, to: PlayerCollection.favouritesName, game: session.url,
            ply: session.viewed.plies.count
        ) {
            notice = CollectionKind.favourites.title
        }
    }
}

/// Every 自建集, ticked where the position already is, and a way to make another.
struct CollectionChooser: View {
    let session: GameSession
    @Environment(CollectionShelf.self) private var shelf
    @Environment(\.dismiss) private var dismiss
    @State private var isNaming = false
    @State private var newName = ""
    @State private var refused = false

    private var position: PositionKey? { PositionKey(fen: session.viewed.state.fen) }

    var body: some View {
        NavigationStack {
            List {
                Section(localized("collection.choose")) {
                    ForEach(shelf.collections, id: \.name) { set in
                        Button {
                            toggle(set.name)
                        } label: {
                            HStack {
                                Text(CollectionKind.player(set.name).title).foregroundStyle(Palette.ink)
                                Spacer(minLength: 0)
                                if let position, set.contains(position) {
                                    Image(systemName: "checkmark").foregroundStyle(Palette.analysis)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    Button {
                        newName = ""
                        isNaming = true
                    } label: {
                        Label(localized("collection.new"), systemImage: "plus")
                    }
                }
            }
            .navigationTitle(localized("collections"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("ok")) { dismiss() }
                }
            }
            .alert(localized("collection.new"), isPresented: $isNaming) {
                TextField(localized("collection.name"), text: $newName)
                Button(localized("cancel"), role: .cancel) {}
                Button(localized("ok")) { create() }
            }
            .alert(localized("collection.nameUnusable"), isPresented: $refused) {
                Button(localized("ok")) {}
            }
        }
    }

    private func toggle(_ name: String) {
        guard let position else { return }
        if shelf.collection(named: name)?.contains(position) == true {
            shelf.remove(position, from: name)
        } else {
            shelf.add(position, to: name, game: session.url, ply: session.viewed.plies.count)
        }
    }

    /// A new set, with the position already in it: nobody makes one to leave it empty.
    private func create() {
        guard shelf.create(newName) else {
            refused = true
            return
        }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let position {
            shelf.add(position, to: name, game: session.url, ply: session.viewed.plies.count)
        }
    }
}
