# sqlite-js

A SQLite loadable extension for writing SQL functions in JavaScript: scalar
functions, aggregates, window functions and collations (ADFA-7081). It is
[sqliteai/sqlite-js](https://github.com/sqliteai/sqlite-js) 1.4.1, the first
release with nine changes of ours, plus four patches of ours, all listed
[below](#changes-in-this-build). The JavaScript engine,
[quickjs-ng](https://github.com/quickjs-ng/quickjs) 0.12.1, is built in.

## Load it

```text
$ sqlite3 my.db
sqlite> .load sqlite-js
```

If `.load sqlite-js` reports that it cannot find the file, give the full path,
which `echo $PREFIX/lib/sqlite-js` prints. (`.load` does not expand `$PREFIX`
itself.)

Load it in the sessions that need it, rather than in `~/.sqliterc`, so that
running a database's stored JavaScript stays a deliberate step: see
[Databases from other people](#databases-from-other-people).

## Examples

A scalar function returns one value per row. Its code is a function that gets
the SQL arguments as an array:

```sql
SELECT js_create_scalar('slugify', '(function (args) {
  return args[0].toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
})');
SELECT slugify('Hello, World!');                      -- hello-world
```

An aggregate takes code to run before the first row, a function to call for
each row, and a function that returns the result:

```sql
SELECT js_create_aggregate('median',
  'values = [];',
  '(function (args) { values.push(args[0]); })',
  '(function () {
     values.sort((a, b) => a - b);
     const m = values.length >> 1;
     return values.length % 2 ? values[m] : (values[m - 1] + values[m]) / 2;
   })');
WITH v(x) AS (VALUES (3), (1), (4), (1), (5))
SELECT median(x) FROM v;                              -- 3
```

A window function also takes a function that returns the current result and
one that removes a row that leaves the window:

```sql
SELECT js_create_window('moving_sum',
  'total = 0;',
  '(function (args) { total += args[0]; })',
  '(function () { return total; })',
  '(function () { return total; })',
  '(function (args) { total -= args[0]; })');
WITH v(x) AS (VALUES (1), (2), (3), (4))
SELECT group_concat(s, ' ') FROM (
  SELECT moving_sum(x) OVER (ORDER BY x ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS s
  FROM v);                                            -- 1 3 5 7
```

A collation compares two strings, like a JavaScript sort comparator:

```sql
SELECT js_create_collation('by_length', '(function (a, b) {
  return a.length - b.length || a.localeCompare(b);
})');
WITH v(s) AS (VALUES ('ccc'), ('a'), ('bb'))
SELECT group_concat(s, ' ') FROM (SELECT s FROM v ORDER BY s COLLATE by_length);  -- a bb ccc
```

`js_eval` runs code and returns its value. In JavaScript, `db.exec` runs SQL
on the same database, with `?` parameters:

```sql
SELECT js_eval('[1, 2, 3].map(x => x * x).join(" ")');   -- 1 4 9
SELECT js_eval('(function () {
  const rows = db.exec("SELECT ? * 2 AS doubled", 21);
  rows.next();
  return rows.get(0);
})()');                                               -- 42
```

`db.exec` returns a result set, and the statement runs as `next()` or
`toArray()` steps it, so call `next()` once to run an `INSERT` or another
statement that returns no rows. An SQL error, while the statement is prepared
or while it runs, is a JavaScript exception.

## Functions

| Function | What it does |
|----------|--------------|
| `js_create_scalar(name, code)` | Creates a scalar function. |
| `js_create_aggregate(name, init, step, final)` | Creates an aggregate. `init` is code; `step` and `final` are functions. |
| `js_create_window(name, init, step, final, value, inverse)` | Creates a window function. |
| `js_create_collation(name, code)` | Creates a collation. |
| `js_eval(code)` | Runs code; returns the value of its last expression. |
| `js_init_table()` | Creates the `js_functions` table. From then on, `js_create_*` also stores each function there. |
| `js_init_table(1)` | Also creates every function stored in `js_functions`. |
| `js_load_text(path)`, `js_load_blob(path)` | Return a file's contents as TEXT or as a BLOB. |
| `js_set_memory_limit(bytes)` | Sets the memory JavaScript may use on this connection; 0 means no limit. |
| `js_set_max_stack_size(bytes)` | Sets JavaScript's stack limit, at most what the thread's stack allows (the error gives the largest size). 0 turns the check off; deep recursion then crashes `sqlite3`. |
| `js_version()`, `js_version(1)` | The sqlite-js version, or with an argument, the quickjs-ng version. |

The functions you create last for the session. To keep them, call
`js_init_table()` before creating them, then `js_init_table(1)` in a later
session. A function cannot be redefined in the session that created it; use a
new session.

All but `js_version` work only in top-level SQL, not in views, triggers, CHECK
constraints, generated columns or indexes stored in a database. (TEMP views and
triggers can call them: SQLite trusts them, since only the session can make
them.) The functions you create have no
such restriction of their own, but `sqlite3` turns `trusted_schema` off, which
keeps them out of a database's views and triggers as well (TEMP ones excepted); run
`PRAGMA trusted_schema = ON;` in a session to use them there. The collations
you create work in table and index definitions either way.

## Values

SQL values reach JavaScript as follows:

| SQL | JavaScript |
|-----|------------|
| NULL | `null` |
| INTEGER, REAL | number |
| TEXT | string |
| BLOB | `ArrayBuffer` |

A result goes back to SQL as follows: `null` and `undefined` become NULL, a
boolean an INTEGER (1 or 0), a whole number from -(2^53 - 1) to 2^53 - 1 an
INTEGER and any other number a REAL, a BigInt an INTEGER, a string TEXT, and an
`ArrayBuffer` or a typed array such as `Uint8Array` a BLOB. Other objects
become NULL; return `JSON.stringify(value)` to keep one as TEXT. The parameters
of `db.exec` convert the same way.

JavaScript has a single number type, a double. So a REAL that holds a whole
number, such as 3.0, comes back as the INTEGER 3, and an INTEGER beyond
±(2^53 - 1) loses precision in JavaScript. To keep such an INTEGER exact, pass
it as TEXT, `CAST(x AS TEXT)`, and convert it with `BigInt(args[0])`.

## JavaScript here

- quickjs-ng runs modern JavaScript (ES2023 and later), with no browser or
  Node.js APIs: no `fetch`, `require`, `setTimeout`, DOM or `process`.
- Promises never settle and `async` functions never finish, because nothing
  runs JavaScript's job queue. Write synchronous code.
- JavaScript has no file, network or process functions of its own. Through
  `db.exec` it can run any SQL, including `js_load_text` and the shell's
  `readfile()` and `writefile()`.
- `console.log` and `print` write to `sqlite3`'s standard output, among the
  query results.
- Each session has its own JavaScript globals, shared by `js_eval` and the
  scalar functions and collations you create. Each running aggregate or window
  function gets globals of its own, set up by its `init` code.

## Limits

- **Memory.** JavaScript may use 64 MB per session. Code that needs more fails
  with an "out of memory" error, and the session stays usable. JavaScript that
  catches the error receives `null` instead when the limit leaves no room even
  for the error. Garbage is collected after the error, so code that failed
  because garbage filled the limit works when run again.
  `js_set_memory_limit` changes the limit, and collects garbage. Memory that
  globals still hold counts against the limit until they are cleared, so a
  limit under it leaves no room for any JavaScript until it is raised again.
- **Endless code.** Ctrl-C stops running JavaScript: the statement fails with
  an "interrupted" error, even if the code catches exceptions, and `sqlite3`
  keeps running. A `db.exec` result set that the stopped code kept, in a
  global say, is ended: reading on from it fails with "interrupted".
- **Stack.** 1 MB by default, or less on a thread with less stack;
  `js_set_max_stack_size` changes it. Code that calls itself too deeply fails
  with "Maximum call stack size exceeded".
- **Collations that fail.** A collation that throws an exception, or runs out
  of memory, compares the two strings as equal. `ORDER BY` then returns a
  wrong order rather than an error, so keep collation code simple.

## Databases from other people

A database can store JavaScript in its `js_functions` table, and
`js_init_table(1)` runs it with your access. Through `db.exec` it can run any
SQL: read and change every attached database and, in `sqlite3`, read and write
your files with `readfile()` and `writefile()` and load other extensions. Call
`js_init_table(1)` only on databases you trust.

Nothing else in a database runs JavaScript on its own: views, triggers, CHECK
constraints and generated columns cannot call `js_eval` or the other
`js_*` functions (see [changes](#changes-in-this-build)), and `sqlite3` turns
`trusted_schema` off as well.

## Changes in this build

Upstream released nine changes of ours in 1.4.0. Compared with 1.3.7:

| Upstream PR | Change |
|-------------|--------|
| #11 | Ctrl-C and `sqlite3_interrupt()` stop running JavaScript. In 1.3.7, endless code hangs `sqlite3`. |
| #12 | A 64 MB memory limit, and `js_set_memory_limit`. In 1.3.7, code that keeps allocating takes all the memory there is. |
| #13 | `js_eval` and the other functions that run code, read files or change the runtime work only in top-level SQL (and TEMP views and triggers). In 1.3.7, with `trusted_schema` on, a view can call them. |
| #14 | A result that is an `ArrayBuffer` or typed array is a BLOB, and `db.exec` binds one as a BLOB or throws if it cannot read it. In 1.3.7, a result is NULL, so a BLOB cannot pass through a function. |
| #15 | A whole-number result is an INTEGER. In 1.3.7, an INTEGER outside the 32-bit range comes back as a REAL. |
| #16 | An exception in an aggregate's or window function's step is an SQL error. In 1.3.7, it is ignored, and the result is silently wrong. |
| #17 | The JavaScript stack size stays within the thread's stack: `js_set_max_stack_size` refuses text and larger sizes, and the default shrinks on a small stack. In 1.3.7, those make endless recursion crash `sqlite3`. |
| #18 | An SQL error while a `db.exec` statement runs is an exception from `next()` or `toArray()`. In 1.3.7, `next()` returns `false` as at the end of the rows, and `toArray()` returns the rows before the error, so a failed write looks like success. |
| #19 | The stack check follows the thread each call runs on. In 1.3.7, JavaScript run on a thread other than the one that set up the connection fails at once, or crashes on endless recursion. |

This build adds four patches of ours, offered upstream:

| Patch | Upstream PR | Change |
|-------|-------------|--------|
| 0001 | #22 | The stack check stays within the stack in two more cases. In 1.4.1, endless recursion crashes on a thread with less than 64 KB of stack left, or on a main thread whose stack was first measured deep down. Neither happens in `sqlite3`, which runs JavaScript on its main thread and loads the extension near the top of its stack. |
| 0002 | #23 | Garbage is collected after any "out of memory" error and whenever the limit is set. In 1.4.1, garbage can make code that fits in the limit fail with "out of memory" every time: an allocation too large to fit, or one made after the limit was lowered to above the memory in use. |
| 0003, 0004 | #24 | After an interrupt, the `db.exec` result sets the stopped code left open are ended, and reading on from one fails with "interrupted". In 1.4.1, Ctrl-C during code that keeps one open, in a global say, leaves every later statement in the session failing with "interrupted". |

The build also exports only the extension's entry points, and adds the one
SQLite derives from the file name, so that `.load sqlite-js` needs no entry
point argument.

## Tests

```text
$ bash $PREFIX/share/sqlite-js/run-tests.sh
```

They print TAP and exit 0 only if every test passes. Two tests need other
packages and are skipped without them: `sqlite-brotli`, to check that both
extensions load together, and `util-linux`, whose `script` drives an
interactive `sqlite3` to check that Ctrl-C leaves it running. The last line
says how many were skipped.

## License

sqlite-js is under the Apache License 2.0 and quickjs-ng under the MIT
License; both licenses are in `$PREFIX/share/doc/sqlite-js/`.
