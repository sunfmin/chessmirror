import ChessfenKit
import SwiftUI
import Testing

@testable import Chessfen

/// The deck under the board, one card per picture (docs/adr/0025).
///
/// Two cards, two PNGs, each with something real on it — a mate with its line numbered on the
/// board, and a shot the engine found. The other suite photographs the *screen* in the states a
/// game passes through; this one photographs the *cards*, side by side and comparable, which is
/// what anybody redesigning them has to be able to lay out on a table.
///
/// So the assertions here are deliberately thin: each says only that the card it named is the card
/// that drew and that the thing it exists to show is on it. The pictures are the point.
@MainActor
@Suite(.serialized, .speaking(.chinese))
struct DeckGallery {
    private func hop() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func screen(
        _ session: GameSession, engine: any Engine, opening: GameScreen.Card
    ) -> some View {
        NavigationStack {
            GameScreen(session: session, path: .constant([]), opening: opening)
        }
        .environment(EngineHost(engine))
        .environment(GameLibrary())
    }

    // ------------------------------------------------------------------ 1 · 杀招

    @Test("1 · 杀招 — the news, with the line numbered on the board")
    func mate() async throws {
        // Morphy's opera game before 16.Qb8+: White mates in two and Black's reply is forced.
        let game = try #require(Game(startFEN: "4kb1r/p2n1ppp/4q3/4p1B1/4P3/1Q6/PPP2PPP/2KR4 w - - 0 1"))
        let engine = ScriptedEngine(
            [],
            byPosition: [
                game.state.fen: Analysis(
                    depth: 10,
                    lines: [
                        Line(
                            score: .mate(in: 2),
                            uciMoves: ["b3b8", "d7b8", "d1d8"],
                            san: ["Qb8+", "Nxb8", "Rd8#"]
                        )
                    ]
                )
            ]
        )
        let session = GameSession.fresh(game, controllers: [.white: .hand, .black: .engine])
        session.attach(engine: engine, library: nil)
        await hop()

        let rendered = await ScreenImage.write("deck-01-mate") {
            screen(session, engine: engine, opening: .mate)
        }
        #expect(rendered.says("你有 2 步杀"))
        #expect(rendered.says("Rd8#"))
    }

    // ------------------------------------------------------------------ 2 · 战术

    @Test("2 · 战术 — one shot the engine found")
    func tactics() async throws {
        let game = try #require(Game(startFEN: "4k3/8/8/3r4/8/8/8/3QK3 w - - 0 1"))
        let engine = ScriptedEngine(
            [],
            byPosition: [
                game.state.fen: Analysis(
                    depth: 10,
                    lines: [
                        Line(score: .centipawns(500), uciMoves: ["d1d5"], san: ["Qxd5"]),
                        Line(score: .centipawns(20), uciMoves: ["e1d2"], san: ["Kd2"]),
                    ]
                )
            ]
        )
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)

        let rendered = await ScreenImage.write("deck-02-tactics") {
            screen(session, engine: engine, opening: .tactics)
        }
        await hop()
        #expect(rendered.says("战术"))
    }
}
