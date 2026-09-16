import Foundation

extension Game {
    /// One position the player moved at, and everything that happened there: the 试招 refused,
    /// the move that stood if one has, and what the Review wanted instead.
    ///
    /// The one walk under both readings of a game's mistakes — the game's own list of 错招
    /// (`slips(by:lines:)`) and the 错题本's Encounters — which used to be two walks of the same
    /// shape that agreed by care, with the library counting positions through a third. Nothing
    /// here decides what counts as wrong: that is each reader's gate, and the gates differ on
    /// purpose (docs/adr/0016, docs/adr/0036).
    public struct Stop: Hashable, Sendable {
        /// The Ply a move played here takes, counting from one — the record strip's number.
        public let ply: Int
        /// The position, as the 错题本 keys one.
        public let position: PositionKey
        /// The 试招 refused here, in the order they were refused.
        public let tried: [Ply.Tried]
        /// The move that stood here; nil at the position the game ends on, where refusals are
        /// still waiting for one (docs/adr/0037).
        public let move: Ply?
        /// What the Review wanted here, when a Line was kept. Nil rather than guessed.
        public let wanted: String?

        /// One wrong move made at this position: a 试招 把关 took back, or the move that stood
        /// when it stood too expensively. The one shape under a 错招's list and a 错题's
        /// 遭遇 — the two readers keep their own gates over it (docs/adr/0036), and this is
        /// what a gate lets through.
        public struct Wrong: Hashable, Sendable {
            public let san: String
            /// What it cost, in percentage points of win probability (docs/adr/0027).
            public let drop: Double
            /// True when this is one 把关 took back, rather than the move that stood.
            public let wasTried: Bool
            /// Which of the 试招 at this position, in the order they were refused; nil for the
            /// move that stood.
            public let attempt: Int?
            /// A 试招 the player did not find for themselves.
            public let notFound: Bool

            public init(san: String, drop: Double, wasTried: Bool, attempt: Int? = nil, notFound: Bool = false) {
                self.san = san
                self.drop = drop
                self.wasTried = wasTried
                self.attempt = attempt
                self.notFound = notFound
            }
        }

        /// Everything wrong that happened here, in the order it happened: the 试招 the 记录线
        /// writes down, and then the move that stood if `stood` names what it cost and that
        /// is over the line too. Which cost a stood move is read by — the `[%judged]` 把关
        /// wrote, or a Review's number alone — is the reader's question, and is handed in.
        public func wrong(recordedBy lines: JudgementLines, stood: Double?) -> [Wrong] {
            var wrong = tried.enumerated()
                .filter { lines.records($0.element.drop) }
                .map { Wrong(san: $0.element.san, drop: $0.element.drop, wasTried: true, attempt: $0.offset, notFound: $0.element.notFound) }
            if let move, let stood, lines.records(stood) {
                wrong.append(Wrong(san: move.san, drop: stood, wasTried: false))
            }
            return wrong
        }
    }

    /// Every position one of `mine` moved at, in the order the game reached them — the moves
    /// that stood, and then the position the game ends on if refusals are still waiting there.
    ///
    /// Only the sides the player actually moved: a game where the engine had Black is a game
    /// where Black's mistakes belong to Stockfish.
    ///
    /// Walked forward once rather than rewound per Ply: `rewound(to:)` replays from the start
    /// every time it is called, which over a whole game is a quadratic number of rules probes
    /// (docs/adr/0003) — the cost this derivation is trying not to pay on every screen.
    public func stops(by mine: Set<PieceColour>) -> [Stop] {
        guard !mine.isEmpty, var walked = rewound(to: 0) else { return [] }
        var stops: [Stop] = []
        for (index, ply) in plies.enumerated() {
            let fen = walked.state.fen
            guard walked.apply(uci: ply.uci) else { break }
            let number = index + 1
            guard mine.contains(mover(ofPly: number)), let key = PositionKey(fen: fen) else {
                continue
            }
            stops.append(
                Stop(
                    ply: number, position: key, tried: ply.tried, move: ply,
                    wanted: reviewLine(atPly: index).first
                )
            )
        }
        // And the refusals no move has absorbed, written at the position they happened at rather
        // than onto a move (docs/adr/0037). **The commonest 错题 there is**: the player reaches
        // for something, 正着 takes it back, and they put the phone down — the game ends with the
        // refusal as the last thing in it, and no move ever comes along to carry it. The side to
        // move there is the side that got it wrong, named by the Ply a move played there would
        // take.
        for pending in pendingTried {
            guard !pending.tries.isEmpty, mine.contains(mover(ofPly: pending.ply + 1)),
                let at = rewound(to: pending.ply), let key = PositionKey(fen: at.state.fen)
            else { continue }
            stops.append(
                Stop(
                    ply: pending.ply + 1, position: key, tried: pending.tries, move: nil,
                    wanted: reviewLine(atPly: pending.ply).first
                )
            )
        }
        return stops.sorted { $0.ply < $1.ply }
    }
}

extension Encounter {
    /// The Ply to open the game at to read this one.
    ///
    /// A move that stood opens on the position *after* it, with the blunder on the board — that
    /// is what reading a game wants (docs/adr/0036). A move 正着 took back never stood, so there
    /// is no position after it: the board it belongs to is the one it was played from, which is
    /// also the one to try again from.
    public var arrivalPly: Int { attempt == nil ? ply : ply - 1 }
}
