# The opponent plays on the shared position search, and has no clock of its own

ADR 0009 gave the engine's own move a clock: Mirrored Time against a person, a named number of
seconds when the engine played itself, offered on screen as the one dial on the opponent. Then
every live search in the app was made one search (commit 43191ca): the position in front of the
player is searched once, for ten seconds or to depth twenty, and 细判, the hint ladder, the cards,
an asked move and the opponent's own move all read that one result. At 满力 the engine's move *is*
the shared search of the position; at a rung it is a search of its own, bound to the rung, on the
same budget (docs/adr/0038).

That made the clock a dial connected to nothing. `thinkingTime` was still kept, still settable,
still restored on reopening, and still described in ADR 0009 and ADR 0038 as live — and the
budget the engine's move ran on was `PositionSearches.budget` whatever it said. The player's own
thinking time was still measured after every hand move, and nothing read it.

**So the clock is gone, and this records that it was a decision rather than an oversight.** The
opponent gets what every live position search gets, and the screen says so where the clock used to
be named — 「10 秒 / 20 层」 on the engine's bar. What ADR 0009 wanted the clock for is answered
elsewhere:

- *A stronger opponent for somebody who wants one.* That is the 棋力 now (ADR 0038): a rung the
  engine itself enforces means the same thing on every phone, where a longer clock meant a
  stronger engine on a newer phone and a weaker one on a hot one.
- *A reflex is not a thinking time; lunch is not one either.* The shared budget has a floor and
  a ceiling of its own, and neither depends on how long the player took.
- *A move every half-second is a wall of notation.* The engine's move is a full position search,
  which is never that fast; and 马上走 is still there for a move that is taking too long.

## Consequences

- `ThinkingTime`, `MirroredTime`, `GameSession.thinkingTime` and `setThinkingTime` are deleted,
  with the session's measurement of the player's last turn. Nothing offers a clock on screen, and
  a reopened game has no clock to come back to.
- ADR 0009's Mirrored Time, its named three-second clock, its `[0.4s, 30s]` clamp and its "changing
  the clock takes effect on the move being thought about now" are superseded. Everything else in
  it stands: one engine, unbounded advice for the ten seconds of a Stint (ADR 0020), full strength
  for every search that is not the opponent's own move.
- ADR 0020's "the engine's own move is untouched: it is bounded by Thinking Time already" and
  ADR 0038's "the clock is untouched" are both read as: bounded by the shared position budget.
- 棋力 is the one dial on the opponent (CONTEXT.md). A 拦截线 is a dial on the coach, and that is
  the other question.
- `EngineClockTests` holds every live search to `PositionSearches.budget`, which is the test that
  would have caught a clock quietly coming back.
