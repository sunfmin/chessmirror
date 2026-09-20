import ChessmirrorKit
import ChessmirrorKitTesting
import Foundation
import Testing

/// Contract: 牌堆 — which cards are on the table, what each row says, and what is drawn on the
/// board — is answered by the kit (docs/adr/0025, 0031, 0047).
///
/// It was the screen's for a year: the catalogue, the rule that a card with no finding takes up
/// no room, and the wording of a row while the finder is still looking all lived in SwiftUI, so
/// the only way to ask any of it was to render on a simulator and read the words back off the
/// pixels. Every test here runs in milliseconds and none of them draws anything.
@MainActor @Suite(.speaking(.chinese)) struct DeckTests {
    /// The Opera Game position: White has a mate in two.
    private static let opera = "4kb1r/p2n1ppp/4q3/4p1B1/4P3/1Q6/PPP2PPP/2KR4 w - - 0 1"

    private func hop() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func mateInTwo(_ fen: String) -> [String: Analysis] {
        [
            fen: Analysis(
                depth: PositionSearches.depth,
                lines: [
                    Line(
                        score: .mate(in: 2), uciMoves: ["b3b8", "d7b8", "d1d8"],
                        san: ["Qb8+", "Nxb8", "Rd8#"]
                    )
                ]
            )
        ]
    }

    @Test("the deck does not change shape, and a card with nothing behind it is not dealt")
    func theCatalogueIsTwoCardsInOneOrder() {
        #expect(Deck.Card.catalogue == [.mate, .tactics])

        let looking = Deck.dealt(isDealt: true, mate: false, tactic: false, isSearching: true)
        #expect(looking.rows.map(\.card) == [.mate, .tactics], "both rows, whatever was found")
        #expect(looking.dealt.isEmpty, "and neither takes up room")
        #expect(looking.isEmpty)
        #expect(looking.rows.allSatisfy { $0.title.contains(localized("discovery.checking")) })

        let finished = Deck.dealt(isDealt: true, mate: false, tactic: false, isSearching: false)
        #expect(finished.rows.allSatisfy { $0.title.contains(localized("discovery.none")) })
        #expect(finished.rows.first?.title.contains(Deck.Card.mate.title) == true)
    }

    @Test("a finding says so in one word, and it is the only pressable row")
    func aFindingIsARowOfItsOwn() {
        let deck = Deck.dealt(isDealt: true, mate: true, tactic: false, isSearching: false)
        #expect(deck.dealt.map(\.card) == [.mate])
        #expect(deck.has(.mate))
        #expect(!deck.has(.tactics))
        #expect(deck.row(.mate)?.title == localized("discovery.mateFound"))
        #expect(deck.row(.tactics)?.isFound == false)
    }

    @Test("a 把关 game is dealt nothing at all")
    func noSlipsIsDealtNothing() {
        let deck = Deck.dealt(isDealt: false, mate: true, tactic: true, isSearching: true)
        #expect(deck.rows.isEmpty, "a card is an opinion about what to play (docs/adr/0031)")
        #expect(deck.isEmpty)
        #expect(!deck.isSearching)
    }

    // ------------------------------------------------------- through a session

    @Test("a session deals its own deck, and a 把关 one deals none")
    func theSessionDealsIt() async throws {
        let game = try #require(Game(startFEN: Self.opera))
        let engine = ScriptedEngine([], byPosition: mateInTwo(game.state.fen))
        let session = GameSession.fresh(game)
        defer { session.suspend() }
        session.attach(engine: engine, library: nil)
        session.setFindingTactics(true)
        await hop()

        #expect(session.dealsCards)
        #expect(session.deck.has(.mate), "the probe found the mate, so the card is on the table")
        #expect(session.deck.row(.mate)?.title == localized("discovery.mateFound"))
        #expect(session.arrows(for: .mate).count == 3, "and its line is three arrows")
        #expect(session.arrows(for: nil).isEmpty, "nothing is drawn for a card nobody opened")

        session.setNoSlips(true)
        #expect(!session.dealsCards)
        #expect(session.deck.rows.isEmpty, "把关 puts the cards away")
        #expect(session.arrows(for: .mate).isEmpty, "and takes the arrows with them")
    }

    @Test("a 练习 is dealt its cards under 把关, because its help is counted")
    func practiceKeepsTheDeck() async throws {
        let position = try #require(PositionKey(fen: Self.opera))
        let game = try #require(Game(startFEN: Self.opera))
        let engine = ScriptedEngine([], byPosition: mateInTwo(game.state.fen))
        let log = PracticeLog(
            url: URL(filePath: NSTemporaryDirectory())
                .appending(path: "chessmirror-deck-\(UUID().uuidString).jsonl")
        )
        defer { try? FileManager.default.removeItem(at: log.url) }
        let drill = try #require(Drill(position: position, engine: engine, log: log))
        let session = GameSession.practising(drill, engine: engine)
        defer { session.suspend() }
        session.setFindingTactics(true)
        await hop()

        #expect(session.isNoSlipsOn, "docs/adr/0047")
        #expect(session.dealsCards)
        #expect(session.deck.has(.mate))
        #expect(drill.hintsOpened == 0, "and opening one is what the 练习日志 counts")
        session.notePracticeHelp()
        #expect(drill.hintsOpened == 1)
    }
}
