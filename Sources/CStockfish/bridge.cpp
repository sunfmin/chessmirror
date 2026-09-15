#include "include/chessfen_bridge.h"

#include <cctype>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

#include <deque>

#include "stockfish/bitboard.h"
#include "stockfish/engine.h"
#include "stockfish/movegen.h"
#include "stockfish/perft.h"
#include "stockfish/position.h"
#include "stockfish/score.h"
#include "stockfish/search.h"
#include "stockfish/types.h"
#include "stockfish/uci.h"
#include "stockfish/ucioption.h"

using namespace Stockfish;

// ---------------------------------------------------------------- lifecycle

void cf_global_init(void) {
    static std::once_flag once;
    std::call_once(once, [] {
        Bitboards::init();
        Position::init();
    });
}

// ------------------------------------------------------------- FEN validity

namespace {

struct Verdict {
    CfFenVerdict value;

    explicit Verdict(CfFenIssue issue = CF_FEN_OK, int colour = -1) {
        value.issue  = issue;
        value.colour = colour;
        for (int i = 0; i < CF_MAX_MARKED_SQUARES; ++i)
            value.squares[i] = CF_NO_SQUARE;
    }

    Verdict& mark(int square) {
        for (int i = 0; i < CF_MAX_MARKED_SQUARES; ++i)
            if (value.squares[i] == CF_NO_SQUARE)
            {
                value.squares[i] = square;
                break;
            }
        return *this;
    }
};

// Everything the placement field says, in a form the later rules can question.
struct Placement {
    int  pieceCount[2]  = {0, 0};
    int  pawnCount[2]   = {0, 0};
    int  kingSquare[2]  = {CF_NO_SQUARE, CF_NO_SQUARE};
    int  extraKing[2]   = {CF_NO_SQUARE, CF_NO_SQUARE};
    bool rookOnHome[2]  = {false, false};  // any rook on that colour's rank 1/8
    std::vector<int> pawnsOnBackRank;
};

constexpr int squareOf(int file, int rank) { return rank * 8 + file; }

// Parses the placement field only. Pure string work: nothing here may hand a
// half-trusted FEN to Stockfish, because that is the thing being guarded.
bool parsePlacement(const std::string& field, Placement& out, Verdict& bad) {
    int file = 0, rank = 7;

    for (char token : field)
    {
        if (token == '/')
        {
            if (file != 8)
            {
                bad = Verdict(CF_FEN_BAD_RANK_WIDTH);
                return false;
            }
            if (--rank < 0)
            {
                bad = Verdict(CF_FEN_BAD_RANK_COUNT);
                return false;
            }
            file = 0;
            continue;
        }

        if (token >= '1' && token <= '8')
        {
            file += token - '0';
            if (file > 8)
            {
                bad = Verdict(CF_FEN_BAD_RANK_WIDTH);
                return false;
            }
            continue;
        }

        const char  upper  = char(std::toupper(token));
        const int   colour = std::islower(token) ? 1 : 0;
        const char* known  = "PNBRQK";
        if (!std::strchr(known, upper))
        {
            bad = Verdict(CF_FEN_BAD_PIECE_CHAR);
            return false;
        }
        if (file > 7)
        {
            bad = Verdict(CF_FEN_BAD_RANK_WIDTH);
            return false;
        }

        const int square = squareOf(file, rank);
        out.pieceCount[colour]++;

        if (upper == 'P')
        {
            out.pawnCount[colour]++;
            if (rank == 0 || rank == 7)
                out.pawnsOnBackRank.push_back(square);
        }
        else if (upper == 'K')
        {
            if (out.kingSquare[colour] == CF_NO_SQUARE)
                out.kingSquare[colour] = square;
            else
                out.extraKing[colour] = square;
        }
        else if (upper == 'R')
        {
            if (rank == (colour == 0 ? 0 : 7))
                out.rookOnHome[colour] = true;
        }

        ++file;
    }

    if (file != 8)
    {
        bad = Verdict(CF_FEN_BAD_RANK_WIDTH);
        return false;
    }
    if (rank != 0)
    {
        bad = Verdict(CF_FEN_BAD_RANK_COUNT);
        return false;
    }
    return true;
}

Verdict validate(const std::string& fen) {
    std::istringstream stream(fen);
    std::string placement, sideToMove, castling, enPassant;
    if (!(stream >> placement >> sideToMove >> castling >> enPassant))
        return Verdict(CF_FEN_MALFORMED);

    Placement board;
    Verdict   bad;
    if (!parsePlacement(placement, board, bad))
        return bad;

    for (int colour = 0; colour < 2; ++colour)
    {
        if (board.kingSquare[colour] == CF_NO_SQUARE)
            return Verdict(CF_FEN_MISSING_KING, colour);
        if (board.extraKing[colour] != CF_NO_SQUARE)
            return Verdict(CF_FEN_EXTRA_KING, colour)
              .mark(board.kingSquare[colour])
              .mark(board.extraKing[colour]);
        if (board.pieceCount[colour] > 16)
            return Verdict(CF_FEN_TOO_MANY_PIECES, colour);
        if (board.pawnCount[colour] > 8)
            return Verdict(CF_FEN_TOO_MANY_PAWNS, colour);
    }

    if (!board.pawnsOnBackRank.empty())
    {
        Verdict verdict(CF_FEN_PAWN_ON_BACK_RANK);
        for (int square : board.pawnsOnBackRank)
            verdict.mark(square);
        return verdict;
    }

    if (sideToMove != "w" && sideToMove != "b")
        return Verdict(CF_FEN_BAD_SIDE_TO_MOVE);

    if (castling != "-")
        for (char right : castling)
        {
            const int  colour   = std::islower(right) ? 1 : 0;
            const char upper    = char(std::toupper(right));
            const int  homeKing = colour == 0 ? squareOf(4, 0) : squareOf(4, 7);

            if (upper != 'K' && upper != 'Q')
                return Verdict(CF_FEN_BAD_CASTLING, colour);
            // Stockfish scans the home rank for a rook in a loop with no lower
            // bound; without one it reads off the board.
            if (!board.rookOnHome[colour])
                return Verdict(CF_FEN_CASTLING_WITHOUT_ROOK, colour);
            if (board.kingSquare[colour] != homeKing)
                return Verdict(CF_FEN_CASTLING_WITHOUT_KING, colour)
                  .mark(board.kingSquare[colour]);
        }

    if (enPassant != "-")
    {
        if (enPassant.size() != 2 || enPassant[0] < 'a' || enPassant[0] > 'h')
            return Verdict(CF_FEN_BAD_EN_PASSANT);
        const char wantedRank = sideToMove == "w" ? '6' : '3';
        if (enPassant[1] != wantedRank)
            return Verdict(CF_FEN_BAD_EN_PASSANT);
    }

    int halfmove = 0, fullmove = 1;
    if (stream >> halfmove)
    {
        if (halfmove < 0 || halfmove > 150)
            return Verdict(CF_FEN_BAD_CLOCK);
        if ((stream >> fullmove) && fullmove < 1)
            return Verdict(CF_FEN_BAD_CLOCK);
    }

    // Only now is the FEN safe to hand over: kings exist, castling rights have a
    // rook to find. The last rule needs a real Position to answer.
    cf_global_init();
    StateInfo state;
    Position  position;
    position.set(fen, false, &state);

    const Color mover  = position.side_to_move();
    const Color waiter = ~mover;
    if (position.attackers_to(position.square<KING>(waiter)) & position.pieces(mover))
        return Verdict(CF_FEN_SIDE_NOT_TO_MOVE_IN_CHECK, waiter == WHITE ? 0 : 1)
          .mark(int(position.square<KING>(waiter)));

    return Verdict();
}

}  // namespace

