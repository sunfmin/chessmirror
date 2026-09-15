# The camera is ours, and the viewfinder judges with the same score

拍棋盘 opens a camera built here on AVFoundation, not `UIImagePickerController` and not
VisionKit's document scanner. It opens on the ultra-wide lens, autofocus is configured for a
subject close by and can be aimed by tapping, the shutter fires only when a thumb presses it,
and a box is drawn live around the board it can see. Nothing about how a photograph is *read*
changes: the picture that comes out goes into the same pipeline as one picked from the album.

The system document scanner, `VNDocumentCameraViewController`, was the obvious thing to reach
for — a board on a table is exactly the quadrilateral it is built to find, it tracks it live,
and it hands back the contents already straightened, with a corner-dragging screen for when it
guesses wrong. It was built and then taken out again. Its entire API is a delegate and an
`isSupported` flag: there is no way to say which lens to open on, no way to touch focus, and no
way to stop it firing the shutter by itself. Those are the three things a chessboard needs and a
sheet of A4 does not. A board is small and gets looked at from twenty centimetres, which is
inside the wide lens's minimum focus distance; the lens then hunts, and an automatic shutter
waits for a steadiness that a hunting lens never reaches. The scanner's own strengths — the
straightening, the crop — are things this app already does for itself and judges for itself
(docs/adr/0007), so what was left to borrow was the part that could not be configured.

The live box is the scanner's one genuinely new idea, kept and re-implemented: candidates from
Vision, then the pipeline's own two measures, ranked by their product and accepted on the
checker score, which is the same accept gate the recogniser uses and is a contrast ratio rather
than a pixel count, so it means the same thing at viewfinder resolution as at reading
resolution. The coordinate descent is left out — it costs seconds and buys corner accuracy that
a box on a moving preview cannot show.

## Consequences

- Everything the camera can be told, it is told here rather than by a system UI, which is the
  whole point and also the whole cost: the permission dance, session lifetime, rotation and
  capture are ours to get right, where the scanner had them already.
- 微距 is the default, and the toggle beside the shutter offers 标准 for a whole board seen from
  across a table. Both are the same physical device — the phone's virtual back camera — asked
  for a different zoom factor, which is what "macro mode" is on an iPhone; the phone stays free
  to fall back between its own lenses when focus demands it.
- On a phone whose back camera is a single wide lens there is no 微距 to give, and the toggle is
  not shown rather than shown and lying.
- The box is guidance, not a decision. What it draws has had no descent run on it, and the
  photograph is searched from scratch at full size afterwards — so a frame where the box never
  appeared can still be photographed and still be read, and a box that sat slightly off the
  board costs nothing.
- Looking at frames costs a rectification per candidate, which is why the frame is dropped to
  384 pixels and the quads scored at 128, and why a frame arriving while the last one is still
  being looked at is discarded rather than queued. The answer comes a couple of times a second;
  the layer eases between answers so the box does not snap.
- Nothing is auto-captured, ever. A photograph is taken because someone took it.
- The Simulator has no back camera, so 拍棋盘 opens on a sentence saying so. The album, the
  clipboard and the file importer are how a screen there gets a board.
