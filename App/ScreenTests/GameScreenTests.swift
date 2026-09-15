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
        #expect(
            rendered.count(of: "再算 10 秒") == 0,
            "and no offer of more while it is still inside its Stint"
        )
        // The move it would play, named beside the arrow the board draws — one move, because a
        // line of six is a language most people playing this have not learnt.
        #expect(rendered.says("建议 d4"))
        #expect(!rendered.says("d4 exd4 cxd4"), "and not the whole line it is the head of")
        // The deck under the record, dealt from this position: two cards, and nothing about a
        // move that has not been played (docs/adr/0025).
        #expect(rendered.says("杀招"))
        #expect(rendered.says("战术"))
        // And the three that went with the drills: nothing on this screen names them any more.
        #expect(!rendered.says("要害"))
        #expect(!rendered.says("五步"))
        #expect(!rendered.says("练习"))
        #expect(!rendered.says("问一格"))
        #expect(!rendered.says("走马灯"))
        #expect(!rendered.says("考一遍"))
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
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true), opening: .tactics)
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
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true))
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
            screen(session, engine: ScriptedEngine(Self.searching, isEndless: true), opening: .tactics)
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
        // And no search ran either. Both remaining cards are questions for the engine, so
        // **dealing is no longer an arrival**: the deck opens on one of them at rest, with its own
        // press on it, and a card that happened to be first is not somebody asking (docs/adr/0023).
        #expect(session.analysis == nil, "nobody asked, so nothing was spent")
        #expect(!session.isFindingTactics, "and the finder was not turned on by the deck opening")
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
            screen(session, engine: engine, opening: .tactics)
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
        // Nobody flips the switch: swiping onto the card is the asking (docs/adr/0025).
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
        #expect(!rendered.says("+0.38"))
        #expect(!rendered.says("+0.24"))
        #expect(!rendered.says("+0."), "and no Score in any of the places one goes")
        #expect(!rendered.says("d4 exd4 cxd4 Bb6"))
        #expect(!rendered.says("O-O d6 d4 Bb6"))
        #expect(!rendered.says("d3 d6 O-O a6"))
        #expect(
            session.analysis == nil,
            "the dealt card is at rest: nothing was asked, so there is nothing to keep off screen"
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
        session.setPractising(false)

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
