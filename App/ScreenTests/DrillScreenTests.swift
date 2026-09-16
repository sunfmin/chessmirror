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
    @Test func practiceRevealsTheSameMultiMoveAnswer() async throws {
        let game = try #require(Game(startFEN: "4kb1r/p2n1ppp/4q3/4p1B1/4P3/1Q6/PPP2PPP/2KR4 w - - 0 1"))
        let position = try #require(PositionKey(fen: game.state.fen))
        let engine = ScriptedEngine([Analysis(depth: 20, lines: [
            Line(score: .mate(in: 2), uciMoves: ["b3b8", "d7b8", "d1d8"],
                 san: ["Qb8+", "Nxb8", "Rd8#"])
        ])])
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log.url) }
        let drill = try #require(Drill(position: position, engine: engine, log: log))
        let rendered = await ScreenImage.write("drill-mate-answer", interact: { window in
            #expect(drill.hintsOpened == 0)
            #expect(!ScreenImage.words(in: window).contains("Rd8#"))
            #expect(ScreenImage.activate(localized("discovery.view"), in: window))
            await ScreenImage.settle()
            #expect(drill.hintsOpened == 1)
        }) {
            NavigationStack {
                DrillScreen(drill: drill, mistake: Mistake(position: position, encounters: []), path: .constant([]))
            }
            .environment(EngineHost(engine))
            .environment(GameLibrary(folder: GameFolder(url: URL(filePath: NSTemporaryDirectory()))))
            .environment(index(log))
        }
        #expect(rendered.says("Rd8#"))
        #expect(log.attempts().isEmpty, "opening an answer is not itself an attempt")
    }
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
                depth: Drill.depth,
                lines: [Line(score: .centipawns(before), uciMoves: [], san: [wanting])]
            )
        ]
        if reached.state.fen != start.state.fen {
            opinions[reached.state.fen] = Analysis(
                depth: Drill.depth, lines: [Line(score: .centipawns(after), uciMoves: [], san: [])]
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

        let rendered = await ScreenImage.write("drill-asking", interact: { window in
            #expect(ScreenImage.activate(localized("game.flip"), in: window))
            await ScreenImage.settle()
            #expect(ScreenImage.activate(localized("game.flip"), in: window))
            #expect(ScreenImage.activate(localized("game.settings.expand", PieceColour.white.label), in: window))
            await ScreenImage.settle()
            #expect(ScreenImage.words(in: window).contains(localized("search.limit")))
            #expect(ScreenImage.activate(localized("game.settings.collapse", PieceColour.white.label), in: window))
        }) {
            NavigationStack {
                DrillScreen(drill: drill, mistake: mistake(), path: .constant([]))
            }
            .environment(EngineHost(ScriptedEngine([])))
            .environment(GameLibrary(folder: GameFolder(url: URL(filePath: NSTemporaryDirectory()))))
            .environment(index(log))
        }

        #expect(rendered.says("该你走"))
        #expect(rendered.says(localized("standing.bar")))
        #expect(rendered.says(localized("game.settings.expand", PieceColour.black.label)))
        let pixels = try #require(ScreenImage.Pixels(of: rendered.url))
        #expect(pixels.fullWidthBoardRows > pixels.width / 2)
        #expect(!rendered.says("Nc6"), "the engine's move is not on the screen before the move")
        #expect(!rendered.says("掉"), "and neither is a number")
        #expect(!rendered.says("下一题"), "the way on arrives with the verdict")
        #expect(!rendered.says(localized("drill.leave")), "and so does the way out")
    }

    @Test("a failed attempt keeps its feedback on the shared, playable game screen")
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

        #expect(rendered.says(localized("drill.dropped")), "the answer, in one word and in colour")
        #expect(rendered.says("Qh4"))
        #expect(rendered.says("12%"), "what it cost, on the one scale")
        #expect(rendered.says("该走 Nc6"), "and what to have played")
        #expect(!rendered.says("继续下"), "the board itself continues the game")
        #expect(rendered.says(localized("standing.bar")))
        #expect(rendered.says(localized("till.name")))
        #expect(rendered.says("退出"))
        // 下一题 only appears when there is another one; this book has exactly this position.
        #expect(!rendered.says("下一题"))
        #expect(log.attempts().count == 1, "and the attempt was written down")
    }

    @Test("a move that holds is told so too, and is not argued with")
    func aPassIsAlsoToldSomething() async throws {
        let (drill, move, log) = try drill(
            playing: "Nc6", before: 0, after: 45, wanting: "d5"
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
        #expect(!rendered.says("站得住"), "the word 过了 is the whole verdict; a pass needs no paragraph")
        #expect(!rendered.says("继续下"))
    }
}
