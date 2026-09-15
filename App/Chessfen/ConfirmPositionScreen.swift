import ChessfenKit
import SwiftUI
import UIKit

/// A position on its way to the editor.
struct PositionProposal: Identifiable, Hashable {
    let id = UUID()
    var draft: PositionDraft
    /// The Shaky Squares — where the classifier was not confident.
    var shaky: Set<Square> = []
    var orientation: Orientation = .whiteAtBottom
    /// The picture it was read from, so the player can check it against the board.
    var picture: RGBImage?
    var origin: GameOrigin = .recognised
    var controllers: [PieceColour: Controller] = [.white: .hand, .black: .hand]
    /// The game this came out of, when it came out of one. A correction goes back into that same
    /// game if nothing has been played in it yet.
    var reopening: GameSession?

    init(reopening session: GameSession) {
        draft = PositionDraft(fen: session.game.startFEN) ?? PositionDraft(pieces: [:])
        shaky = session.shaky
        orientation = session.orientation
        picture = session.picture
        origin = session.origin
        controllers = [
            .white: session.controller(for: .white), .black: session.controller(for: .black),
        ]
        reopening = session
    }

    init(
        draft: PositionDraft,
        shaky: Set<Square> = [],
        orientation: Orientation = .whiteAtBottom,
        picture: RGBImage? = nil,
        origin: GameOrigin = .recognised,
        controllers: [PieceColour: Controller] = [.white: .hand, .black: .hand]
    ) {
        self.draft = draft
        self.shaky = shaky
        self.orientation = orientation
        self.picture = picture
        self.origin = origin
        self.controllers = controllers
    }

