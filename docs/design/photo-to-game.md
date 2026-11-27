# 一张照片是怎么变成一盘棋的

设计笔记：一张棋盘的图，从解码、找盘、识别到开出一盘棋的那条路。
名词在 [GLOSSARY.md](../../GLOSSARY.md) 里，为什么在 [docs/adr/](../adr/) 里，这里只说发生了什么、按什么顺序；每一步下面那行反引号是它在代码里的落点。

1. 图从五个口进来：相机、相册、截图、文件、分享扩展。四千八百万像素的照片直接解码成缩略图，
   整张原图一次也不持有。
   `Sources/ChessmirrorKit/BoardIntake.swift:decode`
2. 在图里找棋盘的四角，做透视矫正。这是一个前置阶段，不是识别的一部分。
   `Sources/ChessmirrorKit/BoardGeometry.swift:findBoard`
3. 棋盘格分数判断这是画出来的还是拍出来的 —— 同一个分数，两个用处。
   `Sources/ChessmirrorKit/BoardGeometry.swift:checkerScore`
   `Sources/ChessmirrorKit/Recognizer.swift:Provenance`
4. 64 格逐格分类，每格带一个把握度。
   `Sources/ChessmirrorKit/Recognizer.swift:recognise`
5. 把握度不够的格子标成抖格，带着走，不在这里拦人。
   `Sources/ChessmirrorKit/Recognizer.swift:Recognition`
6. 读出来的局面**直接开局**。确认关口早就不在了：认对了是常态，不该每次都收一次过路费。
   `App/Chessmirror/LibraryScreen.swift:recognise`
   `Sources/ChessmirrorKit/GameSession.swift:recognised`
7. 认错了才去编辑器。它只做一件事：把子摆到它们实际在的地方。
   `App/Chessmirror/ConfirmPositionScreen.swift:ConfirmPositionScreen`
8. 改完的局面回到同一盘棋里 —— 还没走过子的话，不是新开一局。
   `App/Chessmirror/ConfirmPositionScreen.swift:PositionProposal`

**这里会分叉。** 谁执先、棋盘朝哪边、两边各是谁在下，都在对局屏上常驻，所以不在编辑器里
（[adr/0011](../adr/0011-recognition-opens-a-game-and-corrections-are-an-editor-behind-it.md)）。
直接给 FEN 的，跳过 1 到 5。

