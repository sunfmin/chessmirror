import ChessfenKit
import SwiftUI

/// The sheet that turns a link, or somebody's recent games, into games in the library
/// (docs/adr/0014).
///
/// Two doors and one machine behind them: a link downloads a whole multi-game PGN — a lichess
/// study or a single game — and a username downloads that player's last few games. Either way
/// every game in what came down becomes one file in a collection. Opened from the library the
/// collection is asked for; opened from inside a collection it is pinned, which is the "add more
/// games to this collection" door. The downloading and reading is `ImportSession`'s; this is the
/// deck of controls around it, one state per phase.
struct ImportSheet: View {
    /// Which door. Not a mode — the two share every state after the download, because after the
    /// download there is no difference between them.
    enum Door: Hashable, CaseIterable {
        case link
        case player

        var label: String {
            switch self {
            case .link: localized("import.door.link")
            case .player: localized("import.door.player")
            }
        }

        var explainer: String {
            switch self {
            case .link: localized("import.door.link.explained")
            case .player: localized("import.door.player.explained")
            }
        }
    }

    /// The collection the import is pinned to, when the sheet was opened from inside one.
    let targetCollection: String?
    let session: ImportSession

    @Environment(GameLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var input: String
    @State private var collectionDraft = ""
    @State private var door: Door = .link
    @State private var player = ""
    @State private var count = PGNImport.recentGames

    init(
        targetCollection: String? = nil,
        session: ImportSession = ImportSession(),
        initialInput: String = "",
        initialDoor: Door = .link,
        initialPlayer: String = ""
    ) {
        self.targetCollection = targetCollection
        self.session = session
        _input = State(initialValue: initialInput)
        _door = State(initialValue: initialDoor)
        _player = State(initialValue: initialPlayer)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    doors

                    Text(door.explainer)
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)

                    switch door {
                    case .link:
                        field(localized("import.field.link"), text: $input, keyboard: .URL)
                    case .player:
                        field(localized("import.field.player"), text: $player, keyboard: .default)
                        howMany
                    }

                    collection

                    switch session.phase {
                    case .idle:
                        primaryButton(localized("import.fetch"), isEnabled: canFetch, action: fetch)
                    case .fetching:
                        waiting(localized("import.fetching"))
                    case .ready(let plan):
                        ready(plan)
                    case .importing:
                        waiting(localized("import.writing"))
                    case .done(let outcome):
                        done(outcome)
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
            .onAppear(perform: prefill)
            .onChange(of: session.phase) { _, _ in prefill() }
        }
    }

    // ------------------------------------------------------------------ parts

    /// The two doors. A chip each, because that is the app's one selector idiom.
    private var doors: some View {
        HStack(spacing: 8) {
            ForEach(Door.allCases, id: \.self) { candidate in
                Button {
                    door = candidate
                    session.reset()
                } label: {
                    Chip(label: candidate.label, isOn: door == candidate)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    /// How many recent games. Fixed steps rather than a number to type: the useful answers are
    /// "the last few" and "enough for a flight", and neither is a number anyone has in mind.
    private var howMany: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized("import.howMany")).eyebrow()
            HStack(spacing: 8) {
                ForEach([5, 10, 20, 50], id: \.self) { many in
                    Button {
                        count = many
                    } label: {
                        Chip(label: "\(many)", isOn: count == many)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func field(
        _ prompt: String, text: Binding<String>, keyboard: UIKeyboardType
    ) -> some View {
        TextField(prompt, text: text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.subheadline)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 0.5)
            )
    }

    /// Which collection this lands in: asked for, or pinned by the door the sheet came in
    /// through.
    @ViewBuilder
    private var collection: some View {
        if let targetCollection {
            Text(localized("import.into", targetCollection)).eyebrow()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(localized("import.intoCollection")).eyebrow()
                TextField(localized("collection.name"), text: $collectionDraft)
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 0.5)
                    )
            }
        }
    }

    /// What the download found, with the button that makes it real.
    private func ready(_ plan: PGNImport.ImportPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(summary(of: plan))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                // The first few names, so what is about to land can be checked against the
                // study it came from — all of them would scroll a sheet past its point.
                ForEach(plan.chapters.prefix(5)) { chapter in
                    Text(chapter.name)
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSoft)
                }
                if plan.chapters.count > 5 {
                    Text(localized("import.more", plural: plan.chapters.count - 5))
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSoft)
                }
                if plan.unreadable > 0 {
                    Text(localized("import.unreadable", plural: plan.unreadable))
                        .font(.footnote)
                        .foregroundStyle(Palette.alarm)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12))

            primaryButton(
                localized("import.apply", plural: plan.chapters.count),
                isEnabled: canImport, action: importNow
            )
        }
    }

    private func summary(of plan: PGNImport.ImportPlan) -> String {
        let many = localized("import.plan.games", plural: plan.chapters.count)
        guard let suggested = plan.suggestedCollection else { return many }
        return localized("import.plan.named", suggested, many)
    }

    private func done(_ outcome: PGNImport.ImportOutcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(outcome.message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
            HStack(spacing: 10) {
                Button {
                    session.reset()
                    input = ""
                    collectionDraft = ""
                } label: {
                    Text(localized("import.again"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(Palette.chipRest, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
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

    /// What went wrong, and the one thing there is to do about it. The wording comes with
    /// the error (`PGNImport.Error.alert`), so every door into an import says the same thing
    /// for the same failure.
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
            primaryButton(localized("retry"), isEnabled: true, action: fetch)
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

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPlayer: String {
        player.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canFetch: Bool {
        switch door {
        case .link: !trimmedInput.isEmpty
        case .player: !trimmedPlayer.isEmpty
        }
    }

    /// Whether there is a collection to import into. Pinned sheets always have one; free
    /// ones need a typed name — the collection is the point of the import, not a nicety,
    /// and an empty name would file the games nowhere.
    private var canImport: Bool {
        targetCollection != nil
            || !collectionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The study names its collection; prefill it. Only into a draft nobody has typed
    /// into yet — a suggestion is not an override.
    private func prefill() {
        guard case .ready(let plan) = session.phase,
            let suggested = plan.suggestedCollection,
            collectionDraft.isEmpty
        else { return }
        collectionDraft = suggested
    }

    private func fetch() {
        guard canFetch else { return }
        switch door {
        case .link:
            Task { await session.run(trimmedInput) }
        case .player:
            Task { await session.recent(of: trimmedPlayer, count: count) }
        }
    }

    private func importNow() {
        guard canImport, let name = targetCollection ?? Self.trimmed(collectionDraft) else { return }
        session.apply(into: name, library: library)
    }

    private static func trimmed(_ text: String) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
