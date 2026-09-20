@testable import ChessmirrorKit
import Foundation
import Testing
import ChessmirrorKitTesting

@MainActor @Suite(.speaking(.chinese)) struct StripQuestionsTests {
    private func opening() throws -> Game {
        try #require(Game(startFEN: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"))
    }

    private func tried(_ san: String, depth: Int? = nil, line: [String] = []) -> Game.Ply.Tried {
        Game.Ply.Tried(san: san, drop: 12, notFound: false, depth: depth, line: line)
    }

    private func wrong(_ san: String, at index: Int = 0) -> RecordReading.WrongMove {
        RecordReading.WrongMove(tried(san), at: index)
    }

    private func reading(
        _ move: RecordReading.WrongMove, at index: Int, in position: Game
    ) -> GameSession.ReplyReading {
        GameSession.ReplyReading(
            index: index, move: move, position: position, line: [], isAsking: true
        )
    }

    // ------------------------------------------------------------------ 应招

    @Test("a strip with nothing open has no reading and no question outstanding")
    func replyStartsClosed() {
        let strip = StripReply()
        #expect(strip.reading == nil)
        #expect(strip.pending == nil)
        #expect(!strip.isOpen(at: 0))
    }

    @Test("the answer fills in the reading it was asked for")
    func fillingTheOpenReading() throws {
        var strip = StripReply()
        let move = wrong("Qh5")
        strip.open(reading(move, at: 0, in: try opening()))
        #expect(strip.isOpen(at: 0))
        #expect(try #require(strip.reading).isAsking)

        strip.fill(["Qh5", "g6"], of: move, at: 0)
        #expect(!(try #require(strip.reading).isAsking))
        #expect(try #require(strip.reading).line == ["Qh5", "g6"])
    }

    @Test("an answer to a chip that has since been closed is not an answer")
    func fillingAClosedReadingIsDropped() throws {
        var strip = StripReply()
        let move = wrong("Qh5")
        strip.open(reading(move, at: 0, in: try opening()))
        strip.close()
        strip.fill(["Qh5", "g6"], of: move, at: 0)
        #expect(strip.reading == nil)
    }

    @Test("an answer to the chip that was open, after another was opened over it, is dropped")
    func fillingAReplacedReadingIsDropped() throws {
        var strip = StripReply()
        let first = wrong("Qh5")
        let second = wrong("Nf3", at: 1)
        strip.open(reading(first, at: 0, in: try opening()))
        strip.open(reading(second, at: 1, in: try opening()))

        strip.fill(["Qh5", "g6"], of: first, at: 0)
        #expect(strip.isOpen(at: 1))
        #expect(try #require(strip.reading).line.isEmpty)
        #expect(try #require(strip.reading).isAsking)
    }

    @Test("putting the 应招 away stops the question that was being asked for it")
    func closingCancelsTheQuestion() async throws {
        var strip = StripReply()
        strip.open(reading(wrong("Qh5"), at: 0, in: try opening()))
        let started = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(30))
        }
        strip.ask(started)
        #expect(strip.pending != nil)

        strip.close()
        #expect(strip.reading == nil)
        #expect(strip.pending == nil)
        await started.value
        #expect(started.isCancelled)
    }

    @Test("a 复判 that rewrote the move leaves the reading open, on the rewritten move")
    func rewritingKeepsTheReadingOpen() throws {
        var strip = StripReply()
        let before = wrong("Qh5")
        strip.open(reading(before, at: 0, in: try opening()))
        let after = RecordReading.WrongMove(tried("Qh5", depth: 20, line: ["g6"]), at: 0)
        strip.rewrite(
            as: GameSession.ReplyReading(
                index: 0, move: after, position: try opening(), line: ["Qh5", "g6"], isAsking: false
            )
        )
        #expect(strip.isOpen(at: 0))
        #expect(try #require(strip.reading).move == after)
        #expect(!(try #require(strip.reading).isAsking))
    }

    // ------------------------------------------------------------------ 复判

    @Test("a strip with no 复判 going is not busy and has nothing outstanding")
    func rejudgeStartsIdle() {
        let strip = StripRejudge()
        #expect(!strip.isBusy)
        #expect(strip.rejudging == nil)
        #expect(strip.tried == nil)
        #expect(strip.pending == nil)
    }

    @Test("a 复判 under way reports which 试招 it is judging, and how deep it has got")
    func rejudgeReportsItsProgress() throws {
        var strip = StripRejudge()
        let move = tried("Qh5")
        strip.begin(GameSession.Rejudging(index: 2, tried: move, depth: 0))
        #expect(strip.isBusy)
        #expect(strip.tried == move)
        #expect(try #require(strip.rejudging).depth == 0)

        strip.note(depth: 18)
        #expect(try #require(strip.rejudging).depth == 18)
    }

    @Test("a 复判 that finished has nothing left going")
    func finishingClearsIt() {
        var strip = StripRejudge()
        strip.begin(GameSession.Rejudging(index: 0, tried: tried("Qh5"), depth: 0))
        strip.finish()
        #expect(!strip.isBusy)
        #expect(strip.rejudging == nil)
        #expect(strip.pending == nil)
    }

    @Test("a 复判 that yields takes its deeper 细判 down with it")
    func cancellingStopsTheDeeperJudge() async throws {
        var strip = StripRejudge()
        strip.begin(GameSession.Rejudging(index: 0, tried: tried("Qh5"), depth: 0))
        let started = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(30))
        }
        strip.ask(started)
        #expect(strip.isBusy)

        strip.cancel()
        #expect(!strip.isBusy)
        #expect(strip.rejudging == nil)
        #expect(strip.pending == nil)
        await started.value
        #expect(started.isCancelled)
    }

    @Test("noting a depth after the 复判 has gone writes nowhere")
    func notingAfterCancelIsIgnored() {
        var strip = StripRejudge()
        strip.begin(GameSession.Rejudging(index: 0, tried: tried("Qh5"), depth: 0))
        strip.cancel()
        strip.note(depth: 20)
        #expect(strip.rejudging == nil)
    }
}
