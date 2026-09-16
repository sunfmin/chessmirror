import Foundation

/// Where a game came from, which decides what can be done to it later.
public enum GameOrigin: String, Hashable, Sendable, Codable {
    /// Set up by hand, from the standard position or an edited one.
    case fresh
    /// Read off a picture. Such a game can always be taken back to the Confirm Position
    /// gate, because the thing most likely to be wrong about it is a piece.
    case recognised
    /// Downloaded from a PGN link, whole chapters at a time (docs/adr/0014). The game
    /// text is the study's own, so there is nothing to take back to an editor for.
    case imported

    /// Written into the PGN so the distinction survives a relaunch. Not a standard tag;
    /// PGN has no opinion about where a position came from, and readers ignore what they do
    /// not know.
    public static let tagName = "Source"

    public var tagValue: String { rawValue }
    public var label: String {
        switch self {
        case .fresh: localized("origin.fresh")
        case .recognised: localized("origin.recognised")
        case .imported: localized("origin.imported")
        }
    }
    public var symbol: String {
        switch self {
        case .fresh: "square.grid.3x3"
        case .recognised: "camera"
        case .imported: "link"
        }
    }
}

/// One game being played, and everything the screen showing it needs.
///
/// The Game is the truth; this adds who is moving for each colour, which way up the board is,
/// where the player is looking, and the Analysis as it currently stands. It also owns the
/// engine loop, because "what should the engine be doing right now" has exactly one answer
/// and it follows from the Game, the cursor and the two Controllers.
@Observable @MainActor public final class GameSession: Identifiable, Hashable {
    public nonisolated let id = UUID()
    /// A practice attempt is the first move of this game, not a separate, frozen board.
    public private(set) var practice: Drill?

    public private(set) var game: Game {
        didSet {
            storedViewed = nil
            // The 错题 list is walked out of the Game, and a refusal is written into it without
            // touching a single move — so a cache keyed on the moves alone would go on saying the
            // game had nothing wrong in it while the row under the board showed otherwise.
            storedSlips = nil
        }
    }
    public var orientation: Orientation
    /// Which ply the player is looking at: 0 is the starting position, `plies.count` the
    /// latest. Browsing back does not change the Game — but playing from there does, and what
    /// used to follow becomes a Variation.
    public private(set) var cursor: Int {
        didSet {
            storedViewed = nil
            // A shot found here was found for *this* position, so it goes with the cursor. One
            // home for that, rather than three places that each remember.
            tactic = nil
            isProbingTactics = false
            probedAnalysis = nil
        }
    }
    /// The Game rebuilt where the cursor stands, kept until either the Game or the cursor
    /// moves — the whole point of `viewed` being a stored value instead of a derivation
    /// (see `viewed` itself).
    @ObservationIgnored private var storedViewed: Game?
    /// The 错招 walked out of the Game once, with the key they were walked under. Reading them is
    /// a rules probe per Ply, and the record strip asks on every draw.
    @ObservationIgnored private var storedSlips: (key: String, slips: [Slip])?
    /// The uniform-depth pass over the whole Game, while there is one running or just finished.
    public private(set) var reviewPass: ReviewPass?

    private var reviewTask: Task<Void, Never>?
    /// The Analysis of the position being looked at, replaced each time the engine reports a
    /// deeper one, and cleared the moment anything makes it stale.
    public private(set) var analysis: Analysis?
    /// The move the engine is walking, when it is walking one — and *whose* it is, which is the
    /// part a Bool could not say.
    ///
    /// Both kinds are the engine thinking about a move it will play rather than advice, and they
    /// are not the same act, because they end in opposite ways. `own` is a move it took on under
    /// its own Controller, on a clock, and 马上走 is how you stop waiting for it. `asked` is a move
    /// a thumb is holding the button down for, and it ends when the thumb comes up.
    ///
    /// One flag for both is what this was, and the screen chose between the two buttons by reading
    /// it — so the first instant of a press swapped 让引擎走 for 马上走 under the finger. A button
    /// taken off the screen mid-press is never let go of: the hold ran on with nobody holding it,
    /// and the move it was asked for was never played.
    public enum Thinking: Sendable {
        /// A move the engine took on itself, on a clock.
        case own
        /// A move somebody is holding the button down for.
        case asked
    }

    public private(set) var thinking: Thinking?

    /// Whether a move of either kind is being walked.
    public var isThinking: Bool { thinking != nil }

    // --------------------------------------------------------- shared position search

    /// The shared search has finished; its answer remains available without more work.
    public private(set) var isAdviceSpent = false

    /// How the running search is getting on — how long it has been at it and how deep it has got.
    ///
    /// Apart from the Analysis on purpose, because it is not advice: a Depth and a stopwatch are a
    /// report of what the phone is doing, so practice, which refuses to show what the engine
    /// *thinks*, has no reason to hide them. It is what a thumb held on 让引擎走 is told.
    public private(set) var searchProgress: SearchProgress?

    /// A search is in flight — a Stint, a probe, a move being walked. The cards read this to
    /// say 在算 rather than 「引擎还没算过」 while one of those is running.
    public var isSearching: Bool { searchTask != nil }

    public struct SearchProgress: Hashable, Sendable {
        public var depth: Int
        public var selectiveDepth: Int
        public var milliseconds: UInt64

        public var seconds: Double { Double(milliseconds) / 1000 }

        public init(depth: Int, selectiveDepth: Int, milliseconds: UInt64) {
            self.depth = depth
            self.selectiveDepth = selectiveDepth
            self.milliseconds = milliseconds
        }
    }
    public private(set) var url: URL?
    public let origin: GameOrigin
    /// The picture the position was read from, and the squares recognition was unsure of —
    /// kept so the gate can be returned to.
    public var picture: RGBImage?
    public var shaky: Set<Square>

    /// Legacy answer-visibility preference. Position feedback is independent of this flag;
    /// the game screen no longer presents it as a separate practice/analysis mode.
    public private(set) var isPractising = true
    private var adviceBeforeTilling: Bool?
    public private(set) var preferredIntercept: Double?
    private var showsPositionFeedback = false
    /// Keep assessment/history visible when interception is temporarily switched off.
    public var hasTillingFeedback: Bool { showsPositionFeedback || preferredIntercept != nil }
    public func showPositionFeedback() { showsPositionFeedback = true }

    /// Whether a Tactic may be named on the latest position (docs/adr/0023).
    ///
    /// Off at the start of every Game, never written to PGN, silent on a past Ply. Practice
    /// can stay on: then the board has no Score and no candidate Lines, only the shot.
    public private(set) var isFindingTactics = false
    /// The shot the finder currently names, if the last probe found one.
    public private(set) var tactic: Tactic?
    /// True while the short search that confirms a Tactic is running.
    public private(set) var isProbingTactics = false
    /// The probe's own Analysis, kept only so a mate it happened to see can be reported.
    ///
    /// The finder's search is not advice — it is bounded, it was asked a question about shots, and
    /// practice is allowed to keep it (docs/adr/0023). A mate in it is news, and news is not the
    /// engine's opinion either, so it may be read out where a Score may not (docs/adr/0025). What
    /// is *not* kept is a Score, a Depth or a candidate list: nothing else in here reaches a screen.
    private var probedAnalysis: Analysis?
    /// Analyses already paid for, keyed by the FEN they were found from. A swipe onto another
    /// card of the same position is not a new question, and walking back to a Ply that has
    /// already been asked about is not one either.
    @ObservationIgnored private var analysisByFen: [String: Analysis] = [:]

    private var controllers: [PieceColour: Controller]
    /// The clock somebody has put the engine on, if anybody has. Nil means the game decides —
    /// see `thinkingTime`, which is the one to read.
    ///
    /// Not stored, like the Controllers it goes with: PGN has nowhere to put it, and it is a way
    /// of playing rather than something about the game.
    private var chosenThinkingTime: ThinkingTime?
    private var tags: [PGN.Tag]
    private var searchTask: Task<Void, Never>?

    /// When the current player's turn began, and how long they took over the last one.
    /// Mirrored Time is the whole reason both are kept.
    private var turnBegan: ContinuousClock.Instant?
    private var lastHumanThink: Duration?
    /// The best move known to the search the engine was asked for — the arrow it started from, then
    /// whatever it has found since. What letting go of the button plays.
    private var askedBest: String?
    /// The best move of the search the engine is running on its own turn, kept as the
    /// snapshots land so `moveNow` can play it the instant it is asked for, without
    /// waiting for the stream to end.
    private var thinkingBest: String?
    /// Whether the button has already been let go of while its search was still starting up.
    private var isAskReleased = false

    private var engine: (any Engine)?
    private weak var library: GameLibrary?

    /// The one low-level construction, private because a session is made through one of the named
    /// ways in below — which is where the invariants live: what a session is attached to, and
    /// whether a saved game may be opened at all.
    private init(
        game: Game,
        // Both by hand unless asked otherwise. A board that starts moving on its own is a
        // surprise, and the engine is one switch away for anyone who wants an opponent.
        controllers: [PieceColour: Controller] = [.white: .hand, .black: .hand],
        orientation: Orientation = .whiteAtBottom,
        origin: GameOrigin = .fresh,
        picture: RGBImage? = nil,
        shaky: Set<Square> = [],
        url: URL? = nil,
        tags: [PGN.Tag] = [],
        /// Which ply to open on. The latest by default, which is where a game being played is.
        viewing: Int? = nil
    ) {
        self.game = game
        self.controllers = controllers
        self.orientation = orientation
        self.origin = origin
        self.picture = picture
        self.shaky = shaky
        self.url = url
        self.tags = tags
        self.cursor = min(max(0, viewing ?? game.plies.count), game.plies.count)
        if let value = tags.first(where: { $0.name == "Intercept" }).flatMap({ Double($0.value) }),
            value.isFinite, JudgementLines.interceptRange.contains(value) {
            lines.intercept = value
        }
        preferredIntercept = lines.intercept
        if preferredIntercept == nil,
           let value = tags.first(where: { $0.name == "InterceptPreference" }).flatMap({ Double($0.value) }),
           value.isFinite, JudgementLines.interceptRange.contains(value) {
            preferredIntercept = value
        }
    }

