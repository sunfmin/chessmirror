# 耕棋 weighs a move wherever it is played

耕棋 measured a hand move only when the eye was on the last Ply of the game:

```swift
guard isTilling || hasTillingFeedback, isAtLatest, !game.isOver else {
    commit(move, by: .hand)   // no weighing, no refusal, no judgement
    return
}
```

The reason it was written that way is real. Playing a move from an earlier position is how this
app takes a move back, and a coach that argued with somebody rewinding a game would be stopping
them doing the one thing it exists to let them do (docs/adr/0028).

**But a saved game reopens at its *first* position** — "the beginning rather than the end, because
opening a game that is over is reading it" — so the one move a person is most likely to play is the
one move 耕棋 never looked at. The game that prompted this was a 错题 practice at
`r2qk2r/ppp2ppp/2npbn2/2b1p3/2B1P3/3P1N2/PPP2PPP/RNBQR1K1 w kq - 0 1`: the player had already
played `Bxe6` there (0.09%, passed, in the practice log), reopened the game — cursor on the opening
— and played `Qd2`. `[Intercept "5.0"]` was in the file, the toggle read 开, and the move stood
with no `[%judged]` and no `[%tried]`: it was never weighed. Black answered `Nxe4`, `Qd2` replaced
`Bxe6`, and the app had silently done the thing 耕棋 exists to prevent.

**So the interception follows the move, not the head of the game.** The move is judged from the
position on the board, and the game it interrupts is kept whole while that happens:

- A move that **passes** lands from that position, and what followed it is replaced — exactly what
  playing from an earlier Ply did before, and the only shape this app has for it (no variations,
  ADR 0028).
- A move that is **refused** leaves the game *and* the cursor exactly as they were. The old refusal
  path set `game` to the position the move was played from, which for an earlier Ply is a prefix of
  the game: being stopped would have swallowed the line the player was reading.
- `[%tried]` and `[%judged]` ride on the move that stands, wherever it stands, as before.

## Consequences

- Playing a move while the eye is on an earlier Ply now costs a search before it lands, where it
  used to land instantly. That is the trade the mode asks for: 耕棋 on means every move is weighed,
  and a mode that weighs *most* moves is a mode nobody can trust.
- The instant `commit` path is left for the two cases that are not a move under the coach's eye: a
  position that is already over, and a session nobody has asked for assessment on.
- `GameSession.opened` still opens a saved game at its first position. That default is deliberate
  — opening a game is reading it — and it is now safe to play from, rather than the one place
  where the app quietly stopped being 耕棋.
