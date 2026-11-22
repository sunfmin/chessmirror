#include "include/chessmirror_bridge.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <mutex>
#include <new>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

#include <deque>

#include "engine/engine_build.h"
#include "stockfish/bitboard.h"
#include "stockfish/evaluate.h"
#include "stockfish/misc.h"
#include "stockfish/movegen.h"
#include "stockfish/perft.h"
#include "stockfish/position.h"
#include "stockfish/search.h"
#include "stockfish/types.h"
#include "stockfish/uci.h"

using namespace Stockfish;

// ---------------------------------------------------------------- lifecycle

void cf_global_init(void) { Stockfish::chessmirrorInitialiseTables(); }

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
    // Knights, bishops, rooks, queens, by Stockfish's piece-type number.
    int  officers[2][QUEEN + 1] = {};
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
        if (upper != 'P' && upper != 'K')
            out.officers[colour][std::strchr(known, upper) - known + 1]++;

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

// The fields of a FEN, one space between each. sf_19 reads a FEN a character at a
// time and takes a second space between two fields as the next field (an en passant
// square of " " is a refusal), where a person typing one, and this validator, see
// fields. Whatever Stockfish is handed goes through this.
std::string canonical(const std::string& fen) {
    std::istringstream stream(fen);
    std::string        field, joined;
    while (stream >> field)
        joined += (joined.empty() ? "" : " ") + field;
    return joined;
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
        // Every piece past a side's starting set is a promoted pawn, and that pawn is
        // gone: three queens and eight pawns is not a position any game reaches. sf_19
        // refuses it ("Too many pieces"), so it is refused here first.
        const int* officers = board.officers[colour];
        const int  promoted = std::max(officers[KNIGHT] - 2, 0) + std::max(officers[BISHOP] - 2, 0)
                           + std::max(officers[ROOK] - 2, 0) + std::max(officers[QUEEN] - 1, 0);
        if (promoted > 8 - board.pawnCount[colour])
            return Verdict(CF_FEN_TOO_MANY_PIECES, colour);
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

    // sf_19 refuses a fifth right; KQkq is all there are.
    if (castling.size() > 4)
        return Verdict(CF_FEN_BAD_CASTLING);
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
        // sf_19's ceiling on the game's length, which no real game is near.
        if ((stream >> fullmove) && (fullmove < 1 || fullmove > 100000))
            return Verdict(CF_FEN_BAD_CLOCK);
    }

    // Only now is the FEN safe to hand over: every rule sf_19's Position::set has is
    // asked above. The last rule needs a real Position to answer. sf_19 refusing it
    // anyway means a rule of its own is missing from this list; the FEN is refused
    // rather than half-set (FenValidationTests holds the list to sf_19's).
    cf_global_init();
    StateInfo state;
    Position  position;
    if (position.set(canonical(fen), false, &state).has_value())
        return Verdict(CF_FEN_MALFORMED);

    const Color mover  = position.side_to_move();
    const Color waiter = ~mover;
    if (position.attackers_to(position.square<KING>(waiter)) & position.pieces(mover))
        return Verdict(CF_FEN_SIDE_NOT_TO_MOVE_IN_CHECK, waiter == WHITE ? 0 : 1)
          .mark(int(position.square<KING>(waiter)));

    return Verdict();
}

}  // namespace

bool cf_stockfish_refuses_fen(const char *fen) {
    if (fen == nullptr)
        return true;
    cf_global_init();
    StateInfo state;
    Position  position;
    return position.set(std::string(fen), false, &state).has_value();
}

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
        if (position.set(canonical(startFen), false, &states.back()).has_value())
            return false;
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
    if (position.set(canonical(fen), false, &state).has_value())
        return 0;

    if (depth <= 0)
        return 1;
    // Stockfish's own perft<false> recurses without a floor at depth 1, and its
    // perft<true> prints every root move to stdout. Neither is wanted here.
    if (depth == 1)
        return MoveList<LEGAL>(position).size();
    return Benchmark::perft<false>(position, depth);
}

// ------------------------------------------------------------------- engine

// Two builds of the engine are linked in, and each CfEngine is one of them for its
// whole life (docs/adr/0052). The rules queries above need no dotprod and always run
// on the armv8 build's tables; only a search is worth the second copy.
namespace StockfishDotprod {
const CfEngineBuildOps& chessmirrorEngineBuild();
}

struct CfEngine {
    CfEngineBuild           build;
    const CfEngineBuildOps* ops;
    void*                   instance;
};

const char *cf_engine_name(void) {
    static const std::string name = engine_version_info();
    return name.c_str();
}

const char *cf_engine_net_name(void) { return EvalFileDefaultName; }

int32_t cf_engine_lowest_elo(void) { return Search::Skill::LowestElo; }
int32_t cf_engine_highest_elo(void) { return Search::Skill::HighestElo; }

CfEngine *cf_engine_create(CfEngineBuild build, const char *netPath, CfEngineStatus *status) {
    auto report = [status](CfEngineStatus value) {
        if (status != nullptr)
            *status = value;
    };

    if (netPath == nullptr)
    {
        report(CF_ENGINE_NET_MISSING);
        return nullptr;
    }

    // Checked here, before Stockfish sees it, because Network::verify answers a
    // failed load with exit(EXIT_FAILURE) — in an app, the process just vanishes.
    std::ifstream probe(netPath, std::ios::binary | std::ios::ate);
    if (!probe)
    {
        report(CF_ENGINE_NET_MISSING);
        return nullptr;
    }
    // The real net is 94 MiB; anything under one is a truncated download or the
    // wrong file entirely.
    if (probe.tellg() < std::streamoff(1024 * 1024))
    {
        report(CF_ENGINE_NET_TOO_SMALL);
        return nullptr;
    }

    const CfEngineBuildOps& ops = build == CF_BUILD_DOTPROD
                                  ? StockfishDotprod::chessmirrorEngineBuild()
                                  : Stockfish::chessmirrorEngineBuild();
    void* instance = ops.create(netPath);
    CfEngine* engine = instance == nullptr ? nullptr : new (std::nothrow) CfEngine{build, &ops, instance};
    if (engine == nullptr)
    {
        if (instance != nullptr)
            ops.destroy(instance);
        report(CF_ENGINE_ALLOC_FAILED);
        return nullptr;
    }
    report(CF_ENGINE_OK);
    return engine;
}

CfEngineBuild cf_engine_build(const CfEngine *engine) { return engine->build; }

void cf_engine_destroy(CfEngine *engine) {
    if (engine == nullptr)
        return;
    engine->ops->destroy(engine->instance);
    delete engine;
}

bool cf_engine_set_option(CfEngine *engine, const char *name, const char *value) {
    if (engine == nullptr || name == nullptr || value == nullptr)
        return false;
    return engine->ops->setOption(engine->instance, name, value);
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

    return engine->ops->go(engine->instance, canonical(startFen).c_str(), played, limits, context,
                           onInfo, onBestMove);
}

void cf_engine_stop(CfEngine *engine) {
    if (engine != nullptr)
        engine->ops->stop(engine->instance);
}

void cf_engine_wait(CfEngine *engine) {
    if (engine != nullptr)
        engine->ops->wait(engine->instance);
}

void cf_engine_clear(CfEngine *engine) {
    if (engine != nullptr)
        engine->ops->clear(engine->instance);
}
