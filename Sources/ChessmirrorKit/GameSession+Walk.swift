import Foundation

/// 记录导航 — where the eye is on the record, and every way it moves.
///
/// **Seam: `cursor`.** Moving it is the session saying the position on screen changed: the
/// old one's questions are put away (`letGoOfThePosition`, docs/adr/0034 — the finder drops
/// its shot, the strip puts its 应招 away, the 复判 yields unwritten), and the clock is
/// retuned once where the eye stops. Browsing never changes the Game; `cycleFork` is the
/// one walk that rewrites which line stands, and it saves that.
///
/// Why an extension and not a module: the eye *is* the session's `cursor` — observable
/// state screens bind to — so an `Eye`/`Walk` type would only shuttle it. The walk's depth
/// is the rules of moving it (`canBrowse`, one retune at the end of a walk rather than per
/// Ply, a walk that ends a thinking search first). Those rules live here.
extension GameSession {
    /// The eye has moved to another position. Whatever was found, opened or set going about the
    /// one it left is about a board that is no longer on screen, and each of them knows what
    /// that means for it: the finder drops its shot, the strip puts its 应招 away, the 复判
    /// yields unwritten.
    func letGoOfThePosition() {
        findings.forget()
        finder.forget()
        onStrip.close()
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
}
