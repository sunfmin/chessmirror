# Relicense the repository under GPLv3

The iOS app compiles Stockfish from source into its own binary, and Stockfish is
GPLv3 — linking it makes the whole app a derivative work, so the repository (Python
CLI included) becomes GPLv3 and gains a `LICENSE` file. The alternative was a weaker
self-written Swift engine to stay licence-free, rejected because engine strength is the
point of the feature.

## Consequences

- Distribution is Xcode-direct-install and TestFlight, not the App Store: GPL's terms
  and Apple's are widely held to conflict (VLC was pulled in 2011 over exactly this).
  Not distributing at all keeps the question academic.
- No proprietary or GPL-incompatible third-party code can enter the repository.
- Because the engine is not meant to be swapped out, no abstraction layer is built to
  keep it swappable.