    // ------------------------------------------------------------------ ways in
    //
    // One call per way a session comes to be. Each owns what the callers used to hand-roll:
    // attaching the engine and the library it saves back to, and — for a saved game — the
    // refusal while its file is still on the way from iCloud.

    /// A board just read off a photograph (docs/adr/0011): the legal readings come here straight
    /// from the camera, and an illegal reading arrives through `corrected` once the editor has
    /// had its say. The picture and the squares recognition was unsure of come along so the
    /// gate can be returned to.
    public static func recognised(
        _ game: Game,
        orientation: Orientation = .whiteAtBottom,
        picture: RGBImage? = nil,
        shaky: Set<Square> = [],
        engine: (any Engine)? = nil,
        library: GameLibrary? = nil
    ) -> GameSession {
        let session = GameSession(
            game: game, orientation: orientation, origin: .recognised, picture: picture, shaky: shaky
        )
        session.attach(engine: engine, library: library)
        return session
    }

    /// A new game, both sides by hand unless asked otherwise.
    public static func fresh(
        _ game: Game,
        controllers: [PieceColour: Controller] = [.white: .hand, .black: .hand],
        engine: (any Engine)? = nil,
        library: GameLibrary? = nil
    ) -> GameSession {
        let session = GameSession(game: game, controllers: controllers, origin: .fresh)
        session.attach(engine: engine, library: library)
        return session
    }

    /// A new game to be played: the side to move in hand, the other on the engine answering
    /// a second at a time. From the opening that is White vs Black-engine; it is the same
    /// seating as a reopened record.
    public static func playing(
        _ game: Game,
        engine: (any Engine)? = nil,
        library: GameLibrary? = nil
    ) -> GameSession {
        let session = fresh(game, engine: engine, library: library)
        session.seatEngineOpponent()
        return session
    }

    public static func practising(
        _ drill: Drill, engine: (any Engine)? = nil, library: GameLibrary? = nil
    ) -> GameSession {
        let session = fresh(drill.game, controllers: [
            drill.mover: .hand, drill.mover.opposite: .engine
        ], engine: engine, library: library)
        session.practice = drill
        session.setThinkingTime(.openedRecord)
        session.orientation = drill.mover == .white ? .whiteAtBottom : .blackAtBottom
        session.showPositionFeedback()
        return session
    }

    public func notePracticeHelp() {
        guard let practice, !practice.isSettled, !practice.isJudging else { return }
        practice.hintsOpened += 1
    }

    private var pendingImportURL: URL?

    private func reviewImportIfReady() {
        let session = self
        if let engine, let library, let pendingImportURL,
            let entry = library.entries.first(where: { $0.url == pendingImportURL }) {
            library.reviewImported(entry, using: engine) { [weak session] reviewed in
                guard let session, session.game.uciMoves == reviewed.game.uciMoves,
                    session.game.startFEN == reviewed.game.startFEN else { return }
                session.game = reviewed.game
                session.tags = reviewed.tags
                session.pendingImportURL = nil
            }
        }
    }

    /// A saved game, opened at the position it began in.
    ///
    /// The beginning rather than the end, because opening a game that is over is reading it: the
    /// moves are there to be walked through, and the last position is the one thing about a
    /// finished game you already know. 下一步 is the first tap either way.
    ///
    /// The Controllers are not stored in PGN — nothing in the format has anywhere to put them — so
    /// a reopened game starts with the side about to move in hand, the other side on the engine
    /// answering a second at a time, and in practice: no arrow, no number, nobody whispering an
    /// answer. Reading faces the play: the person who opens a record plays its first move, and
    /// the engine answers it — as soon as it has finished loading, if the record got opened
    /// first.
    ///
    /// Nil — refused, not failed — while the file is still on the way from iCloud. Opening it
    /// would give an empty board wearing the real game's file name, and the autosave after the
    /// first move would write it over the game that was on its way (docs/adr/0012). Every door
    /// into a saved game goes through this one, so the refusal cannot be forgotten.
    public static func opened(
        _ entry: GameLibrary.Entry,
        engine: (any Engine)? = nil,
        library: GameLibrary? = nil
    ) -> GameSession? {
        guard !entry.isDownloading else { return nil }
        let session = GameSession(entry: entry, library: library)
        session.pendingImportURL = entry.url
        session.attach(engine: engine, library: library)
        session.seatEngineOpponent()
        return session
    }

    /// A position the Piece Editor hands back (docs/adr/0011). Carries the shaky squares it came
    /// in with: the editor fixed a reading, it did not remove the doubt about the rest of the
    /// board, and the gate is still the way back to it.
    public static func corrected(
        _ game: Game,
        controllers: [PieceColour: Controller],
        orientation: Orientation,
        origin: GameOrigin,
        picture: RGBImage?,
        shaky: Set<Square>,
        engine: (any Engine)?,
        library: GameLibrary?
    ) -> GameSession {
        let session = GameSession(
            game: game,
            controllers: controllers,
            orientation: orientation,
            origin: origin,
            picture: picture,
            shaky: shaky
        )
        session.attach(engine: engine, library: library)
        return session
    }

    /// Reopens a saved game, at the position it began in, facing the side about to move.
    private convenience init(entry: GameLibrary.Entry, library: GameLibrary? = nil) {
        let pgn = entry.pgn
        let game = pgn?.game ?? Game(startFEN: PGN.standardStartFEN)!
        self.init(
            game: game,
            // The other side is handed to the engine by `opened`. Practice is not set here or
            // there: it is where every Game starts.
            controllers: [.white: .hand, .black: .hand],
            // A record opens facing the side about to move: reading begins where the play does.
            orientation: .facing(game.startingSideToMove),
            origin: entry.origin,
            picture: entry.origin == .recognised ? library?.picture(for: entry.url) : nil,
            url: entry.url,
            tags: pgn?.tags ?? [],
            viewing: 0
        )
    }

    public func attach(engine: (any Engine)?, library: GameLibrary?) {
        self.engine = engine
        self.library = library
        reviewImportIfReady()
    }

    /// The side about to move is the person's; the other side answers at one second a move.
    private func seatEngineOpponent() {
        setController(.engine, for: game.startingSideToMove.opposite)
        setThinkingTime(.openedRecord)
    }

    public func controller(for colour: PieceColour) -> Controller {
        controllers[colour] ?? .hand
    }

    public func setController(_ controller: Controller, for colour: PieceColour) {
        guard !isWeighing, activePunishment == nil else { return }
        guard controllers[colour] != controller else { return }
        controllers[colour] = controller
        // Changing who moves for the side already on the clock has to take effect now, not
        // next move — that is what the switch is for.
        retune()
    }

    /// Whether the engine is holding either Controller, which is when its clock is worth showing.
    public var isEnginePlaying: Bool {
        controller(for: .white) == .engine || controller(for: .black) == .engine
    }

    /// Both Controllers on the engine: the app playing itself, with nobody on the clock.
    public var isSelfPlaying: Bool {
        controller(for: .white) == .engine && controller(for: .black) == .engine
    }

    /// How long the engine gets over a move it plays for a colour it controls.
    ///
    /// What somebody chose, or what the game calls for if nobody has: Mirrored Time against a
    /// person, three seconds a move when the engine is playing itself.
    ///
    /// Self-play also overrules a standing choice of Mirrored Time, which is the one setting the
    /// game is allowed to refuse. It is not a preference there so much as a question with no
    /// answer — there is no player's last move to mirror — and a clock that quietly meant one
    /// second for ever is worse than the app saying which clock it is actually using.
    public var thinkingTime: ThinkingTime {
        guard let chosenThinkingTime else { return isSelfPlaying ? .selfPlay : .mirrored }
        if chosenThinkingTime == .mirrored, isSelfPlaying { return .selfPlay }
        return chosenThinkingTime
    }

    /// Puts the engine on a different clock, mid-move if that is when it is said.
    ///
    /// Now rather than next move, for the same reason changing a Controller is: a search that
    /// carried on under the old clock would make the control a promise about the move after this
    /// one, and the move being waited for is the one anybody reaches for this because of. The
    /// running search starts again on the new clock rather than being trimmed to it — the time
    /// asked for is the time it gets.
    public func setThinkingTime(_ time: ThinkingTime) {
        guard !isWeighing, activePunishment == nil else { return }
        guard thinkingTime != time else { return }
        chosenThinkingTime = time
        retune()
    }

    /// Turns the engine's advice off, or back on. Also takes effect now: a number left standing
    /// from the search that has just been called off is the one thing practice must not show.
    public func setPractising(_ practising: Bool) {
        guard !isWeighing, !isTilling || practising else { return }
        guard isPractising != practising else { return }
        isPractising = practising
        analysis = nil
        // Opening feedback must never start a second, whole-game scoring pass.
        retune()
    }

    /// Turns the tactics finder on, or back off. Takes effect now: a shot left standing after
    /// the switch is thrown is the one thing the live board must not keep drawing.
    public func setFindingTactics(_ on: Bool) {
        guard !isTilling || !on else { return }
        guard isFindingTactics != on else { return }
        isFindingTactics = on
        if !on {
            tactic = nil
            isProbingTactics = false
            probedAnalysis = nil
            // An advice Stint already paid for this position must not be taken down just because
            // the finder card was left. Retune only when there is nothing in hand to keep.
            if searchTask != nil || analysis != nil { return }
            retune()
            return
        }
        // Finding opportunities must not restart a move already on the clock or a review.
        if thinking != nil || reviewPass?.isRunning == true { return }
        if recallCachedAnalysis(), let found = analysis {
            tactic = Tactic.confirmed(in: viewed, analysis: found)
            probedAnalysis = found
            return
        }
        if let found = analysis {
            noteProgress(found)
            tactic = Tactic.confirmed(in: viewed, analysis: found)
            probedAnalysis = found
            return
        }
        retune()
    }

