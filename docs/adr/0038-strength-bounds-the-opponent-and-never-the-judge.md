# 棋力 bounds the opponent, and never the judge

ADR 0009 said there is no difficulty setting in this app, only a clock: the engine plays at full
strength, and a player asking for a weaker opponent is asking for a shorter clock. That held while
the opponent's strength was nobody's measurement. It stops holding the moment the app keeps a
number about a game — 正着数 and 连正, how far the player went before 正着 took a move back —
because a number read against "three seconds a move" is read against a different opponent on a
different day: the same clock is a stronger engine on a newer phone and a weaker one on a hot one.
A rung the player measures themself against has to be the same rung tomorrow, and only a bound the
engine itself enforces gives that.

So a game has a **棋力**: an Elo from a fixed ladder — 1400, 1600, 1800, 2000, 2200, 2500, 2800,
and 满力, which is unbound, is ADR 0009's opponent, and stays the default until the player first
picks a rung — set with Stockfish's own `UCI_LimitStrength` and `UCI_Elo`. Elo rather than depth,
because Elo is the number players already talk in and a strength-limited engine errs the way a
weaker human does, while a depth-limited one is sharp tactically and blind to the long game, and
"depth 8" tells a player nothing. The clock is untouched: Mirrored Time and a named number of
seconds are the courtesy they always were, not a level.

> The default has since moved to the bottom rung, 1400: 满力 as the first opponent was a wall a
> newcomer met before they had picked anything. What the player picks is still remembered and
> still wins over the default.

> The clock was already disconnected when this was written, and it has since been deleted
> ([ADR 0039](0039-the-opponent-plays-on-the-shared-position-search-and-has-no-clock.md)): the
> opponent's move runs on the shared position budget, and 棋力 is the one dial on it.

**The bound is on the opponent's own moves and nothing else.** 细判 weighs every move at full
strength at every 棋力, and so do hints, cards and the 战术发现器: a 掉幅 has to mean the same thing
in every game or the 错题本 cannot add games up (ADR 0016, 0027), and a gentler 正着 is already a
higher 拦截线. With one engine (ADR 0009) that means the limit is set for the opponent's move
searches and cleared for every other search, the way MultiPV is already varied per search on the
serial actor.

**Every engine move records the Elo it was made at**, as an annotation on that move — the way a
judgement is (ADR 0027) and a refusal is written where it happened (ADR 0037). A 棋力 can change
mid-game the way a Controller can, so a game is a sequence of stretches, and the 正着榜 credits
each stretch to the rung it was played at; a stretch against a human is credited to no rung. When
the whole game was played at one 棋力 the standard `WhiteElo` / `BlackElo` tag is written as well,
so other tools read it.

## Considered options

- **Named profiles bundling Elo, clock and the three lines.** Rejected: a level is one number, the
  metric compares by that number, and a renamed profile would orphan the games played under it.
  Profiles can be added on top later without changing what a game stores.
- **One 棋力 per game, fixed at the engine's first move.** Rejected in favour of stretches: a
  player who lowers the rung when stuck has still played the first thirty moves at the higher one,
  and the file should say so.
- **Judging at the level too**, so a beginner is refused less often. Rejected: that is what the
  拦截线 is for, and a 掉幅 that depends on the opponent is a 掉幅 the book cannot compare.

## Consequences

- ADR 0009's "no `UCI_LimitStrength`, no `UCI_Elo`, no `Skill Level`" is superseded by this.
  Everything else in it stands: one engine, unbounded advice, Mirrored Time, and full strength for
  every search that is not the opponent's move.
- The last 棋力 is remembered across games, unlike the clock, which ADR 0009 keeps as a way of
  playing rather than a fact about the game. The rung *is* a fact about the game and is written
  into it; what is remembered is only which rung to offer next.
- Options are set on the serial actor between searches, never during one. A rung changed while the
  engine is thinking takes effect on that move by restarting its search, as a clock change does.
- Tests cannot assert which move a bounded engine plays: `UCI_Elo` picks among moves with a seeded
  random. They assert that the bound was set for the opponent's search and cleared for the next.
- 正着数, 连正 and the 正着榜 are readings of the games and are never stored on their own; the
  library derives and caches them the way it derives the 错题本. Moves played with 正着 off, drill
  attempts and 惩罚 exercises are not counted anywhere.
