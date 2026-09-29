# Positions are kept in collections, and the found ones join the 日课

#24 took 作品集 out: a set of whole games filed by hand, on the ground that nobody curates the
source of their own mistakes. That still stands. What comes back is a different thing — a
**收藏集** holds *positions*, with the position as the identity exactly as a 错题 has it
(docs/adr/0028) — and it comes back in two kinds that are kept apart on purpose.

**自动集: 杀招 and 战术.** Derived from the games the app has judged, the way the 错题本 is: a
position where the side to move has a mate goes in 杀招, one where it has a winning shot goes in
战术, and a mate outranks a shot so each position is in one of them at most. Both sides' shots are
kept — the opponent's is the same question with the board turned — so opening one always shows the
side to move at the bottom. A shot that only takes a loose piece, or that gains too little 胜率, is
not kept: a set that fills with 「吃掉白送的后」 is a set nobody opens. The player can take a
position out (移出), which is remembered; nothing can be put in by hand.

**Their 藏局 enter the 日课, shuffled in with the 错题.** The first design gave every 收藏集 a
queue of its own, 「练这一组」, and that is exactly the practice docs/adr/0032 refuses: a block
of 杀招 tells the player the answer is a mate before they look, which trains Einstellung and
flatters the one who does it. So the found positions are scheduled the way 错题 are — one queue,
nothing saying which kind the next one is — with a daily intake cap of their own so they cannot
crowd the 错题 out. A position that is a 错题 is scheduled as a 错题 and only once.

**自建集 are never scheduled.** The player makes them, names them, fills them with the heart
(喜爱 by default, always there, never renamed), and a position may be in several. Practising from
one is 计划外练习 — recorded, moving nothing — for docs/adr/0032's narrower reason: positions a
player picks to repeat are the ones FSRS would come to believe they know best.

## Consequences

- The 日课 is no longer 「the 错题 due today」 but 「the 错题 and found 藏局 due today」; the
  one-queue rule is untouched.
- Found sets cost engine time: each judged position is also asked whether the side to move has a
  shot.
- 自建集 and the 移出 list are the player's decisions and are stored, each as a PGN file in the
  library folder (docs/adr/0010, docs/adr/0012), one position per entry with a `[FEN]`.
