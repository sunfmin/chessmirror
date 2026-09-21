import ChessmirrorKit
import SwiftUI

/// The sheet that turns somebody's recent games, or a link, into games in the library
/// (docs/adr/0014, docs/adr/0045).
///
/// Four doors and one machine behind them. Two doors take a username — lichess and chess.com —
/// and fetch that player's last few games; one takes a 国象联盟 share link, which carries its game
/// with it; and one takes any other link, a lichess study or a single game. Whichever door,
/// every game that comes through becomes one file in the library. The downloading and reading
/// is `ImportSession`'s; this is the deck of controls around it, one state per phase.
///
/// Which door is open, what is typed at it, what the button says and when a name is remembered
/// are the kit's (`ImportDoors`); this draws them.
struct ImportSheet: View {
    typealias Door = ImportDoors.Door

    /// The engine the games written by 入库 are analysed with, when there is one yet.
    let engine: (any Engine)?
    let onOpen: ((GameLibrary.Entry) -> Void)?

    @Environment(GameLibrary.self) private var library
    @Environment(MistakeIndex.self) private var index
    @Environment(\.dismiss) private var dismiss

    @State private var doors: ImportDoors
    @State private var choosingSide: PGNImport.ImportChapter?
    @FocusState private var isEditing: Bool

    /// - Parameters:
    ///   - initialInput: a link handed in from outside — the share extension — which opens the
    ///     door it belongs to with the link already in the field.
    ///   - initialDoor: the door to open, when not the one used last.
    init(
        session: ImportSession = ImportSession(),
        memory: ImportMemory = PlayerSettings.shared.imports,
        engine: (any Engine)? = nil,
        initialInput: String = "",
        initialDoor: Door? = nil,
        onOpen: ((GameLibrary.Entry) -> Void)? = nil
    ) {
        self.engine = engine
        self.onOpen = onOpen
        _doors = State(initialValue: ImportDoors(
            session: session, memory: memory, initialInput: initialInput, initialDoor: initialDoor
        ))
    }

    private var session: ImportSession { doors.session }
    private var door: Door { doors.door }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    doorChips

