# The import sheet has four doors, and one pipeline behind them

Date: 2026-09-22

## Status

Accepted. Written down long after the decision was made: four files cite `docs/adr/0014` and
the file did not exist (the numbering runs 0013 → 0016). This records what the code already
says, and the seam the 2026-09-22 deepening put under it.

## Context

A game arrives from somewhere: a lichess username, a chess.com username, a 国象联盟 share
link, or any other link to a PGN. Each of those has its own URL grammar, its own meaning for
an HTTP status, its own way of naming what came back and recognising it again across imports.

It would be easy to build four importers. That is four pipelines to keep in step, four
answers to 「一局进来了变成什么」, and four places for a bug in "how a game becomes a record"
to hide.

## Decision

**Four doors, one pipeline.**

A 门 is only *how the text is got*. Behind every door the same thing happens to the text:
split it into games, name each one, write one file per game. That pipeline is
`ImportSession.read`.

Each door carries its own facts — URL grammar, status meaning, dedup identity, naming rules —
behind one place per door (`FetchPlan`, and the members of `PGNImport.Site` /
`ImportDoors.Door`). A door says what it needs; the session only fetches.

## Consequences

- Adding a door is one new case and its members. It is not an edit to six `switch`es over
  site names scattered across the importer.
- A 国象联盟 share link is recognised in one place (`ImportDoors.Door.recognising`). It is a
  link like any other — it just carries its game with it — so the plain link door uses the
  same sniff rather than keeping a second one.
- A door's failures name themselves. A chess.com archives list that will not parse is
  `.unreadableArchives`, not `.notPGN`: the player is told what went wrong and with whose
  account, rather than that a JSON list is not a game record.
- The pipeline is testable through any door with a scripted fetcher (`PGNFetching`), because
  the only thing that varies is how the text arrives.

## Related

- [ADR 0010](0010-pgn-files-are-the-storage-format.md) — what a game becomes once it is in.
- [ADR 0045](0045-the-import-sheet-has-a-door-per-site-and-remembers-who-came-through.md) —
  what the sheet does with a door.
- [ADR 0044](0044-an-imported-games-review-is-asked-for-and-says-how-far-it-has-got.md) —
  what happens to a game after it lands.
