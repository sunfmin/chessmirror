# A save that did not land is said until one does

Every move writes the game (0010), and nothing said when that write failed. `GameSession.save()`
dropped `GameLibrary.write`'s answer, and in iCloud (0012) `write` answers once the save is
chained, before the bytes are down: a coordinated write that failed on its detached task returned
with no trace. A full disk, a folder iCloud will not take, a container signed out from under the
app — each left a player believing a game was kept that was not.

## The library keeps which files are behind

`GameLibrary.unsaved` is the set of files whose last write failed. A failed write puts its file
in, a write to it that lands takes it out, for the plain and the coordinated folder alike, and
the iCloud chain does it in order, so the newest save decides.

It lives in the library rather
than in `write`'s answer because an iCloud failure arrives after `write` has returned; and it is
per file, so a rename or an import that fails says so the same way. `GameSession.saveFailed`
reads it for the session's own file: there is one home for the fact, and the session holds no
copy that could disagree with it.

No retry of its own. The next move saves again, and the player keeps moving; a timer retrying a
write the folder just refused would be machinery for a case that the next save already covers.

## The game screen says it at its foot

「这局没能存下 · 下一步会再存」, in the alarm colour, at the foot of the game screen where the heart's
「已收藏到…」 line is (0051), and above it when both are up. An overlay and not a row: a row would
move the board each time it came and went (0025). It stays for as long as it is true — unlike
the heart's line, which goes after four seconds — because the game is at risk until a save lands.
