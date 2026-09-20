# 棋镜 / Chessmirror

One context. The app turns the moves you got wrong into positions you practise again, and
plays a game against you that will not let a wrong move stand. Everything here serves one
end: raising the player's rating as fast as it can be raised.

The words below are the app's own. Chinese is the name; the English beside it is a gloss for
code, not a second name.

## Language

### 判决 — weighing a move

**胜率 (Win probability)**:
How likely the side to move is to win the game, on a 0–100 scale, converted from the engine's
Score. The one measure the whole app judges by.
_Avoid_: 分数, 评分, centipawns as a user-facing quantity

**掉幅 (Cost)**:
How much 胜率 a move gave away, measured against the best move available in that position.
Never positive: the best move costs nothing, and every other move costs something.
_Avoid_: 损失, 误差, delta

**最佳 (Best move)**:
The move the engine itself would have played from that position: its first choice, by the
search that judged the move. A fact about which move it was, read off that search, never a 掉幅
that rounded to zero — two equally good moves are both 0.0%, and only one of them is 最佳.
_Avoid_: 最好, 好棋, 0%

**收下 (Take-up)**:
When the opponent's last move gave 胜率 away, how much of that gift the player's reply kept.
The one place a positive number is honest, and it is settled only after the move is played.
A reading of the Game with no screen at present (docs/adr/0040).
_Avoid_: 抓住, 反击

**要害 (Vital)**: _retired._ The word named a card that no longer exists. Do not reuse it.

### 错题 — the mistake book

**错题 (Mistake)**:
A position the player got wrong. **The position is the identity**: the same position reached
in four different games is one 错题, not four.
_Avoid_: 错误, 题目, 谜题, puzzle

**错招 (Slip)**:
One move in one game that the player got wrong: the position it was played from, what was played,
what it cost. The answer to 「这一局我哪儿走错了」, and what a game's own record strip marks and
walks to. Not a 错题: a 错题 is the position, and this is one game's account of reaching it.
_Avoid_: 错误, 失误, 招法

**分数曲线 (Score curve)**:
The record's Scores as one shape: a level per position of a game, high where White is doing well,
nil where nobody has scored it, drawn under the record strip once two positions are known
(`ScoreCurve`). It is read off the record — the 细判 written on each move first, then the Review —
and never off the live search. One Score is a number, not a shape.
_Avoid_: 走势, 评估曲线

**遭遇 (Occurrence)**:
One time the player fell for a 错题 — when, in which game, which move they played, what it
cost, where it came from. A 错题 owns a list of them. A 试招 refused while practising is one of
these like any other: the book counts occasions and the 练习日志 counts goes, and neither is read
off the other (docs/adr/0047).
_Avoid_: 记录, 实例, 犯错

**复发 (Recurrence)**:
Falling for the same 错题 more than once. The strongest signal the app has, and the only one
allowed to jump the queue.

**老毛病 (Habit)**: _retired._ The word named a screen that sorted mistakes into five kinds.
错题 are not sorted into kinds at all — the book is one flat list. Do not reuse it.

### 判决线 — the thresholds

Both are a 掉幅, both are the player's, and they are separate on purpose.

**记录线 (Record line)**:
The 掉幅 at which a move is written down at all — and, while 把关 is on, at which the player is
stopped and the move taken back. One number for both, because both ask what counts as a mistake.
The only dial 把关 has on the judgement of a move — the engine's 棋力 shapes the opponent it
plays, never what a move costs.

**拦截线 (Intercept line)**:
Where 把关 stopped the player for a given move: the 记录线 at the time, written on the judgement
as the line it stood under. _Not a setting_ — it was one, with a slider of its own, until the two
were made one number. Do not reintroduce a separate dial for it.

**入列线 (Enrol line)**:
The 掉幅 at which a 错题 starts taking up the player's future practice time. Never below the
记录线, and raised above it by a player who wants a wide book and a narrow queue: a mistake can be
worth remembering without being worth drilling. Both ship at ten.

### 日课 — the day's practice

**练习 (Practice)**:
Working through 日课 or revisiting a 错题, **played under 把关**: the wrong answer comes back off
the board and is written down where it happened (docs/adr/0047). Not the opposite of 把关, and
never was — and not a synonym for hiding the engine's answer either: 杀 and 战术 are dealt here
the way they are in an ordinary game, and opening one is counted as help rather than refused.

**日课 (Daily)**:
The 错题 due today, as one queue, in one order. **It cannot be filtered, sorted or split** —
a queue the player carves up is a queue that has stopped working.
_Avoid_: 今日队列, 复习列表, 任务

**掌握 (Mastered)**:
A 错题 the app does not expect to need for a long time. A reading of how far off its next
practice is, never a state the player or the app sets.
_Avoid_: 毕业, 完成, 已学会

**计划外练习 (Unscheduled practice)**:
Practising a 错题 the player picked themselves rather than one the 日课 handed them. It is
recorded, and it does not move anything's schedule.

**练习日志 (Practice log)**:
What the player has actually done — which 错题, when, how long it took, whether it passed,
how much help was asked for. Facts only: it records what happened and never what should
happen next.
_Avoid_: 进度, 统计, 状态

### 把关 — the game that will not let you slip

