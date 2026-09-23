/// The two questions the strip under the board can ask about one 试招: what the 应招 to it was,
/// and what it is worth judged again, deeper.
///
/// The vocabulary lives here with the conversation, not on the session: a screen reads one face
/// (`StripQuestions`), and the session only asks it to open, fill and put away. Each half pairs
/// the thing on screen with the Task filling it in, so a search cannot outlive the reading it was
/// answering — putting the question away *is* stopping the search.
///
/// Neither half owns an engine. The session runs the search, because the search is the one
/// bounded budget every card shares, and hands the answer back.

/// A 应招 being read on the strip: which 试招, the line it makes, and how far the board can
/// draw it (docs/adr/0034).
public struct ReplyReading: Equatable, Sendable {
    /// One numbered step of the line, as the chips under the board say it.
    public typealias Step = LineStep

    /// Which of `reading.wrongs` is open.
    public let index: Int
    public let move: RecordReading.WrongMove
    /// The position the move was played in, which the arrows are walked from.
    public let position: Game
    /// The 试招 followed by its 应招. Empty until there is an answer: one arrow for a move
    /// that was taken back is a picture of the mistake with the lesson left out.
    public internal(set) var line: [String]
    /// Whether the answer is still being asked for.
    public internal(set) var isAsking: Bool

    public init(
        index: Int,
        move: RecordReading.WrongMove,
        position: Game,
        line: [String],
        isAsking: Bool
    ) {
        self.index = index
        self.move = move
        self.position = position
        self.line = line
        self.isAsking = isAsking
    }

    /// The line as numbered arrows from the position the move was refused in.
    public var arrows: [MoveArrow] { Reply.arrows(in: position, playing: line) }

    /// The arrows as chips, numbered the same way. Read off the arrows rather than off the
    /// line, so the two cannot disagree about how far the walk got or whose move a step is.
    public var steps: [Step] {
        MoveArrow.chips(for: arrows, naming: line)
    }
}

/// A 复判 under way: which 试招 on the strip is being judged again, and how deep both ends
/// have got (CONTEXT.md, 复判; docs/adr/0041).
public struct Rejudging: Equatable, Sendable {
    /// Which of `reading.wrongs`.
    public let index: Int
    public let tried: Game.Ply.Tried
    /// The shallower of the two ends so far — zero before either has said anything.
    public internal(set) var depth: Int

    public init(index: Int, tried: Game.Ply.Tried, depth: Int) {
        self.index = index
        self.tried = tried
        self.depth = depth
    }
}

/// What the strip may offer for one 试招. The screen reads this and nothing else about a 复判:
/// whether there is a button, whether it can be pressed, or the depth of the one already going.
public enum RejudgeOffer: Equatable, Sendable {
    /// Nothing: the move is already judged as deep as a 复判 goes, or there is no engine,
    /// or it is not a 试招.
    case none
    /// The button, greyed: the engine is spoken for — a move being weighed or walked, the
    /// position's own search still running, another 复判 already going, the engine paused.
    case waiting
    case ready
    /// This 试招 is the one being judged again. `depth` is how far the shallower end has got.
    case running(depth: Int)

    /// How deep a 复判 goes, and the depth past which the offer is `.none`. One number: the
    /// button states it, and a 试招 already judged to it is not offered again.
    public static var depth: Int { PositionSearches.deeperDepth }
}

/// The 应招 open on the strip, and the search filling it in (docs/adr/0034).
struct StripReply {
    private(set) var reading: ReplyReading?
    private var task: Task<Void, Never>?

    /// Whether this is the reading that is open — which is how a second tap on a chip knows it
    /// is a tap that closes rather than one that opens.
    func isOpen(at index: Int) -> Bool { reading?.index == index }

    /// The search filling the open reading, for anyone waiting on everything to have spoken.
    var pending: Task<Void, Never>? { task }

    /// Opens a reading. Whatever was open goes away first, question and all.
    mutating func open(_ reading: ReplyReading) {
        close()
        self.reading = reading
    }

