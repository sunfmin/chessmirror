import Testing
@testable import ChessmirrorKit

@Suite struct StripQuestionsSuiteTests {
    private func tried(_ san: String) -> Game.Ply.Tried {
        .init(san: san, drop: 12, notFound: false, depth: 12, line: [])
    }

    @Test func oneFaceCarriesBothQuestionsWithoutLosingEither() {
        var strip = StripQuestions()
        #expect(strip.replyReading == nil)
        #expect(strip.rejudging == nil)

        let move = RecordReading.WrongMove(tried("Qh5"), at: 0)
        let game = Game(startFEN: PGN.standardStartFEN)!
        strip.openReply(ReplyReading(index: 0, move: move, position: game, line: [], isAsking: true))
        strip.beginRejudge(Rejudging(index: 0, tried: tried("Qh5"), depth: 0))

        #expect(strip.isReplyOpen(at: 0))
        #expect(strip.isRejudging)
        #expect(strip.rejudgingTried?.san == "Qh5")
    }

    @Test func closingTheConversationPutsBothQuestionsAway() {
        var strip = StripQuestions()
        let move = RecordReading.WrongMove(tried("Qh5"), at: 0)
        let game = Game(startFEN: PGN.standardStartFEN)!
        strip.openReply(ReplyReading(index: 0, move: move, position: game, line: [], isAsking: true))
        strip.beginRejudge(Rejudging(index: 0, tried: tried("Qh5"), depth: 0))

        strip.close()

        #expect(strip.replyReading == nil)
        #expect(strip.rejudging == nil)
    }

    @Test func rewritingAReplyLeavesTheRejudgeAlone() {
        var strip = StripQuestions()
        let old = tried("Qh5")
        let deeper = Game.Ply.Tried(san: "Qh5", drop: 3, notFound: false, depth: 28, line: ["Qxe5+"])
        let game = Game(startFEN: PGN.standardStartFEN)!
        strip.openReply(
            ReplyReading(
                index: 0, move: RecordReading.WrongMove(old, at: 0), position: game,
                line: [], isAsking: true
            )
        )
        strip.beginRejudge(Rejudging(index: 0, tried: old, depth: 0))

        strip.rewriteReply(
            as: ReplyReading(
                index: 0, move: RecordReading.WrongMove(deeper, at: 0), position: game,
                line: ["Qh5", "Qxe5+"], isAsking: false
            )
        )

        #expect(strip.replyReading?.move.depth == 28)
        #expect(strip.rejudging?.tried == old)
    }
}
