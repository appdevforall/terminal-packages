/*
** sqlite-brotli: a SQLite loadable extension that adds Brotli functions.
**
**   encodeBrotli(data [, dictionary [, quality [, lgwin]]])  -> BLOB
**   decodeBrotli(data [, dictionary])                         -> BLOB
**
** data        BLOB or TEXT to compress (encodeBrotli), BLOB to decompress
**             (decodeBrotli). NULL data returns NULL.
** dictionary  BLOB holding a raw (LZ77 prefix) dictionary: the same kind that
**             `brotli -D FILE` and brotli4j's PreparedDictionary use. NULL or
**             omitted means Brotli's built-in static dictionary only.
** quality     INTEGER, 0 to 11. NULL or omitted means 11.
** lgwin       INTEGER, base-2 log of the window size, 10 to 24. NULL or
**             omitted means 22.
**
** Both functions return a plain Brotli stream, with no header or framing of
** their own, so their output and the standalone brotli tools interoperate.
** Invalid arguments and corrupt input are reported as SQL errors.
**
** Brotli streams carry no checksum and no record of the dictionary they were
** encoded with. Decoding with no dictionary, or the wrong one, fails when the
** stream references dictionary bytes the decoder cannot reach, but it can
** also succeed and return the wrong bytes. Callers must pass the dictionary
** the data was encoded with.
**
** Load it in the sqlite3 shell with:  .load sqlite-brotli
*/
#include <sqlite3ext.h>
/* SQLITE_EXTENSION_INIT1, but static. SQLite opens extensions with
** RTLD_GLOBAL, so an exported sqlite3_api could be bound to another loaded
** extension's copy. Only the entry point is exported. */
static const sqlite3_api_routines *sqlite3_api = 0;

#include <brotli/decode.h>
#include <brotli/encode.h>
#include <brotli/shared_dictionary.h>
#include <stdarg.h>
#include <string.h>

#define ENCODE_NAME "encodeBrotli"
#define DECODE_NAME "decodeBrotli"

/* Ticket ADFA-6635 fixes the defaults to the Brotli library's own. */
#define DEFAULT_QUALITY BROTLI_DEFAULT_QUALITY /* 11 */
#define DEFAULT_LGWIN BROTLI_DEFAULT_WINDOW    /* 22 */

/* A first guess at the decoded size, as a multiple of the encoded size. */
#define DECODE_SIZE_GUESS 4
/* Bounds on the first output buffer. It doubles as needed from there, so a
** large input does not allocate a large guess before any output exists. */
#define MIN_BUFFER_BYTES 1024
#define MAX_FIRST_BUFFER_BYTES (16 * 1024 * 1024)

/*
** The encoder's prepared form of the last dictionary it was given, kept per
** database connection. Preparing a 768 KB dictionary costs far more than
** compressing a typical documentation page, and a bulk INSERT ... SELECT
** passes the same dictionary on every row. Comparing the bytes is much
** cheaper than preparing them again.
**
** Shared by the four arities of encodeBrotli, so it is reference counted:
** SQLite calls the destructor once per registration.
*/
typedef struct EncoderCache {
  int nRef;
  unsigned char *dict;  /* Our own copy: the prepared form points into it. */
  int nDict;
  BrotliEncoderPreparedDictionary *prepared;
} EncoderCache;

static void encoder_cache_clear(EncoderCache *cache) {
  if (cache->prepared) BrotliEncoderDestroyPreparedDictionary(cache->prepared);
  sqlite3_free(cache->dict);
  cache->prepared = 0;
  cache->dict = 0;
  cache->nDict = 0;
}

static void encoder_cache_release(void *p) {
  EncoderCache *cache = (EncoderCache *)p;
  if (--cache->nRef > 0) return;
  encoder_cache_clear(cache);
  sqlite3_free(cache);
}

