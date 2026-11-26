# 棋镜 / Chessmirror

One context. The app turns the moves you got wrong into positions you practise again, and
plays a game that will not let a wrong move stand: all to raise the player's rating as fast as
it can be raised. Chinese is each word's name; the English beside it is a gloss for code, not a
second name. The ADR or symbol beside a word holds its mechanism.

## Language

### 判决 — weighing a move

**胜率 (Win probability)**: How likely the side to move is to win, 0–100, from the engine's
Score; the one measure the app judges by (docs/adr/0027).
_Avoid_: 分数, 评分, centipawns as a user-facing quantity

**掉幅 (Cost)**: How much 胜率 a move gave away against the best move there; never positive.
_Avoid_: 损失, 误差, delta

**最佳 (Best move)**: The engine's own first choice, by the search that judged the move; never
a 掉幅 that rounded to zero.
_Avoid_: 最好, 好棋

**收下 (Take-up)**: How much of the opponent's gift of 胜率 the player's reply kept; no screen
shows it (docs/adr/0040).
_Avoid_: 抓住, 反击

**优势条读数 (Bar reading)**: The one number the advantage bar shows, and where it came from
(`BarReading`).
_Avoid_: 估值, 局面分, feedback

**牌堆 (Deck)**: The findings under the record, 杀招 and 战术, each shut until pressed
(`Deck`, docs/adr/0025).
_Avoid_: 提示 as the name of a card, 卡片列表, panel

**要害 (Vital)**: _retired._ It named a card that no longer exists. Do not reuse it.

### 错题 — the mistake book

**错题 (Mistake)**: A position the player got wrong. The position is the identity: reached in
four games, it is one 错题 (docs/adr/0028).
_Avoid_: 错误, 题目, 谜题, puzzle

**错招 (Slip)**: One move in one game the player got wrong: one game's account of reaching a
错题 (`Slip`).
_Avoid_: 错误, 失误, 招法

**记录读数 (Record reading)**: What one game's record says of the player's 错招 at one
position, with no engine (`RecordReading`).
_Avoid_: 分析, 统计, summary

**分数曲线 (Score curve)**: The record's Scores as one shape under the record strip
(`ScoreCurve`).
_Avoid_: 走势, 评估曲线

**分析行 (Review row)**: What an imported game says of its Review: offered, running or done
(`ReviewRow`, docs/adr/0044).
_Avoid_: 复盘状态, review status

**遭遇 (Occurrence)**: One time the player fell for a 错题: when, in which game, what was
played and what it cost. A 错题 owns a list of them.
_Avoid_: 记录, 实例, 犯错

**复发 (Recurrence)**: Falling for the same 错题 again: the strongest signal, and the only one
allowed to jump the queue.

**老毛病 (Habit)**: _retired._ It named a screen that sorted mistakes into kinds; the book is
one flat list. Do not reuse it.

### 判决线 — the thresholds, each a 掉幅 and the player's

**记录线 (Record line)**: The 掉幅 at which a move is written down, and at which 把关 takes it
back: 把关's only dial (docs/adr/0046).

**拦截线 (Intercept line)**: The 记录线 a refused move stood under, written on its judgement.
Not a setting; do not bring back a dial for it.

**入列线 (Enrol line)**: The 掉幅 at which a 错题 enters the 日课; never below the 记录线
(`Enrolment`).

### 日课 — the day's practice

**练习 (Practice)**: The act of working a 错题 or a 藏局, never a place; played under 把关
(docs/adr/0047).

**日课 (Daily)**: The 错题 and the 自动集's 藏局 due today, one shuffled queue that cannot be
filtered, sorted or split (docs/adr/0032, 0051).
_Avoid_: 今日队列, 复习列表, 任务

**掌握 (Mastered)**: A 错题 whose next practice is far off: a reading, never a state anyone sets.
_Avoid_: 毕业, 完成, 已学会

**计划外练习 (Unscheduled practice)**: Practising a position the player picked rather than
the 日课; recorded, and it moves no schedule.

**练习日志 (Practice log)**: What the player actually did, never what is due (docs/adr/0029).
_Avoid_: 进度, 统计, 状态

### 收藏集 — positions kept

**收藏集 (Collection)**: A named set of positions, one 藏局 per position; two kinds, 自动集 and
自建集 (docs/adr/0051).
_Avoid_: 作品集, 收藏 as the name of the set, 文件夹, 标签

