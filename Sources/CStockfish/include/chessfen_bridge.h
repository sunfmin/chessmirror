/*
  A C ABI over the parts of Stockfish this app uses. Deliberately C and not C++
  interop: the callers are Swift, the values crossing are plain data, and a C
  surface keeps Stockfish's headers — and its concurrency — out of Swift's way.

  Stockfish is GPLv3, so this whole repository is (see docs/adr/0001).
*/

#ifndef CHESSFEN_BRIDGE_H
#define CHESSFEN_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Squares are 0..63 with a1 = 0, h1 = 7, a8 = 56 — Stockfish's own numbering. */
#define CF_NO_SQUARE (-1)

/* ---------------------------------------------------------------- lifecycle */

/* Idempotent; must be called before anything else here. */
void cf_global_init(void);

/* ------------------------------------------------------------- FEN validity */

/*
  Why this exists at all: Stockfish 18's Position::set does no validation. Its
  asserts vanish under NDEBUG, square<KING>() is undefined without exactly one
  king, and the castling parser scans for a rook with an unbounded loop that
  walks off the board when the FEN claims a right no rook can support. Every FEN
  is therefore vetted here before Stockfish is allowed to see it.
*/
typedef enum {
    CF_FEN_OK = 0,
    CF_FEN_MALFORMED,                  /* not enough fields, or junk in them   */
    CF_FEN_BAD_PIECE_CHAR,             /* placement field has an unknown glyph */
    CF_FEN_BAD_RANK_WIDTH,             /* a rank does not add up to 8 files    */
    CF_FEN_BAD_RANK_COUNT,             /* not 8 ranks                          */
    CF_FEN_TOO_MANY_PIECES,            /* >32 on the board, or >16 for a side  */
    CF_FEN_TOO_MANY_PAWNS,             /* >8 pawns for a side                  */
    CF_FEN_MISSING_KING,               /* a side has no king                   */
    CF_FEN_EXTRA_KING,                 /* a side has more than one king        */
    CF_FEN_PAWN_ON_BACK_RANK,          /* pawn on rank 1 or rank 8             */
    CF_FEN_BAD_SIDE_TO_MOVE,
    CF_FEN_BAD_CASTLING,               /* glyph outside KQkq-                  */
    CF_FEN_CASTLING_WITHOUT_ROOK,      /* the unbounded-loop hazard            */
    CF_FEN_CASTLING_WITHOUT_KING,      /* king not on its home square          */
    CF_FEN_BAD_EN_PASSANT,
    CF_FEN_BAD_CLOCK,
    CF_FEN_SIDE_NOT_TO_MOVE_IN_CHECK   /* also covers adjacent kings           */
} CfFenIssue;

#define CF_MAX_MARKED_SQUARES 8

/* `colour`: 0 white, 1 black, -1 when the issue belongs to neither.
   `squares`: the squares worth highlighting, CF_NO_SQUARE-padded. */
typedef struct {
    CfFenIssue issue;
    int32_t    colour;
    int32_t    squares[CF_MAX_MARKED_SQUARES];
} CfFenVerdict;

CfFenVerdict cf_validate_fen(const char *fen);

/* ------------------------------------------------------------------- rules  */

/*
  Rules Queries are stateless: every call takes the starting FEN plus the moves
  played from it and replays them. The Game lives in Swift; nothing is cached
  here, so these calls can never race with a running search (docs/adr/0003).
*/

/* Stockfish's own piece-type numbering, so nothing has to be renumbered. */
typedef enum {
    CF_PIECE_NONE = 0,
    CF_PAWN       = 1,
    CF_KNIGHT     = 2,
    CF_BISHOP     = 3,
    CF_ROOK       = 4,
    CF_QUEEN      = 5,
    CF_KING       = 6
} CfPieceType;