                    Text(door.explainer)
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)

                    field
                    if door.asksForPlayer {
                        remembered
                        howMany
                    }

                    switch session.phase {
                    case .idle:
                        primaryButton(doors.fetchLabel, isEnabled: doors.canFetch, action: fetch)
                    case .fetching:
                        waiting(localized("import.fetching"))
                    case .ready(let plan):
                        ready(plan)
                    case .failed(let error):
                        failed(error)
                    }
                }
                .padding(16)
            }
            .background(Palette.parchment)
            .navigationTitle(localized("import.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.parchment, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(Palette.analysis)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(localized("cancel")) { dismiss() }
                }
            }
        }
        .confirmationDialog(
            localized("import.trackSide"),
            isPresented: Binding(
                get: { choosingSide != nil },
                set: { if !$0 { choosingSide = nil } }
            ),
            titleVisibility: .visible,
            presenting: choosingSide
        ) { chapter in
            ForEach([PieceColour.white, .black], id: \.self) { side in
                Button("\(side.label) · \(chapter.pgn.playerName(side) ?? "?")") {
                    if let entry = session.open(chapter, into: library, tracking: side) {
                        onOpen?(entry)
                        dismiss()
                    }
                }
            }
            Button(localized("cancel"), role: .cancel) { choosingSide = nil }
        }
    }

    // ------------------------------------------------------------------ parts

    /// The four doors. A chip each, because that is the app's one selector idiom.
    private var doorChips: some View {
        HStack(spacing: 8) {
            ForEach(Door.allCases, id: \.self) { candidate in
                Button {
                    doors.open(candidate)
                } label: {
                    Chip(label: candidate.label, isOn: door == candidate)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    /// The one field, with the text this door had. Marked in the alarm colour when the failure
    /// under it is about what was typed here — a name the site does not know, a link that is not
    /// one — so the message and the field it is talking about read as one thing.
    private var field: some View {
        let isAtFault = doors.isInputAtFault
        return HStack(spacing: 8) {
            TextField(door.prompt, text: Bindable(doors).text)
                .keyboardType(door.asksForPlayer ? .asciiCapable : .URL)
                .textContentType(door.asksForPlayer ? .username : .URL)
                .submitLabel(.go)
                .onSubmit(fetch)
                .focused($isEditing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
                .foregroundStyle(Palette.ink)
            if !doors.input.isEmpty {
                Button {
                    doors.clear()
                    isEditing = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSoft)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localized("import.clear"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isAtFault ? Palette.alarm : Palette.hairline, lineWidth: isAtFault ? 1.5 : 0.5)
        )
    }

    /// The accounts that have fetched through this door before, the one in the field marked.
    /// Absent until there is one, and a name can be struck off by holding it.
    @ViewBuilder
    private var remembered: some View {
        let names = doors.remembered
        if !names.isEmpty {
            HStack(spacing: 6) {
                Text(localized("import.remembered")).eyebrow()
                ForEach(names, id: \.self) { name in
                    Button {
                        doors.pick(name)
                    } label: {
                        Chip(label: name, isOn: doors.input.caseInsensitiveCompare(name) == .orderedSame)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            doors.forget(name)
                        } label: {
                            Label(localized("import.forget"), systemImage: "trash")
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// How many recent games. Fixed steps rather than a number to type: the useful answers are
    /// "the last few" and "enough for a flight", and neither is a number anyone has in mind.
    private var howMany: some View {
        HStack(spacing: 6) {
            Text(localized("import.howMany")).eyebrow()
            ForEach(ImportDoors.counts, id: \.self) { many in
                Button {
                    doors.ask(for: many)
                } label: {
                    Chip(label: "\(many)", isOn: doors.count == many)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    /// What the download found: one row per game, and what opening one will do.
    ///
    /// Through a player's door the account is known, so each row is that account's game as
    /// they would tell it — which colour they had, who they played, how it went — and opening
    /// it records their side's mistakes without asking. Through a link nobody is known, so a
    /// row is the chapter's own name and opening it asks whose mistakes to keep.
    private func ready(_ plan: PGNImport.ImportPlan) -> some View {
        let reading = doors.reading(plan, in: library, book: index, hasEngine: engine != nil)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(reading.summary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Text(reading.tapHint)
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 10)
                ForEach(plan.chapters) { chapter in
                    Divider().overlay(Palette.hairline)
                    row(chapter)
                }
                if plan.unreadable > 0 {
                    Divider().overlay(Palette.hairline)
                    Text(localized("import.unreadable", plural: plan.unreadable))
                        .font(.footnote)
                        .foregroundStyle(Palette.alarm)
                        .padding(.top, 10)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12))

            // The one press that makes the fetch real. Gone once there is nothing left to add,
            // and what it did stands in its place — the rows above carry the rest.
            if let applied = reading.applied {
                Text(applied)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let apply = reading.apply {
                primaryButton(apply, isEnabled: true) {
                    session.apply(into: library, as: doors.account, reviewingWith: engine)
                }
            }
            HStack(spacing: 10) {
                Button {
                    doors.again()
                } label: {
                    Text(localized("import.again"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(Palette.chipRest, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                if session.applied != nil {
                    Button {
                        dismiss()
                    } label: {
                        Text(localized("done"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Palette.parchment)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// One game to open. With an account: their colour as a swatch, the opponent, the verdict
    /// from their side, and when. Without: the chapter's name. The 错题本's standing on the game
    /// trails either.
    private func row(_ chapter: PGNImport.ImportChapter) -> some View {
        let row = doors.row(chapter, in: library, book: index)
        let side = row.side
        return Button {
            if let side {
                if let entry = session.open(chapter, into: library, tracking: side) {
                    onOpen?(entry)
                    dismiss()
                }
            } else {
                choosingSide = chapter
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let side {
                    Swatch(colour: side, size: 12)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.title)
                            .font(.subheadline)
                            .foregroundStyle(Palette.ink)
                        if let verdict = row.verdict {
                            Text(verdict)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Palette.inkSoft)
                        }
                    }
                    if let when = row.when {
                        Text(when)
                            .font(.footnote)
                            .foregroundStyle(Palette.inkSoft)
                    }
                }
                Spacer(minLength: 8)
                Text(row.status)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSoft)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.spoken)
        .accessibilityValue(row.status)
    }

    /// What went wrong, and the one thing there is to do about it. The wording comes with
    /// the error (`PGNImport.Error.alert`), so every door into an import says the same thing
    /// for the same failure — and a failure about a name says the name.
    private func failed(_ error: PGNImport.Error) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let alert = error.alert
            VStack(alignment: .leading, spacing: 4) {
                Text(alert.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.alarm)
                Text(alert.message)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSoft)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.alarm.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            primaryButton(doors.retryLabel, isEnabled: doors.canFetch, action: fetch)
        }
    }

    private func waiting(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).eyebrow()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    /// The one main button of whichever phase it serves, wearing the same ink fill the
    /// library's 拍棋盘 wears.
    private func primaryButton(
        _ label: String, isEnabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.parchment)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Palette.ink, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    // ------------------------------------------------------------------ doing

    private func fetch() {
        guard doors.canFetch else { return }
        isEditing = false
        Task { await doors.fetch() }
    }
}
