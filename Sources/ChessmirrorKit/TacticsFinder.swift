/// The tactics finder: the switch, the shot it currently names, and the one bounded search
/// that confirms one (docs/adr/0023, docs/adr/0025).
///
/// Four facts that only ever change together — a shot was found *for a position*, by *a search
/// of that position*, and both stop being true the moment the eye moves. Kept apart on the
/// session they needed the cursor to clear all four by hand, in one place and then another.
/// Here the position moving on is one sentence, `forget()`, and there is no fifth place that
/// remembers half of it.
///
/// It owns no engine. The probe is the session's one shared search of the position on screen —
/// a finder that ran its own would be competing with the session for the same engine — so the
/// session drives the search and tells the finder what came back.
struct TacticsFinder {
    /// Whether a Tactic may be named at all (docs/adr/0023). Off at the start of every Game,
    /// never written to PGN.
    private(set) var isOn = false
    /// The shot the finder currently names, if the last probe found one.
    private(set) var tactic: Tactic?
    /// True while the short search that confirms a Tactic is running.
    private(set) var isProbing = false
    /// The probe's own Analysis, kept only so a mate it happened to see can be reported.
    ///
    /// The finder's search is not advice — it is bounded, it was asked a question about shots, and
    /// practice is allowed to keep it (docs/adr/0023). A mate in it is news, and news is not the
    /// engine's opinion either, so it may be read out where a Score may not (docs/adr/0025). What
    /// is *not* kept is a Score, a Depth or a candidate list: nothing else in here reaches a screen.
    private(set) var probedAnalysis: Analysis?

    /// Throws the switch on. Nothing is named yet: the caller has a position to probe first.
    mutating func turnOn() {
        isOn = true
    }

    /// Throws the switch off, and with it everything the finder was saying. A switch that is off
    /// is not a switch somebody's swipe may throw back — that is what arriving is for.
    mutating func turnOff() {
        isOn = false
        forget()
    }

    /// Records that the switch went on because somebody swiped onto the finder's cards, so that
    /// swiping away again puts it back. Called after the switch has been thrown: a switch that

    /// The position on screen has changed. A shot found here was found for *this* position, and
    /// so was the search that confirmed it.
    mutating func forget() {
        tactic = nil
        isProbing = false
        probedAnalysis = nil
    }

    /// What the rules alone can see, while the search that will confirm or replace it runs.
    mutating func propose(in game: Game) {
        tactic = Tactic.proposed(in: game)
        isProbing = true
    }

    /// What the rules and a finished search agree on. Leaves the probe running as far as the
    /// finder is concerned: a standing Analysis arriving mid-probe answers the question early
    /// without ending the search that was asked it.
    mutating func confirm(in game: Game, analysis: Analysis) {
        tactic = Tactic.confirmed(in: game, analysis: analysis)
        probedAnalysis = analysis
    }

    /// The probe is over, whatever it found.
    mutating func settle() {
        isProbing = false
    }

    /// What the strip under the board should say. Nil when the finder is off.
    func prompt(ourTurn: Bool) -> String? {
        guard isOn else { return nil }
        if isProbing, tactic == nil { return localized("finder.checking") }
        if let tactic {
            let whose = localized(ourTurn ? "finder.ours" : "finder.theirs")
            return "\(whose)：\(tactic.sentence)"
        }
        return localized("finder.none")
    }
}
