/// A mate the engine can already see from the position on screen, whoever it belongs to
/// (docs/adr/0024).
///
/// The one thing on this screen that is **news** rather than an answer: nobody asked for it, and
/// it is not the engine's opinion — a Score is a judgement and 「你三步之后不在了」 is a fact. That
/// is the whole of why it is allowed to appear unbidden where a Score is not (docs/adr/0015).
///
/// Whose it is comes out of the sign of one number: a Score is always White-relative, so
/// `.mate(in: +2)` is White mating in two and `.mate(in: -2)` is White being mated in two. There
/// is no second code path for 「对方的杀」 — there is one number, and who holds which Controller
/// decides which sentence it is read out in.
///
/// Every clause of that sentence is a fact the rules code counted: how many moves, what the first
/// move is, how many of the answers to it are the only legal move there is, and whether the line
/// the engine handed over actually ends in mate. Nothing here is prose about the position, so the
/// app can be told it was wrong.
public struct MateNews: Hashable, Sendable {
    /// Moves to the mate, always positive. Whose it is, `isOurs` says.
    public let moves: Int
    /// The colour that delivers it — not necessarily the one to move.
    public let mater: PieceColour
    /// Whether the mating side is one a person is playing. False both when the mate is against
    /// the player and when nobody is playing by hand at all; `head` tells those two apart.
    public let isOurs: Bool
    /// The mating line in SAN, as far as the engine gave it.
    public let san: [String]
    /// The line as numbered arrows, in the same violet-and-red the five-move plan is drawn in.
    public let arrows: [PlanArrow]
    /// How many of the replies to the mating side's moves were the only legal move on the board.
    public let forcedReplies: Int
    /// How many replies there are in the line at all, so the count above has a denominator.
    public let replies: Int
    /// Whether the line the engine gave actually reaches the mate. A mate Score with a line that
    /// stops short is a real thing to be told, and a different thing from being shown the mate.
    public let reachesMate: Bool
    /// Whether every ply of the line got an arrow, or the board would have been a scribble.
    public let isFullyDrawn: Bool

    /// The headline: who, and in how many.
    public let head: String
    /// One sentence of checkable clauses about how it goes.
    public let sentence: String

    /// How many plies may be drawn at once. Five moves of arrows is already the most a board can
    /// carry — 五步计划 stops at five for what can be *checked* (docs/adr/0018), and this stops at
    /// six for what can be *seen*. Past that the board is a scribble and the rows are the transport.
    public static let arrowLimit = 6

    /// Reads the news out of a search that has already run.
    ///
    /// Nothing here starts a search: the caller passes whichever Analysis it already had — the
    /// standing one when the engine is talking, or the tactics probe's when it is not. `hands` is
    /// the colours a person is playing, which is the only reason this needs to know anything about
    /// the session.
    public static func read(
        _ analysis: Analysis, in game: Game, hands: Set<PieceColour>
    ) -> MateNews? {
        guard let best = analysis.best, case .mate(let signed) = best.score, signed != 0
        else { return nil }
        // A position that is already mate is not news about a mate to come.
        guard !game.state.legalMoves.isEmpty else { return nil }

        let mater: PieceColour = signed > 0 ? .white : .black
        let moves = abs(signed)
        // With nobody playing by hand — the engine against itself — the mating side is the one
        // the arrows call theirs, so a line drawn on the board still has two colours in it.
        let isYours: (PieceColour) -> Bool = { colour in
            hands.isEmpty ? colour == mater : hands.contains(colour)
        }
        let isOurs = !hands.isEmpty && hands.contains(mater)

        let san = best.san
        let opening = game.state.sideToMove
        let arrows = best.uciMoves.prefix(arrowLimit).enumerated().compactMap {
            index, uci -> PlanArrow? in
            guard let move = MoveSquares(uci: uci) else { return nil }
            let mover = index.isMultiple(of: 2) ? opening : opening.opposite
            return PlanArrow(step: index + 1, move: move, isYours: isYours(mover), isPlayed: false)
        }

        // How forced it is, counted rather than asserted: replay the line and ask the rules how
        // many moves the side being mated actually had. This is the difference between a mate
        // somebody can follow and a mate they have to take on trust.
        var replies = 0
        var forced = 0
        var ahead = game
        for (index, move) in san.enumerated() {
            let isReply = (index.isMultiple(of: 2) ? opening : opening.opposite) != mater
            if isReply {
                replies += 1
                if ahead.state.legalMoves.count == 1 { forced += 1 }
            }
            guard ahead.apply(san: move) else { break }
        }

        let reachesMate = san.last?.hasSuffix("#") ?? false
        let head = Self.head(moves: moves, mater: mater, isOurs: isOurs, hands: hands)
        let sentence = Self.sentence(
            san: san, isOurs: isOurs, hands: hands, mater: mater, opens: opening == mater,
            moves: moves, replies: replies, forced: forced, reachesMate: reachesMate
        )

        return MateNews(
            moves: moves,
            mater: mater,
            isOurs: isOurs,
            san: san,
            arrows: arrows,
            forcedReplies: forced,
            replies: replies,
            reachesMate: reachesMate,
            isFullyDrawn: arrows.count == best.uciMoves.count,
            head: head,
            sentence: sentence
        )
    }

    // ------------------------------------------------------------------ the words

    private static func head(
        moves: Int, mater: PieceColour, isOurs: Bool, hands: Set<PieceColour>
    ) -> String {
        if isOurs { return "你有 \(moves) 步杀" }
        if hands.contains(mater.opposite) { return "对方 \(moves) 步杀" }
        return "\(name(mater)) \(moves) 步杀"
    }

    private static func sentence(
        san: [String], isOurs: Bool, hands: Set<PieceColour>, mater: PieceColour, opens: Bool,
        moves: Int, replies: Int, forced: Int, reachesMate: Bool
    ) -> String {
        guard let first = san.first else {
            return "引擎报了 \(moves) 步杀，但没给着法。"
        }
        // Who does what, in the same three voices the head uses. With nobody at the board both
        // sides are named by colour, because 「你」 would be a claim about a person who is not there.
        let mover: String
        let replier: String
        if isOurs {
            mover = "你"
            replier = "对方"
        } else if hands.contains(mater.opposite) {
            mover = "对方"
            replier = "你"
        } else {
            mover = name(mater)
            replier = name(mater.opposite)
        }

        // Two shapes, because the mating side is not always the side to move. Being mated is the
        // case where the line *opens with your own best try* — reading that move out as 「起手」
        // would hand the opponent's plan your move, so the sentence says what it actually is:
        // every move loses, and this is the one the engine would still pick.
        var clauses: [String]
        if opens {
            clauses = ["\(mover)起手 \(first)"]
        } else {
            clauses = ["\(replier)怎么走都躲不掉", "引擎给的最好一手是 \(first)"]
        }
        if replies > 0, forced == replies {
            clauses.append(replies == 1 ? "\(replier)只有一个应手" : "\(replier)每一步都只有一个应手")
        } else if forced > 0 {
            clauses.append("中间\(replier)有 \(forced) 步只有一个应手")
        }
        if reachesMate, let last = san.last {
            clauses.append("\(last) 将死")
        } else {
            clauses.append("引擎只给到第 \(san.count) 步，没给到将死那一步")
        }
        return clauses.joined(separator: "，") + "。"
    }

    /// 白方 / 黑方, for the one framing that is about neither the player nor their opponent. Local
    /// rather than an extension: the app has a `chinese` of its own on this type, and two of them
    /// in scope is one too many.
    private static func name(_ colour: PieceColour) -> String {
        colour == .white ? "白方" : "黑方"
    }
}
