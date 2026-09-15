# The practice log records what happened, and when a position is due is computed from it

[ADR 0010](0010-pgn-files-are-the-storage-format.md) put everything the app knows in the PGN, and
ADR 0018 went further: a Drill is derived from those files and there is never a second store.
Spaced practice cannot live inside that. **When did you last practise this, how long did it take,
did it pass, how much help did you ask for** — none of it happens in any game, and a PGN has
nowhere honest to put it.

**There is now a second store, and it is an append-only log of facts.** One line per thing that
happened: which 错题, when, how long, passed or not, which 提示层 were opened, whether the player
was handed it by the 日课 or picked it themselves. It is the only store in the app that is not a
game.

**What it does not hold is state.** No due date, no interval, no difficulty, no mastered flag.
"This is due today" is computed from the log every time it is asked. That rule is the whole value
of the decision and it is worth being awkward about: **the scheduler's output must never be
written down**, because the moment it is, changing the scheduler means migrating every row, and
the app stops being able to change its mind. As a pure function of the log, a new algorithm — or
parameters refitted to this particular player — simply reschedules the entire history on the next
launch, with nothing to migrate and nothing to reconcile.

A database was the obvious alternative and was rejected for a reason that will expire: **we do
not yet know what the fields are.** A schema committed now would freeze a design that has never
run. A log does not need to know the answer in advance, and when the fields do settle, an index
built from the log is a cache that can be deleted at any time.

## Consequences

- **ADR 0018 is superseded and 0010 is amended.** The 错题 book itself is still derived from the
  PGN files and gains no store of its own — a mistake is a fact about a game, and games live in
  PGN. It is the player's *behaviour* that is new, and it is the only thing the log holds.
- Two devices append independently and iCloud's conflict resolution is **union**: entries are
  distinct by time and 错题, duplicates collapse, and nothing needs merging in the hard sense.
  This is only true because the log has no state to disagree about.
- A 试招 — a move 耕棋 took back — is not a practice fact and does not go here. It belongs to the
  game, and it is written into the PGN as a comment on the move that was finally played, next to
  how many 提示层 were opened. See [ADR 0031](0031-the-player-no-longer-declares-a-reason.md).
- Re-deriving the book from a hundred PGN files on every screen open is already too slow and gets
  worse under a threshold. An index is needed — and it is a cache, rebuilt from the files and the
  log, never a third place where something is true.
