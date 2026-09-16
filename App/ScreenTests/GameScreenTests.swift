import ChessfenKit
import SwiftUI
import Testing

@testable import Chessfen

/// The game screen, photographed.
///
/// Serialized and on the main actor because there is one screen: two of these rendering at once
/// would be two key windows, and whichever drew second would be photographing the other one.
@MainActor
@Suite(.serialized, .speaking(.chinese))
struct GameScreenScreenshots {
    /// The Italian, eight plies in, White to move — a position anyone who plays reads at a glance,
    /// which is what a screenshot is for.
    private static let italian = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6"]

    /// One position's worth of opinion: a Score, and optionally the move the engine would play.
    /// What a study needs, as against a search that deepens.
    /// `then` is the rest of the Line in SAN. A Line of one move was enough while the only thing
    /// read off it was the arrow; the board now reads the continuation to say which squares a move
    /// mattered over, so a fake engine has to be able to have one (docs/adr/0021).
    static func opinion(
        _ score: Score, best: (uci: String, san: String)? = nil, then: [String] = []
    ) -> Analysis {
        Analysis(
            depth: 14,
            selectiveDepth: 18,
            lines: [
                Line(
                    score: score,
                    uciMoves: best.map { [$0.uci] } ?? [],
                    san: best.map { [$0.san] + then } ?? []
                )
            ],
            nodes: 4_000_000,
            nodesPerSecond: 2_000_000,
            timeMilliseconds: 2_000
        )
    }

    /// Two Depths of the same search, because that is how one arrives: the screen is shown the
    /// shallow one and then made to replace it, exactly as it would be in someone's hand.
    private static let searching = [
        Analysis(
            depth: 18,
            selectiveDepth: 25,
            lines: [
                Line(
                    score: .centipawns(24),
                    uciMoves: ["d2d4", "e5d4", "c3d4", "c5b6"],
                    san: ["d4", "exd4", "cxd4", "Bb6"]
                ),
                Line(
                    score: .centipawns(19),
                    uciMoves: ["e1g1", "d7d6", "d2d4", "c5b6"],
                    san: ["O-O", "d6", "d4", "Bb6"]
                ),
            ],
            nodes: 9_800_000,
            nodesPerSecond: 2_360_000,
            timeMilliseconds: 4_150
        ),
        Analysis(
            depth: 26,
            selectiveDepth: 34,
            lines: [
                Line(
                    score: .centipawns(38),
                    uciMoves: ["d2d4", "e5d4", "c3d4", "c5b6", "e4e5", "d7d5"],
                    san: ["d4", "exd4", "cxd4", "Bb6", "e5", "d5"]
                ),
                Line(
                    score: .centipawns(21),
                    uciMoves: ["e1g1", "d7d6", "d2d4", "c5b6", "h2h3", "e8g8"],
                    san: ["O-O", "d6", "d4", "Bb6", "h3", "O-O"]
                ),
                Line(
                    score: .centipawns(9),
                    uciMoves: ["d2d3", "d7d6", "e1g1", "a7a6"],
                    san: ["d3", "d6", "O-O", "a6"]
                ),
            ],
            nodes: 63_400_000,
            nodesPerSecond: 2_480_000,
            timeMilliseconds: 25_600
        ),
    ]

    /// A game under way against the engine. The engine's opinion of the position is not on the
    /// screen — there is no switch for it (docs/adr/0040) — but the search of the position is,
    /// as the depth it has got to.
    @Test("the game screen shows the position, how deep the engine has looked, and the moves")
    func gameInPlay() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(
            game, controllers: [.white: .hand, .black: .engine]
        )

