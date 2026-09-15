# The deck's room is part of the board's budget, and a phone is held in portrait

docs/adr/0024 put one card at a time under the board and made the card the whole of what a
position can do. That deck is sized — `peek - railHeight` — out of whatever the board leaves, and
what the board leaves was `size.height - 388` with a `max(240, …)` over it. **The `max` was a
second decision nobody had taken.** On a screen shorter than the sum the board kept its minimum and
the deck paid the difference, and when the difference was all of it the deck did not become small:
`opacity(peek == 0 ? 0 : 1)` made it invisible — no card, no names, and every action that lives on
a card gone. Nothing on screen said so, and no test could: the assertions are words, and a hidden
view still has words.

## The board yields

The room the deck wants is now part of the sum the board is sized against, in named parts —
`chrome` (the two player bars, the standing strip, the record) + `railReserve` (the five names) +
`cardWanted` (162pt of card) = 388, which is the number the board's height budget already was. So
nothing moved on any screen that was working; what changed is that the arithmetic says why, and
that `max(240, …)` is now `minBoard` *inside* a sum rather than over it.

**And the deck takes that room as a child of the column rather than as an overlay over a spacer
that was measured to find out how much was left.** It was measured for exactly one reason — so that
a card's own length could not push the board around — and a child that takes the leftover does not
push anything, because a scroll view accepts whatever it is given and the board's frame is fixed.
What the measurement cost was a state in which the room had not been reported yet, and the deck's
answer to that state was `opacity(0)`: no card, no names, and every action that lives on a card,
gone, with nothing on screen to say so. That state is not hypothetical — a layout pass that settles
in one go never reports a geometry *change* at all, which is what an off-screen render does and
what the first frame of a screen may do. Removing the measurement removes the state.

`cardFloor` (120pt) is what the board's reserve is aimed at and what the tests hold every screen to;
it is not a clamp in the layout. The deck is whatever the column has left, and the board's budget is
the thing that keeps that at or above the floor. The shortest screen the app runs on — an iPhone SE
— leaves 137pt, which is the tightest a card ever is, and that is the shape to keep it in: a floor
that is doing work is a floor that has been hit.

Measured on the render (`game-in-play.png`, 402×874): the layout is handed 758pt, the board takes
368, the deck gets 212, the card in front is 164. `DeckFloor` reads the card and the column back off
the picture and holds them to the arithmetic on a 375-wide screen — the two together are what says
the constants are not fiction — and holds the arithmetic itself to every screen the app runs on,
including a phone on its side, where the answer has to be "no room", because that is the fact the
next decision is made of.

## The phone is held in portrait

An iPhone on its side is 402pt tall. There is no board, no two bars, no record and no five cards in
402pt: `deckRoom` comes back at −60. The choice was a second layout for landscape or the deck not
existing, and the deck is where everything happens.

The iPad keeps all four ways up — 1032pt of height is room for all of it — so the restriction is
stated per device family (`UISupportedInterfaceOrientations` against `…~ipad`) rather than as a
blanket policy, and a test reads the built plist rather than the file that generates it.

## What a card does with its own room

Three things in the deck were sized by the wrong fact:

- **The fade was unconditional and painted on the scroll view**, so it never moved. The last line of
  a long card stayed washed out even scrolled to the end, and a card whose whole body fitted wore a
  fade promising a paragraph that was not there. It is now shown when the viewport is actually
  holding more than it shows (content against offset), and the column ends with the fade's own
  height of padding, so nothing anybody has to read is ever underneath it.
- **The five names are an index and are the only capped words in the app.** They are one capsule,
  two characters and 22pt of padding each; at the largest text sizes five of them are wider than
  the phone, and what happens to the ends is that they are clipped — 练习 last, which is the card
  that asks the question. The row stops growing at `accessibility1` (334pt of names). The card under
  it keeps growing with the reader.
- **The card's numbers were fixed size while the sentences around them grew.** `.clock(22)` is a
  number at a size somebody designed; beside 40pt prose it stops being the important half of the
  line. They now scale with the reader, capped at 1.4× — a number is a number, and the rows it sits
  in stop fitting before it stops being readable.

The rows that hold those numbers and the chrome around them became minimum heights rather than
heights, so that a larger text size grows the row instead of cutting it in half.

**And the rows above the board stop growing at the first accessibility size** (`chromeType`). Not a
quiet override of the reader's setting: the card is what the app is for, and its sentences are the
only text on this screen anybody has to *read*. Everything else — whose move it is, the clock, the
record's chips, the five names — is status, and those rows are also the only ones whose growth is
not paid for: the board is sized from a budget and the deck takes the rest. At the largest size they
took a hundred points off the deck to say 「黑方 引擎 跟着我」 at 40pt and left the card **42pt**
tall, which is one line of itself and nothing else. Capped, they still grow by a fifth — and the
board gives that fifth back (`accessibilityChrome`, 64pt at an accessibility size), because a board
is a grid and 312pt of it is still a board to look at, where a card squeezed by its own labels is
not a card. That is the same rule as the first half of this ADR, applied one level down: the board
yields, the deck does not. With both, the card at the largest text size is **195pt** — more room
than it has at the default size, because the board gave up more than the labels took and the deck
is whatever is left. `DeckFloor` renders that size and holds the card, the names and the margins.

## Consequences

- A phone will not rotate. Everything else in the app was already a portrait screen — a board
  above a deck — and landscape was reachable only by accident of a plist.
- Two tests read pixels: the names' capsule has to keep a margin on both sides of the glass at the
  largest text size, and the card on the shortest phone has to be at least `cardFloor` tall. Words
  cannot witness either — a clipped name reads out, and a hidden deck says nothing about itself.
- `boardSide` now has four callers' worth of meaning in it. A row added to the chrome has one place
  to be paid for (`GameScreen.chrome`), and the test that measures the picture is what will notice
  if the row is added and the budget is not.
- The deck is still exactly as tall as the room it is given, so a sparse card still wears empty
  panel and a full one still cuts a row where the viewport ends. That is the price of a board that
  does not move when the cards change (docs/adr/0024) and it is not paid here.