    /// What the strip under the board should say while the finder is on.
    ///
    /// Nil when the finder is off. It talks about whichever position is on screen, a past Ply
    /// included: the finder is a card of its own now, and swiping onto it is the asking
    /// (docs/adr/0025, amending 0023).
    public var tacticPrompt: String? {
        guard isFindingTactics, !viewed.isOver else { return nil }
        if isProbingTactics, tactic == nil { return localized("finder.checking") }
        if let tactic {
            let whose = localized(isHandTurn ? "finder.ours" : "finder.theirs")
            return "\(whose)：\(tactic.sentence)"
        }
        return localized("finder.none")
    }

    /// The mate anybody can see from the position on screen, whoever it belongs to
    /// (docs/adr/0025).
    ///
    /// **No search of its own.** It reads whichever one has already run: the standing Analysis
    /// when the engine is talking, and the finder's bounded probe when it is not. So the app
    /// never spends engine time to go looking for a mate, and while practising with the finder
    /// off there is nothing to read and nothing is said — which is ADR-0015 left standing rather
    /// than argued with.
    ///
    /// Any position the eye is on, the latest or a past one. A mate on a Ply somebody walked back
    /// to is the same fact about the same board, and the card carrying it is one swipe away from
    /// 考一遍 rather than on top of it — so looking is a thing a person does on purpose, and the
    /// question is not answered before it is asked (docs/adr/0025, amending 0023).
    public var mateNews: MateNews? {
        guard !viewed.isOver else { return nil }
        guard let source = analysis ?? probedAnalysis else { return nil }
        return MateNews.read(source, in: viewed, hands: handColours)
    }

    /// The colours a person is playing. Both, one, or — the engine against itself — neither.
    private var handColours: Set<PieceColour> {
        Set([PieceColour.white, .black].filter { controller(for: $0) == .hand })
    }

    // ------------------------------------------------------------- the reading

    /// Whether this game's starting position can be taken back to the editor. True for anything
    /// read off a picture, for as long as the game exists: the thing most likely to be wrong
    /// about such a game is a piece, and finding that out ten moves later is the normal case.
    ///
    /// It used to stop once a game had been filed into a collection, on the grounds that filing
    /// was somebody saying they had looked at it and kept it. Collections are gone (docs/adr/0028)
    /// and nothing replaced that signal, so the offer stands for as long as the game does — which
    /// is the side to err on, because a wrong piece is a different game.
    public var canEditPosition: Bool { origin == .recognised }

    /// The squares recognition was unsure about, while they are still worth pointing at. Once a
    /// move has been played the position has been accepted in practice, and rings on the board
    /// would be nothing but noise.
    public var unconfirmedSquares: Set<Square> {
        canEditPosition && game.plies.isEmpty ? shaky : []
    }

    /// Swaps the position the game starts from. Only for a game nobody has moved in yet — which
    /// is the case this exists for: correcting a piece straight after the photograph should fix
    /// the game in front of you, not leave a second record behind.
    public func replaceStart(with fresh: Game) -> Bool {
        guard !isWeighing, activePunishment == nil else { return false }
        guard game.plies.isEmpty else { return false }
        stopSearching()
        game = fresh
        cursor = 0
        analysis = nil
        thinking = nil
        lastHumanThink = nil
        shaky = []
        retune()
        return true
    }

    // ---------------------------------------------------------------- browsing

    /// The Game as it stands where the player is looking.
    ///
    /// Stored rather than recomputed per read: one screen reads this ten times to render
    /// itself once, and every read used to replay the whole game from its first move — O(n²)
    /// move applications for one frame. Now a read after a change rebuilds it once, which is
    /// the one Rules probe per change that ADR-0003 is about; the reads after it are free.
    public var viewed: Game {
        if let storedViewed { return storedViewed }
        let rebuilt = game.rewound(to: cursor) ?? game
        storedViewed = rebuilt
        return rebuilt
    }

    /// What the engine expects to happen from the position on screen, in SAN.
    ///
    /// Two cases, in this order: a Review's line for this position, when one has been written
    /// into the file; otherwise the Line the standing Analysis has reached — including a Stint a
    /// card spent during Practice, so a card can talk without waiting for a Review.
    public var viewedContinuation: [String] {
        let reviewed = game.reviewLine(atPly: cursor)
        if !reviewed.isEmpty { return reviewed }
        return analysis?.best?.san ?? []
    }

    /// The position the board should draw.
    ///
    /// Nothing is held on the glass any more — a move played is a move in the Game — so this is
    /// `viewed`. It stays a separate name because the drawing code asks a different question from
    /// the engine and the record, and the two are free to diverge again.
    public var board: Game { activePunishment?.position ?? viewed }

    /// The move that led to whatever the board is showing.
    public var boardLastMove: MoveSquares? { activePunishment == nil ? lastMove : nil }

    /// The Line the layer should read against whatever the board is showing.
    public var boardContinuation: [String] { activePunishment == nil ? viewedContinuation : [] }

    public var isAtLatest: Bool { cursor >= game.plies.count }

    /// The three lines this game is judged by (docs/adr/0027). Per game rather than global: the
    /// 拦截线 is 耕棋's switch as well as its dial, and 耕棋 is a thing one game is played under.
    public var lines: JudgementLines = .standard

    /// 耕棋: whether a move by hand is measured before it is allowed to stand.
    ///
    /// The switch and the dial are one control, because they are one question — "how much am I
    /// allowed to give away before I am stopped" — and off is the answer "anything" (docs/adr/0027).
    /// It is a *per game* setting and it sits beside 谁执白 and 引擎想多久 rather than in the
    /// app's settings: any position can be tilled, including one reached by playing on from a
    /// 错题 or read off a photograph.
    public var isTilling: Bool { lines.intercept != nil }
    public var findsPunishment = false
    public private(set) var punishment: Punishment?
    public var activePunishment: Punishment? {
        guard let punishment, !punishment.isFinished else { return nil }
        return punishment
    }

    /// Moves the 拦截线, or switches 耕棋 off with nil. **The only difficulty dial there is** —
    /// how strong the opponent is and how much slack the coach cuts are two different questions,
    /// and answering both with one knob makes it impossible to say who improved (docs/adr/0009).
    public func setTilling(_ enabled: Bool) {
        setIntercept(enabled ? (preferredIntercept ?? JudgementLines.defaultIntercept) : nil)
    }

    public func setIntercept(_ line: Double?) {
        guard !isWeighing, activePunishment == nil else { return }
        if let line, !line.isFinite || !JudgementLines.interceptRange.contains(line) { return }
        guard lines.intercept != line else { return }
        if line != nil, !isTilling { adviceBeforeTilling = isPractising }
        lines.intercept = line
        if let line {
            preferredIntercept = line
            isPractising = true
            analysis = nil
            stopReview()
            setFindingTactics(false)
        } else {
            isPractising = adviceBeforeTilling ?? true
            adviceBeforeTilling = nil
        }
        // Whatever was refused was refused under the old line. A move that would stand under the
        // new one is not a move somebody should still be being told about.
        refused = nil
        save()
        retune()
    }

    /// True while 耕棋 is working out what the move just played costs. The board shows the move
    /// during this: it has been played, and whether it is allowed to stand is the question.
    public private(set) var isWeighing = false

    /// The move 耕棋 has just taken back, for the screen to say one sentence about. Cleared by
    /// the next move, because it is about a board that is no longer there.
    public private(set) var refused: Refusal?

    /// A move that was played and taken back, and what it gave away.
    public struct Refusal: Hashable, Sendable {
        public let san: String
        /// Percentage points of win probability, from the mover's own side.
        public let drop: Double

        public init(san: String, drop: Double) {
            self.san = san
            self.drop = drop
        }

        /// 「Qh4 掉 23%，退回去重走。」 — what went wrong and nothing about what to do instead.
        /// The hint ladder is a separate thing somebody has to ask for (docs/adr/0031).
        public var sentence: String {
            localized("till.refused", san, Int(drop.rounded()))
        }
    }

    private var weighing: Task<Void, Never>?
    /// The session's own measurement of the move just played, for the change badge.
    private var measuring: Task<Void, Never>?
    func waitForJudgement() async {
        await weighing?.value
        await measuring?.value
    }
    func waitForPreparedInterception() async { await searchTask?.value }
    private var positionBeforeWeighing: Game?
    /// Where the eye was when the move now being weighed was played. A move played from an
    /// earlier Ply is judged from there, and a refusal has to put the reader back where they were
    /// rather than at the end of a game they were not looking at.
    private var cursorBeforeWeighing: Int?
    /// When the move now being weighed landed on the board.
    private var weighBegan: ContinuousClock.Instant?

    /// How long a move that is about to be taken back is left on the board.
    ///
    /// The refusal is the roll-back, and a roll-back nobody saw is a move that never happened.
    /// A search out of the cache answers inside one frame, so without this the piece went to its
    /// square and came off it between two draws of the board, and the whole gesture was invisible.
    /// Long enough to read as "there" before "and back", short enough not to be a wait.
    private static let takeBackHold = Duration.milliseconds(450)

    /// Gives the board its beat to show the move before the move is taken off it.
    private func holdTheMoveOnTheBoard() async {
        guard let weighedAt = weighBegan else { return }
        let shown = ContinuousClock.now - weighedAt
        guard shown < Self.takeBackHold else { return }
        try? await Task.sleep(for: Self.takeBackHold - shown)
    }
    public static let interceptDepth = 20
    public private(set) var hintLayer = 0
    public private(set) var relaxedIntercept: Double?
    /// Where the hint ladder stood, and what was last said about a refusal, at each position the
    /// player has been asked at. Session state and nothing more: the refusals themselves are the
    /// Game's (`Game.pendingTried`, docs/adr/0037), read at the cursor, and a session that kept
    /// its own copy of them was one more place for them to be wrong.
    private struct PendingHelp {
        var layer: Int
        var relaxed: Double?
        var refusal: Refusal?
    }
    private var helpByPosition: [String: PendingHelp] = [:]
    private var helpPosition: String?

