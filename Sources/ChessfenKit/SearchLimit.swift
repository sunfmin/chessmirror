import Foundation

/// 搜索预算: how long and how deep every live position search goes, and which end stops it
/// (CONTEXT.md).
///
/// One for the whole app — 细判, the engine's own move, the finder and a move a thumb asked for
/// are all this one search (docs/adr/0039) — so that a 掉幅 means the same thing wherever it was
/// measured. A 复判 goes past it by a fixed rule rather than by a second setting: eight plies
/// deeper and six times as long, which at the standard budget is the depth 28 within a minute
/// that docs/adr/0041 names.
public struct SearchLimit: Hashable, Sendable {
    /// Which end of the budget ends the search.
    public enum Stop: String, CaseIterable, Sendable {
        /// Whichever arrives first, the time or the depth.
        case either
        /// The time alone: the search goes as deep as it gets in that time.
        case time
        /// The depth alone, however long it takes.
        case depth
    }

    public var seconds: Int
    public var depth: Int
    public var stop: Stop

    public init(seconds: Int, depth: Int, stop: Stop = .either) {
        self.seconds = seconds
        self.depth = depth
        self.stop = stop
    }

    /// Ten seconds or depth twenty, whichever comes first (docs/adr/0020, docs/adr/0039).
    public static let standard = SearchLimit(seconds: 10, depth: 20)

    /// What either dial is offered. Steps, not a slider: a second here or there is nothing
    /// anybody can feel, and the depths are the ones a phone reaches in the time beside them.
    public static let secondsChoices = [1, 2, 3, 5, 10, 15, 20, 30, 60]
    public static let depthChoices = [8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30]

    /// The budget as an engine is asked for it.
    public var budget: SearchBudget {
        switch stop {
        case .either: .timeOrDepth(.seconds(seconds), depth)
        case .time: .time(.seconds(seconds))
        case .depth: .depth(depth)
        }
    }

    /// What a 复判 takes both ends of a 试招 to: eight deeper and six times as long, stopped the
    /// same way.
    public var deeper: SearchLimit {
        SearchLimit(seconds: seconds * 6, depth: depth + 8, stop: stop)
    }

    /// 「10 秒 / 20 层」, or the one end that counts.
    public var label: String {
        switch stop {
        case .either: localized("search.limit.either", seconds, depth)
        case .time: localized("search.seconds", seconds)
        case .depth: localized("search.plies", depth)
        }
    }

    /// `10 20 either`: the three as one line for a store that keeps strings.
    public var text: String { "\(seconds) \(depth) \(stop.rawValue)" }

    /// Nil for anything that is not three sound parts.
    public init?(text: String) {
        let parts = text.split(separator: " ")
        guard parts.count == 3,
              let seconds = Int(parts[0]), seconds > 0,
              let depth = Int(parts[1]), depth > 0,
              let stop = Stop(rawValue: String(parts[2])) else { return nil }
        self.init(seconds: seconds, depth: depth, stop: stop)
    }
}