    /// Hands the open reading the search that will answer it.
    mutating func ask(_ task: Task<Void, Never>) {
        self.task = task
    }

    /// The answer arrived. Dropped when the reading it was asked for is no longer the one open:
    /// an answer to a question nobody is asking any more is not an answer.
    mutating func fill(_ line: [String], of move: RecordReading.WrongMove, at index: Int) {
        guard reading?.index == index, reading?.move == move else { return }
        reading?.isAsking = false
        reading?.line = line
    }

    /// A 复判 rewrote the move this reading is of, so the reading is of the rewritten move now.
    mutating func rewrite(as reading: ReplyReading) {
        self.reading = reading
    }

    /// Puts the 应招 away. A question asked once is not a layer left on: the board goes back to
    /// the position and says nothing about what the player might have tried.
    mutating func close() {
        task?.cancel()
        task = nil
        reading = nil
    }
}

/// A 复判 under way on the strip, and the deeper 细判 doing it (docs/adr/0041).
struct StripRejudge {
    private(set) var rejudging: Rejudging?
    private var task: Task<Void, Never>?

    /// Whether a 复判 is going, which is one of the reasons the strip may not offer another.
    var isBusy: Bool { rejudging != nil }

    /// The 试招 that was being judged again, so the writer can check the game did not move on
    /// from under it.
    var tried: Game.Ply.Tried? { rejudging?.tried }

    /// The deeper 细判, for anyone waiting on everything to have spoken.
    var pending: Task<Void, Never>? { task }

    mutating func begin(_ rejudging: Rejudging) {
        self.rejudging = rejudging
    }

    mutating func ask(_ task: Task<Void, Never>) {
        self.task = task
    }

    /// How deep the shallower of the two ends has got.
    mutating func note(depth: Int) {
        rejudging?.depth = depth
    }

    /// Both ends have finished and the number has been written. The search is over of its own
    /// accord, so there is nothing to cancel.
    mutating func finish() {
        task = nil
        rejudging = nil
    }

    /// The game moved on. A 复判 yields to it, unwritten — it never changes the fact that the
    /// move was taken back, so there is nothing lost by stopping.
    mutating func cancel() {
        task?.cancel()
        task = nil
        rejudging = nil
    }
}

/// One conversation on the strip: at most one 应招 open, at most one 复判 going. The session
/// holds this and asks it; the vocabulary above is what a screen reads.
struct StripQuestions {
    private var reply = StripReply()
    private var rejudge = StripRejudge()

    var replyReading: ReplyReading? { reply.reading }
    var rejudging: Rejudging? { rejudge.rejudging }
    var isRejudging: Bool { rejudge.isBusy }
    var rejudgingTried: Game.Ply.Tried? { rejudge.tried }
    var replyPending: Task<Void, Never>? { reply.pending }
    var rejudgePending: Task<Void, Never>? { rejudge.pending }

    /// Puts the whole conversation away: the board moved on, or the session is going.
    mutating func close() {
        reply.close()
        rejudge.cancel()
    }

    // MARK: 应招

    func isReplyOpen(at index: Int) -> Bool { reply.isOpen(at: index) }

    mutating func openReply(_ reading: ReplyReading) { reply.open(reading) }

    mutating func askReply(_ task: Task<Void, Never>) { reply.ask(task) }

    mutating func fillReply(_ line: [String], of move: RecordReading.WrongMove, at index: Int) {
        reply.fill(line, of: move, at: index)
    }

    mutating func rewriteReply(as reading: ReplyReading) { reply.rewrite(as: reading) }

    mutating func closeReply() { reply.close() }

    // MARK: 复判

    mutating func beginRejudge(_ rejudging: Rejudging) { rejudge.begin(rejudging) }

    mutating func askRejudge(_ task: Task<Void, Never>) { rejudge.ask(task) }

    mutating func noteRejudge(depth: Int) { rejudge.note(depth: depth) }

    mutating func finishRejudge() { rejudge.finish() }

    mutating func cancelRejudge() { rejudge.cancel() }
}