    private func restoreHelpForViewedPosition() {
        let fen = viewed.state.fen
        guard helpPosition != fen else { return }
        if let helpPosition {
            helpByPosition[helpPosition] = PendingHelp(
                layer: hintLayer, relaxed: relaxedIntercept, refusal: refused
            )
        }
        helpPosition = fen
        let pending = helpByPosition[fen]
        hintLayer = pending?.layer ?? 0
        relaxedIntercept = pending?.relaxed
        refused = pending?.refusal
    }
    public var hintScore: Score? {
        guard activePunishment == nil else { return nil }
        guard hintLayer >= 1, interceptTable?.fen == viewed.state.fen else { return nil }
        return interceptTable?.analysis.best?.score
    }
    /// The number for the position on screen: the live bounded search of it when 耕棋 has one,
    /// else the curve's number for it. No recommended move is exposed here.
    private var tillingScore: Score? {
        if let table = interceptTable, table.fen == viewed.state.fen {
            return table.analysis.best?.score
        }
        return historyScore(atPly: cursor)
    }
    /// The 试招 refused at the position on the board that no move has absorbed yet, oldest
    /// first. Read out of the Game, which is where a refusal is written the moment it happens.
    public var pendingAttempts: [Game.Ply.Tried] { game.pendingTries(atPly: cursor) }

    /// Only the attempts relevant to the position/move being read, never a whole-game list:
    /// what is still pending here, or else what the move that stands here took with it.
    public var visibleAttempts: [Game.Ply.Tried] {
        let pending = pendingAttempts
        if !pending.isEmpty { return pending }
        guard cursor > 0, game.plies.indices.contains(cursor - 1) else { return [] }
        return game.plies[cursor - 1].tried
    }

    /// The position the 已退回 moves on show were played in — the one their 应招 is drawn from.
    ///
    /// The same branch `visibleAttempts` takes, because they are one question: those attempts
    /// belong to the position on the board, and the position on the board is where they were
    /// refused. Nil only for a game with nothing played in it yet.
    public var refusedPosition: Game? {
        if !pendingAttempts.isEmpty { return viewed }
        guard cursor > 0 else { return nil }
        return game.rewound(to: cursor - 1)
    }

    /// The position a 试招 made. It is the one its 应招 comes back from, and the one the board no
    /// longer shows, because 耕棋 has already taken the move back.
    public func position(after tried: Game.Ply.Tried) -> Game? {
        guard var played = refusedPosition,
            let move = SAN.move(for: tried.san, in: played.state),
            played.apply(move)
        else { return nil }
        return played
    }

    /// The 应招 a 试招 earned: what the file kept, or — for a move refused before replies were
    /// written down — the answer the shared bounded search already has for the position it made.
    ///
    /// One door rather than two, so a screen never has to know which kind of 试招 it is showing.
    /// A stored reply costs nothing; a missing one is asked for at the one budget every other
    /// position search uses, which normally answers out of the cache the refusal itself wrote
    /// (docs/adr/0034).
    public func reply(for tried: Game.Ply.Tried) async -> [String] {
        if !tried.line.isEmpty { return tried.line }
        guard let engine, let played = position(after: tried) else { return [] }
        let result = await engine.positionResult(played)
        guard !Task.isCancelled else { return [] }
        return Array((result?.best?.san ?? []).prefix(Reply.limit))
    }

    public var isFaceToFace = false

    public struct MoveChange: Equatable, Sendable {
        public let before: Score
        public let after: Score

        public func percent(for colour: PieceColour) -> Double {
            (after.winPercent - before.winPercent) * (colour == .white ? 1 : -1)
        }
    }
    private var measuredMove: (moves: [String], fen: String, change: MoveChange)?

    /// Only a newly played move gets a change badge; navigating the record is not a move.
    public var moveChange: MoveChange? {
        guard isAtLatest, !isWeighing, measuredMove?.moves == game.uciMoves,
              measuredMove?.fen == game.state.fen else { return nil }
        return measuredMove?.change
    }

    /// What the bar shows, by one priority: where the move just played landed, then the position
    /// on screen, then the standing Analysis.
    public var feedbackScore: Score? {
        moveChange?.after ?? tillingScore ?? analysis?.best?.score
    }

    /// The app's number for the position after `ply` moves — what the curve draws — by one
    /// priority: the move just measured, then what 耕棋 wrote onto the move, then what a Review
    /// wrote (docs/adr/0016). The live search of the position on screen does not enter here:
    /// reading an older move is reading history, and the live number belongs to `tillingScore`.
    /// Curve data includes the latest completed position even while reading an older move.
    public func historyScore(atPly ply: Int) -> Score? {
        guard (0...game.plies.count).contains(ply) else { return nil }
        if let measuredMove, measuredMove.moves == game.uciMoves, measuredMove.fen == game.state.fen {
            if ply == game.plies.count { return measuredMove.change.after }
            if ply == game.plies.count - 1 { return measuredMove.change.before }
        }
        if ply > 0, let judgement = game.plies[ply - 1].judgement {
            return judgement.score
        }
        return game.reviewScore(atPly: ply)
    }

    /// The personal side stays personal when the board is flipped. With two manual sides,
    /// the bottom side supplies the perspective, just as it does for the bar.
    public var feedbackColour: PieceColour {
        let hands = [PieceColour.white, .black].filter { controller(for: $0) == .hand }
        return hands.count == 1 ? hands[0] : (orientation == .whiteAtBottom ? .white : .black)
    }

    /// What the strip under the board says right now (`Standing`): one sentence, by one priority.
    ///
    /// Whether there is an engine at all is the host's fact, not this session's — a session
    /// with none says nothing, and the screen knows why there is none.
    public var standing: Standing {
        if viewed.isOver { return .finished("\(viewed.turn) \(viewed.scoreline)") }
        if isWeighing { return .weighing }
        if let refused { return .refused(refused) }
        if let change = moveChange {
            let value = change.percent(for: feedbackColour)
            return .change((value * 10).rounded() / 10)
        }
        return isPractising ? .quiet : .score(analysis?.best?.score)
    }

    private var isLatestMoveMeasured: Bool {
        measuredMove?.moves == game.uciMoves && measuredMove?.fen == game.state.fen
    }

    /// Badges the move just played if nothing has yet: the session asks for this itself every
    /// time it retunes, so a move that landed by any door — a hand, the engine, a held button —
    /// gets its number without a screen having to remember to ask for it.
    private func measureLatestMove() {
        guard hasTillingFeedback, !isWeighing, !game.plies.isEmpty, engine != nil,
              !isLatestMoveMeasured else { return }
        measuring = Task { [weak self] in await self?.measureLatestMoveChange() }
    }

    /// Reuse both bounded position results, publishing the bar's endpoint and its change
    /// together. Missing or cancelled analysis never becomes a fictitious zero-percent move.
    public func measureLatestMoveChange() async {
        guard hasTillingFeedback, !isWeighing, !game.plies.isEmpty, !isLatestMoveMeasured, let engine,
              let before = game.rewound(to: game.plies.count - 1) else { return }
        let after = game
        let weighed = await engine.weigh(after, from: before)
        guard !Task.isCancelled, !isWeighing, let weighed,
              game.uciMoves == after.uciMoves, game.startFEN == after.startFEN else { return }
        measuredMove = (after.uciMoves, after.state.fen, MoveChange(before: weighed.scoreBefore, after: weighed.after))
    }

    /// Explicit legacy migration only; never started automatically by the game screen.
    public func fillMissingTillingJudgements() async {
        guard hasTillingFeedback, !isWeighing, activePunishment == nil, let engine else { return }
        let original = game
        for index in original.plies.indices {
            guard !Task.isCancelled else { return }
            guard original.plies[index].judgement == nil,
                  controller(for: original.mover(ofPly: index + 1)) == .hand,
                  let before = original.rewound(to: index),
                  let after = original.rewound(to: index + 1) else { continue }
            let weighed = await engine.weigh(after, from: before)
            guard !Task.isCancelled else { return }
            guard let weighed else { continue }
            guard hasTillingFeedback, !isWeighing, activePunishment == nil else { return }
            guard game.uciMoves.prefix(index + 1).elementsEqual(original.uciMoves.prefix(index + 1)) else { return }
            if game.plies[index].judgement == nil {
                game.setJudgement(weighed.judgement, atPly: index)
                save()
            }
        }
    }
    public var hintHasTactic: Bool {
        guard hintLayer >= 2, let table = interceptTable, table.fen == viewed.state.fen else { return false }
        return Tactic.confirmed(in: viewed, analysis: table.analysis) != nil
    }

    public func requestHint() {
        guard activePunishment == nil else { return }
        guard isTilling, !isWeighing, isHandTurn, isAtLatest else { return }
        hintLayer = min(3, hintLayer + 1)
    }

    public func relaxIntercept(to value: Double) {
        guard isTilling, hintLayer == 3, !isWeighing, [20.0, 30.0].contains(value),
            value > (lines.intercept ?? 0) else { return }
        relaxedIntercept = value
    }

    private func interceptsHere(_ drop: Double) -> Bool {
        drop > 0 && drop >= (relaxedIntercept ?? lines.intercept ?? .infinity)
    }

    private func recordHelp(atPly ply: Int, san: String, drop: Double? = nil, score: Score? = nil, depth: Int? = nil) {
        if isTilling || hasTillingFeedback, let drop, let score {
            game.setJudgement(.init(drop: drop, score: score, depth: depth ?? interceptTable?.analysis.depth ?? 0), atPly: ply)
        }
        // A move let through at a relaxed line is written down as a 试招 the player did not find,
        // after the ones that were refused on the way to it.
        var relaxed: [Game.Ply.Tried] = []
        if relaxedIntercept != nil, let drop, lines.records(drop) {
            relaxed = [.init(san: san, drop: drop, notFound: true)]
        }
        // The move that stands takes the refusals with it: the position they were made at is
        // the one this move was played from, which is `ply` here — the index of the move itself.
        game.absorbPendingTried(atPly: ply, hints: hintLayer, adding: relaxed)
        hintLayer = 0
        relaxedIntercept = nil
    }