CfFenVerdict cf_validate_fen(const char *fen) {
    if (fen == nullptr)
        return Verdict(CF_FEN_MALFORMED).value;
    return validate(std::string(fen)).value;
}

// -------------------------------------------------------------------- rules

namespace {

// A Game replayed from its start, which is the only way repetition and the
// fifty-move rule can be answered: they are properties of the history, not of a
// FEN. StateInfo objects have to outlive the replay and be stable in memory, so
// a deque holds them — Position keeps a pointer into it.
struct Replay {
    Position              position;
    std::deque<StateInfo> states;
    // Raw Zobrist keys of every position reached, the current one included.
    // Position::key() is *not* usable here: it is perturbed by rule50 for the
    // benefit of the transposition table, so equal positions can hash apart.
    std::vector<Key> keys;

    bool build(const char* startFen, const char* const* moves, int32_t moveCount) {
        if (startFen == nullptr || cf_validate_fen(startFen).issue != CF_FEN_OK)
            return false;

        cf_global_init();
        states.emplace_back();
        position.set(std::string(startFen), false, &states.back());
        keys.push_back(position.state()->key);

        for (int32_t i = 0; i < moveCount; ++i)
        {
            if (moves == nullptr || moves[i] == nullptr)
                return false;
            const Move move = UCIEngine::to_move(position, std::string(moves[i]));
            if (move == Move::none())
                return false;
            states.emplace_back();
            position.do_move(move, states.back());
            keys.push_back(position.state()->key);
        }
        return true;
    }

