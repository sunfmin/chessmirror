# Chessmirror / 棋镜

Photograph a chessboard, confirm its position, and play against local Stockfish. Build a mistake
book from your games and practise the positions that need work. Recognition and analysis run
on the device. Online imports require a network connection; games and practice logs can sync
through your own iCloud Drive.

## Features

- Camera, photo library, screenshots, image files, FEN, and shared board intake.
- Confirm and correct pieces, side to move, and castling rights before playing.
- Per-game controllers and engine thinking time. Mate and tactics findings appear only when
  available; tap a row to expand its answer. The board keeps the full screen width.
- **错题本:** one position across many games, with encounter history and manual dismissal.
- **日课:** FSRS due dates derived from practice facts, ARTS daily ordering, and ten new positions
  per day by default. Unscheduled practice does not change due dates.
- **耕棋 / No Slips:** per-game interception at 10%, 20%, or 30% loss of win probability, or off.
  Refused moves return to their original position and become PGN comments on the eventual move.
- Three explicit hint layers, answer reveal, and one-move threshold relaxation. Assisted
  attempts carry a “not found” marker in the mistake book.
- An optional opponent-reply exercise on a temporary board. Replies within two percentage
  points of the best depth-16 evaluation pass; retry, Reveal, and Skip leave the real game intact.
- Import a selected game and score every move locally at depth 16, asynchronously. Imported
  evaluations prioritize suspected mistakes but never exclude moves from the local pass.
  Choose which side to track when opening an imported game; original player names are preserved.
- Simplified Chinese, English, French, Japanese, Korean, German, Spanish, and Portuguese.

## Repository

```text
chessmirror/
├── Package.swift
├── Sources/
│   ├── CStockfish/        # vendored engine and C bridge
│   ├── ChessfenKit/       # recognition, rules, games, practice, persistence
│   └── chessfen-cli/      # macOS command-line entry point
├── Resources/Nets/        # NNUE weights, stored with Git LFS
├── Tests/ChessfenKitTests/
├── App/
│   ├── Chessfen/          # SwiftUI screens
│   ├── project.yml       # XcodeGen project definition
│   └── ScreenTests/      # simulator rendering and assertions
└── docs/adr/              # design decisions
```

## Build and test

Use Apple Silicon, Xcode with Swift 6.2 or newer, and the iOS 26 SDK. The Stockfish configuration
targets ARM and does not support Intel simulator builds. Install XcodeGen and Git LFS:

```bash
brew install xcodegen git-lfs
git lfs install
git lfs pull
```

From the repository root:

```bash
swift build
swift test -c release --no-parallel
swift test --filter EngineTests
cd App
xcodegen generate
xcodebuild -project Chessfen.xcodeproj -scheme Chessfen \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
```

Debug recognition tests run substantially slower than release tests. Engine tests need the two
real NNUE files in `Resources/Nets`, not Git LFS pointers. Edit `App/project.yml` and regenerate
the Xcode project when changing build settings or adding screen tests.
Run the full suite serially: recognition memory checks measure the test process footprint, so
unrelated concurrent tests would be included in their measurements.

## Screen snapshots

From `App/`, with an installed iPhone 17 simulator:

```bash
xcodebuild test -project Chessfen.xcodeproj -scheme Chessfen \
  -destination 'platform=iOS Simulator,name=iPhone 17' ARCHS=arm64
```

Tests write PNGs under `App/out/`; these generated images are not versioned.
`ScreenImage.write` renders real SwiftUI screens, with scripted responses at the engine boundary.
Inspect the images as well as their accessibility assertions.

## Command line

From the repository root:

```bash
swift run chessfen-cli recognise board.png
swift run chessfen-cli recognise board.png --straight
swift run chessfen-cli validate '8/8/8/8/8/8/4K3/7k w - - 0 1'
swift run chessfen-cli perft '8/8/8/8/8/8/4K3/7k w - - 0 1' 3
swift run chessfen-cli analyse '8/8/8/8/8/8/4K3/7k w - - 0 1' 16
```

Replace `board.png` with your image. `CHESSFEN_NETS` overrides the source-tree model path.

## Persistence and design

Games are PGN files, with optional photographs alongside them. The append-only practice log is
separate; schedules and the mistake index are derived. No Slips stores `[%tried SAN -loss%]`,
an optional `notfound` suffix for assisted attempts, and `[%hint N]`. The `Intercept` tag stores
the game's threshold. Import review stores local depth in `ReviewDepth` and ordering provenance
in `ReviewSift`. `TrackedSide` identifies the imported side included in the personal mistake book
without replacing the PGN's `White` and `Black` player names.

- [Confirming positions](docs/adr/0008-a-confirm-position-gate-stands-between-recognition-and-game.md)
- [Engine integration](docs/adr/0002-drive-stockfish-through-its-engine-class-not-uci-text.md)
- [PGN storage](docs/adr/0010-pgn-files-are-the-storage-format.md)
- [Eight-language tables](docs/adr/0019-the-app-speaks-eight-languages-from-tables-in-the-package.md)
- [Win-probability judgement](docs/adr/0027-a-move-is-judged-by-the-win-probability-it-costs.md)
- [Position identity](docs/adr/0028-a-mistake-is-a-position-and-the-games-are-its-occurrences.md)
- [Practice facts](docs/adr/0029-the-practice-log-records-what-happened-never-what-is-due.md)
- [Daily practice](docs/adr/0032-the-daily-is-one-queue-and-cannot-be-sharded.md)

## Licence

GPLv3; see the [licensing decision](docs/adr/0001-relicense-the-repository-under-gplv3.md).
Stockfish is linked into the app and retains its upstream licence notices.
