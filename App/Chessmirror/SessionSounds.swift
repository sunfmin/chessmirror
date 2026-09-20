import ChessmirrorKit

extension Feedback {
    /// What a session's event sounds like.
    ///
    /// Here rather than in the session, which says what happened and nothing about a speaker
    /// (`GameSession.Event`). A fork gets the rising two-tone a check gets: a line leaving the
    /// one it was played over is worth a noise of its own, and that is the noise that means
    /// "look".
    func hear(_ event: GameSession.Event) {
        switch event {
        case .landed(let move, let outcome): play(move, outcome: outcome)
        case .refused: play(.refused)
        case .forked: play(.check)
        case .stepped: play(.move)
        }
    }
}
