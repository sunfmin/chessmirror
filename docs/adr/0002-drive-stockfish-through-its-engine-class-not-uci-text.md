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
- The pinned version is the `sf_19` release (ADR-0053; it was `sf_18` until chessmirror#15).
  Pinning to a release rather than master is worth its lag: an upgrade is one ticket that
  re-measures and re-pins, not a drift. sf_19 wants **one** network
  (`nn-1a298aa575a0.nnue`, 94 MiB), set through the `EvalFile` option; sf_18 wanted two,
  through `EvalFile` and `EvalFileSmall`. The file's name is Stockfish's own
  `EvalFileDefaultName`, which the bridge hands to Swift (`EngineService.netFileName`), so the
  bundle, the tests and the CLI cannot look for a different file than the engine was built for.
- Constructing an `Engine` loads the network immediately and exits the process if it
  is missing, so anything that does not need evaluation — validation, legal moves,
  perft — is built on `Position` directly and stays testable without the 94 MiB of
  weights.
- Driving the class rather than the UCI loop matters more under sf_19: its loop answers a
  refused FEN, position or move with `info string CRITICAL ERROR` and `exit(1)`, where
  `Engine::set_position` returns the refusal. The bridge never goes through the loop, and
  never hands the class anything it would refuse (ADR-0053).
