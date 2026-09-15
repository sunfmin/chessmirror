# Perspective correction is a pre-stage the checker score judges

The recogniser assumes an axis-aligned board, which rules out photographs. Rather than
generalising the pipeline to arbitrary quadrilaterals, a pre-stage rectifies the image
and hands the existing pipeline exactly what it already expects.

Two rules keep it honest:

1. **Axis-aligned first.** The existing exhaustive search runs on the original pixels; if
   its checker score clears the threshold — every screenshot will — the image is used as
   is. Warping resamples, and a pixel-perfect screenshot has nothing to gain and sharpness
   to lose.
2. **The existing scores pick the winner.** Vision's `DetectRectanglesRequest` /
   `DetectDocumentSegmentationRequest` propose candidate quads; each is rectified with
   `CIPerspectiveCorrection`, run through the exhaustive search, and scored. The board is
   whichever candidate scores highest, so a detector that returned the page, the screen
   bezel or the phone in the photo is voted down rather than believed. A coordinate
   descent on the four corners then pushes the winner's score to its local maximum.

   The descent needs a *sharp* objective, and the accept gate's corner-patch checker score
   is deliberately a robust one: a corner can sit forty pixels out with barely a dent in
   it, which strands the descent. So the descent maximises the product of the pipeline's
   two existing measures — the Cell-mean grid score the axis-aligned search already
   maximises, which is sharply sensitive to a misaligned grid, times the corner-patch
   score, which is what stops a quad that has slid onto the tablecloth from winning on
   texture alone. Neither measure is new, and the final accept/reject gate is unchanged.

## Consequences

- Vision is a *proposal* mechanism, never an authority; the accept/reject gate stays the
  same measure the original algorithm used, which is what makes the extension safe.
- A quad is rejected before it is scored if its corners have folded over each other, left
  the picture, or closed to less than eight squares' width. Without that, the descent can
  score a degenerate quad highly and walk into it.
- Photographs of physical boards remain out of scope: rectification fixes perspective,
  not three-dimensional pieces, their shadows, or the fact that a 3D knight's outline is
  not the 2D Template's.
- On-device only — Vision ships with the OS, so "fully local" survives.
- Cost is bounded: the exhaustive search runs once per candidate quad, and candidates are
  few.