/*
** Returns the prepared form of the n-byte dictionary at p, preparing it if it
** differs from the cached one. Returns 0 if memory runs out or Brotli rejects
** the dictionary; *pNomem tells the two apart.
*/
static const BrotliEncoderPreparedDictionary *encoder_cache_get(
    EncoderCache *cache, const unsigned char *p, int n, int *pNomem) {
  *pNomem = 0;
  if (cache->prepared && cache->nDict == n && memcmp(cache->dict, p, (size_t)n) == 0) {
    return cache->prepared;
  }
  encoder_cache_clear(cache);
  cache->dict = sqlite3_malloc64((sqlite3_uint64)n);
  if (cache->dict == 0) {
    *pNomem = 1;
    return 0;
  }
  memcpy(cache->dict, p, (size_t)n);
  cache->nDict = n;
  /* Prepared for the highest quality, so it serves every quality. */
  cache->prepared = BrotliEncoderPrepareDictionary(
      BROTLI_SHARED_DICTIONARY_RAW, (size_t)n, cache->dict, BROTLI_MAX_QUALITY,
      0, 0, 0);
  if (cache->prepared == 0) encoder_cache_clear(cache);
  return cache->prepared;
}

/* An output buffer owned by sqlite3_malloc, so SQLite can take it over. */
typedef struct Buffer {
  unsigned char *a;
  sqlite3_uint64 cap;
  sqlite3_uint64 limit; /* SQLITE_LIMIT_LENGTH: the largest value SQLite accepts. */
} Buffer;

typedef enum { GROW_OK, GROW_NOMEM, GROW_TOOBIG } GrowResult;

/* Doubles the buffer's capacity, but never past its limit. */
static GrowResult buffer_grow(Buffer *b) {
  sqlite3_uint64 cap;
  unsigned char *a;
  if (b->cap >= b->limit) return GROW_TOOBIG;
  cap = b->cap * 2;
  if (cap > b->limit) cap = b->limit;
  a = sqlite3_realloc64(b->a, cap);
  if (a == 0) return GROW_NOMEM;
  b->a = a;
  b->cap = cap;
  return GROW_OK;
}

static int buffer_init(Buffer *b, sqlite3_context *ctx, sqlite3_uint64 want) {
  b->limit = (sqlite3_uint64)sqlite3_limit(sqlite3_context_db_handle(ctx),
                                           SQLITE_LIMIT_LENGTH, -1);
  if (want < MIN_BUFFER_BYTES) want = MIN_BUFFER_BYTES;
  if (want > MAX_FIRST_BUFFER_BYTES) want = MAX_FIRST_BUFFER_BYTES;
  if (want > b->limit) want = b->limit;
  b->cap = want;
  b->a = sqlite3_malloc64(want);
  return b->a != 0;
}

/*
** Hands the first n bytes of the buffer to SQLite as the result. An empty
** result must be a zero-length BLOB: SQLite reads a zero-length result whose
** pointer is NULL as SQL NULL, so it is not left to the pointer.
*/
static void buffer_result(sqlite3_context *ctx, Buffer *b, sqlite3_uint64 n) {
  if (n == 0) {
    sqlite3_free(b->a);
    sqlite3_result_zeroblob(ctx, 0);
  } else {
    /* Give back the slack when it is large, since SQLite keeps the block. */
    if (b->cap - n > n / 4) {
      unsigned char *a = sqlite3_realloc64(b->a, n);
      if (a) b->a = a;
    }
    sqlite3_result_blob64(ctx, b->a, n, sqlite3_free);
  }
  b->a = 0;
}

static void result_errorf(sqlite3_context *ctx, const char *fmt, ...) {
  va_list ap;
  char *msg;
  va_start(ap, fmt);
  msg = sqlite3_vmprintf(fmt, ap);
  va_end(ap);
  if (msg == 0) {
    sqlite3_result_error_nomem(ctx);
    return;
  }
  sqlite3_result_error(ctx, msg, -1);
  sqlite3_free(msg);
}

/*
** Reads an optional INTEGER argument. NULL or absent means dflt. Returns 0,
** with the error already set, when the argument is invalid.
*/
static int int_arg(sqlite3_context *ctx, const char *fn, const char *name,
                   int argc, sqlite3_value **argv, int i, int lo, int hi,
                   int dflt, int *out) {
  sqlite3_int64 v;
  *out = dflt;
  if (i >= argc || sqlite3_value_type(argv[i]) == SQLITE_NULL) return 1;
  if (sqlite3_value_type(argv[i]) != SQLITE_INTEGER) {
    result_errorf(ctx, "%s: %s must be an integer from %d to %d", fn, name, lo,
                  hi);
    return 0;
  }
  /* 64-bit, so a value such as 2^32 + 11 cannot wrap into range. */
  v = sqlite3_value_int64(argv[i]);
  if (v < lo || v > hi) {
    result_errorf(ctx, "%s: %s %lld is out of range; it must be from %d to %d",
                  fn, name, v, lo, hi);
    return 0;
  }
  *out = (int)v;
  return 1;
}

