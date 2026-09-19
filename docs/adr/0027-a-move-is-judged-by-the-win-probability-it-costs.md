# A move is judged by the win probability it costs, and three separate lines are drawn on that one scale

`MoveQuality` named a move by centipawns — 300 a 失误, 150 an 错着, 50 an 不准 — and
[ADR 0017](0017-criticality-is-a-rank-within-a-game-not-a-number-of-centipawns.md) then declined
to use those numbers at all, asking instead about the worst three Ply of each Game by rank. Both
halves are now retired.

**A move is judged by the win probability it gives away**, converted from the Score with the
curve lichess judges by, `胜率 = 100 × sigmoid(0.00368208 × 厘兵)`. Centipawns are still what the
engine returns and what a PGN carries; they are no longer what anything is compared against.

The reason is that a centipawn is worth a different amount in every position. Three pawns thrown
away from a winning position barely changes who wins, and 100 centipawns thrown away from a level
one can change everything — so a fixed centipawn band calls the first a 失误 and shrugs at the
second, which is backwards. The win-probability curve is steepest where the game is closest and
flattest where it is decided, which is exactly the shape the judgement wants. Near equality 10%
works out to about 109 centipawns, so the familiar bands survive where they were right and stop
firing where they were not.

Rank goes for a different reason. 0017 chose rank so the app would not need to know how strong
the player is, and that argument was sound while a Drill meant "three questions about the game
you just played." It stops being sound the moment the questions pile into a book that outlives
the game: **rank guarantees that a game played well yields exactly as many mistakes as a game
that collapsed**, and a book built that way has no relationship to how the player is actually
doing. A threshold has one, and the player sets it themselves.

**Three lines are drawn on the one scale, and they are separate because they buy different
things.** The 拦截线 is what 耕棋 stops the player for. The 记录线 is what gets written down.
The 入列线 is what earns a place in the player's future practice time, and it sits above the
记录线 because a mistake can be worth remembering without being worth drilling. Defaults are 10%,
10% and 20%.

_Amended by [ADR 0046](0046-no-slips-stops-the-player-at-the-record-line.md): the 拦截线 is no
longer a line of its own — 把关 stops the player at the 记录线 — and both remaining lines ship at
ten._

## Consequences

- **The 拦截线 is 耕棋's only difficulty dial, and the engine's strength is never one.** How
  strong the opponent is, and how much slack the coach cuts you, are two questions; answering
  them with one control makes it impossible to say who improved. This keeps the spirit of
  [ADR 0009](0009-one-engine-unbounded-analysis-mirrored-opponent-time.md) — time remains the
  only thing said to the engine — while giving the coaching side its own number.
- `MoveQuality`'s four names stay, rebanded onto 掉幅 at 10 / 20 / 30%. Naming a move was always
  a separate job from deciding what to ask about, and it is the half 0017 got right.
- The advantage bar reads in 胜率 rather than Score, so the bar and the judgement are the same
  quantity. The number beside it stays White-relative for the reasons in
  [ADR 0026](0026-the-advantage-bar-turns-with-the-board.md).
- Every evaluation feeding a comparison must still come from one depth
  ([ADR 0016](0016-a-plys-evaluation-belongs-to-a-review-and-to-nothing-else.md)). A threshold
  is more exposed to mixed provenance than a rank was, not less.