    int repetitionCount() const {
        const Key current = position.state()->key;
        int       count   = 0;
        for (Key key : keys)
            if (key == current)
                ++count;
        return count;
    }
};

int squareColour(Square s) { return ((int(s) & 7) + (int(s) >> 3)) & 1; }

// The practical "cannot possibly mate" set, not FIDE's full dead-position rule.
bool insufficientMatingMaterial(const Position& pos) {
    if (pos.pieces(PAWN) || pos.pieces(ROOK) || pos.pieces(QUEEN))
        return false;

    const int white = popcount(pos.pieces(WHITE, KNIGHT, BISHOP));
    const int black = popcount(pos.pieces(BLACK, KNIGHT, BISHOP));

    if (white == 0 && black <= 1)
        return true;
    if (black == 0 && white <= 1)
        return true;
    if (white == 1 && black == 1 && popcount(pos.pieces(BISHOP)) == 2)
        return squareColour(lsb(pos.pieces(WHITE, BISHOP)))
            == squareColour(lsb(pos.pieces(BLACK, BISHOP)));
    return false;
}

CfOutcome outcomeOf(Position& pos, const Replay& replay) {
    if (MoveList<LEGAL>(pos).size() == 0)
        return pos.checkers() ? CF_CHECKMATE : CF_STALEMATE;
    if (pos.rule50_count() >= 100)
        return CF_DRAW_FIFTY_MOVE;
    if (replay.repetitionCount() >= 3)
        return CF_DRAW_REPETITION;
    if (insufficientMatingMaterial(pos))
        return CF_DRAW_INSUFFICIENT_MATERIAL;
    return CF_ONGOING;
}

// Stockfish encodes castling as king-to-rook (e1h1). Players see king-to-g1.
Square visibleDestination(Move move) {
    const Square from = move.from_sq();
    const Square to   = move.to_sq();
    if (move.type_of() == CASTLING)
        return make_square(to > from ? FILE_G : FILE_C, rank_of(from));
    return to;
}

CfMove describe(Position& pos, Move move) {
    CfMove out{};
    out.from        = int32_t(move.from_sq());
    out.to          = int32_t(visibleDestination(move));
    out.piece       = int32_t(type_of(pos.moved_piece(move)));
    out.promotion   = move.type_of() == PROMOTION ? int32_t(move.promotion_type())
                                                  : int32_t(CF_PIECE_NONE);
    out.isEnPassant = move.type_of() == EN_PASSANT;
    out.isCastling  = move.type_of() == CASTLING;
    // Not `piece_on(to) != NO_PIECE`: on a castling move that square holds the
    // player's own rook, which would read as a capture of it.
    out.isCapture  = out.isEnPassant
                  || (!out.isCastling && pos.piece_on(move.to_sq()) != NO_PIECE);
    out.givesCheck = pos.gives_check(move);

    if (out.givesCheck)
    {
        StateInfo state;
        pos.do_move(move, state);
        out.isCheckmate = MoveList<LEGAL>(pos).size() == 0;
        pos.undo_move(move);
    }

    const std::string uci = UCIEngine::move(move, false);
    std::snprintf(out.uci, sizeof(out.uci), "%s", uci.c_str());
    return out;
}

}  // namespace

