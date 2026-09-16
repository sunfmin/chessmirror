# The engine's opinion has no switch

ADR 0015 put the engine's opinion off at the start of every Game and behind one deliberate press;
ADR 0020 brought that press down onto the strip under the board. Then the strip was unified around
正着's judgements (commit 5430445): the badge under the board shows what a move cost and where it
landed, the press went, and the game screen stopped presenting a practice mode and an analysis mode
as two things. What stayed behind was the flag the press had thrown — `isPractising`, documented as
"legacy" — and everything that hung off its other value: an advisory Stint the board itself started,
a Score in the strip's voice, the 「深 26」 effort readout and its capsule, a 「在算」 line in the
player's bar, and the 收下 sentence under the record. Nothing on the phone could reach any of it,
because nothing on the phone could set the flag. Nine screen tests photographed it anyway.

**So the flag is gone, and this records that the app has one answer to "what does the engine say
about the position in front of me": nothing.** The badge says what the move just played cost and
where it landed (ADR 0027); the strip says how deep the search has got (ADR 0020), because a search
that stops has to account for itself; a card says what it was asked (ADR 0023, 0025). None of those
is an opinion about the position the player is looking at, and no switch turns one on.

One adapter is a hypothetical seam: a flag with one live value is not a mode, it is a constant with
a name, and every branch under its other value is a screen nobody can see. Deleting it deletes the
branches, and the tests that photographed them.

## Consequences

- `GameSession.isPractising`, `setPractising`, `adviseAgain` and the session's `settlement` are
  deleted, and so is the `Standing.score` voice. The strip is `.quiet` when there is nothing to
  report, whatever the engine thinks.
- The board no longer starts an advisory search of its own. The one search the board starts is the
  shared bounded search of the position, for 正着 and the badge (ADR 0039); a card that asks gets a
  Stint of the same search (`adviseForCard`), and its answer is kept for the card.
- **收下 has no surface at present.** The settlement row was only reachable with the flag off, so
  it had already been off every phone since the press went. `Game.settlement` and `Settlement` stay
  in the kit, tested, for the day it is given one (CONTEXT.md, 收下).
- ADR 0015's file is not in this repository; where it is cited, "the opinion is off at the start of
  every Game and turned on by one deliberate press" is read as: off, and there is no press. ADR
  0020's strip is otherwise unchanged — depth while it climbs, a bar the badge draws.
- The screen tests that turned the opinion on to photograph it now photograph the depth readout
  instead, and the advantage bar is photographed with a judgement written on the last move, which
  is the number it actually reads.
