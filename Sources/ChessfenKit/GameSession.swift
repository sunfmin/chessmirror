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
    /// (docs/adr/0025, amending 0023).
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
    public var board: Game { viewed }

    /// The move that led to whatever the board is showing.
    public var boardLastMove: MoveSquares? { lastMove }

    /// The Line the layer should read against whatever the board is showing.
    public var boardContinuation: [String] { viewedContinuation }

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

    public static let reviewDepth = 14

    // ----------------------------------------------------------------- point at a square

    // ----------------------------------------------------------------- 五步计划

    // ----------------------------------------------------------------- 走马灯

    // ----------------------------------------------------------------- and why

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
        guard thinking == nil, reviewPass?.isRunning != true else { return }
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
