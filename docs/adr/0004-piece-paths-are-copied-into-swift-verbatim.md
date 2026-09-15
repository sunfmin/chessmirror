# Piece Paths are copied into Swift verbatim

The Python recogniser rasterises its Templates at import time from `chess.svg.PIECES`,
so Templates cannot drift from the renderer. iOS has no SVG rasteriser and no
python-chess, so that trick does not survive the port. We copy the ~4.5 KB of path data
verbatim into a Swift table and write a small renderer for the SVG subset it uses
(`M L C S H V A Z`, `<circle>`, `evenodd`, stroke attributes, one `matrix()` transform)
onto `CGPath`.

Checked-in PNG or SVG assets were the alternative, rejected because the copy would drift
silently and would not scale up crisply on a board view.

## Consequences

- One table feeds both Templates and the on-screen board, so the port keeps the original
  property — the shapes the recogniser expects are the shapes the app draws.
- The Swift table becomes the canonical artwork (see ADR-0005: the Python side is
  frozen, so there is no upstream left to drift away from it).
- Stroke width and line joins must be honoured, not just fills: the Python Templates are
  rasterised with strokes included, and a fill-only silhouette is measurably thinner.
- Rendering and matching share one artwork, so a wrong path would satisfy the roundtrip
  test happily. The reference screenshot — drawn in a *different* piece set — is what
  actually holds the renderer honest, which promotes it from "one more test" to the
  load-bearing one.