/*
** Reads the optional dictionary argument. NULL or absent leaves *p at 0.
** Returns 0, with the error already set, when the argument is invalid.
*/
static int dict_arg(sqlite3_context *ctx, const char *fn, int argc,
                    sqlite3_value **argv, int i, const unsigned char **p,
                    int *n) {
  *p = 0;
  *n = 0;
  if (i >= argc || sqlite3_value_type(argv[i]) == SQLITE_NULL) return 1;
  if (sqlite3_value_type(argv[i]) != SQLITE_BLOB) {
    result_errorf(ctx, "%s: dictionary must be a blob or NULL", fn);
    return 0;
  }
  *p = sqlite3_value_blob(argv[i]);
  *n = sqlite3_value_bytes(argv[i]);
  if (*n == 0) {
    result_errorf(ctx, "%s: dictionary must not be empty", fn);
    return 0;
  }
  if (*p == 0) {
    sqlite3_result_error_nomem(ctx);
    return 0;
  }
  return 1;
}

static void encode_func(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
  EncoderCache *cache = (EncoderCache *)sqlite3_user_data(ctx);
  const unsigned char *in;
  int nIn;
  const unsigned char *dict;
  int nDict;
  int quality, lgwin;
  BrotliEncoderState *enc = 0;
  Buffer out = {0, 0, 0};
  size_t availIn, availOut;
  const uint8_t *nextIn;
  uint8_t *nextOut;
  sqlite3_uint64 n;

  switch (sqlite3_value_type(argv[0])) {
    case SQLITE_NULL:
      sqlite3_result_null(ctx);
      return;
    case SQLITE_BLOB:
    case SQLITE_TEXT:
      break;
    default:
      result_errorf(ctx, "%s: data must be a blob or text", ENCODE_NAME);
      return;
  }
  if (!dict_arg(ctx, ENCODE_NAME, argc, argv, 1, &dict, &nDict)) return;
  if (!int_arg(ctx, ENCODE_NAME, "quality", argc, argv, 2, BROTLI_MIN_QUALITY,
               BROTLI_MAX_QUALITY, DEFAULT_QUALITY, &quality)) {
    return;
  }
  if (!int_arg(ctx, ENCODE_NAME, "lgwin", argc, argv, 3, BROTLI_MIN_WINDOW_BITS,
               BROTLI_MAX_WINDOW_BITS, DEFAULT_LGWIN, &lgwin)) {
    return;
  }
  /* Read the data last: the pointer stays valid only until argv[0] is
  ** converted again, and nothing above touches argv[0]. */
  in = sqlite3_value_blob(argv[0]);
  nIn = sqlite3_value_bytes(argv[0]);
  if (in == 0 && nIn > 0) {
    sqlite3_result_error_nomem(ctx);
    return;
  }

  enc = BrotliEncoderCreateInstance(0, 0, 0);
  if (enc == 0) {
    sqlite3_result_error_nomem(ctx);
    return;
  }
  BrotliEncoderSetParameter(enc, BROTLI_PARAM_QUALITY, (uint32_t)quality);
  BrotliEncoderSetParameter(enc, BROTLI_PARAM_LGWIN, (uint32_t)lgwin);
  /* The brotli tool passes the file size as this hint too. */
  BrotliEncoderSetParameter(enc, BROTLI_PARAM_SIZE_HINT, (uint32_t)nIn);
  if (dict) {
    int nomem;
    const BrotliEncoderPreparedDictionary *prepared =
        encoder_cache_get(cache, dict, nDict, &nomem);
    if (prepared == 0) {
      if (nomem) {
        sqlite3_result_error_nomem(ctx);
      } else {
        result_errorf(ctx, "%s: Brotli could not prepare the %d-byte dictionary",
                      ENCODE_NAME, nDict);
      }
      goto done;
    }
    if (!BrotliEncoderAttachPreparedDictionary(enc, prepared)) {
      result_errorf(ctx, "%s: Brotli could not attach the %d-byte dictionary",
                    ENCODE_NAME, nDict);
      goto done;
    }
  }

  if (!buffer_init(&out, ctx, (sqlite3_uint64)nIn / 2)) {
    sqlite3_result_error_nomem(ctx);
    goto done;
  }
  availIn = (size_t)nIn;
  nextIn = in;
  availOut = (size_t)out.cap;
  nextOut = out.a;
  for (;;) {
    if (!BrotliEncoderCompressStream(enc, BROTLI_OPERATION_FINISH, &availIn,
                                     &nextIn, &availOut, &nextOut, 0)) {
      /* The arguments were checked above, so what is left is Brotli running
      ** out of memory. */
      sqlite3_result_error_nomem(ctx);
      goto done;
    }
    if (BrotliEncoderIsFinished(enc)) break;
    if (availOut == 0) {
      sqlite3_uint64 used = (sqlite3_uint64)(nextOut - out.a);
      GrowResult grown = buffer_grow(&out);
      if (grown == GROW_NOMEM) {
        sqlite3_result_error_nomem(ctx);
        goto done;
      }
      if (grown == GROW_TOOBIG) {
        sqlite3_result_error_toobig(ctx);
        goto done;
      }
      nextOut = out.a + used;
      availOut = (size_t)(out.cap - used);
    }
  }
  n = (sqlite3_uint64)(nextOut - out.a);
  buffer_result(ctx, &out, n);

done:
  sqlite3_free(out.a);
  BrotliEncoderDestroyInstance(enc);
}

