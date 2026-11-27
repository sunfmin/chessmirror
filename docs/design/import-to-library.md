# 外面的一盘棋是怎么进到库里的

设计笔记：从别的网站导入的棋局，从导入表的门、复盘到贡献错题的那条路。
名词在 [GLOSSARY.md](../../GLOSSARY.md) 里，为什么在 [docs/adr/](../adr/) 里，这里只说发生了什么、按什么顺序；每一步下面那行反引号是它在代码里的落点。

1. 玩家在导入表里选一扇门：lichess 用户名、chess.com 用户名、国象联盟分享链接，
   或任意指向 PGN 的链接。四扇门，后面一条管线。
   `App/Chessmirror/ImportSheet.swift:Door`
2. 门把输进来的东西翻成候选 URL。用户名走各站的 API，链接先猜是不是 study 或对局页。
   `Sources/ChessmirrorKit/PGNImport.swift:candidateURLs`
   `Sources/ChessmirrorKit/PGNImport.swift:recentGamesURL`
   `Sources/ChessmirrorKit/PGNImport.swift:chessComArchivesURL`
3. 拉下来的 PGN 拆成一份份棋局，逐份对照库里有没有，玩家挑要哪些。
   `Sources/ChessmirrorKit/PGNImport.swift:ImportOutcome`
4. 选中的写成文件落进库文件夹，和自己下的那些放在一起。
   `Sources/ChessmirrorKit/GameLibrary.swift:write`
5. 复盘是**问过才跑**的，打开一局棋从不自动触发：一手几秒引擎，玩家说什么时候。
   `Sources/ChessmirrorKit/GameLibrary.swift:reviewImported`
6. 粗筛：导入自带的评分先算出哪些手可疑（掉幅 ≥ 7%），排到队伍前面。
   自带评分不完整就整局本地跑。粗筛只决定先看谁，从不决定谁是错题。
   `Sources/ChessmirrorKit/ImportReview.swift:plan`
7. 细判逐个局面搜到 16 层。将杀和和棋不问引擎，直接结算。
   `Sources/ChessmirrorKit/ImportReview.swift:judge`
8. 一局的分数一次性写回，全部在同一个深度上 —— 混了深度的文件事后没法互相排名。
   `Sources/ChessmirrorKit/Game.swift:applyReview`
9. 写回文件。中途任何一个局面没搜完，整局作废，什么都不存，再问一次从头来。
10. 错题本只重走改过的文件，把新的遭遇并进来，顺手报一句这次新增了几道。
    `Sources/ChessmirrorKit/MistakeIndex.swift:update`

**这里会分叉。** 复盘跑的时候文件被改过 → 结果丢掉，不覆盖
（`Sources/ChessmirrorKit/GameLibrary.swift:ReviewOutcome`）。没复盘过的导入棋局不是「没毛病的棋局」，
是「没人看过的棋局」，它一道错题也贡献不出来（[adr/0016](../adr/0016-a-plys-evaluation-belongs-to-a-review-and-to-nothing-else.md)）。

