import ChessmirrorKit
import Foundation
import SwiftUI
import Testing

@testable import Chessmirror
import ChessmirrorKitTesting

/// Every screen on every shape an iPad hands the app: the three sizes held both ways up, and the
/// narrow and half-width windows Split View and Stage Manager cut out of them.
///
/// The phone's contract — the board fills the width and the page scrolls for the rest — is the
/// wrong one on a screen wider than it is tall: a board as wide as a landscape iPad is taller than
/// the screen, and the half of it under the fold is half the game. What is held here is the
/// contract that survives every one of these windows: the whole board is on screen, square, and
/// as large as the window lets it be.
@MainActor
@Suite(.serialized, .drawing(in: .chinese))
struct IPadLayout {
    /// A window an iPad can give the app, in points, named for the picture it is written to.
    struct Window: CustomTestStringConvertible, Sendable {
        let name: String
        let size: CGSize
        var testDescription: String { name }
    }

    nonisolated static let windows: [Window] = [
        Window(name: "mini-portrait", size: CGSize(width: 744, height: 1133)),
        Window(name: "mini-landscape", size: CGSize(width: 1133, height: 744)),
        Window(name: "11-portrait", size: CGSize(width: 834, height: 1210)),
        Window(name: "11-landscape", size: CGSize(width: 1210, height: 834)),
        Window(name: "13-portrait", size: CGSize(width: 1032, height: 1376)),
        Window(name: "13-landscape", size: CGSize(width: 1376, height: 1032)),
        // Split View: a third, a half and two thirds of a landscape 13-inch.
        Window(name: "split-third", size: CGSize(width: 375, height: 1032)),
        Window(name: "split-half", size: CGSize(width: 683, height: 1032)),
        Window(name: "split-two-thirds", size: CGSize(width: 983, height: 1032)),
        // Stage Manager: a window of no particular shape.
        Window(name: "stage-wide", size: CGSize(width: 900, height: 620)),
    ]

    private static let italian = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6"]

    @Test("the whole board is on screen, square, and as large as the window allows", arguments: windows)
    func theBoardFits(_ window: Window) async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let engine = ScriptedEngine([GameScreenScreenshots.opinion(.centipawns(30))], isEndless: true)
        let session = GameSession.fresh(game, engine: engine)
        let rendered = await ScreenImage.write("ipad-game-\(window.name)", size: window.size) {
            NavigationStack { GameScreen(session: session, path: .constant([])) }
                .environment(EngineHost(engine))
                .environment(GameLibrary())
        }

