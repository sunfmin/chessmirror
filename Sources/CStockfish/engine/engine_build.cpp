// One Stockfish Engine behind the bridge's callbacks. Compiled once per build; see
// engine_build.h for why, and bridge.cpp for the C functions that call it.

#include "engine_build.h"

#include <cstdio>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

#include "../stockfish/bitboard.h"
#include "../stockfish/engine.h"
#include "../stockfish/misc.h"
#include "../stockfish/position.h"
#include "../stockfish/score.h"
#include "../stockfish/search.h"
#include "../stockfish/ucioption.h"

namespace Stockfish {
namespace {

// std::visit wants one callable with an overload per alternative. Stockfish's own
// uci.cpp keeps this helper in an anonymous namespace, so it is not reachable here.
template<typename... Ts>
struct overload: Ts... {
    using Ts::operator()...;
};
template<typename... Ts>
overload(Ts...) -> overload<Ts...>;

// Stockfish reports scores from the searching side's point of view and in its own
// internal units; format_score is the only thing that knows how to read them, so
// the same visit is done here rather than a second interpretation invented.
void fillScore(const Score& score, CfSearchInfo& out) {
    score.visit(overload{
      [&out](Score::Mate mate) {
          out.isMate    = true;
          out.matePlies = mate.plies;
      },
      [&out](Score::Tablebase tb) {
          // A tablebase hit is a proven result; reporting it as a huge centipawn
          // score is what UCI does, and it keeps one meaning per field.
          constexpr int32_t TB_CP = 20000;
          out.isMate     = false;
          out.centipawns = tb.win ? TB_CP - tb.plies : -TB_CP - tb.plies;
      },
      [&out](Score::InternalUnits units) {
          out.isMate     = false;
          out.centipawns = int32_t(units.value);
      }});
}

struct Instance {
    Engine engine;

    // Held for the duration of one search, read by Stockfish's threads.
    void              *context = nullptr;
    CfInfoCallback     onInfo  = nullptr;
    CfBestMoveCallback onBest  = nullptr;

