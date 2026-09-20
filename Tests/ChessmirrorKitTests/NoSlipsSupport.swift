@testable import ChessmirrorKit

extension GameSession {
    /// 把关 on, with the 记录线 — which is where it stops the player (docs/adr/0046) — drawn at
    /// `line`. The 入列线 is lifted with it when it has to be: it never sits below the 记录线.
    func noSlips(at line: Double) {
        setLines(JudgementLines(noSlips: true, record: line, enqueue: max(lines.enqueue, line)))
    }
}