    public func revealTillingMove() {
        guard isTilling, hintLayer == 3, !isWeighing, isAtLatest, isHandTurn,
            let table = interceptTable, table.fen == game.state.fen,
            let uci = table.analysis.bestMove, let move = game.state.move(matching: uci)
        else { return }
        // Mark the original failed attempts, rather than manufacturing another occurrence.
        game.setPendingTried(
            pendingAttempts.map { .init(san: $0.san, drop: $0.drop, notFound: true, line: $0.line) },
            atPly: cursor
        )
        commit(move, by: .asked)
    }
    private var interceptTable: (fen: String, analysis: Analysis)?

    private func preparedDrop(for move: Move, in position: Game) -> Double? {
        guard let table = interceptTable, table.fen == position.state.fen,
            !table.analysis.isPartial,
            let candidate = table.analysis.lines.first(where: {
                position.state.move(matching: $0.bestMove ?? "") == move
            })
        else { return nil }
        return MoveQuality.drop(move: position.state.sideToMove,
                                before: table.analysis.best?.score, after: candidate.score)
    }

    private func prepareInterception(on position: Game, using engine: any Engine) {
        if interceptTable?.fen == position.state.fen { return }
        interceptTable = nil
        searchProgress = nil
        searchTask = Task { [weak self] in
            for await snapshot in engine.analysePosition(position) {
                guard !Task.isCancelled, let self else { return }
                noteProgress(snapshot)
                if !snapshot.isPartial {
                    interceptTable = (position.state.fen, snapshot)
                }
            }
            guard !Task.isCancelled, let self else { return }
            searchTask = nil
        }
    }

    /// What came of the opponent's mistake the move on screen was the reply to, or nil — which is
    /// most moves, because most moves are replies to nothing in particular.
    ///
    /// Read off the cursor, so it is the settlement for the move the eye is standing on. Nothing
    /// computes it ahead of the reply: the whole point is that a gift is named only once it has
    /// been taken or missed.
    public var settlement: Settlement? {
        game.settlement(atPly: cursor, lines: lines)
    }

    /// The move that led to the position on screen.
    public var lastMove: MoveSquares? { game.moveSquares(atPly: cursor) }

    public func step(by delta: Int) {
        guard !isWeighing, !isWalkingRecord, activePunishment == nil else { return }
        let wanted = min(max(0, cursor + delta), game.plies.count)
        guard wanted != cursor else { return }
        cursor = wanted
        adoptViewedAnalysis()
        Sounds.current.play(.move)
        retune()
    }

    public func jumpToLatest() {
        guard !isWeighing, !isWalkingRecord, activePunishment == nil else { return }
        guard cursor != game.plies.count else { return }
        cursor = game.plies.count
        adoptViewedAnalysis()
        retune()
    }

    /// Back to the position the game began in, in one tap.
    ///
    /// Browsing, not undoing: the game is untouched and every move is still there to be walked
    /// through again. It is the other end of `jumpToLatest`, and between them a game is readable
    /// without a single move being taken off it.
    public func jumpToStart() {
        guard !isWeighing, !isWalkingRecord, activePunishment == nil else { return }
        guard cursor != 0 else { return }
        cursor = 0
        adoptViewedAnalysis()
        Sounds.current.play(.move)
        retune()
    }

    /// Straight to a named Ply. Zero is the position the Game began in.
    public func jump(toPly ply: Int) {
        guard !isWeighing, !isWalkingRecord, activePunishment == nil else { return }
        let wanted = min(max(0, ply), game.plies.count)
        guard wanted != cursor else { return }
        cursor = wanted
        adoptViewedAnalysis()
        Sounds.current.play(.move)
        retune()
    }

    // ------------------------------------------------------- walking to a mistake

    /// A Ply this session was asked to walk to when its screen arrives, if any.
    public private(set) var arrivalWalk: Int?

    /// Whether the record is being walked forward right now. The board is not the player's while
    /// it is: a tap landing halfway through a fast-forward plays a move from a position that is on
    /// its way off the screen.
    public private(set) var isWalkingRecord = false

    /// Asks for the record to be walked to `ply` when the screen arrives, rather than cut to it.
    ///
    /// Opening a game from the 错题本 is opening it *at* a mistake, and the game is the story of how
    /// the player got there. Cutting to the Ply shows the position and nothing about the journey;
    /// walking shows the moves landing one after another, which is what the record strip has been
    /// scrolling through either way.
    public func walkOnArrival(toPly ply: Int) {
        guard !isWeighing, activePunishment == nil else { return }
        arrivalWalk = min(max(0, ply), game.plies.count)
    }

    /// Walks the record to the Ply this session was opened at, one move at a time.
    public func walkToArrival(step: Duration = .milliseconds(120)) async {
        guard let target = arrivalWalk else { return }
        arrivalWalk = nil
        await walk(toPly: target, step: step)
    }

    /// Walks the record to a Ply. Forward, one move at a time; backwards, straight there — a
    /// board that plays a game in reverse is a board doing something nobody asked it to.
    ///
    /// Deliberately not `step(by:)` per Ply: that retunes, which asks the engine about every
    /// position on the way — twenty searches to watch twenty moves go by. The walk moves the eye
    /// and the board and nothing else, and retunes once, where the eye stops.
    public func walk(toPly ply: Int, step: Duration = .milliseconds(120)) async {
        guard !isWalkingRecord, !isWeighing, activePunishment == nil else { return }
        let wanted = min(max(0, ply), game.plies.count)
        guard wanted != cursor else { return }
        guard wanted > cursor else {
            jump(toPly: wanted)
            return
        }
        isWalkingRecord = true
        defer { isWalkingRecord = false }
        while cursor < wanted, !Task.isCancelled {
            cursor += 1
            adoptViewedAnalysis()
            try? await Task.sleep(for: step)
        }
        guard !Task.isCancelled else { return }
        retune()
    }

    // ------------------------------------------------------------- finding the 错招

    /// Every 错招 in this Game, oldest first (docs/adr/0036).
    ///
    /// The player's own moves that cost at or over the 记录线, each carrying the position it was
    /// played from. This is the list the record strip marks and the strip under it walks: the
    /// answer to 「这一局我哪儿走错了」，which is a question about one game and not about the
    /// schedule.
    public var slips: [Slip] {
        // Keyed on what the answer depends on: the game, and the two lines that decide what
        // counts. A refusal changes the game; moving the record line changes the answer.
        let key = "\(game.uciMoves.joined(separator: " "))|\(lines.record)|\(lines.enqueue)"
        if let storedSlips, storedSlips.key == key { return storedSlips.slips }
        let slips = game.slips(by: handColours, lines: lines)
        storedSlips = (key, slips)
        return slips
    }

    /// The next 错招 from where the eye is: the one after it when it is standing on one, the
    /// first at or after it otherwise. Nil at the end of the game.
    public var nextSlip: Slip? {
        let all = slips
        if let here = all.firstIndex(where: { $0.ply - 1 == cursor }) {
            return all.dropFirst(here + 1).first
        }
        return all.first { $0.ply - 1 >= cursor }
    }

    // ------------------------------------------------------------------ moves

    public var isEngineTurn: Bool {
        !isWeighing && isAtLatest && !game.isOver && controller(for: viewed.state.sideToMove) == .engine
    }

    /// Whether a person may move on the board as it is being looked at. True in the past as
    /// well as the present: playing from an earlier position is how a move is taken back
    /// (docs/adr/0028) — what followed it is dropped, and the game carries on from there.
    public var isHandTurn: Bool {
        if let activePunishment { return !activePunishment.isJudging }
        guard !isWeighing, !isWalkingRecord, !viewed.isOver else { return false }
        if !isAtLatest { return true }
        return controller(for: viewed.state.sideToMove) == .hand
    }

    /// Who is putting a move down. The one thing the three ways in differ by is the clock, and
    /// this is what names that difference.
    private enum Mover {
        /// A person, on their own turn. Stops the clock the engine will mirror.
        case hand
        /// The engine, asked for one move by a held button. Not the player's thinking, so the
        /// mirror — a record of how long the *player* took — must not hold them to it.
        case asked
        /// The engine's own Controller. Its thinking time is not a thinking time to mirror either.
        case engine
    }

    /// A move made by a person. The clock this stops is what the engine will mirror.
    public func play(_ move: Move) {
        if let activePunishment {
            activePunishment.submit(move)
            return
        }
        guard isHandTurn, !isWeighing else { return }
        if let practice, !practice.isSettled {
            commit(move, by: .hand)
            return
        }
        // 耕棋 measures a move before it is allowed to stand, wherever it is played. It used to
        // measure only a move played at the end of the game — "a move played back down the game is
        // somebody taking one back" — and a saved game reopens at its *first* position, so playing
        // the first move again was the one move 耕棋 never looked at. It looked exactly like 耕棋
        // being switched off while switched on.
        guard isTilling || hasTillingFeedback, !viewed.isOver else {
            commit(move, by: .hand)
            return
        }
        weigh(move)
    }

