import ChessmirrorKit
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
    /// A position being practised — a 错题 or a 藏局 — and the queue it came from, which decides
    /// both what 下一道 is and whether the go moves a schedule (docs/adr/0032, docs/adr/0051).
    /// Separate from looking at a 错题, because a drill is a question and the history is the
    /// answer to a different one (docs/adr/0029).
    case drill(PositionKey, DrillQueue)
    /// One 收藏集 opened (docs/adr/0051).
    case collection(CollectionKind)
    /// Every game, where the first screen shows only the newest few.
    case allGames
}

/// Where a drill was handed out from. Only the 日课 moves anything's schedule; a pick off the
/// book or off a 收藏集 is 计划外 (docs/adr/0032).
enum DrillQueue: Hashable {
    case daily
    case book
    case collection(CollectionKind)

    var source: Drill.Source { self == .daily ? .daily : .picked }
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
    @Environment(CollectionShelf.self) private var shelf
    private let settings = PlayerSettings.shared

    @State private var path: [Step] = []
    @State private var isCameraOpen = false
    @State private var isPhotoPickerOpen = false
    @State private var isFileImporterOpen = false
    @State private var isAboutShowing = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isRecognising = false
    @State private var failure: (title: String, message: String)?
    @State private var isImporting = false
    /// The door the import sheet opens on, when something here knows better than the one used
    /// last: a failed 自动拉局 opens the door of the site it failed at.
    @State private var importDoor: ImportDoors.Door?
    /// 自动拉局: the 本人账号's new games, once a day and on the ↻ (docs/adr/0045).
    @State private var autoFetch: AutoFetch
    /// One import, kept across openings of the sheet: what was fetched is still there when the
    /// sheet is opened again, so a list pulled once is not pulled again to look at it twice.
    @State private var importSession = ImportSession()
    @State private var recording: MistakeIndex.Recording?
    @Environment(\.scenePhase) private var scenePhase

    /// How many games the first screen shows. The rest are one row away (`Step.allGames`).
    static let newest = 5