typedef struct {
    int32_t from;
    /* Where the piece lands *as the player sees it*: for castling this is g1/c1,
       not the rook's square that Stockfish encodes internally. */
    int32_t to;
    int32_t piece;      /* CfPieceType of the mover     */
    int32_t promotion;  /* CfPieceType or CF_PIECE_NONE */
    bool    isCapture;
    bool    isEnPassant;
    bool    isCastling;
    bool    givesCheck;
    bool    isCheckmate; /* the opponent has no legal reply to it */
    char    uci[8];      /* "e2e4", "e7e8q", "e1g1" */
} CfMove;

typedef enum {
    CF_ONGOING = 0,
    CF_CHECKMATE,
    CF_STALEMATE,
    CF_DRAW_FIFTY_MOVE,
    CF_DRAW_REPETITION,
    /* Insufficient *mating* material, the practical rule: bare kings, king and a
       single minor, or king and bishop each with both bishops on one colour. */
    CF_DRAW_INSUFFICIENT_MATERIAL
} CfOutcome;

#define CF_MAX_FEN 128
#define CF_MAX_CHECKERS 4

typedef struct {
    char    fen[CF_MAX_FEN];
    int32_t sideToMove; /* 0 white, 1 black */
    bool    inCheck;
    int32_t checkers[CF_MAX_CHECKERS]; /* CF_NO_SQUARE-padded */
    int32_t outcome;                   /* CfOutcome */
    int32_t halfmoveClock;
    int32_t fullmoveNumber;
    int32_t legalMoveCount;
} CfGameState;

/* Both return false when the FEN fails validation or a move does not parse as
   legal in the position it is played from. */
bool cf_game_state(const char       *startFen,
                   const char *const *moves,
                   int32_t            moveCount,
                   CfGameState       *out);

/* Writes at most `capacity` moves and returns how many exist, which may exceed
   `capacity`; 218 is the most any position can have. */
int32_t cf_legal_moves(const char       *startFen,
                       const char *const *moves,
                       int32_t            moveCount,
                       CfMove            *out,
                       int32_t            capacity);

/* ----------------------------------------------------------------- control  */

/*
  Who attacks each of the 64 squares, per colour.

  A move's purpose is nearly always a change in this map — a piece became
  defended, a square changed hands, a piece stopped being hanging — so the map is
  answered here rather than recomputed in Swift, where sliding-piece rays would be
  a second opinion about the rules of chess (docs/adr/0003).

  A piece standing on a square does not attack it. Pinned pieces DO count as
  attackers: a pinned defender still answers a capture on the square it covers,
  because the recapture happens before the pin could ever be cashed. That is a
  real choice rather than an accident of the engine, and the tests hold it.
*/
typedef struct {
    int32_t white[64];
    int32_t black[64];
} CfControl;

bool cf_square_control(const char       *startFen,
                       const char *const *moves,
                       int32_t            moveCount,
                       CfControl         *out);

/*
  What a move is worth in material, by static exchange evaluation: whether the
  side making it comes out ahead, level, or behind once both sides have taken
  everything worth taking on the destination square.

  This is what tells "I win a piece here" from "this is an even trade" — the two
  claims a player confuses most often — and, for a quiet move, whether the piece
  is walking somewhere it can simply be taken.

  Castling, promotion and en passant are reported level: the engine answers those
  from the move type without running an exchange, and none of the three is a way
  to win or shed material on its own.
*/
typedef enum {
    CF_EXCHANGE_LOSING  = -1,
    CF_EXCHANGE_LEVEL   = 0,
    CF_EXCHANGE_WINNING = 1
} CfExchange;

/* False when the position does not validate or `uci` is not legal in it. */
bool cf_exchange_value(const char       *startFen,
                       const char *const *moves,
                       int32_t            moveCount,
                       const char        *uci,
                       int32_t           *out);

/* ------------------------------------------------------------------- perft  */

/*
  Leaf count of the legal move tree `depth` plies below `fen`. Returns 0 when the
  FEN does not validate. Present because it is the cheapest possible proof that
  the vendored engine is really linked and really generating moves.
*/
uint64_t cf_perft(const char *fen, int depth);

/* ------------------------------------------------------------------ engine  */

