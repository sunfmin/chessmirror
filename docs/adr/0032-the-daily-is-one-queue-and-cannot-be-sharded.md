# The 日课 is one queue a day, and the player is not allowed to carve it up

The obvious feature is a filter. Practise just the blunders; practise just this opening; practise
these five. It is the first thing anyone asks for, and **the 日课 does not have it.**

Learners left to arrange their own practice split it into small stacks and cycle each one until it
feels learned, and that destroys the spacing that makes the practice work. Kornell 2009 measured
it: larger stacks won, spacing beat massing for 90% of participants, and final accuracy was **31
percentage points higher** — while **72% of participants believed the massed condition had worked
better.** This is the rare case where the preference is not merely a matter of taste but is
inverted, and a control that lets it act is a control that quietly breaks the product.

There is a second reason, specific to chess. Grouping by theme and practising a theme in a block
trains the failure mode the app exists to fight: Einstellung, where recognising a familiar pattern
holds the eye on the features that support it and the better move goes unseen, with the player
sincerely believing they are still looking (Bilalić, McLeod & Gobet 2008, with eye-tracking).
**Drilling motifs in blocks makes this worse, not better.**

So the 日课 is one queue, in one order, and that order is the scheduler's
([ADR 0030](0030-fsrs-decides-the-day-and-arts-decides-the-order.md)). It has no filter, no sort
and no theme picker, and 错题 carry no classification to offer one with.

**The 错题 book is a different door and it is open.** It is where a position's history lives —
what it cost, how many times it was fallen for, what was played each time — and a position can be
practised straight from it. What that practice cannot do is move anything: it is recorded as
计划外, and the scheduler does not see it. The reason is narrow and worth stating, because it is
not a re-run of the argument above: a player who re-practises the positions they like would
otherwise convince FSRS that those positions are the most secure ones they own, and **the app
would respond by showing them less often.** Handing the player the door while keeping the
schedule out of their hands is what lets both be true.

## Consequences

- No filter, no sort, no "practise these five", and no theme tags for one to work on. The 错题 book
  is a flat list ordered by severity and 复发.
- The day's new intake is capped (10 by default) so the queue stays finishable; what does not fit
  waits, ordered by cost and 复发. 复发 outranks cost: twelve percent three times is a missing
  concept, forty percent once may be a bad night.
- A long queue is not a reason to soften this. Session length does not degrade performance in the
  literature; **time of day does**, which is an argument for a reminder, not for a filter.
- 计划外 practice is still written to the log. It is history, and one day it may be evidence that
  this restriction was wrong.
