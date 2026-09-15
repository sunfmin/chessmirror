# The advantage bar turns with the board, and the number beside it does not

The bar under the board is two colours and one length. It was drawn with White always growing from
the left and Black always filling what was left, whatever way up the board was: with Black at the
bottom the bar said the exact opposite of the number printed beside it, to the only person who could
see either. **Nothing caught it, because the colours are not in the accessibility tree** — its label
is 「优势条」 and its value is the Score, both of them true either way up, and no screenshot in the
suite had ever been taken of a flipped board.

**The bar is board-relative: the side at the bottom of the board owns the left end, in that side's
own colour.** The colours on this screen are the pieces' colours and never "the left one and the
right one" — the arrows, the rings and the key squares are all drawn that way (docs/adr/0018,
0021) — and the bar is the one place where a colour *is* the whole of the statement rather than a
decoration on top of one. So which end grows is a question about the board and nothing else.

**The Score beside it stays White-relative, deliberately.** `+3.00` means White is three pawns up
whichever way the board is turned: that is what a Score is in every book, every engine readout and
every PGN comment, and a number that changed its owner with the view would be a number nobody could
compare with anything. So the two halves of the strip answer two different questions — the number
says *who is winning*, the bar says *how much of the board in front of you is theirs* — and the
middle mark is the balance point between the two ends of the bar, not a cursor for the number.

## Consequences

- A flipped board is now photographed, in both orientations, and held to the bar's two end colours
  by pixels (`EvalBarTests`). It is the first screen state in the suite where colour rather than
  words is the assertion, and it is the first picture of a flipped board at all — the whole state
  was unreachable by every test in the suite before this.
- Two readings of one position now disagree on purpose: turn the board round and the bar's lengths
  swap ends while the number does not move. If that ever needs explaining on screen it is a job for
  the number's own label, not for a second number.