bool cf_game_state(const char       *startFen,
                   const char *const *moves,
                   int32_t            moveCount,
                   CfGameState       *out) {
    if (out == nullptr)
        return false;

    Replay replay;
    if (!replay.build(startFen, moves, moveCount))
        return false;

    Position& pos = replay.position;
    *out          = CfGameState{};

    const std::string fen = pos.fen();
    std::snprintf(out->fen, sizeof(out->fen), "%s", fen.c_str());
    out->sideToMove     = pos.side_to_move() == WHITE ? 0 : 1;
    out->inCheck        = bool(pos.checkers());
    out->outcome        = int32_t(outcomeOf(pos, replay));
    out->halfmoveClock  = pos.rule50_count();
    out->fullmoveNumber = pos.game_ply() / 2 + 1;
    out->legalMoveCount = int32_t(MoveList<LEGAL>(pos).size());

    for (int i = 0; i < CF_MAX_CHECKERS; ++i)
        out->checkers[i] = CF_NO_SQUARE;
    Bitboard checkers = pos.checkers();
    for (int i = 0; checkers && i < CF_MAX_CHECKERS; ++i)
        out->checkers[i] = int32_t(pop_lsb(checkers));

    return true;
}

int32_t cf_legal_moves(const char       *startFen,
                       const char *const *moves,
                       int32_t            moveCount,
                       CfMove            *out,
                       int32_t            capacity) {
    Replay replay;
    if (!replay.build(startFen, moves, moveCount))
        return -1;

    int32_t written = 0;
    for (const auto& move : MoveList<LEGAL>(replay.position))
    {
        if (out != nullptr && written < capacity)
            out[written] = describe(replay.position, move);
        ++written;
    }
    return written;
}

// ----------------------------------------------------------------- control

bool cf_square_control(const char       *startFen,
                       const char *const *moves,
                       int32_t            moveCount,
                       CfControl         *out) {
    if (out == nullptr)
        return false;

    Replay replay;
    if (!replay.build(startFen, moves, moveCount))
        return false;

    const Position& pos = replay.position;
    *out                = CfControl{};

    for (int i = 0; i < 64; ++i)
    {
        // Purely geometric, and deliberately so: pinned pieces count, because a
        // pinned defender still answers a capture on the square it covers.
        const Bitboard attackers = pos.attackers_to(Square(i));
        out->white[i]            = popcount(attackers & pos.pieces(WHITE));
        out->black[i]            = popcount(attackers & pos.pieces(BLACK));
    }
    return true;
}

bool cf_exchange_value(const char       *startFen,
                       const char *const *moves,
                       int32_t            moveCount,
                       const char        *uci,
                       int32_t           *out) {
    if (out == nullptr || uci == nullptr)
        return false;

    Replay replay;
    if (!replay.build(startFen, moves, moveCount))
        return false;

    Position&  pos  = replay.position;
    const Move move = UCIEngine::to_move(pos, std::string(uci));
    if (move == Move::none())
        return false;

    // A threshold of 1 is "strictly better than level" in the engine's own units,
    // so the three answers come out of two questions rather than a scale nobody
    // downstream could interpret.
    if (pos.see_ge(move, 1))
        *out = int32_t(CF_EXCHANGE_WINNING);
    else if (pos.see_ge(move, 0))
        *out = int32_t(CF_EXCHANGE_LEVEL);
    else
        *out = int32_t(CF_EXCHANGE_LOSING);
    return true;
}

// ------------------------------------------------------------------- perft

uint64_t cf_perft(const char *fen, int depth) {
    if (fen == nullptr || cf_validate_fen(fen).issue != CF_FEN_OK)
        return 0;

    cf_global_init();
    StateInfo state;
    Position  position;
    position.set(std::string(fen), false, &state);

    if (depth <= 0)
        return 1;
    // Stockfish's own perft<false> recurses without a floor at depth 1, and its
    // perft<true> prints every root move to stdout. Neither is wanted here.
    if (depth == 1)
        return MoveList<LEGAL>(position).size();
    return Benchmark::perft<false>(position, depth);
}

// ------------------------------------------------------------------- engine

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

}  // namespace

struct CfEngine {
    Stockfish::Engine engine;

    // Held for the duration of one search, read by Stockfish's threads.
    void              *context   = nullptr;
    CfInfoCallback     onInfo    = nullptr;
    CfBestMoveCallback onBest    = nullptr;

    CfEngine() : engine(std::nullopt) {}
};