    init(autoFetch: AutoFetch = AutoFetch(memory: PlayerSettings.shared.imports)) {
        _autoFetch = State(initialValue: autoFetch)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 14) {
                    masthead
                    if let reason = engine.unavailableReason {
                        note(reason, symbol: "exclamationmark.triangle.fill")
                    }
                    doors
                    intake
                    bookDoor.clipShape(RoundedRectangle(cornerRadius: 14))
                    CollectionRows(path: $path)
                    ladderBoard
                    games
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .readableColumn()
            }
            .background(Palette.parchment)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Palette.analysis)
            // No bar. The name is the title of this screen and it is set in the page, with the
            // way to 关于 beside it — a bar holding one button over an empty title was a row of
            // the first screen spent on nothing. The screens pushed from here keep their own bars;
            // the game hides its for the same reason and draws its own strip.
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $isAboutShowing) { AboutScreen() }
            .sheet(isPresented: $isImporting) {
                ImportSheet(
                    session: importSession, engine: engine.service, initialDoor: importDoor,
                    onOpen: open
                )
            }
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
                case .drill(let position, let queue):
                    DrillHost(
                        position: position,
                        index: index,
                        engine: engine.service,
                        queue: queue,
                        path: $path
                    )
                    // 下一题 swaps the top of the path for the next question, and a destination
                    // view keeps its `@State` when only the value under it changes: the new
                    // question arrived and the old `Drill` went on being the one on the screen,
                    // so the button did nothing. The position is the question, so it is the
                    // identity.
                    .id(position)
                case .collection(let kind):
                    CollectionScreen(kind: kind, path: $path)
                case .allGames:
                    AllGamesScreen(path: $path)
                }
            }
            .overlay {
                if isRecognising { recognising }
            }
        }
        .overlay(alignment: .bottom) {
            if let recording {
                Label(localized("book.recorded", recording.count), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.analysis)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .onChange(of: index.recording) { _, receipt in recording = receipt }
        .task(id: recording?.id) {
            guard recording != nil else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            recording = nil
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
        // The 错题本 is derived, so it follows the games: the index brings itself up to date
        // whenever they change, and costs nothing when they have not, because it walks only what
        // is new (docs/adr/0028). Asked for here because this is where the app starts, not
        // because the book is this screen's — freshness is the index's own (`MistakeIndex.follow`).
        .task { index.follow(library, settings: settings) }
        // The 自建集 live in a folder inside the library's, which moves when the library moves
        // into iCloud; and another device may have changed one while this one was away.
        .task(id: library.directory) { shelf.reload() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { shelf.reload() } }
        // Today's 自动拉局, the first time the app comes forward on a day. It waits for the
        // engine to have settled one way or the other, so what comes down is judged at once
        // rather than left for a press nobody knows to make.
        .task(id: scenePhase == .active && (engine.isReady || engine.unavailableReason != nil)) {
            guard scenePhase == .active, engine.isReady || engine.unavailableReason != nil else { return }
            await autoFetch.pullIfDue(into: library, reviewingWith: engine.service)
        }
    }

    // ------------------------------------------------------------------ parts

    /// The name, set rather than accepted. 镜 does two jobs here — a lens, and a mirror: the app
    /// puts the board in front of you onto the phone, unchanged.
    private var masthead: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
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
                Spacer(minLength: 0)
                if case .starting = engine.status {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(localized("library.engineStarting")).eyebrow()
                    }
                }
                Button {
                    isAboutShowing = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundStyle(Palette.inkSoft)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localized("about"))
                // The tap target hangs off the right edge, so the glyph sits on the margin the
                // rows below it end at.
                .padding(.trailing, -12)
            }
            Text(localized("library.tagline"))
                .font(.footnote)
                .foregroundStyle(Palette.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }

    /// What the app is for, at the top and in the heaviest type it has: practise the moves you
    /// got wrong, and play a game that will not let one stand (CONTEXT.md).
    ///
    /// These used to be the fourth and fifth rows, under three ways of handing the app a picture.
    /// A picture is how a position gets *in*; it is not what anybody opened the app to do. The
    /// ways in are still one tap away, in `intake`, wearing the weight that belongs to them.
    private var doors: some View {
        VStack(spacing: 10) {
            Button {
                start(Game(startFEN: PGN.standardStartFEN), noSlips: true)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "leaf.fill").font(.title3)
                    Text(localized("noSlips.start")).font(.headline)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.parchment)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The dark fill belongs to the row, not to this label, so the label has to claim
                // the row as a tap target or only the glyph would answer.
                .contentShape(Rectangle())
                .background(Palette.ink, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(!engine.isReady)

            dailyDoor.clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    /// 进料: the ways a position gets into the app. Photographing a board is the first of them —
    /// the other three ways to hand it a picture are behind the chevron — and all four are
    /// quieter than the two things the app is for.
    private var intake: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                Button {
                    isCameraOpen = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "camera.fill").font(.subheadline.weight(.medium))
                        Text(localized("library.photograph")).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.leading, 18)
                    .padding(.vertical, 16)
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
                        .foregroundStyle(Palette.inkSoft)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 18)
                        .contentShape(Rectangle())
                }
                .overlay(alignment: .leading) {
                    Rectangle().fill(Palette.ink.opacity(0.15)).frame(width: 0.5)
                }
            }
            .background(Palette.chipRest, in: RoundedRectangle(cornerRadius: 14))

            // The two quietest doors share a row. Three full-width rows of the same shape read as
            // a menu, and these two are not even peers of the camera: one is the board with
            // nothing on it yet, the other is somebody else's game. Side by side they say so —
            // and stack again in a language whose words do not fit half a phone.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    lesserDoor(localized("library.fromStart"), symbol: "plus") {
                        start(Game(startFEN: PGN.standardStartFEN))
                    }
                    lesserDoor(localized("import.title"), symbol: "link") {
                        isImporting = true
                    }
                }
                VStack(spacing: 10) {
                    lesserDoor(localized("library.fromStart"), symbol: "plus") {
                        start(Game(startFEN: PGN.standardStartFEN))
                    }
                    lesserDoor(localized("import.title"), symbol: "link") {
                        isImporting = true
                    }
                }
            }
        }
    }

    private func lesserDoor(_ title: String, symbol: String, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.footnote.weight(.medium))
                Text(title).font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(Palette.chipRest, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    /// 日课, and how much of it is left (docs/adr/0030).
    ///
    /// It opens the next question rather than a list of them, and that is the design rather than
    /// a shortcut: a screen listing today's queue is a screen somebody picks from, and picking is
    /// exactly what a spaced schedule exists to take off them (docs/adr/0032). There is one verb
    /// here and it is 下一道.
    ///
    /// **It stays on the screen with nothing due.** A door that disappears once it is done is a
    /// door nobody learns is there, and「今天的练完了」is the whole of what a day's work buys.
    @ViewBuilder private var dailyDoor: some View {
        // One reading of the day (`PracticeDay.Door`) decides what the door is: its label, and
        // whether there is anything behind it. The colour, the chevron and the disabled state
        // were three separate `left > 0` checks in this view, any of which could have drifted
        // from the others and from the label beside them.
        let door = index.practiceDay.door
        Button {
            guard let next = index.daily.next else { return }
            path.append(.drill(next.position, .daily))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sun.max.fill").font(.title3)
                Text(localized("daily")).font(.headline)
                Spacer(minLength: 0)
                Text(door.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(door.isOpen ? Palette.parchment : Palette.inkSoft)
                if door.isOpen {
                    Image(systemName: "chevron.right").font(.caption2)
                }
            }
            .foregroundStyle(door.isOpen ? Palette.parchment : Palette.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(door.isOpen ? Palette.analysis : Palette.chipRest)
        }
        .buttonStyle(.plain)
        .disabled(!door.isOpen)
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
            .background(Palette.chipRest)
        }
        .buttonStyle(.plain)
    }

    /// The 连正榜 (docs/adr/0038): one row per rung the player has stood a move at, the longest
    /// 连正 on each row opening the game it was made in. Nothing at all until something has stood,
    /// because an empty ladder is not a thing to look at.
    @ViewBuilder private var ladderBoard: some View {
        let ladder = index.ladder
        if !ladder.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(localized("ladder")).eyebrow().padding(.top, 6)
                VStack(spacing: 0) {
                    ForEach(ladder.rows) { row in
                        rung(row)
                        if row.id != ladder.rows.last?.id {
                            Divider().padding(.leading, 18)
                        }
                    }
                }
                .background(Palette.chipRest, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func rung(_ row: Ladder.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(row.strength.label)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
            best(localized("ladder.run"), row.longestRun)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.strength.label)
    }

    /// A best on the ladder, and the way to the game it was made in.
    private func best(_ title: String, _ best: Ladder.Best) -> some View {
        Button {
            if let session = opener.open(best.game).session { path.append(.game(session)) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.caption).foregroundStyle(Palette.inkSoft)
                Text("\(best.value)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.ink)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(best.value)")
    }

    /// The newest games, as one flat list, with the ↻ that pulls the 本人账号's new ones.
    ///
    /// Flat, and that is the change: a game used to be a work that got curated into a collection,
    /// and it is raw material now — nobody curates the source of their own mistakes (docs/adr/0028).
    /// What a person looks for here is the game they just played, so the order is the order they
    /// arrived in, and only the newest few are here: the first screen is the last few games and a
    /// way to the rest, not the archive.
    ///
    /// **Not the drills.** Every 错题 answered leaves a file (docs/adr/0047), and they are games
    /// all the same — but not ones the player sat down to play. A drill answered wrong is found
    /// from its 错题's 遭遇, where it belongs; one answered right is in the 练习日志.
    private var games: some View {
        let played = library.entries.filter { $0.origin != .practised }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(localized("library.games")).eyebrow()
                Spacer(minLength: 0)
                refresh
            }
            .padding(.top, 6)

            if let reading = autoFetch.reading {
                Button {
                    // A failure opens the door it failed at; with no account yet, the sheet is
                    // where one is given.
                    if case .failed(let site, _) = autoFetch.phase {
                        importDoor = ImportDoors.Door(rawValue: site.rawValue)
                        isImporting = true
                    } else if autoFetch.accounts.isEmpty {
                        importDoor = nil
                        isImporting = true
                    }
                } label: {
                    Text(reading.text)
                        .font(.caption)
                        .foregroundStyle(reading.isAlarm ? Palette.alarm : Palette.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            }

            if played.isEmpty {
                Text(localized("library.empty"))
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }

            GameList(entries: Array(played.prefix(Self.newest)), wrongByGame: index.wrongByGame) {
                open($0)
            }

            if played.count > Self.newest {
                Button {
                    path.append(.allGames)
                } label: {
                    HStack(spacing: 10) {
                        Text(localized("library.allGames", plural: played.count))
                            .font(.subheadline.weight(.medium))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(Palette.inkSoft)
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(Palette.chipRest, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// ↻: 自动拉局 now, whatever the day. With no 本人账号 yet, the import sheet, where one is
    /// given by fetching it once.
    private var refresh: some View {
        Button {
            guard !autoFetch.accounts.isEmpty else {
                importDoor = nil
                isImporting = true
                return
            }
            Task { await autoFetch.pull(into: library, reviewingWith: engine.service) }
        } label: {
            Group {
                if autoFetch.phase == .pulling {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.inkSoft)
                }
            }
            .frame(width: 44, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(autoFetch.phase == .pulling)
        .accessibilityLabel(localized("autoFetch.refresh"))
        // The tap target hangs off the right edge, so the glyph sits on the margin the rows end at.
        .padding(.trailing, -12)
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
                let session = opener.recognised(
                    game, orientation: orientation, picture: picture, shaky: shaky
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

    private func start(_ game: Game?, noSlips: Bool = false) {
        guard let game else { return }
        path.append(.game(opener.play(game, noSlips: noSlips)))
    }

    private func open(_ entry: GameLibrary.Entry) {
        guard let session = opener.open(entry).session else { return }
        path.append(.game(session))
    }

    /// Every game this screen opens is opened with the engine, the library and what the player
    /// has set right now (`GameOpener`).
    private var opener: GameOpener {
        GameOpener(engine: engine.service, library: library, settings: settings)
    }
}

/// A list of games, and everything that can be done to one: open it, name it, delete it.
///
/// Reads one face of the 错题本 — `wrongByGame` — and not the whole index: a row is labelled
/// from a count and a review state, which is the same seam `PGNImport.Status` takes.
struct GameList: View {
    let entries: [GameLibrary.Entry]
    let wrongByGame: [URL: Int]
    let open: (GameLibrary.Entry) -> Void

    @Environment(GameLibrary.self) private var library

    @State private var renaming: GameLibrary.Entry?
    @State private var nameDraft = ""

    var body: some View {
        // Lazy, because every row now draws a board, and a library of a hundred games is a
        // hundred boards nobody has scrolled to.
        LazyVStack(alignment: .leading, spacing: 8) {
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
                // The position the game stands at, in place of a glyph saying where it came
                // from. A game is a position before it is anything else, and a shelf of boards
                // is what a 棋谱 collection looks like; where it came from is the first word of
                // the line under the name. The glyph stays for a file with no position in it.
                if let pgn = entry.pgn, let fen = entry.shownFEN {
                    BoardView(
                        pieces: PositionDraft(fen: fen)?.pieces ?? [:],
                        // The chair the game opens in, so the shelf and the opened board agree.
                        orientation: pgn.orientation,
                        coordinates: false,
                        isInteractive: false
                    )
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hairline, lineWidth: 0.5))
                    .accessibilityHidden(true)
                } else {
                    Image(systemName: entry.origin.symbol)
                        .font(.footnote)
                        .foregroundStyle(Palette.ink)
                        .frame(width: 48, height: 48)
                        .background(Palette.chipRest, in: RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.ink)
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(Palette.inkSoft)
                    if entry.origin == .imported {
                        Text(
                            PGNImport.Status(
                                scoring: library.reviewing[entry.url],
                                isReviewed: entry.pgn?.game.isReviewed == true,
                                wrong: wrongByGame[entry.url] ?? 0
                            ).label
                        )
                            .font(.caption)
                            .foregroundStyle(Palette.inkSoft)
                    }
                }
                Spacer(minLength: 0)
                if let wrong = wrongByGame[entry.url], wrong > 0 {
                    Text(localized("library.wrong", wrong))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Palette.alarm)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Palette.alarm.opacity(0.12), in: Capsule())
                }
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

/// Every game, newest first, where the first screen shows only the newest few. The drills are not
/// here either: they are found from their 错题 (docs/adr/0047).
struct AllGamesScreen: View {
    @Binding var path: [Step]

    @Environment(GameLibrary.self) private var library
    @Environment(MistakeIndex.self) private var index
    @Environment(EngineHost.self) private var engine

    var body: some View {
        ScrollView {
            GameList(
                entries: library.entries.filter { $0.origin != .practised },
                wrongByGame: index.wrongByGame
            ) { entry in
                let opener = GameOpener(engine: engine.service, library: library, settings: .shared)
                guard let session = opener.open(entry).session else { return }
                path.append(.game(session))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .readableColumn()
        }
        .background(Palette.parchment)
        .navigationTitle(localized("library.games"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.parchment, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar(.visible, for: .navigationBar)
    }
}
