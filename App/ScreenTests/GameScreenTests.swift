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

    /// A game under way against the engine, with the engine talking — which is to say somebody
    /// has reached down and turned its opinion on, because that is not where a Game starts.
    @Test("the game screen shows the position, what the engine makes of it, and the moves")
    func gameInPlay() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(
            game, controllers: [.white: .hand, .black: .engine]
        )
        session.setPractising(false)

        let rendered = await ScreenImage.write("game-in-play") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }

        // Whose move it is, said in that side's own bar, and what the engine says about it.
        #expect(rendered.says("白方"))
        #expect(rendered.says("该走了"))
        #expect(rendered.says("+0.38"), "the deeper snapshot should have replaced the shallow one")
        #expect(rendered.says("优势条"), "said once, at the end of the bar that draws it")
        #expect(
            !rendered.says("搜索深度"),
            "and not how fast the phone is going while it says it — that was a row of plumbing"
        )
        // How deep it has got, though, which is not the same thing: a search that stops after ten
        // seconds (docs/adr/0020) has to account for itself, or a number that stopped moving is
        // indistinguishable from an engine that died. One figure, in the strip, and no speed.
        #expect(rendered.says("深 26"))
        #expect(!rendered.says("再算"), "and no offer of more while it is still inside its Stint")
        // The move it would play, named beside the arrow the board draws — one move, because a
        // line of six is a language most people playing this have not learnt.
        #expect(rendered.says("建议 d4"))
        #expect(!rendered.says("d4 exd4 cxd4"), "and not the whole line it is the head of")
        // The deck under the record, dealt from this position: what a live board can be asked,
        // and nothing about a move that has not been played (docs/adr/0024). The runners-up have
        // a card of their own now — `deckReading` photographs it.
        #expect(rendered.says("要害"))
        #expect(rendered.says("杀招"))
        #expect(rendered.says("战术"))
        #expect(rendered.says("五步"))
        #expect(rendered.says("练习"))
        #expect(rendered.says("刚走的这一步做了什么"), "the card showing is 要害")
        #expect(!rendered.says("问一格"))
        #expect(!rendered.says("走马灯"))
        #expect(!rendered.says("五步计划"))
        #expect(!rendered.says("考一遍"))
        #expect(!rendered.says("这儿还问不了的"))
        // One card at a time, so the numbers on screen are the strip's and no more.
        #expect(rendered.count(of: "+0.") == 2)
        // The record, and the whole walk through it.
        #expect(rendered.says("第 8 步 Nf6"), "the record should carry the game, move by move")
        #expect(rendered.says("开局"))
        #expect(rendered.says("上一步"))
        #expect(rendered.says("下一步"))
        #expect(rendered.says("让引擎走"), "one move from the engine, in the bar of the side to move")
        // Who plays each side, on that side's own bar, without anybody having to open anything.
        #expect(rendered.says("白方"))
        #expect(rendered.says("手动"))
        #expect(rendered.says("黑方"))
        #expect(rendered.says("引擎"))
        #expect(rendered.says("跟着我"), "and the engine's clock, where the engine is playing")
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
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true), opening: .key)
        }

        #expect(session.unconfirmedSquares.count == 3, "the shaky squares stay ringed on the board")
        #expect(rendered.says("从这里开始走"))
        // Nothing is played yet, so the side to move has its own questions open.
        #expect(rendered.says("谁走"))
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

    /// A board just read off a photograph and then filed into a collection: the same reading, with
    /// its doubts settled by somebody keeping it.
    @Test("a filed game stops ringing the squares it once was unsure of")
    func filedBoard() async throws {
        let fen = "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/2P2N2/PP1P1PPP/RNBQK2R w KQkq - 0 5"
        let game = try #require(Game(startFEN: fen))
        // The filed state exists only as a saved game: a reading somebody kept, with the
        // collection it was kept in written into the file.
        let entry = GameLibrary.Entry(
            url: URL(filePath: "/games/chessfen-2026-08-12-190100.pgn"),
            pgn: PGN(game: game, tags: [
                PGN.Tag(GameOrigin.tagName, GameOrigin.recognised.rawValue),
                PGN.Tag("Event", "西西里防御"),
            ]),
            modified: Date(timeIntervalSince1970: 1_786_000_100)
        )
        let session = try #require(GameSession.opened(entry))

        let rendered = await ScreenImage.write("game-filed") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }

        #expect(session.isFiled)
        #expect(session.unconfirmedSquares.isEmpty, "no rings on a board somebody has kept")
        #expect(!rendered.says("拿不太准"), "and no question about the squares under them")
        #expect(!rendered.says("改棋子"))
        // A record opens in practice, so the engine holds its opinion: no advice, no number.
        #expect(!rendered.says("+0.38"))
    }

    /// The engine on the clock. It is thinking about its own move rather than advising, and the one
    /// thing to do about that is stop waiting.
    @Test("while the engine is on the clock the screen offers to stop waiting for it")
    func engineThinking() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(
            game, controllers: [.white: .engine, .black: .hand]
        )
        // The number this test is about is the engine's opinion, so it is turned on.
        session.setPractising(false)

        let rendered = await ScreenImage.write("game-engine-thinking") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }

        #expect(session.isThinking, "the engine's own turn starts the moment the screen appears")
        #expect(rendered.says("马上走"))
        #expect(rendered.says("+0.38"))
        #expect(rendered.says("白方"))
        #expect(rendered.says("引擎"))
        #expect(rendered.says("跟着我"))
        #expect(rendered.says("手动"), "and the side a person is holding says so too")
        #expect(
            !session.canPlayBestMove,
            "and 让引擎走 stands down while the engine is already walking this one"
        )
    }

    /// Ten seconds later. The advisory search has run its Stint and stopped itself, which is the
    /// whole point of a Stint (docs/adr/0020) — and the strip under the board has to say so, or a
    /// number that quietly stopped moving reads as an engine that died.
    @Test("when its Stint runs out the strip keeps the answer and offers another ten seconds")
    func adviceSpent() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(
            game, controllers: [.white: .hand, .black: .engine]
        )
        session.setPractising(false)
        // The app's Stint is ten seconds. A screenshot that waited ten seconds is a screenshot
        // nobody runs, so this one is over before the screen has finished settling.
        session.adviceStint = .milliseconds(100)

        let rendered = await ScreenImage.write("game-advice-spent") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }

        #expect(session.isAdviceSpent, "the search stopped on its own rather than running on")
        #expect(rendered.says("再算 10 秒"), "and the strip offers the one thing left to do")
        #expect(rendered.says("+0.38"), "with what it found still standing")
        #expect(rendered.says("优势条"), "and the bar it found it for")
        #expect(rendered.says("建议 d4"), "the move too — stopping is not forgetting")
    }

    /// Both Controllers on the engine: the app playing itself. There is no player's last move to
    /// mirror, so the screen has to name the clock it is on — and say how to stop it.
    @Test("with both sides on the engine the screen names the clock and says how to stop")
    func selfPlay() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN))
        let session = GameSession.fresh(
            game, controllers: [.white: .engine, .black: .engine]
        )

        let rendered = await ScreenImage.write("game-self-play") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true), opening: .key)
        }

        #expect(session.thinkingTime == .fixed(seconds: 3), "three seconds a move until told else")
        #expect(rendered.says("白方"))
        #expect(rendered.says("黑方"))
        #expect(rendered.says("引擎"))
        // The clock, on chips, with the mirror standing down for want of anybody to mirror.
        #expect(rendered.says("每步"))
        #expect(rendered.says("3 秒"))
        #expect(rendered.says("10 秒"))
        #expect(rendered.says("跟着我"))
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
        session.setPractising(false)

        let rendered = await ScreenImage.write("game-in-play-dark", style: .dark) {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }

        #expect(rendered.says("白方"))
        #expect(rendered.says("该走了"))
        #expect(rendered.says("+0.38"))
        #expect(rendered.says("让引擎走"))
    }

    /// A move played over an earlier one. The line it replaced is kept as a Variation, offered where
    /// it branches rather than lost — which is the whole reason 悔棋 is not how you go back.
    @Test("a move played over an earlier one offers the line it replaced")
    func variationKept() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(game)
        // Back to before 4. c3, and play something else there.
        session.step(by: -2)
        let other = try #require(session.viewed.state.legalMoves.first { $0.uci == "d2d3" })
        session.play(other)
        // And stand where the branch is, which is where the line that was replaced is offered.
        session.step(by: -1)

        let rendered = await ScreenImage.write("game-variation") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true), opening: .key)
        }

        #expect(session.variationsHere.count == 1, "the abandoned line is kept, not dropped")
        #expect(rendered.says("回到最新"), "and the way back to the present, beside the arrows")
        #expect(rendered.says("第 7 步 d3"), "with the move that replaced it in the record")
        #expect(rendered.says("树枝 2/2"), "the fork is named on that ply, still on the one row")
        #expect(rendered.says("切换分支"), "the rail is the switch, not a second list")
        #expect(!rendered.says("变着 c3 Nf6"), "the other line is reached by flipping, not a second row")
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
        #expect(
            session.isPractising,
            "the engine was never turned on here — the result is not its opinion"
        )
        #expect(rendered.says("白方胜"), "the bar reads the result rather than sitting half and half")
        #expect(rendered.says("1-0"), "and the number the screen has been showing resolves into it")
        #expect(
            rendered.says("引擎意见"),
            "with the one thing left to do said where the lines were — a switch, not a place"
        )
        #expect(!rendered.says("和棋"))
        #expect(!rendered.says("未知"), "a finished game is not an unknown one")
        // There is nothing left to play, so the one button that plays a move is out.
        #expect(!session.canPlayBestMove)
        #expect(rendered.says("第 7 步 Qxf7#"), "the record ends where the game did")
        #expect(!rendered.says("该走了"), "and nobody is on the clock in a game that is over")
    }

    /// Practice: the engine plays on but says nothing, so the screen has to account for the
    /// number it is not showing. Nothing is switched here — this is a Game as it opens.
    @Test("practice leaves the engine's opinion off the screen and says why")
    func practising() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(game)

        let rendered = await ScreenImage.write("game-practising") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }

        #expect(session.isPractising, "which is where a Game starts (docs/adr/0015)")
        #expect(rendered.says("练习"))
        #expect(
            rendered.says("引擎意见"),
            "practice points at the one switch that makes the engine talk"
        )
        #expect(!rendered.says("+0.38"), "no Score anywhere while practising")
        // One search did run, and it is the dealt card's own Stint: **dealing a card is an
        // arrival**, so 要害 answers while it is the card in front, and what it found is kept for
        // the card rather than for the board (docs/adr/0020, 0024). Practice hides the engine's
        // opinion; it does not stop the engine. What must never happen is any of it reaching the
        // board, which is what the words above are checking.
        #expect(session.analysis != nil, "the card in front asked, so a search ran")
    }

    /// A card spending a Stint has to say so, and how deep it has got. A number that quietly
    /// stops moving is indistinguishable from an engine that died (docs/adr/0020) — and that is
    /// as true on the card as it is on the strip.
    @Test("a card that is spending a Stint says so, and how deep it has got")
    func aSearchingCardNamesItsDepth() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let engine = ScriptedEngine(Self.searching, isEndless: true)
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        let rendered = await ScreenImage.write("game-card-searching") {
            screen(session, engine: engine, opening: .walk)
        }

        #expect(session.isPractising)
        #expect(rendered.says("正在算"))
        #expect(rendered.says("层级 26"), "the Depth is a figure of its own, not swallowed by 正在算")
        #expect(!rendered.says("+0.38"), "practice still keeps the Score off the board")
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
                        Line(score: .centipawns(500), uciMoves: ["d1d5"], san: ["Qxd5"]),
                        Line(score: .centipawns(20), uciMoves: ["e1d2"], san: ["Kd2"]),
                    ]
                )
            ]
        )
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        // Nobody flips the switch: swiping onto the card is the asking (docs/adr/0024).
        let rendered = await ScreenImage.write("game-tactics-finder") {
            screen(session, engine: engine, opening: .tactics)
        }
        await hop()

        #expect(session.isPractising)
        #expect(session.isFindingTactics, "arriving at the card opened it")
        #expect(session.tactic?.move.uci == "d1d5")
        #expect(rendered.says("战术"))
        #expect(rendered.says("有战术"))
        #expect(rendered.says("没人守的车"))
        #expect(!rendered.says("+5.00"), "no Score while practising — a card's Stint is for the card")
        #expect(!rendered.says("建议"))
    }

    // ------------------------------------------------------------------- the news

    /// Morphy's opera game, one move before 16.Qb8+, with practice on and only the finder on.
    ///
    /// The screenshot the feature is answerable to: nobody asked, the deck is open at the news
    /// rather than at 问一格, the line is on the chips in the order it goes, and there is still not
    /// a Score anywhere (docs/adr/0015, 0024).
    @Test("a mate on the board opens the deck by itself and says whose it is")
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

        let rendered = await ScreenImage.write("game-mate-news-ours") {
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
        #expect(rendered.says("这几步没有走进棋谱"))
        #expect(session.mateNews?.arrows.count == 3)
        // Practice is untouched on the board: the mate is a fact, and a Score would be an opinion.
        #expect(session.isPractising)
        #expect(!rendered.says("建议"), "no recommendation, because that is an opinion")
        // The deck is not on the card it usually opens: the names are on the rail, so what says
        // which one is showing is the card's own subtitle.
        #expect(rendered.says("几步之内有人要被将死了"))
        #expect(!rendered.says("我哪些子能走到这一格"))
    }

    /// The same game one move on, from the other seat: 16.Qb8+ is on the board, the player is
    /// Black, and Black is the one being mated. One signed number, one code path, the other voice
    /// — and the line opens with the player's own best try rather than the opponent's plan, which
    /// is a different sentence and says so (docs/adr/0024).
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

        let rendered = await ScreenImage.write("game-mate-news-theirs") {
            screen(session, engine: engine)
        }

        #expect(rendered.says("对方 1 步杀"))
        #expect(rendered.says("你怎么走都躲不掉"))
        #expect(rendered.says("引擎给的最好一手是 Nxb8"))
        #expect(rendered.says("Rd8# 将死"))
        #expect(session.mateNews?.isOurs == false)
        // Your own move is the near colour and the mate is the far one, whoever the news is about.
        #expect(session.mateNews?.arrows.map(\.isYours) == [true, false])
        #expect(session.isPractising)
        #expect(rendered.says("被将"), "and the bar says what the board already shows")
    }

    /// The same game, one move on, with the position on screen a past Ply — so the line the card's
    /// own Stint finds is the mate, and the deck is showing 五步 while it does.
    ///
    /// A mate is news and may take the eye (docs/adr/0024), but not out from under work in
    /// progress: 五步 spends the Stint that finds this mate, so a deck that jumped here would be
    /// tearing down the very walk that paid for the news.
    @Test("a mate turning up does not take the deck off a line being walked")
    func mateNewsDoesNotStealAWalk() async throws {
        let opera = "4kb1r/p2n1ppp/4q3/4p1B1/4P3/1Q6/PPP2PPP/2KR4 w - - 0 1"
        let game = try #require(Game(startFEN: opera, uciMoves: ["b3b8", "d7b8"]))
        let engine = ScriptedEngine(
            [],
            byPosition: [
                (try #require(Game(startFEN: opera))).state.fen: Analysis(
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
        session.jump(toPly: 0)
        _ = await ScreenImage.write("game-walk-keeps-its-card") {
            screen(session, engine: engine, opening: .walk)
        }
        await hop()
        #expect(session.mateNews != nil, "the news is real — this card's own Stint is what found it")
        #expect(session.walk != nil, "and the Line it was walking survived it")
        #expect(
            !session.isFindingTactics,
            "with no jump to 杀招, whose arrival is what turns the probe on"
        )
    }

    /// The other half of the same rule: with nothing in progress the news still takes the eye,
    /// which is what 「直接给予提示」 amounts to on a deck (docs/adr/0024).
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
            screen(session, engine: engine, opening: .key)
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
        #expect(!rendered.says("+0.38"))
        #expect(!rendered.says("+0.24"))
        #expect(!rendered.says("+0."), "and no Score in any of the places one goes")
        #expect(!rendered.says("d4 exd4 cxd4 Bb6"))
        #expect(!rendered.says("O-O d6 d4 Bb6"))
        #expect(!rendered.says("d3 d6 O-O a6"))
        #expect(
            session.analysis != nil,
            "the dealt card spent its own Stint — and none of it reached the screen to be drawn"
        )

        // And the screen accounts for the silence rather than wearing the face of a broken engine.
        #expect(rendered.says("练习"))
        #expect(rendered.says("引擎意见"), "with the one switch that ends it, named")
        // The game itself is entirely unaffected: the moves, the clock, the engine as an opponent.
        #expect(rendered.says("第 8 步 Nf6"))
        #expect(rendered.says("该走了"))
        #expect(rendered.says("让引擎走"))
        #expect(rendered.says("引擎"), "which still plays Black")
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

    /// Browsing back with the engine silent: the one board is a question now. No number anywhere,
    /// and the screen says what it wants instead of looking like a game that has lost its turn.
    @Test("a past position with the engine silent asks what you would play")
    func studyBeforeTheGuess() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(game)
        session.jump(toPly: 6)

        let rendered = await ScreenImage.write("game-study-asking") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }

        #expect(session.isStudying)
        #expect(rendered.says("你会走哪一步"))
        #expect(rendered.says("直接在棋盘上走一步"))
        #expect(!rendered.says("说不清"), "the reason is asked for after a move, not before one")
        #expect(rendered.says("第 7 步 c3"), "and the record says where the eye is")
        // The answer is not on the screen: no Score, no candidate lines, no arrow to copy.
        #expect(!rendered.says("+0."))
        #expect(!rendered.says("d4 exd4 cxd4 Bb6"))
        #expect(session.analysis == nil)
    }

    /// 五步: the engine's stored Line played out on the main board, with the layer following each
    /// step and one sentence saying where the whole thing arrives.
    ///
    /// The sentence is the point. Without it a carousel recites four moves, the position is
    /// different at the end, and the difference is exactly what a beginner cannot see (docs/adr/0021).
    @Test("the carousel walks the stored line, the layer follows, and one sentence says where it went")
    func carouselMidLine() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(game)
        let engine = ScriptedEngine(Self.searching, isEndless: true)
        session.attach(engine: engine, library: nil)
        // The Line the Review stored on ply 6. Arriving at the card also spends a Stint, but the
        // walk reads the Review's line first — the one written down.
        session.applyReview(
            game.plies.indices.map { ply in
                ReviewedPly(
                    score: .centipawns(20),
                    line: ply == 5 ? ["Nxe5", "Nxe5", "d4", "Bd6"] : []
                )
            },
            startEvaluation: nil,
            depth: 18
        )
        session.jump(toPly: 6)
        session.startWalk()
        session.stepWalk(by: 2)

        let rendered = await ScreenImage.write("game-carousel") { screen(session, engine: engine, opening: .walk) }

        // Two of four plies on the board, and the board is showing them.
        #expect(session.board.plies.map(\.san).suffix(2) == ["Nxe5", "Nxe5"])
        #expect(rendered.says("第 2/4 步"))
        #expect(rendered.says("五步"))
        // The layer redrew for the position the walk is standing in, not the one the game is in —
        // asked of the layer itself, because the squares it names are on the 要害 card and this
        // screenshot is of the carousel's (docs/adr/0024).
        #expect(session.boardContinuation == ["d4", "Bd6"])
        #expect(session.walkArrows.map(\.step) == [3, 4], "the arrows still ahead, numbered as the chips")
        #expect(
            session.board.keySquares(continuation: session.boardContinuation)
                .contains { $0.square == Square("f7") },
            "f7 is a square of the walked-to position, and not of the one the record is on"
        )
        // And where the whole line arrives, in one sentence over facts anybody can count.
        #expect(rendered.says("4 步之后，你吃了对方 1 个兵，自己丢了 1 个马"))
        #expect(rendered.says("这几步没有走进棋谱"))
        // The walk itself writes nothing. Arriving at the card spends a Stint so the card has a
        // live line even without a Review; the Review's line is still what is being walked.
        #expect(session.game.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6", "Bc4", "Bc5", "c3", "Nf6"])
        #expect(session.game.variations(atPly: 6).isEmpty)

        // And leaving puts the board back exactly where it was.
        session.endWalk()
        #expect(session.board.state.fen == session.viewed.state.fen)
    }

    /// 点一格问它, in three pictures and in the one order that matters.
    ///
    /// The scanner is the only thing on this screen allowed to speak before a Guess is committed,
    /// and it answers about the square somebody pointed at and about nothing else (docs/adr/0015).
    /// The engine comes last and on a tap: you point at a square, you hear what your own move is
    /// worth in your own terms, and only then do you find out what the engine thought. Reversed, it
    /// is a hint button (docs/adr/0021).
    @Test("the scanner lights the ways in, weighs the one you pick, and asks the engine last")
    func scannerWalkthrough() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let asked = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: Array(Self.italian.prefix(6)))
        )
        let engine = ScriptedEngine(
            Self.searching,
            isEndless: true,
            byPosition: [
                asked.state.fen: Self.opinion(
                    .centipawns(45), best: ("e1g1", "O-O"), then: ["d6", "d4"]
                )
            ]
        )
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        session.jump(toPly: 6)

        // One — armed, and pointed at d4. Two pieces can get there and the board rings both.
        session.armScanner()
        session.scan(at: try #require(Square("d4")))
        let lit = await ScreenImage.write("game-scan-asked") { screen(session, engine: engine, opening: .drill) }

        #expect(session.scan?.origins == Set([try #require(Square("d2")), try #require(Square("f3"))]))
        #expect(lit.says("d4：2 个子能过去。"))
        #expect(lit.says("Nd4"))
        // And nothing else on this card has drawn itself: no answer, no Score, no search at all.
        // What the 要害 card would say over the same position is that card's business — the deck
        // keeps a neighbouring page alive, so a screenshot is held to its own card and to the
        // session, never to another card's words (docs/adr/0024).
        #expect(!lit.says("引擎那步是为了"), "and no answer, because nothing was asked")
        #expect(!lit.says("深度 14"))
        #expect(session.analysis == nil)
        #expect(engine.searchCount == 0, "not asked and hidden — not asked")

        // Two — the pawn tried out. What it buys and what it costs, in that order, both of them
        // facts anybody can go and count on the board.
        session.tryOut(try #require(session.scan?.arrivals.first?.move))
        let tried = await ScreenImage.write("game-scan-trial") { screen(session, engine: engine, opening: .drill) }

        #expect(session.trial?.san == "d4")
        #expect(tried.says("攻 c5"), "what it is for, in the same verbs a player declares in")
        #expect(tried.says("站不住：兵从 e5 就能吃它"), "and what it costs, with the taker named")
        #expect(tried.says("引擎怎么说"), "the engine is behind a tap, and the tap has not happened")
        #expect(!tried.says("引擎那步是为了"))
        #expect(session.scanAnswer == nil)
        #expect(engine.searchCount == 0)
        // The trial is on the glass and in no Game.
        #expect(session.board.plies.map(\.san).last == "d4")
        #expect(session.game.plies.map(\.san) == ["e4", "e5", "Nf3", "Nc6", "Bc4", "Bc5", "c3", "Nf6"])

        // Three — and now the engine, because somebody asked it.
        session.askEngine()
        await hop()
        let answered = await ScreenImage.write("game-scan-engine") { screen(session, engine: engine, opening: .drill) }

        #expect(engine.searchCount == 1)
        #expect(session.scanAnswer?.best == "O-O")
        #expect(answered.says("引擎走"))
        #expect(answered.says("O-O"))
        #expect(answered.says("+0.45"))
        #expect(answered.says("深度 14"))
        // Its reason in the same seven words the trial's was written in.
        #expect(answered.says("引擎那步是为了"))
        #expect(answered.says("护 f2"))

        // And leaving takes all of it off, board included.
        session.endScan()
        #expect(session.board.state.fen == session.viewed.state.fen)
        #expect(session.game.variations(atPly: 6).isEmpty)
    }

    /// The same question asked in French — the one screenshot here that proves eight tables of
    /// words reached the app rather than only the one it was written in. Every other picture in
    /// this file would look exactly the same if seven of them had been left behind, because a
    /// missing language falls back to Chinese by design (docs/adr/0019).
    ///
    /// It is also the row that had to give. The eight answers to 为什么 are one character each
    /// in Chinese and Prendre, Échanger, Défendre in French, so this is the picture that says
    /// whether they wrapped onto a second line or were squeezed into ellipses.
    @Test("the same question, asked in French", .speaking(.french))
    func studyInFrench() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(game)
        session.jump(toPly: 6)
        session.offer(try #require(session.viewed.state.move(matching: "d2d4")))

        let rendered = await ScreenImage.write("game-study-french") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }

        #expect(rendered.says("Vous jouez d4. Pourquoi ?"))
        #expect(rendered.says("Dites d'abord à quoi sert ce coup."))
        // All eight answers, the long ones included, and the two buttons under them.
        for verb in ["Prendre", "Échanger", "Attaquer", "Défendre", "Fuir", "Bloquer", "Occuper"] {
            #expect(rendered.says(verb), "the verb \(verb) is one of the eight answers")
        }
        #expect(rendered.says("Je ne sais pas"))
        #expect(rendered.says("C'est mon coup"))
        #expect(rendered.says("Reprendre"))
        // And nothing has leaked back from the language it was all written in.
        #expect(!rendered.says("说不清"))
        #expect(!rendered.says("你会走哪一步"))
    }

    /// Committing a guess: your move, the engine's, and the one actually played, at one Depth.
    @Test("committing a guess shows it against the engine's move and the one that was played")
    func studyAfterTheReveal() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let asked = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Array(Self.italian.prefix(6))))
        let guessed = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Array(Self.italian.prefix(6)) + ["d2d4"]))
        let played = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Array(Self.italian.prefix(7))))
        let engine = ScriptedEngine(
            Self.searching,
            isEndless: true,
            byPosition: [
                asked.state.fen: Self.opinion(
                    .centipawns(45), best: ("e1g1", "O-O"), then: ["d6", "d4"]
                ),
                guessed.state.fen: Self.opinion(.centipawns(20)),
                played.state.fen: Self.opinion(.centipawns(38)),
            ]
        )

        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        session.jump(toPly: 6)
        let d4 = try #require(session.viewed.state.move(matching: "d2d4"))
        session.offer(d4)
        // One tap for the verb, one for the target — and the reason is committed with the move,
        // not after seeing what the move was worth.
        session.choose(.attack)
        session.aim(at: try #require(Square("c5")))
        session.commitGuess()
        await hop()

        let rendered = await ScreenImage.write("game-study-revealed") {
            screen(session, engine: engine)
        }

        let reveal = try #require(session.reveal)
        #expect(reveal.lost == 25)
        #expect(reveal.counts == true)
        // Three moves, three numbers, and no combined score anywhere.
        #expect(rendered.says("你走"))
        #expect(rendered.says("d4"))
        #expect(rendered.says("引擎"))
        #expect(rendered.says("O-O"))
        #expect(rendered.says("实战"))
        #expect(rendered.says("c3"))
        #expect(rendered.says("过关"), "and what it was worth, in words")
        #expect(rendered.says("深度 14"), "with the Depth all three were computed at named")
        #expect(rendered.says("改走这步"), "a guess worth playing can be played")
        // The second verdict, beside the first and never multiplied into it.
        #expect(rendered.says("攻 c5"))
        #expect(rendered.says("说对了"))
        #expect(rendered.says("走对了，理由也站得住"))
        #expect(session.reveal?.intentCheck?.verdict == .held)
        // And the engine's own reason, in the same seven verbs the player just declared in — read
        // off the Line the same search produced, so the two claims can be compared and not merely
        // translated (docs/adr/0021).
        #expect(session.reveal?.bestReading?.sentence == "护 f2，往后第 3 步 d4 再 攻 c5")
        #expect(rendered.says("引擎那步是为了"))
        #expect(rendered.says("护 f2"))
        #expect(rendered.says("往后第 3 步 d4 再 攻 c5"))
        // The guess is on the board and not in the game: the record still ends where it did.
        #expect(session.game.plies.map(\.san).last == "Nf6")
        #expect(rendered.says("第 8 步 Nf6"))
    }

    /// The reason is asked for before anything is shown, and the two verdicts are marked
    /// separately: this is the screenshot for "right move, wrong reason", which is the failure no
    /// other chess app can see.
    @Test("a good move given for a reason that is not true reads as exactly that")
    func studyRightMoveWrongReason() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let asked = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Array(Self.italian.prefix(6))))
        let guessed = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Array(Self.italian.prefix(6)) + ["d2d4"]))
        let engine = ScriptedEngine(
            Self.searching,
            isEndless: true,
            byPosition: [
                asked.state.fen: Self.opinion(.centipawns(45), best: ("e1g1", "O-O")),
                guessed.state.fen: Self.opinion(.centipawns(20)),
            ]
        )
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        session.jump(toPly: 6)

        session.offer(try #require(session.viewed.state.move(matching: "d2d4")))
        // 吃 d4 — "I win something here" about a quiet move, which is the commonest wrong reason
        // there is and one the rules code can settle in microseconds.
        session.choose(.take)
        session.aim(at: try #require(Square("d4")))
        session.commitGuess()
        await hop()

        let marked = await ScreenImage.write("game-study-wrong-reason") {
            screen(session, engine: engine)
        }

        let reveal = try #require(session.reveal)
        #expect(reveal.counts == true)
        #expect(reveal.intentCheck?.verdict == .failed)
        #expect(marked.says("这步棋没问题，但理由不成立"))
        #expect(marked.says("吃 d4"))
        #expect(marked.says("没做到"))
        #expect(marked.says("没有在 d4 吃子"), "with the fact about the board that settles it")
        // And it is written into the game whether it held or not.
        #expect(
            session.game.variations(atPly: 6).first?.first?.intent
                == .claim(.take, try #require(Square("d4")))
        )
    }

    // ------------------------------------------------------------------- the layers

    /// A game with something actually hanging in it, so the rings have something to ring: after
    /// 1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. Nxe5?? Nxe5 White has thrown a knight away.
    private static let givenAway = [
        "e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "f3e5", "c6e5",
    ]

    /// Both board layers at once, with the two arrows: the engine's teal and the player's violet,
    /// on a position that has already been played into.
    private func layered() async throws -> (GameSession, ScriptedEngine) {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.givenAway))
        let asked = try #require(
            Game(startFEN: PGN.standardStartFEN, uciMoves: Array(Self.givenAway.prefix(7)))
        )
        let guessed = try #require(
            Game(
                startFEN: PGN.standardStartFEN,
                uciMoves: Array(Self.givenAway.prefix(7)) + ["d8g5"]
            )
        )
        let engine = ScriptedEngine(
            Self.searching,
            isEndless: true,
            byPosition: [
                asked.state.fen: Self.opinion(.centipawns(30), best: ("d2d3", "d3")),
                guessed.state.fen: Self.opinion(
                    .centipawns(25), best: ("e5f3", "Nf3"), then: ["Qf6", "d3", "d6"]
                ),
            ]
        )
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        // The position right after White threw the knight away: it stands on e5 attacked by the
        // knight on c6 and defended by nothing, which is exactly what the red ring is for. Black
        // is to move, and the guess on the board is not the recapture that was played.
        session.jump(toPly: 7)
        session.offer(try #require(session.viewed.state.move(matching: "d8g5")))
        session.choose(.attack)
        session.aim(at: try #require(Square("e5")))
        session.setShowsControlChange(true)
        return (session, engine)
    }

    /// Before the Guess is committed the layer has nothing to say, and says *that* rather than
    /// falling back on the diff it used to print. Drawing the reading here would be handing over
    /// the answer to the question being asked (docs/adr/0015, 0021).
    @Test("a studied position rings what is hanging and holds the reading until the guess is in")
    func boardLayers() async throws {
        let (session, engine) = try await layered()

        let rendered = await ScreenImage.write("game-layers") {
            screen(session, engine: engine, opening: .key)
        }

        // The layers are on the board, which is a drawing — so what is asserted here is the state
        // the drawing is made from, and the PNG is the record of how it looked.
        let loose = try #require(session.viewed.loosePieces)
        #expect(loose.contains(try #require(Square("e5"))), "the knight White left there")
        #expect(session.showsControlChange)
        #expect(session.guess?.san == "Qg5", "the player's own arrow has something to draw")
        #expect(session.declaredIntent?.target == Square("e5"), "and the claim has a target to ring")
        #expect(rendered.says("要害"))
        #expect(rendered.says("红圈"), "with the one mark that needs a word said in one")
        // Nothing is ranked, because nothing has been paid for: the engine has not been let speak
        // about this position yet, and the panel says which of the two silences it is.
        #expect(session.viewedContinuation.isEmpty)
        #expect(session.viewed.keySquares(continuation: session.viewedContinuation).isEmpty)
        #expect(rendered.says("先交卷"))
        #expect(!rendered.says("管住了 6 格"), "the old diff is gone, not merely quieter")
    }

    /// And the moment it *is* committed: one square, numbered, with a sentence saying what it
    /// cost — which is the whole of what this layer was rebuilt for.
    @Test("committing the guess brings up the reading by itself, one square with a sentence")
    func keySquaresAfterTheGuessIsIn() async throws {
        let (session, engine) = try await layered()
        session.setShowsControlChange(false)
        session.commitGuess()
        await hop()

        let rendered = await ScreenImage.write("game-key-squares") {
            screen(session, engine: engine, opening: .key)
        }

        #expect(!session.viewedContinuation.isEmpty, "the reveal kept the line its search produced")
        let purpose = try #require(session.viewed.purpose(continuation: session.viewedContinuation))
        #expect(purpose.opening.san == "Qg5")
        #expect(rendered.says("Qg5"))
        #expect(rendered.says("是为了\(purpose.opening.intent.goal)"))
        #expect(rendered.says(purpose.opening.intent.label))
    }

    /// An outpost, cashed in: the square, the piece that comes to it, and the walk between them.
    /// 「松开了 d5」 is a fact about a map; 「自己的马(c3)1 步就能走进来，到了就赶不走了」 is a fact
    /// about the game (docs/adr/0021).
    @Test("an outpost is drawn as a route from the piece that would come to it")
    func anOutpostIsDrawnAsARoute() async throws {
        // Black's pawns on c5 and e5 are past d5 for ever. White's knight goes to c3, one move
        // from standing on it, and the engine's own line walks it there.
        var game = try #require(
            Game(startFEN: "4k3/8/8/2p1p3/8/8/8/1N2K3 w - - 0 1", uciMoves: ["b1c3", "e8e7"])
        )
        game.applyReview(
            [
                ReviewedPly(score: .centipawns(60), line: ["Ke7", "Nd5+"]),
                ReviewedPly(score: .centipawns(65), line: ["Nd5+"]),
            ],
            startEvaluation: .centipawns(40),
            depth: 18
        )
        let engine = ScriptedEngine(Self.searching)
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        session.jump(toPly: 1)
        session.setShowsControlChange(true)

        let rendered = await ScreenImage.write("game-outpost") {
            screen(session, engine: engine, opening: .key)
        }

        let purpose = try #require(session.viewed.purpose(continuation: session.viewedContinuation))
        #expect(purpose.opening.san == "Nc3")
        #expect(rendered.says("Nc3"))
        #expect(rendered.says("是为了\(purpose.opening.intent.goal)"))
        #expect(rendered.says(purpose.opening.intent.label))
    }

    /// The one reading that is about your own pieces. The rook takes the fifth rank and d5 changes
    /// hands — and the knight that would like to stand there still cannot, which is a cost of the
    /// move that never shows up as anything changing hands (docs/adr/0021).
    @Test("a square you took and still cannot stand on is drawn as one of yours")
    func aSquareYouAreShutOutOfIsDrawn() async throws {
        var game = try #require(
            Game(
                startFEN: "4k3/1p1p1pp1/2p1p3/8/1N6/8/1P4B1/R3K3 w - - 0 1",
                uciMoves: ["a1a5", "e8f8"]
            )
        )
        game.applyReview(
            [
                ReviewedPly(score: .centipawns(30), line: ["Kf8", "Ke2", "Ke8", "Kd1"]),
                ReviewedPly(score: .centipawns(30), line: ["Ke2"]),
            ],
            startEvaluation: .centipawns(25),
            depth: 18
        )
        let engine = ScriptedEngine(Self.searching)
        let session = GameSession.fresh(game)
        session.attach(engine: engine, library: nil)
        session.jump(toPly: 1)
        session.setShowsControlChange(true)

        let rendered = await ScreenImage.write("game-shut-out") {
            screen(session, engine: engine, opening: .key)
        }

        let purpose = try #require(session.viewed.purpose(continuation: session.viewedContinuation))
        #expect(purpose.opening.san == "Ra5")
        #expect(rendered.says("Ra5"))
        #expect(rendered.says("是为了\(purpose.opening.intent.goal)"))
        #expect(rendered.says(purpose.opening.intent.label))
    }

    @Test("the same two layers hold up in the dark")
    func boardLayersInTheDark() async throws {
        let (session, engine) = try await layered()

        let rendered = await ScreenImage.write("game-layers-dark", style: .dark) {
            screen(session, engine: engine, opening: .key)
        }

        #expect(rendered.says("要害"))
        #expect(rendered.says("红圈"), "the one mark on the board that needs a word, in the dark too")
        #expect(rendered.says("先交卷"), "and the reason the ranked squares are not here yet")
        // The guess and its claim are the drill's card and are photographed there — this one is
        // about the two layers, and a card is held to its own words (docs/adr/0024).
        #expect(session.guess?.san == "Qg5")
        #expect(session.declaredIntent?.target == Square("e5"))
    }

    @Test("the last move's hanging pieces are named on 要害, even at the latest")
    func noLayersOnTheLivePosition() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.givenAway))
        let session = GameSession.fresh(game)

        #expect(try #require(session.viewed.loosePieces).isEmpty == false)

        let silent = await ScreenImage.write("game-layers-live") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
        }
        #expect(silent.says("要害"))
        #expect(silent.says("红圈"), "要害 is about the move just played, latest included")
        #expect(silent.says("是为了"))
    }

    /// The switch on: this is 复盘, on the board the game was played on.
    @Test("turning the engine's opinion on puts the whole game's report on the same screen")
    func reportWithTheSwitchOn() async throws {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(game)
        // A pass that has already run: the curve, the labels and the Depth are what it left.
        session.applyReview(
            [
                .centipawns(30), .centipawns(25), .centipawns(35), .centipawns(30),
                .centipawns(40), .centipawns(35), .centipawns(-420), .centipawns(-410),
            ],
            startEvaluation: .centipawns(20),
            depth: 18
        )
        session.jump(toPly: 7)
        session.setPractising(false)

        let rendered = await ScreenImage.write("game-report") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true), opening: .key)
        }

        #expect(!session.isPractising)
        #expect(session.reviewPass == nil, "a Game that already has a pass is not made to sit through another")
        #expect(rendered.says("优势条"), "the bar is back, because the opinion is on")
        #expect(rendered.says("分数曲线"))
    }

    /// The curve behind the moves: one strip, the record still the record, the shape of the game
    /// underneath it.
    @Test("the curve is the ground the record stands on, not a second record")
    func theCurveIsAGround() async throws {
        let session = try Self.reviewed()

        let rendered = await ScreenImage.write("game-report") {
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true), opening: .key)
        }

        #expect(rendered.says("第 7 步 c3"), "the moves read exactly as they did")
        #expect(rendered.says("第 8 步 Nf6"))
        #expect(rendered.says("开局"), "including the way back to the start")
        #expect(rendered.says("分数曲线"), "and the curve is behind them")
    }

    @Test("a practising board has no curve behind its record, and nor has an unscored game")
    func theCurveIsTheEnginesVoice() async throws {
        let practising = try Self.reviewed()
        practising.setPractising(true)
        let quiet = await ScreenImage.write("game-record-practising") {
            screen(practising, engine: ScriptedEngine(Self.searching, isEndless: true))
        }
        #expect(!quiet.says("分数曲线"), "a curve is a Score, and practice is not being told one")
        #expect(quiet.says("第 7 步 c3"), "the record itself is unchanged by any of this")

        let unscored = GameSession.fresh(
            try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        )
        unscored.setPractising(false)
        let blank = await ScreenImage.write("game-record-unscored") {
            screen(unscored, engine: ScriptedEngine(Self.searching, isEndless: true))
        }
        #expect(!blank.says("分数曲线"), "nothing to draw one out of yet")
    }

    // ------------------------------------------------------------------- glue

    /// The Italian eight plies in, with a pass already over it and the switch on — the state both
    /// pictures of the record are read in.
    @MainActor
    private static func reviewed() throws -> GameSession {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: italian))
        let session = GameSession.fresh(game)
        session.applyReview(
            [
                .centipawns(30), .centipawns(25), .centipawns(35), .centipawns(30),
                .centipawns(40), .centipawns(35), .centipawns(-420), .centipawns(-410),
            ],
            startEvaluation: .centipawns(20),
            depth: 18
        )
        session.jump(toPly: 7)
        session.setPractising(false)
        return session
    }

    /// The screen as the app pushes it: inside a navigation stack, with the engine and the library
    /// in the environment. The engine is the only thing that is not the app's own.
    /// The screen, and — when a test is photographing something that lives on one card of the
    /// deck — the card to open on. The app decides that for itself from the position; a test says
    /// so, the same way it says which game and which engine (docs/adr/0024).
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
