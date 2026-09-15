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

    public private(set) var game: Game {
        didSet { storedViewed = nil }
    }
    public var orientation: Orientation
    /// Which ply the player is looking at: 0 is the starting position, `plies.count` the
    /// latest. Browsing back does not change the Game — but playing from there does, and what
    /// used to follow becomes a Variation.
    public private(set) var cursor: Int {
        didSet {
            storedViewed = nil
            // The cursor *is* the question a Drill asks, so moving it takes the answer off the
            // board with it — the move, the reason, and what either was worth. One home for that,
            // rather than four places that each remember.
            guess = nil
            reveal = nil
            declaringVerb = nil
            declaredIntent = nil
            revealTask?.cancel()
            revealTask = nil
            isRevealing = false
            // A question about a square is a question about *this* position, so the scanner goes
            // with the cursor as well. Same home, same reason.
            isScannerArmed = false
            scan = nil
            trial = nil
            scanAnswer = nil
            askTask?.cancel()
            isAsking = false
            walk = nil
            planDraft = nil
            planNotes = []
            planTask?.cancel()
            isPlanning = false
            planCheck = nil
            planOutcome = nil
            tactic = nil
            isProbingTactics = false
            probedAnalysis = nil
        }
    }
    /// The Game rebuilt where the cursor stands, kept until either the Game or the cursor
    /// moves — the whole point of `viewed` being a stored value instead of a derivation
    /// (see `viewed` itself).
    @ObservationIgnored private var storedViewed: Game?
    /// The move offered at the Ply being studied, on the board and not yet in the Game.
    public private(set) var guess: Guess?
    /// Whether the layer showing what the move changed is on.
    ///
    /// Off to begin with and off for every Game, like the engine's opinion and for the same reason
    /// (docs/adr/0015): a board wearing every layer at once is a board nobody reads, and the
    /// answer to "what did that move do" is worth more when somebody asked for it. On the session
    /// rather than in the screen so that it cannot come back from a Game the player has left.
    ///
    /// One exception, and it is the one moment it is allowed: committing a Guess turns it on. At
    /// that moment the engine is already speaking, so the tap it would cost buys nothing
    /// (docs/adr/0021).
    public private(set) var showsControlChange = false
    /// The verb chosen, waiting for the Square it is about. A claim with no target is not a claim
    /// yet, which is why this is not an Intent.
    public private(set) var declaringVerb: Intent.Verb?
    /// The finished declaration — a verb and its target, or 说不清 — ready to be committed with
    /// the move it is about.
    public private(set) var declaredIntent: Intent?
    /// What committing it showed. Nil until something has been committed, and cleared by
    /// anything that changes the question.
    public private(set) var reveal: Reveal?
    /// True while the searches behind a reveal are running.
    public private(set) var isRevealing = false
    /// The uniform-depth pass over the whole Game, while there is one running or just finished.
    public private(set) var reviewPass: ReviewPass?

    // ----------------------------------------------------------------- the scanner

    /// Whether the board is waiting to be pointed at.
    ///
    /// Armed by a tap and by nothing else. The scanner is the only thing the layer is allowed to
    /// say before a Guess is committed, and it only ever answers about the square somebody chose
    /// (docs/adr/0015, 0021) — so arming it is a deliberate act and never a state the screen
    /// arrives in.
    public private(set) var isScannerArmed = false
    /// The square that was pointed at, and every piece of the side to move that can reach it.
    public private(set) var scan: Scan?
    /// The move being tried out: on the board, in no Game, and gone the moment the scanner closes.
    public private(set) var trial: Trial?
    /// The Line being played out on the board, when one is.
    ///
    /// 走马灯 (docs/adr/0021). The Line is the one somebody already paid for — a Review's or a
    /// Reveal's — so watching it costs no engine time, and nothing in it is played: the Game, the
    /// PGN and the Variations are all untouched, and leaving puts the board back exactly.
    public private(set) var walk: Walk?
    /// The five moves on the board, with one Intent to come over the whole of them.
    ///
    /// 五步计划 (docs/adr/0017). Seeded from the engine's own best line, because a blank five-move
    /// canvas is a wall: the club player who could already write the line down did not need the
    /// feature, and everyone else got an empty box. What is asked of them instead is the harder
    /// half and the half that was always the point — the line is given, the *reason* is theirs,
    /// and it is judged (docs/adr/0022).
    public private(set) var planDraft: PlanDraft?
    /// What each move of the plan is for, and what it gives away — one per step, in order.
    public private(set) var planNotes: [PlanNote] = []
    /// True while the search that fills the plan in is running.
    public private(set) var isPlanning = false
    private var planTask: Task<Void, Never>?
    /// How the last committed plan was judged, and at which step.
    public private(set) var planCheck: PlanCheck?
    /// Where that plan arrived, by the same reckoning the carousel uses (docs/adr/0021).
    public private(set) var planOutcome: LineOutcome?
    /// What the engine said about the scanned position — only ever after somebody asked.
    public private(set) var scanAnswer: ScanAnswer?
    /// True while that search is running.
    public private(set) var isAsking = false
    private var askTask: Task<Void, Never>?

    private var revealTask: Task<Void, Never>?
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

    // ------------------------------------------------------------------- the Stint

    /// How long a Stint runs: ten seconds of advice, and then the engine stops.
    ///
    /// The Analysis in front of a player used to deepen for as long as it was left alone
    /// (docs/adr/0009), which on a phone left on a table is a search that never ends — eight cores
    /// on a position nobody is looking at any more, until the battery says otherwise. Ten seconds
    /// is past the point where another ply changes the recommendation on most positions, and
    /// 再算 10 秒 is there for the positions where it does.
    ///
    /// Settable only so a test does not have to wait ten seconds to watch one end. Not a dial: the
    /// app never changes it, and asking for another Stint is how a person asks for more.
    public var adviceStint: Duration = .seconds(10)

    /// Whether the standing Analysis has run its Stint and stopped, with more to give if asked.
    ///
    /// False while one is running and false when there is nothing to run — practice, a finished
    /// game, no engine. It is the whole of what puts 再算 10 秒 on the screen, so it says "stopped
    /// with more available" rather than merely "not searching".
    public private(set) var isAdviceSpent = false

    /// The clock that ends a Stint. Kept beside `searchTask` and taken down with it: a clock left
    /// ticking over a search that has already been replaced would stop the replacement.
    private var stintTask: Task<Void, Never>?

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

    /// Whether the engine keeps its opinion to itself: no advisory search runs, no Score is
    /// drawn, and nothing the engine thinks is written into the plies — so a game played this way
    /// carries no marks, and a Review is where it finally meets the engine at one uniform Depth
    /// (docs/adr/0009).
    ///
    /// **True is where every Game starts** (docs/adr/0015). An answer on screen is an answer the
    /// eye cannot decline to read, so no amount of self-discipline makes a visible evaluation
    /// compatible with learning to evaluate; showing what the engine thinks is therefore
    /// something a person does, once, on purpose. Playing a whole game with the engine looking
    /// over your shoulder and playing one out yourself are different exercises, and only the
    /// second one tells you what you would have done.
    ///
    /// It does not silence the engine as an *opponent*: a bounded search for the engine's own
    /// move is not advice, and playing a side without being told what it thinks of your last
    /// move is exactly the exercise.
    ///
    /// Not stored, and not carried from one Game to the next either. PGN has nowhere to put it,
    /// and — unlike who is playing which colour — it is not a way of working that should be set
    /// up once for a session of fifty positions: it is the one thing standing between a player
    /// and the answer, so it has to be found off every time rather than wherever it was left.
    public private(set) var isPractising = true

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
    /// engine's opinion either, so it may be read out where a Score may not (docs/adr/0024). What
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

    /// The next saved game in a collection, opened the way this one is being worked: who plays
    /// each side, and the clock somebody put the engine on. Those are ways of working rather than
    /// facts about a game, and having to set them again for every position is exactly the friction
    /// that makes a set of fifty not get done. Which way up the board is is a fact about the game
    /// being opened, though — each record faces its own side to move, not the last one's. Nil
    /// while the next file is still on the way (see `opened`).
    ///
    /// The one thing that does **not** carry over is the engine's opinion. Working through fifty
    /// positions with it left on is fifty positions read off a screen instead of fifty positions
    /// thought about, and that is precisely the set this app exists to make worth doing — so each
    /// one opens silent and turning it on is a fresh decision (docs/adr/0015).
    public func next(_ entry: GameLibrary.Entry) -> GameSession? {
        guard let next = Self.opened(entry, engine: engine, library: library) else { return nil }
        for colour in [PieceColour.white, .black] {
            next.setController(controller(for: colour), for: colour)
        }
        if let chosenThinkingTime { next.setThinkingTime(chosenThinkingTime) }
        return next
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
        guard thinkingTime != time else { return }
        chosenThinkingTime = time
        retune()
    }

    /// Turns the engine's advice off, or back on. Also takes effect now: a number left standing
    /// from the search that has just been called off is the one thing practice must not show.
    public func setPractising(_ practising: Bool) {
        guard isPractising != practising else { return }
        isPractising = practising
        analysis = nil
        // A Drill is what the board is while the opinion is off, so turning it on ends any
        // question in progress rather than leaving an unmarked answer under a curve.
        withdrawGuess()
        // The one moment a Game can acquire a Review. 复盘 is not a place any more; it is the
        // name of what this switch turns on, and a Game that has never had a uniform pass gets
        // one here (docs/adr/0015).
        if !practising, !game.isReviewed { startReview() }
        retune()
    }

    /// Turns the tactics finder on, or back off. Takes effect now: a shot left standing after
    /// the switch is thrown is the one thing the live board must not keep drawing.
    public func setFindingTactics(_ on: Bool) {
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
    /// (docs/adr/0024, amending 0023).
    public var tacticPrompt: String? {
        guard isFindingTactics, !viewed.isOver else { return nil }
        if isProbingTactics, tactic == nil { return "在看有没有战术" }
        if let tactic {
            let whose = isHandTurn ? "有战术" : "对方有战术"
            return "\(whose)：\(tactic.sentence)"
        }
        return "这一步没有战术"
    }

    /// The mate anybody can see from the position on screen, whoever it belongs to
    /// (docs/adr/0024).
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
    /// question is not answered before it is asked (docs/adr/0024, amending 0023).
    public var mateNews: MateNews? {
        guard !viewed.isOver else { return nil }
        guard let source = analysis ?? probedAnalysis else { return nil }
        return MateNews.read(source, in: viewed, hands: handColours)
    }

    /// The colours a person is playing. Both, one, or — the engine against itself — neither.
    private var handColours: Set<PieceColour> {
        Set([PieceColour.white, .black].filter { controller(for: $0) == .hand })
    }

    /// The collection this game is filed under, according to its own file.
    ///
    /// Read from the tags rather than carried alongside them, so that it cannot disagree with what
    /// the library shows — and so a game that has never been saved has no collection, which is the
    /// truth about it.
    public var collection: String? {
        guard let event = tags.first(where: { $0.name == "Event" })?.value,
            !GameLibrary.unfiledEvents.contains(event)
        else { return nil }
        return event
    }

    // ------------------------------------------------------------- the reading

    /// Whether somebody has filed this game into a collection, which is them saying they are keeping
    /// it — and so also saying the position it starts from is the one they meant.
    public var isFiled: Bool { collection != nil }

    /// Whether this game's starting position can be taken back to the editor. True for anything
    /// read off a picture, for as long as the game exists: the thing most likely to be wrong
    /// about such a game is a piece, and finding that out ten moves later is the normal case.
    ///
    /// Except once it has been filed. A game somebody has put in a collection has been looked at
    /// and kept, so either the reading was right or it has already been put right, and a screen
    /// that goes on asking about the pieces is asking a question that was answered.
    public var canEditPosition: Bool { origin == .recognised && !isFiled }

    /// The squares recognition was unsure about, while they are still worth pointing at. Once a
    /// move has been played the position has been accepted in practice, and rings on the board
    /// would be nothing but noise — as they would on a game that has been filed, for the same
    /// reason `canEditPosition` stops offering the editor.
    public var unconfirmedSquares: Set<Square> {
        canEditPosition && game.plies.isEmpty ? shaky : []
    }

    /// Swaps the position the game starts from. Only for a game nobody has moved in yet — which
    /// is the case this exists for: correcting a piece straight after the photograph should fix
    /// the game in front of you, not leave a second record behind.
    public func replaceStart(with fresh: Game) -> Bool {
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
        var rebuilt = game.rewound(to: cursor) ?? game
        // A held Guess is shown on the board. A move you cannot see is not a move you can weigh,
        // and the position after it is the thing being asked about.
        if let guess { rebuilt.apply(guess.move) }
        storedViewed = rebuilt
        return rebuilt
    }

    /// What the engine expects to happen from the position on screen, in SAN.
    ///
    /// Four cases, in this order:
    ///
    /// - a Guess that has been committed: the line the Reveal's own search produced;
    /// - a Guess still being held: nothing, because the engine has not been let speak yet
    ///   (docs/adr/0015), and the layer says so rather than guessing;
    /// - a Review's line for this position, when one has been written into the file;
    /// - otherwise the Line the standing Analysis has reached — including a Stint a card spent
    ///   during Practice, so 走马灯 and 要害格 can talk without waiting for a Review.
    public var viewedContinuation: [String] {
        if guess != nil { return reveal?.guessLine ?? [] }
        let reviewed = game.reviewLine(atPly: cursor)
        if !reviewed.isEmpty { return reviewed }
        return analysis?.best?.san ?? []
    }

    /// The position the board should draw — the trial's, when one is being tried out.
    ///
    /// Deliberately *not* `viewed`: the engine, the record, the Review and every other reader go on
    /// seeing the real position, so a trial cannot start a search, cannot be played by the engine
    /// on the other side, and cannot reach the Game. It is a hypothesis on a piece of glass.
    public var board: Game {
        if let planDraft, !planDraft.isEmpty {
            var building = viewed
            for move in planDraft.moves {
                guard building.apply(move) else { return viewed }
            }
            return building
        }
        if let walk, walk.step > 0 {
            var ahead = viewed
            for san in walk.played {
                guard ahead.apply(san: san) else { return viewed }
            }
            return ahead
        }
        guard let trial else { return viewed }
        var hypothetical = viewed
        guard hypothetical.apply(trial.move) else { return viewed }
        return hypothetical
    }

    /// The move that led to whatever the board is showing — the walked one, mid-walk.
    ///
    /// Without this the board tints the squares of the real last Ply while showing a position five
    /// moves past it, which is the one thing a carousel must not do: the tint is how the eye finds
    /// the move that just happened.
    public var boardLastMove: MoveSquares? {
        if let planDraft, let move = planDraft.moves.last {
            return MoveSquares(uci: move.uci)
        }
        if let walk, walk.step > 0 {
            let ahead = board
            return ahead.moveSquares(atPly: ahead.plies.count)
        }
        return lastMove
    }

    /// The Line the layer should read against whatever the board is showing.
    ///
    /// Mid-walk that is what the Line still expects, which is why the 要害格 layer follows the plan
    /// step by step rather than re-answering the same question five times: the second net moves with
    /// the board (docs/adr/0021).
    public var boardContinuation: [String] {
        // A plan being built is its own second net: what the layer judges each step against is the
        // rest of *your* plan, which is the one case where no engine is needed to say whether a
        // square mattered — you have already said what you are going to do with it (docs/adr/0021).
        if let planDraft { return planDraft.remaining }
        if let walk { return walk.remaining }
        return viewedContinuation
    }

    public var isAtLatest: Bool { cursor >= game.plies.count }

    /// The move that led to the position on screen.
    public var lastMove: MoveSquares? { game.moveSquares(atPly: cursor) }

    /// The lines that were played from the position on screen instead of the move that
    /// follows it.
    public var variationsHere: [[Game.Ply]] { game.variations(atPly: cursor) }

    public func step(by delta: Int) {
        let wanted = min(max(0, cursor + delta), game.plies.count)
        guard wanted != cursor else { return }
        cursor = wanted
        adoptViewedAnalysis()
        Sounds.current.play(.move)
        retune()
    }

    public func jumpToLatest() {
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
        guard cursor != 0 else { return }
        cursor = 0
        adoptViewedAnalysis()
        Sounds.current.play(.move)
        retune()
    }

    /// Straight to a named Ply — how a Game's worst moves are walked through in turn
    /// (docs/adr/0017). Zero is the position the Game began in.
    public func jump(toPly ply: Int) {
        let wanted = min(max(0, ply), game.plies.count)
        guard wanted != cursor else { return }
        cursor = wanted
        adoptViewedAnalysis()
        Sounds.current.play(.move)
        retune()
    }

    /// Carries on down one of the lines that was left behind here.
    public func enterVariation(_ index: Int, atPly ply: Int? = nil) {
        let at = ply ?? cursor
        guard game.promoteVariation(index, atPly: at) else { return }
        cursor = at + 1
        adoptViewedAnalysis()
        save()
        retune()
    }

    /// The Ply whose siblings the record can cycle, if the eye is on a fork.
    public var forkPly: Int? {
        if cursor > 0, game.siblings(atPly: cursor - 1).count > 1 { return cursor - 1 }
        if cursor < game.plies.count, game.siblings(atPly: cursor).count > 1 { return cursor }
        return nil
    }

    /// Swipes the record onto the next (or previous) sibling at the fork the eye is on.
    /// The strip stays one line; the tree is what the swipe walks.
    public func cycleFork(by delta: Int) {
        guard let ply = forkPly else { return }
        cycleFork(atPly: ply, by: delta, keepStanding: true)
    }

    /// Cycles the siblings of a named Ply. A tap on that ply's rail names it; a swipe on the
    /// strip uses whichever fork the eye is already on, and tries not to jump the cursor.
    public func cycleFork(atPly ply: Int, by delta: Int, keepStanding: Bool = false) {
        guard delta != 0 else { return }
        let siblings = game.siblings(atPly: ply)
        guard siblings.count > 1 else { return }
        let current = siblings.firstIndex { $0.variationIndex == nil } ?? 0
        let count = siblings.count
        let next = siblings[((current + delta) % count + count) % count]
        guard let index = next.variationIndex else { return }
        let standing = cursor
        guard game.promoteVariation(index, atPly: ply) else { return }
        if keepStanding {
            cursor = standing <= ply ? ply : ply + 1
        } else {
            cursor = ply + 1
        }
        adoptViewedAnalysis()
        save()
        retune()
    }

    // ------------------------------------------------------------------ moves

    public var isEngineTurn: Bool {
        isAtLatest && !game.isOver && controller(for: viewed.state.sideToMove) == .engine
    }

    /// Whether a person may move on the board as it is being looked at. True in the past as
    /// well as the present: playing from an earlier position is how a branch is made.
    public var isHandTurn: Bool {
        guard !viewed.isOver else { return false }
        // An answer is on the board and has not been committed or taken back. Until it is, the
        // board is not accepting anything else: a Drill with two answers on it has none.
        if guess != nil { return false }
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
        guard isHandTurn else { return }
        commit(move, by: .hand)
    }

    /// The one way a move lands: the write, the cursor, the noise, the save, the retune. The
    /// three public paths differ only in the clock and who may be moving, and having them each
    /// hand-roll this is how one of them eventually forgets a line of it.
    private func commit(_ move: Move, by mover: Mover) {
        // A move actually played answers the question the scanner was asking, whoever played it.
        endScan()
        // The clock. Only a hand move at the latest position stops it: Mirrored Time is the
        // length of a *player's* last turn, and neither an engine move nor a move asked of it
        // was the player thinking (docs/adr/0009).
        if mover == .hand, isAtLatest, let turnBegan {
            lastHumanThink = ContinuousClock.now - turnBegan
        }
        // A move played over an earlier one: what used to follow becomes a Variation, and the
        // capture of a whole line being replaced is worth its own noise. Computed before the
        // play, which is what the comparison is against. The engine's own moves always land at
        // the latest position, so this is only ever a hand or asked concern.
        let branching = mover != .engine && !isAtLatest && game.plies[cursor].uci != move.uci
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
        if branching { Sounds.current.play(.check) }
        // The invariant: the Analysis that described the position before this move is stale,
        // the game is written to its file, and the engine is asked what it makes of the new
        // position — whoever moved.
        analysis = nil
        save()
        retune()
    }

    // ------------------------------------------------------------------ a study

    /// Whether the one board is a Drill rather than a game right now: the engine's opinion is off
    /// and the Ply being looked at is a past one, so there is a move that was played from here and
    /// it has not been given away (docs/adr/0015).
    ///
    /// Not a mode and not a screen. It is a reading of the two things a person has already
    /// said — the switch, and where they are looking.
    public var isStudying: Bool {
        isPractising && !isAtLatest && !viewed.isOver
    }

    /// The Depth a study is settled at: the Game's own Review Depth when it has one, so a Drill's
    /// numbers and the file's numbers are the same numbers, and a default when it does not.
    public var studyDepth: Int { game.reviewDepth ?? Self.reviewDepth }

    public static let reviewDepth = 14

    /// Offers a move at the Ply being studied — on the board, not in the Game.
    ///
    /// The move is not played. Nothing is written, nothing is saved, and the Game is untouched: a
    /// Drill's answer has to be visible before it is marked, and taking it back has to cost
    /// nothing, or the honest first guess never gets made.
    public func offer(_ move: Move) {
        guard isStudying, guess == nil, reveal == nil else { return }
        // A move being offered ends the asking: the scanner is what you use *before* committing,
        // and a trial left on the board under a Guess would be two hypotheses at once.
        endScan()
        endWalk()
        let position = viewed
        guard position.state.move(matching: move.uci) != nil else {
            Sounds.current.play(.refused)
            return
        }
        guess = Guess(ply: cursor + 1, move: move, san: SAN.text(for: move, in: position.state))
        storedViewed = nil
        Sounds.current.play(.move)
    }

    // ----------------------------------------------------------------- point at a square

    /// Arms the scanner: the next tap on the board is a question about that square.
    public func armScanner() {
        // One hypothesis on the board at a time: a trial inside a walked line, or beside five plan
        // arrows pointing somewhere else, is a position nobody can name. The walk is ended because
        // nothing in it was the player's; a plan is refused instead, because a plan holds a reason
        // they typed and closing it under them would throw that away.
        guard !isScannerArmed, planDraft == nil else { return }
        endWalk()
        isScannerArmed = true
        scan = nil
        trial = nil
        scanAnswer = nil
    }

    /// Asks about one square: which of your pieces can legally get there.
    ///
    /// Only while armed, and only about the position being looked at. A scan makes no move, starts
    /// no search and writes nothing — the answer is a list of your own legal moves, which is a fact
    /// the player could count themselves and the app is merely quicker at.
    public func scan(at square: Square) {
        guard isScannerArmed else { return }
        trial = nil
        scanAnswer = nil
        askTask?.cancel()
        isAsking = false
        scan = viewed.scan(at: square)
        Sounds.current.play(scan?.isEmpty == false ? .move : .refused)
    }

    /// Plays one of the scanned moves as a hypothesis and says what it buys and costs.
    public func tryOut(_ move: Move) {
        guard let scan, scan.arrivals.contains(where: { $0.move == move }) else { return }
        scanAnswer = nil
        askTask?.cancel()
        isAsking = false
        trial = viewed.tryOut(move)
        Sounds.current.play(trial == nil ? .refused : .move)
    }

    /// Takes the trial back off the board, keeping the question.
    public func takeBackTrial() {
        guard trial != nil || scanAnswer != nil else { return }
        askTask?.cancel()
        isAsking = false
        trial = nil
        scanAnswer = nil
    }

    /// Closes the scanner and leaves nothing behind.
    public func endScan() {
        askTask?.cancel()
        isAsking = false
        isScannerArmed = false
        scan = nil
        trial = nil
        scanAnswer = nil
    }

    /// Asks the engine what it would play here, and reads its answer through the seven verbs.
    ///
    /// Last, and only on a tap. The whole design is in the order: you point at a square, you hear
    /// what your own move is worth in your own terms, and only then do you find out what the engine
    /// thought. Reversed, it is a hint button (docs/adr/0015). One bounded search at the study
    /// Depth, so it is the same number the Reveal would show and not a live search's whatever.
    public func askEngine() {
        guard let engine, scan != nil, !isAsking, scanAnswer == nil else { return }
        let position = viewed
        let depth = studyDepth
        let tried = trial?.san
        isAsking = true
        askTask?.cancel()
        askTask = Task { [weak self] in
            await engine.clear()
            var best: Line?
            for await snapshot in engine.analyse(position, budget: .depth(depth), lines: 1) {
                if Task.isCancelled { return }
                best = snapshot.best ?? best
                self?.noteProgress(snapshot)
            }
            guard let self, !Task.isCancelled else { return }
            isAsking = false
            guard let best, let san = best.san.first else { return }
            scanAnswer = ScanAnswer(
                depth: depth,
                best: san,
                score: best.score,
                reading: position.reading(of: best.san),
                isSameAsTrial: san == tried
            )
        }
    }

    // ----------------------------------------------------------------- 五步计划

    /// Opens the board as a place to try a line out, with the engine's next five drawn on it.
    ///
    /// Only at a past position, and that is not a limitation so much as what a plan *is* here: it
    /// goes into the file as a Variation, a Variation is an alternative to a move, and at the latest
    /// position there is no move for it to be an alternative to — a line played there is the game,
    /// which the app already has a name for (docs/adr/0017).
    ///
    /// The five moves arrive from the engine rather than from the player, and that is the one place
    /// on this screen where the engine goes first (docs/adr/0022). What it does not hand over is the
    /// claim: the reason is still declared, still in the seven verbs, and still judged move by move.
    public func startPlan() {
        guard planDraft == nil, !isAtLatest, cursor < game.plies.count else { return }
        endScan()
        endWalk()
        withdrawGuess()
        planCheck = nil
        planOutcome = nil
        planNotes = []
        // The layer marks each square as the line is walked, so it comes on with it — the same
        // exception a commit and a carousel get, and for the same reason (docs/adr/0015).
        showsControlChange = true
        planDraft = PlanDraft(ply: cursor)
        lookAhead()
    }

    /// Plays one move into the plan — any legal move, the engine's or one of your own.
    ///
    /// Deviating is the point. The five on the board are what the engine would do; playing something
    /// else and watching the next five change is the only way to find out what your idea was worth,
    /// and an app that only let you tap along the engine's line would be a replay button.
    ///
    /// Walking past five is allowed and 交卷 is not: exploring is free, and it is the *claim* the cap
    /// is about (docs/adr/0018).
    public func playInPlan(_ move: Move) {
        guard planDraft != nil else {
            Sounds.current.play(.refused)
            return
        }
        var tip = board
        guard let legal = tip.state.move(matching: move.uci) else {
            Sounds.current.play(.refused)
            return
        }
        let san = SAN.text(for: legal, in: tip.state)
        guard tip.apply(legal), var draft = planDraft else {
            Sounds.current.play(.refused)
            return
        }
        draft.steps.append(PlanDraft.Step(move: legal, san: san))
        // Stale the moment a move is played: the five that were drawn were five from the *old*
        // position, and leaving them up for the length of a search would be five arrows pointing
        // at a board that has moved.
        draft.ahead = []
        planDraft = draft
        planNotes = []
        Sounds.current.play(.move)
        lookAhead()
    }

    /// Plays the first `steps` moves of what the engine is showing.
    ///
    /// What the carousel's play button was, folded into the rows: tapping row three means "take me
    /// three moves down this line", and what you get is the position, not a recital.
    public func followPlan(through steps: Int) {
        guard let draft = planDraft, steps > 0, steps <= draft.ahead.count else { return }
        for step in draft.ahead.prefix(steps) {
            guard planDraft != nil else { return }
            var tip = board
            guard let legal = tip.state.move(matching: step.move.uci) else { break }
            let san = SAN.text(for: legal, in: tip.state)
            guard var walking = planDraft else { return }
            walking.steps.append(PlanDraft.Step(move: legal, san: san))
            planDraft = walking
        }
        guard var draft = planDraft else { return }
        draft.ahead = []
        planDraft = draft
        planNotes = []
        Sounds.current.play(.move)
        lookAhead()
    }

    /// Takes the last move back off the board and looks ahead again from where that leaves you.
    public func undoPlanMove() {
        guard var draft = planDraft, !draft.steps.isEmpty else { return }
        draft.steps.removeLast()
        draft.ahead = []
        planDraft = draft
        planNotes = []
        lookAhead()
    }

    /// Asks the engine what it would play from the tip of the walk, and reads every ply of it.
    ///
    /// One bounded search at the study Depth, so the plan and everything else a study says are the
    /// same number deep. Nothing arriving is not a failure and does not close anything: the board is
    /// still a board, and walking a line out on it by hand is what this was before the engine was
    /// asked to go first.
    ///
    /// **The table is not cleared between look-aheads, and that is the difference between a plan and
    /// a stream of suggestions.** Everywhere else a study searches it forgets first, so the Depth
    /// means what it says and a Reveal's number and the scanner's are the same number (docs/adr/0016).
    /// Nothing here shows a Score, so nothing here needs that — and clearing costs something real.
    /// Measured on Stockfish at depth 14 after 1.e4 e5, walking the engine's own line four moves:
    ///
    ///     cold   Nf3 Nc6 d4 exd4 Nxd4 → Nc6 Bb5 a6 Bxc6 dxc6 → Bb5 a6 Ba4 Nf6 O-O
    ///     warm   Nf3 Nc6 d4 exd4 Nxd4 → Nc6 Bb5 a6 Ba4 Nf6   → Bb5 a6 Ba4 Nf6 O-O
    ///
    /// Cold, the tail is rewritten at every step and the five on the board have nothing to do with
    /// the five that were there a move ago. Warm, each answer is the last one rolled forward by one
    /// move. The line still changes when the engine genuinely changes its mind — the tail of a PV is
    /// searched shallower than its head, so playing a move buys it a ply of depth and sometimes a
    /// different idea — but that change now means something (docs/adr/0022).
    private func lookAhead() {
        guard let engine, let draft = planDraft, draft.ahead.isEmpty else { return }
        let position = board
        let ply = draft.ply
        let walked = draft.steps.count
        let depth = studyDepth
        isPlanning = true
        planTask?.cancel()
        planTask = Task { [weak self] in
            var best: Line?
            for await snapshot in engine.analyse(position, budget: .depth(depth), lines: 1) {
                if Task.isCancelled { return }
                best = snapshot.best ?? best
                self?.noteProgress(snapshot)
            }
            guard let self, !Task.isCancelled else { return }
            isPlanning = false
            // Overtaken: another move went on the board while this search was running, and five
            // arrows out of a position nobody is standing in are worse than none.
            guard var draft = planDraft, draft.ply == ply, draft.steps.count == walked,
                draft.ahead.isEmpty, let best
            else { return }
            var tip = position
            for san in best.san.prefix(Game.Ply.planLimit) {
                let at = tip
                guard tip.apply(san: san), let played = tip.plies.last,
                    let move = at.state.move(matching: played.uci)
                else { break }
                // Written the way this package writes it, not the way the engine adapter did: the
                // notation on the rows and the notation everywhere else have to be one string.
                draft.ahead.append(
                    PlanDraft.Step(move: move, san: SAN.text(for: move, in: at.state))
                )
            }
            planDraft = draft
            readPlan()
        }
    }

    /// Reads every move the engine is showing — what it is for, and what it costs. Stored rather
    /// than derived so a view body never pays for it.
    private func readPlan() {
        guard let draft = planDraft, !draft.ahead.isEmpty else {
            planNotes = []
            return
        }
        // Read as the player, not as whoever happens to move at the tip: after one move of your own
        // the engine's five open with the opponent's reply, and 「你的」 has to go on meaning yours.
        planNotes = board.readPlan(of: draft.aheadSans, as: viewed.state.sideToMove) ?? []
    }

    /// The rest of a walked Line, as numbered arrows on the board now showing.
    ///
    /// Numbered to match the chips on 五步. What you already walked is not drawn: those moves
    /// happened, and the tint under the last one is how the board says so. At most five, because
    /// that is the card, and past that a board is a scribble.
    public var walkArrows: [PlanArrow] {
        guard let walk else { return [] }
        let remaining = Array(walk.remaining.prefix(5))
        guard !remaining.isEmpty else { return [] }
        let yoursToMove = board.state.sideToMove == viewed.state.sideToMove
        var position = board
        var arrows: [PlanArrow] = []
        for (offset, san) in remaining.enumerated() {
            guard position.apply(san: san), let played = position.plies.last,
                let move = MoveSquares(uci: played.uci)
            else { break }
            arrows.append(
                PlanArrow(
                    step: walk.step + offset + 1,
                    move: move,
                    isYours: offset.isMultiple(of: 2) == yoursToMove,
                    isPlayed: false
                )
            )
        }
        return arrows
    }

    /// The five the engine is showing, as the board draws them: one numbered arrow each.
    ///
    /// The sides alternate, so whose move a step is follows from its number — a legal line has no
    /// other shape. What you already walked is not drawn: those moves happened, and the tint under
    /// the last one is how the board says so everywhere else.
    public var planArrows: [PlanArrow] {
        guard let planDraft else { return [] }
        // Whose move step one is depends on how far you have walked, so the parity is measured
        // against the player and not against the head of the line.
        let opensOnYours = board.state.sideToMove == viewed.state.sideToMove
        return planDraft.ahead.enumerated().map { index, step in
            PlanArrow(
                step: index + 1,
                move: MoveSquares(from: step.move.from, to: step.move.to),
                isYours: index.isMultiple(of: 2) == opensOnYours,
                isPlayed: false
            )
        }
    }

    /// Whether there is a line and a reason to commit, and it is short enough to be told false.
    public var canCommitPlan: Bool {
        guard let planDraft, !planDraft.isEmpty, !planDraft.isTooLong, declaredIntent != nil
        else { return false }
        return true
    }

    /// Writes the walked line into the Game as a Variation with one Intent over the whole of it, and
    /// judges it by the same checker a single-Ply Intent uses.
    ///
    /// What is written is what you *played*, never what the engine was showing when you stopped: a
    /// plan is a claim about moves somebody made.
    public func commitPlan() {
        guard let draft = planDraft, let intent = declaredIntent, !draft.isEmpty, !draft.isTooLong,
            let before = game.rewound(to: draft.ply)
        else { return }
        let line = draft.steps.map { (uci: $0.move.uci, san: $0.san) }
        guard game.recordPlan(line, intent: intent, atPly: draft.ply) else { return }
        planTask?.cancel()
        isPlanning = false
        planCheck = intent.check(plan: draft.sans, in: before)
        planOutcome = before.outcome(of: draft.sans)
        planDraft = nil
        planNotes = []
        declaringVerb = nil
        declaredIntent = nil
        save()
    }

    /// Throws the plan away. Nothing was written, so there is nothing to undo.
    public func abandonPlan() {
        guard planDraft != nil else { return }
        planTask?.cancel()
        isPlanning = false
        planDraft = nil
        planNotes = []
        declaringVerb = nil
        declaredIntent = nil
    }

    // ----------------------------------------------------------------- 走马灯

    /// Starts playing the stored Line out on the board.
    ///
    /// The Line is whichever one somebody already paid for — the Review's for this Ply, or the one
    /// a committed Guess's search produced. No search is started to play a carousel: an app that
    /// went and fetched a line when somebody pressed play would be spending a Stint on a picture
    /// (docs/adr/0020, 0021). Nothing to play means nothing happens and the screen says why.
    public func startWalk(line: [String]? = nil) {
        // Not over a plan: the board would show one line and the arrows another, and the plan has a
        // transport of its own for exactly this.
        guard planDraft == nil else { return }
        // A walk already under way is not replaced: the person is reading it. One still sitting
        // on the first ply may take a longer Line as the Stint deepens, so 五步 does not freeze
        // on the first one-move snapshot.
        if let walk, walk.step > 0 { return }
        let line = line ?? viewedContinuation
        guard !line.isEmpty, walk?.line != line else { return }
        guard let outcome = viewed.outcome(of: line) else { return }
        endScan()
        // Watching the squares change hands is the whole point of playing it, so the layer comes on
        // with it — the same one exception a commit gets, and for the same reason (docs/adr/0015).
        showsControlChange = true
        let quiet = walk != nil
        walk = Walk(line: line, step: 0, outcome: outcome)
        if !quiet { Sounds.current.play(.move) }
    }

    /// Steps the Line forward or back. Clamped at both ends rather than wrapping: a carousel that
    /// silently starts again is a carousel you cannot read the end of.
    public func stepWalk(by delta: Int) {
        guard var walking = walk else { return }
        let wanted = min(max(0, walking.step + delta), walking.line.count)
        guard wanted != walking.step else { return }
        walking.step = wanted
        walk = walking
        Sounds.current.play(.move)
    }

    /// Puts the board back where it was.
    public func endWalk() {
        guard walk != nil else { return }
        walk = nil
    }

    /// Takes the offered move back off the board, and any reveal with it.
    public func withdrawGuess() {
        guard guess != nil || reveal != nil || declaredIntent != nil || declaringVerb != nil
        else { return }
        revealTask?.cancel()
        revealTask = nil
        isRevealing = false
        guess = nil
        reveal = nil
        declaringVerb = nil
        declaredIntent = nil
        storedViewed = nil
    }

    // ----------------------------------------------------------------- and why

    public func setShowsControlChange(_ shows: Bool) {
        showsControlChange = shows
    }

    /// Picks the verb, which is half a claim. Passing nil takes the choice back.
    ///
    /// A verb without a target cannot be committed: every one of the seven is a statement *about a
    /// Square*, and the one that is not — 说不清 — has its own way in below (docs/adr/0018).
    public func choose(_ verb: Intent.Verb?) {
        declaringVerb = verb
        declaredIntent = nil
    }

    /// Names the Square the chosen verb is about, which finishes the claim.
    public func aim(at square: Square) {
        guard let verb = declaringVerb else { return }
        declaredIntent = .claim(verb, square)
    }

    /// 说不清 — one tap, no target, and nothing discouraging about it.
    ///
    /// It is recorded exactly as the other seven are. A Game with twenty-five of these is itself
    /// the diagnosis, and the app that made it hard to say would never obtain one.
    public func declareUnclear() {
        declaringVerb = nil
        declaredIntent = .unclear
    }

    /// Whether there is a move and a reason to commit. Both, because a Drill takes a reason as
    /// well as a move: an answer with no reason attached teaches only whether you were lucky.
    public var canCommitGuess: Bool {
        guess != nil && declaredIntent != nil && engine != nil && !isRevealing && reveal == nil
    }

    /// Marks the offered move: your move, the engine's, and the one that was played, all at one
    /// Depth.
    ///
    /// Three searches rather than one, and all three at the same Depth, because the comparison is
    /// the whole product. A guess weighed against a deeper opinion of the alternative is a guess
    /// marked wrong by arithmetic (docs/adr/0016).
    public func commitGuess() {
        guard let guess, let engine, !isRevealing, reveal == nil, declaredIntent != nil
        else { return }
        guard let before = game.rewound(to: guess.ply - 1),
            let guessed = try? applied(guess.move, to: before),
            game.plies.indices.contains(guess.ply - 1)
        else { return }

        // Written now, before a single search runs and whether or not it turns out to be true.
        // Committing is the act; what the engine says afterwards is a separate fact about it.
        let declared = declaredIntent
        if let declared { record(guess, reason: declared) }
        // Checked against the board and not against the engine: whether f7 gained a defender is
        // a question about the position, and the rules code can answer it in microseconds
        // (docs/adr/0018).
        let check = declared?.check(guess.move, in: before)

        let playedSAN = game.plies[guess.ply - 1].san
        let playedPosition = game.rewound(to: guess.ply)
        let mover = game.mover(ofPly: guess.ply)
        let depth = studyDepth
        let recorded = game.reviewScore(atPly: guess.ply)
        let ply = guess.ply
        let offered = guess.san

        // The one moment the layer is allowed to appear by itself. Before a Guess is committed
        // it would be the blunder-check performed on the player's behalf (docs/adr/0015); at the
        // commit the engine is already talking, and hiding the reading behind another tap buys
        // nothing (docs/adr/0021).
        showsControlChange = true
        isRevealing = true
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            // At one Depth and from nothing already known: the game screen has been analysing
            // these same positions unbounded, and a search that inherits that is not at the Depth
            // it says it is.
            await engine.clear()

            var best: Line?
            for await snapshot in engine.analyse(before, budget: .depth(depth), lines: 1) {
                if Task.isCancelled { return }
                best = snapshot.best ?? best
                self?.noteProgress(snapshot)
            }
            // Analysed rather than merely evaluated: `evaluate` throws the Line away, and the
            // Line after the Guess is what the board reads to say which squares mattered. Same
            // search, same Depth, one more thing kept (docs/adr/0021).
            var afterGuess: Line?
            for await snapshot in engine.analyse(guessed, budget: .depth(depth), lines: 1) {
                if Task.isCancelled { return }
                afterGuess = snapshot.best ?? afterGuess
                self?.noteProgress(snapshot)
            }
            let guessScore = afterGuess?.score
            // The move that was played needs no search when it *is* the guess, and none when the
            // file already holds it at this very Depth.
            let playedScore: Score?
            if offered == playedSAN {
                playedScore = guessScore
            } else if let recorded, depth == self?.game.reviewDepth {
                playedScore = recorded
            } else if let playedPosition {
                playedScore = await engine.evaluate(playedPosition, budget: .depth(depth))
            } else {
                playedScore = nil
            }

            guard let self, !Task.isCancelled else { return }
            reveal = Reveal(
                ply: ply,
                mover: mover,
                depth: depth,
                guess: offered,
                guessScore: guessScore,
                played: playedSAN,
                playedScore: playedScore,
                best: best?.san.first,
                bestScore: best?.score,
                guessLine: Array((afterGuess?.san ?? []).prefix(Game.Ply.lineLimit)),
                // Read from the Line the same search produced, not asked for separately: the
                // engine gives a number and a sequence of moves and never a reason, and this is
                // the reason (docs/adr/0021).
                bestReading: before.reading(of: best?.san ?? []),
                intent: declared,
                intentCheck: check
            )
            isRevealing = false
            revealTask = nil
        }
    }

    /// Writes a committed Guess into the Game — on the played Ply when it *is* the played move,
    /// and as an alternative to it when it is not.
    ///
    /// Two homes because there are two facts. "I played Nf3 and here is why" belongs on Nf3; "I
    /// would have played d4, and here is why" is a line that was not played, which is what PGN's
    /// brackets have been for since 1994.
    private func record(_ guess: Guess, reason: Intent) {
        let index = guess.ply - 1
        guard game.plies.indices.contains(index) else { return }
        if game.plies[index].uci == guess.move.uci {
            game.setIntent(reason, atPly: guess.ply)
        } else {
            game.recordGuess(
                uci: guess.move.uci, san: guess.san, intent: reason, atPly: index
            )
        }
        save()
    }

    /// Plays the offered move for real: it becomes the move at this point in the Game, and the
    /// line it replaces is kept beside it — which is what playing from a past position has always
    /// done.
    ///
    /// The way a Drill turns into analysis. A guess worth playing is a line worth having, and the
    /// alternative — a study that can only ever be thrown away — is how somebody's best idea of
    /// the session gets lost.
    public func keepGuess() {
        guard let guess else { return }
        let index = guess.ply - 1
        let uci = guess.move.uci
        let move = guess.move
        let recorded = game.variations(atPly: index).firstIndex { $0.first?.uci == uci }
        withdrawGuess()
        guard cursor == index else { return }
        if let recorded {
            // Committing already wrote it down as an alternative, so this promotes what is there
            // rather than writing the same move a second time — and promoting carries the reason
            // with it.
            enterVariation(recorded)
        } else {
            play(move)
        }
    }

    /// A Game's worst moves as a list of questions, worst first — nil for a Game no Review has
    /// been over, which is a refusal and not an empty list (docs/adr/0017).
    public func worstMoves(_ count: Int = 3) -> [Criticality]? {
        game.worstMoves(count)
    }

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
    public var canPlayBestMove: Bool { engine != nil && !viewed.isOver && !isEngineTurn }

    /// Starts the engine thinking about a move it will play when it is let go.
    ///
    /// Held time *is* thinking time, which is the same bargain the engine's own moves are played
    /// under (Mirrored Time, docs/adr/0009): it is never handicapped, so the only thing that shapes
    /// how well it plays is how long it is left alone — and here that is a thumb on a button. A tap
    /// is a snap answer, two seconds is a considered one, and neither is the app deciding.
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
            // Unbounded: how long it runs is how long the button is held. One line: the
            // answer is one move, and every extra line halves how deep the hold looks.
            for await snapshot in engine.analyse(position, budget: .untilStopped, lines: 1) {
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
        stintTask?.cancel()
        stintTask = nil
        isAdviceSpent = false
    }

    /// Starts whatever the position calls for. Safe to call repeatedly.
    public func retune() {
        stopSearching()
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

        // Wherever the eye is, not only on the latest position (docs/adr/0024). The engine still
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

    /// A short two-line search that confirms or drops a rules-named shot, then hands the
    /// engine back to whatever it was going to do — its own move, or a Stint of advice.
    ///
    /// Before, not after: a prompt that lands once the opponent has already moved is a
    /// post-mortem (docs/adr/0023). The table is left warm on purpose.
    private func probeTactics(on position: Game, using engine: any Engine) {
        if recallCachedAnalysis(), let found = analysis {
            tactic = Tactic.confirmed(in: position, analysis: found)
            probedAnalysis = found
            isProbingTactics = false
            return
        }
        tactic = Tactic.proposed(in: position)
        isProbingTactics = true
        searchTask = Task { [weak self] in
            var last: Analysis?
            for await snapshot in engine.analyse(
                position, budget: .depth(Tactic.probeDepth), lines: 2
            ) {
                if Task.isCancelled { return }
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
            let budget = thinkingTime.budget(mirroring: lastHumanThink)
            searchTask = Task { [weak self] in
                var last: Analysis?
                // One line: the engine is choosing a move, not advising, and each extra line
                // roughly doubles the time to the same Depth — a weaker move on the same clock.
                for await snapshot in engine.analyse(position, budget: budget, lines: 1) {
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
            // Practice turns off exactly this search — the one whose only product is advice. It
            // is refused here rather than in the screen for the reason the pause is: "what should
            // the engine be doing right now" has one answer, and a screen that forgot would leave
            // a phone deepening a search nobody is allowed to see the result of.
            guard !isPractising else { return }
            advise(on: position, using: engine)
        }
    }

    /// One Stint of advice on a position, and the clock that ends it.
    ///
    /// The search itself is unbounded, and what stops it is a timer here rather than a `movetime`
    /// handed to the engine. Two reasons, and the first is the load-bearing one: the pause gate
    /// admits a bounded search and refuses an unbounded one, because a bounded search has somebody
    /// waiting on its answer while an unbounded one belongs to a screen (docs/adr/0009) — and this
    /// is the second kind however few seconds it runs for. The other is that cancelling is already
    /// how every search in this app ends, a thumb coming off 让引擎走 included.
    private func advise(on position: Game, using engine: any Engine, lines: Int = 3) {
        isAdviceSpent = false
        searchProgress = nil
        searchTask = Task { [weak self] in
            // A card's Stint is one line — 五步 walks it, 要害 reads it — because each extra
            // Line costs about a Depth, and the three-candidate panel is gone. Standing advice
            // with the opinion on still asks for three, the honest picture of a search
            // (docs/adr/0009).
            for await snapshot in engine.analyse(
                position, budget: .untilStopped, lines: max(1, lines)
            ) {
                if Task.isCancelled { return }
                self?.record(snapshot)
            }
        }
        let stint = adviceStint
        stintTask = Task { [weak self] in
            try? await Task.sleep(for: stint)
            guard !Task.isCancelled else { return }
            self?.spendStint()
        }
    }

    /// The Stint has run out. The search stops where it got to; what it found stays on screen, and
    /// the strip under the board offers another one.
    private func spendStint() {
        // Only ever an advisory search. Anything walking a move has taken the search over since
        // the clock was wound, and stopping that is not this clock's business — it has its own
        // ending, a budget or a thumb.
        guard thinking == nil, searchTask != nil else { return }
        stopSearching()
        isAdviceSpent = true
    }

    /// Another Stint on the position being looked at.
    ///
    /// Not a `retune`: that would start the player's clock again, and Mirrored Time is a record of
    /// how long *they* have been thinking. Asking the engine for more time is not the player
    /// taking less.
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
        guard let engine, !viewed.isOver, !engine.isPaused else { return }
        guard thinking == nil, planDraft == nil, reviewPass?.isRunning != true else { return }
        // A Guess still being held is the player answering; the engine does not speak first
        // (docs/adr/0015).
        guard guess == nil else { return }
        if recallCachedAnalysis() {
            if searchTask == nil { isAdviceSpent = true }
            return
        }
        if searchTask != nil { return }
        stopSearching()
        advise(on: viewed, using: engine, lines: 1)
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
        stopSearching()
        thinking = nil
        // A pass that outlived the screen would come back having written Scores nobody watched
        // arrive, at a Depth chosen by a screen that has gone.
        stopReview()
        revealTask?.cancel()
        revealTask = nil
        isRevealing = false
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
        // Event is only filled in when the game is not in a collection. It used to be set to the
        // app's name unconditionally, which would have rubbed out the collection of every filed game
        // on its next move — the tag naming the collection and the tag naming the app are the same
        // tag, and the file is the only place either of them lives (docs/adr/0010).
        if written.tag("Event").map(GameLibrary.unfiledEvents.contains) ?? true {
            written.setTag("Event", to: "Chessfen")
        }
        written.setTag("White", to: controller(for: .white).playerName)
        written.setTag("Black", to: controller(for: .black).playerName)
        written.setTag("Result", to: game.resultToken)
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
