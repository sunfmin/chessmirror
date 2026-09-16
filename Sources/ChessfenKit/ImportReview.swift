import Foundation

/// Imported scores prioritize the local pass; they never exclude a position or supply a verdict.
public enum ImportReview {
    public static let depth = 16
    public static let siftThreshold = 7.0

    public struct Plan: Equatable, Sendable {
        /// Every one-based move, with imported suspects first when scores are available.
        public let plies: [Int]
        public let usesImportedScores: Bool
        public var positions: [Int] {
            var seen: Set<Int> = []
            return plies.flatMap { [$0 - 1, $0] }.filter { seen.insert($0).inserted }
        }
    }

    public static func plan(for game: Game) -> Plan {
        guard !game.plies.isEmpty else { return Plan(plies: [], usesImportedScores: false) }
        guard game.plies.allSatisfy({ $0.importedEvaluation != nil }) else {
            return Plan(plies: Array(1...game.plies.count), usesImportedScores: false)
        }
        // The imported starting evaluation is not retained by older files, so always judge
        // the first move locally instead of inventing a zero baseline.
        var candidates = [1]
        for index in game.plies.indices.dropFirst() {
            if let drop = MoveQuality.drop(move: game.mover(ofPly: index + 1),
                                          before: game.plies[index - 1].importedEvaluation,
                                          after: game.plies[index].importedEvaluation),
               drop >= siftThreshold {
                candidates.append(index + 1)
            }
        }
        let prioritized = Set(candidates)
        let remainder = (1...game.plies.count).filter { !prioritized.contains($0) }
        return Plan(plies: candidates + remainder, usesImportedScores: true)
    }

    public enum Failure: Error { case incompleteSearch(Int) }

    public static func judge(_ pgn: PGN, using engine: any Engine) async throws -> PGN {
        let plan = plan(for: pgn.game)
        var scores: [Int: Score] = [:]
        for ply in plan.positions {
            try Task.checkCancellation()
            guard let position = pgn.game.rewound(to: ply) else { throw Failure.incompleteSearch(ply) }
            if let settled = position.state.outcomeScore {
                scores[ply] = settled
            } else {
                let snapshot = await engine.analyseInBackground(position, depth: depth)
                try Task.checkCancellation()
                if snapshot?.depth == depth, snapshot?.isPartial == false {
                    scores[ply] = snapshot?.best?.score
                }
            }
            guard scores[ply] != nil else { throw Failure.incompleteSearch(ply) }
        }
        var result = pgn
        result.game.applyReview(pgn.game.plies.indices.map { scores[$0 + 1] },
                                startEvaluation: scores[0], depth: depth)
        result.setTag("ReviewSift", to: plan.usesImportedScores ? "imported-eval-7-priority" : "full-local")
        return result
    }
}
