/*
  The engine half of the bridge, as each Stockfish build exposes it.

  engine_build.cpp beside this header is compiled twice: once in CStockfish, as the armv8 build, and
  once in CStockfishDotprod, whose `Stockfish` define renames the whole namespace to
  `StockfishDotprod` so the two copies of the engine can live in one binary (docs/adr/0052).
  The declaration below is renamed with it, so each build answers its own table.

  Not public: the dispatcher in bridge.cpp is the only caller. It has already vetted the
  position and probed the nets by the time anything here runs.
*/

#ifndef CHESSMIRROR_ENGINE_BUILD_H
#define CHESSMIRROR_ENGINE_BUILD_H

#include <string>
#include <vector>

#include "chessmirror_bridge.h"

struct CfEngineBuildOps {
    /* Null when the engine could not be allocated. */
    void *(*create)(const char *bigNetPath, const char *smallNetPath);
    void (*destroy)(void *instance);
    bool (*setOption)(void *instance, const char *name, const char *value);
    void (*go)(void                           *instance,
               const char                     *startFen,
               const std::vector<std::string> &moves,
               const CfSearchLimits           *limits,
               void                           *context,
               CfInfoCallback                  onInfo,
               CfBestMoveCallback              onBestMove);
    void (*stop)(void *instance);
    void (*wait)(void *instance);
    void (*clear)(void *instance);
};

namespace Stockfish {
void chessmirrorInitialiseTables();
const CfEngineBuildOps &chessmirrorEngineBuild();
}

#endif /* CHESSMIRROR_ENGINE_BUILD_H */
