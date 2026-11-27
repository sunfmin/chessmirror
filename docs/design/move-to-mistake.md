# 一步棋是怎么变成错题的

设计笔记：对局里落下的一步棋，从称量、判定到并进错题本的那条路。
名词在 [GLOSSARY.md](../../GLOSSARY.md) 里，为什么在 [docs/adr/](../adr/) 里，这里只说发生了什么、按什么顺序；每一步下面那行反引号是它在代码里的落点。

1. 玩家在棋盘上落子。会话先问这步该不该称：轮到人走、没在称别的、有引擎、棋局没结束。
   有一条不成立，这步棋就无判地站住。
   `Sources/ChessmirrorKit/GameSession.swift:play`
2. 该称的，这步棋**先落到棋盘上**，记录上也先摆好 —— 人看得见自己走了什么，引擎在后台开始算。
   `Sources/ChessmirrorKit/GameSession.swift:weigh`
3. 细判称这步棋的两端：走之前的局面和走之后的局面，同一次搜索，10 秒或 20 层先到先停。
   这步棋该得的应招从同一次搜索里顺手取出，因为局面一旦被退回就再也取不到了。
   `Sources/ChessmirrorKit/Weighing.swift:weigh`
4. 掉幅 = 两端胜率之差，从走棋方的角度看。最佳的那手花掉零，别的都要花。
   `Sources/ChessmirrorKit/Weighing.swift:Weighing`
5. 判定读一条线：掉幅 < 记录线，这步棋站住，把它之前被退回的试招一并带上；
   掉幅 ≥ 记录线，这步棋被退回，写在它发生的那个位置上。
   `Sources/ChessmirrorKit/Judgement.swift:records`
   `Sources/ChessmirrorKit/Ruling.swift:Ruling`
6. 判定落地：棋盘和眼睛按它走，出声、存盘、必要时开惩罚练习。
   `Sources/ChessmirrorKit/GameSession.swift:land`
7. 站住的招法带着它的判决写进去，被退回的招法写成试招。
   `Sources/ChessmirrorKit/Game.swift:setJudgement`
   `Sources/ChessmirrorKit/Game.swift:recordTried`
8. 会话存盘。一局棋就是一个 PGN 文件，在 iCloud 的库文件夹里。
   `Sources/ChessmirrorKit/GameSession.swift:save`
9. 错题本重走这个文件，把每个停顿上所有超过记录线的招法读成遭遇 ——
   站住的那手（需要复盘量过）和被退回的试招（退回时就量过了）是同一种事实。
   `Sources/ChessmirrorKit/MistakeBook.swift:encounters`
10. 同一个局面的所有遭遇并成一道错题。局面就是身份：同一个局面在四局里走错，是一道错题，不是四道。
    `Sources/ChessmirrorKit/MistakeIndex.swift:rebuild`

**这里会分叉。** 把关关掉 → 不再退回，但细判照做（[adr/0046](../adr/0046-no-slips-stops-the-player-at-the-record-line.md)）。
开关任何时候都能按，判断中途也行：这手按判完那一刻的开关裁（[adr/0048](../adr/0048-the-no-slips-switch-always-moves.md)）。
引擎不在或棋局已结束 → 第 1 步就放行，这步棋无判地站住。
被退回的试招可以单独要求复判，更深地重算，但「它被退回过」这件事不会因此消失（GLOSSARY.md 复判）。

