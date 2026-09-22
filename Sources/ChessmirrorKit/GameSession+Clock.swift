import Foundation

/// 搜索时钟 — what the engine should be doing right now, and the one search doing it.
///
/// **Seam: `retune()`.** It answers "what should the engine be doing right now" from the
/// Game, the cursor, the two Controllers and the cards: the engine's own move, a probe for
/// a Tactic, the interception table 把关 reads, or a card's Stint. One `searchTask` at a
/// time; every way a search ends goes through `stopSearching`, so a Stint clock cannot
/// stop the search that replaced it. `beginAskedMove` / `endAskedMove` / `moveNow` are the
/// two ways a human cuts that clock short.
///
/// Why an extension and not a module: the clock's drivers reach into `activity`, `finder`,
/// `viewed` and landing (`playByEngine` → `commit`), so a standalone `EngineClock` would be
/// a god-object's guts behind a thin name. The state stays on the session so screens keep
/// reading `isSearching`, `searchProgress`, `thinking` and `analysis` without a hop; this
/// file is the locality for the search lifecycle that moves those facts.
extension GameSession {
    public var thinking: Thinking? {
        if case .thinking(let whose) = activity { whose } else { nil }
    }

    /// Whether a move of either kind is being walked.
    public var isThinking: Bool { thinking != nil }

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

    func waitForPreparedInterception() async { await searchTask?.value }

    func prepareInterception(on position: Game, using engine: any Engine) {
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

    // ----------------------------------------------------------------- engine

    /// Takes down whatever search is running, and the Stint clock with it.
    ///
    /// Every way a search ends goes through here, which is the point: a clock left ticking over a
    /// search that has already been replaced would stop the replacement — a thumb on 让引擎走 would
    /// have its move taken out from under it by the timer belonging to the advice it interrupted.
    func stopSearching() {
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
            finder.forget()
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
        finder.forget()
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
            finder.confirm(in: position, analysis: found)
            finder.settle()
            continueAfterProbe()
            return
        }
        finder.propose(in: position)
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
            if let last { finder.confirm(in: position, analysis: last) }
            finder.settle()
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
        // Not the finder: suspending is not the eye moving, and a shot named for the position
        // still on screen is still named for it.
        onStrip.close()
        // Whatever it was, it is over: the task is cancelled, the exercise skipped, the search
        // taken down. One assignment, because the activity owns what each of those kept.
        activity = .reading
    }

    func noteProgress(_ snapshot: Analysis) {
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
    func recallCachedAnalysis() -> Bool {
        guard let cached = analysisByFen[viewed.state.fen] else { return false }
        analysis = cached
        noteProgress(cached)
        return true
    }

    /// Walking the record: restore this Ply's Analysis, or clear the last one so a new
    /// position does not keep wearing the old Depth.
    func adoptViewedAnalysis() {
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
        if isFindingTactics { finder.confirm(in: viewed, analysis: snapshot) }
        // The Score stays here, on a snapshot belonging to a screen, and is not written into
        // the Game. It used to be — "provisional, a Review will overwrite it" — but a Game is
        // a file, and a file that mixes one search's incidental Depth with a Review's uniform
        // one cannot be ranked afterwards without inventing mistakes. Only a Review writes an
        // evaluation now (docs/adr/0016).
    }
}
