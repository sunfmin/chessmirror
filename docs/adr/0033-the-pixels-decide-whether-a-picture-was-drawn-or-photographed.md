# The pixels decide whether a picture was drawn or photographed

The main way a position gets into this app is a **screenshot** of a lichess review, taken on
the same phone the app runs on and handed over from the album or the share sheet. Holding the
phone up to a real board is the rarer case now, and photographing a printed diagram rarer
still. The pipeline was built for the rare case first (docs/adr/0007, docs/adr/0013) and gave
every picture the same preparation.

A screenshot and a photograph are not the same picture with different noise. A screenshot is
square on, so there is no perspective to correct; it is drawn rather than lit, so there is no
lamp, no shadow and no shine to normalise away; and its squares are flat single values, so the
pieces sit on exactly the background the classifier expects. Every stage built for the
photograph is, on a screenshot, either wasted time or a way to be wrong.

**The picture says which it is.** Not the door it came through — the album holds both kinds,
and a share sheet says nothing about either — and not a flag the screen sets, which would be a
question the person has to answer about their own screenshot. `BoardGeometry.checkerScore` is
already computed on the found rectangle, before a single Cell is judged, and it measures
exactly the thing that differs: how cleanly the board's two square colours separate. Drawn
boards score 63 and up. Photographs score 23 and down — including a photograph of a printed
book diagram, which is the hardest case on that side. The line goes at 40, between them rather
than at either edge.

Two consequences follow from one number:

1. **No rectification.** A screenshot returns from the axis-aligned read by name, without the
   search over quads. Rule 1 of 0007 said this already, as a threshold that "every screenshot
   will" clear; it is said as a fact about the picture now, which is both stricter and
   legible in the result.
2. **No light to follow.** `BoardLighting` normally takes a median of the light squares
   *beside* each Cell, so that a gradient across a photograph is followed rather than averaged
   away. A drawn board has one light value everywhere, so the whole grid gets that one value.

## Consequences

- Provenance is on the `Recognition`, so a reading can say which preparation it was given —
  which is what makes it testable, and what a diagnostic can print.
- Rule 2 is not merely cheaper, it is steadier. The local median is the thing a highlighted
  square, a move arrow or a check ring can pull off, and those are drawn on lichess boards
  constantly. One global level cannot be pulled off by anything drawn on sixty-four squares.
- A screenshot *of* a photograph is read as a photograph, and a photograph of a screen is read
  as a photograph. Both are right: it is the pixels that have to be read, not the file's
  history.
- A drawn board this misjudges pays a slower read, not a worse one — the quad search still has
  to beat the axis-aligned score to be used. The cost of the line being in the wrong place is
  bounded on both sides, which is why it can sit in a gap rather than be tuned.
- Nothing about the photograph path changed. The fixtures that pin it — a board on a table, a
  printed diagram, a JPEG at 30%, a rescale to a quarter — read the same FENs as before.
