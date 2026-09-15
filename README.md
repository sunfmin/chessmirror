# Chessfen for iOS

Point the camera at a chessboard, get the position, and play on from it against Stockfish —
entirely on the phone. No account, no network, no upload: recognition is arithmetic on pixels
and the engine is linked into the app, so the whole thing works on a plane.

This is the Swift rewrite of the Python recogniser in the repository root, and it is now
[the only living implementation](../docs/adr/0005-swift-becomes-the-only-living-implementation.md).

## Layout

```
ios/
├── Package.swift          # one package, three targets
├── Sources/
│   ├── CStockfish/        # Stockfish 18, vendored, plus a C ABI bridge
│   ├── ChessfenKit/       # recognition, rules, engine, game, PGN — all the thinking
│   └── chessfen-cli/      # a macOS entry point to the same code
├── Resources/Nets/        # the two NNUE files (Git LFS)
├── Tests/                 # 290 tests
└── App/                   # the SwiftUI shell: screens and nothing else
    ├── project.yml        # the Xcode project is generated from this
    └── ScreenTests/       # the screens, drawn into PNGs and held to what they say
```

The split is the point: everything that decides anything lives in `ChessfenKit`, which has no
UIKit and no SwiftUI in it and is testable from a terminal. `App/` is screens.

## Prerequisites

```bash
brew install xcodegen git-lfs && git lfs install
```

Xcode 26 or newer (the app targets iOS 26 and uses Swift 6 approachable concurrency), and a
clone that actually fetched LFS — `ls -l Resources/Nets` should show two files of 108 MB and
4 MB, not two one-line pointers.

## The package, from a terminal

```bash
cd ios
swift build
swift test -c release                        # ~4 seconds of tests after ~15s of compiling
swift test                                   # the same tests, ~5 minutes: recognition is
                                             # arithmetic, and -O0 arithmetic is 80x slower
swift test -c release --filter EngineTests    # just the engine
```

`chessfen-cli` is the same code with a shell around it, which is how a doubt gets settled
without opening a simulator:

```bash
swift run chessfen-cli recognise board.png    # FEN, orientation, shaky squares
swift run chessfen-cli recognise board.png --straight   # no perspective correction
swift run chessfen-cli validate "<fen>"       # is this a position at all
swift run chessfen-cli perft "<fen>" 5        # count the moves; compare with anyone
swift run chessfen-cli control "<fen>" [d5]     # who attacks and defends every square
swift run chessfen-cli exchange "<fen>" e4d5  # what that move is worth in material
swift run chessfen-cli analyse "<fen>" 24     # Stockfish, three lines, to depth 24
swift run chessfen-cli icon out.png 1024      # redraw the app icon
```

`analyse` and the engine tests need the nets. They are found relative to the source tree;
`CHESSFEN_NETS=/somewhere` overrides that.

## The app

```bash
cd ios/App
xcodegen generate            # writes Chessfen.xcodeproj — do this after a fresh clone
open Chessfen.xcodeproj
```

The `.xcodeproj` is not in the repository: a pbxproj is a merge conflict waiting to happen and
says nothing a reader wants to read. `project.yml` says the same thing in fifty lines, so it is
the file to edit — signing, the deployment target and the Info.plist strings all live there.

To put a build on a device without Xcode's UI:

```bash
xcrun devicectl list devices
xcodebuild -project Chessfen.xcodeproj -scheme Chessfen -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath /tmp/dd build
xcrun devicectl device install app --device <udid> \
    /tmp/dd/Build/Products/Release-iphoneos/Chessfen.app
xcrun devicectl device process launch --device <udid> --terminate-existing com.sunfmin.chessfen
```

## The screens, photographed

```bash
cd ios/App
xcodebuild test -project Chessfen.xcodeproj -scheme Chessfen \
    -destination 'platform=iOS Simulator,name=iPhone 17'
open out/game-in-play.png
```

A picture per state lands in `ios/App/out`: a game under way, a board straight off a photograph, one
filed into a collection, a reopened game, the engine on its own clock, an engine that has run
its Stint out, the app playing itself, a Variation offered where it branches, a mate, practice,
老毛病, the import sheet, one square named as this move's 要害 with the sentence that says why, an
outpost drawn as a route from the piece that would come to it, a square taken and still not stood
on, the three steps of the scanner — the ways into a square somebody pointed at, the move they
tried weighed in their own terms, and the engine's answer once they asked for it — a line halfway
through being walked with the layer following it, and the whole screen at night. One of them —
`game-study-french.png` — is the same question asked in French, which is how a run finds out that
all eight languages reached the app rather than only the one it was written in (docs/adr/0020).
`DeckGalleryTests` photographs the five cards of the deck one at a time as well
(`deck-01-key` … `deck-05-drill`), which is what anybody redesigning them has to be able to lay out
on a table — including 五步 with 五步计划 under it, the same card drafting and then judged.
`DeckFloorTests` and `EvalBarTests` photograph the sizes and the text sizes the rest of the suite
cannot reach — a 375-wide phone, the largest accessibility text, and the board both ways up —
because those are the states whose failures are silent: a deck with no room and a bar whose ends do
not turn with the board both read out to the accessibility tree exactly like the correct ones. They
are not in the repository — they are written to be looked at, and they are rewritten by every run.

