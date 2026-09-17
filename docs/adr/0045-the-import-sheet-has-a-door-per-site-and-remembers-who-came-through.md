# The import sheet has a door per site, and remembers who came through

The import sheet had two doors: a link, and a lichess username. Both were typed fresh every time
the sheet opened, and a name the site did not know came back as 「没有这个用户」— true, and no
help, because the one thing worth checking is the spelling and the message did not show it. The
sheet is the thing done before a flight, and a flight is not the moment to remember how a handle
is spelt or which of two accounts was the one with the games.

Players here also play on more than lichess. chess.com has a public archive per player per month.
国象联盟 has no export at all, but its share link *is* the game: the fragment after `#` is the
game's JSON, brotli-compressed and base64url-encoded, exactly as the site's own viewer reads it.

**So there is a door per site — lichess, chess.com, 国象联盟 — and the plain link door beside
them, and the sheet remembers.** `PGNImport.Site` names the three; the kit fetches a chess.com
player's newest games by walking back from the newest monthly archive until there are enough or
three months have been asked (`chessComMonthsBack`), and reads a 国象联盟 link with no network at
all (`chesseaseGame`). Every door feeds one pipeline: text, split, plan, files.

What the sheet remembers (`ImportMemory`, both stores like the lines): per site, the names that
have fetched games, newest first, at most four; the count; the door. A name is kept only after it
has fetched something — a misspelling that failed is not an account, and offering it back as a
chip would be offering the mistake back. When a door opens, its last account is in the field and
the others are a chip away; the button says what it is about to do, 「拉 sunfmin 最近 10 局」, so
the wrong account is caught before the network is asked.

A failure about a person carries the site and the name as typed: `unknownPlayer(.chessCom,
"SunFmn")` reads 「chess.com 上没有 SunFmn」. The session substitutes the name as typed over the one
in the URL, because chess.com lowercases its URLs and the reader is checking their own spelling.
The field the failure is about is marked in the alarm colour, and the button under the message is
the fetch again with the corrected name, not a bare 重试 — the same input a second time is the one
thing that will not help.

**The side whose mistakes are kept is the account's.** Through a player's door every game that
comes down is that account's game, so a row is told from their side — a swatch for the colour
they had, the opponent, 胜 / 负 / 和, when — and opening it records their side without the
「记录哪一方的错题？」 question, whose answer is already the name in the field. Through a link
nobody is known: a row is the chapter's own name and opening it still asks.

Not done: a 国象联盟 username. There is no endpoint for one, and a door that asks for what cannot
be answered is worse than no door. If the site ever publishes one, it is a fourth `withPlayers`
site and nothing in the sheet changes shape.

## Postscript: 入库 is one press, and the list stays

The list was, at first, only a list of games to open one at a time: opening a row wrote that
one game and closed the sheet, and the other nine stayed on the site until the sheet was opened
and the account pulled again. Ten games meant ten downloads and ten trips. That was the whole
value of a fetch thrown away.

So the list has one button, 「入库 N 局」, with what will be skipped in brackets. Pressing it
writes every game not already in the library and **puts each one in the library's review chain
at once** — this is the one place a Review starts without its own press (docs/adr/0044): the
player pressed for the lot, and a batch pulled before a flight should be judged by the time the
plane is up. The sheet does not close. Each row's standing changes where it is — 排队分析,
分析中 12/40, 已入库 5 道题 — read off the library the chain runs on, so closing the sheet and
coming back finds it still going. Opening a row is still opening one game to read it.

The fetch is kept across openings of the sheet (`LibraryScreen` owns the `ImportSession`), so a
list pulled once can be looked at twice.
