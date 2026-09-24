# A wide window puts the game beside the board

docs/adr/0025 kept the iPad's four orientations on the grounds that "1032pt of height is room for
all of it". That was true of the height budget it was written against, and stopped being true when
the budget went: the board became full bleed at every size, and on an iPad held sideways full bleed
is a board 1376pt wide in a window 1032pt tall. The bottom rank, the standing line and the side on
the clock were under the fold, and the record and the cards were a scroll below that. Split View
and Stage Manager make it worse, because they hand the app windows of any shape at all.

## The window decides, and nothing else

`GameScreen.Arrangement(in:)` takes the window's size and returns the board's side and whether the
game stands beside it. Nothing it depends on changes during a game, so the board still never moves
because the engine found another line.

- **Taller than wide, or narrower than two columns** (every phone, a portrait iPad, a third or
  half of Split View): one column, as before. The board is as wide as the window, unless that
  would push its own two bars and the standing line (`chrome`, 150pt) off the screen, in which
  case it is that much shorter and the column is centred. On a phone that limit is never reached,
  so the phone's layout is unchanged.
- **Wider than tall, with room for two 320pt columns** (a landscape iPad, a two-thirds split, most
  Stage Manager windows): the board and its bars on the left, as tall as the window allows, and
  the drill's verdict, the record and the deck in a column on the right. When the board at full
  height would leave the column narrower than 320pt, the board is the one that gives way.

Each column scrolls on its own, so a side's controls unfolding pushes its own bar down and never
the record out of reach.

## The pages of rows are a column too

The library, the 错题本 and the position editor stop widening at 680pt and stand in the middle of
anything wider (`readableColumn`). The editor's board is centred as well: `BoardView` draws in the
top-left of whatever it is offered, which in a landscape window was a board against the left edge.

## Consequences

- `IPadLayout` renders the game, a drill, the editor and the three pages on ten windows (three
  iPads both ways up, three Split View widths, and a Stage Manager shape). It holds the board to
  being whole, square and as large as the window allows by reading the picture, not the code.
- `DeckFloor` still holds every phone to a full-width board in one column.
