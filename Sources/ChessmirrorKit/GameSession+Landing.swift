import Foundation

/// 判定落地 — every way a move becomes part of the game, and what a session does with a
/// `Ruling` once one exists.
///
/// **Seam: `land(Ruling,played:engine:)`.** Both 把关 and a 练习 end there — the drill's
/// attempt and a hand move under 把关 are two intakes and one door. `commit` is the other
/// way in: a move that nobody weighs (no engine, or a move played by the engine's own
/// Controller). `weigh` → `settle` → `Ruling` → `land` is the judged path; `play` is the
/// router that picks the path from whose move it is and what is already on the board.
///
/// What both intakes do once a move stands is one routine (`stoodOnBoard`): the badge or the
/// owed judgement, the stale Analysis, the 试招 riding onto the move, the save, the reply on
/// the record, the next search. It was written out twice and had drifted.
///
/// Why an extension and not a module: landing is the session's own effects — `game`,
/// `cursor`, `activity`, `save`, `retune`, the 惩罚 exercise — and a `Landing` type would
/// be an adapter over those facts rather than a deep module. `Ruling` already owns the
/// pure decision (stand / refuse / unjudged, and the game each leaves behind). This file
/// is the locality for what the session does with that decision; the seam stays one name
/// so both intakes cannot drift.
extension GameSession {
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
    ///
    /// A `var` rather than a `let` so a test can pass `.zero` and assert the roll-back itself
    /// instead of sleeping through a gesture the test cannot see.
    static var takeBackHold = Duration.milliseconds(450)

    /// Gives the board its beat to show the move before the move is taken off it.
    private func holdTheMoveOnTheBoard() async {
        let hold = Self.takeBackHold
        guard hold > .zero, let shown = standpoint?.shown, shown < hold else { return }
        try? await Task.sleep(for: hold - shown)
    }

    var isLatestMoveMeasured: Bool {
        badge?.describes(game) ?? false
    }

    /// Badges the move just played if nothing has yet: the session asks for this itself every
    /// time it retunes, so a move that landed by any door — a hand, the engine, a held button —
    /// gets its number without a screen having to remember to ask for it.
    func measureLatestMove() {
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
                badge = LandedBadge(
                    after, change: MoveChange(before: before, after: judgement.score, isBest: judgement.best)
                )
            }
            return
        }
        guard let before = after.rewound(to: last) else { return }
        let weighed = await engine.weigh(after, from: before)
        guard !Task.isCancelled, !isWeighing, let weighed,
              game.uciMoves == after.uciMoves, game.startFEN == after.startFEN else { return }
        if game.plies[last].judgement == nil, let landed = landedUnjudged,
           landed.matches(after) {
            game.setJudgement(weighed.judgement, atPly: last)
            landedUnjudged = nil
            save()
        }
        badge = LandedBadge(
            after,
            change: MoveChange(before: weighed.scoreBefore, after: weighed.after, isBest: weighed.isBest)
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

    /// Who is putting a move down. The three ways in differ by whose move it is — which decides
    /// whether 把关 weighs it and whether a rung is written on it.
    enum Mover {
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
        // A 练习 is one answer at one position, ruled under its own 线 (docs/adr/0047). The
        // attempt owns the intake; the session only lands what comes back — the same `land` a
        // move under 把关 ends at.
        if let practice, !practice.isSettled {
            playPractice(move, into: practice, by: .hand)
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

    /// Hands the move to a 练习 and lands whatever the attempt rules. One mover into the same
    /// `land` a hand move under 把关 uses; the attempt keeps its own 线 and its own verdict.
    private func playPractice(_ move: Move, into practice: Drill, by mover: Mover) {
        guard isAtLatest, game.state.fen == practice.game.state.fen else { return }
        stopSearching()
        // The hand walking its own move is not help; the engine walking it for them is.
        if mover != .hand { practice.noteHelp() }
        switch practice.take(move) {
        case .refused:
            return
        case .unjudged(let played):
            game = played
            cursor = game.plies.count
            save()
            retune()
        case .judging(let played):
            game = played
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
        }
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

    /// The one routine a move that stands goes through, whoever put it there.
    ///
    /// `land`'s `.stands` and `commit`'s tail both end here. They had drifted — one absorbed the
    /// refusals made where the move was played from and the other did not — and the order of the
    /// rest was written out twice. The comments on each were a history of the bugs that caused
    /// (docs/adr/0037, and the "seventh copy of the 细判" this file used to write).
    ///
    /// Nothing is judged here. Every move that lands is weighed by the one 细判, and its
    /// judgement is written from that weighing in `measureLatestMoveChange` — the same act the
    /// badge reads. `owedJudgement` is for the move that landed with nothing written on it yet.
    private func stoodOnBoard(change: MoveChange?, owedJudgement: Bool) {
        if let change { badge = LandedBadge(game, change: change) }
        if owedJudgement { landedUnjudged = OfGame(game) }
        // The Analysis that described the position before this move is stale.
        analysis = nil
        // The refusals made where it was played from ride onto it as its 试招 (docs/adr/0037).
        // Idempotent: a `Ruling` has already folded its own in, and this finds nothing pending.
        absorbRefusals(atPly: cursor - 1)
        // Whatever was being said about a refusal is no longer the news.
        refused = nil
        save()
        // The reply already on the record is played if there is one.
        answerFromTheRecord()
        // And the engine is asked what it makes of the new position — whoever moved.
        retune()
    }

    /// Puts a ruling into effect. **The one door** (`land(Ruling,played:engine:)`): both 把关 and
    /// a 练习 end here — the drill's attempt and a hand move under 把关 are two intakes and one
    /// door. The game and the eye go where the ruling says; what is the session's own is the rest
    /// — the noise, the save, the badge, the exercise, the next search. A refusal gets no retune:
    /// the engine is not owed a reply to a move that came back.
    func land(_ ruling: Ruling, played: Game, engine: any Engine) {
        game = ruling.game
        cursor = ruling.cursor
        switch ruling.verdict {
        case .unjudged:
            retune()
        case .stands(let change):
            stoodOnBoard(change: change, owedJudgement: false)
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

    /// The one way a move lands without a weighing: the write, the cursor, the noise — and then
    /// the same `stoodOnBoard` a ruled move that stands ends at. A 练习 goes through
    /// `playPractice` and the same `land` a ruled move uses.
    ///
    /// `commit` used to carry the whole of its tail here as nine ordered steps, which is the
    /// ordering that had already produced a bug per step. What remains is what is genuinely this
    /// intake's own: who moved, and therefore where the move may land and what is written on it.
    func commit(_ move: Move, by mover: Mover) {
        guard !isWeighing else { return }
        // A move played is the game moving on: a 复判 of a 试招 here yields to it, unwritten.
        onStrip.cancelRejudge()
        if let practice, !practice.isSettled {
            playPractice(move, into: practice, by: mover)
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
        // Nobody weighed it: no engine, or the engine's own move. Its badge is owed.
        stoodOnBoard(change: nil, owedJudgement: true)
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

    /// A move the engine was asked for. Like a hand move in every way but one: it is not the
    /// engine's own, so no rung is written on it.
    func playAsked(_ move: Move) {
        commit(move, by: .asked)
    }

    /// A move the engine played for itself, under its own Controller.
    func playByEngine(_ move: Move) {
        commit(move, by: .engine)
    }

}