        let rendered = await ScreenImage.write("game-in-play") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }

        // Whose move it is, said in that side's own bar, and how far the engine has looked.
        #expect(rendered.says("白方"))
        #expect(rendered.says("该走了"))
        #expect(rendered.says(localized("game.depth", 26)), "the deeper snapshot should have replaced the shallow one")
        // Whether the bar carries a number here turns on which of the dealt card and the board's own
        // search asked first, so the picture is not held to either; `gameInPlaySaysNothing` is the
        // one that holds the default to silence (docs/adr/0040).
        #expect(rendered.says("优势条"), "said once, at the end of the bar that draws it")
        #expect(
            !rendered.says("搜索深度"),
            "and not how fast the phone is going while it says it — that was a row of plumbing"
        )
        // How deep it has got, though, which is not the same thing: a search that stops after ten
        // seconds (docs/adr/0020) has to account for itself, or a number that stopped moving is
        // indistinguishable from an engine that died. One figure, in the strip, and no speed.
        #expect(rendered.says(localized("game.depth", 26)))
        #expect(
            rendered.count(of: "再算 10 秒") == 0,
            "and no offer of more while it is still inside its Stint"
        )
        // The move it would play, named beside the arrow the board draws — one move, because a
        // line of six is a language most people playing this have not learnt.
        #expect(!rendered.says("建议 d4"), "a finding must be opened before naming its move")
        #expect(!rendered.says("d4 exd4 cxd4"), "and not the whole line it is the head of")
        // The deck under the record, dealt from this position: two cards, and nothing about a
        // move that has not been played (docs/adr/0025).
        #expect(!rendered.says(localized("discovery.mateFound")))
        #expect(rendered.says("战术"))
        // And the three that went with the drills: nothing on this screen names them any more.
        #expect(!rendered.says("要害"))
        #expect(!rendered.says("五步"))
        #expect(!rendered.says("练习"))
        #expect(!rendered.says("问一格"))
        #expect(!rendered.says("走马灯"))
        #expect(!rendered.says("考一遍"))
        // The record, and the whole walk through it.
        #expect(rendered.says("第 8 步 Nf6"), "the record should carry the game, move by move")
        #expect(
            !rendered.words.contains { $0.hasPrefix("第 ") && $0.contains("掉") },
            "nothing measured, so no line of costs: the strip as it was (#48)"
        )
        #expect(rendered.says("开局"))
        #expect(rendered.says("上一步"))
        #expect(rendered.says("下一步"))
        #expect(rendered.says("让引擎走"), "one move from the engine, in the bar of the side to move")
        // Who plays each side, on that side's own bar, without anybody having to open anything.
        #expect(rendered.says("白方"))
        #expect(rendered.says("手动"))
        #expect(rendered.says("黑方"))
        #expect(rendered.says("Stockfish 18"), "the engine by name; its rung is on the same line")
        #expect(rendered.says(localized("search.limit")), "the shared search limit stays visible")
        #expect(
            !rendered.says("谁走"),
            "but the chips that change them stay folded once there are moves"
        )
        // And the Score stayed on the screen: it does *not* reach the game. A live search's
        // Depth is whatever it happened to get to, and a file that mixes those with a
        // Review's uniform ones cannot be ranked afterwards without inventing mistakes, so
        // only a Review writes an evaluation now (docs/adr/0016).
        #expect(session.game.plies.last?.evaluation == nil)
        #expect(!session.game.isReviewed)
    }

    /// A board just read off a photograph: nothing played yet, three squares the recogniser was
    /// not sure of, and the way back to the editor.
    @Test("a freshly recognised board offers the editor and rings what it was unsure of")
    func recognisedBoard() async throws {
        let fen = "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/2P2N2/PP1P1PPP/RNBQK2R w KQkq - 0 5"
        let game = try #require(Game(startFEN: fen))
        let session = GameSession.recognised(
            game, shaky: [Square("c6")!, Square("f6")!, Square("c5")!]
        )

        let rendered = await ScreenImage.write("game-recognised") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true), opening: .tactics)
        }

        #expect(session.unconfirmedSquares.count == 3, "the shaky squares stay ringed on the board")
        #expect(rendered.says(localized("record.opening")))
        // Settings stay folded even on a freshly recognised position.
        #expect(!rendered.says("谁走"))
        #expect(rendered.says(localized("game.settings.expand", PieceColour.white.label)))
        #expect(rendered.says("手动"))
        #expect(rendered.says("先走的是白方"))
        #expect(rendered.says("翻转棋盘"))
        // Nothing to walk through yet, and the engine can be asked to open.
        #expect(rendered.says("让引擎走"))
    }

    /// A game opened again from the library, which opens where it began.
    @Test("a saved game reopens at its first position, ready to be walked forward")
    func reopenedGame() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let entry = GameLibrary.Entry(
            url: URL(filePath: "/games/chessfen-2026-08-12-190000.pgn"),
            pgn: PGN(game: game, tags: [PGN.Tag("White", "手动"), PGN.Tag("Black", "引擎")]),
            modified: Date(timeIntervalSince1970: 1_786_000_000)
        )
        let session = try #require(GameSession.opened(entry))

        let rendered = await ScreenImage.write("game-reopened") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }

        #expect(session.cursor == 0, "a reopened game opens at the position it began in")
        // Where the eye is is the record's own job — the filled card. What a browsing game needs
        // in words is the way back to the present, and that is beside the arrows that left it.
        #expect(rendered.says("回到最新"))
        #expect(rendered.says("第 1 步 e4"), "the moves are all there to be walked through")
        #expect(rendered.says("第 2 步 e5"))
        #expect(rendered.says("开局"), "including the position it began in")
    }

    /// The engine on the clock. It is thinking about its own move rather than advising, and the one
    /// thing to do about that is stop waiting.
    @Test("while the engine is on the clock the screen offers to stop waiting for it")
    func engineThinking() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(
            game, controllers: [.white: .engine, .black: .hand]
        )
        let gate = AsyncStream<Analysis>.makeStream()
        gate.continuation.yield(Self.opinion(.centipawns(38), best: ("d2d4", "d4")))
        defer { gate.continuation.finish(); session.suspend() }

        let rendered = await ScreenImage.write("game-engine-thinking") {
            screen(session, engine: ScriptedEngine([], controlled: { position, _ in
                position.state.fen == game.state.fen ? gate.stream : nil
            }))
        }

        #expect(session.isThinking, "the engine's own turn starts the moment the screen appears")
        #expect(rendered.says("马上走"))
        #expect(!rendered.says("+0.38"), "the engine's move is walked without its opinion being shown")
        #expect(rendered.says("白方"))
        #expect(rendered.says("Stockfish 18"), "the engine by name, on its own bar")
        #expect(rendered.says(localized("search.limit")))
        #expect(rendered.says("手动"), "and the side a person is holding says so too")
        #expect(
            !session.canPlayBestMove,
            "and 让引擎走 stands down while the engine is already walking this one"
        )
    }

    /// Ten seconds later. The position search has run to its budget and stopped itself, which is
    /// the whole point of a bounded search (docs/adr/0020, 0039) — and the strip under the board
    /// keeps the depth it reached, or a number that quietly stopped moving reads as an engine
    /// that died.
    @Test("a finished search keeps the depth it reached without offering another")
    func searchSpent() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(
            game, controllers: [.white: .hand, .black: .engine]
        )

        let rendered = await ScreenImage.write("game-search-spent") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }

        #expect(!session.isSearching, "the search stopped on its own rather than running on")
        #expect(!rendered.says("再算 10 秒"), "the same position must never be searched again")
        #expect(rendered.says(localized("game.depth", 26)), "with where it got to still standing")
        #expect(rendered.says("优势条"), "and the bar it found it for")
        #expect(!rendered.says("建议 d4"), "finishing a search does not reveal a finding")
    }

    /// Both Controllers on the engine: the app playing itself. The screen names the budget each
    /// move is on — and says how to stop waiting for it.
    @Test("with both sides on the engine the screen names the budget and says how to stop")
    func selfPlay() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let session = GameSession.fresh(
            game, controllers: [.white: .engine, .black: .engine]
        )
        let gate = AsyncStream<Analysis>.makeStream()
        gate.continuation.yield(Self.opinion(.centipawns(38), best: ("e2e4", "e4")))
        defer { gate.continuation.finish(); session.suspend() }

        let rendered = await ScreenImage.write("game-self-play") {
            screen(session, engine: ScriptedEngine([], controlled: { position, _ in
                position.state.fen == game.state.fen ? gate.stream : nil
            }))
        }

        #expect(rendered.says("白方"))
        #expect(rendered.says("黑方"))
        #expect(rendered.says("Stockfish 18"))
        // The current clock stays visible; alternative clocks stay in the folded settings.
        #expect(!rendered.says("每步"))
        #expect(!rendered.says("3 秒"))
        #expect(rendered.says(localized("search.limit")))
        #expect(!rendered.says("跟着我"))
        #expect(rendered.says("马上走"), "with the way to stop waiting for the move on the clock")
    }

    /// The same game at night. Every colour on this screen has a dark half that nothing else looks
    /// at, and a palette is not checked by reading its hex values.
    @Test("the game screen holds up in the dark")
    func gameAtNight() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(
            game, controllers: [.white: .hand, .black: .engine]
        )

        let rendered = await ScreenImage.write("game-in-play-dark", style: .dark) {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }

        #expect(rendered.says("白方"))
        #expect(rendered.says("该走了"))
        #expect(rendered.says(localized("game.depth", 26)))
        #expect(rendered.says("让引擎走"))
    }

    /// A move played over an earlier one. It replaces what followed rather than branching beside
    /// it: a Game is a list now, not a tree (docs/adr/0028), and somebody taking a move back and
    /// playing another has played one game, not two.
    @Test("a move played over an earlier one drops the line it replaced")
    func replayedFromEarlier() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(game)
        // Back to before 4. c3, and play something else there.
        session.step(by: -2)
        let other = try #require(session.viewed.state.legalMoves.first { $0.uci == "d2d3" })
        session.play(other)
        // And stand one back from it, so the record is drawn with a past to walk back into.
        session.step(by: -1)

        let rendered = await ScreenImage.write("game-replayed") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true), opening: .tactics)
        }

        #expect(session.game.plies.count == 7, "the tail it was played over is gone, not kept")
        #expect(rendered.says("回到最新"), "and the way back to the present, beside the arrows")
        #expect(rendered.says("第 7 步 d3"), "with the move that replaced it in the record")
        #expect(!rendered.says("第 7 步 c3"), "and no sign of the move it replaced")
        #expect(!rendered.says("第 8 步 Nf6"), "nor of what used to follow that")
    }

    /// A finished game. The engine has nothing to search and so says nothing, and the screen has to
    /// say who won anyway.
    @Test("a game that ended in mate reads as won, not as level")
    func matedGame() async throws {
        // 1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qxf7#
        let mate = ["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6", "h5f7"]
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: mate))
        let session = GameSession.fresh(game)
        #expect(game.state.outcome == .checkmate)

        // An engine with nothing to say, which is what a real one does with a finished position.
        let rendered = await ScreenImage.write("game-mated") {
            screen(session, engine: ScriptedEngine([]))
        }

        #expect(rendered.says("白方将杀"))
        #expect(rendered.says("白方胜"), "the bar reads the result rather than sitting half and half")
        #expect(rendered.says("1-0"), "and the number the screen has been showing resolves into it")
        #expect(
            rendered.says("正着"),
            "interception remains the page's single mode switch"
        )
        #expect(!rendered.says("和棋"))
        #expect(!rendered.says("未知"), "a finished game is not an unknown one")
        // There is nothing left to play, so the one button that plays a move is out.
        #expect(!session.canPlayBestMove)
        #expect(rendered.says("第 7 步 Qxf7#"), "the record ends where the game did")
        #expect(!rendered.says("该走了"), "and nobody is on the clock in a game that is over")
    }

    /// The engine plays on but says nothing about the position, so the screen has to account for
    /// the number it is not showing. Nothing is switched here — this is a Game as it opens, and
    /// there is no switch (docs/adr/0040).
    @Test("the engine's opinion is off the screen, and the screen says why")
    func practising() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(game)

        let rendered = await ScreenImage.write("game-practising") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }

        #expect(!rendered.says("练习"))
        #expect(
            rendered.says("正着"),
            "the page exposes interception, not a separate practice/advice mode"
        )
        #expect(rendered.says(localized("standing.bar")), "assessment is visible independently of answers")
        #expect(session.analysis == nil, "finding availability does not enable advisory scores")
        #expect(session.isFindingTactics, "availability is discovered automatically")
        #expect(!rendered.says("建议 d4"), "discovery does not reveal the move")
    }

    /// Opening a completed finding preserves the depth it reached without claiming it is running.
    @Test("an opened finding names the depth reached by its completed probe")
    func aSearchingCardNamesItsDepth() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let engine = ScriptedEngine(Self.searching, isEndless: true)
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        let rendered = await ScreenImage.write("game-card-searching", interact: { window in
            #expect(ScreenImage.activate(localized("discovery.view"), in: window))
        }) {
            screen(session, engine: engine, opening: .tactics)
        }

        #expect(!session.isProbingTactics)
        #expect(rendered.says(localized("search.reached")))
        #expect(!rendered.says(localized("till.judging")))
        #expect(rendered.says(localized("game.depth", 26)), "the Depth is a figure of its own")
        #expect(rendered.says(localized("standing.bar")))
    }

    /// Practice still on, the finder on: one shot named, no Score. This is the combination
    /// docs/adr/0023 exists for.
    @Test("the tactics finder names a shot while practice stays on")
    func tacticsFinderDuringPractice() async throws {
        let fen = "4k3/8/8/3r4/8/8/8/3QK3 w - - 0 1"
        let game = try #require(Game(startFEN: fen))
        let engine = ScriptedEngine(
            [],
            byPosition: [
                game.state.fen: Analysis(
                    depth: 10,
                    lines: [
                        Line(score: .centipawns(500), uciMoves: ["d1d5", "e8e7", "d5e5"], san: ["Qxd5", "Ke7", "Qe5+"]),
                        Line(score: .centipawns(20), uciMoves: ["e1d2"], san: ["Kd2"]),
                    ]
                )
            ]
        )
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        let rendered = await ScreenImage.write("game-tactics-finder", interact: { window in
            #expect(!ScreenImage.words(in: window).contains { $0.contains("没人守的车") })
            #expect(ScreenImage.activate(localized("discovery.view"), in: window))
        }) {
            screen(session, engine: engine, opening: .tactics)
        }
        await hop()

        #expect(session.isFindingTactics, "arriving at the card opened it")
        #expect(session.tactic?.move.uci == "d1d5")
        #expect(rendered.says("战术"))
        #expect(rendered.says("有战术"))
        #expect(rendered.says("没人守的车"))
        #expect(rendered.says("Ke7"))
        #expect(rendered.says("Qe5+"))
        #expect(rendered.says(localized("screen.hideArrows")))
        #expect(session.game.uciMoves.isEmpty, "drawing a continuation must not play it")
        #expect(rendered.says(localized("standing.bar")))
        #expect(!rendered.says("建议"))
    }

    // ------------------------------------------------------------------- the news

    /// Morphy's opera game, one move before 16.Qb8+, with practice on and only the finder on.
    ///
    /// The screenshot the feature is answerable to: nobody asked, the deck is open at the news
    /// rather than at 问一格, the line is on the chips in the order it goes, and there is still not
    /// a Score anywhere (docs/adr/0015, 0024).
    @Test("a mate reveals its owner and line only after opening the finding")
    func mateNewsIsOurs() async throws {
        let opera = "4kb1r/p2n1ppp/4q3/4p1B1/4P3/1Q6/PPP2PPP/2KR4 w - - 0 1"
        let game = try #require(Game(startFEN: opera))
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
        session.setFindingTactics(true)
        await hop()

        let rendered = await ScreenImage.write("game-mate-news-ours", interact: { window in
            #expect(!ScreenImage.words(in: window).contains { $0.contains("Qb8+") })
            #expect(ScreenImage.activate(localized("discovery.view"), in: window))
            await ScreenImage.settle()
            #expect(ScreenImage.activate(localized("screen.hideArrows"), in: window))
            await ScreenImage.settle()
            #expect(ScreenImage.words(in: window).contains(localized("screen.showArrows")))
            #expect(ScreenImage.activate(localized("screen.showArrows"), in: window))
        }) {
            screen(session, engine: engine)
        }

        // The card the deck dealt itself to, wearing whose mate it is in its own title.
        #expect(rendered.says("你有 2 步杀"))
        #expect(rendered.says("你起手 Qb8+，对方只有一个应手，Rd8# 将死。"))
        // The line, numbered to match the arrows the board is drawing.
        #expect(rendered.says("Qb8+"))
        #expect(rendered.says("Nxb8"))
        #expect(rendered.says("Rd8#"))
        #expect(rendered.says("把箭头收起"), "arriving drew them, and one press takes them off")
        #expect(!rendered.says(localized("screen.arrowsExplained")), "instructions belong to the button hint, not another row")
        #expect(session.mateNews?.arrows.count == 3)
        // The board is untouched: the mate is a fact, and a Score would be an opinion.
        #expect(!rendered.says("建议"), "no recommendation, because that is an opinion")
        // The deck is not on the card it usually opens: the names are on the rail, so what says
        // which one is showing is the card's own subtitle.
        #expect(!rendered.says("几步之内有人要被将死了"), "the expanded answer needs no repeated subtitle")
        #expect(!rendered.says("我哪些子能走到这一格"))
    }

    /// The same game one move on, from the other seat: 16.Qb8+ is on the board, the player is
    /// Black, and Black is the one being mated. One signed number, one code path, the other voice
    /// — and the line opens with the player's own best try rather than the opponent's plan, which
    /// is a different sentence and says so (docs/adr/0025).
    @Test("the opponent's mate is the same news in the other voice, and opens with your own move")
    func mateNewsIsTheirs() async throws {
        let afterCheck = "1Q2kb1r/p2n1ppp/4q3/4p1B1/4P3/8/PPP2PPP/2KR4 b - - 0 1"
        let game = try #require(Game(startFEN: afterCheck))
        let engine = ScriptedEngine(
            [],
            byPosition: [
                game.state.fen: Analysis(
                    depth: 10,
                    lines: [
                        Line(
                            score: .mate(in: 1),
                            uciMoves: ["d7b8", "d1d8"],
                            san: ["Nxb8", "Rd8#"]
                        )
                    ]
                )
            ]
        )
        let session = GameSession.fresh(game, controllers: [.white: .engine, .black: .hand])
        session.attach(engine: engine, library: nil)
        session.setFindingTactics(true)
        await hop()

        let rendered = await ScreenImage.write("game-mate-news-theirs", interact: { window in
            #expect(!ScreenImage.words(in: window).contains { $0.contains("Rd8#") })
            #expect(ScreenImage.activate(localized("discovery.view"), in: window))
        }) {
            screen(session, engine: engine)
        }

        #expect(rendered.says("对方 1 步杀"))
        #expect(rendered.says("你怎么走都躲不掉"))
        #expect(rendered.says("引擎给的最好一手是 Nxb8"))
        #expect(rendered.says("Rd8# 将死"))
        #expect(session.mateNews?.isOurs == false)
        // Your own move is the near colour and the mate is the far one, whoever the news is about.
        #expect(session.mateNews?.arrows.map(\.isYours) == [true, false])
        #expect(rendered.says("被将"), "and the bar says what the board already shows")
    }


    /// The other half of the same rule: with nothing in progress the news still takes the eye,
    /// which is what 「直接给予提示」 amounts to on a deck (docs/adr/0025).
    @Test("with nothing in progress the news still takes the eye")
    func mateNewsStillTakesTheEye() async throws {
        let opera = "4kb1r/p2n1ppp/4q3/4p1B1/4P3/1Q6/PPP2PPP/2KR4 w - - 0 1"
        let game = try #require(Game(startFEN: opera))
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
        // Dealt to 要害 — the card that acts is not the news — and the search that finds the mate
        // is that card's own Stint, arriving a hop later.
        _ = await ScreenImage.write("game-news-takes-the-eye") {
            screen(session, engine: engine, opening: .tactics)
        }
        await hop()

        #expect(session.mateNews != nil)
        #expect(
            session.isFindingTactics,
            "the deck moved to 杀招, and arriving there is what turns the probe on"
        )
    }

    /// The same game, the same engine, the same moves played into it — and nothing whispered.
    /// This is the screenshot the default is answerable to: a person reading it should not be able
    /// to work out what the engine thinks of the position, and should be in no doubt that the app
    /// is working.
    @Test("a game in play says nothing about the position until it is asked to")
    func gameInPlaySaysNothing() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(game, controllers: [.white: .hand, .black: .engine])

        let rendered = await ScreenImage.write("game-in-play-silent") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }

        // Not one number, not one line, not one of the engine's candidates.
        #expect(rendered.says(localized("standing.bar")), "feedback does not disclose a move")
        #expect(!rendered.says("d4 exd4 cxd4 Bb6"))
        #expect(!rendered.says("O-O d6 d4 Bb6"))
        #expect(!rendered.says("d3 d6 O-O a6"))
        #expect(
            session.analysis == nil,
            "the dealt card is at rest: nothing was asked, so there is nothing to keep off screen"
        )

        // And the screen accounts for the silence rather than wearing the face of a broken engine.
        #expect(!rendered.says("练习"))
        #expect(!rendered.says("引擎意见"))
        #expect(rendered.says("正着"))
        // The game itself is entirely unaffected: the moves, the clock, the engine as an opponent.
        #expect(rendered.says("第 8 步 Nf6"))
        #expect(rendered.says("该走了"))
        #expect(rendered.says("让引擎走"))
        #expect(rendered.says("Stockfish 18"), "which still plays Black")
    }

    // ------------------------------------------------------------------- the study

    /// The searches behind a reveal run in tasks of their own, so their answers are known a hop
    /// later — which is as true of the screen as it is of this test.
    private func hop() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The app in French — the one screenshot here that proves eight tables of words reached the
    /// app rather than only the one it was written in. Every other picture in this file would look
    /// exactly the same if seven of them had been left behind, because a missing language falls
    /// back to Chinese by design (docs/adr/0019).
    ///
    /// The live screen rather than a card, because the live screen is the one every player sees:
    /// whose move it is, the record's own controls, and the button that hands the move over. If a
    /// table went missing, this is where it shows.
    @Test("the same screen, in French", .speaking(.french))
    func gameInFrench() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(game, controllers: [.white: .hand, .black: .engine])

        let rendered = await ScreenImage.write("game-in-french") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }

        #expect(rendered.says("Au trait"))
        #expect(rendered.says("Fais jouer"))
        #expect(rendered.says("Coup précédent"))
        #expect(rendered.says("Coup suivant"))
        #expect(rendered.says("Départ"))
        // And nothing has leaked back from the language it was all written in.
        #expect(!rendered.says("该走了"))
        #expect(!rendered.says("让引擎走"))
    }

    // ------------------------------------------------------------ 掉幅 on the record

    /// Every measured move on the record carries its cost under it (#48): a 正着 game prices the
    /// player's own moves and leaves the engine's blank, and the mark at the foot of a cell speaks
    /// as a mistake made from that position rather than as this move's cost.
    @Test("the record says what each measured move cost")
    func costsOnTheRecord() async throws {
        let session = try Self.tallied()
        let rendered = await ScreenImage.write("game-record-costs") {
            screen(session, engine: ScriptedEngine([]))
        }
        let sep = localized("clause.separator")
        #expect(session.game.hasCosts)
        #expect(rendered.says(localized("screen.spokenMove", 1, "e4") + sep + localized("book.cost", 1)))
        #expect(rendered.says(localized("screen.spokenMove", 7, "c3") + sep + localized("book.cost", 1)))
        #expect(rendered.words.contains(localized("screen.spokenMove", 2, "e5")), "the engine's move was never judged: no cost, and not zero")
        // Nh3 was refused at the position after 4. Nc6, so that cell wears the mark — and says so.
        #expect(rendered.says(localized("screen.spokenMove", 4, "Nc6") + sep + localized("record.slipMark", 12)))
        #expect(!rendered.says(localized("screen.spokenMove", 4, "Nc6") + sep + localized("book.cost", 12)), "the mark is not this move's cost")
    }

    /// A reviewed game prices both sides, and a move that cost nothing says 「0」 rather than nothing.
    @Test("a reviewed record prices both sides, zero included")
    func costsOnAReviewedRecord() async throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        game.applyReview(
            [30, 30, 30, 90, 90, 90, 90, 90].map { Score.centipawns($0) },
            startEvaluation: .centipawns(30), depth: 16
        )
        let session = GameSession.fresh(game)
        let rendered = await ScreenImage.write("game-record-costs-reviewed") {
            screen(session, engine: ScriptedEngine([]))
        }
        let sep = localized("clause.separator")
        let gaveAway = try #require(game.cost(atPly: 4))
        #expect(gaveAway > 0, "4... Nc6 let the position slide")
        #expect(rendered.says(localized("screen.spokenMove", 4, "Nc6") + sep + localized("book.cost", Drop.points(gaveAway))))
        #expect(rendered.says(localized("screen.spokenMove", 1, "e4") + sep + localized("book.cost", 0)), "a move that cost nothing says so")
        #expect(rendered.says(localized("screen.spokenMove", 8, "Nf6") + sep + localized("book.cost", 0)), "the engine's moves are priced too")
    }

    // ------------------------------------------------------------------------- 复判

    /// f3 e5 with g4 refused at the position on the board, judged at `depth` with Qh4 as its 应招.
    private static func refusedG4(depth: Int? = 20) throws -> Game {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["f2f3", "e7e5"]))
        game.recordTried(.init(san: "g4", drop: 40, depth: depth, line: ["Qh4"]), atPly: 2)
        return game
    }

    private static let afterG4FEN = "rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq - 0 2"

    private func until(_ settled: () -> Bool, seconds: Double = 5) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !settled(), ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Contract: the 应招 reading offers 「算到 28 层」 for a 试招 judged shallower; pressed, the
    /// button's place shows the depth climbing; when both ends have finished the chip's number, the
    /// line and the depth change together, and the button is gone (#50, docs/adr/0041).
    @Test("the reading offers 复判, shows the depth climbing, and lands the deeper number")
    func rejudgeFromTheReading() async throws {
        let game = try Self.refusedG4()
        let before = AsyncStream<Analysis>.makeStream()
        let after = AsyncStream<Analysis>.makeStream()
        let afterFEN = Self.afterG4FEN
        let engine = ScriptedEngine([], controlled: { position, budget in
            guard budget == PositionSearches.deeper else { return nil }
            return position.state.fen == afterFEN ? after.stream : before.stream
        })
        let session = GameSession.fresh(game, engine: engine)
        defer { session.suspend() }
        session.jumpToLatest()
        let quiet = [Line(score: .centipawns(20), uciMoves: ["d2d4"], san: ["d4"])]

        let rendered = await ScreenImage.write("game-rejudge", interact: { window in
            #expect(ScreenImage.activate("g4", in: window), "the chip opens the reading")
            await ScreenImage.settle()
            var words = ScreenImage.words(in: window)
            #expect(words.contains { $0.contains(localized("tried.rejudge", 28)) }, "the reading offers it")
            #expect(words.contains { $0.contains(localized("game.depth", 20)) }, "and says how deep the move was judged")
            #expect(ScreenImage.activate(localized("tried.rejudge", 28), in: window), "the button must be pressable")
            await until { engine.searchCount >= 2 }
            before.continuation.yield(Analysis(depth: 24, lines: quiet))
            await ScreenImage.settle()
            words = ScreenImage.words(in: window)
            #expect(words.contains { $0.contains(localized("game.depth", 24)) }, "the depth climbs where the button was")
            #expect(!words.contains { $0.contains(localized("tried.rejudge", 28)) })
            #expect(words.contains { $0.contains("−40%") }, "the chip does not change until the number lands")
            before.continuation.yield(Analysis(depth: 28, lines: quiet))
            before.continuation.finish()
            await until { engine.searchCount >= 4 }
            after.continuation.yield(Analysis(depth: 28, lines: [Line(score: .mate(in: -1), uciMoves: ["d8h4"], san: ["Qh4"])]))
            after.continuation.finish()
            await until { session.rejudging == nil }
            await ScreenImage.settle()
        }) {
            screen(session, engine: engine)
        }
        let landed = try #require(session.visibleAttempts.first)
        #expect(landed.depth == 28)
        #expect(landed.drop > 40, "a mate in one is worse than the everyday search made it")
        #expect(rendered.says(localized("game.depth", 28)))
        #expect(!rendered.says(localized("tried.rejudge", 28)), "at 28 there is nothing more to offer")
        #expect(rendered.says(Drop.figure(landed.drop)), "the chip carries the new number")
        #expect(rendered.says("Qh4"), "and the line is the deeper search's")
        #expect(session.game.uciMoves == ["f2f3", "e7e5"], "the refusal stands")
    }

    /// A 试招 from an older file carries no depth: the reading shows none, and offers the 复判.
    @Test("the reading, in English, for a move judged at no known depth", .speaking(.english))
    func rejudgeOfferedInEnglish() async throws {
        let engine = ScriptedEngine([])
        let session = GameSession.fresh(try Self.refusedG4(depth: nil), engine: engine)
        defer { session.suspend() }
        session.jumpToLatest()
        let rendered = await ScreenImage.write("game-rejudge-english", interact: { window in
            #expect(ScreenImage.activate("g4", in: window))
            await ScreenImage.settle()
        }) {
            screen(session, engine: engine)
        }
        #expect(rendered.says("Search to depth 28"))
        #expect(!rendered.says("Depth 20"), "no depth is invented for an older file")
        #expect(session.rejudgeOffer(at: 0) == .ready)
    }

    /// While the engine is spoken for — here, 正着's own search of the position still running —
    /// the button is there but greyed, and pressing it does nothing.
    @Test("the button waits while the engine is busy")
    func rejudgeWaitsForTheEngine() async throws {
        // An everyday search that never answers, so 正着's preparation of the next move stays open.
        let engine = ScriptedEngine([], controlled: { _, _ in AsyncStream { _ in } })
        let session = GameSession.fresh(try Self.refusedG4(), engine: engine)
        defer { session.suspend() }
        session.jumpToLatest()
        session.setTilling(true)
        await hop()
        #expect(session.isSearching, "正着 is preparing its interception of the next move")
        let rendered = await ScreenImage.write("game-rejudge-waiting", interact: { window in
            #expect(ScreenImage.activate("g4", in: window))
            await ScreenImage.settle()
            #expect(session.rejudgeOffer(at: 0) == .waiting)
            _ = ScreenImage.activate(localized("tried.rejudge", 28), in: window)
            await ScreenImage.settle()
            #expect(session.rejudging == nil, "greyed: pressing it starts nothing")
        }) {
            screen(session, engine: engine)
        }
        #expect(rendered.says(localized("tried.rejudge", 28)), "the button is there to be waited on")
    }

    // ---------------------------------------------------------------- 最佳

    /// The engine's own first choice, played by the hand: the strip says the word, not `+0.0%`.
    private static func bestMovePlayed() throws -> (GameSession, ScriptedEngine) {
        let start = try #require(Game(startFEN: PGN.standardStartFEN))
        let played = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ["e2e4"]))
        let engine = ScriptedEngine([], byPosition: [
            start.state.fen: Analysis(depth: 20, lines: [
                .init(score: .centipawns(30), uciMoves: ["e2e4", "e7e5"], san: ["e4", "e5"]),
                .init(score: .centipawns(20), uciMoves: ["d2d4"], san: ["d4"]),
            ]),
            played.state.fen: Analysis(depth: 20, lines: [
                .init(score: .centipawns(-40), uciMoves: ["e7e5"], san: ["e5"]),
            ]),
        ])
        let session = GameSession.fresh(played, engine: engine)
        session.showPositionFeedback()
        return (session, engine)
    }

    @Test("the strip says 最佳 for the engine's own first choice")
    func theStripSaysBest() async throws {
        let (session, engine) = try Self.bestMovePlayed()
        defer { session.suspend() }
        await session.measureLatestMoveChange()
        #expect(session.standing == .best)
        let rendered = await ScreenImage.write("game-best-move") { screen(session, engine: engine) }
        #expect(rendered.says("最佳"))
        #expect(!rendered.words.contains("+0.0%"), "the word, not the number")
        #expect(rendered.says("本步胜率变化 +0.0%"), "VoiceOver still gets the number")
    }

    @Test("the strip says Best move, in English", .speaking(.english))
    func theStripSaysBestInEnglish() async throws {
        let (session, engine) = try Self.bestMovePlayed()
        defer { session.suspend() }
        await session.measureLatestMoveChange()
        let rendered = await ScreenImage.write("game-best-move-english") { screen(session, engine: engine) }
        #expect(rendered.says("Best move"))
    }

    // ------------------------------------------------------------ 正着数 · 连正

    /// The Italian with 正着 on: White's four moves all stood, and a 试招 at 3. Bc4 broke the run,
    /// so the row says 「连正 2」 (docs/adr/0038).
    private static func tallied() throws -> GameSession {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: italian))
        let stood = Game.Ply.Judgement(drop: 1, score: .centipawns(20), depth: 20, intercept: 5)
        for ply in [0, 2, 4, 6] { game.setJudgement(stood, atPly: ply) }
        game.setTried([.init(san: "Nh3", drop: 12)], atPly: 4)
        let session = GameSession.fresh(game, controllers: [.white: .hand, .black: .engine])
        session.setIntercept(5)
        return session
    }

    /// 连正 sits on the 正着 row, next to the switch, so the number a 正着 game is about is in
    /// view while it is being played.
    @Test("the 正着 row counts the run the player is on")
    func theTallyOnTheRow() async throws {
        let session = try Self.tallied()
        let rendered = await ScreenImage.write("game-tally") {
            screen(session, engine: ScriptedEngine([]))
        }
        #expect(session.noSlips == .init(run: 2, longestRun: 2))
        #expect(rendered.says("连正 2"))
        #expect(!rendered.says("正着 4"), "and no count of everything that stood")
    }

    @Test("the tally, in English", .speaking(.english))
    func theTallyInEnglish() async throws {
        let session = try Self.tallied()
        let rendered = await ScreenImage.write("game-tally-english") {
            screen(session, engine: ScriptedEngine([]))
        }
        #expect(rendered.says("Run 2"))
    }

    /// Nothing to count, nothing said: a game with the switch off and no move that stood keeps
    /// the row as it was.
    @Test("a game that never stood under 正着 shows no tally")
    func noTallyWithoutNoSlips() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(game, controllers: [.white: .hand, .black: .engine])
        let rendered = await ScreenImage.write("game-no-tally") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }
        #expect(!rendered.says("连正"))
    }

    // ---------------------------------------------------------------- 棋力

    /// The rung on the engine's own bar (docs/adr/0038): 「Stockfish 18 · 1800」 at a rung, the
    /// name alone at 满力, and for VoiceOver the word for what the number is.
    @Test("the engine's bar names its rung, and only its name at 满力")
    func theEngineBarNamesItsRung() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let bound = GameSession.fresh(
            game, controllers: [.white: .hand, .black: .engine], strength: .elo(1800)
        )
        let rendered = await ScreenImage.write("game-rung-1800") {
            screen(bound, engine: ScriptedEngine(Self.searching, isEndless: true))
        }
        #expect(rendered.says("Stockfish 18 · 1800"))
        #expect(rendered.says("棋力"), "VoiceOver says what the number is")

        let unbound = GameSession.fresh(game, controllers: [.white: .hand, .black: .engine])
        let atFull = await ScreenImage.write("game-rung-full") {
            screen(unbound, engine: ScriptedEngine(Self.searching, isEndless: true))
        }
        #expect(atFull.says("Stockfish 18"))
        #expect(!atFull.says("Stockfish 18 ·"), "the name alone at 满力")
    }

    /// Where a hand holds the side, there is no rung to show: a person is not at a 棋力.
    @Test("a hand's bar has no rung")
    func aHandHasNoRung() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(game)
        let rendered = await ScreenImage.write("game-rung-hands") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }
        #expect(!rendered.says("Stockfish 18"))
        #expect(!rendered.says("棋力"))
    }

    /// A game the engine played at 2000 reopens at 2000, whatever rung the player has since
    /// climbed to: the rung is the game's, written on its moves (docs/adr/0038).
    @Test("a reopened game opens at the rung its engine moves were played at")
    func reopenedGameKeepsItsRung() async throws {
        var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        for ply in [1, 3, 5, 7] { game.setStrength(.elo(2000), atPly: ply) }
        let entry = GameLibrary.Entry(
            url: URL(filePath: "/games/chessfen-2026-08-12-190000.pgn"),
            pgn: PGN(game: game, tags: [PGN.Tag("White", "手动"), PGN.Tag("Black", "Stockfish 18")]),
            modified: Date(timeIntervalSince1970: 1_786_000_000)
        )
        let session = try #require(GameSession.opened(entry, strength: .elo(1400)))
        #expect(session.strength == .elo(2000))

        let rendered = await ScreenImage.write("game-reopened-rung") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }
        #expect(rendered.says("Stockfish 18 · 2000"))
    }

    /// The rung picked is the one the next game starts at, on this phone and on the next one; a
    /// phone that has never picked starts at 满力.
    @Test("the rung picked is remembered, and a fresh phone starts at 满力")
    func theRungIsRemembered() {
        let setting = StrengthSetting.shared
        #expect(setting.strength == .full, "nothing picked yet")
        setting.strength = .elo(2200)
        defer { setting.strength = .full }
        #expect(UserDefaults.standard.string(forKey: "chessfen.strength") == "2200")
        #expect(NSUbiquitousKeyValueStore.default.string(forKey: "chessfen.strength") == "2200")
    }

    // ------------------------------------------------------------------- glue

    /// The screen as the app pushes it: inside a navigation stack, with the engine and the library
    /// in the environment. The engine is the only thing that is not the app's own.
    /// The screen, and — when a test is photographing something that lives on one card of the
    /// deck — the card to open on. The app decides that for itself from the position; a test says
    /// so, the same way it says which game and which engine (docs/adr/0025).
    private func screen(
        _ session: GameSession, engine: any Engine, opening: GameScreen.Card? = nil
    ) -> some View {
        NavigationStack {
            GameScreen(session: session, path: .constant([]), opening: opening)
        }
        .environment(EngineHost(engine))
        .environment(GameLibrary())
    }
}

