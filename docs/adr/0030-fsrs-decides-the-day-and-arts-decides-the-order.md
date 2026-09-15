# FSRS decides which day, ARTS decides the order within it

Spaced practice is a solved problem and this app should not invent one. It also does not fit the
solved problem exactly, and the mismatch is worth being deliberate about: every published
scheduler grades a card from **what the learner says about themselves** — again, hard, good, easy
— and this app never has to ask. The verdict is the engine's, and it comes with a second measure
a flashcard has never had: **how long the player took.**

**FSRS decides which day a 错题 comes back**, at the default `desiredRetention` of 0.90, graded
binary: passed or not. Binary is not a compromise — Anki's two-button and four-button users get
statistically indistinguishable FSRS accuracy — and 0.90 is the default for a specific reason.
The advice circulating to lower it to 0.85 came from Anki's retention optimiser, which was
removed in 25.07 after a modelling bug was found; the workload curve is roughly exponential
either way (90→95% costs about 2.1×), so this is a dial to leave alone until there is a reason.

**ARTS decides the order of the day's queue.** Adaptive Response-Time-based Sequencing (Mettler,
Massey & Kellman 2016) is the peer-reviewed way to let latency into a schedule, at d = 0.56–0.78
against fixed sequencing, and three properties of its shape are copied exactly:

- **A wrong answer ignores the time entirely** and takes a large fixed jump in priority.
  Three minutes of thought ending in the wrong move and two seconds ending in the wrong move are
  the same event.
- **Time only separates answers that were right.** It says how fluent the player was, and
  fluency is only a question once correctness is settled.
- **It enters as `log(用时 / 这道题的参考用时)`** — compressed, and relative to that item's own
  reference rather than in seconds. This is what absorbs the noise (a long position, a
  distraction, a slow thumb) that made FSRS's maintainers refuse latency in the first place. That
  refusal was explicitly about how it feels to be timed while grading yourself, not about whether
  it works — and nobody is grading themselves here.

## Consequences

- Both are pure functions of the practice log
  ([ADR 0029](0029-the-practice-log-records-what-happened-never-what-is-due.md)). Refitting FSRS's
  parameters to this player, or replacing the scheduler outright, reschedules the whole history on
  the next launch and migrates nothing.
- Each 错题 needs a reference time to be relative to. Until it has its own history, the reference
  is the population's; this is the one number in the scheduler that has to be bootstrapped.
- The two halves can ship apart. A Leitner box would get most of the way — Cepeda's 317-experiment
  review found expanding schedules had no measurable advantage over uniform ones (62.0% vs 58.6%,
  p = .61), and FSRS earns its place by adapting *per item*, not by making intervals grow. If the
  order matters more than the day, ARTS first is a defensible build order.
- There is no Swift FSRS this project has vetted. Porting is a few hundred lines of arithmetic
  against a reference implementation, and it is a port, not a design.
