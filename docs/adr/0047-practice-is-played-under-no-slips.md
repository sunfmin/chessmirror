# 练习 is played under 把关, and a failure there is an occasion like any other

A 错题 drill has always been able to take a wrong answer back. `Drill` carries a `JudgementLines`,
rules its own attempt through the same `Ruling` a game's move goes through
([ADR 0037](0037-a-refusal-nothing-absorbed-is-written-where-it-happened.md)), and a test held it
to both outcomes. The app never once took an answer back: the only place a drill was made handed
it `JudgementSetting.lines`, which is the player's two numbers **with 把关 off**, because the
switch is a thing a game is played under and a setting has no business holding one
([ADR 0046](0046-no-slips-stops-the-player-at-the-record-line.md)). So the refusal branch was
written, tested and unreachable, and a 日课 answer that gave away twelve points stood on the
board, the engine replied to it, and the player carried on from the worse position they had just
been told about — 「下着下着就从错题里下出一盘新棋」.

**练习 is played under 把关.** Not because a setting says so, but because it is what a drill *is*:
the question is this position, and a wrong move standing on the board is the question being
answered by moving on. The switch is forced on where the drill is made, so every door into one —
the 日课 queue, 错题本's 练习 button, a screen test — gets the same game.

Two things follow that are worth saying out loud, because both were decided rather than inherited.

**A refusal is written down even when nothing else is.** A file used to need a move before it was
worth keeping, which in a drill means: answer wrong, put the phone down, and nothing happened. The
commonest 错题 there is, is being stopped and stopping (ADR 0037) — in practice it is the *whole
question* — so a game carrying a pending 试招 is saved, moves or no moves.

**A failure in practice is a 遭遇 like any other.** The 试招 goes into the 错题本 through the door
every other 试招 uses, so the position's 复发 counts it and 「你栽过 4 次」 includes the times you
fell for it while practising. The alternative — a practice-only kind of 试招 the book skips — was
considered and refused: it would have made the book's sentence depend on where you were sitting,
and it would have needed the one thing this repo does not have, a second place where a mistake is
true ([ADR 0029](0029-the-practice-log-records-what-happened-never-what-is-due.md)). The practice
log still records the attempt exactly once, and FSRS still schedules off the log alone
([ADR 0030](0030-fsrs-decides-the-day-and-arts-decides-the-order.md)), so the two accounts do not
feed each other: the book counts occasions, the log counts goes.

## Consequences

- `Drill` switches `noSlips` on in its own initialiser. A caller's 记录线 and 入列线 are taken as
  they are; the switch is not a caller's to set, and `GameSession.practising` mirrors the whole
  value, so the line that judges the attempt is still the line that refuses it (ADR 0046).
- A wrong answer comes off the board after its beat, the 判决 row says what it cost, the 试招 chip
  under the record carries its 应招, and the position is there to be tried again — by playing on,
  not by re-answering: the attempt is settled and one attempt is one line in the log.
- `GameSession.save` writes a game that has no moves but does have a pending 试招.
- Practice keeps its cards. 把关 is what stops a move; whether 杀 and 战术 may be looked at is a
  different question, and pressing a card is counted as help rather than refused
  (`dealsCards`, ADR 0029).
- Every answered 错题 now leaves a file in the library — a move and the engine's reply for a pass,
  a bare position and a 试招 for a failure. What the list makes of them is its own problem.