    Instance() : engine(std::nullopt) {}
};

Instance& of(void* instance) { return *static_cast<Instance*>(instance); }

bool setOption(void* instance, const char* name, const char* value) {
    auto& options = of(instance).engine.get_options();
    if (options.count(name) == 0)
        return false;
    // OptionsMap exposes only a const subscript; setoption is the writable door, and
    // it is the same one UCI text goes through, so option handlers fire as they should.
    std::istringstream command("name " + std::string(name) + " value " + std::string(value));
    options.setoption(command);
    return true;
}

void* create(const char* bigNetPath, const char* smallNetPath) {
    chessmirrorInitialiseTables();

    Instance* wrapper = nullptr;
    try
    {
        wrapper = new Instance();
    }
    catch (...)
    {
        return nullptr;
    }

    // Setting the option runs its handler, which loads that net. The constructor
    // already tried the bare default names against an empty directory and failed
    // harmlessly; these absolute paths are the load that counts.
    setOption(wrapper, "EvalFile", bigNetPath);
    setOption(wrapper, "EvalFileSmall", smallNetPath);

    wrapper->engine.set_on_update_full([wrapper](const Engine::InfoFull& info) {
        if (wrapper->onInfo == nullptr)
            return;
        CfSearchInfo out{};
        out.depth          = info.depth;
        out.selectiveDepth = info.selDepth;
        out.multiPvIndex   = int32_t(info.multiPV);
        out.isBound        = !info.bound.empty();
        out.nodes          = uint64_t(info.nodes);
        out.nodesPerSecond = uint64_t(info.nps);
        out.timeMs         = uint64_t(info.timeMs);
        out.hashFull       = info.hashfull;
        fillScore(info.score, out);
        std::snprintf(out.pv, sizeof(out.pv), "%.*s", int(info.pv.size()), info.pv.data());
        wrapper->onInfo(wrapper->context, &out);
    });

    // A position with no legal moves is reported only here, and only once: depth 0, a
    // mate or draw score, and then a bestmove of "(none)". Forwarded rather than dropped,
    // because it is the search's entire answer for a finished game.
    wrapper->engine.set_on_update_no_moves([wrapper](const Engine::InfoShort& info) {
        if (wrapper->onInfo == nullptr)
            return;
        CfSearchInfo out{};
        out.depth        = info.depth;
        out.multiPvIndex = 1;
        fillScore(info.score, out);
        wrapper->onInfo(wrapper->context, &out);
    });

    wrapper->engine.set_on_bestmove([wrapper](std::string_view best, std::string_view ponder) {
        if (wrapper->onBest == nullptr)
            return;
        const std::string bestMove(best);
        const std::string ponderMove(ponder);
        wrapper->onBest(wrapper->context, bestMove.c_str(), ponderMove.c_str());
    });

    // Every one of Stockfish's callbacks must be installed, not just the ones whose
    // answers are wanted: they are bare std::functions, called unconditionally, and an
    // empty one throws std::bad_function_call from inside the search. Engine::go begins
    // by verifying the networks, so leaving that hook alone means every search aborts the
    // process on its first line. These two are the ones with nothing to say to the app —
    // "currently searching move 23" during a ten-million-node iteration, and "Network
    // replica 1: Shared memory." — so they are installed to be dropped, deliberately.
    wrapper->engine.set_on_iter([](const Engine::InfoIter&) {});
    wrapper->engine.set_on_verify_networks([](std::string_view) {});

    return wrapper;
}

void destroy(void* instance) {
    of(instance).engine.stop();
    of(instance).engine.wait_for_search_finished();
    delete static_cast<Instance*>(instance);
}

void go(void*                           instance,
        const char*                     startFen,
        const std::vector<std::string>& moves,
        const CfSearchLimits*           limits,
        void*                           context,
        CfInfoCallback                  onInfo,
        CfBestMoveCallback              onBestMove) {
    Instance& engine = of(instance);

    // The previous search has to be finished before its position is overwritten.
    // ThreadPool::start_thinking waits, but set_position happens first and writes the
    // Engine's own Position, so the wait belongs here too. Callers serialise, so by the
    // time a second search is asked for the first has already reported; this is free.
    engine.engine.wait_for_search_finished();

    engine.context = context;
    engine.onInfo  = onInfo;
    engine.onBest  = onBestMove;

    engine.engine.set_position(std::string(startFen), moves);

    Search::LimitsType searchLimits;
    searchLimits.startTime = now();
    if (limits != nullptr)
    {
        if (limits->movetimeMs > 0)
            searchLimits.movetime = TimePoint(limits->movetimeMs);
        if (limits->depth > 0)
            searchLimits.depth = limits->depth;
        if (limits->nodes > 0)
            searchLimits.nodes = limits->nodes;
    }
    // Nothing asked for means deepen until told to stop, which is what an
    // Analysis is (docs/adr/0009).
    if (searchLimits.movetime == 0 && searchLimits.depth == 0 && searchLimits.nodes == 0)
        searchLimits.infinite = 1;

    engine.engine.go(searchLimits);
}

void stop(void* instance) { of(instance).engine.stop(); }
void wait(void* instance) { of(instance).engine.wait_for_search_finished(); }
void clear(void* instance) { of(instance).engine.search_clear(); }

}  // namespace

// Each build has its own copy of these tables, so each initialises its own, once.
void chessmirrorInitialiseTables() {
    static std::once_flag once;
    std::call_once(once, [] {
        Bitboards::init();
        Position::init();
    });
}

const CfEngineBuildOps& chessmirrorEngineBuild() {
    static const CfEngineBuildOps ops{create, destroy, setOption, go, stop, wait, clear};
    return ops;
}

}  // namespace Stockfish
