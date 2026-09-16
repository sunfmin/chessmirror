import ChessmirrorKit
import SwiftUI

/// The sheet that turns a link, or somebody's recent games, into games in the library
/// (docs/adr/0014).
///
/// Two doors and one machine behind them: a link downloads a whole multi-game PGN — a lichess
/// study or a single game — and a username downloads that player's last few games. Either way
/// every game in what came down becomes one file in the library. The downloading and reading is
/// `ImportSession`'s; this is the deck of controls around it, one state per phase.
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

    let session: ImportSession
    let onOpen: ((GameLibrary.Entry) -> Void)?

    @Environment(GameLibrary.self) private var library
    @Environment(MistakeIndex.self) private var index
    @Environment(\.dismiss) private var dismiss

    @State private var input: String
    @State private var door: Door = .link
    @State private var player = ""
    @State private var count = PGNImport.recentGames
    @State private var choosingSide: PGNImport.ImportChapter?

    init(
        session: ImportSession = ImportSession(),
        initialInput: String = "",
        initialDoor: Door = .link,
        initialPlayer: String = "",
        onOpen: ((GameLibrary.Entry) -> Void)? = nil
    ) {
        self.session = session
        self.onOpen = onOpen
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
                Button("\(side.label) · \(chapter.pgn.tag(side == .white ? "White" : "Black") ?? "?")") {
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

    /// What the download found, with the button that makes it real.
    private func ready(_ plan: PGNImport.ImportPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(summary(of: plan))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                // The first few names, so what is about to land can be checked against the
                // study it came from — all of them would scroll a sheet past its point.
                ForEach(plan.chapters) { chapter in
                    Button {
                        choosingSide = chapter
                    } label: {
                        HStack {
                            Text(chapter.name)
                            Spacer()
                            Text(session.status(of: chapter, in: library, book: index).label)
                                .foregroundStyle(Palette.inkSoft)
                        }
                    }
                    .font(.footnote)
                    .accessibilityLabel(chapter.name)
                    .accessibilityValue(session.status(of: chapter, in: library, book: index).label)
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

        }
    }

    private func summary(of plan: PGNImport.ImportPlan) -> String {
        localized("import.plan.games", plural: plan.chapters.count)
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
        session.apply(into: library)
    }
}
