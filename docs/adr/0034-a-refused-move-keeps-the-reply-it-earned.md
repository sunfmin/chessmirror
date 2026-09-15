# A 试招 keeps the 应招 it earned, and shows it only when pressed

耕棋 refuses a move and says nothing about what to play instead. That silence is deliberate
([ADR 0031](0031-the-player-no-longer-declares-a-reason.md)): the roll-back *is* the lesson, and
the hint ladder is a separate thing somebody has to climb. But it left the player with no way to
ask the one question a refused move raises — **what was it asking for?** A strip of chips saying
`Qh4 −23%` tells you that a move was wrong and nothing about why, and a player who cannot see the
answer has learnt to avoid one move, not to read a position.

So each 试招 now keeps the Line the search that judged it already produced: the opponent's
strongest answer and the few moves after it, in SAN, written inside the same `[%tried]` token —

```
12. Bd3 {[%tried Nf3 -23% | Nxe4 Nxe4 d5] [%tried Bc4 -12% | d5 exd5]}
```

— and pressing the chip shows it: the numbered chips the two cards already use, and the same
numbered arrows on the board.

**Kept rather than looked up, because there is nothing left to look up.** The position a 试招 made
is off the board the moment it is refused; `weigh` has already run a bounded search on it to find
out what the move cost, and the principal variation came back in the same frame as the Score. A
second search would spend the same ten seconds re-deriving an answer the app had in hand and
deliberately threw away, at the one moment the player is looking at it.

**Asked for rather than shown, because the whole point of the refusal is that it says nothing.**
The reply is not a recommendation and the app must not treat it as one: it is what the move cost,
made concrete, and it appears when and only when somebody presses the chip. That is the rule the
rest of the screen is already under (ADR 0031), and it is why the answer is empty until pressed
rather than sitting behind a chevron.

**A reply is drawn in two colours, and they are not "you" and "the engine."** Step one is the move
that was wrong and every step after it is the move that answers it, counted from whoever played the
试招. A game between two people has no engine to colour the second side, and the thing the picture
has to say — this is what you tried, this is what happens to it — is true either way.

**Five plies of reply, so the 试招 and its answer come to six arrows.** That is
`MateNews.arrowLimit` minus one, derived rather than chosen twice: both are the same fact about how
much a board can carry before it is a scribble. The search's Line runs well past that, and nothing
reads further.

The bar inside `[%tried]` rather than a tag of its own, because a reply belongs to one refused
move: a file with three of them has three answers, and a second token indexed back to its move is
a pairing that can drift the first time one of them is missing. A reader that does not know the bar
reads the token exactly as it did before.

## Consequences

- Files written before this keep no reply. A 试招 without one falls back to the shared bounded
  position search — ten seconds or depth twenty, the same budget every other position gets — which
  normally answers out of the cache the refusal itself wrote, and on device across a relaunch.
  Nothing is written back: the file is annotation, and browsing is not a reason to rewrite it.
- The drill's refusal keeps its reply the same way. `DrillVerdict` carries the Line out of the
  search that judged the attempt, and the 错题 a drill files therefore has an answer to show
  without the engine being asked again.
- A reply is annotation on the move that stands, like the refusals it rides with
  ([ADR 0028](0028-a-mistake-is-a-position-and-the-games-are-its-occurrences.md)). Nothing derives
  from it, and the 错题 book reads the same two fields it always did.
- The 惩罚 exercise and this are the same word — 应招 — with the finding done by different people:
  the exercise asks the player for it, the chip shows it. So the chips are shut while an exercise
  is open: the answer the exercise is asking for must not be one press away. An exercise answered
  by the reveal is still one 遭遇, exactly as before.