    /// Plays the move, asks what it cost, and either lets it stand or puts it back.
    ///
    /// The move goes on the board first and comes off if it is refused, rather than being held
    /// while the engine thinks: a piece that does not move when you move it reads as a broken
    /// app, and the roll-back *is* the lesson — the board going back to where it was is the one
    /// unmistakable way to say "not that" (docs/adr/0027).
    ///
    /// **Judged from the position on the board, not from the end of the game.** A move played from
    /// an earlier Ply is played from a real position like any other, and the game it interrupts is
    /// kept whole beside it: a refusal has to leave that game exactly as it was, or the act of
    /// being stopped would swallow the line the player was reading.
    private func weigh(_ move: Move) {
        guard engine != nil else { return }
        let position = viewed
        var played = position
        guard played.apply(move), let landed = played.plies.last else {
            Sounds.current.play(.refused)
            return
        }
        if let began = turnBegan { lastHumanThink = ContinuousClock.now - began }
        stopSearching()
        stopReview()
        positionBeforeWeighing = game
        cursorBeforeWeighing = cursor
        weighBegan = ContinuousClock.now
        game = played
        cursor = game.plies.count
        analysis = nil
        thinking = nil
        refused = nil
        isWeighing = true
        Sounds.current.play(move, outcome: game.state.outcome)
        weighing?.cancel()
        weighing = Task { [weak self] in
            await self?.settle(move, san: landed.san, from: position, to: played)
        }
    }

    /// Join the baseline and resulting position's shared searches. Completion at either
    /// ten seconds or depth twenty publishes the assessment and releases the opponent.
    private func settle(_ move: Move, san: String, from position: Game, to played: Game) async {
        guard let engine else { return }
        // The 细判 itself is one act shared with the drill and the exercise (`Weighing`); what is
        // this session's is what to do with the answer. The 应招 the move earned comes back with
        // it, picked up from the same search that judged it (docs/adr/0034): the position the move
        // made is off the board the moment it is refused, so this is the last moment the Line can
        // be had without paying for a second search.
        let weighed = await engine.weigh(played, from: position, progress: noteProgress)
        guard !Task.isCancelled else { return }
        if let weighed { interceptTable = (position.state.fen, weighed.before) }
        // The move comes off the board, and it is given its beat to be seen there first — while
        // the session still counts as weighing, so a second tap cannot land on a board that is
        // halfway through taking one back.
        let takesItBack = weighed.map { interceptsHere($0.drop) } ?? true
        if takesItBack { await holdTheMoveOnTheBoard() }
        guard !Task.isCancelled else { return }
        isWeighing = false
        // What to put back when the move does not stand: the game as it was being read, whole,
        // and the eye where it was. `position` is only the position it was played from, which is
        // the whole game when the move was played at the end of it — and a prefix of it otherwise.
        let gameBefore = positionBeforeWeighing ?? position
        let cursorBefore = cursorBeforeWeighing
        positionBeforeWeighing = nil
        cursorBeforeWeighing = nil
        weighBegan = nil
        weighing = nil
        guard let weighed else {
            game = gameBefore
            cursor = cursorBefore ?? game.plies.count
            retune()
            return
        }
        guard interceptsHere(weighed.drop) else {
            // It stands. Whatever was refused on the way here rides along with it, as a comment
            // on the move that was actually played (docs/adr/0028).
            recordHelp(atPly: cursor - 1, san: san, drop: weighed.drop, score: weighed.after, depth: weighed.depth)
            measuredMove = (game.uciMoves, game.state.fen, MoveChange(before: weighed.scoreBefore, after: weighed.after))
            save()
            retune()
            return
        }
        refused = Refusal(san: san, drop: weighed.drop)
        game = gameBefore
        cursor = cursorBefore ?? game.plies.count
        // Written down here rather than when a move finally stands, because a player who is
        // refused and then walks away has played no such move — and the refusal used to go with
        // them: leaving the game forgot it, and opening it again showed nothing to practise
        // (docs/adr/0037). At the position it happened at, which is where the eye was standing —
        // a refusal is not always at the end of the game, because the player is free to play from
        // anywhere in it. No retune: the engine is not owed a reply to a move that came back.
        game.recordTried(Game.Ply.Tried(san: san, drop: weighed.drop, line: weighed.reply), atPly: cursor)
        save()
        Sounds.current.play(.refused)
        if findsPunishment { punishment = Punishment(position: played, engine: engine) }
    }

    /// The one way a move lands: the write, the cursor, the noise, the save, the retune. The
    /// three public paths differ only in the clock and who may be moving, and having them each
    /// hand-roll this is how one of them eventually forgets a line of it.
    private func commit(_ move: Move, by mover: Mover) {
        guard !isWeighing else { return }
        if let practice, !practice.isSettled {
            guard isAtLatest, game.state.fen == practice.game.state.fen else { return }
            stopSearching()
            stopReview()
            if mover != .hand { notePracticeHelp() }
            practice.play(move)
            guard practice.isJudging else { return }
            game = practice.game
            cursor = game.plies.count
            analysis = nil
            thinking = nil
            isWeighing = true
            Sounds.current.play(move, outcome: game.state.outcome)
            weighing = Task { [weak self] in
                await practice.settled()
                guard let self, !Task.isCancelled else { return }
                game = practice.game
                cursor = game.plies.count
                isWeighing = false
                if let verdict = practice.verdict, interceptsHere(verdict.drop) {
                    refused = Refusal(san: verdict.played, drop: verdict.drop)
                    if let start = game.rewound(to: 0) { game = start }
                    cursor = 0
                    // The drill's refusal goes through the same door as 耕棋's: into the Game, at
                    // the position it happened at (docs/adr/0037).
                    game.recordTried(
                        .init(san: verdict.played, drop: verdict.drop, line: verdict.reply), atPly: 0
                    )
                    Sounds.current.play(.refused)
                    return
                }
                if let before = practice.startingScore, let after = game.plies.first?.judgement?.score {
                    measuredMove = (game.uciMoves, game.state.fen, MoveChange(before: before, after: after))
                }
                save()
                retune()
            }
            return
        }
        if mover == .asked, isTilling || hasTillingFeedback, isAtLatest {
            weigh(move)
            return
        }
        let measuredDrop = preparedDrop(for: move, in: viewed)
        let measuredScore = interceptTable?.analysis.lines.first { $0.bestMove == move.uci }?.score
        // The clock. Only a hand move at the latest position stops it: Mirrored Time is the
        // length of a *player's* last turn, and neither an engine move nor a move asked of it
        // was the player thinking (docs/adr/0009).
        if mover == .hand, isAtLatest, let turnBegan {
            lastHumanThink = ContinuousClock.now - turnBegan
        }
        // A move played over an earlier one: what used to follow is dropped, and losing a line is
        // worth its own noise. Computed before the play, which is what the comparison is against.
        // The engine's own moves always land at the latest position, so this is only ever a hand
        // or asked concern.
        let replacing = mover != .engine && !isAtLatest && game.plies[cursor].uci != move.uci
        if mover == .engine {
            // Played only at the latest position: it was found for the position its search
            // started from, and applying it anywhere else would be a different move.
            guard isAtLatest, game.apply(move) else { return }
            cursor = game.plies.count
        } else {
            guard game.play(move, atPly: cursor) else {
                Sounds.current.play(.refused)
                return
            }
            cursor += 1
        }
        Sounds.current.play(move, outcome: viewed.state.outcome)
        if replacing { Sounds.current.play(.check) }
        // The invariant: the Analysis that described the position before this move is stale,
        // the game is written to its file, and the engine is asked what it makes of the new
        // position — whoever moved.
        analysis = nil
        recordHelp(atPly: cursor - 1, san: game.plies[cursor - 1].san, drop: measuredDrop, score: measuredScore)
        refused = nil
        save()
        retune()
    }

    // ------------------------------------------------------------------ a study

    public static let reviewDepth = 14

    // ----------------------------------------------------------------- point at a square

    private func applied(_ move: Move, to game: Game) throws -> Game {
        var next = game
        guard next.apply(move) else { throw StudyRefusal.illegalMove }
        return next
    }

    private enum StudyRefusal: Error { case illegalMove }

    // ------------------------------------------------------------------ the pass

    /// Re-scores every ply at one Depth, so the Scores in the file can be compared with each
    /// other and the Game can be ranked (docs/adr/0016, 0017).
    ///
    /// Started by turning the engine's opinion on, and by nothing else. There is no other door,
    /// which is what makes the switch answerable for it: a Game the player has never let the
    /// engine talk about has no marks in it at all.
    public func startReview(depth: Int? = nil) {
        guard !isWeighing, activePunishment == nil else { return }
        guard let engine, !game.plies.isEmpty, reviewPass?.isRunning != true else { return }
        let depth = depth ?? Self.reviewDepth
        let reviewed = game
        reviewTask?.cancel()
        reviewPass = ReviewPass(
            depth: depth, completed: 0, total: reviewed.plies.count, isRunning: true
        )
        reviewTask = Task { [weak self] in
            await engine.clear()
            var baseline: Score?
            if let start = reviewed.rewound(to: 0) {
                baseline = await engine.evaluate(start, budget: .depth(depth))
            }
            if Task.isCancelled { return }
            let results = await engine.review(reviewed, depth: depth) { index, _ in
                Task { @MainActor in self?.notePassReached(index) }
            }
            guard let self, !Task.isCancelled else { return }
            // Only written if the Game is still the one that was reviewed. A move or a branch
            // played while the pass ran makes these Scores a report on a game that no longer
            // exists, and one place to notice that is better than five mutators each
            // remembering to cancel.
            guard game.plies.count >= reviewed.plies.count,
                game.plies.prefix(reviewed.plies.count).map(\.uci) == reviewed.plies.map(\.uci)
            else {
                reviewPass = nil
                return
            }
            applyReview(results, startEvaluation: baseline, depth: depth)
            if var pass = reviewPass {
                pass.completed = results.count
                pass.isRunning = false
                reviewPass = pass
            }
        }
    }

    /// Stops a pass without writing anything.
    ///
    /// Half a pass is not half a Review: its Scores would sit in the file beside nothing, at a
    /// Depth the rest of the game was never searched to. Cancelling therefore leaves the Game
    /// exactly as unreviewed as it was.
    public func stopReview() {
        reviewTask?.cancel()
        reviewTask = nil
        if reviewPass?.isRunning == true { reviewPass = nil }
    }

