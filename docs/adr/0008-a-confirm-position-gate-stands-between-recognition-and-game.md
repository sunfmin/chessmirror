# A Confirm Position gate stands between Recognition and Game

> **Revised by ADR-0011.** The gate is no longer mandatory: Recognition opens a Game and
> the screen became the Piece Editor, entered when something came out wrong. Everything
> below about *what can go wrong* and about validating a Position before Stockfish sees it
> still holds — 0011 only moves where the screen sits in the flow.

Recognition never flows straight into a Game. A mandatory screen shows the recognised
Position beside the source image, highlights Shaky Squares, lets any square be edited,
lets the Orientation be flipped, and exposes every Unknowable Field — side to move,
castling rights, en passant square, halfmove clock. Only a Position Stockfish accepts can
start a Game.

The screen exists because the failures it catches are the ones nothing else can:

- A mirrored Orientation is a point reflection, so it stays perfectly legal. The engine
  will confidently advise on a position that is not the one in the picture. In the CLI a
  glance at the FEN caught this; inside a game it would silently poison every move that
  follows.
- The en passant square is unknowable from pixels, so it defaults to none — which
  silently deletes a capture that may be the best move in the position.
- Castling rights are *inferred* from kings and rooks sitting at home, which over-grants
  them for any game where those pieces moved and came back.

## Consequences

- Legality has to be implemented here, not borrowed. Stockfish 18's `Position::set`
  validates **nothing**: its asserts compile out under `NDEBUG`, `square<KING>()` is
  undefined without exactly one king, and the castling parser hunts the home rank for a
  rook with `for (rsq = …SQ_H1; piece_on(rsq) != rook; --rsq) {}` — a loop with no lower
  bound that reads off the board when the FEN claims a right no rook can support. A user
  editing squares on this screen can produce exactly that. So the gate owns a validator
  that runs before Stockfish is handed anything, and it is a safety mechanism as much as
  a UX one. (Master gained a `PositionSetError` for this; the pinned release has not.)
- Owning the validator turns out to be the better design anyway: it reports a structured
  issue with the squares to highlight — "black has two kings, here and here" — where a
  string from the engine could only be printed.
- A future reader will be tempted to streamline this screen away for flow. It is not
  flow-padding; it is where the four unknowables get resolved.
- Editing squares here needs no legality rules — an arbitrary arrangement is allowed
  while editing, and the gate is what refuses to let an impossible one through.
