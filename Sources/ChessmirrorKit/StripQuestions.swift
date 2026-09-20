/// The two questions the strip under the board can ask about one 试招: what the 应招 to it was,
/// and what it is worth judged again, deeper.
///
/// Each was a pair of properties on the session — the thing on screen, and the Task filling it
/// in — which meant a search could outlive the reading it was answering, and the session had to
/// remember to take both down in every place a position stops being the position. Pairing them
/// makes that combination unrepresentable: putting the question away *is* stopping the search.
///
/// Neither owns an engine. The session runs the search, because the search is the one bounded
/// budget every card shares, and hands the answer back.

/// The 应招 open on the strip, and the search filling it in (docs/adr/0034).
struct StripReply {
    private(set) var reading: GameSession.ReplyReading?
    private var task: Task<Void, Never>?

    /// Whether this is the reading that is open — which is how a second tap on a chip knows it
    /// is a tap that closes rather than one that opens.
    func isOpen(at index: Int) -> Bool { reading?.index == index }

    /// The search filling the open reading, for anyone waiting on everything to have spoken.
    var pending: Task<Void, Never>? { task }

    /// Opens a reading. Whatever was open goes away first, question and all.
    mutating func open(_ reading: GameSession.ReplyReading) {
        close()
        self.reading = reading
    }

    /// Hands the open reading the search that will answer it.
    mutating func ask(_ task: Task<Void, Never>) {
        self.task = task
    }

    /// The answer arrived. Dropped when the reading it was asked for is no longer the one open:
    /// an answer to a question nobody is asking any more is not an answer.
    mutating func fill(_ line: [String], of move: GameSession.WrongMove, at index: Int) {
        guard reading?.index == index, reading?.move == move else { return }
        reading?.isAsking = false
        reading?.line = line
    }

    /// A 复判 rewrote the move this reading is of, so the reading is of the rewritten move now.
    mutating func rewrite(as reading: GameSession.ReplyReading) {
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
    private(set) var rejudging: GameSession.Rejudging?
    private var task: Task<Void, Never>?

    /// Whether a 复判 is going, which is one of the reasons the strip may not offer another.
    var isBusy: Bool { rejudging != nil }

    /// The 试招 that was being judged again, so the writer can check the game did not move on
    /// from under it.
    var tried: Game.Ply.Tried? { rejudging?.tried }

    /// The deeper 细判, for anyone waiting on everything to have spoken.
    var pending: Task<Void, Never>? { task }

    mutating func begin(_ rejudging: GameSession.Rejudging) {
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
