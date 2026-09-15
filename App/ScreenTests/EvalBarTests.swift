import ChessfenKit
import SwiftUI
import Testing
import UIKit

@testable import Chessfen

/// The advantage bar, from both ways up.
///
/// The bar is two colours and one length, and the colours are the *pieces'* colours — so which end
/// belongs to whom is decided by the board's Orientation and by nothing else. Turn the board round
/// and the bar has to turn with it, or it says the opposite of the number printed beside it. That is
/// not a thing the accessibility tree can witness: its label is 「优势条」 either way, and the number
/// beside it is White-relative either way. So this reads the pixels at both ends of the bar, in both
/// orientations — the one place on this screen where colour is the whole of the statement.
@MainActor
@Suite(.serialized, .speaking(.chinese))
struct EvalBarSides {
    /// The Italian, eight plies in.
    private static let italian = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6"]

    /// White three pawns up: about five sixths of the bar one colour and one sixth the other, so
    /// neither end can be read as the other by accident.
    private static let winning = [
        Analysis(
            depth: 22,
            selectiveDepth: 30,
            lines: [Line(score: .centipawns(300), uciMoves: ["d2d4"], san: ["d4"])],
            nodes: 20_000_000,
            nodesPerSecond: 2_400_000,
            timeMilliseconds: 8_000
        )
    ]

    @Test("the bar's ends wear the colours of the board's own sides")
    func endsFollowTheBoard() async throws {
        let whiteAtBottom = try #require(
            await shoot("eval-bar-white-at-bottom", facing: .white), "no bar in the picture"
        )
        let blackAtBottom = try #require(
            await shoot("eval-bar-black-at-bottom", facing: .black), "no bar in the picture"
        )

        #expect(
            whiteAtBottom.left > 200,
            "White at the bottom and the bar's left end is \(whiteAtBottom.left) — it should be White"
        )
        #expect(
            whiteAtBottom.right < 60,
            "White at the bottom and the bar's right end is \(whiteAtBottom.right) — it should be Black"
        )
        #expect(
            blackAtBottom.left < 60,
            "Black at the bottom and the bar's left end is \(blackAtBottom.left) — the ends are the wrong way round"
        )
        #expect(
            blackAtBottom.right > 200,
            "Black at the bottom and the bar's right end is \(blackAtBottom.right) — it should be White"
        )
    }

    // ------------------------------------------------------------------- glue

    /// One screen, one way up, with White three pawns to the good on it.
    private func shoot(_ name: String, facing: PieceColour) async throws -> (left: Int, right: Int)? {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(game, controllers: [.white: .hand, .black: .engine])
        session.orientation = .facing(facing)
        session.setPractising(false)

        let rendered = await ScreenImage.write(name) {
            NavigationStack {
                GameScreen(session: session, path: .constant([]))
            }
            .environment(EngineHost(ScriptedEngine(Self.winning, isEndless: true)))
            .environment(GameLibrary())
        }
        return ends(of: rendered.url, size: CGSize(width: 402, height: 874))
    }

    /// The brightness at each end of the advantage bar.
    ///
    /// Found by looking for the bar itself: a row whose longest run of the bar's own two colours —
    /// or of the balance mark standing in it — is over a hundred points long. The page the bar is
    /// drawn on is nearly white too, so the test is the exact colours (`barWhite` 255,252,247 and
    /// `barBlack` 36,26,18) rather than "light" and "dark": parchment is 247,237,225, which is a
    /// different thing at this tolerance. The board is wood and its pieces are ink, so a row through
    /// the board breaks that run at the first square edge. The two readings are taken a little way in
    /// from the ends of the run, so what is measured is the fill rather than the rounded end.
    private func ends(of url: URL, size: CGSize) -> (left: Int, right: Int)? {
        guard let pixels = ScreenImage.Pixels(of: url) else { return nil }
        let scale = pixels.pixelsPerPoint(of: size)

        func isBar(_ c: (r: Int, g: Int, b: Int)) -> Bool {
            let isWhite = abs(c.r - 255) <= 4 && abs(c.g - 252) <= 4 && abs(c.b - 247) <= 4
            let isBlack = abs(c.r - 36) <= 12 && abs(c.g - 26) <= 12 && abs(c.b - 18) <= 12
            let isMark = abs(c.r - 46) <= 40 && abs(c.g - 125) <= 40 && abs(c.b - 110) <= 40
            return isWhite || isBlack || isMark
        }

        func longestRun(in row: Int) -> (start: Int, end: Int) {
            var best = (start: 0, end: -1)
            var start: Int?
            for x in 0..<pixels.width {
                if isBar(pixels.colour(x: x, y: row)) {
                    if start == nil { start = x }
                } else if let from = start {
                    if x - from > best.end - best.start { best = (from, x - 1) }
                    start = nil
                }
            }
            if let from = start, pixels.width - from > best.end - best.start {
                best = (from, pixels.width - 1)
            }
            return best
        }

        let runs = (0..<pixels.height).map { (row: $0, run: longestRun(in: $0)) }
        let widest = runs.map { $0.run.end - $0.run.start }.max() ?? 0
        guard CGFloat(widest) > 100 * scale else { return nil }
        // Only the bar's own rows: the depth mark under it is the same teal, and shorter.
        let rows = runs.filter { $0.run.end - $0.run.start >= widest - 4 }.map(\.row)
        guard rows.count >= 3, let span = runs.first(where: { $0.run.end - $0.run.start == widest })
        else { return nil }

        let inset = max(4, (span.run.end - span.run.start) * 6 / 100)
        func brightness(at x: Int) -> Int {
            let values = rows.map { row -> Int in
                let colour = pixels.colour(x: x, y: row)
                return (colour.r + colour.g + colour.b) / 3
            }
            return values.reduce(0, +) / values.count
        }
        return (brightness(at: span.run.start + inset), brightness(at: span.run.end - inset))
    }
}
