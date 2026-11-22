# The engine is built twice, and the CPU chooses

Until now CStockfish was built with the define set the Stockfish Makefile uses for `ARCH=armv8`
and never with `ARCH=apple-silicon`'s, and Package.swift said why: the dotprod instructions that
set adds took the start position from 11.0M to 12.5M nodes per second on the development Mac,
and an A12 does not have them. iPadOS 26 still runs on A12 iPads (the first iPad Pro 11-inch
among them), and there the first NNUE evaluation is an illegal instruction — the app dies the
moment the engine looks at a board. No App Store device requirement can exclude an A12, so the
build stopped asking for the instruction, and every device paid the 14% so that one could run.

That reasoning was right about the A12 and wrong that one build had to serve every device.
Nothing forces one build on every device: the choice can be made on the device, at run time,
by the one thing that knows.

## Two builds of one engine, linked side by side

The vendored tree is compiled twice. `CStockfish` builds it with the armv8 set, as before.
`CStockfishDotprod` builds the same files — its `stockfish/` and `engine/` are symlinks into
CStockfish, so there is one copy of the sources and nothing to keep in step — with what
`ARCH=apple-silicon` adds: `USE_NEON_DOTPROD` and `-march=armv8.2-a+dotprod`.

Two copies of Stockfish in one binary would collide symbol for symbol. They don't, because every
symbol Stockfish defines is inside `namespace Stockfish`, and the dotprod target defines
`Stockfish=StockfishDotprod`: the preprocessor moves the whole second copy into a namespace of its
own. That is a define, not an edit — the vendored tree stays verbatim (sf_19 now, ADR-0053), as
VENDORED.txt says.

Only the engine is worth the second copy. The bridge's rules queries — FEN vetting, legal moves,
control, exchanges, perft — run on the armv8 build's tables wherever they run; a dot product is no
help to them. The engine half of the bridge (`engine/engine_build.cpp`) is compiled into both
targets and answers a table of functions; `cf_engine_create` takes the build it is to start on and
holds that build's table for the engine's whole life.

## The CPU chooses, once

`EngineService` asks the kernel — `sysctl hw.optional.arm.FEAT_DotProd` — when it starts the
engine, and starts the dotprod build where the answer is 1 and the armv8 build everywhere else,
including where the key is unknown: armv8 runs on anything. The answer is a value
(`CPUFeatures`), so a test can be a CPU without dotprod and see the armv8 engine started; the
engine reports back the build it was created on, so the test reads what happened rather than what
was asked. The device's name is never consulted. A list of models goes stale; the CPU's own
answer cannot.

The two builds walk the same tree: one thread to a fixed depth searches the same number of nodes
in both, which a test holds. Dotprod changes how the NNUE layers multiply, not what they answer.

sf_19 ships the same design in its own Makefile (`ARCH=arm64-universal`: the tree built as armv8
and as armv8-dotprod, renamed apart, picked at start from the CPU) and it does not replace this
one: it renames with an LTO-object and awk pass that SwiftPM cannot run, and its CPU query is
`getauxval` or `IsProcessorFeaturePresent`, Linux and Windows only — on Darwin sf_19 builds the
dotprod slice alone (`macos-lipo`). A define and a sysctl do the same here with nothing to run (ADR-0053).

## What it buys: about 2.5%, not 14%

Measured on the development Mac on 2026-11-21 (chessmirror#4 has the runs): from the start
position to depth 25 on one thread, 1280k nodes per second before and 1313k after, +2.6%; +2.4%
on eight threads. The 14% did not reproduce. The reason is where sf_18 spends its time. Dotprod
speeds up only the small affine layers after the feature transformer, and a profile of the armv8
build puts those at about a tenth of the search. The accumulator updates that dominate are int16
NEON in both builds. The gain is small, but it is free: same engine, same tree, about 640 KB more
binary (the CLI went from 4.73 MB to 5.38 MB), and nothing to decide again.

## A check, so a build setting cannot bring it back

The armv8 build containing a dot-product instruction is the A12 crash again, and it would arrive
silently: a later flag, a compiler that starts emitting `sdot` from a plain loop, or the linker
picking a shared libc++ function from the dotprod objects. So `scripts/dotprod-confined.sh`
disassembles the *linked* binary and fails if any function using `sdot` or `udot` is outside
`StockfishDotprod::` — and also if none uses them at all, so a check that finds nothing because
nothing was built with dotprod does not pass. The gate runs it on the test binary; `deploy.sh`
and `appstore.sh` run it on the app binary going to the device.

## Not changed

The two search threads and the hash size in `EngineService.Configuration` stay as they are. Those
are a battery and heat decision, not this one: a faster build reaches a depth sooner on the same
two cores.
