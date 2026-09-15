/// A shot for the side to move that wins material or mates (docs/adr/0023).
///
/// The rules propose and a short search disposes, the same two-net order as 要害格. The
/// sentence is a template over facts the rules code can check — in the seven Intent verbs
/// where they fit — so the app can be told it was wrong. Motif names do not get a slot.
public struct Tactic: Hashable, Sendable {
    public let move: Move
    public let san: String
    public let intent: Intent
    public let sentence: String
    /// SAN from this position, when a search produced a continuation. Empty for a rules-only
    /// proposal that has not been confirmed, and for a one-move shot.
    public let line: [String]

    /// The Depth the confirming search is asked for. Shallow enough to finish before an
    /// engine reply, deep enough to see a short combination.
    public static let probeDepth = 10

    /// How much better the Best Move has to be than the second, in centipawns for the side
    /// to move, before a line the rules did not name counts as a Tactic. The same band
    /// `MoveQuality` calls a 失误 — quieter gaps are just a preference.
    public static let uniqueGain = 150

    /// What the rules can see, with no search. Nil when none of the legal moves is a mate,
    /// a winning capture, or a double attack.
    public static func proposed(in game: Game) -> Tactic? {
        game.state.legalMoves.compactMap { shot(from: $0, in: game) }.min { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.booty != b.booty { return a.booty > b.booty }
            return a.tactic.move.uci < b.tactic.move.uci
        }?.tactic
    }

    /// The rules' shot, if the engine would play it; otherwise a unique forcing line the
    /// rules did not name; otherwise nothing.
    public static func confirmed(in game: Game, analysis: Analysis) -> Tactic? {
        guard let best = analysis.best, let uci = best.bestMove,
            let move = game.state.move(matching: uci)
        else { return nil }
        let san = SAN.text(for: move, in: game.state)
        let proposal = proposed(in: game)

        if let proposal, proposal.move.uci == uci {
            return Tactic(
                move: proposal.move,
                san: proposal.san,
                intent: proposal.intent,
                sentence: proposal.sentence,
                line: best.san.isEmpty ? [san] : best.san
            )
        }

        let unique: Bool
        if case .mate = best.score {
            unique = true
        } else if analysis.lines.count >= 2 {
            let swing =
                MoveQuality.centipawns(best.score)
                - MoveQuality.centipawns(analysis.lines[1].score)
            let forMover = game.state.sideToMove == .white ? swing : -swing
            unique = forMover >= uniqueGain
        } else {
            unique = false
        }
        guard unique else { return nil }

        if move.isCheckmate {
            return Tactic(
                move: move, san: san, intent: .unclear, sentence: "\(san) 杀",
                line: best.san.isEmpty ? [san] : best.san
            )
        }
        let intent = Intent.read(move, in: game)
        let reading = game.reading(of: best.san)
        let sentence: String
        if let reading, reading.opening.intent != .unclear {
            sentence = "\(san)：\(reading.sentence)"
        } else if intent != .unclear {
            sentence = "\(san) \(intent.label)"
        } else {
            sentence = san
        }
        return Tactic(
            move: move, san: san, intent: intent, sentence: sentence,
            line: best.san.isEmpty ? [san] : best.san
        )
    }

    private struct Shot {
        var tactic: Tactic
        /// 0 mate, 1 winning capture, 2 double attack.
        var rank: Int
        /// Material the shot takes, for a tie inside a rank. Mate is off the scale.
        var booty: Int
    }

    private static func shot(from move: Move, in game: Game) -> Shot? {
        let san = SAN.text(for: move, in: game.state)
        if move.isCheckmate {
            return Shot(
                tactic: Tactic(
                    move: move, san: san, intent: .unclear, sentence: "\(san) 杀", line: [san]
                ),
                rank: 0,
                booty: 100
            )
        }

        let opponent = game.state.sideToMove.opposite
        guard let pieces = BoardRenderer.placement(game.state.fen) else { return nil }
        let capturedSquare =
            move.isEnPassant
            ? Square(file: move.to.file, rank: move.from.rank) : move.to

        if move.isCapture,
            Rules.exchangeValue(startFEN: game.startFEN, moves: game.uciMoves, uci: move.uci)
                == .winning
        {
            let kind = pieces[capturedSquare]?.kind
            let hanging = game.loosePieces(of: opponent)?.contains(capturedSquare) ?? false
            let what = kind.map(\.name) ?? "子"
            let sentence =
                hanging
                ? "\(san) 吃 \(capturedSquare) 上没人守的\(what)"
                : "\(san) 吃 \(capturedSquare) 的\(what)，这笔赚"
            return Shot(
                tactic: Tactic(
                    move: move,
                    san: san,
                    intent: .claim(.take, capturedSquare),
                    sentence: sentence,
                    line: [san]
                ),
                rank: 1,
                booty: Int(kind?.rawValue ?? 0)
            )
        }

        var after = game
        guard after.apply(move) else { return nil }
        let beforeLoose = game.loosePieces(of: opponent) ?? []
        let afterLoose = after.loosePieces(of: opponent) ?? []
        let newly = afterLoose.subtracting(beforeLoose)
        let fork = newly.count >= 2 || (move.givesCheck && !newly.isEmpty)
        guard fork, let afterPieces = BoardRenderer.placement(after.state.fen) else { return nil }

        var named: [(Square, Piece)] = []
        if move.givesCheck, let king = afterPieces.first(where: {
            $0.value.kind == .king && $0.value.colour == opponent
        }) {
            named.append(king)
        }
        let rest = newly.compactMap { square -> (Square, Piece)? in
            afterPieces[square].map { (square, $0) }
        }
        .sorted { a, b in
            if a.1.kind.rawValue != b.1.kind.rawValue {
                return a.1.kind.rawValue > b.1.kind.rawValue
            }
            return a.0.index < b.0.index
        }
        for piece in rest where !named.contains(where: { $0.0 == piece.0 }) {
            named.append(piece)
            if named.count == 2 { break }
        }
        guard named.count >= 2 else { return nil }
        let clause = named.map { "\($0.0) 的\($0.1.kind.name)" }.joined(separator: "和")
        return Shot(
            tactic: Tactic(
                move: move,
                san: san,
                intent: .claim(.attack, named[1].0),
                sentence: "\(san) 同时打了\(clause)",
                line: [san]
            ),
            rank: 2,
            booty: named.map { Int($0.1.kind.rawValue) }.reduce(0, +)
        )
    }
}
