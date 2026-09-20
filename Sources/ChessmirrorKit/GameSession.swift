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
            // And a 应招 being read was being read at *this* position: the board moving on is
            // the question being put away (docs/adr/0034) — and so is a 复判 of it.
            closeReply()
            cancelRejudge()
        }
    }
    /// The Game rebuilt where the cursor stands, kept until either the Game or the cursor
    /// moves — the whole point of `viewed` being a stored value instead of a derivation
    /// (see `viewed` itself).
    @ObservationIgnored private var storedViewed: Game?
    /// The 错招 walked out of the Game once, with the key they were walked under. Reading them is
    /// a rules probe per Ply, and the record strip asks on every draw.
    @ObservationIgnored private var storedSlips: (key: String, slips: [Slip])?
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

    public var thinking: Thinking? {
        if case .thinking(let whose) = activity { whose } else { nil }
    }

    /// Whether a move of either kind is being walked.
    public var isThinking: Bool { thinking != nil }

    // ------------------------------------------------------------------ what happened

    /// Something that happened on the board, for whoever makes the noise about it.
    ///
    /// The session says *what happened* and nothing about what it sounds like. It used to reach
    /// for the app's speaker itself, fourteen times, from the middle of deciding whether a move
    /// stands — so which noise a refusal makes was a line of the judgement, and the only way a
    /// test could hear a game was to swap a global out from under it.
    public enum Event: Hashable, Sendable {
        /// A move landed on the board — by hand, asked for, or the engine's own — and this is
        /// what it did to the game. A move being weighed has landed: it is on the board, and
        /// whether it stands is said by what follows.
        case landed(Move, outcome: Outcome)
        /// A move did not stand: 把关 took it back, or the rules would not play it.
        case refused
        /// A move was played over another, and what followed moved in beside it as a 分支
        /// (docs/adr/0043). Said after the `landed` of the move that did it.
        case forked
        /// The record stepped without a move being played: browsed, switched to another 分支,
        /// a move taken off the end, a reply played off the record.
        case stepped
    }

    /// Who is listening. One listener, set by the screen the session is on; a session nobody is
    /// listening to is a silent one, which is what a test and a session off screen both want.
    @ObservationIgnored public var onEvent: (@MainActor (Event) -> Void)?

    private func emit(_ event: Event) { onEvent?(event) }

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

    /// A card's Stint is in flight: something is searching, it is not the opponent's move being
    /// walked, and the card has not already been answered. What a card's frame says 正在算 on.
    public var isAdvising: Bool { thinking == nil && isSearching && !isAdviceSpent }

    /// Depth already paid for: the running search's progress while there is one, and once it has
    /// stopped the Depth of the Analysis in hand — a cache hit that dropped the Depth would look
    /// like the engine had never run. Nil until either has got anywhere.
    public var standingProgress: SearchProgress? {
        if let searchProgress, searchProgress.depth > 0 { return searchProgress }
        guard let analysis, analysis.depth > 0 else { return nil }
        return SearchProgress(
            depth: analysis.depth, selectiveDepth: analysis.selectiveDepth,
            milliseconds: analysis.timeMilliseconds
        )
    }

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

    /// Whether a Tactic may be named on the latest position (docs/adr/0023).
    ///
    /// Off at the start of every Game, never written to PGN, silent on a past Ply. Practice
    /// can stay on: then the board has no Score and no candidate Lines, only the shot.
    public private(set) var isFindingTactics = false
    /// The shot the finder currently names, if the last probe found one.
    public private(set) var tactic: Tactic?
    /// Whether it was arriving at the finder's cards that turned the finder on, rather than a
    /// person pressing its switch. Only what a swipe turned on does a swipe turn off again.
    private var finderOpenedByArrival = false

    /// The finder's line as numbered arrows on the position on screen, yours where the hand is
    /// moving that colour. Empty when the finder has named nothing.
    public var tacticArrows: [MoveArrow] {
        guard let tactic else { return [] }
        return MoveArrow.walk(tactic.line, from: viewed) { controller(for: $0) == .hand }
    }
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
    /// The 棋力 the engine plays its own moves at (docs/adr/0038). A fact about the game rather
    /// than a way of playing it, unlike a Controller: it is written onto every move the engine
    /// plays, and a reopened game comes back at the rung its last engine move was played at.
    public private(set) var strength: Strength
    private var tags: [PGN.Tag]
    private var searchTask: Task<Void, Never>?
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
        viewing: Int? = nil,
        /// The 棋力 to play at when the game itself does not say: what the player last picked.
        strength: Strength = .full,
        /// The lines to judge by. Whether 把关 is on is the file's word (`Intercept`) when it has one.
        lines: JudgementLines = .standard
    ) {
        self.game = game
        self.controllers = controllers
        // The game's own word first: a record with engine moves in it was played at a rung, and
        // reopening it at some other rung would be a different opponent wearing the same name.
        self.strength = game.plies.last(where: { $0.strength != nil })?.strength ?? strength
        self.orientation = orientation
        self.origin = origin
        self.picture = picture
        self.shaky = shaky
        self.url = url
        self.tags = tags
        self.cursor = min(max(0, viewing ?? game.plies.count), game.plies.count)
        // The file's word on 把关 wins over the caller's: it is a thing one game is played
        // under, and a game saved with it on comes back with it on. *Where* it stops the player
        // is the caller's 记录线 — the one number the player owns (docs/adr/0046) — and not the
        // number the file was saved under, which stays on the judgements that stood under it.
        self.lines = lines
        if PGN(game: game, tags: tags).intercept != nil { self.lines.noSlips = true }
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
        library: GameLibrary? = nil,
        lines: JudgementLines = .standard
    ) -> GameSession {
        let session = GameSession(
            game: game, orientation: orientation, origin: .recognised, picture: picture, shaky: shaky,
            lines: lines
        )
        session.attach(engine: engine, library: library)
        return session
    }

    /// A new game, both sides by hand unless asked otherwise, judged by the standard lines
    /// unless the caller has its own (the library's setting, with 把关 on or off).
    public static func fresh(
        _ game: Game,
        controllers: [PieceColour: Controller] = [.white: .hand, .black: .hand],
        engine: (any Engine)? = nil,
        library: GameLibrary? = nil,
        strength: Strength = .full,
        lines: JudgementLines = .standard
    ) -> GameSession {
        let session = GameSession(
            game: game, controllers: controllers, origin: .fresh, strength: strength, lines: lines
        )
        session.attach(engine: engine, library: library)
        return session
    }

    /// A new game to be played: the side to move in hand, the other on the engine. From the
    /// opening that is White vs Black-engine; it is the same seating as a reopened record.
    public static func playing(
        _ game: Game,
        engine: (any Engine)? = nil,
        library: GameLibrary? = nil,
        strength: Strength = .full,
        lines: JudgementLines = .standard
    ) -> GameSession {
        let session = fresh(game, engine: engine, library: library, strength: strength, lines: lines)
        session.seatEngineOpponent()
        return session
    }

    public static func practising(
        _ drill: Drill, engine: (any Engine)? = nil, library: GameLibrary? = nil
    ) -> GameSession {
        // The drill's 线 are the session's: the attempt is judged and ruled under one value, and
        // the screen's toggle and the 错招 row read the same one.
        let session = fresh(drill.game, controllers: [
            drill.mover: .hand, drill.mover.opposite: .engine
        ], engine: engine, library: library, lines: drill.lines)
        session.practice = drill
        session.orientation = drill.mover == .white ? .whiteAtBottom : .blackAtBottom
        return session
    }

    public func notePracticeHelp() {
        guard let practice, !practice.isSettled, !practice.isJudging else { return }
        practice.hintsOpened += 1
    }

    // ------------------------------------------------------------- the Review of an import

    /// An imported game nobody has judged yet (docs/adr/0016). Its moves carry no cost, so it
    /// has no 错招 and puts nothing in the 错题本 — not a clean game, a game nobody has looked
    /// at. The screen says so and offers the Review, rather than starting it on its own: it is
    /// seconds of engine per move, and the player says when.
    public var awaitsReview: Bool { origin == .imported && url != nil && !game.isReviewed }

    /// Whether the offer can be taken up right now: an engine to judge with, a library to write
    /// into, and no Review of this game already running.
    public var canReview: Bool { awaitsReview && engine != nil && library != nil && !isReviewing }

    /// How far this game's Review has got, while one is running. Read off the library, which is
    /// where the Review runs — a session that came and went finds it still going.
    public var reviewProgress: ImportReview.Progress? { url.flatMap { library?.reviewing[$0] } }
    public var isReviewing: Bool { reviewProgress != nil }

    /// How the last Review this session asked for ended, for the screen to say once.
    public enum ReviewNews: Hashable, Sendable {
        /// The Review landed, and this many positions of the game turned out to be 错招 — each
        /// of them, from the moment the file was written, an occurrence in the 错题本.
        case done(slips: Int)
        /// The engine could not settle every position. Nothing was written; ask again.
        case failed
    }
    public private(set) var reviewNews: ReviewNews?

    /// Starts the Review of this imported game. Nothing happens unless `canReview`.
    public func review() {
        guard canReview, let engine, let library, let url,
            let entry = library.entries.first(where: { $0.url == url }) else { return }
        reviewNews = nil
        library.reviewImported(entry, using: engine) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .reviewed(let reviewed):
                guard game.uciMoves == reviewed.game.uciMoves,
                    game.startFEN == reviewed.game.startFEN else { return }
                game = reviewed.game
                tags = reviewed.tags
                reviewNews = .done(slips: slips.count)
            case .superseded:
                return
            case .failed:
                reviewNews = .failed
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
    /// a reopened game starts with the side about to move in hand, the other side on the engine,
    /// and in practice: no arrow, no number, nobody whispering an answer. Reading faces the play:
    /// the person who opens a record plays its first move, and the engine answers it — as soon as
    /// it has finished loading, if the record got opened first.
    ///
    /// Nil — refused, not failed — while the file is still on the way from iCloud. Opening it
    /// would give an empty board wearing the real game's file name, and the autosave after the
    /// first move would write it over the game that was on its way (docs/adr/0012). Every door
    /// into a saved game goes through this one, so the refusal cannot be forgotten.
    public static func opened(
        _ entry: GameLibrary.Entry,
        engine: (any Engine)? = nil,
        library: GameLibrary? = nil,
        strength: Strength = .full,
        /// The player's lines as they are now. The file says whether 把关 is on; where it stops
        /// the player is the 记录线 handed in here (docs/adr/0046).
        lines: JudgementLines = .standard
    ) -> GameSession? {
        guard !entry.isDownloading else { return nil }
        let session = GameSession(entry: entry, library: library, strength: strength, lines: lines)
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
        library: GameLibrary?,
        lines: JudgementLines = .standard
    ) -> GameSession {
        let session = GameSession(
            game: game,
            controllers: controllers,
            orientation: orientation,
            origin: origin,
            picture: picture,
            shaky: shaky,
            lines: lines
        )
        session.attach(engine: engine, library: library)
        return session
    }

    /// Reopens a saved game, at the position it began in, facing the person holding the phone
    /// when the file says who that is, and the side about to move otherwise.
    private convenience init(
        entry: GameLibrary.Entry, library: GameLibrary? = nil, strength: Strength = .full,
        lines: JudgementLines = .standard
    ) {
        let pgn = entry.pgn
        let game = pgn?.game ?? Game(startFEN: PGN.standardStartFEN)!
        let hands = pgn?.handColours ?? []
        let facing = hands.count == 1 ? hands.first! : game.startingSideToMove
        self.init(
            game: game,
            // The other side is handed to the engine by `opened`. Practice is not set here or
            // there: it is where every Game starts.
            controllers: [.white: .hand, .black: .hand],
            // A record that names the player's side (an import tracked as Black, a game where the
            // engine had White) opens with that side at the bottom: it is their game, seen from
            // their chair. Any other record faces the side about to move: reading begins where
            // the play does.
            orientation: .facing(facing),
            origin: entry.origin,
            picture: entry.origin == .recognised ? library?.picture(for: entry.url) : nil,
            url: entry.url,
            tags: pgn?.tags ?? [],
            viewing: 0,
            strength: strength,
            lines: lines
        )
    }

    public func attach(engine: (any Engine)?, library: GameLibrary?) {
        self.engine = engine
        self.library = library
    }

    // ------------------------------------------------------------ the screen's comings and goings

    @ObservationIgnored private var host: EngineHost?
    @ObservationIgnored private var isOnScreen = false
    @ObservationIgnored private var watch = 0

    /// The screen this session is on has appeared, with the app's one engine host and the
    /// library to save into. From here the session keeps its own searches in step with the host:
    /// it takes the engine when it arrives, retunes when the app comes to the front and suspends
    /// when it leaves. A screen calls this on every appearance and `disappear` on every
    /// disappearance, and nothing else about when the engine should be doing what — the four
    /// hooks a screen used to wire for that were an ordering contract kept in a comment.
    ///
    /// Retunes before it returns, so a card dealt right after this keeps the Stint it starts.
    public func appear(on host: EngineHost, library: GameLibrary?) {
        self.host = host
        isOnScreen = true
        attach(engine: host.service, library: library)
        retune()
        followHost()
    }

    /// The screen has gone: nothing searches for a board nobody is looking at.
    public func disappear() {
        isOnScreen = false
        watch += 1
        suspend()
    }

    /// One registration per change: Observation fires once and forgets, so each firing hops to
    /// the main actor, reads what the host says now, and registers again. `watch` names the
    /// registration, so a screen that came and went does not leave a stale chain following.
    private func followHost() {
        guard let host, isOnScreen else { return }
        watch += 1
        let registration = watch
        withObservationTracking {
            _ = host.isReady
            _ = host.isActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, registration == watch, isOnScreen, let host = self.host else { return }
                // The engine may have finished starting while the screen was up: take it, and
                // the search this screen wants starts. The app leaving is a suspend, and coming
                // back a fresh retune rather than a search left running underneath — the engine
                // will not start one while the app is away, and a bounded one it held would
                // otherwise slip past that gate (`EngineHost.isActive`).
                if host.isReady, engine == nil { attach(engine: host.service, library: library) }
                if host.isActive { retune() } else { suspend() }
                followHost()
            }
        }
    }

    /// The side about to move is the person's; the other side is the engine's.
    private func seatEngineOpponent() {
        setController(.engine, for: game.startingSideToMove.opposite)
    }

    public func controller(for colour: PieceColour) -> Controller {
        controllers[colour] ?? .hand
    }

    public func setController(_ controller: Controller, for colour: PieceColour) {
        guard !isOccupied else { return }
        guard controllers[colour] != controller else { return }
        controllers[colour] = controller
        // A seat is a fact of the record: the file says who played which side, and the row
        // under the board reads whose moves are whose off that same file (`mine`).
        save()
        // Changing who moves for the side already on the clock has to take effect now, not
        // next move — that is what the switch is for.
        retune()
    }

    /// Puts the engine on another rung of the ladder, mid-move if that is when it is said.
    ///
    /// Now rather than next move, for the reason a clock change is: the move being waited for is
    /// the one anybody reaches for this because of, so a search the engine is walking under the
    /// old rung starts again under the new one (docs/adr/0038). Nothing else restarts — the bound
    /// is on the opponent's own move and on nothing else, so 细判 and the cards have nothing to
    /// redo.
    public func setStrength(_ strength: Strength) {
        guard !isOccupied else { return }
        guard self.strength != strength else { return }
        self.strength = strength
        if thinking == .own { retune() }
    }

    /// Turns the tactics finder on, or back off. Takes effect now: a shot left standing after
    /// the switch is thrown is the one thing the live board must not keep drawing.
    public func setFindingTactics(_ on: Bool) {
        guard !isNoSlipsOn || !on else { return }
        guard isFindingTactics != on else { return }
        isFindingTactics = on
        if !on {
            finderOpenedByArrival = false
            tactic = nil
            isProbingTactics = false
            probedAnalysis = nil
            // An advice Stint already paid for this position must not be taken down just because
            // the finder card was left. Retune only when there is nothing in hand to keep.
            if searchTask != nil || analysis != nil { return }
            retune()
            return
        }
        // Finding opportunities must not restart a move already on the clock.
        if thinking != nil { return }
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

    /// Arriving at 杀 or 战术: the swipe is the asking (docs/adr/0025), so the finder goes on if it
    /// was not on already, and remembers that it was the arrival that did it.
    public func arriveAtFinder() {
        guard !isFindingTactics else { return }
        setFindingTactics(true)
        finderOpenedByArrival = isFindingTactics
    }

    /// Leaving the finder's cards puts back only what arriving turned on. A switch somebody
    /// pressed by hand is theirs and stays as they left it — including on the strip, where it
    /// goes on colouring the mate's dot for the rest of the game.
    public func leaveFinder() {
        guard finderOpenedByArrival else { return }
        setFindingTactics(false)
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
        return MateNews.read(source, in: viewed, hands: mine)
    }

    /// The colours the player is playing: both, one, or — the engine against itself — neither.
    ///
    /// Read off the file this session would write (`PGN.handColours`), which is what the 错题本
    /// and the 连正榜 read off the file it did write: the row under the board and the ladder
    /// count the same moves because they ask the same question of the same record. For a game
    /// played here that is the seats; for an imported game it is the side the import tracked,
    /// whatever seat the player is reading it from.
    public var mine: Set<PieceColour> { pgn.handColours }

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
        guard !isOccupied else { return false }
        guard game.plies.isEmpty else { return false }
        stopSearching()
        game = fresh
        cursor = 0
        analysis = nil
        stopThinking()
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

    /// The position the board should draw.
    ///
    /// Nothing is held on the glass any more — a move played is a move in the Game — so this is
    /// `viewed`. It stays a separate name because the drawing code asks a different question from
    /// the engine and the record, and the two are free to diverge again.
    public var board: Game { activePunishment?.position ?? viewed }

    /// The move that led to whatever the board is showing.
    public var boardLastMove: MoveSquares? { activePunishment == nil ? lastMove : nil }

    public var isAtLatest: Bool { cursor >= game.plies.count }

    /// The lines this game is judged by (docs/adr/0027, 0046). Per game rather than global: the
    /// numbers are the player's, and whether 把关 reads them is a thing one game is played under.
    /// Written through `setLines` and `setNoSlips`, which is where what follows a change lives.
    public private(set) var lines: JudgementLines = .standard

    /// 把关: whether a move by hand is measured before it is allowed to stand.
    ///
    /// A switch and nothing else: where it stops the player is the 记录线, the same number that
    /// decides what is written down (docs/adr/0046). The switch is a *per game* setting and it
    /// sits beside 谁执白 and 引擎想多久 rather than in the app's settings: any position can be
    /// played under 把关, including one reached by playing on from a 错题 or read off a photograph.
    public var isNoSlipsOn: Bool { lines.noSlips }
    /// Whether the deck is dealt and a card may ask the engine: never under 把关. A card is an
    /// opinion about the position in front of the player, and 把关 says nothing about what to
    /// play (docs/adr/0031, 0040). The one rule, read here by the screen that deals and by the
    /// session that answers, so the two cannot disagree about whether a card is on the table.
    public var dealsCards: Bool { !isNoSlipsOn }
    public var findsPunishment = false
    /// The exercise last put on the board, kept once it is finished so its answer can still be
    /// read. Whether it is *on* the board is the activity's to say (`activePunishment`).
    public private(set) var punishment: Punishment?
    public var activePunishment: Punishment? {
        if case .exercising(let exercise) = activity { exercise } else { nil }
    }

    /// Puts an exercise on the board in place of the game, until it says it is finished. One
    /// with nothing to find — a position with no legal reply — is finished as it is made.
    private func exercise(_ exercise: Punishment) {
        punishment = exercise
        guard !exercise.isFinished else { return }
        exercise.onFinish = { [weak self, weak exercise] in
            guard let self, let exercise, activePunishment === exercise else { return }
            activity = .reading
        }
        activity = .exercising(exercise)
    }

    /// Switches 把关 on or off. It stops the player at the 记录线, **the only dial 把关 has on the
    /// judgement of a move** — how strong the opponent is (`strength`, docs/adr/0038) and how
    /// much slack the coach cuts are two different questions, and answering both with one knob
    /// makes it impossible to say who improved (docs/adr/0009).
    public func setNoSlips(_ enabled: Bool) {
        var moved = lines
        moved.noSlips = enabled
        setLines(moved)
    }

    /// The lines and the switch at once — what a game opened from the library starts under. The
    /// same consequences as flipping the switch alone: a refusal made under the old lines is
    /// forgotten, the file says the new ones, and the search starts over.
    public func setLines(_ new: JudgementLines) {
        guard !isOccupied else { return }
        guard new.isDrawn else { return }
        guard lines != new else { return }
        let interceptMoved = lines.intercept != new.intercept
        lines = new
        if interceptMoved, new.noSlips {
            analysis = nil
            setFindingTactics(false)
        }
        // Whatever was refused was refused under the old line. A move that would stand under the
        // new one is not a move somebody should still be being told about.
        refused = nil
        save()
        retune()
    }

    /// True while 把关 is working out what the move just played costs. The board shows the move
    /// during this: it has been played, and whether it is allowed to stand is the question.
    ///
    /// Ask `phase` unless the question is this fact.
    public var isWeighing: Bool {
        if case .weighing = activity { true } else { false }
    }

    /// What the session is doing, with what belongs to the doing of it. **The stored truth**:
    /// `phase` is its face, and `thinking`, `isWeighing`, `isWalkingRecord` and
    /// `activePunishment` are each one case of it read out.
    ///
    /// It used to be four stored facts read in a priority order, which left every combination of
    /// them representable — a move being weighed while the engine thought — and left what a
    /// weighing owns (the 原局 to put back, the task doing it, the flag saying so) as three fields
    /// to set and clear together by hand. A case carries what is its own, so leaving the case is
    /// letting go of all of it.
    private enum Activity {
        case reading
        /// The 原局 to put back if the move does not stand, and the task weighing it. A drill's
        /// attempt has no 原局 here: the drill keeps its own and puts it back itself.
        case weighing(standpoint: Standpoint?, task: Task<Void, Never>)
        case walking
        case exercising(Punishment)
        case thinking(Thinking)
    }

    private var activity: Activity = .reading

    /// Starts the engine walking a move. Refused while the board is spoken for or the record is
    /// on its way somewhere: those are not things a search may take the board from.
    private func think(_ whose: Thinking) -> Bool {
        switch activity {
        case .reading, .thinking:
            activity = .thinking(whose)
            return true
        case .weighing, .walking, .exercising:
            return false
        }
    }

    /// The engine is no longer walking a move. Nothing else is touched: a move being weighed or
    /// an exercise on the board is not the engine thinking, and is not ended by this.
    private func stopThinking() {
        if case .thinking = activity { activity = .reading }
    }

    /// A move is on the board and being weighed. It ends whatever the engine was walking, which
    /// the caller has already taken the search of, and replaces a weighing still in flight.
    private func beginWeighing(from standpoint: Standpoint?, task: Task<Void, Never>) {
        if case .weighing(_, let running) = activity { running.cancel() }
        activity = .weighing(standpoint: standpoint, task: task)
    }

    /// The weighing is over, whichever way: the board is the player's again.
    private func endWeighing() {
        if case .weighing = activity { activity = .reading }
    }

    /// What the session is doing, which is one thing at a time.
    ///
    /// Every mutator used to guard on its own handful of the session's facts, every screen
    /// `disabled` used to spell out its own combination, and the two drifted: which of them the
    /// player's hands have to wait for was answered in fifteen places. Now it is answered here,
    /// once, and the readers ask the one question they have: is the board spoken for
    /// (`isOccupied`), may the record be browsed (`canBrowse`), and whose clock it is
    /// (`isOnClock`).
    public enum Phase: Hashable, Sendable {
        /// Nothing is in flight: the board is the player's, or the record is being read.
        case reading
        /// 把关 is working out what the move just played costs (`isWeighing`).
        case weighing
        /// The record is being walked forward to a Ply, one move at a time (`isWalkingRecord`).
        case walking
        /// A 惩罚 exercise is on the board in place of the game (`activePunishment`).
        case exercising
        /// The engine is walking a move: its own, or one somebody is holding the button for.
        case thinking(Thinking)
    }

    /// The activity, without what it carries.
    public var phase: Phase {
        switch activity {
        case .reading: .reading
        case .weighing: .weighing
        case .walking: .walking
        case .exercising: .exercising
        case .thinking(let whose): .thinking(whose)
        }
    }

    /// The board is spoken for — a move being weighed, or an exercise standing in for the game —
    /// and nothing may change the game, its lines or its seats until it is given back.
    public var isOccupied: Bool {
        switch phase {
        case .weighing, .exercising: true
        case .reading, .walking, .thinking: false
        }
    }

    /// Whether the record may be browsed: not while the board is occupied, and not while it is
    /// already being walked. Browsing while the engine thinks is allowed — it is how a
    /// self-playing game is paused (docs/adr/0009).
    public var canBrowse: Bool {
        switch phase {
        case .reading, .thinking: true
        case .weighing, .walking, .exercising: false
        }
    }

    /// Whether `colour` is the side to move on the board being looked at — the side the action,
    /// the mark down the bar and the engine's line belong to. Nobody is on the clock while a move
    /// is being weighed: it has been played, and whether it stands is the question. An exercise
    /// has its own board and its own side to move.
    public func isOnClock(_ colour: PieceColour) -> Bool {
        switch phase {
        case .weighing: false
        case .exercising: board.state.sideToMove == colour
        case .reading, .walking, .thinking: !viewed.isOver && viewed.state.sideToMove == colour
        }
    }

    /// The move 把关 has just taken back, for the screen to say one sentence about. Cleared by
    /// the next move, because it is about a board that is no longer there.
    public private(set) var refused: Game.Ply.Tried?

    /// The session's own measurement of the move just played, for the change badge.
    private var measuring: Task<Void, Never>?
    /// Waits until everything that is judging a move has said its piece: a move being weighed
    /// and the badge measured after it, a 复判, a 应招 being fetched, an exercise checking a
    /// reply. Not the position's own standing search — that is the engine looking, or playing,
    /// and it is what a move played next interrupts. The one thing a screen or a test holds on
    /// to instead of polling the session's state: a verdict arrives when the engine has answered
    /// and not a moment sooner, and the state after this is the state the screen would draw.
    public func settled() async {
        if case .weighing(_, let task) = activity { await task.value }
        await measuring?.value
        await rejudgeTask?.value
        await replyTask?.value
        await punishment?.settled()
    }
    func waitForPreparedInterception() async { await searchTask?.value }
    /// The 原局 the move now being weighed was played from (`Standpoint`): what a refusal, a
    /// weighing nobody finished, or leaving the screen puts back. Nil when nothing is being weighed.
    private var standpoint: Standpoint? {
        if case .weighing(let standpoint, _) = activity { standpoint } else { nil }
    }

    /// How long a move that is about to be taken back is left on the board.
    ///
    /// The refusal is the roll-back, and a roll-back nobody saw is a move that never happened.
    /// A search out of the cache answers inside one frame, so without this the piece went to its
    /// square and came off it between two draws of the board, and the whole gesture was invisible.
    /// Long enough to read as "there" before "and back", short enough not to be a wait.
    private static let takeBackHold = Duration.milliseconds(450)

    /// Gives the board its beat to show the move before the move is taken off it.
    private func holdTheMoveOnTheBoard() async {
        guard let shown = standpoint?.shown, shown < Self.takeBackHold else { return }
        try? await Task.sleep(for: Self.takeBackHold - shown)
    }
    /// What was last said about a refusal at each position the player has been refused at, so
    /// the sentence under the board follows the eye: browsing away from a refusal puts it away,
    /// and coming back brings it back. Session state and nothing more: the refusals themselves
    /// are the Game's (`Game.pendingTried`, docs/adr/0037), read at the cursor, and a session
    /// that kept its own copy of them was one more place for them to be wrong.
    private var refusalByPosition: [String: Game.Ply.Tried] = [:]
    private var refusalPosition: String?

    private func restoreRefusalForViewedPosition() {
        let fen = viewed.state.fen
        guard refusalPosition != fen else { return }
        if let refusalPosition {
            refusalByPosition[refusalPosition] = refused
        }
        refusalPosition = fen
        refused = refusalByPosition[fen]
    }
    /// The number for the position on screen: the live bounded search of it when 把关 has one,
    /// else the curve's number for it. No recommended move is exposed here.
    ///
    /// While a move is being weighed it is the number of the position the move was played from.
    /// The position it made has no number until the weighing ends — that is what the weighing is
    /// — and a bar with no number draws a level game: on a phone, ten seconds and more of half
    /// and half over a position that is nothing like it. The table, while weighing, can only be
    /// that position's: the search that fills it was stopped when the move was played.
    private var noSlipsScore: Score? {
        if let table = interceptTable, table.fen == viewed.state.fen {
            return table.analysis.best?.score
        }
        if let known = historyScore(atPly: cursor) { return known }
        guard isWeighing else { return nil }
        return interceptTable?.analysis.best?.score ?? historyScore(atPly: cursor - 1)
    }
    /// The 试招 refused at the position on the board that no move has absorbed yet, oldest
    /// first. Read out of the Game, which is where a refusal is written the moment it happens.
    public var pendingAttempts: [Game.Ply.Tried] { game.pendingTries(atPly: cursor) }

    /// Where the wrong moves on the strip are read from: the position on the board first — what
    /// is still pending there, else what the move played *from* it took with it — and only when
    /// the position has nothing of its own, the move that has just landed on it, which is the one
    /// the eye is on at the end of a live game. Never a whole-game list.
    ///
    /// The position first, because a position is what the strip's cells, its marks and the 错题
    /// tiles all count (docs/adr/0036, 0037): walking to a 错题 puts the board on the position
    /// the move was played from, and the moves listed under it have to be that position's. They
    /// used to be read one Ply behind — off the move that had landed — so a tile walked to showed
    /// nothing, and the next arrow showed what the tile had promised.
    private enum WrongsAt: Equatable {
        /// Refusals still pending at the cursor.
        case pending
        /// The move at this index of `plies`: its 试招, and itself when it stood too expensively.
        case ply(Int)
        case nothing
    }

    private var wrongsAt: WrongsAt {
        if !pendingAttempts.isEmpty { return .pending }
        if game.plies.indices.contains(cursor),
            !game.plies[cursor].tried.isEmpty || stoodWrong(atPly: cursor) != nil
        {
            return .ply(cursor)
        }
        if cursor > 0, game.plies.indices.contains(cursor - 1) { return .ply(cursor - 1) }
        return .nothing
    }

    /// Only the attempts relevant to the position being read (`wrongsAt`): what is still pending
    /// here, else the 试招 the move played from here took with it, else what the move that has
    /// just landed took with it.
    public var visibleAttempts: [Game.Ply.Tried] {
        switch wrongsAt {
        case .pending: return pendingAttempts
        case .ply(let index): return game.plies[index].tried
        case .nothing: return []
        }
    }

    /// One wrong move at the position on the board, as the strip lists it: a 试招 把关 took
    /// back, or the move that stood there too expensively. Two kinds under one chip, because an
    /// imported game has only the second — nothing was ever refused in it — and its 错招 want the
    /// same chip and the same 应招 as a refusal's (docs/adr/0034, 0036).
    public struct WrongMove: Hashable, Sendable {
        public enum Source: Hashable, Sendable {
            /// Which of `visibleAttempts`.
            case tried(Int)
            /// The move that stood, at the Ply it took, counting from one.
            case stood(ply: Int)
        }

        public let source: Source
        public let san: String
        /// What it cost, in percentage points of win probability (docs/adr/0027).
        public let drop: Double
        /// The Depth it was judged at, when one was written down.
        public let depth: Int?
        /// The 应招 kept for it: a 试招's own, or the Review's Line from the position the move
        /// that stood made. Empty when nothing was written down, and then asked for
        /// (`reply(for:)`).
        public let line: [String]

        public init(source: Source, san: String, drop: Double, depth: Int?, line: [String]) {
            self.source = source
            self.san = san
            self.drop = drop
            self.depth = depth
            self.line = Array(line.prefix(Reply.limit))
        }

        init(_ tried: Game.Ply.Tried, at index: Int) {
            self.init(
                source: .tried(index), san: tried.san, drop: tried.drop, depth: tried.depth,
                line: tried.line
            )
        }

        /// True for the move that stood, rather than one taken back.
        public var stood: Bool {
            if case .stood = source { return true }
            return false
        }

        /// Which of `visibleAttempts` this is, for a 试招.
        public var triedIndex: Int? {
            if case .tried(let index) = source { return index }
            return nil
        }
    }

    /// Every wrong move at the position being read, oldest first: the 试招 in the order they were
    /// refused, then the move that finally stood if it was too expensive too — the list a 错题
    /// tile counts (`Slip.wrong`), for the position the board is on. The move that stood is
    /// listed only at its own position: at the position after it, the badge already says what
    /// it cost.
    public var visibleWrongs: [WrongMove] {
        var wrongs = visibleAttempts.enumerated().map { WrongMove($1, at: $0) }
        switch wrongsAt {
        case .pending:
            if let stood = stoodWrong(atPly: cursor) { wrongs.append(stood) }
        case .ply(let index) where index == cursor:
            if let stood = stoodWrong(atPly: cursor) { wrongs.append(stood) }
        default:
            break
        }
        return wrongs
    }

    /// The move that stood at `index` of `plies`, when it was the player's own and cost at or
    /// over the 记录线 — the 错招 an imported game is made of, since nothing was refused in it.
    /// By the same rule the 错题 tiles use (`slips`), so the chip and the tile never disagree
    /// about whether a move was wrong.
    private func stoodWrong(atPly index: Int) -> WrongMove? {
        guard game.plies.indices.contains(index), let slip = slipByPosition[index],
            let wrong = slip.wrong.first(where: { !$0.wasTried })
        else { return nil }
        return WrongMove(
            source: .stood(ply: index + 1), san: wrong.san, drop: wrong.drop,
            depth: game.plies[index].judgement?.depth ?? game.reviewDepth,
            line: game.reviewLine(atPly: index + 1)
        )
    }

    /// The position the wrong moves on show were played in — the one their 应招 is drawn from.
    ///
    /// The same branch `visibleAttempts` takes, because they are one question: the moves belong
    /// to a position, and this is it. Nil only when there is nothing to show.
    public var refusedPosition: Game? {
        switch wrongsAt {
        case .pending: return viewed
        case .ply(let index): return index == cursor ? viewed : game.rewound(to: index)
        case .nothing: return nil
        }
    }

    /// The position a 试招 made. It is the one its 应招 comes back from, and the one the board no
    /// longer shows, because 把关 has already taken the move back.
    public func position(after tried: Game.Ply.Tried) -> Game? {
        position(afterPlaying: tried.san)
    }

    /// The same for any wrong move on the strip — for one that stood, the position the game
    /// went on from.
    public func position(after wrong: WrongMove) -> Game? {
        position(afterPlaying: wrong.san)
    }

    private func position(afterPlaying san: String) -> Game? {
        guard var played = refusedPosition,
            let move = SAN.move(for: san, in: played.state),
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
        await reply(kept: tried.line, afterPlaying: tried.san)
    }

    /// The same door for any wrong move on the strip: a move that stood in a reviewed game
    /// carries the Review's Line, and one in a game nobody reviewed asks the same search.
    public func reply(for wrong: WrongMove) async -> [String] {
        await reply(kept: wrong.line, afterPlaying: wrong.san)
    }

    private func reply(kept line: [String], afterPlaying san: String) async -> [String] {
        if !line.isEmpty { return line }
        guard let engine, let played = position(afterPlaying: san) else { return [] }
        let result = await engine.positionResult(played)
        guard !Task.isCancelled else { return [] }
        return Array((result?.best?.san ?? []).prefix(Reply.limit))
    }

    /// A 应招 being read on the strip: which 试招, the line it makes, and how far the board can
    /// draw it (docs/adr/0034).
    ///
    /// The screen used to keep this as four pieces of view state — which chip is on, the answer,
    /// whether it was still being asked for, and the task asking — and derive the line, the
    /// arrows and the chips from them on every draw. A reading is one value: opened by a tap,
    /// filled in when the answer arrives, and closed by the next tap or by the board moving on.
    public struct ReplyReading: Equatable, Sendable {
        /// One numbered step of the line, as the chips under the board say it.
        public struct Step: Hashable, Sendable {
            public let step: Int
            public let san: String
            public let isYours: Bool
        }

        /// Which of `visibleWrongs` is open.
        public let index: Int
        public let move: WrongMove
        /// The position the move was played in, which the arrows are walked from.
        public let position: Game
        /// The 试招 followed by its 应招. Empty until there is an answer: one arrow for a move
        /// that was taken back is a picture of the mistake with the lesson left out.
        public internal(set) var line: [String]
        /// Whether the answer is still being asked for.
        public internal(set) var isAsking: Bool

        /// The line as numbered arrows from the position the move was refused in.
        public var arrows: [MoveArrow] { Reply.arrows(in: position, playing: line) }

        /// The arrows as chips, numbered the same way. Read off the arrows rather than off the
        /// line, so the two cannot disagree about how far the walk got or whose move a step is.
        public var steps: [Step] {
            arrows.compactMap { arrow in
                guard line.indices.contains(arrow.step - 1) else { return nil }
                return Step(step: arrow.step, san: line[arrow.step - 1], isYours: arrow.isYours)
            }
        }
    }

    /// The 应招 open on the strip, if one is (`readReply(at:)`).
    public private(set) var replyReading: ReplyReading?
    private var replyTask: Task<Void, Never>?

    /// Reads the 应招 of a 试招 on the strip, or puts it away again if it is the one open.
    ///
    /// A move that carries its answer is read at once; one refused before replies were written
    /// down asks the shared bounded search and is filled in when the answer comes. Shut while a
    /// 惩罚 exercise is open: that exercise is the same answer with the finding left to the
    /// player, and a reading that would hand it over is the exercise not being one.
    public func readReply(at index: Int) {
        if replyReading?.index == index {
            closeReply()
            return
        }
        let wrongs = visibleWrongs
        guard activePunishment == nil, wrongs.indices.contains(index),
            let position = refusedPosition
        else { return }
        closeReply()
        let wrong = wrongs[index]
        let hasAnswer = !wrong.line.isEmpty
        replyReading = ReplyReading(
            index: index, move: wrong, position: position,
            line: hasAnswer ? Reply.moves(of: wrong) : [], isAsking: !hasAnswer
        )
        guard !hasAnswer else { return }
        replyTask = Task { [weak self] in
            guard let self else { return }
            let answer = await reply(for: wrong)
            guard !Task.isCancelled, replyReading?.index == index, replyReading?.move == wrong
            else { return }
            replyReading?.isAsking = false
            replyReading?.line = answer.isEmpty ? [] : Reply.moves(of: wrong, reply: answer)
        }
    }

    /// Puts the 应招 away. A question asked once is not a layer left on: the board goes back to
    /// the position and says nothing about what the player might have tried.
    private func closeReply() {
        replyTask?.cancel()
        replyTask = nil
        replyReading = nil
    }

    // ------------------------------------------------------------------ 复判

    /// A 复判 under way: which 试招 on the strip is being judged again, and how deep both ends
    /// have got (CONTEXT.md, 复判; docs/adr/0041).
    public struct Rejudging: Equatable, Sendable {
        /// Which of `visibleWrongs`.
        public let index: Int
        public let tried: Game.Ply.Tried
        /// The shallower of the two ends so far — zero before either has said anything.
        public internal(set) var depth: Int
    }

    public private(set) var rejudging: Rejudging?
    private var rejudgeTask: Task<Void, Never>?

    /// What the strip may offer for one 试招.
    public enum RejudgeOffer: Equatable, Sendable {
        /// Nothing: the move is already judged as deep as a 复判 goes, or there is no engine.
        case none
        /// The button, greyed: the engine is spoken for — a move being weighed or walked, the
        /// position's own search still running, a 复判 already going, the engine paused.
        case waiting
        case ready
    }

    /// The 试招 at `index` of `visibleWrongs`, when that is what it is. A move that stood is
    /// judged by the game it stands in, and a 复判 is for a move that was taken back.
    private func triedToRejudge(at index: Int) -> (tried: Game.Ply.Tried, at: Int)? {
        let wrongs = visibleWrongs
        guard wrongs.indices.contains(index), let at = wrongs[index].triedIndex,
            visibleAttempts.indices.contains(at)
        else { return nil }
        return (visibleAttempts[at], at)
    }

    public func rejudgeOffer(at index: Int) -> RejudgeOffer {
        guard let engine, let found = triedToRejudge(at: index) else { return .none }
        if (found.tried.depth ?? 0) >= PositionSearches.deeperDepth { return .none }
        if rejudging != nil || isOccupied || isThinking || isSearching || engine.isPaused {
            return .waiting
        }
        return .ready
    }

    /// Judges one 试招 again, deeper: both ends of the move to `PositionSearches.deeperDepth`,
    /// and the move's 掉幅, 应招 and depth rewritten in place when both have finished. The refusal
    /// itself is not touched, and neither is the move that stood in the same position. Cancelled,
    /// with nothing written, by a move being played, the eye moving on, or the session going away.
    public func rejudge(at index: Int) {
        guard rejudgeOffer(at: index) == .ready, let engine,
            let before = refusedPosition, let tried = triedToRejudge(at: index)?.tried
        else { return }
        guard let played = position(after: tried) else { return }
        rejudging = Rejudging(index: index, tried: tried, depth: 0)
        rejudgeTask = Task { [weak self] in
            guard let self else { return }
            // The same 细判 as the one that refused the move, at the deeper budget: one act, so
            // the depth the number is worth and the 应招 beside it are read by the one rule.
            let weighed = await engine.weigh(played, from: before, budget: PositionSearches.deeper) {
                rejudging?.depth = $0.depth
            }
            guard !Task.isCancelled else { return }
            finishRejudge(
                weighed.map {
                    .init(san: tried.san, drop: $0.drop, notFound: tried.notFound, depth: $0.depth, line: $0.reply)
                },
                at: index
            )
        }
    }

    /// Writes the deeper number where the 试招 is — pending at the position, or on the move that
    /// carried it — and brings an open reading of it up to date. Nothing is written when the
    /// game has moved on from under it.
    private func finishRejudge(_ deeper: Game.Ply.Tried?, at index: Int) {
        defer {
            rejudgeTask = nil
            rejudging = nil
        }
        guard let deeper, let was = rejudging?.tried, let found = triedToRejudge(at: index),
            found.tried == was
        else { return }
        let at = found.at
        var attempts = visibleAttempts
        attempts[at] = deeper
        switch wrongsAt {
        case .pending: game.setPendingTried(attempts, atPly: cursor)
        case .ply(let ply): game.setTried(attempts, hints: game.plies[ply].hints, atPly: ply)
        case .nothing: return
        }
        if let reading = replyReading, reading.index == index, reading.move == WrongMove(was, at: at) {
            replyReading = ReplyReading(
                index: index, move: WrongMove(deeper, at: at), position: reading.position,
                line: Reply.moves(of: deeper), isAsking: false
            )
        }
        save()
    }

    private func cancelRejudge() {
        rejudgeTask?.cancel()
        rejudgeTask = nil
        rejudging = nil
    }

    public var isFaceToFace = false

    private var measuredMove: (moves: [String], fen: String, change: MoveChange)?
    /// The game as it stood when a move last landed through `commit` with no judgement on it —
    /// the one move `measureLatestMoveChange` is owed a judgement for. A move that was already
    /// in the file when the game was opened keeps whatever it has: filling those in is the
    /// explicit migration (`fillMissingNoSlipsJudgements`), never something a screen starts.
    private var landedUnjudged: (moves: [String], fen: String)?

    /// Only a newly played move gets a change badge; navigating the record is not a move.
    public var moveChange: MoveChange? {
        guard isAtLatest, !isWeighing, measuredMove?.moves == game.uciMoves,
              measuredMove?.fen == game.state.fen else { return nil }
        return measuredMove?.change
    }

    /// What the bar shows, by one priority: where the move just played landed, then the position
    /// on screen, then the standing Analysis.
    public var feedbackScore: Score? {
        moveChange?.after ?? noSlipsScore ?? analysis?.best?.score
    }

    /// The app's number for the position after `ply` moves — what the curve draws — by one
    /// priority: what the 细判 wrote onto the move, then what the badge's weighing found at
    /// either end of the last move (which a move that came from the file without a judgement
    /// has nothing else for), then what a Review wrote (docs/adr/0016). The record first,
    /// because the badge is written from the same weighing as the record and never disagrees
    /// with it. The live search of the position on screen does not enter here: reading an older
    /// move is reading history, and the live number belongs to `noSlipsScore`.
    public func historyScore(atPly ply: Int) -> Score? {
        guard (0...game.plies.count).contains(ply) else { return nil }
        if ply > 0, let judgement = game.plies[ply - 1].judgement {
            return judgement.score
        }
        if let measuredMove, measuredMove.moves == game.uciMoves, measuredMove.fen == game.state.fen {
            if ply == game.plies.count { return measuredMove.change.after }
            if ply == game.plies.count - 1 { return measuredMove.change.before }
        }
        return game.reviewScore(atPly: ply)
    }

    /// The personal side stays personal when the board is flipped. With two manual sides,
    /// the bottom side supplies the perspective, just as it does for the bar.
    private var feedbackColour: PieceColour {
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
            if change.isBest { return .best }
            let value = change.percent(for: feedbackColour)
            return .change((value * 10).rounded() / 10)
        }
        return .quiet
    }

    /// The strip under the board, whole (`Strip`, docs/adr/0020): the voice, the tally, the depth
    /// to account for and the bar, each from the facts this session already holds.
    public var strip: Strip {
        let finish = viewed.finish
        let bar = Strip.Bar(score: feedbackScore, finish: finish)
        let tally = noSlips
        // A search to account for is one that has got somewhere, or one that is running and has
        // not yet: zero is "in flight, nothing said", and is never said of a board nothing is
        // searching — a session with no engine used to read 深度 0 for as long as it was open.
        let reached = searchProgress?.depth ?? 0
        let accountsForASearch = phase != .exercising && finish == nil && (reached > 0 || isSearching)
        return Strip(
            voice: standing,
            tally: isNoSlipsOn || tally.longestRun > 0 ? tally : nil,
            depth: accountsForASearch ? reached : nil,
            bar: bar
        )
    }

    private var isLatestMoveMeasured: Bool {
        measuredMove?.moves == game.uciMoves && measuredMove?.fen == game.state.fen
    }

    /// Badges the move just played if nothing has yet: the session asks for this itself every
    /// time it retunes, so a move that landed by any door — a hand, the engine, a held button —
    /// gets its number without a screen having to remember to ask for it.
    private func measureLatestMove() {
        guard !isWeighing, !game.plies.isEmpty, engine != nil, !isLatestMoveMeasured else { return }
        measuring = Task { [weak self] in await self?.measureLatestMoveChange() }
    }

    /// The one door a move's judgement comes through when it did not come through a ruling:
    /// the same 细判 that rules under 把关, run on the move just played, and its answer written
    /// twice from the one Weighing — onto the move, as its judgement, and into the badge, as the
    /// change. A move that already carries a judgement (it stood under a ruling, or came from a
    /// file) keeps it, and the badge is read from that rather than searched for again; a move
    /// that came from the file without one gets the badge and nothing written.
    /// Missing or cancelled analysis never becomes a fictitious zero-percent move.
    public func measureLatestMoveChange() async {
        guard !isWeighing, !game.plies.isEmpty, !isLatestMoveMeasured, let engine else { return }
        let after = game
        let last = after.plies.count - 1
        if let judgement = after.plies[last].judgement {
            if let before = historyScore(atPly: last) {
                measuredMove = (
                    after.uciMoves, after.state.fen,
                    MoveChange(before: before, after: judgement.score, isBest: judgement.best)
                )
            }
            return
        }
        guard let before = after.rewound(to: last) else { return }
        let weighed = await engine.weigh(after, from: before)
        guard !Task.isCancelled, !isWeighing, let weighed,
              game.uciMoves == after.uciMoves, game.startFEN == after.startFEN else { return }
        if game.plies[last].judgement == nil, let landed = landedUnjudged,
           landed.moves == after.uciMoves, landed.fen == after.state.fen {
            game.setJudgement(weighed.judgement, atPly: last)
            landedUnjudged = nil
            save()
        }
        measuredMove = (
            after.uciMoves, after.state.fen,
            MoveChange(before: weighed.scoreBefore, after: weighed.after, isBest: weighed.isBest)
        )
    }

    /// Explicit legacy migration only; never started automatically by the game screen.
    public func fillMissingNoSlipsJudgements() async {
        guard !isOccupied, let engine else { return }
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
            guard !isOccupied else { return }
            guard game.uciMoves.prefix(index + 1).elementsEqual(original.uciMoves.prefix(index + 1)) else { return }
            if game.plies[index].judgement == nil {
                game.setJudgement(weighed.judgement, atPly: index)
                save()
            }
        }
    }
    /// What a move that lands through `commit` takes with it: the refusals made where it was
    /// played from, as its 试招 (`Game.absorbPendingTried`, docs/adr/0037).
    ///
    /// Nothing is judged here. Every move that lands is weighed by the one 细判 — the engine's
    /// own move, a move played with 把关 off, a move asked of the engine — and its judgement is
    /// written from that weighing in `measureLatestMoveChange`, the same act the badge reads. A
    /// judgement read off the before-table alone used to be written here, and it was a seventh
    /// copy of the 细判 that disagreed with the badge about 最佳 (CONTEXT.md, 细判).
    private func absorbRefusals(atPly ply: Int) {
        game.absorbPendingTried(atPly: ply)
    }

    private var interceptTable: (fen: String, analysis: Analysis)?

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

    /// The move that led to the position on screen.
    public var lastMove: MoveSquares? { game.moveSquares(atPly: cursor) }

    public func step(by delta: Int) {
        guard canBrowse else { return }
        let wanted = min(max(0, cursor + delta), game.plies.count)
        guard wanted != cursor else { return }
        cursor = wanted
        adoptViewedAnalysis()
        emit(.stepped)
        retune()
    }

    public func jumpToLatest() {
        guard canBrowse else { return }
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
        guard canBrowse else { return }
        guard cursor != 0 else { return }
        cursor = 0
        adoptViewedAnalysis()
        emit(.stepped)
        retune()
    }

    /// Straight to a named Ply. Zero is the position the Game began in.
    public func jump(toPly ply: Int) {
        guard canBrowse else { return }
        let wanted = min(max(0, ply), game.plies.count)
        guard wanted != cursor else { return }
        cursor = wanted
        adoptViewedAnalysis()
        emit(.stepped)
        retune()
    }

    // ------------------------------------------------------------ the branches

    /// The lines that were played from the position on screen instead of the move that
    /// follows it (docs/adr/0043).
    public var variationsHere: [[Game.Ply]] { game.variations(atPly: cursor) }

    /// The Ply whose siblings the record can cycle, if the eye is on a fork: the one just
    /// played, else the one about to be.
    public var forkPly: Int? {
        if cursor > 0, game.siblings(atPly: cursor - 1).count > 1 { return cursor - 1 }
        if cursor < game.plies.count, game.siblings(atPly: cursor).count > 1 { return cursor }
        return nil
    }

    /// Swipes the record onto the next (or previous) sibling at the fork the eye is on. The
    /// strip stays one line; the tree is what the swipe walks.
    public func cycleFork(by delta: Int) {
        guard let ply = forkPly else { return }
        cycleFork(atPly: ply, by: delta, keepStanding: true)
    }

    /// Cycles the siblings of a named Ply. A tap on that Ply's rail names it; a swipe on the
    /// strip uses whichever fork the eye is already on, and tries not to jump the cursor.
    ///
    /// Browsing, like a step: the game is the same tree afterwards with a different line on
    /// the board, and nothing is judged. Not while a move is being weighed or a drill is on —
    /// the same gate every other walk through the game has.
    public func cycleFork(atPly ply: Int, by delta: Int, keepStanding: Bool = false) {
        guard canBrowse, delta != 0 else { return }
        let siblings = game.siblings(atPly: ply)
        guard siblings.count > 1 else { return }
        let current = siblings.firstIndex { $0.variationIndex == nil } ?? 0
        let count = siblings.count
        let next = siblings[((current + delta) % count + count) % count]
        guard let index = next.variationIndex else { return }
        let standing = cursor
        guard game.promoteVariation(index, atPly: ply) else { return }
        cursor = keepStanding ? (standing <= ply ? ply : ply + 1) : ply + 1
        adoptViewedAnalysis()
        emit(.stepped)
        save()
        retune()
    }

    // ------------------------------------------------------- walking to a mistake

    /// A Ply this session was asked to walk to when its screen arrives, if any.
    private var arrivalWalk: Int?

    /// Whether the record is being walked forward right now. The board is not the player's while
    /// it is: a tap landing halfway through a fast-forward plays a move from a position that is on
    /// its way off the screen.
    public var isWalkingRecord: Bool {
        if case .walking = activity { true } else { false }
    }

    /// Asks for the record to be walked to `ply` when the screen arrives, rather than cut to it.
    ///
    /// Opening a game from the 错题本 is opening it *at* a mistake, and the game is the story of how
    /// the player got there. Cutting to the Ply shows the position and nothing about the journey;
    /// walking shows the moves landing one after another, which is what the record strip has been
    /// scrolling through either way.
    public func walkOnArrival(toPly ply: Int) {
        guard !isOccupied else { return }
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
        guard canBrowse else { return }
        let wanted = min(max(0, ply), game.plies.count)
        guard wanted != cursor else { return }
        guard wanted > cursor else {
            jump(toPly: wanted)
            return
        }
        // A move the engine was walking is ended rather than left running under the walk: the
        // board is on its way somewhere, and the retune where it stops starts what is wanted there.
        if isThinking { stopSearching() }
        activity = .walking
        while cursor < wanted, !Task.isCancelled {
            cursor += 1
            adoptViewedAnalysis()
            try? await Task.sleep(for: step)
        }
        // Whatever happened to the task, the walk is over; a session suspended meanwhile has
        // already said so, and is left as it put itself.
        if isWalkingRecord { activity = .reading }
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
        let slips = game.slips(by: mine, lines: lines)
        storedSlips = (key, slips)
        return slips
    }

    /// The 错招 by the *position* they were made at, which is what the record strip's cells are:
    /// a cell's cursor is the position it takes the board to, so a mistake at Ply `n` is marked on
    /// the cell at `n - 1` (docs/adr/0036). Zero is the opening cell.
    public var slipByPosition: [Int: Slip] {
        Dictionary(slips.map { ($0.positionPly, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The record's Scores, one level per position, for the curve under the strip: the same
    /// numbers `historyScore` gives one at a time, as one value with the rule for whether there
    /// is a curve to draw.
    public var curve: ScoreCurve {
        ScoreCurve(scores: (0...game.plies.count).map { historyScore(atPly: $0) })
    }

    /// 连正 for the sides the player is moving, read out of the game (CONTEXT.md).
    public var noSlips: Game.NoSlips { game.noSlips(by: mine) }

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
        phase != .weighing && isAtLatest && !game.isOver && controller(for: viewed.state.sideToMove) == .engine
    }

    /// Whether a person may move on the board as it is being looked at. True in the past as
    /// well as the present: playing from an earlier position is how a 分支 is made
    /// (docs/adr/0043) — what followed stays beside the new move, and the game carries on down it.
    public var isHandTurn: Bool {
        switch phase {
        case .exercising: return activePunishment?.isJudging == false
        case .weighing, .walking: return false
        case .reading, .thinking: break
        }
        guard !viewed.isOver else { return false }
        if !isAtLatest { return true }
        return controller(for: viewed.state.sideToMove) == .hand
    }

    /// Who is putting a move down. The three ways in differ by whose move it is — which decides
    /// whether 把关 weighs it and whether a rung is written on it.
    private enum Mover {
        /// A person, on their own turn.
        case hand
        /// The engine, asked for one move by a held button. Weighed like a hand move where 把关
        /// is on, and no rung is written on it: it was played for the player, not against them.
        case asked
        /// The engine's own Controller. Lands only at the latest position, with the rung it was
        /// found at (docs/adr/0038).
        case engine
    }

    /// A move made by a person.
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
        // 把关 measures a move before it is allowed to stand, wherever it is played. It used to
        // measure only a move played at the end of the game — "a move played back down the game is
        // somebody taking one back" — and a saved game reopens at its *first* position, so playing
        // the first move again was the one move 把关 never looked at. It looked exactly like 把关
        // being switched off while switched on.
        // A move nobody can weigh — no engine attached, or a game that is over — lands as it is.
        guard engine != nil, !viewed.isOver else {
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
            emit(.refused)
            return
        }
        stopSearching()
        let standpoint = Standpoint(game: game, cursor: cursor)
        // What the board and the record show while the engine thinks: the move in the game it
        // was played in, with the line it was played over kept beside it as a 分支
        // (docs/adr/0043) — the shape the ruling lands if the move stands, so nothing on the
        // strip disappears and comes back. `played` is the prefix the engine weighs.
        var shown = game
        guard shown.play(move, atPly: cursor) else {
            emit(.refused)
            return
        }
        game = shown
        cursor += 1
        analysis = nil
        refused = nil
        emit(.landed(move, outcome: game.state.outcome))
        beginWeighing(from: standpoint, task: Task { [weak self] in
            await self?.settle(move, san: landed.san, from: position, to: played)
        })
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
        let weighed = await engine.weigh(played, from: position) { noteProgress($0.snapshot) }
        guard !Task.isCancelled else { return }
        if let weighed { interceptTable = (position.state.fen, weighed.before) }
        // What to put back when the move does not stand is the 原局 `weigh` kept: the game as it
        // was being read, whole, and the eye where it was. `position` is only the position the
        // move was played from, which is a prefix of that game when it was played from an earlier
        // Ply. A session that was suspended meanwhile has put the 原局 back itself.
        guard let standpoint else { return }
        let ruling = Ruling(weighed, san: san, played: played, from: standpoint, lines: lines)
        // The move comes off the board, and it is given its beat to be seen there first — while
        // the session still counts as weighing, so a second tap cannot land on a board that is
        // halfway through taking one back.
        if ruling.takesTheMoveBack { await holdTheMoveOnTheBoard() }
        guard !Task.isCancelled else { return }
        endWeighing()
        land(ruling, played: played, engine: engine)
    }

    /// Puts a ruling into effect. The game and the eye go where it says; what is the session's
    /// own is the rest — the noise, the save, the badge, the exercise, the next search. A refusal
    /// gets no retune: the engine is not owed a reply to a move that came back.
    private func land(_ ruling: Ruling, played: Game, engine: any Engine) {
        game = ruling.game
        cursor = ruling.cursor
        switch ruling.verdict {
        case .unjudged:
            retune()
        case .stands(let change):
            if let change { measuredMove = (game.uciMoves, game.state.fen, change) }
            save()
            answerFromTheRecord()
            retune()
        case .refused(let refusal):
            // Written down by the ruling at the position it happened at, rather than when a move
            // finally stands, because a player who is refused and then walks away has played no
            // such move — and the refusal used to go with them (docs/adr/0037).
            refused = refusal
            save()
            emit(.refused)
            if findsPunishment { exercise(Punishment(position: played, engine: engine)) }
        }
    }

    /// The one way a move lands: the write, the cursor, the noise, the save, the retune. The
    /// three public paths differ only in who is moving, and having them each hand-roll this is
    /// how one of them eventually forgets a line of it.
    private func commit(_ move: Move, by mover: Mover) {
        guard !isWeighing else { return }
        // A move played is the game moving on: a 复判 of a 试招 here yields to it, unwritten.
        cancelRejudge()
        if let practice, !practice.isSettled {
            guard isAtLatest, game.state.fen == practice.game.state.fen else { return }
            stopSearching()
            if mover != .hand { notePracticeHelp() }
            practice.play(move)
            guard practice.isJudging else { return }
            game = practice.game
            cursor = game.plies.count
            analysis = nil
            emit(.landed(move, outcome: game.state.outcome))
            beginWeighing(from: nil, task: Task { [weak self] in
                await practice.settled()
                guard let self, !Task.isCancelled else { return }
                endWeighing()
                // The drill rules its own attempt, under its own 线, and its refusal goes through
                // the same door as 把关's: into the Game, at the position it happened at
                // (docs/adr/0037). A drill that could not be judged is a move that stands unmeasured.
                guard let ruling = practice.ruling, let engine else {
                    game = practice.game
                    cursor = game.plies.count
                    save()
                    retune()
                    return
                }
                land(ruling, played: practice.game, engine: engine)
            })
            return
        }
        if mover == .asked, isAtLatest {
            weigh(move)
            return
        }
        // A move played over an earlier one: what used to follow becomes a 分支 (docs/adr/0043),
        // and a line forking is worth its own noise. Computed before the play, which is what the
        // comparison is against. The engine's own moves always land at the latest position, so
        // this is only ever a hand or asked concern.
        let branching = mover != .engine && !isAtLatest && game.plies[cursor].uci != move.uci
        if mover == .engine {
            // Played only at the latest position: it was found for the position its search
            // started from, and applying it anywhere else would be a different move.
            guard isAtLatest, game.apply(move) else { return }
            cursor = game.plies.count
            // With the rung it was found at, 满力 included: the record of a game against the
            // engine says what the engine was (docs/adr/0038).
            game.setStrength(strength, atPly: game.plies.count - 1)
        } else {
            guard game.play(move, atPly: cursor) else {
                emit(.refused)
                return
            }
            cursor += 1
        }
        emit(.landed(move, outcome: viewed.state.outcome))
        if branching { emit(.forked) }
        // The invariant: the Analysis that described the position before this move is stale,
        // the game is written to its file, and the engine is asked what it makes of the new
        // position — whoever moved.
        analysis = nil
        absorbRefusals(atPly: cursor - 1)
        landedUnjudged = (game.uciMoves, game.state.fen)
        refused = nil
        save()
        answerFromTheRecord()
        retune()
    }

    /// The opponent's reply, when the move just played already had one on the record.
    ///
    /// Going back and playing the move that is standing there carries on down the line that
    /// exists (`Game.play(_:atPly:)`) rather than branching — which leaves the eye in the middle
    /// of the record with the engine's seat to move. The engine only *plays* from the latest
    /// position (`isEngineTurn`), because browsing onto its turn must not move anything; so
    /// nobody answered, and a game set to play the engine sat there as if it were not. The answer
    /// is already written down: the reply that was made to this move from this position. It is
    /// played off the record, the way a walk plays one — no search, no 分支, and the line the
    /// player is replaying stays the line. A move that is *not* the one on the record branches,
    /// lands at the latest position, and gets a fresh reply the ordinary way.
    private func answerFromTheRecord() {
        guard !isAtLatest, controller(for: viewed.state.sideToMove) == .engine else { return }
        cursor += 1
        adoptViewedAnalysis()
        emit(.stepped)
    }

    // ------------------------------------------------------------------ a study


    // ----------------------------------------------------------------- point at a square

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
        engine != nil && !viewed.isOver && !isEngineTurn && !isOccupied
    }

    /// Starts the engine thinking about a move it will play when it is let go.
    ///
    /// Held time *is* thinking time: the move is never bound to a rung, so the only thing that
    /// shapes how well it plays is how long it is left alone — and here that is a thumb on a
    /// button. A tap is a snap answer, two seconds is a considered one, and neither is the app
    /// deciding.
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
        guard think(.asked) else { return }
        stopSearching()
        searchProgress = nil
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
        stopThinking()
        isAskReleased = false
        let uci = askedBest
        askedBest = nil
        guard let uci, let move = position.state.move(matching: uci) else { return }
        playAsked(move)
    }

    /// A move the engine was asked for. Like a hand move in every way but one: it is not the
    /// engine's own, so no rung is written on it.
    private func playAsked(_ move: Move) {
        commit(move, by: .asked)
    }

    /// Takes the last move of the game off. Only from the latest position: in the middle of a
    /// game, going backwards is browsing, and deleting is not what a back button means.
    public func undo() {
        guard !isOccupied else { return }
        guard isAtLatest, !game.plies.isEmpty else { return }
        stopSearching()
        game.undo()
        emit(.stepped)
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
        guard !isOccupied else { return }
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
        stopThinking()
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
        guard !isOccupied else { return }
        restoreRefusalForViewedPosition()
        stopSearching()
        measureLatestMove()
        stopThinking()
        thinkingBest = nil

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
            guard think(.own) else { return }
            // No clock of its own (docs/adr/0039): the engine's move is bounded the way every
            // live position search is, and a rung is the one dial on how well it plays.
            let strength = strength
            searchTask = Task { [weak self] in
                var last: Analysis?
                // At 满力 the engine's move is the shared bounded search every other reader of
                // this position joins. At a rung it is a search of its own, bound to that rung and
                // shared with nothing: a bound answer is the opponent's and must not become the
                // number a hint or a judgement reads for this position (docs/adr/0038). One line
                // either way: the engine is choosing a move, not advising, and each extra line
                // roughly doubles the time to the same Depth — a weaker move on the same clock.
                let search = strength == .full
                    ? engine.analysePosition(position)
                    : engine.analyse(position, budget: PositionSearches.budget, lines: 1, strength: strength)
                for await snapshot in search {
                    if Task.isCancelled { return }
                    if strength == .full { self?.record(snapshot) } else { self?.noteProgress(snapshot) }
                    self?.thinkingBest = snapshot.bestMove
                    last = snapshot
                }
                guard let self, !Task.isCancelled else { return }
                stopThinking()
                if let uci = last?.bestMove, let move = position.state.move(matching: uci) {
                    playByEngine(move)
                }
            }
        } else {
            // The one search the board itself starts: the position in front of the player, for
            // 把关 and the badge to read. The engine's opinion of it is not shown, and no search
            // whose only product is advice is started for the board (docs/adr/0040); a card
            // that asks gets one (`adviseForCard`).
            prepareInterception(on: position, using: engine)
        }
    }

    /// A card's Stint: the same bounded position search every live reader joins, with its
    /// opinion kept for the card (docs/adr/0020, 0040) — and, since it is the same search, the
    /// badge's table filled from it too, so a card that took the search over owes the board nothing.
    private func advise(on position: Game, using engine: any Engine) {
        guard dealsCards, !isWeighing else { return }
        isAdviceSpent = false
        searchProgress = nil
        interceptTable = nil
        searchTask = Task { [weak self] in
            for await snapshot in engine.analysePosition(position) {
                guard !Task.isCancelled, let self else { return }
                record(snapshot)
                if !snapshot.isPartial { interceptTable = (position.state.fen, snapshot) }
            }
            guard !Task.isCancelled else { return }
            self?.searchTask = nil
            self?.isAdviceSpent = true
        }
    }

    /// A Stint spent because a card arrived. Runs during Practice too: the swipe is the asking,
    /// and the board stays silent. A move the engine is walking, a plan's own look-ahead, and a
    /// Review in flight keep the engine — those are not advice, and a swipe must not take them
    /// off the clock.
    public func adviseForCard() {
        guard dealsCards, !isWeighing else { return }
        if let url, library?.reviewingURLs.contains(url) == true { return }
        guard let engine, !viewed.isOver, !engine.isPaused else { return }
        guard thinking == nil else { return }
        if recallCachedAnalysis() {
            if searchTask == nil { isAdviceSpent = true }
            return
        }
        // The board may already be searching this position for the badge (`prepareInterception`),
        // or a probe may be. A card dealt while that runs is a card at rest: nothing is taken over,
        // and the card asks again when the board is quiet. A card that asks once the shared search
        // has finished is answered out of its cache without a second search (`PositionSearches`).
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
        stopThinking()
        if let uci = thinkingBest, let move = position.state.move(matching: uci) {
            playByEngine(move)
        }
        thinkingBest = nil
    }

    /// A move the engine played for itself, under its own Controller.
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
        if case .weighing(let standpoint, let task) = activity {
            task.cancel()
            // A move nobody finished weighing is put back the way a ruling puts it back: the
            // 原局, whole, with nothing written (docs/adr/0035). The same code the ruling runs,
            // so the two cannot drift.
            if let standpoint {
                let ruling = Ruling.unjudged(standpoint)
                game = ruling.game
                cursor = ruling.cursor
            }
        }
        stopSearching()
        closeReply()
        cancelRejudge()
        // Whatever it was, it is over: the task is cancelled, the exercise skipped, the search
        // taken down. One assignment, because the activity owns what each of those kept.
        activity = .reading
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
        // A move being walked is not advice, and that search's opinion is dropped rather than
        // merely hidden — the game's plies stay unmarked and the Review has nothing to disagree
        // with. A card's Stint is the other case: the swipe asked, so the Line is kept for the
        // card even while the board stays silent (docs/adr/0040).
        if thinking != nil { return }
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

    /// The file this game is: the Game and the facts about it, each in its tag (`PGN`). This
    /// session names no tag; what it holds is the facts.
    public var pgn: PGN {
        PGN(
            game: game, seats: controllers, origin: origin, lines: lines, carrying: tags
        )
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
