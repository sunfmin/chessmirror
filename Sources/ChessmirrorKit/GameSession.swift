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
    /// Begun as a 错题, in practice (docs/adr/0047). A real game — it is played on from, it is
    /// judged, and its 试招 fill the book like any other's — and one the player did not sit down
    /// to play, so the list keeps it apart from the ones they did.
    case practised

    /// Written into the PGN so the distinction survives a relaunch. Not a standard tag;
    /// PGN has no opinion about where a position came from, and readers ignore what they do
    /// not know.
    public static let tagName = PGN.Tags.source

    public var tagValue: String { rawValue }
    public var label: String {
        switch self {
        case .fresh: localized("origin.fresh")
        case .recognised: localized("origin.recognised")
        case .imported: localized("origin.imported")
        case .practised: localized("origin.practised")
        }
    }
    public var symbol: String {
        switch self {
        case .fresh: "square.grid.3x3"
        case .recognised: "camera"
        case .imported: "link"
        case .practised: "figure.mind.and.body"
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

    public internal(set) var game: Game {
        didSet {
            storedViewed = nil
            // The 错题 list is walked out of the Game, and a refusal is written into it without
            // touching a single move — so a cache keyed on the moves alone would go on saying the
            // game had nothing wrong in it while the row under the board showed otherwise.
            storedReading = nil
        }
    }
    public var orientation: Orientation
    /// Which ply the player is looking at: 0 is the starting position, `plies.count` the
    /// latest. Browsing back does not change the Game — but playing from there does, and what
    /// used to follow becomes a Variation.
    public internal(set) var cursor: Int {
        didSet {
            storedViewed = nil
            // Everything on screen was about *this* position: the shot the finder named, the
            // 应招 somebody opened on the strip, the 复判 they set going. The eye moving on is
            // all of it being put away (docs/adr/0034). The cursor says that it happened; what
            // it means is each of their business, not the cursor's.
            letGoOfThePosition()
        }
    }
    /// The Game rebuilt where the cursor stands, kept until either the Game or the cursor
    /// moves — the whole point of `viewed` being a stored value instead of a derivation
    /// (see `viewed` itself).
    @ObservationIgnored private var storedViewed: Game?
    /// The 错招 walked out of the Game once, with the key they were walked under. Reading them is
    /// a rules probe per Ply, and the record strip asks on every draw.
    @ObservationIgnored private var storedReading: (key: String, reading: RecordReading)?
    /// The Analysis of the position being looked at, replaced each time the engine reports a
    /// deeper one, and cleared the moment anything makes it stale.
    public internal(set) var analysis: Analysis?
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

    /// Who is listening. One listener, and only `hear` sets it — `disappear` always takes it
    /// away, so a screen cannot leave one behind on a session that outlives it.
    @ObservationIgnored private var onEvent: (@MainActor (Event) -> Void)?

    /// Listens to what happens on the board. The one listener at a time: a second `hear`
    /// replaces the first. `disappear` takes it away.
    public func hear(_ body: @escaping @MainActor (Event) -> Void) { onEvent = body }

    func emit(_ event: Event) { onEvent?(event) }

    // --------------------------------------------------------- shared position search
    // Search-clock state. Drivers live in `GameSession+Clock.swift`.

    /// The shared search has finished; its answer remains available without more work.
    public internal(set) var isAdviceSpent = false

    /// How the running search is getting on — how long it has been at it and how deep it has got.
    ///
    /// Apart from the Analysis on purpose, because it is not advice: a Depth and a stopwatch are a
    /// report of what the phone is doing, so practice, which refuses to show what the engine
    /// *thinks*, has no reason to hide them. It is what a thumb held on 让引擎走 is told.
    public internal(set) var searchProgress: SearchProgress?


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

    /// The tactics finder, which keeps its own four facts and the rules that move them together.
    /// The session owns the engine it probes with, and nothing else about it.
    var finder = TacticsFinder()


    /// Whether a Tactic may be named on the latest position (docs/adr/0023).
    ///
    /// Off at the start of every Game, never written to PGN, silent on a past Ply. Practice
    /// can stay on: then the board has no Score and no candidate Lines, only the shot.
    public var isFindingTactics: Bool { finder.isOn }
    /// The shot the finder currently names, if the last probe found one.
    public var tactic: Tactic? { finder.tactic }

    /// The finder's line as numbered arrows on the position on screen, yours where the hand is
    /// moving that colour. Empty when the finder has named nothing.
    public var tacticArrows: [MoveArrow] {
        guard let tactic else { return [] }
        return MoveArrow.walk(tactic.line, from: viewed) { controller(for: $0) == .hand }
    }
    /// True while the short search that confirms a Tactic is running.
    public var isProbingTactics: Bool { finder.isProbing }

    /// 牌堆 — what the deck under the record shows right now (`Deck`, docs/adr/0025): which of
    /// the two cards have a finding behind them, what each row says, which one is open, and
    /// whether anything is still being looked for. The screen draws this; it does not work it
    /// out. This is the one reading of the open card — `openCard`, `draws` and `drawnCard`
    /// read it back rather than reaching into `Findings` themselves, so the deck cannot say
    /// one thing and the arrows another.
    public var deck: Deck {
        Deck.dealt(
            isDealt: dealsCards, mate: mateNews != nil, tactic: tactic != nil,
            isSearching: isSearching || isProbingTactics,
            open: findings.openCard(on: viewed.state.fen),
            drawsLine: findings.drawsLine(on: viewed.state.fen)
        )
    }

    // ------------------------------------------------------------------ the open card

    /// Which card is open, whether its line is on the board, and the position it was opened on
    /// (docs/adr/0025). One state machine behind one seam (`Findings`); `deck` is what the
    /// screen is handed of it.
    var findings = Findings()

    /// Whether the deck has been dealt onto the screen once for this game. Not `dealsCards`,
    /// which is whether cards are allowed at all: coming back from a Review must not ask the
    /// engine again for what is already on the table.
    public var isDeckDealt: Bool { findings.isDealt }

    /// The card that is open, if one is.
    public var openCard: Deck.Card? { deck.rows.first(where: \.isOpen)?.card }

    public func isOpen(_ card: Deck.Card) -> Bool { deck.row(card)?.isOpen == true }

    /// Whether this card's line is the one on the board.
    public func draws(_ card: Deck.Card) -> Bool { deck.row(card)?.drawsLine == true }

    /// The card whose line is on the board, when one is.
    public var drawnCard: Deck.Card? { deck.rows.first { $0.isOpen && $0.drawsLine }?.card }

    /// What the board draws for the deck: the drawn card's line, or nothing.
    public var deckArrows: [MoveArrow] { arrows(for: drawnCard) }

    /// Pressing a finding. A row with nothing behind it does not press. Opening one in a 练习
    /// is help, and is counted as help.
    public func press(_ card: Deck.Card) {
        guard deck.has(card) else { return }
        if findings.press(card, on: viewed.state.fen) {
            notePracticeHelp()
        }
    }

    /// The arrow on the open card: its line on the board, or off it.
    public func toggleLine() {
        findings.toggleLine()
    }

    /// The deck arriving on screen. Both findings are questions for the finder, and arriving is
    /// what asks it (docs/adr/0023, 0025). Nothing is opened: a mate it turns up is said on its
    /// own row — 「发现杀招」 — and opened by whoever presses it. Once: the second call is nothing.
    public func dealDeck() {
        guard !findings.isDealt else { return }
        findings.isDealt = true
        arriveAtFinder()
        adviseForCard()
    }

    /// The card's line as chips, each the player's or not by the rule its arrows use.
    public func steps(on card: Deck.Card) -> [LineStep] {
        switch card {
        case .mate:
            return mateNews?.steps ?? []
        case .tactics:
            guard let tactic else { return [] }
            let opening = viewed.state.sideToMove
            return tactic.line.enumerated().map { index, san in
                let mover = index.isMultiple(of: 2) ? opening : opening.opposite
                return LineStep(step: index + 1, san: san, isYours: controller(for: mover) == .hand)
            }
        }
    }

    /// What the 杀招 card says when it has no mate to show. No news is news, and it is three
    /// different pieces of it — the game is over, there is no mate, nobody has looked yet — and
    /// nothing at all while a search is running: a card that goes blank when there is no mate is
    /// a card that looks broken (docs/adr/0025). Nil when there is a mate.
    public var mateQuiet: String? {
        guard mateNews == nil else { return nil }
        if viewed.isOver { return localized("screen.finished") }
        if isProbingTactics || isSearching { return nil }
        if isFindingTactics || analysis != nil { return localized("screen.noMate") }
        return localized("screen.mateIdle")
    }

    /// The open card's line as numbered arrows on the position on screen. Nothing for a card
    /// nobody can see: arrows from a card that is not on the table are arrows about a question
    /// nobody asked (docs/adr/0025).
    public func arrows(for card: Deck.Card?) -> [MoveArrow] {
        guard let card, dealsCards else { return [] }
        switch card {
        case .tactics: return tacticArrows
        case .mate: return mateNews?.arrows ?? []
        }
    }
    /// Analyses already paid for, keyed by the FEN they were found from. A swipe onto another
    /// card of the same position is not a new question, and walking back to a Ply that has
    /// already been asked about is not one either.
    @ObservationIgnored var analysisByFen = RecentAnalyses()

    private var controllers: [PieceColour: Controller]
    /// The 棋力 the engine plays its own moves at (docs/adr/0038). A fact about the game rather
    /// than a way of playing it, unlike a Controller: it is written onto every move the engine
    /// plays, and a reopened game comes back at the rung its last engine move was played at.
    public private(set) var strength: Strength
    private var tags: [PGN.Tag]
    var searchTask: Task<Void, Never>?
    /// The best move known to the search the engine was asked for — the arrow it started from, then
    /// whatever it has found since. What letting go of the button plays.
    var askedBest: String?
    /// The best move of the search the engine is running on its own turn, kept as the
    /// snapshots land so `moveNow` can play it the instant it is asked for, without
    /// waiting for the stream to end.
    var thinkingBest: String?
    /// Whether the button has already been let go of while its search was still starting up.
    var isAskReleased = false
    /// The move `holdForMove` returns, and the hook that wakes it. Both live here so the hold
    /// is one call whose lifetime is the thumb's: the press stores the hook, `finishAskedMove`
    /// plays and wakes, and a press that was refused wakes without a move.
    var heldMove: Move?
    var holdEnded: (() -> Void)?

    var engine: (any Engine)?
    weak var library: GameLibrary?

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
        self.ownLines = lines
        if PGN(game: game, tags: tags).intercept != nil { self.ownLines.noSlips = true }
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
        strength: Strength = .full,
        lines: JudgementLines = .standard
    ) -> GameSession {
        let session = GameSession(
            game: game, orientation: orientation, origin: .recognised, picture: picture, shaky: shaky,
            strength: strength, lines: lines
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
        // The drill's 线 are the session's — read through `lines` for as long as the drill is
        // here, so there is one value and not two kept in step. The initial value below is what
        // the file is written under before anybody has played (`pgn`, docs/adr/0046).
        let session = GameSession(
            game: drill.game,
            controllers: [drill.mover: .hand, drill.mover.opposite: .engine],
            // What it is, written into the file it saves: a game that began as a 错题
            // (docs/adr/0047). Every answered question leaves one, and the list reads this to
            // keep them out of the way of the games the player sat down to play.
            origin: .practised,
            lines: drill.lines
        )
        session.attach(engine: engine, library: library)
        session.practice = drill
        session.orientation = .facing(drill.mover)
        return session
    }

    public func notePracticeHelp() {
        practice?.noteHelp()
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

    /// The row under the record for an imported game's Review (docs/adr/0016, 0044): how far it
    /// has got, the offer to start it, or what it found. Nil for every game that is not an
    /// import awaiting or just given its Review — which is every game played here.
    public enum ReviewRow: Hashable, Sendable {
        /// Running: positions settled of positions to settle, or queued behind another game.
        case running(ImportReview.Progress)
        /// Offered, as a press rather than something that starts itself — seconds of engine per
        /// move. `failed` when the last try could not settle every position; `canStart` false
        /// while there is no engine or library to run it with.
        case offered(failed: Bool, canStart: Bool)
        /// Landed, with this many 错招 found.
        case done(slips: Int)

        /// What the row says.
        public var text: String {
            switch self {
            case .running(let progress):
                progress.total > 0
                    ? localized("review.progress", progress.judged, progress.total)
                    : localized("import.status.queued")
            case .offered(let failed, _): localized(failed ? "review.failed" : "review.offer")
            case .done(let slips):
                slips > 0 ? localized("review.done", slips) : localized("review.done.clean")
            }
        }

        /// The button's word, for the one state that has a button.
        public var action: String? {
            guard case .offered(_, let canStart) = self else { return nil }
            return localized(canStart ? "review.start" : "review.waiting")
        }
    }

    public var reviewRow: ReviewRow? {
        if let reviewProgress { return .running(reviewProgress) }
        if awaitsReview { return .offered(failed: reviewNews == .failed, canStart: canReview) }
        if case .done(let slips) = reviewNews { return .done(slips: slips) }
        return nil
    }

    /// Starts the Review of this imported game. Nothing happens unless `canReview`.
    public func review() {
        guard canReview, let engine, let library, let url,
            let entry = library.entry(at: url) else { return }
        reviewNews = nil
        library.reviewImported(entry, using: engine) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .reviewed(let reviewed):
                guard game.uciMoves == reviewed.game.uciMoves,
                    game.startFEN == reviewed.game.startFEN else { return }
                game = reviewed.game
                tags = reviewed.tags
                reviewNews = .done(slips: reading.slips.count)
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
    /// In the seat the file gave it (`seats(named:startingSideToMove:)`): the roster says which
    /// side was played by hand, and that side is still the player's when the record comes back.
    /// A record that names neither side, or both, faces the play instead — the person who opens it
    /// plays its first move, and the engine answers it, as soon as it has finished loading if the
    /// record got opened first. Either way it opens in practice: no arrow, no number, nobody
    /// whispering an answer.
    ///
    /// Opening writes nothing. The seats are settled as the session is made rather than switched
    /// afterwards, because switching one saves the file — and a record that rewrites its own
    /// roster the moment it is looked at is a record whose 错题 change hands (docs/adr/0028).
    ///
    /// Nil — refused, not failed — while the file is still on the way from iCloud. Opening it
    /// would give an empty board wearing the real game's file name, and the autosave after the
    /// first move would write it over the game that was on its way (docs/adr/0012). Every door
    /// into a saved game goes through this one, so the refusal cannot be forgotten.
    ///
    /// That refusal is named (`Opening.notArrived`) rather than left as a nil every caller had
    /// to remember is not a failure. `Opening.session` is the short path for a caller that has
    /// already decided the refusal is not its question; switching on `Opening` is the one that
    /// wants to say something about it.
    public enum Opening {
        /// The game, opened at the position it began in.
        case ready(GameSession)
        /// Still on the way from iCloud (docs/adr/0012).
        case notArrived

        /// The session, or nil for the one refusal. What `#require` takes in a test that is not
        /// about the refusal itself.
        public var session: GameSession? {
            if case .ready(let session) = self { session } else { nil }
        }
    }

    public static func opened(
        _ entry: GameLibrary.Entry,
        engine: (any Engine)? = nil,
        library: GameLibrary? = nil,
        strength: Strength = .full,
        /// The player's lines as they are now. The file says whether 把关 is on; where it stops
        /// the player is the 记录线 handed in here (docs/adr/0046).
        lines: JudgementLines = .standard
    ) -> Opening {
        guard !entry.isDownloading else { return .notArrived }
        let session = GameSession(entry: entry, library: library, strength: strength, lines: lines)
        session.attach(engine: engine, library: library)
        return .ready(session)
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
        strength: Strength = .full,
        lines: JudgementLines = .standard
    ) -> GameSession {
        let session = GameSession(
            game: game,
            controllers: controllers,
            orientation: orientation,
            origin: origin,
            picture: picture,
            shaky: shaky,
            strength: strength,
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
        self.init(
            game: game,
            // Seated here rather than by `opened`, because seating through `setController` writes
            // the file — and opening a record must not change it before the player has touched it.
            controllers: Self.seats(named: hands, startingSideToMove: game.startingSideToMove),
            // A record that names the player's side (an import tracked as Black, a game where the
            // engine had White) opens with that side at the bottom: it is their game, seen from
            // their chair. Any other record faces the side about to move: reading begins where
            // the play does.
            orientation: pgn?.orientation ?? .facing(game.startingSideToMove),
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
    @ObservationIgnored private var hostWatch: EngineHost.Watch?

    /// The screen this session is on has appeared, with the app's one engine host and the
    /// library to save into. From here the session keeps its own searches in step with the host:
    /// it takes the engine when it arrives, retunes when the app comes to the front and suspends
    /// when it leaves. A screen calls this on every appearance and `disappear` on every
    /// disappearance, and nothing else about when the engine should be doing what — the four
    /// hooks a screen used to wire for that were an ordering contract kept in a comment.
    ///
    /// `hearing` is who hears what happens on the board, and it is taken here rather than
    /// assigned afterwards so a screen cannot appear and forget to say. `disappear` always
    /// takes the listener away.
    ///
    /// Retunes before it returns, so a card dealt right after this keeps the Stint it starts.
    public func appear(
        on host: EngineHost, library: GameLibrary?,
        hearing hear: @escaping @MainActor (Event) -> Void = { _ in }
    ) {
        self.host = host
        isOnScreen = true
        self.hear(hear)
        attach(engine: host.service, library: library)
        retune()
        followHost()
    }

    /// The screen has gone: nothing searches for a board nobody is looking at, nobody hears a
    /// session nobody is looking at, and a thumb still down on 让引擎走 is let go of (`suspend`).
    public func disappear() {
        isOnScreen = false
        hostWatch?.stop()
        hostWatch = nil
        onEvent = nil
        suspend()
    }

    /// Subscribes to the host's two facts through the host's own seam (`EngineHost.Watch`), so
    /// "when does the engine's arrival reach this session" has one home. The token is dropped
    /// on `disappear`, which is what stops a screen that has gone from being followed.
    private func followHost() {
        hostWatch?.stop()
        hostWatch = nil
        guard let host, isOnScreen else { return }
        hostWatch = host.onStatusChange { [weak self] in
            guard let self, self.isOnScreen, let host = self.host else { return }
            // The engine may have finished starting while the screen was up: take it, and
            // the search this screen wants starts. The app leaving is a suspend, and coming
            // back a fresh retune rather than a search left running underneath — the engine
            // will not start one while the app is away, and a bounded one it held would
            // otherwise slip past that gate (`EngineHost.isActive`).
            if host.isReady, engine == nil { attach(engine: host.service, library: library) }
            if host.isActive { retune() } else { suspend() }
        }
    }

    /// The side about to move is the person's; the other side is the engine's.
    private func seatEngineOpponent() {
        setController(.engine, for: game.startingSideToMove.opposite)
    }

    /// The seats a saved record comes back to.
    ///
    /// **The file's word first.** A record names who played each side — `手动` against the
    /// engine's name — and the 错题本 counts a game's mistakes over exactly those colours
    /// (`PGN.handColours`, docs/adr/0028). Seating by the side that happens to move first instead
    /// put the player's own colour on the engine whenever the two differ — a photographed position
    /// with White to move in a game the player has Black in, an import tracked as Black, a game
    /// whose first move was handed over — and then wrote the flipped roster back to the file, so
    /// the game's 错题 changed owner and left the book.
    ///
    /// A file that names one side leaves that side in hand and gives the engine the other. A file
    /// that names both, or names none, has nothing to say about who is playing now: then the side
    /// about to move is the person's, which is where reading a record begins.
    static func seats(
        named hands: Set<PieceColour>, startingSideToMove: PieceColour
    ) -> [PieceColour: Controller] {
        let mine = hands.count == 1 ? hands.first! : startingSideToMove
        return [mine: .hand, mine.opposite: .engine]
    }

    public func controller(for colour: PieceColour) -> Controller {
        controllers[colour] ?? .hand
    }

    /// Whether a seat chip may be pressed: never while the board is spoken for — the same refusal
    /// `setController` makes — and the engine's only once there is an engine. Seating it before
    /// one has arrived is allowed in the kit (a game can be made before the host is ready); it is
    /// the chip that has nothing to offer yet.
    public func canSeat(_ controller: Controller) -> Bool {
        !isOccupied && (controller == .hand || engine != nil)
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
    /// Sets the 棋力 this game is played at, **and the one the next game starts at** (docs/adr/0038).
    ///
    /// Two facts, one call. The screen used to write `settings.strength` beside this, so
    /// `setStrength` on its own did not do what its name says and a caller that forgot the
    /// second line changed this game and not the next. The settings are handed in rather than
    /// reached for as a singleton, because the kit has none — and a test has an in-memory one.
    public func setStrength(_ strength: Strength, in settings: PlayerSettings? = nil) {
        guard !isOccupied else { return }
        guard self.strength != strength else { return }
        self.strength = strength
        settings?.strength = strength
        if thinking == .own { retune() }
    }

    /// Turns the tactics finder on, or back off. Takes effect now: a shot left standing after
    /// the switch is thrown is the one thing the live board must not keep drawing.
    public func setFindingTactics(_ on: Bool) {
        guard dealsCards || !on else { return }
        guard isFindingTactics != on else { return }
        if !on {
            finder.turnOff()
            // An advice Stint already paid for this position must not be taken down just because
            // the finder card was left. Retune only when there is nothing in hand to keep.
            if searchTask != nil || analysis != nil { return }
            retune()
            return
        }
        finder.turnOn()
        // Finding opportunities must not restart a move already on the clock.
        if thinking != nil { return }
        if recallCachedAnalysis(), let found = analysis {
            finder.confirm(in: viewed, analysis: found)
            return
        }
        if let found = analysis {
            noteProgress(found)
            finder.confirm(in: viewed, analysis: found)
            return
        }
        retune()
    }

    /// Arriving at 杀 or 战术: the swipe is the asking (docs/adr/0025), so the finder goes on if
    /// it was not on already.
    ///
    /// There is no leaving. The finder was a place you could swipe away from when it had a deck
    /// of its own; it is a card under the record now, and a card is not somewhere you leave —
    /// the switch stays where the arrival put it until somebody moves it or 把关 takes it.
    public func arriveAtFinder() {
        guard !isFindingTactics else { return }
        setFindingTactics(true)
    }

    /// What the strip under the board should say while the finder is on.
    ///
    /// Nil when the finder is off. It talks about whichever position is on screen, a past Ply
    /// included: the finder is a card of its own now, and swiping onto it is the asking
    /// (docs/adr/0025, amending 0023).
    public var tacticPrompt: String? {
        guard !viewed.isOver else { return nil }
        return finder.prompt(ourTurn: isHandTurn)
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
        guard let source = analysis ?? finder.probedAnalysis else { return nil }
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
    /// Whether a corrected position can go back into this game rather than make a second one:
    /// nothing played in it yet, and the board not spoken for. What the editor's button reads to
    /// say which of the two it will do — it read only the first, and said 「用这个」 over a press
    /// that then made a second game.
    public var canReplaceStart: Bool { !isOccupied && game.plies.isEmpty }

    public func replaceStart(with fresh: Game) -> Bool {
        guard canReplaceStart else { return false }
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
    ///
    /// **A 练习 keeps no second copy.** While one is on, the drill's 线 *are* the session's: the
    /// drill judges and rules the attempt under them (`Drill.lines`), and a session that kept its
    /// own value beside them could be switched to 把关 off while the drill went on refusing. The
    /// switch writes through to the drill instead (docs/adr/0048).
    public var lines: JudgementLines { practice?.lines ?? ownLines }

    /// The 线 for a game nobody is practising. Read through `lines`, never around it.
    private var ownLines: JudgementLines = .standard

    /// 把关: whether a move by hand is measured before it is allowed to stand.
    ///
    /// A switch and nothing else: where it stops the player is the 记录线, the same number that
    /// decides what is written down (docs/adr/0046). The switch is a *per game* setting and it
    /// sits beside 谁执白 and 引擎想多久 rather than in the app's settings: any position can be
    /// played under 把关, including one reached by playing on from a 错题 or read off a photograph.
    public var isNoSlipsOn: Bool { lines.noSlips }
    /// Whether the deck is dealt and a card may ask the engine. The one rule, read here by the
    /// screen that deals, by the session that answers and by the finder's own switch, so none of
    /// the three can disagree about whether a card is on the table.
    ///
    /// **Never in a 把关 game**: a card is an opinion about the position in front of the player,
    /// and 把关 says nothing about what to play (docs/adr/0031, 0040).
    ///
    /// **Always in a practice session**, 把关 or not. This used to read the switch alone, which
    /// tied two unrelated things together: whether anybody is stopping your hand, and whether 杀
    /// and 战术 may be looked at. A drill's help is counted rather than withheld — pressing a card
    /// is a rung on the practice log's `hints` (docs/adr/0029) — so putting practice under 把关
    /// would have taken the cards away and left that number with nothing to count.
    public var dealsCards: Bool { practice != nil || !isNoSlipsOn }
    public var findsPunishment = false
    /// The exercise last put on the board, kept once it is finished so its answer can still be
    /// read. Whether it is *on* the board is the activity's to say (`activePunishment`).
    public internal(set) var punishment: Punishment?
    public var activePunishment: Punishment? {
        if case .exercising(let exercise) = activity { exercise } else { nil }
    }


    /// Whether the two numbers may be moved right now.
    ///
    /// Not while a move is being weighed, and never in a 练习: a drill owns the 记录线 its
    /// attempt passes or fails by, and a number moved under it would change what the attempt
    /// was asked. The 把关 switch is not one of the numbers and does not ask (`setNoSlips`).
    public var acceptsLines: Bool { !isOccupied && practice == nil }

    /// Switches 把关 on or off. It stops the player at the 记录线, **the only dial 把关 has on the
    /// judgement of a move** — how strong the opponent is (`strength`, docs/adr/0038) and how
    /// much slack the coach cuts are two different questions, and answering both with one knob
    /// makes it impossible to say who improved (docs/adr/0009).
    ///
    /// **Always moves** (docs/adr/0048): mid-move, under an exercise, in a 练习, with no engine
    /// yet. A move being weighed is ruled under the switch as it stands when the weighing ends,
    /// so switching off while 把关 is judging lets that move stand. With no engine the switch is
    /// still the game's — nothing is measured until one arrives, and then 把关 does its job.
    public func setNoSlips(_ enabled: Bool) {
        var moved = lines
        moved.noSlips = enabled
        adopt(moved)
    }

    /// The lines and the switch at once — what a game opened from the library starts under. The
    /// same consequences as flipping the switch alone: a refusal made under the old lines is
    /// forgotten, the file says the new ones, and the search starts over.
    public func setLines(_ new: JudgementLines) {
        guard acceptsLines else { return }
        adopt(new)
    }

    /// Where `setLines` and `setNoSlips` both end: the one write of the 线, into the drill's value
    /// while a 练习 is on and into the session's own otherwise, and what follows a change.
    private func adopt(_ new: JudgementLines) {
        guard new.isDrawn else { return }
        guard lines != new else { return }
        let interceptMoved = lines.intercept != new.intercept
        if let practice { practice.lines = new } else { ownLines = new }
        // A game going under 把关 puts its cards away; a practice session keeps them, because
        // what it deals is not decided by the switch (`dealsCards`).
        if interceptMoved, !dealsCards {
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
    enum Activity {
        case reading
        /// The 原局 to put back if the move does not stand, and the task weighing it. A drill's
        /// attempt has no 原局 here: the drill keeps its own and puts it back itself.
        case weighing(standpoint: Standpoint?, task: Task<Void, Never>)
        case walking
        case exercising(Punishment)
        case thinking(Thinking)

        /// Whether this is a thumb holding 让引擎走 down. The hold ends the moment this stops
        /// being true, which is the fact `activity`'s watcher reads.
        var isAskedHold: Bool {
            if case .thinking(.asked) = self { true } else { false }
        }
    }

    /// What the session is doing. Leaving `.thinking(.asked)` is letting go of the hold, whoever
    /// did it — a release, a walk taking the board, a hand move being weighed, the screen going
    /// away — so `holdForMove` is woken here rather than in each of those places. One watcher
    /// for one fact: a hold that can only be ended by its own release is a hold that outlives
    /// everything else on the screen.
    var activity: Activity = .reading {
        didSet {
            if oldValue.isAskedHold, !activity.isAskedHold { wakeHold() }
        }
    }

    /// Starts the engine walking a move. Refused while the board is spoken for or the record is
    /// on its way somewhere: those are not things a search may take the board from.
    func think(_ whose: Thinking) -> Bool {
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
    func stopThinking() {
        if case .thinking = activity { activity = .reading }
    }

    /// Lets go of whoever is inside `holdForMove`, with whatever move it had. Only that call
    /// stores a hook, so this is a no-op for a session nobody is holding.
    func wakeHold() {
        let ended = holdEnded
        holdEnded = nil
        ended?()
    }

    /// A move is on the board and being weighed. It ends whatever the engine was walking, which
    /// the caller has already taken the search of, and replaces a weighing still in flight.
    func beginWeighing(from standpoint: Standpoint?, task: Task<Void, Never>) {
        if case .weighing(_, let running) = activity { running.cancel() }
        activity = .weighing(standpoint: standpoint, task: task)
    }

    /// The weighing is over, whichever way: the board is the player's again.
    func endWeighing() {
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
    /// and nothing may change the game, its lines or its seats until it is given back. The 把关
    /// switch is the one exception: it always moves (docs/adr/0048).
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
    public internal(set) var refused: Game.Ply.Tried?

    /// The session's own measurement of the move just played, for the change badge.
    var measuring: Task<Void, Never>?
    /// Waits until everything that is judging a move has said its piece: a move being weighed
    /// and the badge measured after it, a 复判, a 应招 being fetched, an exercise checking a
    /// reply. Not the position's own standing search — that is the engine looking, or playing,
    /// and it is what a move played next interrupts. The one thing a screen or a test holds on
    /// to instead of polling the session's state: a verdict arrives when the engine has answered
    /// and not a moment sooner, and the state after this is the state the screen would draw.
    ///
    /// **Waits for what is in flight and starts nothing.** Asking for the badge here as well
    /// (`measureLatestMove`) was the obvious way to make this the one await, and it is a trap:
    /// the badge is a `weigh`, so a session whose engine is scripted to hold one search open
    /// would have that search stolen by the wait — the budget the test scripted, the positions
    /// it counted, the 应招 it expected to be asked for. `retune` schedules the badge when a
    /// move lands; a caller that wants one without a retune asks (`measureLatestMoveChange`).
    public func settled() async {
        if case .weighing(_, let task) = activity { await task.value }
        await measuring?.value
        await onStrip.rejudgePending?.value
        await onStrip.replyPending?.value
        await punishment?.settled()
    }
    /// What was last said about a refusal at each position the player has been refused at, so
    /// the sentence under the board follows the eye: browsing away from a refusal puts it away,
    /// and coming back brings it back. Session state and nothing more: the refusals themselves
    /// are the Game's (`Game.pendingTried`, docs/adr/0037), read at the cursor, and a session
    /// that kept its own copy of them was one more place for them to be wrong.
    var refusalByPosition: [String: Game.Ply.Tried] = [:]
    var refusalPosition: String?

    func restoreRefusalForViewedPosition() {
        let fen = viewed.state.fen
        guard refusalPosition != fen else { return }
        if let refusalPosition {
            refusalByPosition[refusalPosition] = refused
        }
        refusalPosition = fen
        refused = refusalByPosition[fen]
    }
    /// 优势条读数 — the one number the bar shows, and where it came from (`BarReading`).
    ///
    /// One priority, written here and nowhere else. While a move is being weighed, the position
    /// it made has no number — that is what the weighing is — and a bar with no number draws a
    /// level game over a position that is nothing like it; so the reading steps back to the
    /// position the move was played from and says so.
    public var barReading: BarReading {
        // The move just played, while it is still the move just played.
        if let badge, badge.describes(game), isAtLatest, !isWeighing {
            return BarReading(.landed(badge.change))
        }
        // The live bounded search of the position on screen.
        if let score = liveScore(of: viewed.state.fen) {
            return BarReading(.searching(score))
        }
        // What the record says about the position on screen.
        if let known = historyScore(atPly: cursor) {
            return BarReading(.record(known))
        }
        // Weighing: hold the number of the position the move was played from. The table can
        // only be that position's — its search was stopped when the move landed.
        if isWeighing {
            if let score = liveScore() { return BarReading(.searching(score)) }
            if let known = historyScore(atPly: cursor - 1) { return BarReading(.record(known)) }
        }
        return BarReading(nil)
    }

    /// The live bounded search's number for a position. With a `fen`, only that position's
    /// table; without one, whatever the table holds. The standing Analysis is the same search
    /// in its other home — a card's Stint fills both (GameSession+Clock) — so it answers here
    /// too rather than after the record.
    private func liveScore(of fen: String? = nil) -> Score? {
        if let table = interceptTable, fen == nil || table.fen == fen {
            return table.analysis.best?.score
        }
        return analysis?.best?.score
    }
    /// The 试招 refused at the position on the board that no move has absorbed yet, oldest
    /// first. Read out of the Game, which is where a refusal is written the moment it happens.
    public var pendingAttempts: [Game.Ply.Tried] { game.pendingTries(atPly: cursor) }

    /// 记录读数 — everything this game's record says about the player's 错招 at the position on
    /// the board (`RecordReading`): the 错招 themselves, the 试招 refused here, and which of them
    /// a chip should show. Held rather than recomputed, because the walk behind `slips` is the
    /// expensive half and the eye moves far more often than the game changes.
    public var reading: RecordReading {
        // Keyed on what the answer depends on: the game (a refusal is written into it without
        // touching a move, so the `game` didSet is the invalidation and this is the second
        // check), whose moves count, and the two lines that decide what counts. Moving the
        // record line changes the answer; changing whose hand is whose changes which moves
        // are 错招 at all.
        let key = "\(game.uciMoves.joined(separator: " "))|\(mine.map(String.init(describing:)).sorted().joined())|\(lines.record)|\(lines.enqueue)"
        if let stored = storedReading, stored.key == key {
            if stored.reading.cursor == cursor { return stored.reading }
            let moved = stored.reading.moved(to: cursor)
            storedReading = (key, moved)
            return moved
        }
        let made = RecordReading(game: game, mine: mine, lines: lines, cursor: cursor)
        storedReading = (key, made)
        return made
    }

    /// to a position, and this is it. Nil only when there is nothing to show.
    public var refusedPosition: Game? {
        guard let ply = reading.wrongsPly else { return nil }
        return ply == cursor ? viewed : game.rewound(to: ply)
    }

    /// The position a 试招 made. It is the one its 应招 comes back from, and the one the board no
    /// longer shows, because 把关 has already taken the move back.
    public func position(after tried: Game.Ply.Tried) -> Game? {
        position(afterPlaying: tried.san)
    }

    /// The same for any wrong move on the strip — for one that stood, the position the game
    /// went on from.
    public func position(after wrong: RecordReading.WrongMove) -> Game? {
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
    public func reply(for wrong: RecordReading.WrongMove) async -> [String] {
        await reply(kept: wrong.line, afterPlaying: wrong.san)
    }

    private func reply(kept line: [String], afterPlaying san: String) async -> [String] {
        if !line.isEmpty { return line }
        guard let engine, let played = position(afterPlaying: san) else { return [] }
        let result = await engine.positionResult(played)
        guard !Task.isCancelled else { return [] }
        return Array((result?.best?.san ?? []).prefix(Reply.limit))
    }

    var onStrip = StripQuestions()
    /// The 应招 open on the strip, if one is (`readReply(at:)`).
    public var replyReading: ReplyReading? { onStrip.replyReading }

    /// Whether a wrong move on the strip may be asked about: not while a 惩罚 exercise has the
    /// board, which is the one thing in the strip asking something of the player (docs/adr/0031).
    public var canReadReply: Bool { activePunishment == nil }

    /// Reads the 应招 of a 试招 on the strip, or puts it away again if it is the one open.
    ///
    /// A move that carries its answer is read at once; one refused before replies were written
    /// down asks the shared bounded search and is filled in when the answer comes. Shut while a
    /// 惩罚 exercise is open: that exercise is the same answer with the finding left to the
    /// player, and a reading that would hand it over is the exercise not being one.
    public func readReply(at index: Int) {
        if onStrip.isReplyOpen(at: index) {
            onStrip.closeReply()
            return
        }
        let wrongs = reading.wrongs
        guard canReadReply, wrongs.indices.contains(index),
            let position = refusedPosition
        else { return }
        let wrong = wrongs[index]
        let hasAnswer = !wrong.line.isEmpty
        onStrip.openReply(
            ReplyReading(
                index: index, move: wrong, position: position,
                line: hasAnswer ? Reply.moves(of: wrong) : [], isAsking: !hasAnswer
            )
        )
        guard !hasAnswer else { return }
        onStrip.askReply(
            Task { [weak self] in
                guard let self else { return }
                let answer = await self.reply(for: wrong)
                guard !Task.isCancelled else { return }
                onStrip.fillReply(
                    answer.isEmpty ? [] : Reply.moves(of: wrong, reply: answer),
                    of: wrong, at: index
                )
            }
        )
    }

    // ------------------------------------------------------------------ 复判

    /// The 复判 under way, if one is (`rejudge(at:)`).
    public var rejudging: Rejudging? { onStrip.rejudging }

    /// The 试招 at `index` of `reading.wrongs`, when that is what it is. A move that stood is
    /// judged by the game it stands in, and a 复判 is for a move that was taken back.
    private func triedToRejudge(at index: Int) -> (tried: Game.Ply.Tried, at: Int)? {
        let wrongs = reading.wrongs
        guard wrongs.indices.contains(index), let at = wrongs[index].triedIndex,
            reading.attempts.indices.contains(at)
        else { return nil }
        return (reading.attempts[at], at)
    }

    public func rejudgeOffer(at index: Int) -> RejudgeOffer {
        guard let engine, let found = triedToRejudge(at: index) else { return .none }
        if (found.tried.depth ?? 0) >= PositionSearches.deeperDepth { return .none }
        if onStrip.isRejudging || isOccupied || isThinking || isSearching || engine.isPaused {
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
        onStrip.beginRejudge(Rejudging(index: index, tried: tried, depth: 0))
        onStrip.askRejudge(
            Task { [weak self] in
                guard let self else { return }
                // The same 细判 as the one that refused the move, at the deeper budget: one act,
                // so the depth the number is worth and the 应招 beside it are read by one rule.
                let weighed = await engine.weigh(played, from: before, budget: PositionSearches.deeper) {
                    onStrip.noteRejudge(depth: $0.depth)
                }
                guard !Task.isCancelled else { return }
                finishRejudge(
                    weighed.map {
                        .init(san: tried.san, drop: $0.drop, notFound: tried.notFound, depth: $0.depth, line: $0.reply)
                    },
                    at: index
                )
            }
        )
    }

    /// Writes the deeper number where the 试招 is — pending at the position, or on the move that
    /// carried it — and brings an open reading of it up to date. Nothing is written when the
    /// game has moved on from under it.
    private func finishRejudge(_ deeper: Game.Ply.Tried?, at index: Int) {
        defer { onStrip.finishRejudge() }
        guard let deeper, let was = onStrip.rejudgingTried, let found = triedToRejudge(at: index),
            found.tried == was
        else { return }
        let at = found.at
        var attempts = reading.attempts
        attempts[at] = deeper
        switch reading.place {
        case .pending: game.setPendingTried(attempts, atPly: cursor)
        case .ply(let ply): game.setTried(attempts, hints: game.plies[ply].hints, atPly: ply)
        case .nothing: return
        }
        if let reading = replyReading, reading.index == index, reading.move == RecordReading.WrongMove(was, at: at) {
            onStrip.rewriteReply(
                as: ReplyReading(
                    index: index, move: RecordReading.WrongMove(deeper, at: at), position: reading.position,
                    line: Reply.moves(of: deeper), isAsking: false
                )
            )
        }
        save()
    }

    public var isFaceToFace = false

    /// The badge for the move just played (`LandedBadge`), while it is still that move.
    var badge: LandedBadge?
    /// The game as it stood when a move last landed through `commit` with no judgement on it —
    /// the one move `measureLatestMoveChange` is owed a judgement for. A move that was already
    /// in the file when the game was opened keeps whatever it has: filling those in is the
    /// explicit migration (`fillMissingNoSlipsJudgements`), never something a screen starts.
    var landedUnjudged: OfGame?

    /// Only a newly played move gets a change badge; navigating the record is not a move.
    public var moveChange: MoveChange? { barReading.change }

    /// What the bar shows. `barReading` is the reading; this is the number on it.
    public var feedbackScore: Score? { barReading.score }

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
        if let badge, badge.describes(game) {
            if ply == game.plies.count { return badge.change.after }
            if ply == game.plies.count - 1 { return badge.change.before }
        }
        return game.reviewScore(atPly: ply)
    }

    /// The personal side stays personal when the board is flipped. With two manual sides,
    /// the bottom side supplies the perspective, just as it does for the bar.
    private var feedbackColour: PieceColour {
        let hands = [PieceColour.white, .black].filter { controller(for: $0) == .hand }
        return hands.count == 1 ? hands[0] : orientation.bottom
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


    var interceptTable: (fen: String, analysis: Analysis)?


    // ------------------------------------------------------------- finding the 错招

    /// is a curve to draw.
    public var curve: ScoreCurve {
        ScoreCurve(scores: (0...game.plies.count).map { historyScore(atPly: $0) })
    }

    /// 连正 for the sides the player is moving, read out of the game (CONTEXT.md).
    public var noSlips: Game.NoSlips { game.noSlips(by: mine) }

    /// A Ply this session was asked to walk to when its screen arrives, if any.
    /// Walk rules live in `GameSession+Walk.swift`.
    var arrivalWalk: Int?

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


    // ------------------------------------------------------------------ a study


    // ----------------------------------------------------------------- point at a square


    /// Takes the last move of the game off. Only from the latest position: in the middle of a
    /// game, going backwards is browsing, and deleting is not what a back button means.
    /// Whether 撤销 may be pressed: the three refusals `undo()` makes, read by the menu that
    /// offers it. The menu used to spell only two of them, so it stayed live while a move was
    /// being weighed and did nothing when pressed.
    public var canUndo: Bool { !isOccupied && isAtLatest && !game.plies.isEmpty }

    public func undo() {
        guard canUndo else { return }
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
        // A refusal is as much a thing that happened as a move is (docs/adr/0037, 0047). It used
        // to take a move to make a game worth a file, so being stopped at the first position and
        // putting the phone down left nothing behind — in a drill, where the first position is
        // the whole question, that was every 错题 answered wrong and walked away from.
        guard url != nil || !game.plies.isEmpty || !game.pendingTried.isEmpty else { return }
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
