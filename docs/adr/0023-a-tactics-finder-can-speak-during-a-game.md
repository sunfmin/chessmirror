# A tactics finder can speak during a game

docs/adr/0015 forbids two things this feature needs: the engine speaking first, and the
app pointing at a critical moment while a Game is being played. A Tactic on the live
board is both. This ADR is the opening, and it is narrow.

**战术发现器 is a second switch, off at the start of every Game, never written to PGN.**
Practice is untouched. The legal combination this exists for is Practice on and the
finder on: no Score, no candidate Lines, one shot if there is one. The finder talks only
about the **latest** position of a Game in progress. A past Ply is still a Drill, and the
finder is silent there.

A **Tactic** is a shot for the side to move that wins material or mates. The rules propose
(mate, a winning capture, a double attack) and a short search disposes — the same two-net
order as 要害格 (docs/adr/0021). The sentence is a template over facts the rules code can
check, in the seven Intent verbs where they fit. Motif names (fork, pin, skewer) do not
get a slot: they cannot be told false.

Whose Tactic it is follows who is to move, not who just moved: after you play it is
「对方有战术」, after they play it is 「有战术」. No Tactic is a line of text, not a drawing.

The probe is one bounded search (`depth 10`, two Lines) and runs **before** the engine's
own move or a Stint of advice, because there is still only one engine (docs/adr/0009).
It does not `clear()`: the engine may be about to move, and the table should still be warm.
The finder is refused while the app is away, with every other search.

## Consequences

- Two switches on one strip. docs/adr/0015 paid to avoid that; this ADR spends it, on
  purpose, and keeps the cost visible: both still start off, both still belong to this Game.
- The board may draw **one** arrow, the shot, while the finder is on. Hanging pieces, 要害格,
  and the control layer stay off the live position (docs/adr/0015, 0021).
- A half-second delay before an engine reply is accepted: the prompt has to land before
  the opponent moves, or it is a post-mortem.