CfEngine *cf_engine_create(const char     *bigNetPath,
                           const char     *smallNetPath,
                           CfEngineStatus *status) {
    auto report = [status](CfEngineStatus value) {
        if (status != nullptr)
            *status = value;
    };

    if (bigNetPath == nullptr || smallNetPath == nullptr)
    {
        report(CF_ENGINE_NET_MISSING);
        return nullptr;
    }

    // Checked here, before Stockfish sees them, because Network::verify answers a
    // failed load with exit(EXIT_FAILURE) — in an app, the process just vanishes.
    for (const char *path : {bigNetPath, smallNetPath})
    {
        std::ifstream probe(path, std::ios::binary | std::ios::ate);
        if (!probe)
        {
            report(CF_ENGINE_NET_MISSING);
            return nullptr;
        }
        // The smaller of the two real nets is a few megabytes; anything under one
        // is a truncated download or the wrong file entirely.
        if (probe.tellg() < std::streamoff(1024 * 1024))
        {
            report(CF_ENGINE_NET_TOO_SMALL);
            return nullptr;
        }
    }

    cf_global_init();

    CfEngine *wrapper = nullptr;
    try
    {
        wrapper = new CfEngine();
    }
    catch (...)
    {
        report(CF_ENGINE_ALLOC_FAILED);
        return nullptr;
    }

    // Setting the option runs its handler, which loads that net. The constructor
    // already tried the bare default names against an empty directory and failed
    // harmlessly; these absolute paths are the load that counts.
    cf_engine_set_option(wrapper, "EvalFile", bigNetPath);
    cf_engine_set_option(wrapper, "EvalFileSmall", smallNetPath);

    wrapper->engine.set_on_update_full([wrapper](const Stockfish::Engine::InfoFull& info) {
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
    wrapper->engine.set_on_update_no_moves([wrapper](const Stockfish::Engine::InfoShort& info) {
        if (wrapper->onInfo == nullptr)
            return;
        CfSearchInfo out{};
        out.depth        = info.depth;
        out.multiPvIndex = 1;
        fillScore(info.score, out);
        wrapper->onInfo(wrapper->context, &out);
    });

    wrapper->engine.set_on_bestmove(
      [wrapper](std::string_view best, std::string_view ponder) {
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
    wrapper->engine.set_on_iter([](const Stockfish::Engine::InfoIter&) {});
    wrapper->engine.set_on_verify_networks([](std::string_view) {});

    report(CF_ENGINE_OK);
    return wrapper;
}

void cf_engine_destroy(CfEngine *engine) {
    if (engine == nullptr)
        return;
    engine->engine.stop();
    engine->engine.wait_for_search_finished();
    delete engine;
}

bool cf_engine_set_option(CfEngine *engine, const char *name, const char *value) {
    if (engine == nullptr || name == nullptr || value == nullptr)
        return false;
    auto& options = engine->engine.get_options();
    if (options.count(name) == 0)
        return false;
    // OptionsMap exposes only a const subscript; setoption is the writable door, and
    // it is the same one UCI text goes through, so option handlers fire as they should.
    std::istringstream command("name " + std::string(name) + " value " + std::string(value));
    options.setoption(command);
    return true;
}

bool cf_engine_go(CfEngine             *engine,
                  const char           *startFen,
                  const char *const    *moves,
                  int32_t               moveCount,
                  const CfSearchLimits *limits,
                  void                 *context,
                  CfInfoCallback        onInfo,
                  CfBestMoveCallback    onBestMove) {
    if (engine == nullptr || startFen == nullptr)
        return false;
    if (cf_validate_fen(startFen).issue != CF_FEN_OK)
        return false;

    // The moves are replayed once here purely to reject an illegal one before the
    // search starts; Stockfish's own set_position would accept it silently.
    Replay replay;
    if (!replay.build(startFen, moves, moveCount))
        return false;

    std::vector<std::string> played;
    for (int32_t i = 0; i < moveCount; ++i)
        played.emplace_back(moves[i]);

    // The previous search has to be finished before its position is overwritten.
    // ThreadPool::start_thinking waits, but set_position happens first and writes the
    // Engine's own Position, so the wait belongs here too. Callers serialise, so by the
    // time a second search is asked for the first has already reported; this is free.
    engine->engine.wait_for_search_finished();

    engine->context = context;
    engine->onInfo  = onInfo;
    engine->onBest  = onBestMove;

    engine->engine.set_position(std::string(startFen), played);

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

    engine->engine.go(searchLimits);
    return true;
}

void cf_engine_stop(CfEngine *engine) {
    if (engine != nullptr)
        engine->engine.stop();
}

void cf_engine_wait(CfEngine *engine) {
    if (engine != nullptr)
        engine->engine.wait_for_search_finished();
}

void cf_engine_clear(CfEngine *engine) {
    if (engine != nullptr)
        engine->engine.search_clear();
}
