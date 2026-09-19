# 把关 stops the player at the 记录线, and has no line of its own

[ADR 0027](0027-a-move-is-judged-by-the-win-probability-it-costs.md) drew three lines on the
win-probability scale and kept them separate because they bought different things: the 拦截线 was
what 把关 stopped the player for, the 记录线 what got written down, the 入列线 what earned practice
time. The first of those separations is retired. **把关 stops the player at the 记录线.** There
are two numbers now, both the player's, both in 关于 → 判决线, both shipping at ten — and 把关 is
a switch that reads the first of them.

The reason is that the two lines were never two questions. "How much may I give away before I am
stopped" and "how much must I give away before it is written down as a mistake" are both *what
counts as a mistake*, and a player who answers them differently gets a game that contradicts
itself. With the 拦截线 at five and the 记录线 at ten — which is what shipped — 把关 turned back
moves the book would not have called a mistake, and the player was handed two dials, one on the
game screen and one in 关于, and left to reconcile them: 「把把关和错题本的百分比合成一个吧」. One
number says one thing: a move 把关 refuses is exactly a move that would have been written down.

The separation 0027 cared most about survives untouched. The 入列线 still moves on its own and
still never sits below the 记录线, because "worth remembering" and "worth drilling" really are two
questions. And the line 把关 reads is still the only dial it has on the judgement of a move: the
engine's 棋力 shapes the opponent and never what a move costs
([ADR 0038](0038-strength-bounds-the-opponent-and-never-the-judge.md),
[ADR 0009](0009-one-engine-unbounded-analysis-mirrored-opponent-time.md)).

## Consequences

- **The slider is gone from the game screen.** 把关 there is on or off. Where it stops the player
  is changed where the 记录线 is changed, in 关于, and the footer under the two pickers says so.
- `JudgementLines` holds `tilling`, `record` and `enqueue`. `intercept` is derived — the 记录线
  while 把关 is on, nil while it is off — and cannot be set, so a game stopping the player
  somewhere the book does not write down is not a state the kit can be in.
- **Nothing already written is rewritten.** A judgement keeps the line it stood under
  (`under N` on the move), so a move that stood under five still says five, and the 连正榜 reads
  it as it always did. The `Intercept` tag is still written — it is how a file says 把关 was on,
  and other readers of the file know it — and now carries the 记录线 the game was saved under.
- **A reopened game takes the switch from the file and the line from the player.** A game saved
  with `Intercept "5.0"` comes back with 把关 on and stops the next move at the player's 记录线 as
  it is today. Every way into a session — new, reopened, photographed, corrected — is handed the
  player's lines for this reason; a reopened game used to be judged by the standard pair whatever
  关于 said, which did not matter while 把关 brought its own number and matters now.
- `InterceptPreference`, the line 把关 would come back on at while it was off, is no longer
  written, and is dropped from a file that carried it the next time that file is saved. It
  remembered the position of a dial that does not exist.
- A player who had moved the 记录线 off ten keeps where they put it, and 把关 follows it there.
  Ten is what a phone ships with, not something a setting is reset to.
