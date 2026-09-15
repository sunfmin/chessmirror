import ChessfenKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Where the app goes next. A game is pushed by identity, because the session it shows is a live
/// object rather than a value that can be recreated.
///
/// There is no review here. A Review is not a place: it is what the engine's opinion switched on
/// looks like, on the same board the game is played on (docs/adr/0015).
enum Step: Hashable {
    case confirm(PositionProposal)
    case game(GameSession)
    /// The 错题本. It carries nothing, because it is derived from the games every time it is
    /// opened and is not a second store of anything (docs/adr/0028, docs/adr/0029).
    case book
    /// One 错题, carried by value: it is a position and the occasions hanging off it, and both
    /// were computed before this screen was pushed.
    case mistake(Mistake)
    /// The same 错题, being practised. Separate from looking at it, because a drill is a question
    /// and the history is the answer to a different one (docs/adr/0029).
    case drill(Mistake, Drill.Source)
}

/// A typed name, or nil for one that was only spaces — which is how a name is taken back off.
private func trimmed(_ text: String) -> String? {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.isEmpty ? nil : clean
}

struct LibraryScreen: View {
    @Environment(EngineHost.self) private var engine
    @Environment(GameLibrary.self) private var library
    @Environment(MistakeIndex.self) private var index
    private let judgement = JudgementSetting.shared

