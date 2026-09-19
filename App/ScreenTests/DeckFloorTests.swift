import ChessmirrorKit
import SwiftUI
import Testing
import UIKit

@testable import Chessmirror
import ChessmirrorKitTesting

/// Contract: the board keeps the entire viewport width regardless of height or text size.
/// Settings start closed; bottom analysis tabs remain reachable without shrinking the board.
@MainActor
@Suite(.serialized, .speaking(.chinese))
struct DeckFloor {
    @Test func boardAlwaysUsesTheFullWidth() {
        #expect(GameScreen.boardSide(in: .zero) == 0)
        for size in [
            CGSize(width: 375, height: 667), CGSize(width: 402, height: 874),
            CGSize(width: 440, height: 956), CGSize(width: 744, height: 1133),
            CGSize(width: 1376, height: 1032),
        ] {
            #expect(GameScreen.boardSide(in: size) == size.width)
            #expect(GameScreen.boardSide(in: size, accessibilityText: true) == size.width)
        }
    }

    @Test(arguments: [false, true])
    func fullWidthBoardAndBottomTabs(largeText: Bool) async throws {
        let size = largeText ? CGSize(width: 402, height: 874) : CGSize(width: 375, height: 667)
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let engine = ScriptedEngine([Analysis(depth: 16, lines: [
            Line(score: .centipawns(0), uciMoves: ["e2e4"], san: ["e4"])
        ])])
        let session = GameSession.fresh(game, engine: engine)
        defer { session.suspend() }
        let rendered = await ScreenImage.write(largeText ? "deck-large-text" : "deck-small-phone", size: size) {
            NavigationStack {
                GameScreen(session: session, path: .constant([]))
            }
            .environment(EngineHost(engine))
            .environment(GameLibrary())
            .dynamicTypeSize(largeText ? .accessibility5 : .large)
        }
        #expect(!rendered.says(localized("discovery.mateFound")))
        #expect(!rendered.says(localized("discovery.tacticFound")))
        #expect(!rendered.says(localized("discovery.none")), "no-result states occupy no UI")
        #expect(!rendered.says(localized("punish.toggle")), "settings must not open automatically")
        #expect(!rendered.says("e4"), "an engine answer is not permission to reveal it")
        let pixels = try #require(ScreenImage.Pixels(of: rendered.url))
        func wood(_ colour: (r: Int, g: Int, b: Int)) -> Bool {
            colour.r > 176 && colour.b < 192 && colour.r - colour.b > 50
        }
        let edgeRows = (0..<pixels.height).filter {
            wood(pixels.colour(x: 0, y: $0)) &&
            wood(pixels.colour(x: pixels.width - 1, y: $0))
        }
        #expect(edgeRows.count > pixels.width / 3,
                "real board squares must reach both screen edges, not just a width helper")
    }
}
