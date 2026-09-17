# An imported game's Review is asked for, and says how far it has got

Opening an imported game used to start its Review on its own (docs/adr/0016): the session
handed the file to the library the moment it was attached to an engine, the engine spent a
few seconds per move in the background, and at some point the record's costs quietly filled
in. Nothing on the screen said the game had not been looked at, nothing said it was being
looked at now, and nothing said when it was done. An imported game with no 错招 row read as a
clean game, which is the one thing an unreviewed game must never read as — it is a game
nobody has judged, not a game with nothing wrong in it.

So the Review is now **offered, not started**, in one row under the record:

- **An unreviewed import says so** — 「这一局还没分析过」 — and offers 「分析这一局」. The
  press is the start. The offer waits with the engine when the engine is not ready yet, and
  it is refused while a Review of the same game is already running, so it cannot be queued
  twice.
- **While it runs, the row is its progress**: positions settled out of the positions the plan
  has to settle (`ImportReview.Progress`), reported by the search itself as each one lands.
  The count lives on the library (`GameLibrary.reviewing`), where the Review runs, so a screen
  that leaves and comes back finds it still going.
- **When it lands, the row says what it found** — 「本局 N 处错题，已加入错题本」, or that the
  game has none — and the 错招 row fills in below it from the same game. Nothing is *added*
  to the book: the Review writes `[ReviewDepth]` into the file, the library lists the file,
  and the 错题本 is derived from the library (docs/adr/0028). The sentence is a report of
  what already happened, not a second step.
- **A Review that could not finish says so and offers again.** No partial scores are written
  (docs/adr/0016), so the offer is exactly where it was.

Why a press rather than a start: a Review is seconds of engine per move, on a phone, and a
player opening a game to read it did not ask for the engine at all. The Review is the one
thing that turns an import into 错题, and the moment it starts is the player's to pick.

## Consequences

- `GameSession.attach` no longer starts anything. `GameSession.review()` does, and only
  under `canReview`; `awaitsReview`, `reviewProgress` and `reviewNews` are what the screen
  reads.
- The import sheet's waiting state stopped saying 「打开重试」 — opening never retried anything
  a person could see — and says to open the game and analyse it.
- 分析 is the word on the screen for what the domain calls a Review, because it is the word
  the player used. It stays a Review in the code and in these documents.
