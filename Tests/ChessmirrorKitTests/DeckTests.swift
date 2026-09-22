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

    // ------------------------------------------------------- the open card

    /// A session on the Opera Game with its deck dealt and the mate found.
    private func dealtOnAMate() async throws -> (GameSession, ScriptedEngine) {
        let game = try #require(Game(startFEN: Self.opera))
        let engine = ScriptedEngine([], byPosition: mateInTwo(game.state.fen))
        let session = GameSession.fresh(game, engine: engine)
        session.dealDeck()
        await hop()
        return (session, engine)
    }

    /// A mate the finder comes back with is said on its own row and left shut: the line is not
    /// read out, and not drawn, until somebody presses it.
    @Test("a mate already found is announced, and not opened")
    func aMateAlreadyFoundIsAnnouncedAndNotOpened() async throws {
        let (session, _) = try await dealtOnAMate()
        defer { session.suspend() }
        #expect(session.isFindingTactics, "arriving is the asking")
        #expect(session.deck.has(.mate))
        #expect(session.openCard == nil)
        #expect(session.deckArrows.isEmpty)
    }

    /// Pressing opens with the line drawn, pressing again shuts, and the board moving puts it
    /// away: a new position asks for a new press, even walking back to the old one.
    @Test("a finding opens on a press, shuts on a press, and is put away when the board moves")
    func aFindingOpensOnAPressAndIsPutAwayWhenTheBoardMoves() async throws {
        let (session, _) = try await dealtOnAMate()
        defer { session.suspend() }
        let news = try #require(session.mateNews)

        session.press(.mate)
        #expect(session.openCard == .mate)
        #expect(session.draws(.mate))
        #expect(session.deckArrows == news.arrows)

        session.press(.mate)
        #expect(session.openCard == nil, "pressing the open one shuts it")
        #expect(session.deckArrows.isEmpty)

        session.press(.mate)
        session.play(try #require(session.viewed.state.move(matching: "b3b8")))
        #expect(session.game.uciMoves == ["b3b8"])
        #expect(session.openCard == nil, "a new position needs a new press")
        #expect(session.deckArrows.isEmpty)
        session.step(by: -1)
        #expect(session.openCard == nil, "and so does the old one, come back to")
    }

    /// The arrow on the card takes the line off the board and leaves the card open.
    @Test("the card's arrow takes its line off the board and back")
    func theArrowTakesTheLineOffTheBoard() async throws {
        let (session, _) = try await dealtOnAMate()
        defer { session.suspend() }
        session.press(.mate)
        session.toggleLine()
        #expect(session.isOpen(.mate))
        #expect(!session.draws(.mate))
        #expect(session.drawnCard == nil)
        #expect(session.deckArrows.isEmpty)
        session.toggleLine()
        #expect(session.drawnCard == .mate)
    }

    /// The open card is part of the deck's one reading, not a second reach into `Findings`:
    /// a row says whether it is the one in front of the player and whether its line is on the
    /// board, so the deck and the arrows cannot disagree.
    @Test("the open card is read off the deck itself")
    func theOpenCardIsReadOffTheDeckItself() async throws {
        let (session, _) = try await dealtOnAMate()
        defer { session.suspend() }

        #expect(session.deck.row(.mate)?.isOpen == false)
        #expect(session.deck.row(.mate)?.drawsLine == false)
        #expect(session.deck.row(.tactics)?.isOpen == false)

        session.press(.mate)
        #expect(session.deck.row(.mate)?.isOpen == true, "the one reading says which is open")
        #expect(session.deck.row(.mate)?.drawsLine == true)
        #expect(session.deck.row(.tactics)?.isOpen == false)

        session.toggleLine()
        #expect(session.deck.row(.mate)?.isOpen == true, "the arrow takes the line, not the card")
        #expect(session.deck.row(.mate)?.drawsLine == false)
    }

    /// A row with nothing behind it does not press.
    @Test("a row with nothing behind it does not open")
    func aRowWithNothingBehindItDoesNotOpen() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let engine = ScriptedEngine([], byPosition: [
            game.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(30), uciMoves: ["e2e4"], san: ["e4"])]),
        ])
        let session = GameSession.fresh(game, engine: engine)
        defer { session.suspend() }
        session.dealDeck()
        await hop()
        #expect(session.deck.dealt.isEmpty)
        session.press(.mate)
        session.press(.tactics)
        #expect(session.openCard == nil)
        session.toggleLine()
        #expect(session.drawnCard == nil, "and a shut deck has no arrow to press")
    }

    /// Opening a finding in a 练习 is the help the 练习日志 counts — once per opening, not per
    /// shutting.
    @Test("opening a finding in a 练习 is counted as help")
    func openingAFindingInPracticeIsHelp() async throws {
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
        session.dealDeck()
        await hop()

        session.press(.mate)
        #expect(drill.hintsOpened == 1)
        session.press(.mate)
        #expect(drill.hintsOpened == 1, "shutting it is not more help")
        session.press(.tactics)
        #expect(drill.hintsOpened == 2, "opening the other finding is help again")
    }

    /// The deck is dealt once: coming back to the screen asks nothing again.
    @Test("the deck is dealt once")
    func theDeckIsDealtOnce() async throws {
        let (session, engine) = try await dealtOnAMate()
        defer { session.suspend() }
        #expect(session.isDeckDealt)
        let asked = engine.searchCount
        session.setFindingTactics(false)
        session.dealDeck()
        await hop()
        #expect(!session.isFindingTactics, "the second deal does not turn the finder back on")
        #expect(engine.searchCount == asked)
    }

    /// When the engine puts its own move down, the position it left is asked about by the session
    /// itself, deck or no deck. The screen used to watch for the engine going quiet and ask again
    /// for the card; by then the session's own search was always running and the card's asking
    /// came to nothing, so the watching is gone rather than moved.
    @Test(arguments: [true, false])
    func thePositionTheEngineLeavesIsAskedAbout(dealt: Bool) async throws {
        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        let afterE4 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
        let afterE5 = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4", "e7e5"]))
        let engine = ScriptedEngine([], byPosition: [
            start.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(30), uciMoves: ["e2e4"], san: ["e4"])]),
            afterE4.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(10), uciMoves: ["e7e5"], san: ["e5"])]),
            afterE5.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(20), uciMoves: ["g1f3"], san: ["Nf3"])]),
        ])
        let session = GameSession.fresh(
            start, controllers: [.white: .hand, .black: .engine], engine: engine
        )
        defer { session.suspend() }
        if dealt {
            session.dealDeck()
            session.setFindingTactics(false)
        }
        await hop()
        session.play(try #require(start.state.move(matching: "e2e4")))
        await hop()
        #expect(session.game.uciMoves == ["e2e4", "e7e5"], "the engine answered")
        #expect(session.thinking == nil)
        #expect(engine.positions.contains(afterE5.state.fen))
    }

    /// Every move of a line is somebody's, past the sixth too. The card used to read the colour
    /// off the arrows, which stop at six, and called every move after them the other side's.
    @Test("every chip of a long mate is coloured by who plays it")
    func everyChipOfALongMateIsSomebodys() throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let uci = ["e2e4", "e7e5", "d1h5", "b8c6", "f1c4", "g8f6", "h5f7", "e8e7", "c4d5"]
        let san = ["e4", "e5", "Qh5", "Nc6", "Bc4", "Nf6", "Qxf7+", "Ke7", "Bd5"]
        let analysis = Analysis(depth: 20, lines: [Line(score: .mate(in: 5), uciMoves: uci, san: san)])
        let news = try #require(MateNews.read(analysis, in: game, hands: [.white]))
        #expect(news.arrows.count == MateNews.arrowLimit)
        #expect(news.steps.map(\.san) == san, "every move gets a chip")
        #expect(news.steps.map(\.isYours) == san.indices.map { $0.isMultiple(of: 2) })
        #expect(Array(news.steps.prefix(MateNews.arrowLimit).map(\.isYours)) == news.arrows.map(\.isYours),
                "and the chips agree with the arrows where there are arrows")

        let black = try #require(MateNews.read(analysis, in: game, hands: [.black]))
        #expect(black.steps.map(\.isYours) == san.indices.map { !$0.isMultiple(of: 2) })
    }

    /// No news is news, three kinds of it.
    @Test("the mate card says which silence it is")
    func theMateCardSaysWhichSilenceItIs() async throws {
        let idle = GameSession.fresh(try #require(Game(startFEN: PGN.standardStartFEN)))
        #expect(idle.mateQuiet == localized("screen.mateIdle"), "nobody has looked")

        let mated = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3", "e7e5", "g2g4", "d8h4"]))
        #expect(GameSession.fresh(mated).mateQuiet == localized("screen.finished"))

        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let engine = ScriptedEngine([], byPosition: [
            game.state.fen: Analysis(depth: 20, lines: [.init(score: .centipawns(30), uciMoves: ["e2e4"], san: ["e4"])]),
        ])
        let looked = GameSession.fresh(game, engine: engine)
        defer { looked.suspend() }
        looked.dealDeck()
        await hop()
        #expect(looked.mateNews == nil)
        #expect(looked.mateQuiet == localized("screen.noMate"), "looked, and there is none")

        let (onAMate, _) = try await dealtOnAMate()
        defer { onAMate.suspend() }
        #expect(onAMate.mateQuiet == nil, "a mate is not a silence")
    }
}
