# The Swift code is a multiplatform package with a thin app shell

Everything but the screens — recogniser, piece rendering, the Stockfish sources, the
bridge, the Game model — lives in a SwiftPM package under `ios/` that builds for macOS
as well as iOS. The Xcode project holds only SwiftUI views and the NNUE resource.

## Consequences

- `swift test` runs the whole non-UI suite on the Mac in seconds with no simulator, which
  is the difference between iterating on the algorithm and waiting on it.
- Nothing in the package may import UIKit; anything platform-specific goes behind
  `#if canImport(UIKit)` or stays in the app.
- A `chessfen-cli` executable target comes almost free from the same package and gives
  the Python CLI's ergonomics back on the desktop — batch a folder of images, print
  FENs, compare against the frozen Python output when a doubt arises.
- The Stockfish sources are vendored (pinned, not a submodule) as a C++ target, with
  `src/incbin/incbin.h` included even though embedding is off: Stockfish includes that
  header unconditionally.
