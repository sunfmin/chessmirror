import ChessmirrorKit
import Foundation
import SwiftUI
import Testing

@testable import Chessmirror
import ChessmirrorKitTesting

/// The screen with a player's own controls open and the deck on the table — the state three
/// tickets were written about from a screenshot no test produces any more.
///
/// The screen's own contract is that the board fills the screen's width and the page scrolls to
/// make room for anything else; this reads the pixels to hold it to that, and reads the words to
/// see what the cards and the controls actually say while it is open.
@MainActor
@Suite(.serialized, .drawing(in: .chinese))
struct UnfoldedControls {
    private static let opera = "4kb1r/p2n1ppp/4q3/4p1B1/4P3/1Q6/PPP2PPP/2KR4 w - - 0 1"

    private func mateFinding(_ game: Game) -> ScriptedEngine {
        ScriptedEngine([], byPosition: [
            game.state.fen: Analysis(depth: 20, lines: [
                Line(score: .mate(in: 2), uciMoves: ["b3b8", "d7b8", "d1d8"],
                     san: ["Qb8+", "Nxb8", "Rd8#"])
            ])
        ])
    }

    /// Opening a side's settings must not shrink the board.
    @Test("the board keeps the screen's width when a player's controls unfold")
    func theBoardKeepsItsWidth() async throws {
        let game = try #require(Game(startFEN: Self.opera))
        let engine = mateFinding(game)
        let shut = GameSession.fresh(game, engine: engine)
        let shutShot = await ScreenImage.write("unfolded-shut") { screen(shut, engine: engine) }

        let open = GameSession.fresh(game, engine: engine)
        let openShot = await ScreenImage.write("unfolded-open", interact: { window in
            #expect(
                ScreenImage.activate(localized("game.settings.expand", PieceColour.white.label), in: window),
                "a side's settings must be openable"
            )
        }, of: { screen(open, engine: engine) })

        let (width, closed) = try #require(boardSpan(of: shutShot.url))
        let (_, opened) = try #require(boardSpan(of: openShot.url))
        #expect(openShot.says("收起"), "the controls really are open")
        #expect(
            opened.count >= width - 2,
            "the board is \(opened.count) of \(width) pixels wide with the controls open"
        )
        #expect(
            abs(opened.count - closed.count) <= 1,
            "the board changed width when the controls opened: \(closed) then \(opened)"
        )
    }

    /// What the cards and the open controls say while they are open — one state each, and every
    /// control named.
    @Test("nothing on the open screen says two things at once")
    func theOpenScreenSaysOneThingAtATime() async throws {
        let game = try #require(Game(startFEN: Self.opera))
        let engine = mateFinding(game)
        let session = GameSession.fresh(game, engine: engine)
        let rendered = await ScreenImage.write("unfolded-controls", interact: { window in
            _ = ScreenImage.activate(localized("game.settings.expand", PieceColour.white.label), in: window)
        }, of: { screen(session, engine: engine) })

        let searching = rendered.says(localized("noSlips.judging"))
        let unanswered = rendered.says(localized("discovery.none"))
        #expect(
            !(searching && unanswered),
            "「\(localized("noSlips.judging"))」 and 「\(localized("discovery.none"))」 are on screen together"
        )
        // Every word it drew, for the eye: the accessibility tree is the whole of what it says.
        print("WORDS: " + rendered.words.joined(separator: " | "))
    }

    private func screen(_ session: GameSession, engine: any Engine) -> some View {
        NavigationStack { GameScreen(session: session, path: .constant([])) }
            .environment(EngineHost(engine))
            .environment(GameLibrary()).environment(CollectionShelf(library: GameLibrary()))
    }

    /// The picture's width, and the longest run of board-coloured pixels across its middle.
    private func boardSpan(of url: URL) -> (width: Int, run: ClosedRange<Int>)? {
        guard let image = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // The same two-channel test the board's vertical extent is found by: saturated wood.
        func isBoard(_ row: Int, _ column: Int) -> Bool {
            let offset = (row * width + column) * 4
            return Int(pixels[offset]) > 0xB0 && Int(pixels[offset + 2]) < 0xC0
        }
        var best: ClosedRange<Int>?
        for row in stride(from: 0, to: height, by: 4) {
            var start: Int?
            for column in 0...width {
                let board = column < width && isBoard(row, column)
                switch (board, start) {
                case (true, nil): start = column
                case (false, .some(let from)):
                    let run = from...(column - 1)
                    if run.count > (best?.count ?? 0) { best = run }
                    start = nil
                default: break
                }
            }
        }
        return best.map { (width, $0) }
    }
}