        let pixels = try #require(ScreenImage.Pixels(of: rendered.url))
        let scale = pixels.pixelsPerPoint(of: window.size)
        let board = try #require(boardBox(in: pixels), "no board drawn at \(window.name)")
        let width = CGFloat(board.width) / scale
        let height = CGFloat(board.height) / scale
        #expect(abs(width - height) <= 4, "the board is \(width)×\(height) at \(window.name)")
        // Clear of every edge: a board cut off at the bottom is not on screen.
        #expect(board.minY > 0 && board.maxY < CGFloat(pixels.height - 1),
                "the board runs off the window at \(window.name): \(board)")
        // As large as it can be: at least half the window's shorter side once the host's safe areas
        // are paid for (an iPhone host takes 96pt of them), and never tiny.
        let short = min(window.size.width, window.size.height)
        #expect(width >= min(short * 0.5, window.size.width - 2),
                "the board is only \(width)pt in a \(window.size) window")
        // The record and the controls are still on the screen with it.
        #expect(rendered.says("优势条"))
    }

    @Test("the library, book and settings read as columns, not stretched rows", arguments: windows)
    func theListsFit(_ window: Window) async throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "chessmirror-ipad-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = GameLibrary(folder: GameFolder(url: directory))
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
        game.applyReview([.centipawns(-400)], startEvaluation: .centipawns(0), depth: 20)
        #expect(library.write(
            PGN(game: game, tags: [PGN.Tag("White", Controller.hand.playerName)]),
            to: directory.appending(path: "mistake.pgn")
        ))
        let index = MistakeIndex(log: PracticeLog(url: directory.appending(path: "p.jsonl")))
        index.update(from: library.entries)

        let home = await ScreenImage.write("ipad-library-\(window.name)", size: window.size) {
            LibraryScreen()
                .environment(EngineHost(ScriptedEngine([])))
                .environment(library)
                .environment(index)
        }
        #expect(home.says("拍棋盘"))
        #expect(home.says("错题本"))

        let book = await ScreenImage.write("ipad-book-\(window.name)", size: window.size) {
            NavigationStack { BookScreen(path: .constant([])) }
                .environment(library)
                .environment(index)
                .environment(EngineHost(ScriptedEngine([])))
        }
        #expect(book.says("错题本"))

        let about = await ScreenImage.write("ipad-about-\(window.name)", size: window.size) {
            AboutScreen()
                .environment(EngineHost(ScriptedEngine([])))
                .environment(library)
        }
        #expect(about.says("判决线"))
    }

    @Test("a drill keeps its whole board on screen", arguments: windows)
    func theDrillFits(_ window: Window) async throws {
        let game = try #require(Game(startFEN: "4kb1r/p2n1ppp/4q3/4p1B1/4P3/1Q6/PPP2PPP/2KR4 w - - 0 1"))
        let position = try #require(PositionKey(fen: game.state.fen))
        let engine = ScriptedEngine([Analysis(depth: 20, lines: [
            Line(score: .mate(in: 2), uciMoves: ["b3b8", "d7b8", "d1d8"], san: ["Qb8+", "Nxb8", "Rd8#"])
        ])])
        let log = PracticeLog(url: URL(filePath: NSTemporaryDirectory())
            .appending(path: "chessmirror-ipad-drill-\(UUID().uuidString).jsonl"))
        defer { try? FileManager.default.removeItem(at: log.url) }
        let drill = try #require(Drill(position: position, engine: engine, log: log))
        let rendered = await ScreenImage.write("ipad-drill-\(window.name)", size: window.size) {
            NavigationStack {
                DrillScreen(drill: drill, mistake: Mistake(position: position, encounters: []), path: .constant([]))
            }
            .environment(EngineHost(engine))
            .environment(GameLibrary(folder: GameFolder(url: URL(filePath: NSTemporaryDirectory()))))
            .environment(MistakeIndex(log: log))
        }
        let pixels = try #require(ScreenImage.Pixels(of: rendered.url))
        let board = try #require(boardBox(in: pixels), "no board drawn at \(window.name)")
        #expect(board.minY > 0 && board.maxY < CGFloat(pixels.height - 1),
                "the drill's board runs off the window at \(window.name): \(board)")
    }

    @Test("the editor's board is whole, square and centred", arguments: windows)
    func theEditorFits(_ window: Window) async throws {
        let draft = try #require(PositionDraft(fen: PGN.standardStartFEN))
        let rendered = await ScreenImage.write("ipad-confirm-\(window.name)", size: window.size) {
            NavigationStack {
                ConfirmPositionScreen(proposal: PositionProposal(draft: draft), path: .constant([]))
            }
            .environment(EngineHost(ScriptedEngine([])))
            .environment(GameLibrary(folder: GameFolder(url: URL(filePath: NSTemporaryDirectory()))))
        }
        let pixels = try #require(ScreenImage.Pixels(of: rendered.url))
        let board = try #require(boardBox(in: pixels), "no board drawn at \(window.name)")
        #expect(abs(board.width - board.height) <= 12, "the editor's board is \(board) at \(window.name)")
        let left = board.minX
        let right = CGFloat(pixels.width) - board.maxX
        #expect(abs(left - right) <= 12, "the editor's board is off centre at \(window.name): \(board)")
    }

    // ------------------------------------------------------------------ reading the picture

    /// The bounding box of the largest block of board-coloured wood, found by the rows and columns
    /// that are mostly wood — the same colour test the phone's full-width check uses.
    private func boardBox(in pixels: ScreenImage.Pixels) -> CGRect? {
        func wood(_ x: Int, _ y: Int) -> Bool {
            let c = pixels.colour(x: x, y: y)
            return c.r > 176 && c.b < 192 && c.r - c.b > 50
        }
        // A light square and a dark square are both wood; a row across the board is at least a
        // quarter wood even with pieces and marks on it, and a row of anything else is not.
        let rows = (0..<pixels.height).filter { y in
            stride(from: 0, to: pixels.width, by: 3).count { wood($0, y) } * 3 > pixels.width / 4
        }
        guard let top = rows.first, let bottom = rows.last else { return nil }
        let middle = (top + bottom) / 2
        let columns = (0..<pixels.width).filter { x in
            stride(from: top, through: bottom, by: 3).count { wood(x, $0) } * 3 > (bottom - top) / 4
        }
        guard let left = columns.first, let right = columns.last, middle > 0 else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }
}