    /// Read into a local and written back whole. `reviewPass?.completed = max(reviewPass?…)`
    /// reads the property inside its own modification, which is an exclusivity violation and
    /// traps at runtime rather than merely reading badly.
    private func notePassReached(_ index: Int) {
        guard var pass = reviewPass, pass.isRunning else { return }
        pass.completed = max(pass.completed, index + 1)
        reviewPass = pass
    }

    // -------------------------------------------------------- one move, asked for

    /// Whether the engine can be asked to take this move, for either colour.
    ///
    /// A search already running does not make it false. The button that asks is held down while the
    /// search it started runs, and a control that disabled itself under the finger would never hear
    /// it let go.
    ///
    /// The engine's own turn does, though: it is already walking this move under its own Controller,
    /// and 马上走 is how you stop waiting for it. Asking a second time for a move that is already
    /// being played is two controls doing one job.
    public var canPlayBestMove: Bool {
        engine != nil && !viewed.isOver && !isEngineTurn && !isWeighing && activePunishment == nil
    }

    /// Starts the engine thinking about a move it will play when it is let go.
    ///
    /// Held time *is* thinking time, which is the same bargain the engine's own moves are played
    /// under (Mirrored Time, docs/adr/0009): it is never handicapped, so the only thing that shapes
    /// how well it plays is how long it is left alone — and here that is a thumb on a button. A tap
    /// is a snap answer, two seconds is a considered one, and neither is the app deciding.
    ///
    /// The search is the shared bounded one every other reader of this position joins
    /// (`PositionSearches`), so a press after the position has been searched plays at once and a
    /// hold deepens the answer that was already going to be there. It ends by itself at ten
    /// seconds or depth twenty, and then the move is played: a thumb still down on a search that
    /// has stopped is waiting for nothing.
    ///
    /// Not a Controller and not advice left standing: one move, asked for by hand, for whichever
    /// colour is on the clock.
    public func beginAskedMove() {
        // Once per press. A press arrives as a drag of no distance, which reports as it is held, and
        // the button cannot know it is already down until the state saying so has come back around
        // to it — so two of them can reach here before it does. Nothing else is thinking on a hand
        // turn, which is what makes this the honest guard.
        guard canPlayBestMove, !isThinking, let engine else { return }
        // What the arrow on the board is pointing at. It is the answer already, for the case where
        // the press turns out to be a tap and the search has not said anything of its own yet.
        askedBest = analysis?.bestMove
        isAskReleased = false
        let position = viewed
        stopSearching()
        searchProgress = nil
        thinking = .asked
        searchTask = Task { [weak self] in
            // The shared bounded search: how deep it gets is how long the button is held, up to
            // the ten seconds or depth twenty the position is worth. One line is not asked for
            // here — the shared result carries two, and the one that decides a *move* is the best.
            for await snapshot in engine.analysePosition(position) {
                if Task.isCancelled { return }
                guard let self else { return }
                record(snapshot)
                if let best = snapshot.bestMove { askedBest = best }
                // The thumb came up before the engine had said anything worth playing, so this
                // first word is the answer.
                if isAskReleased { break }
            }
            guard let self, !Task.isCancelled else { return }
            finishAskedMove(in: position)
        }
    }

    /// Let go: the engine stops where it has got to and plays what it likes best.
    ///
    /// The move is played here rather than left to the stream ending, because a press can be
    /// shorter than the trip to the engine and back: the search may not have started yet, and a
    /// game that only moves when the engine happens to notice is not a button. So a release
    /// plays what is known at that instant and takes the search down with it — cancelling the
    /// task is what takes the search down, the stream's termination being the one way in. The
    /// one case where nothing is known yet waits for the first snapshot, which is the soonest
    /// an answer can exist at all, and the loop plays it the moment it lands.
    public func endAskedMove() {
        // Only the search a thumb started: a release is an answer to a press, and there is nothing
        // for it to end when the engine is walking a move of its own.
        guard thinking == .asked else { return }
        isAskReleased = true
        guard askedBest != nil else { return }
        let position = viewed
        stopSearching()
        finishAskedMove(in: position)
    }

    private func finishAskedMove(in position: Game) {
        thinking = nil
        isAskReleased = false
        let uci = askedBest
        askedBest = nil
        guard let uci, let move = position.state.move(matching: uci) else { return }
        playAsked(move)
    }

    /// A move the engine was asked for. Like a hand move in every way except the clock: the time
    /// the engine mirrors is a record of how long the *player* took, and this was not that.
    private func playAsked(_ move: Move) {
        commit(move, by: .asked)
    }

    /// Takes the last move of the game off. Only from the latest position: in the middle of a
    /// game, going backwards is browsing, and deleting is not what a back button means.
    public func undo() {
        guard !isWeighing, activePunishment == nil else { return }
        guard isAtLatest, !game.plies.isEmpty else { return }
        stopSearching()
        game.undo()
        Sounds.current.play(.move)
        // If undoing leaves the engine on the clock while the player is not, undo its move
        // too — otherwise it replies instantly and the player is exactly where they were.
        if controller(for: game.state.sideToMove) == .engine,
            controller(for: game.state.sideToMove.opposite) == .hand,
            !game.plies.isEmpty
        {
            game.undo()
        }
        cursor = game.plies.count
        analysis = nil
        lastHumanThink = nil
        save()
        retune()
    }

    // ------------------------------------------------------------- who starts

    /// Which colour moves first from the position this game began in.
    public var startingSideToMove: PieceColour { game.startingSideToMove }

    /// Whether the game could begin with `colour` to move at all. Handing the move to the
    /// other side can make a position illegal, because their opponent may be standing in
    /// check — and a position nobody could have reached is not one to play from.
    public func canStart(withSideToMove colour: PieceColour) -> Bool {
        restarted(withSideToMove: colour) != nil
    }

    /// Starts the game again from the position it began in, with `colour` to move.
    public func restart(withSideToMove colour: PieceColour) {
        guard !isWeighing, activePunishment == nil else { return }
        guard let fresh = restarted(withSideToMove: colour) else { return }
        stopSearching()
        // A game with moves in it has already been written to its own file. Leaving that file
        // behind and taking a new one means restarting never eats the record of what was
        // played — the old game is still in the library, exactly as it stood.
        if !game.plies.isEmpty { url = nil }
        game = fresh
        cursor = 0
        // The move has been handed to `colour`; the board turns so they face the person playing.
        orientation = .facing(colour)
        analysis = nil
        thinking = nil
        lastHumanThink = nil
        save()
        retune()
    }

    private func restarted(withSideToMove colour: PieceColour) -> Game? {
        guard var draft = PositionDraft(fen: game.startFEN) else { return nil }
        draft.sideToMove = colour
        return draft.game
    }

    // ----------------------------------------------------------------- engine

    /// Takes down whatever search is running, and the Stint clock with it.
    ///
    /// Every way a search ends goes through here, which is the point: a clock left ticking over a
    /// search that has already been replaced would stop the replacement — a thumb on 让引擎走 would
    /// have its move taken out from under it by the timer belonging to the advice it interrupted.
    private func stopSearching() {
        searchTask?.cancel()
        searchTask = nil
        measuring?.cancel()
        measuring = nil
        isAdviceSpent = false
    }

    /// Starts whatever the position calls for. Safe to call repeatedly.
    public func retune() {
        guard !isWeighing, activePunishment == nil else { return }
        restoreHelpForViewedPosition()
        stopSearching()
        measureLatestMove()
        thinking = nil
        thinkingBest = nil
        turnBegan = nil

        let position = viewed
        // Nothing starts while the engine is paused — not the standing Analysis, and not the
        // engine's own move, which takes a bounded budget and so would otherwise slip past the
        // gate in `analyse`. `retune` is called from more places than the app coming back
        // (`onAppear`, the engine having just played), so the answer to "what should the engine
        // be doing right now" has to include "nothing, nobody is watching".
        guard let engine, !position.isOver, !engine.isPaused else { return }

        if isEngineTurn {
            isProbingTactics = false
            tactic = nil
            probedAnalysis = nil
            continueAfterProbe()
            return
        }

        // Wherever the eye is, not only on the latest position (docs/adr/0025). The engine still
        // only *plays* from the latest one — `isEngineTurn` says so — so a probe at a past Ply
        // costs one bounded search and moves nothing.
        if isFindingTactics {
            probeTactics(on: position, using: engine)
            return
        }
        tactic = nil
        isProbingTactics = false
        probedAnalysis = nil
        continueAfterProbe()
    }

    /// Reads the rules' shot against the one bounded search of this position, then hands the
    /// engine back to whatever it was going to do — its own move, or a card's answer.
    ///
    /// Two lines is what the shared search is asked for everywhere: the shot needs a second
    /// candidate to be confirmed against, and a third would only cost Depth. It used to be a
    /// probe of its own at a shallower Depth, which meant the same position was searched twice
    /// to answer two questions about it.
    ///
    /// Before, not after: a prompt that lands once the opponent has already moved is a
    /// post-mortem (docs/adr/0023). The table is left warm on purpose.
    private func probeTactics(on position: Game, using engine: any Engine) {
        if recallCachedAnalysis(), let found = analysis {
            tactic = Tactic.confirmed(in: position, analysis: found)
            probedAnalysis = found
            isProbingTactics = false
            continueAfterProbe()
            return
        }
        tactic = Tactic.proposed(in: position)
        isProbingTactics = true
        searchTask = Task { [weak self] in
            var last: Analysis?
            for await snapshot in engine.analysePosition(position) {
                if Task.isCancelled { return }
                // How deep it has got, and nothing else off the snapshot. The probe is the only
                // search most cards ever run now, and a search that does not account for itself
                // is indistinguishable from an engine that died (docs/adr/0020). The Score stays
                // out of it: `record` is what lets an opinion reach the board, and this is not
                // one — which is why practice can leave this line alone.
                self?.noteProgress(snapshot)
                last = snapshot
            }
            guard let self, !Task.isCancelled else { return }
            if let last {
                tactic = Tactic.confirmed(in: position, analysis: last)
                probedAnalysis = last
            }
            isProbingTactics = false
            // The stream has ended. Leave the handle down, or 正在算 stays on a probe that
            // is already over, and the next card thinks the engine is still busy.
            searchTask = nil
            continueAfterProbe()
        }
    }