The only thing faked is the search. `Engine` is a protocol the app's `EngineService` conforms
to, so a test can hand a screen a scripted `Analysis` and everything above the search — the
retune, the Score written against the Ply, every view — is the app's own code. `ScreenImage.write`
is the only glue: it puts the view in a real window on the simulator's scene, waits for it to
settle, writes the PNG, and hands back everything the screen said. A new screenshot is a new
subject passed to it, not new plumbing.

The words come from the accessibility tree, which is also the point: a screen that says nothing
to that tree says nothing to VoiceOver either. SwiftUI only builds it when something is
listening, so the helper switches automation on through `libAccessibility` — a test-only lever,
and the reason `#expect(rendered.says("+0.38"))` can be written at all.

## How the app hangs together

**拍棋盘 is our own camera**
([ADR 0013](../docs/adr/0013-the-camera-is-ours-and-the-viewfinder-judges-with-the-same-score.md)).
It opens on the ultra-wide so a board twenty centimetres away is in focus rather than being
hunted for, focus can be aimed by tapping, and the shutter is manual — nothing is ever captured
automatically. A box is drawn live around the board it can see, found by the same two measures
the recogniser uses, so "it can see the board" is the app's own opinion and not a second one.
VisionKit's document scanner does all of this and none of it can be configured: it was built,
tried and taken back out, which is what the ADR is about.

**Recognition never becomes a game on its own.** Every reading goes through the Confirm
Position gate ([ADR 0008](../docs/adr/0008-a-confirm-position-gate-stands-between-recognition-and-game.md)):
the squares it was unsure about are ringed in orange, every square can be corrected by hand,
and the fields no picture could have settled — whose move it is, castling rights, which way up
the board is — are asked rather than assumed. A wrong piece is not a wrong pixel; it is a
different game, discovered ten moves later.

**One engine, thinking in ten-second Stints.** There is a single Stockfish instance behind a
serial queue, and a new search supersedes the one before it. While it is the player's move the
search deepens and what it recommends keeps changing — that is the honest display of what an
engine is doing, not a bug
([ADR 0009](../docs/adr/0009-one-engine-unbounded-analysis-mirrored-opponent-time.md)) — and
after ten seconds it stops, because a phone left on a table is not a reason to keep eight cores
busy ([ADR 0020](../docs/adr/0020-advice-runs-in-ten-second-stints-and-the-strip-says-so.md)).
The strip under the board says how deep it got and offers 再算 10 秒 for the positions where
another ply is worth having. When
the engine is playing, it takes about as long as the player just took, and 马上走 cuts that
short without changing which move it picks. Put both sides on the engine and it plays itself,
three seconds a move — there is no player's clock to mirror then, so the clock is named, and
每步 changes it mid-game for either kind of opponent. Time is the only dial: no skill level,
no Elo.

**It speaks eight languages, out of the package rather than the app**
([ADR 0019](../docs/adr/0019-the-app-speaks-eight-languages-from-tables-in-the-package.md)).
Chinese, English, French, Japanese, Korean, German, Spanish and Portuguese, one
`Sources/ChessfenKit/Resources/<lang>.lproj/Localizable.strings` each — with the words beside
the domain because most of them *are* the domain: 漏着, 说不清, "王旁边有王" are `MoveQuality`,
`Intent` and `FENIssue` values, and each of those types owns its own `.label`. Chinese is the
language it was written in and the one every key falls back to. The person can pick one in 关于
regardless of what the phone is set to, and `LocalizationTests` fails the build if a key is
missing from a table or carries different `%@`s than the Chinese it translates.

**Games are PGN files.** One per game, in Documents, with the photograph a recognised game came
from kept beside it ([ADR 0010](../docs/adr/0010-pgn-files-are-the-storage-format.md)). There is
no database and no migration story: anything that reads PGN reads everything this app has ever
saved, and branches, evaluations and where the position came from all ride along in notation
PGN already had. A game nobody has moved in yet is not written at all.

**Stockfish is driven through its `Engine` class, not through UCI text**
([ADR 0002](../docs/adr/0002-drive-stockfish-through-its-engine-class-not-uci-text.md)), because
iOS forbids `fork`/`exec` — there is no subprocess to pipe commands to, so the engine is linked
in and called. The same C++ answers the rules questions
([ADR 0003](../docs/adr/0003-borrow-stockfish-for-rules-queries-behind-a-stateless-bridge.md)):
a second move generator would be a second opinion about the rules of chess, and Stockfish's is
the one already being trusted with everything else.

## Licence

GPLv3, for the whole repository
([ADR 0001](../docs/adr/0001-relicense-the-repository-under-gplv3.md)). Stockfish is GPLv3 and
this links against it, so the licence is not a choice — which also means this app is not going
to the App Store, whose terms and the GPL do not agree.
