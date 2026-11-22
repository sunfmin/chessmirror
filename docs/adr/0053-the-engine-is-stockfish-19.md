# The engine is Stockfish 19

The vendored engine is the `sf_19` release (2026-09-05), in place of `sf_18`. chessmirror#4's
profile put sf_18's accumulator updates (FullThreats and HalfKAv2_hm) at 40% of a search thread's
time, and chessmirror#13 found no build flag that moves them. sf_19 changes exactly that part: its
SFNNv16 network drops redundant threat features and retires the second, small network, and the
release notes measure it up to +44 Elo over sf_18. This supersedes what 0002, 0008, 0011 and 0052
said about sf_18; each now says sf_19 and points here.

## Vendored as before

`Sources/CStockfish/stockfish/` is the tag's `src/` with `main.cpp` and the `Makefile` removed and
everything else verbatim (VENDORED.txt has the commit). sf_19's `universal/` directory comes with
it and is excluded from both targets in Package.swift: it is the Makefile's runtime CPU dispatch,
which this package does its own way (below).

## One network, named by Stockfish

sf_19 wants one network, `nn-1a298aa575a0.nnue` (94 MiB, in Git LFS as the old two were), set
through `EvalFile`; `EvalFileSmall` is gone. The bridge takes one path. The file's name is not
written anywhere in this repository but the vendored `evaluate.h`: `cf_engine_net_name()` returns
its `EvalFileDefaultName`, and the app's bundle lookup, the tests and `chessmirror-cli` all ask
`EngineService.netFileName`. The next upgrade changes the file and nothing that looks for it.

## sf_19 validates, by ending the process

sf_18's `Position::set` validated nothing, which is why the bridge has its own validator (0008).
sf_19's validates FENs, positions and UCI commands and, through its UCI loop, answers a refusal
with `info string CRITICAL ERROR` and `exit(1)` (`UCIEngine::terminate_on_critical_error`). The
engine is in the app's own process, so one refused input through that loop would close the app.

Two things keep it from happening:

- The bridge never goes through the UCI loop (0002). `Engine::set_position` and `Position::set`
  *return* a `PositionSetError`; the bridge checks every one of them, and a refusal means no
  search and a failed Rules Query, never a half-set position.
- Nothing sf_19 would refuse is handed to it. The validator asks every rule sf_19's
  `Position::set` has, before Stockfish sees the FEN, and names it in the terms the Confirm
  Position screen already explains. sf_19 added three the validator did not have, each mapped
  to an issue that already had words: more promoted pieces than pawns gone (*too many pieces*),
  more than four castling rights (*bad castling*) and a fullmove number past 100000 (*bad
  clock*). And sf_19 reads a FEN a character at a time, so a second space between fields is a
  refused en passant square to it; the bridge hands it every FEN with one space per field.

`cf_stockfish_refuses_fen` asks sf_19's own `Position::set` about a FEN, unvetted — safe now that
it checks before it trusts. The tests hold one FEN per refusal sf_19 can give to it being refused
by sf_19 *and* by the validator first, and hand each to a live engine of both builds, which refuses
it at the bridge, searches nothing, and then searches the next position as if nothing happened.

## The strength range did not move

`UCI_Elo` is 1320...3190 in sf_19 as in sf_18, and the `Skill` mapping from Elo is unchanged.
`Strength.eloRange` now reads it from the vendored `Search::Skill` rather than a copy, so the
ladder cannot offer a rung the engine would silently ignore.

## The name comes from Stockfish too

`EngineService.name` is the vendored `engine_version_info()` — 「Stockfish 19」 — and the engine's
bar, the about screen, the PGN roster and the opponent's search cache all read it. The store's
descriptions cannot read Swift, so a test holds them to it. A game saved under sf_18 keeps the
「Stockfish 18」 it was saved with: `Controller.isEngine` knows the former names, so such a file is
still read as the engine's (its unrung moves at 满力, 0038) and saving it again does not rename
its engine.

## Runtime CPU dispatch stays ours

sf_19's releases are universal binaries that pick the CPU's features at run time, and its
`ARCH=arm64-universal` is the same design as 0052: the tree built twice (armv8, armv8-dotprod),
renamed apart, one picked at start. It cannot replace the two targets here. It renames by
compiling each build to one LTO object and rewriting its init sections with an awk script, a
pipeline SwiftPM and Xcode do not run; and its CPU query (`universal/entry_arm64.cpp`) is
`getauxval(AT_HWCAP)` on Linux and `IsProcessorFeaturePresent` on Windows, with no Darwin branch.
On Darwin the Makefile's `macos-lipo` builds the arm64 slice as dotprod alone — right for every
Apple-silicon Mac, and the A12 crash 0052 exists to avoid on an iPad. A namespace define and
`hw.optional.arm.FEAT_DotProd` already do the same with nothing to run.

## What it buys

Measured on the development Mac (M5 Max) on 2026-11-22 with `scripts/engine-speed.sh -r 5`: the
start position to depth 25 on one thread, the four builds interleaved, at a load average of 16–23
(chessmirror#15 has every run). The script now prints each run's time to the depth, because two
versions search different trees and nodes per second compare nothing between them.

| build   | time to depth 25, fastest / median | nodes     | median nps |
|---------|------------------------------------|-----------|------------|
| sf_18 dotprod | 2647 / 2854 ms               | 3,654,468 | 1280k      |
| sf_19 dotprod | 1870 / 1918 ms (−29% / −33%) | 1,975,369 | 1029k      |
| sf_18 armv8   | 2786 / 2895 ms               | 3,654,468 | 1262k      |
| sf_19 armv8   | 2036 / 2213 ms (−27% / −24%) | 1,975,369 |  892k      |

sf_19 is slower per node, because each evaluation costs more, and needs 46% fewer nodes for the
depth. It reaches the depth about a quarter to a third sooner on both builds, the armv8 one an A12
runs included, and plays stronger there. The fewest core cycles for a whole run fell 27% (dotprod)
and 23% (armv8). The package's tests, which search a great deal, went from 265 s to 186 s in the
gate.

Pinned numbers moved with the network: the start position's depth-10 node count is 8663 (sf_18:
12507). One test's premise did not survive: sf_19 does not call 19. Kxh3 in the phone game a
mistake at any depth from 16 to 26, so that regression now plays 14. Re1, which sf_19 refuses at
every depth from 16 to 24 (chessmirror#15 has both series).