    private func continueAfterProbe() {
        let position = viewed
        guard let engine, !position.isOver, !engine.isPaused else { return }

        if isEngineTurn {
            thinking = .own
            // Mirrored Time is only the default, and only against a person: with both Controllers
            // on the engine there is no last human move to mirror, and there is a named clock
            // instead (`thinkingTime`).
            searchTask = Task { [weak self] in
                var last: Analysis?
                // One line: the engine is choosing a move, not advising, and each extra line
                // roughly doubles the time to the same Depth — a weaker move on the same clock.
                for await snapshot in engine.analysePosition(position) {
                    if Task.isCancelled { return }
                    self?.record(snapshot)
                    self?.thinkingBest = snapshot.bestMove
                    last = snapshot
                }
                guard let self, !Task.isCancelled else { return }
                thinking = nil
                if let uci = last?.bestMove, let move = position.state.move(matching: uci) {
                    playByEngine(move)
                }
            }
        } else {
            // Before the practice gate: the clock the engine mirrors is a record of how long the
            // player took, and that is true whether or not anyone was being advised.
            turnBegan = ContinuousClock.now
            if isTilling || (hasTillingFeedback && isPractising) {
                prepareInterception(on: position, using: engine)
                return
            }
            // Practice turns off exactly this search — the one whose only product is advice. It
            // is refused here rather than in the screen for the reason the pause is: "what should
            // the engine be doing right now" has one answer, and a screen that forgot would leave
            // a phone deepening a search nobody is allowed to see the result of.
            guard !isPractising else { return }
            advise(on: position, using: engine)
        }
    }

    /// Subscribe to the same bounded result used by judgement, tactics and opponent play.
    private func advise(on position: Game, using engine: any Engine) {
        guard !isTilling, !isWeighing else { return }
        isAdviceSpent = false
        searchProgress = nil
        searchTask = Task { [weak self] in
            for await snapshot in engine.analysePosition(position) {
                if Task.isCancelled { return }
                self?.record(snapshot)
            }
            guard !Task.isCancelled else { return }
            self?.searchTask = nil
            self?.isAdviceSpent = true
        }
    }

    /// Legacy callers may request the answer again, but never a new search of that position.
    public func adviseAgain() {
        guard isAdviceSpent, !isPractising, let engine, !engine.isPaused else { return }
        let position = viewed
        guard !position.isOver, !isEngineTurn else { return }
        advise(on: position, using: engine)
    }

    /// A Stint spent because a card arrived. Runs during Practice too: the swipe is the asking,
    /// and the board stays silent. A move the engine is walking, a plan's own look-ahead, and a
    /// Review in flight keep the engine — those are not advice, and a swipe must not take them
    /// off the clock.
    public func adviseForCard() {
        guard !isTilling, !isWeighing else { return }
        if let url, library?.reviewingURLs.contains(url) == true { return }
        guard let engine, !viewed.isOver, !engine.isPaused else { return }
        guard thinking == nil, reviewPass?.isRunning != true else { return }
        if recallCachedAnalysis() {
            if searchTask == nil { isAdviceSpent = true }
            return
        }
        if searchTask != nil { return }
        stopSearching()
        advise(on: viewed, using: engine)
    }

    /// Cuts the engine's thinking short and takes whatever it likes best right now.
    ///
    /// What the engine likes best is the newest snapshot it has reported, and that is already
    /// in hand — so the move is played here rather than left to the stream ending, and
    /// cancelling the task is what cuts the search short: the stream's termination is the one
    /// way in, so the engine never outlives the button that ends it.
    public func moveNow() {
        // Only the engine's own move. What it likes best is kept in `thinkingBest`, which only that
        // search fills in — an Asked Move keeps its answer somewhere else and is ended by letting
        // go, so cutting one short here would stop the search and play nothing.
        guard thinking == .own else { return }
        let position = viewed
        stopSearching()
        thinking = nil
        if let uci = thinkingBest, let move = position.state.move(matching: uci) {
            playByEngine(move)
        }
        thinkingBest = nil
    }

    /// A move the engine played for itself. It does not touch the mirror — the engine's own
    /// thinking time is not a thinking time for the engine to mirror.
    private func playByEngine(_ move: Move) {
        commit(move, by: .engine)
    }

    /// Stops thinking — the screen has gone away, or the app has.
    ///
    /// Cancelling is the whole of it: the stream's termination stops the engine, on its own
    /// queue and with the generation check that a bare stop call never had.
    public func suspend() {
        if let practice, practice.isJudging {
            practice.cancel()
            game = practice.game
            cursor = game.plies.count
        }
        punishment?.skip()
        weighing?.cancel()
        weighing = nil
        if let positionBeforeWeighing {
            game = positionBeforeWeighing
            cursor = cursorBeforeWeighing ?? game.plies.count
        }
        positionBeforeWeighing = nil
        cursorBeforeWeighing = nil
        weighBegan = nil
        isWeighing = false
        stopSearching()
        thinking = nil
        // A pass that outlived the screen would come back having written Scores nobody watched
        // arrive, at a Depth chosen by a screen that has gone.
        stopReview()
    }

    private func noteProgress(_ snapshot: Analysis) {
        searchProgress = SearchProgress(
            depth: snapshot.depth,
            selectiveDepth: snapshot.selectiveDepth,
            milliseconds: snapshot.timeMilliseconds
        )
    }

    /// Puts back what a previous search already found for the position on screen, including
    /// how deep it got — a cache hit that dropped the Depth would look like the engine had
    /// never run.
    @discardableResult
    private func recallCachedAnalysis() -> Bool {
        guard let cached = analysisByFen[viewed.state.fen] else { return false }
        analysis = cached
        noteProgress(cached)
        return true
    }

    /// Walking the record: restore this Ply's Analysis, or clear the last one so a new
    /// position does not keep wearing the old Depth.
    private func adoptViewedAnalysis() {
        if !recallCachedAnalysis() {
            analysis = nil
            searchProgress = nil
        }
    }

    private func record(_ snapshot: Analysis) {
        noteProgress(snapshot)
        // A move being walked is not advice, and during Practice that search's opinion is dropped
        // rather than merely hidden — the game's plies stay unmarked and the Review has nothing
        // to disagree with. A card's Stint is the other case: the swipe asked, so the Line is
        // kept for the card even while the board stays silent.
        if isPractising, thinking != nil { return }
        analysis = snapshot
        analysisByFen[viewed.state.fen] = snapshot
        if isFindingTactics {
            tactic = Tactic.confirmed(in: viewed, analysis: snapshot)
            probedAnalysis = snapshot
        }
        // The Score stays here, on a snapshot belonging to a screen, and is not written into
        // the Game. It used to be — "provisional, a Review will overwrite it" — but a Game is
        // a file, and a file that mixes one search's incidental Depth with a Review's uniform
        // one cannot be ranked afterwards without inventing mistakes. Only a Review writes an
        // evaluation now (docs/adr/0016).
    }

    // --------------------------------------------------------------- storage

    public var pgn: PGN {
        var written = PGN(game: game, tags: tags)
        // Event carries the app's name, which is what PGN's "which set of games is this" tag is
        // worth saying now that there are no collections (docs/adr/0028). Written unconditionally:
        // an Event an import brought in names somebody else's tournament, and the file this app
        // writes is this app's.
        written.setTag("Event", to: "Chessfen")
        if origin != .imported {
            written.setTag("White", to: controller(for: .white).playerName)
            written.setTag("Black", to: controller(for: .black).playerName)
        }
        written.setTag("Result", to: game.resultToken)
        written.setTag("Intercept", to: lines.intercept.map(String.init(describing:)))
        written.setTag("InterceptPreference", to: isTilling ? nil : preferredIntercept.map(String.init(describing:)))
        written.setTag(GameOrigin.tagName, to: origin.tagValue)
        if written.tag("Date") == nil {
            written.tags.append(PGN.dateTag())
        }
        return written
    }

    /// Writes after every move. A game is a few kilobytes of text, so there is no reason for
    /// an app that can be killed at any moment to hold one in memory only.
    ///
    /// A game nobody has moved in yet is not written at all. Recognising a board, looking at
    /// what the engine makes of it and going back is a thing people do constantly, and it
    /// should not leave a trail of empty games behind it. The first move is what makes a game
    /// worth keeping — and once a file exists it keeps being written to, even if the moves are
    /// taken back off it again.
    public func save() {
        guard !isWeighing else { return }
        guard let library else { return }
        guard url != nil || !game.plies.isEmpty else { return }
        if url == nil { url = library.newURL() }
        guard let url else { return }
        library.write(pgn, to: url)
        // The picture goes beside the game, written every save rather than only the first:
        // the photograph can arrive after the game has — it is the whole reason a game can be
        // recognised and then filed — and a picture assigned later is as much the game's as one
        // it was born with. Writing to the same place, so nothing accumulates.
        if origin == .recognised, let picture {
            library.writePicture(picture, for: url)
        }
    }

    /// Records a Review: one Score per ply, the starting position's, and the single Depth all
    /// of them were computed at. The Depth travels with the Scores because without it they are
    /// numbers nothing may be compared against (docs/adr/0016).
    public func applyReview(_ scores: [Score?], startEvaluation: Score?, depth: Int) {
        game.applyReview(scores, startEvaluation: startEvaluation, depth: depth)
        save()
    }

    /// The same, from a pass that kept the Line each Score came out of (docs/adr/0021).
    public func applyReview(_ reviewed: [ReviewedPly], startEvaluation: Score?, depth: Int) {
        game.applyReview(reviewed, startEvaluation: startEvaluation, depth: depth)
        save()
    }

    public nonisolated static func == (left: GameSession, right: GameSession) -> Bool { left === right }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
