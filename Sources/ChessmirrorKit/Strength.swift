import Foundation

/// 棋力 — the Elo the engine is bound to for its own moves, picked from a fixed ladder
/// (CONTEXT.md, docs/adr/0038).
///
/// It shapes the opponent and nothing else: 细判 weighs every move at full strength whatever the
/// 棋力, and so do hints, cards and the finder, so a 掉幅 means the same thing at every rung. 满力
/// is unbound — ADR 0009's opponent, as strong as the clock lets it be — and is the default until
/// the player first picks a rung.
///
/// Elo rather than depth, because Elo is the number players already talk in, and an engine bound
/// this way errs the way a weaker human does where a depth-limited one is sharp tactically and
/// blind to the long game.
public enum Strength: Hashable, Sendable {
    /// Unbound.
    case full
    /// Bound to an Elo with Stockfish's own `UCI_LimitStrength` and `UCI_Elo`.
    case elo(Int)

    /// What the engine's bar calls the engine at this rung: 「Stockfish 18 · 1800」, or the name
    /// alone at 满力 (docs/adr/0038).
    public var engineName: String {
        let name = Controller.engine.playerName
        return self == .full ? name : "\(name) · \(label)"
    }

    /// The rungs on offer, weakest first and 满力 last. A short list of round numbers, because
    /// this is picked with a thumb between moves and every rung is a row on the 连正榜.
    public static let ladder: [Strength] = [
        .elo(1400), .elo(1600), .elo(1800), .elo(2000), .elo(2200), .elo(2500), .elo(2800), .full,
    ]

    /// What Stockfish 18 accepts for `UCI_Elo`.
    public static let eloRange = 1320...3190

    public var elo: Int? {
        if case .elo(let elo) = self { return elo }
        return nil
    }

    /// `1800`, or 满力 in whatever language the app is speaking.
    public var label: String {
        switch self {
        case .full: localized("strength.full")
        case .elo(let elo): String(elo)
        }
    }

    /// The rung as a file or a setting writes it: `full`, or the Elo. Not localized, because it is
    /// read back out of a file that may be opened in another language.
    public var text: String { elo.map(String.init) ?? "full" }

    public init?(text: String) {
        if text == "full" {
            self = .full
            return
        }
        guard let elo = Int(text), Self.eloRange.contains(elo) else { return nil }
        self = .elo(elo)
    }
}
