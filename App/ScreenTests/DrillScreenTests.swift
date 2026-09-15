import ChessfenKit
import Foundation
import SwiftUI
import Testing

@testable import Chessfen

/// Practising one 错题, photographed: the position with nothing said about it, and the settlement
/// after the move (docs/adr/0029).
@MainActor
@Suite(.serialized, .speaking(.chinese))
struct DrillScreenshots {
    /// The position after 1. e4 e5 2. Nf3, which is the one the book fixtures fall for.
    private let position = PositionKey(
        "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq -"
    )

    private func temporaryLog() -> PracticeLog {
        PracticeLog(
            url: URL(filePath: NSTemporaryDirectory())
                .appending(path: "chessfen-drill-screen-\(UUID().uuidString).jsonl")
        )
    }

    /// A drill over that position, with an engine that has one opinion about it and one about
    /// where `san` leads.
    private func drill(
        playing san: String?, before: Int, after: Int, wanting: String
    ) throws -> (drill: Drill, move: Move?, log: PracticeLog) {
        let start = try #require(Game(startFEN: position.text + " 0 1"))
        var reached = start
        var move: Move?
        if let san {
            let legal = reached.apply(san: san)
            #expect(legal, "\(san) has to be legal here")
            move = start.state.move(matching: try #require(reached.plies.last).uci)
        }
        // Built up rather than written as a literal: with no move played the two positions are
        // the same position, and a literal with the same key twice is a crash.
        var opinions = [
            start.state.fen: Analysis(
                depth: 14,
                lines: [Line(score: .centipawns(before), uciMoves: [], san: [wanting])]
            )
        ]
        if reached.state.fen != start.state.fen {
            opinions[reached.state.fen] = Analysis(
                depth: 14, lines: [Line(score: .centipawns(after), uciMoves: [], san: [])]
            )
        }
        let engine = ScriptedEngine([], byPosition: opinions)
        let log = temporaryLog()
        return (try #require(Drill(position: position, engine: engine, log: log)), move, log)
    }

    private func index(_ log: PracticeLog) -> MistakeIndex { MistakeIndex(log: log) }

    private func mistake(_ when: Date = Date()) -> Mistake {
        Mistake(
            position: position,
            encounters: [
                Encounter(
                    game: URL(filePath: "/games/monday.pgn"), ply: 4, when: when,
                    played: "Qh4", wanted: "Nc6", cost: 31, origin: .fresh
                )
            ]
        )
    }

    @Test("the position goes up with nothing said about it")
    func nothingIsGivenAwayBeforeTheMove() async throws {
        let (drill, _, log) = try drill(playing: nil, before: 0, after: 0, wanting: "Nc6")
        defer { try? FileManager.default.removeItem(at: log.url) }

        let rendered = await ScreenImage.write("drill-asking") {
            NavigationStack {
                DrillScreen(drill: drill, mistake: mistake(), path: .constant([]))
            }
            .environment(EngineHost(ScriptedEngine([])))
            .environment(GameLibrary(folder: GameFolder(url: URL(filePath: NSTemporaryDirectory()))))
            .environment(index(log))
        }

        #expect(rendered.says("该你走"))
        let pixels = try #require(ScreenImage.Pixels(of: rendered.url))
        #expect(pixels.fullWidthBoardRows > pixels.width / 2)
        #expect(!rendered.says("Nc6"), "the engine's move is not on the screen before the move")
        #expect(!rendered.says("掉"), "and neither is a number")
        #expect(!rendered.says("下一题"), "the exits arrive with the verdict")
    }

    @Test("a move that costs twelve points is failed, told why, and offered three ways out")
    func aFailedAttemptIsSettledOnScreen() async throws {
        let (drill, move, log) = try drill(
            playing: "Qh4", before: 0, after: 133, wanting: "Nc6"
        )
        defer { try? FileManager.default.removeItem(at: log.url) }
        drill.play(try #require(move))
        await drill.settled()

        let rendered = await ScreenImage.write("drill-settled") {
            NavigationStack {
                DrillScreen(drill: drill, mistake: mistake(), path: .constant([]))
            }
            .environment(EngineHost(ScriptedEngine([])))
            .environment(GameLibrary(folder: GameFolder(url: URL(filePath: NSTemporaryDirectory()))))
            .environment(index(log))
        }

        #expect(rendered.says("Qh4"))
        #expect(rendered.says("12%"), "what it cost, on the one scale")
        #expect(rendered.says("该走 Nc6"), "and what to have played")
        #expect(rendered.says("继续下"), "三个出口")
        #expect(rendered.says("退出"))
        // 下一题 only appears when there is another one; this book has exactly this position.
        #expect(!rendered.says("下一题"))
        #expect(log.attempts().count == 1, "and the attempt was written down")
    }

    @Test("a move that holds is told so too, and is not argued with")
    func aPassIsAlsoToldSomething() async throws {
        let (drill, move, log) = try drill(
            playing: "Nc6", before: 0, after: 109, wanting: "d5"
        )
        defer { try? FileManager.default.removeItem(at: log.url) }
        drill.play(try #require(move))
        await drill.settled()

        let rendered = await ScreenImage.write("drill-passed") {
            NavigationStack {
                DrillScreen(drill: drill, mistake: mistake(), path: .constant([]))
            }
            .environment(EngineHost(ScriptedEngine([])))
            .environment(GameLibrary(folder: GameFolder(url: URL(filePath: NSTemporaryDirectory()))))
            .environment(index(log))
        }

        // Rowland 2014: a pass with nothing said is retrieval practice with no corrective
        // feedback, which is worth nothing measurable.
        #expect(rendered.says("过了"))
        #expect(!rendered.says("该走 d5"), "多解: a move that holds is not the wrong answer")
        #expect(rendered.says("继续下"))
    }
}
