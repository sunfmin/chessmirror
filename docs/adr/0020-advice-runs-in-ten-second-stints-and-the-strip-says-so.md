# Advice runs in ten-second Stints, and the strip under the board says so

The Analysis in front of a player was **unbounded** (docs/adr/0009): iterative deepening ran
for as long as it was left alone, and the recommendation visibly changed as depth climbed.
That is the honest picture of what an engine is doing, and it is what this ADR keeps —
for ten seconds. **The advisory search now runs a Stint and stops.** 再算 10 秒 puts another
one on.

The reason is a phone. A screen left standing on a table is a screen nobody is looking at,
and "for as long as it is left alone" turns eight cores loose on a position that stopped
being interesting an hour ago. It is felt as heat and paid for in battery, and neither
buys anything: past about ten seconds on a phone another ply almost never changes which
move is recommended, and on the positions where it does, the player is the one who knows —
so they are the one who asks.

**The Stint is a clock the session keeps, not a budget handed to the engine.** The search
is still asked for `.untilStopped` and stopped by cancelling it, which is how every search
in this app ends, a thumb coming off 让引擎走 included. The distinction is load-bearing:
the pause gate refuses an unbounded search while the app is away and holds a bounded one,
because a bounded search has somebody waiting on its answer while an unbounded one belongs
to a screen (docs/adr/0009). Advice belongs to a screen however few seconds it runs for. A
ten-second `movetime` would be admitted at that gate and held for a screen nobody is
looking at, which is the bug this ADR is about, wearing a different hat.

**A search that stops has to account for itself.** An unbounded one never had to: the
number moved, so the engine was alive. A number that quietly stops moving is
indistinguishable from an engine that has died, so the strip under the board gained a
Depth while it climbs — 深 26, one figure, no speed — and the offer of another Stint when
it has stopped climbing.

That strip is now the whole of what the engine has to say, and the switch deciding whether
it says anything came down from the navigation bar to join it (docs/adr/0015 is unchanged:
the opinion is still off at the start of every Game and still turned on by one deliberate
press). Four things that are one thought — whether it is talking, who is ahead, by how
much, and how far it has got working it out — and the merge is what makes the last one
affordable, because the bar the search produced is also the button that buys it more time.

## Consequences

- The heat is bounded by the moves played, not by how long the app is open. A game is ten
  seconds of thinking per position looked at, and a phone left on a table is a phone doing
  nothing.
- Depth is now on the screen, having been deliberately taken off it before — that meter
  said what the phone was doing rather than what the position was, and it went. It comes
  back as one figure rather than a row, and it is a different claim: not "the engine is
  fast" but "the engine has stopped here, and this is where".
- Asking again does **not** restart the player's clock. Mirrored Time is a record of how
  long the *player* has been thinking, and asking the engine for more time is not the
  player taking less.
- Every way a search ends now goes through one place, because a Stint's clock outliving the
  search it was wound for would stop the search that replaced it — the timer belonging to
  the advice a thumb interrupted would take that thumb's own move down with it.
- The engine's own move is untouched. It is bounded by Thinking Time already, and an
  opponent that stopped thinking after ten seconds and asked to be prodded is not an
  opponent.
- A Review is untouched. Its whole point is one uniform Depth across a Game, and a Stint is
  a wall clock — the two do not mix, which is also why a Review's searches are the bounded
  kind that the pause gate holds rather than refuses.

  > And it is a Review, not a Stint, that pays for everything in
  > [ADR 0021](0021-the-layer-names-a-few-squares-instead-of-reporting-them-all.md): the squares a move cost are worked
  > out from the Line a Review already had in hand. A layer that started its own search
  > would put the heat this ADR removed straight back on.