**把关 (No Slips)**:
A game against the engine in which any move costing the 记录线 or more is refused and taken
back, with nothing said about what to play instead. Only sound moves stand. The switch and the
door are named for what the app does — somebody is at the gate — because 正着, the word for the
move, read as nonsense on a switch: 「正着 开」.
_Avoid_: 正着 as the name of the mode, 耕棋 (retired, and the ploughing words with it), 训练模式,
挑战模式, hard mode

**正着 (Sound move)**:
What a move is once it has stood under 把关. The word for the move, never for the mode; it
survives in 连正, a run of them.
_Avoid_: 好棋, 正确

**试招 (Tried move)**:
A move the player played and 把关 took back. It never happened in the game, and it is exactly
what the 错题 is made of.
_Avoid_: 变着, 悔棋

**分支 (Branch)**:
A line played from an earlier position instead of the move that stood there. Playing over a
move never writes it out: what followed moves in beside the new move, whole, and the record can
switch between them (docs/adr/0043). A game is a tree of lines with one 树干 — the line it
arrived as, imported or played out — and every other line a 树枝, inked in its own colour.
_Avoid_: 变着 (that word is for a 试招 and is refused there too), 变体, alternative, fork as the
name of the line (a fork is the position the lines leave from)

**原局 (Standpoint)**:
The game as it was being read when a move was played, and where the eye stood in it, kept while
the move is weighed. What is put back when the move does not stand — refused, or nobody finished
weighing it, or the player left mid-weighing — whole, with the eye where it was. The whole game,
not only the position the move was played from: a move played from an earlier position must not
swallow the line being read.
_Avoid_: 原位, 之前的局面, snapshot

**应招 (Reply)**:
The Line a 试招 earned — the opponent's strongest answer and the few moves after it. Worked out
by the search that refused the move, kept beside it, and shown only when the 试招 is pressed.
The 惩罚 exercise asks the player to find this same answer; what differs is who finds it.
_Avoid_: 反击, 变着, 惩罚

**提示层 (Hint layer)**: _retired._ The word named a ladder of rungs no screen could press
(docs/adr/0042). A game file may still carry how many were opened before a move. Do not reuse
it without a rung on the screen.

**放宽 (Relax)**: _retired._ The top of that ladder, gone with it (docs/adr/0042).

**棋力 (Strength)**:
The Elo the engine is bound to for its own moves, picked from a fixed ladder; 满力 is unbound.
It shapes the opponent and nothing else: 细判 weighs every move at full strength whatever the
棋力, so a 掉幅 means the same thing at every rung.
_Avoid_: 难度, 级别, 等级, 档位

**正着数 (Distance)**: _retired._ It counted every move that stood while 把关 was on, which
with 把关 on was the length of the game — a number the record already shows. Only 连正 is read.

**连正 (Run)**:
An unbroken run of the player's moves that stood, with no 试招 between them. Two are read: the
run since the last 试招, and the game's longest. Only a 试招 ends a run; switching 把关 off
pauses it.

**连正榜 (Ladder)**:
Per 棋力, the longest 连正 across all games, pointing at the game it happened in. Read out of
the games themselves. A game
can change 棋力 as it goes, and each stretch is credited to the 棋力 it was played at; a stretch
against a human is credited to none.

### 进料 — where positions come from

**门 (Door)**:
One way into the import sheet: a site's username — lichess, chess.com — a 国象联盟 share link,
or any other link to a PGN. Four doors, one pipeline behind them. The sheet opens on the door
used last, with the account that fetched last already in the field, and a failure about a name
says the site and the name as typed (docs/adr/0045).
_Avoid_: 来源, 平台, mode

**粗筛 (Sift)**:
Using evaluations that came with an imported game to decide which moves are worth looking at
properly. Never decides whether something is a 错题.

**细判 (Judge)**:
The app's own engine, at its own depth, deciding what a move actually cost. **The only thing
allowed to call something a 错题.** One act, wherever it is asked for: 把关 refusing a move as
it lands, a drill judging an attempt and the 惩罚 exercise checking a reply all weigh a move the
same way, at the same budget, and a checkmate or a draw is settled without asking the engine.

**搜索预算 (Search budget)**:
How long and how deep the engine looks at one position, and which of the two ends it: the first
to arrive, the time alone, or the depth alone. One for the whole app, set by the player: 细判, the
engine's own move and a hint are all the same search, so a 掉幅 means the same thing wherever it
was measured. A 复判 goes past it by a fixed rule, never by a second budget.
_Avoid_: 难度 (that is 棋力), 思考时间 or 层数 on their own, 引擎设置

**判定 (Ruling)**:
What follows from a 细判: whether the move stands, and what is written down either way. A move
that stands carries its judgement and the 试招 refused before it; a move that is refused is
written where it happened and the game is put back as it was being read; a move nobody could
judge is put back with nothing written. One reading, shared by 把关 and a drill's attempt.

**复判 (Re-judge)**:
Judging a 试招 again, deeper: both ends of the move — the position it was played from and the
position it made — searched to the same deeper level, and its 掉幅 and 应招 rewritten from that.
Asked for by the player, one move at a time, never run on its own. It does not change the fact
that the move was taken back; that happened, and stays written where it happened.
_Avoid_: 再算, 深算, 重新分析
