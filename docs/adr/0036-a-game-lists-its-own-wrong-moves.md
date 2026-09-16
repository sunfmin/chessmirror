# A game says where the player went wrong in it, and takes them there

A 耕棋 game played last week has a dozen wrong moves in it, and every one of them is already in the
file: the 试招 耕棋 took back are `[%tried]`, and the moves that stood with a measured cost are
`[%judged]`. What the game could not do was **say where they are**. The record strip draws the moves
one per half-move in one line, and a move that cost twenty points looks exactly like a move that
cost nothing until the eye is on it. Finding the ones worth re-practising meant scrolling and
remembering.

So a game now lists its own **错题**: one entry per position, oldest first, and each one carries the
board that was on the screen when the player got it wrong.

**A position, not a move.** The first cut named each entry after the move that cost the most there
and showed that name in a chip — and a move is the wrong thing to name a position by, because a
position takes N wrong moves: three 试招 and then a fourth move, or the same 试招 twice (which is
what the phone did). Half of those names are moves that were never played. An entry is described
the way this app already describes a position — **by its picture** (`BookRow`: "the board is the
title"), with the move number that tells two positions of one game apart, the cost that makes it
worth stopping at, and `×N` for how many wrong moves were tried there.

- **The record strip marks them.** A dot at the foot of the move: pale for what the 记录线 put in
  the file, the alarm colour for what the 入列线 says is still owed. It is an overlay, not a row, so
  a card with a mistake in it is exactly as tall as one without — the curve behind the strip is
  drawn against those cards being even.
- **A row under the strip lists them** — 「3 处要重练」 and a chip per 错招 — and pressing one takes
  the board straight to its position. 下一处 is the whole of the reading: it takes the eye to the
  next one whether or not the player knows which one they are looking for.
- **The position is the one before the move.** Reading a game wants what was played — which is why
  an encounter row in the 错题本 opens on the position *after* it, with the blunder on the board. A
  错招 is there to be tried again, so it lands on the position where the move has to be found, which
  is where the drill starts too.

**One entry per position, whatever happened at it.** A position where three 试招 were refused and a
fourth move was finally played is one place in the game and one stop on the way through it; the
strip of 已退回 attempts belongs to the *position* and stays where it is, and it is where the moves
are named.

**Two weights, because the app has two lines** (ADR 0027) and they mean different things: written
down is the 记录线, owed is the 入列线, and the second is what the 日课 would hand back
(ADR 0030). One list with two weights rather than two lists, because it is one game and one way
through it.

**No Review required, which is where this deliberately parts company with the 错题本.** The book
compares a move's cost with the cost of moves in other games, so every score in it has to come from
one uniform pass (ADR 0016), and a move that stood enters it only from a Review. A game's own list
compares nothing across games: every judgement in it came from the same bounded search of the same
position, which is the app's own engine at the depth it reached (`[%judged]`). Reading a game's own
history is a question about that game.

## Consequences

- 错招 is a word now, and it is not 错题. A 错题 is a position, shared by every game that reached it;
  a 错招 is one move in one game. The two meet at `PositionKey`, so a 错招 can be recognised as an
  encounter of a 错题 — which is what the book is made of — without either being derived from the
  other.
- `MistakeBook` is untouched. The book keeps its own gate, and the game's list has a different one.
  That is two readings of the same Plies, and the reason is stated above; if a third reader ever
  appears, the walk is the thing to share and the gate is the thing to keep. It appeared — the
  library counts a game's positions through the book — and the walk is now shared: `Game.stops(by:)`
  lays out every position the player moved at once, and each reader keeps its own gate over it.
- The list is walked lazily and cached against the game and the two lines, because the record strip
  asks for it on every draw and walking it is a rules probe per Ply.
- **One row, and it is the record row's twin**: full width, square corners, an alarm bar down its
  leading edge and a hairline at each end. It was a rounded card inset from the page, which made it
  a different kind of thing from every row around it; the words 「本局 N 处错题」 and 「已退回」 went
  with it, to VoiceOver. The tile shows the position's board (sixty-four points, the size the
  错题本 gives the same job — at twenty-eight a chessboard is a fingernail), and **under it**, as a
  caption on the picture it belongs to, the scoresheet number the cell above carries, `×N`, and the
  cost at the weight its line gives it. Every tile carries a number, the last one included: the
  错招 at the position a game stops on is at the Ply one past the last move (ADR 0037), which is the
  Ply a move played there would take, and a word in the middle of a row of figures was a tile of a
  different kind. VoiceOver still says 「现在」 for it, because spoken, in a sentence, that is what
  the position a game stands on is. Beside the board those figures made every tile half as wide
  again as the thing worth looking at; under it a tile is its board, and the row holds nearly twice
  as many of them before anybody has to scroll.
- **The picture is the button.** A board that cannot be played on takes no taps of its own
  (`BoardView.isInteractive`): these small ones sit inside buttons, and a gesture on the board is
  one the button never sees — pressing the position was dead while pressing the figures beside it
  worked, which is the opposite of what a tile named by its picture promises.
- The registers share one rail and one frame, and the lower one is the upper one **at the position
  on the board**: walking to a 错题 slides its 试招 out, and a position where nothing was refused
  has none. The 惩罚 exercise is the last register — the only thing in the row that asks something
  of the player — because a row that says what happened and then offers the next thing to do is one
  subject, not three.
- A game nobody got anything wrong in shows no row at all. A screen that has to say 「没有错招」 is a
  screen with a row it does not need.
