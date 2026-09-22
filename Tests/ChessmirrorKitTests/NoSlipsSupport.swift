@testable import ChessmirrorKit

extension GameSession {
    /// 把关 on, with the 记录线 — which is where it stops the player (docs/adr/0046) — drawn at
    /// `line`. The rule lives on `JudgementLines.noSlips(at:enqueue:)`; this only hands it over.
    func noSlips(at line: Double) {
        setLines(.noSlips(at: line, enqueue: lines.enqueue))
    }
}
