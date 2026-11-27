# Chessmirror / 棋镜

Photograph a chessboard, confirm its position, and play against local Stockfish. Build a mistake
book from your games and practise the positions that need work. Recognition and analysis run
on the device. Online imports require a network connection; games and practice logs can sync
through your own iCloud Drive.

## Features

- Board intake from the camera, photos, screenshots, files, FEN and the share sheet; confirm the
  position before playing.
- Play against Stockfish with per-game controllers and strength; **把关 / No Slips** takes back a
  move that crosses the 记录线.
- **错题本:** each wrong position once, across every game it occurred in.
- **日课:** daily practice of those positions, scheduled by FSRS.
- Import games from the web and review every move on the device.
- Eight languages.

What each does and why is in [docs/adr/](docs/adr/); the words are in [GLOSSARY.md](GLOSSARY.md).

## Repository

```text
chessmirror/
├── Package.swift
├── Sources/
│   ├── CStockfish/        # vendored engine and C bridge
│   ├── ChessmirrorKit/    # recognition, rules, games, practice, persistence
│   └── chessmirror-cli/   # macOS command-line entry point
├── Resources/Nets/        # NNUE weights, stored with Git LFS
├── Tests/ChessmirrorKitTests/
├── App/
│   ├── Chessmirror/       # SwiftUI screens
│   ├── project.yml        # XcodeGen project definition
│   └── ScreenTests/       # simulator rendering and assertions
└── docs/adr/              # design decisions
```

## Build and test

Use Apple Silicon, Xcode with Swift 6.2 or newer, and the iOS 26 SDK. Install XcodeGen and
Git LFS:

```bash
brew install xcodegen git-lfs
git lfs install
git lfs pull
```

From the repository root:

```bash
swift build
scripts/test.sh
swift test --filter EngineTests
cd App
xcodegen generate
xcodebuild -project Chessmirror.xcodeproj -scheme Chessmirror \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
```

`scripts/test.sh` runs the suite as the gate does; its header says how.

## Screen snapshots

The screen tests render the real SwiftUI screens on a simulator of the run's own and write PNGs
under `App/out/`, to look at as well as assert on. From the repository root:

```bash
scripts/screen-tests.sh
scripts/screen-tests.sh -only-testing:ScreenTests/GameScreenTests
```

## Command line

```bash
swift run chessmirror-cli recognise board.png
swift run chessmirror-cli validate '8/8/8/8/8/8/4K3/7k w - - 0 1'
swift run chessmirror-cli analyse '8/8/8/8/8/8/4K3/7k w - - 0 1' 16
```

`scripts/engine-speed.sh` compares two engine builds; its header has the recipe.

## Design

- [Confirming positions](docs/adr/0008-a-confirm-position-gate-stands-between-recognition-and-game.md)
- [Engine integration](docs/adr/0002-drive-stockfish-through-its-engine-class-not-uci-text.md)
- [PGN storage](docs/adr/0010-pgn-files-are-the-storage-format.md)
- [Win-probability judgement](docs/adr/0027-a-move-is-judged-by-the-win-probability-it-costs.md)
- [Position identity](docs/adr/0028-a-mistake-is-a-position-and-the-games-are-its-occurrences.md)
- [Practice facts](docs/adr/0029-the-practice-log-records-what-happened-never-what-is-due.md)

## Licence

GPLv3; see the [licensing decision](docs/adr/0001-relicense-the-repository-under-gplv3.md).
Stockfish is linked into the app and retains its upstream licence notices.
