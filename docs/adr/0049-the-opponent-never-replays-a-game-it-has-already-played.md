# The opponent never replays a game it has already played

ADR 0039 put the opponent's own move on the shared position search: at 满力 the move the engine
plays *is* the one bounded search of that position every other reader joins, and nothing else
bounds it. One of the reasons written down there was that the shared search is never fast — «a
move every half-second is a wall of notation. The engine's move is a full position search, which
is never that fast.»

That sentence was wrong about its own store. `PositionSearches` keeps every finished result, and
on device writes them to a file that survives relaunch (ADR 0041 made it keep the deepest one it
knows). A reader of a position that has already been searched is answered out of that store
inside a frame — which is the whole point for 细判, the badge, a card and a hint, and which for
the opponent meant this:

> Set both sides to 引擎 from the standard position. The first game is played at ten seconds a
> move. Every game after it — this run, or any run, the file being on disk — is played *at the
> speed of a disk read*, move for move identical to the first, because Stockfish at 满力 is
> deterministic and each position's answer was already written down.

Two things were wrong, and both are fixed here.

## The store answers one opponent per position, and no more

`analyse(playing:)` marks the one reader that plays a move out of what it reads. An entry that
has had a move played out of it is **spent**, and a spent entry never stands in for a second
opponent: the search runs again, at the everyday 搜索预算.

Spending it, rather than simply never reading it, is what keeps the common case free. 把关 judges
the move the player just made by searching the position it made — which is the very position the
opponent must now move from — and that search is still the opponent's own. What is refused is the
*second* ask, and a second ask for a position already played from is a game being played again.
A result restored from disk is spent from the moment it is read back: whatever game it was
searched for is over.

## At 满力 the opponent tosses between moves it cannot tell apart

Re-searching alone would not have been enough. A deterministic engine asked the same question
twice gives the same answer twice, so the second game would have been the first game again, more
slowly. At a rung this never happened — Stockfish's `Skill` picks among its top lines with a
clock-seeded random (ADR 0038) — and 满力 now has the same idea, explicit and bounded: 掷子
(`Toss`) picks at random among the lines the search scores within fifteen centipawns of its
first, from the mover's side.

Fifteen is below what a player can feel and far below 掉幅's own floor, so no move the toss can
reach is one the app would call a mistake if a person played it. A mate is never tossed for.

**The toss moves a piece; it does not move a number.** The search is untouched and is still the
position's shared answer: 最佳 is still the first line, 细判 still weighs a move against it, the
hint still points at it. That is the same line ADR 0038 draws for a bound engine, drawn once more
in the other direction.

## Consequences

- ADR 0039's "the engine's move is a full position search, which is never that fast" is amended:
  it is a full position search *the first time*, and from then on it is one whenever the opponent
  is the one asking.
- Two engines from the same position no longer play the same game, and each move takes the budget
  it is supposed to take. A 把关 game's reply is unchanged: one search, the one that judged.
- `PositionSearches` never commits a shallower result over a deeper one, which a re-search of a
  position a 复判 had answered would otherwise have done (ADR 0041).
- `GameSession.toss` is the seam. `Toss.strongest` never tosses, and is what a test that expects
  a particular move asks for; `OpponentMoveTests` is where the rule is held, including the second
  game that used to be a replay.
- 马上走 plays what the toss picked, not the first line: both read `thinkingBest`, which is
  settled once per snapshot by `opponentMove`, so the two can never name different moves.