    // Identity, not contents: the draft is edited here and the navigation stack must not treat
    // an edited proposal as a different destination.
    static func == (left: PositionProposal, right: PositionProposal) -> Bool {
        left.id == right.id
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The piece editor: put the pieces where they actually are.
///
/// This used to be a gate every recognised board had to pass through. It is now the place you go
/// when something is wrong (docs/adr/0011), and it does one thing. Whose move it is, which way up
/// the board is and who plays each side are all on the game screen, permanently — so they are not
/// here. What is left is a board, a box of pieces, and a way back.
struct ConfirmPositionScreen: View {
    let proposal: PositionProposal
    @Binding var path: [Step]

    @Environment(EngineHost.self) private var engine
    @Environment(GameLibrary.self) private var library

    @State private var draft: PositionDraft
    /// The piece taps place. Nil means taps do nothing; the eraser is what this starts on, because
    /// the misreadings that bring anyone here are a piece seen where there is none, and clearing a
    /// square is the one edit that needs no choice made in the box first. Wrong taps are cheap —
    /// an emptied square is visibly empty and re-placing it is one more tap.
    @State private var brush: Brush? = .eraser
    @State private var isPictureShowing = false
    @State private var isAdvancedShowing = false
    /// How much of the photograph is showing. Off to begin with: the board is what is being edited,
    /// and the picture is what you reach for when you doubt it.
    @State private var photo: PhotoMode = .off
    /// True while 按住看照片 is held. Separate from the mode so releasing goes back to whatever was
    /// set rather than to a fourth state nobody chose.
    @State private var isPeeking = false
    /// The photograph as something SwiftUI can draw. A plain read: `RGBImage` owns its
    /// `CGImage` conversion now — a fresh buffer per read is what once took the app to
    /// three and a half gigabytes, and this used to be an `@State` cache that stood in
    /// for the cache the pixels themselves were missing.
    private var photoImage: Image? {
        guard let picture = proposal.picture else { return nil }
        return Image(rgb: picture)
    }

    enum Brush: Hashable {
        case piece(Piece)
        case eraser
    }

    /// The three useful amounts of photograph. A slider was the other option and it is worse: it
    /// looks continuous while only these three values do anything — compare, look, and get out of
    /// the way — and each one is a tap here instead of a drag.
    enum PhotoMode: Hashable {
        /// The board as the editor believes it.
        case off
        /// Under the pieces, muted, and still editable — this is the one you work in.
        case under
        /// The photograph by itself. What is really on that square, with nothing drawn over it.
        case alone
    }

    private static let kinds: [PieceKind] = [.king, .queen, .rook, .bishop, .knight, .pawn]

    init(proposal: PositionProposal, path: Binding<[Step]>) {
        self.proposal = proposal
        _path = path
        _draft = State(initialValue: proposal.draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            instruction
            board
            photoControl
            palette
            Spacer(minLength: 0)
            if isAdvancedShowing { advanced }
            done
        }
        .background(Palette.parchment)
        .navigationTitle(localized("edit.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.parchment, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(Palette.analysis)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Only for a picture that cannot be laid over the board — one stored before the
                    // board was cut out of it. Anything that can be is better seen in place, and
                    // two ways to look at the same photograph is one too many.
                    if proposal.picture != nil, !hasBoardPhoto {
                        Button {
                            isPictureShowing = true
                        } label: {
                            Label(localized("edit.seePhoto"), systemImage: "photo")
                        }
                    }
                    Button {
                        isAdvancedShowing.toggle()
                    } label: {
                        Label(
                            localized(
                                isAdvancedShowing ? "edit.advanced.hide" : "edit.advanced.show"
                            ),
                            systemImage: "slider.horizontal.3"
                        )
                    }
                    Button {
                        UIPasteboard.general.string = draft.fen
                    } label: {
                        Label(localized("edit.copyFEN"), systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button {
                        draft.reset()
                    } label: {
                        Label(localized("edit.reset"), systemImage: "arrow.counterclockwise")
                    }
                    Button(role: .destructive) {
                        draft.clear()
                    } label: {
                        Label(localized("edit.clear"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isPictureShowing) {
            if let photoImage {
                NavigationStack {
                    photoImage
                        .resizable()
                        .scaledToFit()
                        .navigationTitle(localized("edit.photo"))
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }

    // ------------------------------------------------------------------ parts

    /// What a tap on a square will do right now. The eraser needs its own line: it is what the
    /// screen opens on, and telling someone they are about to put a piece down when they are about
    /// to take one off is worse than saying nothing.
    private var hint: String {
        if isShowingPhotoAlone { return localized("edit.hint.photo") }
        return switch brush {
        case .none: localized("edit.hint.pick")
        case .eraser: localized("edit.hint.erase")
        case .piece: localized("edit.hint.place")
        }
    }

    private var instruction: some View {
        HStack(spacing: 8) {
            if let summary = proposal.shaky.shakySummary {
                Image(systemName: "questionmark.circle").foregroundStyle(Palette.alarm)
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(Palette.alarm)
            } else {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSoft)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .padding(.horizontal, 16)
    }

    private var board: some View {
        BoardView(
            pieces: draft.pieces,
            // The board's orientation is the game's, and it is set there. Turning it here would
            // be a second place to change one thing.
            orientation: proposal.orientation,
            suspects: proposal.shaky,
            coordinates: true,
            // Nothing to edit against a photograph: while it is the only thing showing, a tap
            // would be aimed at a piece the board is not currently claiming to have.
            isInteractive: !isShowingPhotoAlone,
            onTap: paint,
            backdrop: backdrop
        )
        .padding(.horizontal, 16)
    }

    /// Whether the stored picture can be laid over the board.
    ///
    /// It can when it is square: a picture cut to the board is square by construction, and one that
    /// is not was stored before the board was cut out of it, so it would sit under the pieces
    /// misaligned — worse than not offering the comparison at all. Those open in the sheet instead,
    /// which asks nothing of the coordinates. Answered from the dimensions rather than from the
    /// converted image, so the control row is there on the first frame and does not pop in.
    private var hasBoardPhoto: Bool {
        guard let picture = proposal.picture else { return false }
        return picture.width == picture.height && picture.width > 0
    }

    private var isShowingPhotoAlone: Bool { isPeeking || photo == .alone }

    private var backdrop: BoardView.Backdrop? {
        guard hasBoardPhoto, let boardPhoto = photoImage, photo != .off || isPeeking else {
            return nil
        }
        if isShowingPhotoAlone {
            return .init(image: boardPhoto, opacity: 1, saturation: 1, showsPieces: false)
        }
        // Under the pieces: enough of the photograph to compare against, muted enough that the
        // drawn pieces stay the darkest and lightest things in any square.
        return .init(image: boardPhoto, opacity: 0.5, saturation: 0.45, showsPieces: true)
    }

    /// How much of the photograph is showing. Directly under the board, because that is the thing
    /// it changes and the comparison happens up there.
    @ViewBuilder private var photoControl: some View {
        if hasBoardPhoto {
            HStack(spacing: 10) {
                ChipCluster(
                    title: localized("edit.photo"),
                    options: [
                        .init(value: PhotoMode.off, label: localized("edit.photo.off")),
                        .init(value: PhotoMode.under, label: localized("edit.photo.under")),
                        .init(value: PhotoMode.alone, label: localized("edit.photo.alone")),
                    ],
                    selection: photo
                ) { mode in
                    withAnimation(.easeOut(duration: 0.15)) { photo = mode }
                }
                Spacer(minLength: 2)
                peek
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    /// Hold it to see the photograph, let go to come back. Two taps of the chips do the same thing,
    /// but settling one doubtful square is a glance, and a glance should not cost a mode change.
    ///
    /// A held button rather than a long press on the board itself: taps on the board edit it, this
    /// screen opens with the eraser in hand, and a hold that ended in a stray tap would rub out the
    /// piece you were checking.
    private var peek: some View {
        HStack(spacing: 5) {
            Image(systemName: isPeeking ? "eye.fill" : "eye").font(.footnote)
            Text(localized("edit.peek")).font(.footnote.weight(.medium))
        }
        .foregroundStyle(isPeeking ? Palette.parchment : Palette.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            isPeeking ? Palette.analysis : Palette.chipRest,
            in: RoundedRectangle(cornerRadius: 9)
        )
        .contentShape(Rectangle())
        // A drag of no distance is the reliable way to be told about the release as well as the
        // press; a long-press gesture reports the press and keeps the rest to itself.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPeeking = true }
                .onEnded { _ in isPeeking = false }
        )
    }

    /// The box of pieces: white above, black below, all twelve visible at once. A scroller put
    /// the piece you wanted off the side of the screen about half the time.
    private var palette: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(spacing: 6) {
                ForEach([PieceColour.white, .black], id: \.self) { colour in
                    HStack(spacing: 6) {
                        ForEach(Self.kinds, id: \.self) { kind in
                            let piece = Piece(colour: colour, kind: kind)
                            Button {
                                brush = brush == .piece(piece) ? nil : .piece(piece)
                            } label: {
                                PieceGlyphView(piece: piece)
                                    .padding(4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8).fill(
                                            brush == .piece(piece)
                                                ? Palette.analysis.opacity(0.22)
                                                : Palette.chipRest
                                        )
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8).stroke(
                                            brush == .piece(piece)
                                                ? Palette.analysis : .clear,
                                            lineWidth: 1.5
                                        )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Button {
                brush = brush == .eraser ? nil : .eraser
            } label: {
                Image(systemName: "eraser")
                    .font(.title3)
                    .foregroundStyle(brush == .eraser ? Palette.analysis : Palette.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(
                            brush == .eraser ? Palette.analysis.opacity(0.22) : Palette.chipRest
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).stroke(
                            brush == .eraser ? Palette.analysis : .clear, lineWidth: 1.5
                        )
                    )
            }
            .buttonStyle(.plain)
            .frame(width: 44)
        }
        .frame(height: 108)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// The two fields no picture can show and no glance can check. Off by default: they are
    /// inferred from where the pieces stand, and that inference is right except in positions a
    /// player would know to come looking for these.
    private var advanced: some View {
        VStack(spacing: 10) {
            if !draft.possibleCastling.isEmpty {
                HStack(spacing: 8) {
                    Text(localized("edit.castling")).eyebrow()
                    Spacer(minLength: 0)
                    ForEach(castlingRights, id: \.right) { entry in
                        Button {
                            if draft.castling.contains(entry.right) {
                                draft.castling.remove(entry.right)
                            } else {
                                draft.castling.insert(entry.right)
                            }
                        } label: {
                            Chip(label: entry.label, isOn: draft.castling.contains(entry.right))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !draft.possibleEnPassantSquares.isEmpty {
                HStack {
                    Text(localized("edit.enPassant")).eyebrow()
                    Spacer()
                    Menu {
                        Button(localized("edit.none")) { draft.enPassant = nil }
                        ForEach(draft.possibleEnPassantSquares, id: \.self) { square in
                            Button(square.description) { draft.enPassant = square }
                        }
                    } label: {
                        Chip(
                            label: draft.enPassant?.description ?? localized("edit.none"),
                            isOn: draft.enPassant != nil
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var done: some View {
        VStack(spacing: 8) {
            if let issue = draft.verdict.issue {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption)
                    Text(issue.label).font(.footnote)
                }
                .foregroundStyle(Palette.alarm)
            }
            Button {
                finish()
            } label: {
                Text(localized(isCorrection ? "edit.useThis" : "edit.startGame"))
                    .font(.headline)
                    .foregroundStyle(Palette.parchment)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        draft.isPlayable ? Palette.ink : Palette.inkSoft,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!draft.isPlayable)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // ------------------------------------------------------------------ doing

    /// Whether this goes back into the game it came from. It does when nothing has been played
    /// there yet, which is when the answer to "the camera got a piece wrong" should be that the
    /// piece is now right — not a second game in the list.
    private var isCorrection: Bool {
        proposal.reopening?.game.plies.isEmpty ?? false
    }

    private func paint(_ square: Square) {
        switch brush {
        case .none: return
        case .eraser: draft.setPiece(nil, at: square)
        case .piece(let piece):
            // Tapping the same piece onto the square it already occupies takes it off, which is
            // what a finger expects and saves a trip to the eraser.
            draft.setPiece(draft.piece(at: square) == piece ? nil : piece, at: square)
        }
    }

    private func finish() {
        guard let game = draft.game else { return }

        if let session = proposal.reopening, session.replaceStart(with: game) {
            path.removeLast()
            return
        }

        let session = GameSession.corrected(
            game,
            controllers: proposal.controllers,
            orientation: proposal.orientation,
            origin: proposal.origin,
            picture: proposal.picture,
            shaky: proposal.shaky,
            engine: engine.service,
            library: library
        )
        // Replaces the stack rather than adding to it: going back from a game in progress belongs
        // in the library, not in the editor of a position already being played.
        path = [.game(session)]
    }

    private var castlingRights: [(right: Character, label: String)] {
        [
            ("K", localized("edit.castling.K")), ("Q", localized("edit.castling.Q")),
            ("k", localized("edit.castling.k")), ("q", localized("edit.castling.q")),
        ]
            .filter { draft.possibleCastling.contains($0.0) }
            .map { (right: $0.0, label: $0.1) }
    }
}
