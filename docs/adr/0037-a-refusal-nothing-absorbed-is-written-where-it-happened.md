# A 试招 that nothing absorbed is written down where it happened

A refused move lives in the file as a comment on the move that finally stands — `[%tried Qh4 -23%]`
on the move the player found instead — because that is what it is: something that happened at this
position *before* this move was found (ADR 0027, 0028). Which leaves the case where no such move
is ever played. A player is refused, looks at it, and leaves. Nothing stands, so there is nothing
to write the refusal on, and `settle` said as much:

```swift
// No save and no retune: nothing happened to the game, and the engine is not owed a
// reply to a move that was taken back.
```

**Nothing happened to the game, and something happened to the player.** They got a position wrong.
Opening the game again showed a board with no trace of it — no mark on the record, nothing in the
错招 list, nothing to practise — which is the one thing 耕棋 exists to prevent.

So the refusals at the position the game is standing on are written down too, at the end of the
movetext, and they survive being left:

```
1. Nc3 {[%tried Qd2 -23%]} *        ← the refusals before Nc3 was found
1. Nc3 {[%pending Qh4 -31%] [%pending f3 -12%]} *   ← the refusals at the position after it
```

**`%pending` and not a trailing `%tried`, because the slot is taken.** A comment after a move
already means "refused at the position *before* it", and a reader cannot tell a comment written
past the last move from one written for the last move — the two are the same text in the same
place. Every file written before this would have been re-read one Ply out. A second name costs one
line of grammar and says which position the refusals belong to.

**Before the result token, and that is not a matter of taste**: the reader stops at the result, so
a comment written past it is a comment nothing will ever read. The token carries the same body as a
`%tried` — the move, what it cost, and the 应招 it earned — because it is the same fact.

**What happens next is what always happened, only now it is in a file.** When a move is played at
that position it takes the refusals with them: they become its `%tried` comment, which is where a
refusal belongs once there is a move to belong to. Before a move, they are the game's tail.

## Consequences

- Leaving a game right after a refusal writes the file, where it used to write nothing. A refusal
  is part of the game's record now, so a Game compares different when one has happened — the tests
  that asserted 「a refusal left the game untouched」 now assert that it left the *moves* untouched.
- The 错招 list has a stop for it: the Ply one past the last move, so walking there lands on the
  position the game ends on — which is the position to try again from. When a move is played there
  and absorbs the refusals, the same Ply is that move's, so the stop does not move.
- The 应招 comes along, because `%pending` carries the same body as `%tried`. A refusal the player
  walked away from still knows what it was asking for.
- A game with no moves can have a 错招: a 试招 at the opening position that the player did not
  follow up. The walk over the Plies is written so that this is not an empty range.