/*
  One Stockfish Engine, driven through its C++ class rather than UCI text
  (docs/adr/0002). iOS forbids fork/exec, so there is no subprocess to talk to;
  the engine is linked in and called directly.

  Threading, in one place because getting it wrong here is a crash and not a bug:
  cf_engine_go returns immediately and Stockfish's own threads do the searching.
  The callbacks below are therefore invoked *on those threads*, not on the caller's.
  Everything they touch must be safe for that; the Swift side hands them straight
  to an actor. Do not call any cf_engine_* function from inside a callback.
*/

typedef struct CfEngine CfEngine;

typedef enum {
    CF_ENGINE_OK = 0,
    CF_ENGINE_NET_MISSING,   /* a weights file is absent or unreadable */
    CF_ENGINE_NET_TOO_SMALL, /* present but far too small to be a net  */
    CF_ENGINE_ALLOC_FAILED
} CfEngineStatus;

/*
  Absolute paths to the two weights files. Both are required, and both are
  checked before Stockfish sees them: Network::verify calls exit(EXIT_FAILURE)
  when a net did not load, which in an app means the process simply vanishes.
  Returns NULL and sets *status on failure.
*/
CfEngine *cf_engine_create(const char     *bigNetPath,
                           const char     *smallNetPath,
                           CfEngineStatus *status);

void cf_engine_destroy(CfEngine *engine);

/* Any UCI option name: "Threads", "Hash", "MultiPV". Returns false if unknown. */
bool cf_engine_set_option(CfEngine *engine, const char *name, const char *value);

/* One line of a search's answer, as it stood at the depth just completed. */
typedef struct {
    int32_t  depth;
    int32_t  selectiveDepth;
    int32_t  multiPvIndex; /* 1-based, matching UCI */
    /* Exactly one of these is meaningful; `isMate` says which. Both are from the
       *searching side's* point of view, which is how Stockfish reports them —
       the Swift side is what makes them White-relative. */
    int32_t  centipawns;
    int32_t  matePlies;
    bool     isMate;
    /* True when the search was cut off before the score was proven, so the score
       is only a bound. A line reported this way is not worth showing yet. */
    bool     isBound;
    uint64_t nodes;
    uint64_t nodesPerSecond;
    uint64_t timeMs;
    int32_t  hashFull; /* per mille */
    char     pv[1024]; /* space-separated UCI moves */
} CfSearchInfo;

/* `context` is passed straight back, untouched. */
typedef void (*CfInfoCallback)(void *context, const CfSearchInfo *info);
/* `bestMove` is "e2e4" or "(none)"; `ponder` may be empty. */
typedef void (*CfBestMoveCallback)(void *context, const char *bestMove, const char *ponder);

/*
  What bounds a search. All zero means "search until stopped", which is the mode
  the Analysis screen uses (docs/adr/0009) — it deepens for as long as it is left
  alone. Set exactly the one you mean; movetime and depth together is a race.
*/
typedef struct {
    int32_t  movetimeMs; /* think for this long, then move   */
    int32_t  depth;      /* stop after completing this depth  */
    uint64_t nodes;      /* stop after about this many nodes  */
} CfSearchLimits;

/*
  Starts a search from (startFen, moves) and returns at once. False means the
  position did not validate, in which case nothing was started and no callback
  will fire. Only one search may be in flight per engine; the caller serialises.
*/
bool cf_engine_go(CfEngine             *engine,
                  const char           *startFen,
                  const char *const    *moves,
                  int32_t               moveCount,
                  const CfSearchLimits *limits,
                  void                 *context,
                  CfInfoCallback        onInfo,
                  CfBestMoveCallback    onBestMove);

/* Asks the search to stop. It still reports a best move; this is how an unbounded
   Analysis ends. Safe to call when nothing is running. */
void cf_engine_stop(CfEngine *engine);

/* Blocks until the running search has finished reporting. */
void cf_engine_wait(CfEngine *engine);

/* Forgets everything learned: transposition table, history, the lot. */
void cf_engine_clear(CfEngine *engine);

#ifdef __cplusplus
}
#endif
#endif /* CHESSFEN_BRIDGE_H */
