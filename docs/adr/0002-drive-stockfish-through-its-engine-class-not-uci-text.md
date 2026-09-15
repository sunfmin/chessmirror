# Drive Stockfish through its Engine class, not UCI text

iOS forbids `fork`/`exec`, so Stockfish must be linked into the app process rather than
spoken to over pipes. Of the two in-process options we picked the typed one: a thin C++
bridge holds a `Stockfish::Engine` and turns its `on_update_full` / `on_bestmove`
callbacks into a Swift `AsyncStream`. The alternative — running `UCIEngine::loop()` on a
thread with `std::cin`/`std::cout` rdbufs swapped — needs a text parser and its tests to
recover the very structs (`InfoFull`) the callbacks already hand us.

## Consequences

- The bridge is coupled to Stockfish's internal API, not to the stable UCI contract, so
  a Stockfish upgrade may require bridge changes. Mitigated by vendoring a pinned
  version rather than tracking master.
- `Bitboards::init()` and `Position::init()` must run once before any Engine exists.
- Engine callbacks fire on search threads; the bridge is responsible for getting values
  onto the Swift concurrency domain.
- The NNUE networks ship as bundle resources (compiled with `NNUE_EMBEDDING_OFF`), which
  avoids making incbin's assembly embedding work under Xcode. "Fully local" is about the
  networks never being fetched, not about them living inside the executable.
- The pinned version is the `sf_18` release, and pinning to a release rather than master
  has a price worth writing down: sf_18 wants **two** networks
  (`nn-c288c895ea92.nnue`, 69.4 MiB, and `nn-37f18f62d772.nnue`, 2.7 MiB) set through the
  `EvalFile`/`EvalFileSmall` options followed by `load_networks()`, where master has one
  network and a `load_network(path)`. Master also validates FENs where sf_18 does not
  (see ADR-0008). The release's reproducibility is still worth those differences.
- Constructing an `Engine` loads the networks immediately and exits the process if they
  are missing, so anything that does not need evaluation — validation, legal moves,
  perft — is built on `Position` directly and stays testable without the 72 MiB of
  weights.
