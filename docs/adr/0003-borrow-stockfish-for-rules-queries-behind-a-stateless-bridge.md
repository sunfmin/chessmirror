# Borrow Stockfish for Rules Queries, behind a stateless bridge

Legal move generation, checkmate and draw detection come from Stockfish's own
`Position`/movegen rather than a reimplementation in Swift: it is perft-verified code we
already have to compile. Writing it again in Swift was the alternative, attractive for
purity but a thousand lines with nothing to prove that the Python original ever needed.

The bridge that answers Rules Queries is **stateless**: every call takes
`(startFEN, moves)` and rebuilds a `Position` by replaying the moves. The Game is the
only truth and it lives in Swift.

## Consequences

- Undo is dropping the last element of an array; jumping around a Game is slicing it.
- Repetition and the fifty-move rule come out right, because replaying builds the
  `StateInfo` chain they are computed from. A bare FEN could not answer them.
- Rules Queries never touch the searching `Engine` instance, so there is no race with
  the search threads — the bridge owns no shared mutable state at all.
- One bridge call per Game change, not per tap: Swift caches the returned legal moves
  and answers "can this piece go there" locally.
- SAN is generated on the Swift side from the returned legal moves, since Stockfish has
  no SAN of its own.
