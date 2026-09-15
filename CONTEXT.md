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

**收下 (Take-up)**:
When the opponent's last move gave 胜率 away, how much of that gift the player's reply kept.
The one place a positive number is honest, and it is settled only after the move is played.
_Avoid_: 抓住, 反击

**要害 (Vital)**: _retired._ The word named a card that no longer exists. Do not reuse it.

### 错题 — the mistake book

**错题 (Mistake)**:
A position the player got wrong. **The position is the identity**: the same position reached
in four different games is one 错题, not four.
_Avoid_: 错误, 题目, 谜题, puzzle

**遭遇 (Occurrence)**:
One time the player fell for a 错题 — when, in which game, which move they played, what it
cost, where it came from. A 错题 owns a list of them.
_Avoid_: 记录, 实例, 犯错

**复发 (Recurrence)**:
Falling for the same 错题 more than once. The strongest signal the app has, and the only one
allowed to jump the queue.

**老毛病 (Habit)**: _retired._ The word named a screen that sorted mistakes into five kinds.
错题 are not sorted into kinds at all — the book is one flat list. Do not reuse it.

### 三条线 — the thresholds

All three are a 掉幅, and they are separate on purpose.

**拦截线 (Intercept line)**:
The 掉幅 at which 耕棋 stops the player and takes the move back. The only dial 耕棋 has — the
engine's strength is never the difficulty.

**记录线 (Record line)**:
The 掉幅 at which a move is written down at all.

**入列线 (Enrol line)**:
The 掉幅 at which a 错题 starts taking up the player's future practice time. Higher than the
记录线: a mistake can be worth remembering without being worth drilling.

### 日课 — the day's practice

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

### 耕棋 — the game that will not let you slip

**耕棋 (No Slips)**:
A game against the engine in which any move costing more than the 拦截线 is refused and taken
back, with nothing said about what to play instead. Ploughing: an inch at a time, and no
moving on until this inch is right.
_Avoid_: 训练模式, 挑战模式, hard mode

**试招 (Tried move)**:
A move the player played and 耕棋 took back. It never happened in the game, and it is exactly
what the 错题 is made of.
_Avoid_: 变着, 悔棋

**提示层 (Hint layer)**:
One rung of what the app will say when asked. Every rung must be asked for, and how far the
player climbed is part of what the move is worth knowing about.

**放宽 (Relax)**:
Letting one move through at a looser 拦截线 because the player could not find anything better.
The move still becomes a 错题, and a heavier one than a first-try slip.

### 进料 — where positions come from

**粗筛 (Sift)**:
Using evaluations that came with an imported game to decide which moves are worth looking at
properly. Never decides whether something is a 错题.

**细判 (Judge)**:
The app's own engine, at its own depth, deciding what a move actually cost. **The only thing
allowed to call something a 错题.**
