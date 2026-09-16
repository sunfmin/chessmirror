# A 试招 can be judged again, deeper, and the game file takes the deeper number

A 试招's 掉幅 comes from two bounded searches — the position it was played from and the position it
made — each stopping at ten seconds or depth twenty, whichever comes first ([ADR 0020](0020-advice-runs-in-ten-second-stints-and-the-strip-says-so.md),
[ADR 0039](0039-the-opponent-plays-on-the-shared-position-search-and-has-no-clock.md)). On a phone
the two ends often stop at different depths, and a tactical position can stop well short of twenty,
so the number on the 已退回 chip is sometimes a number nobody should trust. [ADR 0034](0034-a-refused-move-keeps-the-reply-it-earned.md)
said nothing needs to run again once a move is judged; this reopens that for one act.

**The player can ask for a 复判 of one 试招 from its chip (CONTEXT.md, 复判): both ends are searched
to the same deeper level — depth 28, each end capped at sixty seconds — and the move's 掉幅, 应招
and the depth they were worked out at are rewritten in place, in the game file.** The refusal
itself is never rewritten: the move was taken back, and that stays written where it happened
([ADR 0037](0037-a-refusal-nothing-absorbed-is-written-where-it-happened.md)). Only the number changes.

Three things follow that a reader of the code will otherwise find surprising:

- **`Ply.Tried` carries a depth, and `[%tried San -23%]` grows a trailing depth.** A tried move
  read from an older file has none, and none is shown for it: "judged at whatever depth the shared
  search reached" is not a number, and writing twenty there would be a guess dressed as a fact.
- **The shared position store keeps the deepest finished result, not the ten-second one.** A
  复判's depth-28 analysis replaces the depth-20 entry for that position, and every later reader —
  the badge, the finder, the next 细判 there — gets the deeper answer without searching. The
  store's rule becomes "the deepest we know", which is one sentence, instead of "the ten-second
  result, except where somebody asked for more".
- **The stood move in the same position keeps its own Judgement.** A 复判 touches one 试招. The
  deeper search of the position it was played from may find a better best move and so imply a
  different cost for the move that finally stood, and that number is left as it was: two depths in
  one position is acceptable, because each 掉幅 is true at the depth written beside it, and
  re-judging stood moves is a separate act for a separate day.

## Consequences

- The 错题本 is a cache under file dates ([ADR 0029](0029-the-practice-log-records-what-happened-never-what-is-due.md)),
  so a rewritten game is re-walked on its own; a 遭遇 whose deeper 掉幅 falls under the 记录线 leaves
  the book by the filter that already exists. Nothing is struck off by hand.
- A 复判 that hits the sixty-second cap before depth 28 writes the depth both ends actually
  reached (the shallower of the two), and the chip's button stays until 28 is written. The
  engine's hash table makes the second press a continuation, not a restart.
- The 复判 yields to the game: it is greyed out while the clock runs or the engine is busy, and
  cancelled — nothing written — if the player moves or leaves the screen. What the two ends
  reached stays in the shared store, so asking again costs almost nothing.
- 应招 is replaced together with the number, once, when the search finishes: the line and the cost
  come out of one search, and showing a deeper number over a shallower line would split them.
