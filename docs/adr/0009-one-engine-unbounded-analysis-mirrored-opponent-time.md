# One engine, unbounded Analysis, Mirrored Time for the opponent

The app asks the engine for three different things — advice on the position in front of
the player, the opponent's move, and a Review's uniform scores — and does all three
through a single `Stockfish::Engine` behind a serial Swift actor that stops the previous
search before starting the next. The three never overlap in time anyway: the engine is
not the opponent while it is advising the player.

Search is **unbounded** when advising: iterative deepening runs for as long as the player
leaves it, and the UI re-renders every `info` update, so the recommended move and score
visibly change as depth climbs. Reproducibility is explicitly given up.

> Amended by [ADR 0020](0020-advice-runs-in-ten-second-stints-and-the-strip-says-so.md):
> the advisory search is still asked for unbounded — everything below about the pause gate
> turns on that — but it is stopped after ten seconds by a clock the session keeps, because
> "for as long as the player leaves it" is for ever on a phone put down on a table.

Each colour has a **Controller** — the player's hands or the engine — switchable at any
point in a Game, so hand-moving both sides, playing one, swapping, and engine-versus-engine
all fall out of the same model. When the engine controls a colour it plays at **full
strength**, limited only by **Thinking Time**: by default **Mirrored Time**, about as long
as the player took over their last move — and, when there is no player to mirror or somebody
would rather name a number, a fixed number of seconds a move. No `UCI_LimitStrength`, no
`UCI_Elo`, no `Skill Level` — there is no difficulty setting in this app, only a clock.

## Consequences

- Memory stays at one resident copy of the 67 MiB network plus one transposition table.
  A second instance would double the network and put a phone at risk of being killed.
- Tests cannot assert an exact best move, because multithreaded search is
  non-deterministic by design (`Skill::pick_best` even seeds its PRNG from the clock).
  They assert **convergence properties** instead: on a mate-in-2, once depth reaches 10
  the best move must be the mating one. A correct engine satisfies that without being
  deterministic.
- A Review needs one uniform Depth across every move to make Scores comparable; during a
  game the per-move scores are whatever depth happened to be reached, so they are drawn
  as provisional (hollow, depth-labelled) and never fed into the Review's curve.
- Mirrored Time is clamped to `[0.4s, 30s]` so a phone is not pinned at full load while the
  player is away from it, and so a move tapped out as a reflex is not answered in 100 ms.
- With both Controllers on the engine there is no human move to mirror, so Mirrored Time is
  not an answer there and a clock is **named** instead: **three seconds a move**. Long
  enough that a machine game can be followed as it is played, short enough to sit in front
  of. The choice between the mirror and a named clock is offered whenever the engine holds
  either Controller, because time is the only dial this app has — somebody asking for a
  stronger opponent is asking for a longer clock, and there is nothing else to give them.
  It is a way of playing rather than a fact about the game, so like the Controllers it is
  not written to PGN and a reopened game starts on the default.
- Changing the clock takes effect on the move being thought about now, not the next one:
  the running search is started again on the new clock rather than trimmed to it. The move
  being waited for is the one anybody reaches for the control because of.
- The engine only plays from the **latest** position, so browsing back is where a
  self-playing game pauses and 回到最新 is where it carries on. That falls out of the model
  rather than being a stop button, and it is the answer to "how do I stop it" along with
  putting a colour back on a hand.
- Search must stop when the app leaves the foreground, and the gate that enforces it sits in
  the engine rather than in the screens — a screen can forget, and one that did would leave a
  phone thinking in a pocket. What a search wanting to start while the app is away does depends
  on what it is for: an unbounded Analysis is refused, because it belongs to a screen someone
  is looking at and that screen asks again on the way back, while a bounded search is held and
  run when the app returns, because someone is waiting on its answer. Holding is what a Review
  in particular needs: stopping its searches one ply at a time and carrying on would score the
  rest of the game at whatever Depth each got to, and a Review that is not at one uniform Depth
  is not comparable with itself.
