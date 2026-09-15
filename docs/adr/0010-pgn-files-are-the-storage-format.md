# PGN files are the storage format

A Game is stored as one `.pgn` file in the app's Documents directory, with the source
image saved beside it under the same basename. There is no database and no separate
internal representation: `[FEN "…"]` + `[SetUp "1"]` carry the recognised starting
Position, the movetext carries the Game, and `{[%eval …]}` comments — the convention
lichess and chess.com already use — carry a Review's scores.

SwiftData was the alternative, rejected because it would make PGN a second format
reachable only through a conversion layer, and two representations of one Game drift.

## Consequences

- Storing, exporting and importing are the same code path, so export cannot fall behind
  the model. Pasting a PGN in is a supported way to start a Game.
- Files are readable and shareable straight out of the Files app, which also makes them
  easy to inspect when something looks wrong.
- Listing games means reading a directory and parsing headers rather than querying an
  index. At the scale one person generates, that is not a problem worth a database.
- A PGN parser is needed, not just a writer — and it must round-trip its own output.