/// The one thing this screen promises: the board does not move.
///
/// Everything around it changes every single move — whose bar is live, which side the engine is
/// answering for, what it is answering — and the board is what a person is looking at while it
/// does. A bar that grew by a line when its side came on the clock walked the board up and down
/// the screen once per ply, which is unusable and was invisible to every test that only read
/// words. So this one reads pixels.
@MainActor
@Suite(.serialized, .speaking(.chinese))
struct BoardStandsStill {
    private static let italian = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6"]

    private static let searching = [
        Analysis(
            depth: 24,
            selectiveDepth: 31,
            lines: [
                Line(
                    score: .centipawns(31),
                    uciMoves: ["d2d4", "e5d4"],
                    san: ["d4", "exd4"]
                )
            ],
            nodes: 50_000_000,
            nodesPerSecond: 2_400_000,
            timeMilliseconds: 20_000
        )
    ]

    @Test("the board sits in the same place whichever colour is on the clock")
    func boardDoesNotWalk() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))

        // The same game one ply apart: White to move, then Black to move. Nothing else differs.
        let white = GameSession.fresh(game)
        let whiteShot = await shoot("game-steady-white", white)

        let black = GameSession.fresh(game)
        black.step(by: -1)
        let blackShot = await shoot("game-steady-black", black)

        #expect(white.viewed.state.sideToMove == .white)
        #expect(black.viewed.state.sideToMove == .black)

        let onWhite = try #require(boardEdges(of: whiteShot.url))
        let onBlack = try #require(boardEdges(of: blackShot.url))
        // A pixel, not a point: at three pixels to the point that is the hairline above the board
        // landing either side of a boundary, and no eye has ever seen it. A ply's worth of bar is
        // seventy-five.
        #expect(
            abs(onWhite.lowerBound - onBlack.lowerBound) <= 1,
            "the board's top moved between plies: \(onWhite) then \(onBlack)"
        )
        #expect(
            abs(onWhite.count - onBlack.count) <= 1,
            "the board changed size between plies: \(onWhite) then \(onBlack)"
        )
    }

    // ------------------------------------------------------------------- glue

    private func shoot(_ name: String, _ session: GameSession) async -> ScreenImage.Rendered {
        await ScreenImage.write(name) {
            NavigationStack {
                GameScreen(session: session, path: .constant([]))
            }
            .environment(EngineHost(ScriptedEngine(Self.searching, isEndless: true)))
            .environment(GameLibrary())
        }
    }

    /// The rows down the middle of the picture that the board occupies.
    ///
    /// Told apart by colour: the squares are saturated wood (a red end and a dim blue end), and
    /// everything else on this screen — parchment, the white half of the advantage bar, teal,
    /// ink — fails one of the two. The longest run of them rather than the outermost, because a
    /// stray antialiased pixel somewhere up in the bars would otherwise pass for the board's edge.
    private func boardEdges(of url: URL) -> ClosedRange<Int>? {
        guard let image = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let column = width / 2
        var longest: ClosedRange<Int>?
        var start: Int?
        for row in 0...height {
            let isBoard: Bool
            if row == height {
                isBoard = false
            } else {
                let offset = (row * width + column) * 4
                isBoard = Int(pixels[offset]) > 0xB0 && Int(pixels[offset + 2]) < 0xC0
            }
            switch (isBoard, start) {
            case (true, nil):
                start = row
            case (false, .some(let from)):
                let run = from...(row - 1)
                if run.count > (longest?.count ?? 0) { longest = run }
                start = nil
            default:
                break
            }
        }
        return longest
    }
}
