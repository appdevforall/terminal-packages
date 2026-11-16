/*
** The smallest SQLite loadable extension: hello() returns 'Hello, world'.
** ADFA-6635 started with it to show that the sqlite3 shell loads extensions,
** and acceptance criterion 1 loads it: run-tests.sh -x hello.so.
**
** Build it for the machine that runs the tests, for example on Linux:
**   cc -shared -fPIC -o hello.so hello.c
** Keep the name hello.so: SQLite finds the entry point, sqlite3_hello_init,
** from the file name.
*/
#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT1

static void hello(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
  (void)argc;
  (void)argv;
  sqlite3_result_text(ctx, "Hello, world", -1, SQLITE_STATIC);
}

#if defined(__GNUC__) || defined(__clang__)
__attribute__((visibility("default")))
#endif
int sqlite3_hello_init(sqlite3 *db, char **pzErrMsg,
                       const sqlite3_api_routines *pApi) {
  (void)pzErrMsg;
  SQLITE_EXTENSION_INIT2(pApi);
  return sqlite3_create_function(db, "hello", 0,
                                 SQLITE_UTF8 | SQLITE_DETERMINISTIC, 0, hello,
                                 0, 0);
}