static void decode_func(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
  const unsigned char *in;
  int nIn;
  const unsigned char *dict;
  int nDict;
  BrotliDecoderState *dec = 0;
  Buffer out = {0, 0, 0};
  size_t availIn, availOut;
  const uint8_t *nextIn;
  uint8_t *nextOut;

  switch (sqlite3_value_type(argv[0])) {
    case SQLITE_NULL:
      sqlite3_result_null(ctx);
      return;
    case SQLITE_BLOB:
      break;
    default:
      result_errorf(ctx, "%s: data must be a blob", DECODE_NAME);
      return;
  }
  if (!dict_arg(ctx, DECODE_NAME, argc, argv, 1, &dict, &nDict)) return;
  in = sqlite3_value_blob(argv[0]);
  nIn = sqlite3_value_bytes(argv[0]);
  if (nIn == 0) {
    result_errorf(ctx, "%s: data is empty, which is not a Brotli stream",
                  DECODE_NAME);
    return;
  }
  if (in == 0) {
    sqlite3_result_error_nomem(ctx);
    return;
  }

  dec = BrotliDecoderCreateInstance(0, 0, 0);
  if (dec == 0) {
    sqlite3_result_error_nomem(ctx);
    return;
  }
  /* The decoder reads the dictionary in place, so it must stay valid until
  ** decoding ends; argv[1] does, for the length of this call. */
  if (dict && !BrotliDecoderAttachDictionary(dec, BROTLI_SHARED_DICTIONARY_RAW,
                                             (size_t)nDict, dict)) {
    result_errorf(ctx, "%s: Brotli could not attach the %d-byte dictionary",
                  DECODE_NAME, nDict);
    goto done;
  }

  if (!buffer_init(&out, ctx, (sqlite3_uint64)nIn * DECODE_SIZE_GUESS)) {
    sqlite3_result_error_nomem(ctx);
    goto done;
  }
  availIn = (size_t)nIn;
  nextIn = in;
  availOut = (size_t)out.cap;
  nextOut = out.a;
  for (;;) {
    BrotliDecoderResult r = BrotliDecoderDecompressStream(
        dec, &availIn, &nextIn, &availOut, &nextOut, 0);
    if (r == BROTLI_DECODER_RESULT_SUCCESS) {
      if (availIn != 0) {
        result_errorf(ctx,
                      "%s: %llu bytes of trailing data after the end of the "
                      "Brotli stream",
                      DECODE_NAME, (unsigned long long)availIn);
        goto done;
      }
      break;
    }
    if (r == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) {
      sqlite3_uint64 used = (sqlite3_uint64)(nextOut - out.a);
      GrowResult grown = buffer_grow(&out);
      if (grown == GROW_NOMEM) {
        sqlite3_result_error_nomem(ctx);
        goto done;
      }
      if (grown == GROW_TOOBIG) {
        /* SQLite's length limit is the only cap on the result. Its default,
        ** 1,000,000,000 bytes, can be more than a phone lets one process
        ** allocate, so the README says to lower it for untrusted input. */
        sqlite3_result_error_toobig(ctx);
        goto done;
      }
      nextOut = out.a + used;
      availOut = (size_t)(out.cap - used);
      continue;
    }
    if (r == BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT) {
      result_errorf(ctx, "%s: the Brotli stream is truncated", DECODE_NAME);
      goto done;
    }
    {
      /* Brotli names its errors like "_ERROR_FORMAT_CL_SPACE". The
      ** _ERROR_ALLOC_ ones mean it ran out of memory, not bad input. */
      const char *why =
          BrotliDecoderErrorString(BrotliDecoderGetErrorCode(dec));
      if (strncmp(why, "_ERROR_ALLOC_", 13) == 0) {
        sqlite3_result_error_nomem(ctx);
        goto done;
      }
      if (strncmp(why, "_ERROR_", 7) == 0) why += 7;
      result_errorf(ctx, "%s: invalid Brotli stream (%s)%s", DECODE_NAME, why,
                    dict ? "; it may need a different dictionary"
                         : "; it may need a dictionary");
    }
    goto done;
  }
  buffer_result(ctx, &out, (sqlite3_uint64)(nextOut - out.a));

done:
  sqlite3_free(out.a);
  BrotliDecoderDestroyInstance(dec);
}

