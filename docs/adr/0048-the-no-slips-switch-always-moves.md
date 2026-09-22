# The 把关 switch always moves

The switch used to be pressable only some of the time. `canSwitchNoSlips` greyed it out in three
cases, each with a reason of its own:

- **while a move was being weighed or an exercise had the board** — nothing may change the game's
  lines under a judgement, and every move played by hand with an engine attached is weighed, 把关
  on or off, for up to ten seconds;
- **in a 练习, for the whole game** — a drill is played under 把关
  ([ADR 0047](0047-practice-is-played-under-no-slips.md)), and the session kept the drill's value
  for as long as it lived, so a game played on from a 错题 could never be switched off;
- **with no engine, when 把关 was off** — nothing to do the stopping, which in the app means the
  first seconds after launch while Stockfish starts.

Each case was reasonable on its own. Together they made the one mode switch on the page a switch
that was grey every time a move went down, and for the rest of any game that began as a 错题 —
「不管在什么情况下，把关都可以打开或者关闭」.

**The switch always moves.** It is the player's say on whether their hand is stopped, and there is
no state of the board in which that is not theirs to say.

- **Under a judgement, the move is ruled under the switch as it stands when the weighing ends.**
  The ruling already read the 线 after the engine answered, so switching off while 把关 is
  judging lets that move stand, and switching on refuses one that costs the 记录线. One rule, and
  the switch means what it says the moment it is pressed. A move whose refusal has already been
  ruled is given its beat on the board and taken back; the switch then holds for the next one.
- **In a 练习, the switch writes into the drill.** The session still keeps no second copy: `lines`
  is the drill's value, and `setNoSlips` writes through to it, so the attempt is ruled under what
  the switch says. A drill still *arrives* under 把关 — `Drill.init` switches it on, which is what
  ADR 0047 was about: the refusal is reachable by default, not by remembering to ask. Switched
  off, a wrong answer is still a wrong answer: the verdict fails, the log records the go and the
  book counts the 遭遇; the move is only left on the board.
- **With no engine, the switch is still the game's.** Nothing is measured until an engine is
  attached; from then on 把关 does its job.
- **Under an exercise, the exercise keeps the board.** The switch is about the game's next move,
  not about the exercise standing in for it.

The two numbers are not the switch. `setLines` still refuses to move them under a judgement or in
a 练习, where the 记录线 is what the attempt passes or fails by.

## Consequences

- `GameSession.canSwitchNoSlips` is gone, and with it the `.disabled` on the switch in the strip
  and in the game's settings.
- `setNoSlips` and `setLines` end in the one write of the 线, into the drill while a 练习 is on
  and into the session's own otherwise. `acceptsLines` guards `setLines` alone.
- `Drill.lines` can be set by the session. `Drill.init` still switches 把关 on.
- A practice file can now say 把关 was off. The book reads it the way it reads any other game.
- ADR 0047's "the switch cannot take a 练习 out of 把关" is withdrawn; the rest of it stands.
