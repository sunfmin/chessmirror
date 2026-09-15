/// What the player says a move was **for**: one verb and one target Square, declared by whoever
/// played the Ply (docs/adr/0018).
///
/// The shape is the whole point. A verb with a target can be drawn on the board — an arrow and a
/// ring — and can be told false by the rules code; freeform words can be neither, which is why
/// there is no free text here and never will be. The vocabulary is fixed and small, and the rule
/// that produced it is worth keeping if it is ever edited: **a verb that cannot be wrong does not
/// get a slot.**
public enum Intent: Hashable, Sendable {
    /// A claim about a Square, which the rules code can agree or disagree with.
    case claim(Verb, Square)
    /// 说不清 — no reason at all.
    ///
    /// Recorded rather than skipped. A Game with twenty-five of these is itself the whole
    /// diagnosis, and it is a diagnosis no engine could have produced: an engine can say a move
    /// was bad, and only the player can say they had no idea why they played it.
    case unclear

    /// The seven things a move can be *for*. Each one claims something that can turn out false.
    ///
    /// 将 is not here, and its absence is the rule: the app already knows whether a move gives
    /// check, so declaring it could never be wrong and so teaches nothing. 吃 is here because its
    /// claim is not "this is a capture" — that is also unfalsifiable — but "I win material here",
    /// which the exchange value can call false.
    public enum Verb: String, Hashable, Sendable, CaseIterable {
        /// 吃 — I win material on that square.
        case take
        /// 换 — this is a trade that does not lose.
        case trade
        /// 攻 — I now threaten that piece and it cannot hold: outnumbered, or taking it
        /// would win material — a pawn looking at a queen.
        case attack
        /// 护 — that piece or square now has one more defender.
        case defend = "def"
        /// 躲 — this piece was hanging, and on that square it is not.
        case flee
        /// 挡 — I interposed on a line by stepping onto that square.
        case block
        /// 占 — I hold that square more than the opponent does.
        case hold

        /// What it is called on screen. One character each, because a row of eight has to fit on
        /// a phone beside the board rather than under it.
        public var label: String {
            switch self {
            case .take: localized("verb.take")
            case .trade: localized("verb.trade")
            case .attack: localized("verb.attack")
            case .defend: localized("verb.defend")
            case .flee: localized("verb.flee")
            case .block: localized("verb.block")
            case .hold: localized("verb.hold")
            }
        }
    }

    /// 说不清's own name on screen, so the eighth button is written from the same place as the
    /// other seven.
    public static var unclearLabel: String { localized("intent.unclear") }

    public var verb: Verb? {
        switch self {
        case .claim(let verb, _): verb
        case .unclear: nil
        }
    }

    public var target: Square? {
        switch self {
        case .claim(_, let square): square
        case .unclear: nil
        }
    }

    public var label: String {
        switch self {
        case .claim(let verb, let square): "\(verb.label) \(square)"
        case .unclear: Self.unclearLabel
        }
    }

    /// The coarse reason a move is played, for 这步的要害: 进攻 or 防御, and 交换 / 占位 when
    /// neither fits. The seven verbs stay the checkable claim; this is how they are said as a goal.
    public var goal: String {
        switch self {
        case .claim(.take, _), .claim(.attack, _): "进攻"
        case .claim(.defend, _), .claim(.flee, _), .claim(.block, _): "防御"
        case .claim(.trade, _): "交换"
        case .claim(.hold, _): "占位"
        case .unclear: Self.unclearLabel
        }
    }

    // ------------------------------------------------------------------ the wire

    /// What goes inside `{[%int …]}`: `def f7`, or `?` for 说不清.
    public var pgnText: String {
        switch self {
        case .claim(let verb, let square): "\(verb.rawValue) \(square)"
        case .unclear: "?"
        }
    }

    /// Reads what was inside `{[%int …]}`. Nil for anything this app does not recognise — an
    /// unknown verb, a target that is not a square, a verb with no target at all.
    ///
    /// Nil rather than an error, because a file this app did not write must still open. The
    /// vocabulary here is small and fixed, and the whole point of the fixed vocabulary is that a
    /// token outside it cannot be checked and so cannot be kept.
    public init?(pgnText: String) {
        let words = pgnText.split(whereSeparator: \.isWhitespace).map(String.init)
        if words == ["?"] {
            self = .unclear
            return
        }
        guard words.count == 2, let verb = Verb(rawValue: words[0].lowercased()),
            let square = Square(words[1].lowercased())
        else { return nil }
        self = .claim(verb, square)
    }
}
