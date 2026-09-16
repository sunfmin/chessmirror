# The hint ladder has no rung to press, and is gone from the session

ADR 0031 kept the 提示层: a ladder of three rungs the player climbs one deliberate press at a
time, a 放宽 at the top that lets one move through at a looser 拦截线, and a reveal that plays
the engine's move and writes the refusals down as moves not found. The session carried all of
it — `requestHint`, `relaxIntercept`, `revealTillingMove`, a rung count and a relaxed line
restored per position on every retune — and `Standpoint`, `Ruling` and `Game.letStand` each
took the rungs and the relaxed line as parameters so a move that stood could be written with
them.

**Nothing on the phone could press any of it.** No screen called the three methods or read the
rung count; the only callers were three kit tests. That is the shape ADR 0040 deleted
`isPractising` over: a flag with one live value is not a mode, it is a constant with a name, and
every branch under its other value is a screen nobody can see. One adapter is a hypothetical
seam. The ladder had none.

So the session's ladder is deleted, and with it the relaxed line: `Standpoint` is the game and
the eye again, `Ruling.intercepts` reads the 拦截线 alone, and `letStand` writes a judgement and
takes the pending refusals and nothing else. What was tangled up with the ladder and is live —
the refusal sentence following the eye when the player browses away from a refused position
and back — is kept on its own, as `refusalByPosition`.

## Consequences

- 提示层 and 放宽 are retired words in CONTEXT.md. A ladder that comes back will be designed
  with a rung on the screen first, and will be a value the ruling is handed, not five fields
  the session restores per position.
- `Ply.hints` and the `[%hint N]` token stay: files written while the ladder existed carry the
  count, and reading them is not a reason to lose it. Nothing writes a count above zero now.
  `Drill.hintsOpened` and the practice log's `hints` field are the drill's own and stay live
  (docs/adr/0029).
- `Ply.Tried.notFound` stays as data. The reveal was the one thing in the session that wrote
  it; a drill's refusal and old files still carry it, and the 错题本 still reads it.
- ADR 0031's account of how many 提示层 were opened riding on the move is read as: the field
  rides, and the session has no ladder to fill it from.