/*
** The entry point SQLite derives from the file name sqlite-brotli.so: it
** keeps the letters and adds "sqlite3_" and "_init".
*/
#if defined(__GNUC__) || defined(__clang__)
__attribute__((visibility("default")))
#endif
int sqlite3_sqlitebrotli_init(
    sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi) {
  /* Deterministic: the same arguments always give the same bytes.
  ** Innocuous: no side effects, so views, triggers, CHECK constraints and
  ** generated columns can use them with trusted_schema off, which the
  ** sqlite3 shell sets. */
  const int flags =
      SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS;
  EncoderCache *cache;
  int rc = SQLITE_OK;
  int nArg;
  (void)pzErrMsg;
  SQLITE_EXTENSION_INIT2(pApi);

  cache = sqlite3_malloc64(sizeof(*cache));
  if (cache == 0) return SQLITE_NOMEM;
  memset(cache, 0, sizeof(*cache));
  /* One reference per registration; each one's destructor drops one. The
  ** count starts at 4 so a failed registration, which also calls the
  ** destructor, leaves the others' references intact. */
  cache->nRef = 4;
  for (nArg = 1; nArg <= 4; nArg++) {
    int r = sqlite3_create_function_v2(db, ENCODE_NAME, nArg, flags, cache,
                                       encode_func, 0, 0,
                                       encoder_cache_release);
    if (r != SQLITE_OK && rc == SQLITE_OK) rc = r;
  }
  for (nArg = 1; nArg <= 2 && rc == SQLITE_OK; nArg++) {
    rc = sqlite3_create_function_v2(db, DECODE_NAME, nArg, flags, 0,
                                    decode_func, 0, 0, 0);
  }
  if (rc != SQLITE_OK) {
    /* SQLite unloads the library when this returns an error, so remove
    ** every registration rather than leave some pointing into it. Passing
    ** no callbacks deletes a function and runs its destructor. */
    for (nArg = 1; nArg <= 4; nArg++) {
      sqlite3_create_function_v2(db, ENCODE_NAME, nArg, flags, 0, 0, 0, 0, 0);
    }
    for (nArg = 1; nArg <= 2; nArg++) {
      sqlite3_create_function_v2(db, DECODE_NAME, nArg, flags, 0, 0, 0, 0, 0);
    }
  }
  return rc;
}
