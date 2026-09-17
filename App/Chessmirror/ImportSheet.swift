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
/// The sheet remembers (`ImportMemory`): the account that fetched last is in the field when its
/// door opens, the other accounts that have fetched are a chip away, and the door and count are
/// the ones used last time. The button says what it is about to do — 「拉 sunfmin 最近 10 局」 —
/// so a wrong name is caught before the network is asked, and when the site says there is no
/// such player, the message names the name as it was typed and the field it came from is
/// marked.
struct ImportSheet: View {
    /// Which door. Not a mode — all four share every state after the download, because after
    /// the download there is no difference between them.
    enum Door: String, Hashable, CaseIterable {
        case lichess
        case chessCom
        case chessease
        case link

        /// The site a door belongs to; the plain link door belongs to none.
        var site: PGNImport.Site? {
            switch self {
            case .lichess: .lichess
            case .chessCom: .chessCom
            case .chessease: .chessease
            case .link: nil
            }
        }

        /// A door that asks for a username rather than a link.
        var asksForPlayer: Bool { site.map { PGNImport.Site.withPlayers.contains($0) } ?? false }

        var label: String {
            switch self {
            case .link: localized("import.door.link")
            default: site!.label
            }
        }

        var explainer: String {
            switch self {
            case .lichess: localized("import.door.lichess.explained")
            case .chessCom: localized("import.door.chessCom.explained")
            case .chessease: localized("import.door.chessease.explained")
            case .link: localized("import.door.link.explained")
            }
        }

        var prompt: String {
            switch self {
            case .lichess, .chessCom: localized("import.field.player", site!.label)
            case .chessease: localized("import.field.share")
            case .link: localized("import.field.link")
            }
        }
    }

    let session: ImportSession
    let memory: ImportMemory
    /// The engine the games written by 入库 are analysed with, when there is one yet.
    let engine: (any Engine)?
    let onOpen: ((GameLibrary.Entry) -> Void)?

    @Environment(GameLibrary.self) private var library
    @Environment(MistakeIndex.self) private var index
    @Environment(\.dismiss) private var dismiss

    /// One field's text per door, so switching doors and back loses nothing typed.
    @State private var typed: [Door: String]
    @State private var door: Door
    @State private var count: Int
    @State private var choosingSide: PGNImport.ImportChapter?
    @FocusState private var isEditing: Bool

