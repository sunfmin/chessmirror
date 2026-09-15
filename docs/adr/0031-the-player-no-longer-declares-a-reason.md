# The player no longer declares a reason, and the app still speaks in the seven verbs

The seven verbs — 吃 换 攻 护 躲 挡 占, and 说不清 — ran in two directions. The player picked one
and named a square, and `IntentCheck` held the claim against the board
(ADR 0015, ADR 0022); and `IntentReading` ran the same vocabulary backwards, stating the engine's
move in the player's own words. **The first direction is removed. The second stays.**

This is the one decision in the redesign made *against* the evidence, and it should be recorded as
such. Retrieval practice transfers according to **response congruency** — whether the answer
practised is the answer needed later (Pan & Rickard 2018, 192 effect sizes): with it d ≈ 0.58,
without it d = 0.28, and correcting for publication bias takes the latter to approximately zero.
Elaboration — making the learner articulate *why* — adds about +0.22, and with both present the
effect reaches d = 0.78. Asking for a reason was that elaboration, already built and already
judged automatically.

It was removed for throughput. A drill answered with one move takes ten to twenty seconds; a
drill that also asks for a verb and a square takes twenty-five, and a book fed by real games and
by 耕棋 cannot be worked through at half speed. **The cost is accepted with its consequence stated:
the app drills the same position again, and does not serve the same motif in a new position.**
Same-position practice is the high-congruency case that stands up without elaboration. New
positions on a shared theme are the low-congruency case, which without elaboration is worth
approximately nothing — so that feature is not merely unbuilt, it is ruled out until the reason is
asked for again.

**What is not negotiable is feedback.** Rowland 2014 finds no testing effect *at all* without
corrective feedback. Every drill says what the move cost and what the better move was doing,
whether or not it passed, and `IntentReading` is what lets that be a sentence — 「Qxd5 吃 d5 上没人
守的车」 — rather than a line of notation, which to a 1200 is a second puzzle and not an answer.

## Consequences

- ADR 0015's "the player answers first" and ADR 0022's handed-over plan are both retired. No
  `[%int]` comment is written; the `check.*` templates and the verb labels become dead keys.
- The saved-up cost of a move is written where the move is, not in the practice log: a 试招 taken
  back by 耕棋, and how many 提示层 were opened, ride in the PGN comment on the move that was
  finally played. That keeps the book derivable from the games
  ([ADR 0029](0029-the-practice-log-records-what-happened-never-what-is-due.md)) without bringing
  back variation trees to hold a flat list.
- 战术's sentence and 耕棋's top hint layer are both `IntentReading` output. Deleting the second
  direction as well would leave the app able to judge a move and unable to say anything about it.
- If throughput turns out to be survivable, asking for a reason is the first thing to put back,
  and putting it back is what unlocks motif drills.