    @State private var path: [Step] = []
    @State private var isCameraOpen = false
    @State private var isPhotoPickerOpen = false
    @State private var isFileImporterOpen = false
    @State private var isAboutShowing = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isRecognising = false
    @State private var failure: (title: String, message: String)?
    @State private var isImporting = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 14) {
                    masthead
                    if let reason = engine.unavailableReason {
                        note(reason, symbol: "exclamationmark.triangle.fill")
                    }
                    entries
                    dailyDoor
                    bookDoor
                    games
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Palette.parchment)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.parchment, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(Palette.analysis)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if case .starting = engine.status {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(localized("library.engineStarting")).eyebrow()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAboutShowing = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .sheet(isPresented: $isAboutShowing) { AboutScreen() }
            .sheet(isPresented: $isImporting) { ImportSheet() }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .confirm(let proposal):
                    ConfirmPositionScreen(proposal: proposal, path: $path)
                case .game(let session):
                    GameScreen(session: session, path: $path)
                case .book:
                    BookScreen(path: $path)
                case .mistake(let mistake):
                    BookEntryScreen(mistake: mistake, path: $path)
                case .drill(let mistake, let source):
                    DrillHost(
                        mistake: mistake,
                        engine: engine.service,
                        lines: judgement.lines,
                        log: index.log,
                        source: source,
                        path: $path
                    )
                }
            }
            .overlay {
                if isRecognising { recognising }
            }
        }
        .fullScreenCover(isPresented: $isCameraOpen) {
            BoardCameraScreen { picked in
                guard let image = BoardImageLoader.image(from: picked) else {
                    failure = BoardIntake.Intake.unreadableAlert
                    return
                }
                // The camera's is the only copy of this picture; the other ways in have
                // their original elsewhere already.
                recognise(.image(image), keepingPhotograph: true)
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $isPhotoPickerOpen, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    failure = BoardIntake.Intake.unreadableAlert
                    return
                }
                recognise(.data(data))
            }
        }
        .fileImporter(
            isPresented: $isFileImporterOpen,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    failure = BoardIntake.Intake.unreadableAlert
                    return
                }
                recognise(.file(url))
            case .failure(let error):
                failure = (localized("library.noPicture"), error.localizedDescription)
            }
        }
        .alert(failure?.title ?? "", isPresented: .constant(failure != nil)) {
            Button(localized("ok")) { failure = nil }
        } message: {
            Text(failure?.message ?? "")
        }
        // A picture somebody shared into the app from somewhere else. The extension wrote it
        // and stopped there; this is the half that reads it (docs/adr/0033). Coming forward is
        // the cue rather than the URL, because the URL is only a shortcut — a share the system
        // declined to open the app for is still waiting here, and is found the next time the
        // app is looked at. `initial` covers a launch that starts active.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            takeWhatWasShared()
        }
        .onOpenURL { _ in takeWhatWasShared() }
        // The 错题本 is derived, so it is brought up to date whenever the games change or a line
        // moves — and costs nothing when neither has, because the index walks only what is new
        // (docs/adr/0028). `initial` covers the launch, where the library is already listed.
        .onChange(of: library.entries, initial: true) { _, entries in
            index.update(from: entries, lines: judgement.lines)
        }
        .onChange(of: judgement.lines) { _, lines in
            index.update(from: library.entries, lines: lines)
        }
    }

    // ------------------------------------------------------------------ parts

    /// The name, set rather than accepted. 镜 does two jobs here — a lens, and a mirror: the app
    /// puts the board in front of you onto the phone, unchanged.
    private var masthead: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(localized("app.name"))
                    .font(.system(size: 34, weight: .bold))
                    .tracking(6)
                    .foregroundStyle(Palette.ink)
                Text(localized("app.mark"))
                    .font(.caption2.weight(.medium))
                    .tracking(3)
                    .foregroundStyle(Palette.inkSoft)
            }
            Text(localized("library.tagline"))
                .font(.footnote)
                .foregroundStyle(Palette.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    /// The two ways in. Photographing a board is the one this app is for, so it is the one that
    /// looks like a button — the other three ways to hand it a picture are behind the chevron.
    private var entries: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                Button {
                    isCameraOpen = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "camera.fill").font(.title3)
                        Text(localized("library.photograph")).font(.headline)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Palette.parchment)
                    .padding(.leading, 18)
                    .padding(.vertical, 16)
                    // The dark fill belongs to the row, not to this label, so the label has to
                    // claim its half of the row as a tap target or only the glyph would answer.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Menu {
                    Button {
                        isPhotoPickerOpen = true
                    } label: {
                        Label(localized("library.fromAlbum"), systemImage: "photo.on.rectangle")
                    }
                    Button {
                        paste()
                    } label: {
                        Label(localized("library.paste"), systemImage: "doc.on.clipboard")
                    }
                    Button {
                        isFileImporterOpen = true
                    } label: {
                        Label(localized("library.fromFiles"), systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.parchment)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 18)
                        .contentShape(Rectangle())
                }
                .overlay(alignment: .leading) {
                    Rectangle().fill(Palette.parchment.opacity(0.25)).frame(width: 0.5)
                }
            }
            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 14))

            Button {
                start(Game(startFEN: PGN.standardStartFEN))
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                    Text(localized("library.fromStart")).font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .background(Palette.chipRest, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)

            Button {
                isImporting = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                    Text(localized("import.title")).font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .background(Palette.chipRest, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    /// 日课, and how much of it is left (docs/adr/0030).
    ///
    /// It opens the next question rather than a list of them, and that is the design rather than
    /// a shortcut: a screen listing today's queue is a screen somebody picks from, and picking is
    /// exactly what a spaced schedule exists to take off them (docs/adr/0032). There is one verb
    /// here and it is 下一道.
    @ViewBuilder private var dailyDoor: some View {
        let left = index.daily.remaining
        Button {
            guard let next = index.daily.next else { return }
            path.append(.drill(next.mistake, .daily))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sun.max")
                Text(localized("daily")).font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
                Text(
                    left > 0
                        ? localized("daily.left", plural: left)
                        : localized(index.book.isEmpty ? "daily.none" : "daily.done")
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(left > 0 ? Palette.parchment : Palette.inkSoft)
                if left > 0 {
                    Image(systemName: "chevron.right").font(.caption2)
                }
            }
            .foregroundStyle(left > 0 ? Palette.parchment : Palette.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(
                left > 0 ? Palette.analysis : Palette.chipRest,
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
        .disabled(left == 0)
    }

    /// The way into the 错题本, carrying how many are in it (docs/adr/0028).
    ///
    /// Always on the screen, including when it is empty: a door that appears only once there is
    /// something behind it is a door nobody learns about, and the sentence behind it when it is
    /// empty says what puts things there.
    private var bookDoor: some View {
        Button {
            path.append(.book)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "book.closed")
                Text(localized("book")).font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
                if !index.book.isEmpty {
                    Text(localized("book.items", plural: index.book.mistakes.count))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Palette.alarm)
                }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Palette.inkSoft)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(Palette.chipRest, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    /// The games, as one flat list.
    ///
    /// Flat, and that is the change: a game used to be a work that got curated into a collection,
    /// and it is raw material now — nobody curates the source of their own mistakes (docs/adr/0028).
    /// What a person looks for here is the game they just played, so the order is the order they
    /// arrived in and there is nothing to open first.
    private var games: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localized("library.games")).eyebrow().padding(.top, 6)

            if library.entries.isEmpty {
                Text(localized("library.empty"))
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }

            GameList(entries: library.entries) { open($0) }
        }
    }

    private func note(_ text: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.footnote)
            Text(text).font(.footnote)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.alarm)
        .padding(12)
        .background(Palette.alarm.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private var recognising: some View {
        ZStack {
            Palette.ink.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(Palette.analysis)
                Text(localized("library.recognising")).eyebrow()
            }
            .padding(28)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // ------------------------------------------------------------------ doing

    /// Reads the newest shared picture, if there is one and nothing else is being read.
    ///
    /// Newest and only one: somebody who shares three boards in a row is going to look at the
    /// last of them, and the other two are still wherever they came from. The rest are dropped
    /// rather than queued, because a queue here would mean the app opening a board nobody
    /// asked about on some later launch.
    private func takeWhatWasShared() {
        guard !isRecognising, path.isEmpty, let inbox = SharedInbox.shared else { return }
        guard let data = inbox.takeNewest() else { return }
        inbox.empty()
        recognise(.data(data))
    }

    private func paste() {
        guard let image = BoardImageLoader.fromClipboard() else {
            failure = (localized("library.noClipboard.title"), localized("library.noClipboard.message"))
            return
        }
        recognise(.image(image))
    }

    /// Reads the picture and goes straight to the game (docs/adr/0011). The squares recognition
    /// was unsure of stay ringed on the board there, and 改棋子 is one tap away — so the common
    /// case costs no taps at all and the rare one costs one.
    private func recognise(_ source: BoardIntake.Source, keepingPhotograph: Bool = false) {
        isRecognising = true
        Task {
            let intake: BoardIntake.Intake
            if keepingPhotograph {
                intake = await BoardIntake.read(source, keepingPhotograph: { image in
                    library.keepPhotograph(image)
                })
            } else {
                intake = await BoardIntake.read(source)
            }
            isRecognising = false

            switch intake {
            case .played(let game, let shaky, let orientation, let picture):
                let session = GameSession.recognised(
                    game,
                    orientation: orientation,
                    picture: picture,
                    shaky: shaky,
                    engine: engine.service,
                    library: library
                )
                path.append(.game(session))
            case .needsEditing(let draft, let shaky, let orientation, let picture):
                path.append(
                    .confirm(
                        PositionProposal(
                            draft: draft,
                            shaky: shaky,
                            orientation: orientation,
                            picture: picture
                        )
                    )
                )
            case .noBoard, .unreadable:
                failure = intake.alert
            }
        }
    }

    private func start(_ game: Game?) {
        guard let game else { return }
        let session = GameSession.playing(game, engine: engine.service, library: library)
        path.append(.game(session))
    }

    private func open(_ entry: GameLibrary.Entry) {
        guard let session = GameSession.opened(entry, engine: engine.service, library: library) else {
            return
        }
        path.append(.game(session))
    }
}

/// A list of games, and everything that can be done to one: open it, name it, delete it.
struct GameList: View {
    let entries: [GameLibrary.Entry]
    let open: (GameLibrary.Entry) -> Void

    @Environment(GameLibrary.self) private var library

    @State private var renaming: GameLibrary.Entry?
    @State private var nameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(entries) { entry in
                row(entry)
            }
        }
        .alert(localized("game.name.title"), isPresented: .constant(renaming != nil)) {
            TextField(localized("game.name.field"), text: $nameDraft)
            Button(localized("ok")) {
                if let entry = renaming { library.rename(entry, to: trimmed(nameDraft)) }
                renaming = nil
            }
            Button(localized("cancel"), role: .cancel) { renaming = nil }
        } message: {
            Text(localized("game.name.explained"))
        }
    }

    private func row(_ entry: GameLibrary.Entry) -> some View {
        Button {
            open(entry)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.origin.symbol)
                    .font(.footnote)
                    .foregroundStyle(entry.origin == .recognised ? Palette.parchment : Palette.ink)
                    .frame(width: 30, height: 30)
                    .background(
                        entry.origin == .recognised ? Palette.analysis : Palette.chipRest,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.ink)
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(Palette.inkSoft)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Palette.inkSoft)
            }
            .padding(12)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                nameDraft = entry.name ?? ""
                renaming = entry
            } label: {
                Label(localized("rename"), systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                library.delete(entry)
            } label: {
                Label(localized("delete"), systemImage: "trash")
            }
        }
    }
}