    /// - Parameters:
    ///   - initialInput: a link handed in from outside — the share extension — which opens the
    ///     door it belongs to with the link already in the field.
    ///   - initialDoor: the door to open, when not the one used last.
    init(
        session: ImportSession = ImportSession(),
        memory: ImportMemory = .shared,
        engine: (any Engine)? = nil,
        initialInput: String = "",
        initialDoor: Door? = nil,
        onOpen: ((GameLibrary.Entry) -> Void)? = nil
    ) {
        self.session = session
        self.memory = memory
        self.engine = engine
        self.onOpen = onOpen
        var typed: [Door: String] = [:]
        for site in PGNImport.Site.withPlayers {
            if let name = memory.latest(on: site), let door = Door(rawValue: site.rawValue) {
                typed[door] = name
            }
        }
        var door = initialDoor ?? Door(rawValue: memory.door) ?? .lichess
        if !initialInput.isEmpty {
            door = PGNImport.chesseaseGame(in: initialInput) != nil ? .chessease : .link
            typed[door] = initialInput
        }
        _typed = State(initialValue: typed)
        _door = State(initialValue: door)
        _count = State(initialValue: memory.count)
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

                    field
                    if door.asksForPlayer {
                        remembered
                        howMany
                    }

                    switch session.phase {
                    case .idle:
                        primaryButton(fetchLabel, isEnabled: canFetch, action: fetch)
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
        .onChange(of: session.phase) { _, phase in
            // A name is remembered the moment it has fetched something, and not before.
            guard case .ready = phase, let site = door.site, door.asksForPlayer else { return }
            memory.remember(input, on: site)
        }
        .onChange(of: door) { _, door in memory.door = door.rawValue }
        .onChange(of: count) { _, count in memory.count = count }
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

    /// The four doors. A chip each, because that is the app's one selector idiom.
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

    /// The one field, with the text this door had. Marked in the alarm colour when the failure
    /// under it is about what was typed here — a name the site does not know, a link that is not
    /// one — so the message and the field it is talking about read as one thing.
    private var field: some View {
        let isAtFault = if case .failed(let error) = session.phase { error.isAboutInput } else { false }
        return HStack(spacing: 8) {
            TextField(door.prompt, text: inputBinding)
                .keyboardType(door.asksForPlayer ? .asciiCapable : .URL)
                .textContentType(door.asksForPlayer ? .username : .URL)
                .submitLabel(.go)
                .onSubmit(fetch)
                .focused($isEditing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
                .foregroundStyle(Palette.ink)
            if !input.isEmpty {
                Button {
                    typed[door] = ""
                    session.reset()
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
        if let site = door.site, let names = memory.names[site], !names.isEmpty {
            HStack(spacing: 6) {
                Text(localized("import.remembered")).eyebrow()
                ForEach(names, id: \.self) { name in
                    Button {
                        typed[door] = name
                        session.reset()
                    } label: {
                        Chip(label: name, isOn: input.caseInsensitiveCompare(name) == .orderedSame)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            memory.forget(name, on: site)
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

    /// What the download found: one row per game, and what opening one will do.
    ///
    /// Through a player's door the account is known, so each row is that account's game as
    /// they would tell it — which colour they had, who they played, how it went — and opening
    /// it records their side's mistakes without asking. Through a link nobody is known, so a
    /// row is the chapter's own name and opening it asks whose mistakes to keep.
    private func ready(_ plan: PGNImport.ImportPlan) -> some View {
        let account = door.asksForPlayer && !input.isEmpty ? input : nil
        let standing = plan.chapters.map { session.status(of: $0, in: library, book: index) }
        let toAdd = standing.count { $0 == .notImported }
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary(of: plan))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Text(
                        account.map { localized("import.plan.tap.player", $0) }
                            ?? localized("import.plan.tap.link")
                    )
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 10)
                ForEach(plan.chapters) { chapter in
                    Divider().overlay(Palette.hairline)
                    row(chapter, account: account)
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
            if let applied = session.applied, toAdd == 0 {
                Text(
                    applied.imported == 0
                        ? localized("import.applied.none")
                        : engine == nil
                            ? localized("import.done", plural: applied.imported)
                            : standing.contains { if case .scoring = $0 { true } else { false } }
                                ? localized("import.applied", plural: applied.imported)
                                : localized("import.applied.landed", plural: applied.imported)
                )
                .font(.footnote)
                .foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            } else if toAdd > 0 {
                primaryButton(applyLabel(adding: toAdd, of: plan.chapters.count), isEnabled: true) {
                    session.apply(into: library, as: account, reviewingWith: engine)
                }
            }
            HStack(spacing: 10) {
                Button {
                    session.reset()
                    if !door.asksForPlayer { typed[door] = "" }
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

    /// 「入库 8 局（2 局已有）」: what the press will write, and what it will leave alone.
    private func applyLabel(adding: Int, of total: Int) -> String {
        var label = localized("import.apply", plural: adding)
        if total > adding { label += " " + localized("import.apply.skipped", plural: total - adding) }
        return label
    }

    /// One game to open. With an account: their colour as a swatch, the opponent, the verdict
    /// from their side, and when. Without: the chapter's name. The 错题本's standing on the game
    /// trails either.
    private func row(_ chapter: PGNImport.ImportChapter, account: String?) -> some View {
        let side = account.flatMap { PGNImport.side(of: $0, in: chapter.pgn) }
        let status = session.status(of: chapter, in: library, book: index).label
        let opponent = side.map { chapter.pgn.tag($0 == .white ? "Black" : "White") ?? "?" }
        let verdict = side.flatMap { PGNImport.verdict(for: $0, in: chapter.pgn) }
        let when = side != nil ? PGNImport.playedAt(chapter.pgn) : nil
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
                        Text(opponent ?? chapter.name)
                            .font(.subheadline)
                            .foregroundStyle(Palette.ink)
                        if let verdict {
                            Text(verdict)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Palette.inkSoft)
                        }
                    }
                    if let when {
                        Text(when)
                            .font(.footnote)
                            .foregroundStyle(Palette.inkSoft)
                    }
                }
                Spacer(minLength: 8)
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSoft)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            [side.map(\.label), opponent ?? chapter.name, verdict, when].compactMap { $0 }
                .joined(separator: " · ")
        )
        .accessibilityValue(status)
    }

    private func summary(of plan: PGNImport.ImportPlan) -> String {
        localized("import.plan.games", plural: plan.chapters.count)
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
            primaryButton(
                error.isAboutInput ? fetchLabel : localized("retry"), isEnabled: canFetch, action: fetch
            )
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

    private var input: String {
        (typed[door] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var inputBinding: Binding<String> {
        Binding(get: { typed[door] ?? "" }, set: { typed[door] = $0 })
    }

    private var canFetch: Bool { !input.isEmpty }

    /// What the button will do, said with the name and the number it will do it with — the
    /// sentence is the check that the right account is about to be asked.
    private var fetchLabel: String {
        switch door {
        case .lichess, .chessCom:
            input.isEmpty
                ? localized("import.fetch") : localized("import.fetch.recent", plural: count, input)
        case .chessease: localized("import.fetch.share")
        case .link: localized("import.fetch")
        }
    }

    private func fetch() {
        guard canFetch else { return }
        isEditing = false
        switch door {
        case .lichess, .chessCom:
            Task { await session.recent(of: input, count: count, on: door.site!) }
        case .chessease, .link:
            Task { await session.run(input) }
        }
    }
}

extension PGNImport.Error {
    /// A failure the typed text is answerable for — as against one the network or the site is.
    /// The sheet marks the field for these, and offers the fetch again rather than a bare retry,
    /// because what is wanted is a corrected input and not the same one a second time.
    var isAboutInput: Bool {
        switch self {
        case .notALink, .unknownPlayer, .notAPlayer, .noGames, .unreadableShare, .missingGame: true
        default: false
        }
    }
}