**藏局 (Holding)**: One position in a 收藏集, with the games it was reached in.
_Avoid_: 收藏项, 条目

**自动集 (Found collection)**: 杀招 and 战术, one 收藏集 each, found in the judged games; its
藏局 enter the 日课.
_Avoid_: 战术库, 题库, puzzle

**自建集 (Player collection)**: A 收藏集 the player names and fills by hand; never scheduled.
_Avoid_: 文件夹, 分组

**喜爱 (Favourites)**: The 自建集 that is always there, where the heart puts a position.
_Avoid_: 收藏 (that is the set of all of them), 书签

**移出 (Take out)**: Taking a 藏局 out of a 自动集 for good.

**作品集 (Collection of games)**: _retired._ It named a set of whole games. Do not reuse it: a
收藏集 holds positions.

### 把关 — the game that will not let you slip

**把关 (No Slips)**: A game in which a move costing the 记录线 or more is refused and taken
back, with nothing said about what to play instead (docs/adr/0046, 0048).
_Avoid_: 正着 as the mode's name (「正着 开」 reads as nonsense), 耕棋 and its ploughing words,
训练模式, 挑战模式, hard mode

**正着 (Sound move)**: A move that stood under 把关; it survives in 连正.
_Avoid_: 好棋, 正确

**试招 (Tried move)**: A move 把关 took back. It never happened in the game; the 错题 is made
of it.
_Avoid_: 变着, 悔棋

**分支 (Branch)**: A line played from an earlier position over the move that stood there; a
game has one 树干, and every other line is a 树枝 (docs/adr/0043).
_Avoid_: 变着, 变体, alternative, fork as the name of the line

**原局 (Standpoint)**: The game as it was being read when a move was played, put back whole
when the move does not stand (`Standpoint`).
_Avoid_: 原位, 之前的局面, snapshot

**应招 (Reply)**: The opponent's strongest answer to a 试招, kept beside it (docs/adr/0034).
_Avoid_: 反击, 变着, 惩罚

**提示层 (Hint layer)**, **放宽 (Relax)**: _retired_ with the hint ladder (docs/adr/0042). Do
not reuse them without a rung on the screen.

**棋力 (Strength)**: The Elo the engine is bound to for its own moves; 满力 is unbound. It
shapes the opponent, never the judge (docs/adr/0038).
_Avoid_: 难度, 级别, 等级, 档位

**掷子 (Toss)**: How a 满力 opponent picks at random among moves its search cannot tell apart
(`Toss`, docs/adr/0049).
_Avoid_: 随机, 开局库, 让子

**正着数 (Distance)**: _retired._ It was the game's length under 把关. Only 连正 is read.

**连正 (Run)**: An unbroken run of the player's moves that stood; only a 试招 ends it.

**连正榜 (Ladder)**: Per 棋力, the longest 连正 across all games, and the game it was in
(`Ladder`).

### 进料 — where positions come from

**门 (Door)**: One way into the import sheet: a lichess or chess.com name, a 国象联盟 link, or
any link to a PGN (docs/adr/0045).
_Avoid_: 来源, 平台, mode

**本人账号 (Own account)**: Per site, the account that last fetched through its 门: the
player's.
_Avoid_: 我的账号, 主账号, 绑定账号

**自动拉局 (Auto fetch)**: Pulling the 本人账号's new games unasked, once a day and on request
(`AutoFetch`).
_Avoid_: 同步, 自动导入 (导入 is the whole sheet)

**粗筛 (Sift)**: Using an imported game's own evaluations to pick the moves worth judging;
never decides a 错题.

**细判 (Judge)**: The app's own engine deciding what a move cost: the only thing that may call
something a 错题.

**搜索预算 (Search budget)**: How long and how deep the engine looks at one position; one for
the whole app, set by the player (`SearchLimit`).
_Avoid_: 难度 (that is 棋力), 思考时间 or 层数 on their own, 引擎设置

**判定 (Ruling)**: What follows from a 细判: whether the move stands, and what is written down
either way (`Ruling`).

**复判 (Re-judge)**: Judging a 试招 again, deeper, when the player asks (docs/adr/0041).
_Avoid_: 再算, 深算, 重新分析
