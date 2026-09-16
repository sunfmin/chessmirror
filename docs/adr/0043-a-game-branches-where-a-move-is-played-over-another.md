# A game branches where a move is played over another

ADR 0028's cut took the variation tree out of a Game and made it a list: browsing back and playing
something else **replaced** what followed. The reasoning was that the only two things ever writing
a branch were a Drill's answer and a 五步计划, both gone, and that taking a move back and playing
another is one game, not two.

That held for a game the player was playing. It broke on a game the player was *reading*. Open an
imported game — somebody's forty moves, a lichess study chapter, a book line — tap move ten to see
where it went wrong, play the move you would have played, and the thirty moves that came after are
gone from the file. The record shows your move in their place. Nothing said it was going to happen
and nothing brings them back: 「导入的棋谱，我点击某一步并自己走了之后，貌似把原来的棋都覆盖了」.
An imported game is not the player's to overwrite by accident, and trying an idea from the middle
of one is exactly what a reader does with a game.

**So a Game is a tree again, with one 树干.** Playing over a move puts the line that was there
beside the new move as a 分支, whole, with everything that was said about its moves — judgements,
试招, the Review's Scores — and the record can switch between the lines at that position: a rail
on the cell where they fork, and a vertical swipe on the strip. Stepping into a 分支 promotes it
to the line on the board and puts the other where it came from; the tree never loses a line.

The 树干 is the line the game arrived as — imported, or played out at the board — and it stays
the 树干 whichever line is on the board. The record inks a 树枝 in its own colour, so a line the
player tried from move ten cannot be mistaken for the game they were reading. This is the part
ADR 0028's tree did not keep across a save: a file was read with the line on the board as the
trunk, so reopening a game with a 树枝 on the board recoloured the original as the aside. The file
now says which is which, and says it only where the default is wrong — `[%trunk]` on the head of a
bracketed line that is the 树干, `[%branch]` on the move where the written line leaves it — so a
file with no markers reads the way every other program writes one: the mainline is the game and
the brackets are asides.

**把关 lands the same way.** A move weighed from an earlier position (ADR 0035) used to land as
the prefix it was weighed from with the move on the end, which dropped the rest of the game even
with 把关 on. The ruling now lands the move in the 原局 itself, so the line it was played over is
kept beside it, and while the engine thinks the board already shows that shape — nothing on the
strip disappears and comes back.

**What travels with a line.** A 试招 refused at a position along a line — recorded there because
no move had come to carry it (ADR 0037) — rides onto the move that stood at that position when the
line leaves the trunk, the same door it takes when the player carries on down a line; it is back in
its `[%pending]` slot when the line comes back. The one thing this loses is a refusal at the very
end of a line: there is no move to ride on and no position on the other line to keep it at.

## Consequences

- `Game.play(_:atPly:)` branches; `promoteVariation`, `siblings(atPly:)`, `variations(atPly:)`
  and `hasBranches` are back. `Ply.variations` and `Ply.isTrunk` are Ply fields again, carried by
  `takeAnnotations` like everything else said about a move.
- The 错题本, the 错招 list and the Review read the line on the board. A mistake on a 树枝 that is
  not on the board is not in the book until the 树枝 is; it is in the file.
- The file is one PGN with brackets, as it was before 0028, plus two markers nothing else reads.
  A file this app wrote between 0028 and now has no brackets and reads exactly as it did.
- 0028's identity for a 错题 — a position, not a Ply — is untouched, and is what makes a 错题 on a
  分支 the same 错题 as on the 树干: the same position reached is the same position.
