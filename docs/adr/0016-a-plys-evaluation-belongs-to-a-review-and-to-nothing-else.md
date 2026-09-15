# A Ply's evaluation belongs to a Review, and to nothing else

> Extended by [ADR 0021](0021-the-layer-names-a-few-squares-instead-of-reporting-them-all.md): a Review now keeps
> the Line it produced alongside the Score, under the same rule — nothing but a Review
> writes either. The Line is what lets the board say which squares a move actually cost,
> and keeping it costs no engine time, because the search that produced the Score produced
> it too.

`Game.Ply.evaluation` had three writers at different Depths from different engines: the
unbounded search during play wrote whatever Depth it happened to have reached
(`GameSession.recordAnalysis`), a Review overwrote the lot at one uniform Depth
(`applyReview`), and a PGN import wrote lichess's `[%eval]` from an unknown Depth and an
unknown engine (`PGN.swift`). Nobody had said which of the three wins.

That was survivable while the field only drove a curve and a label. It stops being
survivable now that **which moves come back as a Drill is decided by ranking the
differences between consecutive evaluations** (docs/adr/0017). A move whose "before" came
from a Depth-10 live search and whose "after" came from lichess's Depth-30 cloud eval
reads as an enormous swing that never happened: mixed provenance does not merely blur the
ranking, it manufactures mistakes and hides real ones. This app's standing rule is that
it may be wrong but never *quietly* wrong.

So the field becomes a Review's, exclusively, and the invariant is structural rather than
a comment:

- **Only a Review writes `Ply.evaluation`.** One engine, one uniform Depth, one pass over
  the whole Game.
- **The live search no longer writes into the Game at all.** It was already documented as
  provisional and destined to be overwritten (docs/adr/0009 said it must never feed a
  Review's curve); it is now simply not recorded. It stays on screen through
  `GameSession.analysis`, where a snapshot belongs. With the engine silent by default
  (docs/adr/0015) that search mostly does not happen in the first place.
- **An imported `[%eval]` is kept, labelled, and never trusted.** It lands in its own slot
  and is shown as lichess's number, not the app's. `MoveQuality` may not read it, a rank
  may not be built from it, and no Drill may be chosen by it. It round-trips out again as
  what it came in as. The reasoning is ADR 0003's: a second move generator would be a
  second opinion about the rules of chess, and an imported eval is a second opinion about
  how well somebody played — while the app already owns the machine that produces the
  trustworthy answer in a few seconds.
- **A Review's Depth is one tag on the Game, `[ReviewDepth "22"]`, not a field per Ply.**
  Uniformity is what a Review *is*, so the Depth is a property of the pass, and recording
  it once turns "has this been reviewed, and how deeply" from an inference into a fact the
  app can act on — offering to redo a Depth-14 Review at 22 rather than silently mixing
  the two.
- **The starting position's Score is written too**, as a comment before the first move.
  It lived only in `ReviewRun.baseline`, in memory, which meant the first move's quality
  could not be recomputed from a saved file at all — and everything about a Drill is
  derived from the saved files (docs/adr/0018).

## Consequences

- Two Games can no longer be compared by evaluation unless their `ReviewDepth` agrees.
  That is not a new limitation, only an admitted one.
- The cost is real: a lichess game that arrives already analysed brings good, deep numbers
  that are now ignored until a local Review has run. Accepted, because the alternative is
  a ranking nobody can trust, and a Review is cheap.
- Games saved before this carry a `[%eval]` of unknown provenance in the Review's field.
  They are treated as unreviewed — absent a `ReviewDepth`, the numbers are read for
  display and never for ranking.
