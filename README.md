# Chessmirror / 棋镜

Photograph a chessboard, confirm its position, and play against local Stockfish. Build a mistake
book from your games and practise the positions that need work. Recognition and analysis run
on the device. Online imports require a network connection; games and practice logs can sync
through your own iCloud Drive.

## Features

- Camera, photo library, screenshots, image files, FEN, and shared board intake.
- Confirm and correct pieces, side to move, and castling rights before playing.
- Per-game controllers and engine 棋力. Mate and tactics findings appear only when
  available; tap a row to expand its answer. The board keeps the full screen width.
- **错题本:** one position across many games, with encounter history and manual dismissal. A game
  contributes both the moves it recorded and the refusals 耕棋 took back — including the ones no
  move ever absorbed, which is how a session that ends on a refused move gets written down. Rows
  are named by a 96pt board, and an encounter opens the game at its position.
- **日课:** FSRS due dates derived from practice facts, ARTS daily ordering, and ten new positions
  per day by default. Unscheduled practice does not change due dates.
- Practice uses the game screen's full-width board, side settings, advantage bar, history and
  explicit multi-move findings. The first move is judged at depth 20 and logged once; play on in
  the same game, exit, or take the next question, without a separate Continue button. The verdict
  is one row: 过了 or 没过 in the colour it means, the explanation only when the move failed, and
  one full-width button — 下一题, or 退出 at the end of the queue.
- The two standing lines, 记录线 and 入列线, both default to 10%. Either moves on its own in
  关于 → 判决线.
- **把关 / No Slips:** an on/off switch with no number of its own — it stops the player at the
  记录线, so a move it refuses is exactly a move that would have been written down.
  The board's No Slips label toggles interception directly.
  Feedback remains visible while off; answers are explicit multi-move reveals, never a single
  recommendation arrow or a separate practice/analysis eye switch.
  Refused moves return to their original position and become PGN comments on the eventual move.
  Every live human move waits for the resulting position's evaluation before the opponent starts.
  Each position is searched once, stopping at 10 seconds or depth 20, whichever comes first.
  Judgement, advantage, tactics and opponent replies share the result; device caches survive relaunch.
  Turning interception off disables rollback, not this assessment gate. Search uses at most two
  threads by default, and opening the game never launches an automatic historical scoring pass.
- A game lists its own 错题 — one entry per position, described by a small board with the move
  number and the cost captioned under it, marked across the foot of that position on the record
  strip in two weights (written down, and still owed), and reached by pressing the tile — the board
  itself included — or by 下一处. Under the positions, the 试招 tried where
  the eye is standing, and then the opponent-reply exercise when it is on: one full-width row, the
  record row's twin, and nothing rounded. The library row says how many a game holds.
- The advantage bar remains visible. Refused attempts appear as a compact horizontal strip
  for the current move, with SAN and percentage cost, instead of a whole-game cost list.
  Pressing one shows the 应招 it earned — the opponent's answer and the few moves after it, as
  numbered chips and numbered arrows on the board. The line was kept by the search that refused
  the move; older files are answered from the shared bounded position search.
  Judgements preserve their achieved depth in PGN. The history curve still includes the last move.
- A face-to-face toolbar toggle rotates the top player's pieces for over-the-board play on a phone.
- An optional opponent-reply exercise on a temporary board, asked for inside the game's 错题 row. Replies within two percentage
  points of the shared bounded evaluation pass; retry, Reveal, and Skip leave the real game intact.
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
│   ├── ChessmirrorKit/       # recognition, rules, games, practice, persistence
│   └── chessmirror-cli/      # macOS command-line entry point
├── Resources/Nets/        # NNUE weights, stored with Git LFS
├── Tests/ChessmirrorKitTests/
├── App/
│   ├── Chessmirror/          # SwiftUI screens
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
xcodebuild -project Chessmirror.xcodeproj -scheme Chessmirror \
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
xcodebuild test -project Chessmirror.xcodeproj -scheme Chessmirror \
  -destination 'platform=iOS Simulator,name=iPhone 17' ARCHS=arm64
```

Tests write PNGs under `App/out/`; these generated images are not versioned.
`ScreenImage.write` renders real SwiftUI screens, with scripted responses at the engine boundary.
Inspect the images as well as their accessibility assertions.

## Command line

From the repository root:

```bash
swift run chessmirror-cli recognise board.png
swift run chessmirror-cli recognise board.png --straight
swift run chessmirror-cli validate '8/8/8/8/8/8/4K3/7k w - - 0 1'
swift run chessmirror-cli perft '8/8/8/8/8/8/4K3/7k w - - 0 1' 3
swift run chessmirror-cli analyse '8/8/8/8/8/8/4K3/7k w - - 0 1' 16
```

Replace `board.png` with your image. `CHESSMIRROR_NETS` overrides the source-tree model path.

## Persistence and design

Games are PGN files, with optional photographs alongside them. The append-only practice log is
separate; schedules and the mistake index are derived. No Slips stores `[%tried SAN -loss%]`, an
optional `notfound` suffix for assisted attempts, the 应招 after a bar (`[%tried Nf3 -23% | Nxe4
Nxe4 d5]`), and `[%hint N]`. A refusal nothing has absorbed yet — the player left before finding a
move — is written under `[%pending <plies> …]`, carrying the position it happened at and moving
onto the move that takes it when one is played. The `Intercept` tag says
No Slips was on, and the 记录线 it was stopping the player at. Import review stores local depth in `ReviewDepth` and ordering provenance
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
- [A refused move's reply](docs/adr/0034-a-refused-move-keeps-the-reply-it-earned.md)
- [A game's own wrong moves](docs/adr/0036-a-game-lists-its-own-wrong-moves.md)
- [A refusal nothing absorbed](docs/adr/0037-a-refusal-nothing-absorbed-is-written-where-it-happened.md)

## Licence

GPLv3; see the [licensing decision](docs/adr/0001-relicense-the-repository-under-gplv3.md).
Stockfish is linked into the app and retains its upstream licence notices.
