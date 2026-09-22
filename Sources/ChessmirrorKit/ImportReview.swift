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

        /// What the file's `ReviewSift` tag says when imported scores were used to prioritise.
        ///
        /// The threshold is spelled into the tag because the file is the storage (docs/adr/0010)
        /// and a later reader has to know which rule produced the order — and it is spelled from
        /// `siftThreshold` rather than beside it, because a threshold that moved while the string
        /// stood still is a tag that lies about the file. The shape is stable: `7.0` reads as `7`.
        public static var siftTag: String {
            "imported-eval-\(Int(siftThreshold))-priority"
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

    /// How far a Review has got: positions settled out of the positions it has to settle. Reported
    /// as it goes, so a screen can say something truer than 「正在分析」 for a game of eighty moves.
    public struct Progress: Hashable, Sendable {
        public let judged: Int
        public let total: Int

        public init(judged: Int, total: Int) {
            self.judged = judged
            self.total = total
        }

        public var fraction: Double { total > 0 ? Double(judged) / Double(total) : 0 }
    }

    public static func judge(
        _ pgn: PGN, using engine: any Engine,
        progress: @escaping @MainActor (Progress) -> Void = { _ in }
    ) async throws -> PGN {
        let plan = plan(for: pgn.game)
        // One result per position the plan visits: the Score and the continuation the same
        // search produced. A position settled without a search, or a search with nothing to
        // say, keeps an empty line — never a second pass to go and fetch one (docs/adr/0021).
        var found: [Int: ReviewedPly] = [:]
        await progress(Progress(judged: 0, total: plan.positions.count))
        for ply in plan.positions {
            try Task.checkCancellation()
            guard let position = pgn.game.rewound(to: ply) else { throw Failure.incompleteSearch(ply) }
            if let settled = position.state.outcomeScore {
                found[ply] = ReviewedPly(score: settled)
            } else {
                let snapshot = await engine.analyseInBackground(position, depth: depth)
                try Task.checkCancellation()
                if snapshot?.depth == depth, snapshot?.isPartial == false, let score = snapshot?.best?.score {
                    let line = Array((snapshot?.best?.san ?? []).prefix(Game.Ply.lineLimit))
                    found[ply] = ReviewedPly(score: score, line: line)
                }
            }
            guard found[ply] != nil else { throw Failure.incompleteSearch(ply) }
            await progress(Progress(judged: found.count, total: plan.positions.count))
        }
        var result = pgn
        result.game.applyReview(
            pgn.game.plies.indices.map { found[$0 + 1] ?? ReviewedPly(score: nil) },
            startEvaluation: found[0]?.score, depth: depth
        )
        result.setTag(PGN.Tags.reviewSift, to: plan.usesImportedScores ? Plan.siftTag : "full-local")
        return result
    }
}
