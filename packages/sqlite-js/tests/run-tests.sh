#!/usr/bin/env bash
#
# Acceptance tests for the sqlite-js extension (ADFA-7081).
#
# Runs in Code on the Go's terminal with the sqlite, sqlite-js and
# sqlite-brotli packages installed, and on a Linux host against a local build.
#
# Usage: bash run-tests.sh
#
# Environment:
#   SQLITE3     the sqlite3 shell to test                 (default: sqlite3)
#   EXT         the extension, as given to .load          (default: sqlite-js)
#   BROTLI_EXT  sqlite-brotli, as given to .load, for AC12 (default: sqlite-brotli)
#   README      the README whose sql examples to run      (default: found next
#               to this script, installed or in the source tree)
#
# Prints TAP. Exits 0 only if every test passes. AC numbers are those of the
# acceptance criteria in ADFA-7081.

set -u

SQLITE3=${SQLITE3:-sqlite3}
EXT=${EXT:-sqlite-js}
BROTLI_EXT=${BROTLI_EXT:-sqlite-brotli}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

usage() {
	sed -n '3,19s/^# \{0,1\}//p' "$0"
}

while getopts h opt; do
	case $opt in
	h)
		usage
		exit 0
		;;
	*)
		usage >&2
		exit 2
		;;
	esac
done

# Installed, the README is in $PREFIX/share/doc/sqlite-js and this script in
# $PREFIX/share/sqlite-js; in the source tree, the README is one level up.
if [[ -z ${README:-} ]]; then
	for c in "$SCRIPT_DIR/../doc/sqlite-js/README.md" "$SCRIPT_DIR/../README.md"; do
		if [[ -f $c ]]; then
			README=$c
			break
		fi
	done
fi

# Relative paths must survive the cd into the work directory.
abs_path() {
	if [[ $1 == */* && $1 != /* ]]; then
		printf '%s/%s' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"
	else
		printf '%s' "$1"
	fi
}
EXT=$(abs_path "$EXT")
BROTLI_EXT=$(abs_path "$BROTLI_EXT")
[[ -n ${README:-} ]] && README=$(abs_path "$README")

# As an SQL string literal.
sql_str() {
	printf "'%s'" "${1//\'/\'\'}"
}

# As a sqlite3 shell dot-command argument: in double quotes, the shell reads
# backslash escapes.
dot_arg() {
	local s=${1//\\/\\\\}
	printf '"%s"' "${s//\"/\\\"}"
}

LOAD_EXT=".load $(dot_arg "$EXT")"
LOAD_BROTLI=".load $(dot_arg "$BROTLI_EXT")"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sqlite-js-tests.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1
DB=$WORK/test.db

n=0
failed=0
# Microseconds; the locale may make the decimal separator a comma.
last=${EPOCHREALTIME//[!0-9]/}

# Sets took to the seconds since the previous test finished, to spot slow
# tests on a phone. Not run in $(...): a subshell could not update last.
took=
elapsed() {
	local now=${EPOCHREALTIME//[!0-9]/} tenths
	tenths=$(((now - last) / 100000))
	took="$((tenths / 10)).$((tenths % 10)) s"
	last=$now
}

ok() {
	n=$((n + 1))
	elapsed
	echo "ok $n - $1 ($took)"
}

not_ok() {
	n=$((n + 1))
	failed=$((failed + 1))
	elapsed
	echo "not ok $n - $1 ($took)"
	shift
	local line
	for line in "$@"; do
		printf '#   %s\n' "${line:0:400}"
	done
}

note() {
	printf '# %s\n' "$*"
}

# Runs SQL against $DB in a new session, with the extension loaded. Every
# session starts without the functions created in earlier ones.
sql() {
	"$SQLITE3" -bail -batch -noheader -cmd "$LOAD_EXT" "$DB" "$@"
}

# The same, but going on after an error, as an interactive session does. The
# SQL goes in on standard input: sqlite3 exits at the first error in an SQL
# argument, -bail or not.
sql_nobail() {
	printf '%s\n' "$@" | "$SQLITE3" -batch -noheader -cmd "$LOAD_EXT" "$DB"
}

# expect NAME WANT SQL...: the SQL must succeed and print exactly WANT.
expect() {
	local name=$1 want=$2 got rc
	shift 2
	got=$(sql "$@" 2>&1)
	rc=$?
	if [[ $rc -eq 0 && $got == "$want" ]]; then
		ok "$name"
	else
		not_ok "$name" "exit status $rc" "want: $want" "got:  $got"
	fi
}

# expect_error NAME PATTERN SQL...: the SQL must fail with an SQL error whose
# message matches the extended regex PATTERN. The shell exits with the SQLite
# result code; 128 and up means a signal, a crash.
expect_error() {
	local name=$1 pattern=$2 got rc
	shift 2
	got=$(sql "$@" 2>&1)
	rc=$?
	if [[ $rc -ge 1 && $rc -lt 128 && $got =~ $pattern ]]; then
		ok "$name"
	else
		not_ok "$name" "exit status $rc, want 1 to 127" "want an error matching: $pattern" "got: $got"
	fi
}

# expect_nobail NAME PATTERN SQL...: like sql_nobail, the output (errors
# included) must match the extended regex PATTERN, and the shell must not
# crash.
expect_nobail() {
	local name=$1 pattern=$2 got rc
	shift 2
	got=$(sql_nobail "$@" 2>&1)
	rc=$?
	if [[ $rc -lt 128 && $got =~ $pattern ]]; then
		ok "$name"
	else
		not_ok "$name" "exit status $rc" "want output matching: $pattern" "got: $got"
	fi
}

# Starts the SQL in the background, sends SIGINT, as Ctrl-C does, after a
# second, and expects the statement to fail as interrupted within 5 seconds.
# sqlite3 is started directly, not through sql(), so that $! is its process.
expect_sigint_stops() {
	local name=$1 pid i rc got
	shift
	"$SQLITE3" -bail -batch -noheader -cmd "$LOAD_EXT" "$DB" "$@" >sigint.out 2>&1 &
	pid=$!
	sleep 1
	kill -INT "$pid" 2>/dev/null
	for ((i = 0; i < 50; i++)); do
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.1
	done
	if kill -0 "$pid" 2>/dev/null; then
		kill -KILL "$pid" 2>/dev/null
		wait "$pid" 2>/dev/null
		not_ok "$name" "still running 5 s after SIGINT; killed"
		return
	fi
	wait "$pid"
	rc=$?
	got=$(<sigint.out)
	if [[ $rc -ge 1 && $rc -lt 128 && $got =~ interrupted ]]; then
		ok "$name"
	else
		not_ok "$name" "exit status $rc, want 1 to 127" "got: $got"
	fi
}

note "sqlite3: $(command -v "$SQLITE3") $("$SQLITE3" --version | cut -d' ' -f1)"
note "extension: $EXT"

# --- AC1: the extension loads and registers its functions --------------------

expect "AC1: loads with .load in a fresh session; function_list shows its functions" \
	"js_create_aggregate|4;js_create_collation|2;js_create_scalar|2;js_create_window|6;js_eval|1;js_init_table|0,1;js_load_blob|1;js_load_text|1;js_set_max_stack_size|1;js_set_memory_limit|1;js_version|0,1" \
	"SELECT group_concat(f, ';') FROM (SELECT name || '|' || group_concat(narg, ',') AS f FROM (SELECT DISTINCT name, narg FROM pragma_function_list WHERE name LIKE 'js\_%' ESCAPE '\\' ORDER BY name, narg) GROUP BY name ORDER BY name);"

expect "loading the extension twice in one session is harmless" "2" \
	"$LOAD_EXT" "SELECT js_eval('1 + 1');"

# --- AC2: the engine is quickjs-ng --------------------------------------------

expect "AC2: js_version() is the sqlite-js version, 1.3.7" "1.3.7" "SELECT js_version();"
got=$(sql "SELECT js_version(1);" 2>&1)
# Bellard's QuickJS has no version function, so sqlite-js does not build with it.
if [[ $got =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	ok "AC2: js_version(1) reports the quickjs-ng version"
	note "quickjs-ng $got"
else
	not_ok "AC2: js_version(1) reports the quickjs-ng version" "got: $got"
fi

# --- AC3: scalar, aggregate, window and collation functions ------------------
#
# First the README's examples, as written: each ```sql block runs in a session
# of its own, and its "-- result" comments are the last lines it must print.

if [[ -n ${README:-} && -f $README ]]; then
	note "README: $README"
	rm -f example*.sql
	awk '/^```sql$/ { n++; on = 1; next } /^```$/ { on = 0 } on { print > ("example" n ".sql") }' "$README"
	examples=0
	for f in example*.sql; do
		[[ -f $f ]] || continue
		examples=$((examples + 1))
		want=$(grep -o -- '-- .*$' "$f" | sed 's/^-- //')
		lines=$(printf '%s\n' "$want" | wc -l)
		got=$(sql "$(<"$f")" 2>&1)
		rc=$?
		first=$(grep -m1 -o 'js_create_[a-z]*(.[a-z_]*\|js_eval' "$f")
		if [[ $rc -eq 0 && -n $want && $(printf '%s\n' "$got" | tail -n "$lines") == "$want" ]]; then
			ok "AC3: README example ${f//[!0-9]/} ($first...) prints what it says"
		else
			not_ok "AC3: README example ${f//[!0-9]/} ($first...) prints what it says" \
				"exit status $rc" "want (last lines): $want" "got: $got"
		fi
	done
	[[ $examples -ge 5 ]] || not_ok "AC3: the README has at least 5 sql examples" "found $examples in $README"
else
	not_ok "AC3: README examples" "README not found; set README"
fi

MEDIAN="SELECT js_create_aggregate('median', 'values = [];', '(function (args) { values.push(args[0]); })', '(function () { values.sort((a, b) => a - b); const m = values.length >> 1; return values.length % 2 ? values[m] : (values[m - 1] + values[m]) / 2; })');"
expect "AC3: an aggregate keeps the state of each group apart (GROUP BY)" $'0\na|2\nb|25\nc|7' \
	"$MEDIAN" \
	"WITH v(g, x) AS (VALUES ('a', 1), ('b', 10), ('a', 3), ('c', 7), ('b', 40), ('a', 2))
	 SELECT g, median(x) FROM v GROUP BY g ORDER BY g;"

expect "AC3: two aggregates of one function in one query keep separate state" $'0\n2|20' \
	"$MEDIAN" \
	"WITH v(x, y) AS (VALUES (1, 10), (2, 20), (3, 30)) SELECT median(x), median(y) FROM v;"

expect "AC3: a window function over partitions" $'0\na:1 a:3 a:5 b:10 b:30' \
	"SELECT js_create_window('moving_sum', 'total = 0;', '(function (args) { total += args[0]; })', '(function () { return total; })', '(function () { return total; })', '(function (args) { total -= args[0]; })');" \
	"WITH v(g, x) AS (VALUES ('a', 1), ('a', 2), ('a', 3), ('b', 10), ('b', 20))
	 SELECT group_concat(g || ':' || s, ' ') FROM (
	   SELECT g, moving_sum(x) OVER (PARTITION BY g ORDER BY x ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS s
	   FROM v ORDER BY g, x);"

expect "AC3: a collation orders a column, its index and a UNIQUE constraint" $'0\na bb ccc\n1' \
	"SELECT js_create_collation('nocase_js', '(function (a, b) { return a.toLowerCase().localeCompare(b.toLowerCase()); })');" \
	"CREATE TEMP TABLE words (w TEXT COLLATE nocase_js UNIQUE); INSERT INTO words VALUES ('bb'), ('ccc'), ('a');" \
	"SELECT group_concat(w, ' ') FROM (SELECT w FROM words ORDER BY w);" \
	"SELECT count(*) FROM words WHERE w = 'BB';"

expect_error "AC3: the collation's UNIQUE index rejects a duplicate that differs in case" "UNIQUE constraint failed" \
	"SELECT js_create_collation('nocase_js', '(function (a, b) { return a.toLowerCase().localeCompare(b.toLowerCase()); })');" \
	"CREATE TEMP TABLE words (w TEXT COLLATE nocase_js UNIQUE); INSERT INTO words VALUES ('bb');" \
	"INSERT INTO words VALUES ('BB');"

expect "AC3: scalar functions and js_eval share the session's globals" $'3\n0\n5' \
	"SELECT js_eval('globalThis.base = 3');" \
	"SELECT js_create_scalar('add_base', '(function (args) { return base + args[0]; })');" \
	"SELECT add_base(2);"

# --- AC4: stored functions load in a new session ----------------------------

DB=$WORK/ac4.db
sql "SELECT js_init_table();" \
	"SELECT js_create_scalar('twice', '(function (args) { return args[0] * 2; })');" \
	"$MEDIAN" \
	"SELECT js_create_window('moving_sum', 'total = 0;', '(function (args) { total += args[0]; })', '(function () { return total; })', '(function () { return total; })', '(function (args) { total -= args[0]; })');" \
	"SELECT js_create_collation('by_length', '(function (a, b) { return a.length - b.length || a.localeCompare(b); })');" \
	>/dev/null 2>&1 || not_ok "AC4: store four functions with js_init_table()"
expect "AC4: js_functions holds the four functions" "by_length|collation;median|aggregate;moving_sum|window;twice|scalar" \
	"SELECT group_concat(name || '|' || kind, ';') FROM (SELECT name, kind FROM js_functions ORDER BY name);"
expect_error "AC4: a new session does not have them before js_init_table(1)" "no such function: twice" \
	"SELECT twice(21);"
expect "AC4: js_init_table(1) in a new session creates all four" $'0\n42|2|1 3 5|a bb ccc' \
	"SELECT js_init_table(1);" \
	"WITH v(x) AS (VALUES (1), (2), (3)), w(s) AS (VALUES ('ccc'), ('a'), ('bb'))
	 SELECT twice(21),
	        (SELECT median(x) FROM v),
	        (SELECT group_concat(s, ' ') FROM (SELECT moving_sum(x) OVER (ORDER BY x ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS s FROM v)),
	        (SELECT group_concat(s, ' ') FROM (SELECT s FROM w ORDER BY s COLLATE by_length));"
expect_error "AC4: a function cannot be redefined in the session that created it" \
	"Function updates must be performed using a separate database connection" \
	"SELECT js_init_table(1);" \
	"SELECT js_create_scalar('twice', '(function (args) { return args[0] * 3; })');"
expect "AC4: a new session can redefine it, and stores the new code" $'0\n63' \
	"SELECT js_create_scalar('twice', '(function (args) { return args[0] * 3; })');" \
	"SELECT twice(21);"
DB=$WORK/test.db

# --- AC5: JavaScript errors are SQL errors -----------------------------------

expect_error "AC5: an exception thrown by js_eval is an SQL error with its message" "boom" \
	"SELECT js_eval('throw new Error(\"boom\")');"
expect_error "AC5: a reference to an undefined name is an SQL error" "undefined_name is not defined" \
	"SELECT js_eval('undefined_name + 1');"
expect_error "AC5: a syntax error in js_eval is an SQL error" "SyntaxError|expected|unexpected" \
	"SELECT js_eval('function (');"
expect_error "AC5: an exception in a scalar function is an SQL error" "scalar boom" \
	"SELECT js_create_scalar('fails', '(function (args) { throw new Error(\"scalar boom\"); })');" \
	"SELECT fails(1);"
expect_error "AC5: an exception in an aggregate step is an SQL error" "step boom" \
	"SELECT js_create_aggregate('agg_fails', 'n = 0;', '(function (args) { throw new Error(\"step boom\"); })', '(function () { return n; })');" \
	"WITH v(x) AS (VALUES (1), (2)) SELECT agg_fails(x) FROM v;"
expect_error "AC5: an exception in a window function's inverse is an SQL error" "inverse boom" \
	"SELECT js_create_window('inverse_fails', 'total = 0;', '(function (args) { total += args[0]; })', '(function () { return total; })', '(function () { return total; })', '(function (args) { throw new Error(\"inverse boom\"); })');" \
	"WITH v(x) AS (VALUES (1), (2), (3)) SELECT inverse_fails(x) OVER (ORDER BY x ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM v;"
expect_error "AC5: code with a syntax error does not create a function" "SyntaxError|expected|unexpected" \
	"SELECT js_create_scalar('broken', '(function (args) { return args[0] +; })');"
expect_error "AC5: code that is not a function does not create one" "must evaluate to a function" \
	"SELECT js_create_scalar('not_a_function', '42');"
expect_error "AC5: js_create_scalar with non-TEXT arguments is an SQL error" "Two parameters of type TEXT are required" \
	"SELECT js_create_scalar(1, 2);"
expect_error "AC5: js_eval with a non-TEXT argument is an SQL error" "A parameter of type TEXT is required" \
	"SELECT js_eval(NULL);"

# --- AC6: values pass correctly in both directions -------------------------

IDENTITY="SELECT js_create_scalar('identity', '(function (args) { return args[0]; })');"
JSTYPE="SELECT js_create_scalar('jstype', '(function (args) { const v = args[0]; return v === null ? \"null\" : v instanceof ArrayBuffer ? \"ArrayBuffer\" : typeof v; })');"
expect "AC6: SQL values reach JavaScript with the right type and come back unchanged" \
	$'0\n0\nnull:null:1 number:integer:1 number:integer:1 number:integer:1 number:integer:1 number:integer:1 number:integer:1 number:real:1 number:real:1 number:real:1 string:text:1 string:text:1 string:text:1 ArrayBuffer:blob:1 ArrayBuffer:blob:1 ArrayBuffer:blob:1' \
	"$IDENTITY" "$JSTYPE" \
	"WITH v(x) AS (VALUES (NULL), (0), (42), (-7), (2147483648), (-2147483649), (9007199254740991), (3.5), (-0.25), (1e300),
	                      ('plain'), ('Grüße aus Zürich — 世界 ✓ 😀'), (''), (x'00ff10'), (x''), (randomblob(100000)))
	 SELECT group_concat(jstype(x) || ':' || typeof(identity(x)) || ':' || (identity(x) IS x), ' ') FROM v;"
expect "AC6: JavaScript results reach SQL with the right type" \
	"1|0|4611686018427387904|X'010203'|X'0203'|X'0708'|NULL|{\"a\":1}|NULL|5|real" \
	"SELECT quote(js_eval('true')), quote(js_eval('false')), quote(js_eval('2n ** 62n')),
	        quote(js_eval('new Uint8Array([1, 2, 3])')), quote(js_eval('new Uint8Array([1, 2, 3]).subarray(1)')),
	        quote(js_eval('new Uint8Array([7, 8]).buffer')), quote(js_eval('({a: 1})')),
	        js_eval('JSON.stringify({a: 1})'), quote(js_eval('undefined')), quote(js_eval('2.5 * 2')),
	        typeof(js_eval('0.1 + 0.2'));"
expect "AC6: a function can make a BLOB from a BLOB" $'0\nX\'030201\'' \
	"SELECT js_create_scalar('reverse_bytes', '(function (args) { return new Uint8Array(args[0]).reverse(); })');" \
	"SELECT quote(reverse_bytes(x'010203'));"
expect "AC6: text passes byte for byte, non-ASCII included" $'0\n0\n1|1|1' \
	"$IDENTITY" \
	"SELECT js_create_scalar('js_length', '(function (args) { return args[0].length; })');" \
	"SELECT identity('Grüße 世界 😀') = 'Grüße 世界 😀', js_length('Grüße 世界') = 8, length(identity('😀')) = 1;"
expect "AC6: as documented, a whole REAL comes back as an INTEGER, and an INTEGER beyond 2^53 - 1 as a REAL" $'0\n3|real' \
	"$IDENTITY" "SELECT quote(identity(3.0)), typeof(identity(9007199254740993));"
expect "AC6: as documented, an INTEGER passed as TEXT keeps every digit with BigInt" $'0\n9223372036854775807' \
	"SELECT js_create_scalar('big_next', '(function (args) { return BigInt(args[0]) + 1n; })');" \
	"SELECT big_next(CAST(9223372036854775806 AS TEXT));"
expect "AC6: db.exec passes parameters and returns rows with the same conversions" \
	"integer,real,text,blob,null|X'0102'" \
	"SELECT js_eval('(function () {
	   const r = db.exec(\"SELECT typeof(?), typeof(?), typeof(?), typeof(?), typeof(?)\", 2147483648, 2.5, \"x\", new Uint8Array([1]), null);
	   r.next();
	   return [0, 1, 2, 3, 4].map(i => r.get(i)).join();
	 })()'), quote(js_eval('(function () { const r = db.exec(\"SELECT x''0102''\"); r.next(); return r.get(0); })()'));"
printf 'line one\nline two ✓\n' >loadme.txt
expect "js_load_text and js_load_blob read a file" "line one|X'6C696E65206F6E650A6C696E652074776F20E29C930A'" \
	"SELECT substr(js_load_text($(sql_str "$WORK/loadme.txt")), 1, 8), quote(js_load_blob($(sql_str "$WORK/loadme.txt")));"

# --- AC7: the crash cases fixed in 1.3.6 are SQL errors ----------------------

DB=$WORK/ac7.db
JS_FUNCTIONS="CREATE TABLE js_functions (name TEXT PRIMARY KEY COLLATE NOCASE, kind TEXT NOT NULL, init_code TEXT, step_code TEXT, final_code TEXT, value_code TEXT, inverse_code TEXT);"
rm -f "$DB"
expect_error "AC7: a stored scalar with NULL step_code is an SQL error, not a crash" "step code is required" \
	"$JS_FUNCTIONS" "INSERT INTO js_functions (name, kind) VALUES ('no_code', 'scalar');" "SELECT js_init_table(1);"
rm -f "$DB"
expect_error "AC7: a stored aggregate with NULL final_code is an SQL error, not a crash" "final code is required" \
	"$JS_FUNCTIONS" "INSERT INTO js_functions (name, kind, step_code) VALUES ('no_final', 'aggregate', '(function (args) {})');" "SELECT js_init_table(1);"
rm -f "$DB"
expect_error "AC7: a stored function of an unknown kind is an SQL error" "Unsupported function kind" \
	"$JS_FUNCTIONS" "INSERT INTO js_functions (name, kind, step_code) VALUES ('odd', 'procedure', '(function (args) {})');" "SELECT js_init_table(1);"
rm -f "$DB"
expect_error "AC7: a js_functions table with other columns is an SQL error, not a crash" "no such column" \
	"CREATE TABLE js_functions (name TEXT, kind TEXT);" "INSERT INTO js_functions VALUES ('f', 'scalar');" "SELECT js_init_table(1);"
rm -f "$DB"
expect_error "AC7: stored code that is not a function is an SQL error" "must evaluate to a function" \
	"$JS_FUNCTIONS" "INSERT INTO js_functions (name, kind, step_code) VALUES ('not_fn', 'scalar', '42');" "SELECT js_init_table(1);"
DB=$WORK/test.db

# --- AC8: Ctrl-C stops runaway JavaScript -----------------------------------

expect_sigint_stops "AC8: SIGINT (Ctrl-C) stops while (true) {} in js_eval" \
	"SELECT js_eval('while (true) {}');"
expect_sigint_stops "AC8: SIGINT stops an endless scalar function" \
	"SELECT js_create_scalar('forever', '(function (args) { for (;;) {} })');" "SELECT forever(1);"
expect_sigint_stops "AC8: SIGINT stops code that catches every exception" \
	"SELECT js_eval('for (;;) { try { while (true) {} } catch (e) {} }');"

# In batch mode the shell exits after an interrupt, whatever stopped; only an
# interactive session goes on. script(1) runs one on a pseudo-terminal, where
# the byte 0x03 is Ctrl-C.
if command -v script >/dev/null 2>&1; then
	cmd=$(printf '%q ' "$SQLITE3" -noheader -cmd "$LOAD_EXT" "$DB")
	got=$({
		sleep 1
		printf '%s\n' "SELECT js_eval('while (true) {}');"
		sleep 2
		printf '\003'
		sleep 1
		printf '%s\n' "SELECT 'still' || ' alive';"
		sleep 1
		printf '.quit\n'
	} | timeout 30 script -q -c "$cmd" /dev/null 2>&1 | tr -d '\r')
	if [[ $got == *interrupted* && $got == *"still alive"* ]]; then
		ok "AC8: in an interactive session, Ctrl-C stops while (true) {} and sqlite3 keeps running"
	else
		not_ok "AC8: in an interactive session, Ctrl-C stops while (true) {} and sqlite3 keeps running" "got: $got"
	fi
else
	not_ok "AC8: in an interactive session, Ctrl-C stops while (true) {} and sqlite3 keeps running" \
		"needs script(1); install util-linux"
fi

# --- AC9: the memory limit ------------------------------------------------------

expect "AC9: the default limit allows 16 MB" "16777216" \
	"SELECT js_eval('new ArrayBuffer(16 * 1024 * 1024).byteLength');"
expect_error "AC9: the default limit (64 MB) refuses 128 MB" "out of memory" \
	"SELECT js_eval('new ArrayBuffer(128 * 1024 * 1024).byteLength');"
expect_nobail "AC9: code that never stops allocating fails at the limit, and the session stays usable" \
	"out of memory.*"$'\n'"1,2,3$" \
	"SELECT js_eval('(function () { const a = []; for (;;) a.push(new Array(100000).fill(1)); })()');" \
	"SELECT js_eval('[1, 2, 3].join()');"
expect_nobail "AC9: memory held by a global counts until the global is cleared" \
	"out of memory.*"$'\n'"16777216$" \
	"SELECT js_eval('globalThis.keep = new ArrayBuffer(60 * 1024 * 1024); 0');" \
	"SELECT js_eval('new ArrayBuffer(16 * 1024 * 1024).byteLength');" \
	"SELECT js_eval('keep = null; new ArrayBuffer(16 * 1024 * 1024).byteLength');"
# js_set_memory_limit returns NULL, which prints as an empty line.
expect "AC9: js_set_memory_limit raises the limit" $'\n134217728' \
	"SELECT js_set_memory_limit(256 * 1024 * 1024);" \
	"SELECT js_eval('new ArrayBuffer(128 * 1024 * 1024).byteLength');"
expect_error "AC9: js_set_memory_limit lowers the limit" "out of memory" \
	"SELECT js_set_memory_limit(8 * 1024 * 1024);" \
	"SELECT js_eval('new ArrayBuffer(16 * 1024 * 1024).byteLength');"
for bad in -1 1.5 "'64'" NULL; do
	expect_error "AC9: js_set_memory_limit($bad) is an SQL error" "The memory limit must be an integer number of bytes" \
		"SELECT js_set_memory_limit($bad);"
done

# --- AC10: a database cannot run JavaScript from its schema ----------------------

# The database is made without the extension, as someone else's would be.
rm -f untrusted.db
"$SQLITE3" -bail -batch untrusted.db "
CREATE TABLE t (a);
CREATE TABLE log (msg);
CREATE VIEW v_eval AS SELECT js_eval('6 * 7') AS x;
CREATE VIEW v_load AS SELECT js_load_text('/proc/self/status') AS x;
CREATE VIEW v_init AS SELECT js_init_table(1) AS x;
CREATE TRIGGER t_insert AFTER INSERT ON t BEGIN INSERT INTO log VALUES (js_eval('\"trigger ran\"')); END;
" || not_ok "AC10: create a database with JavaScript in its schema"
DB=$WORK/untrusted.db
for trusted in "sqlite3's default" ON; do
	if [[ $trusted == ON ]]; then pragma="PRAGMA trusted_schema = ON;"; else pragma="SELECT 1 WHERE 0;"; fi
	for view_function in v_eval:js_eval v_load:js_load_text v_init:js_init_table; do
		expect_error "AC10: a view cannot call ${view_function#*:} (trusted_schema $trusted)" "unsafe use of ${view_function#*:}" \
			"$pragma" "SELECT x FROM ${view_function%%:*};"
	done
	expect_error "AC10: a trigger cannot call js_eval (trusted_schema $trusted)" "unsafe use of js_eval" \
		"$pragma" "INSERT INTO t VALUES (1);"
done
expect "AC10: so the trigger never ran" "0" "SELECT count(*) FROM log;"
# The view is in the database file: SQLite trusts the TEMP schema, which only
# the session itself can fill.
DB=$WORK/views.db
"$SQLITE3" -bail -batch "$DB" "CREATE VIEW v_twice AS SELECT twice(21) AS x;" ||
	not_ok "AC10: create a view that uses a function made with js_create_scalar"
TWICE="SELECT js_create_scalar('twice', '(function (args) { return args[0] * 2; })');"
expect "AC10: with trusted_schema ON, a view can use a function made with js_create_scalar" $'0\n42' \
	"PRAGMA trusted_schema = ON;" "$TWICE" "SELECT x FROM v_twice;"
expect_error "AC10: with sqlite3's default (trusted_schema off), it cannot" "unsafe use of twice" \
	"$TWICE" "SELECT x FROM v_twice;"
DB=$WORK/test.db

# --- AC11: no file or process access through the std or os modules ------------

expect "AC11: std, os and bjson are not globals; neither are require or process" "undefined undefined undefined undefined undefined" \
	"SELECT js_eval('[typeof std, typeof os, typeof bjson, typeof require, typeof process].join(\" \")');"
expect "AC11: import(\"os\") never completes" $'1\npending' \
	"SELECT js_eval('globalThis.r = \"pending\"; import(\"os\").then(m => { r = \"loaded: \" + typeof m.exec; }, e => { r = \"rejected\"; }); 1');" \
	"SELECT js_eval('r');"
printf 'globalThis.moduleRan = true;\nexport const x = 1;\n' >module.mjs
expect "AC11: import() of a module file never runs it" $'1\nfalse' \
	"SELECT js_eval('import(\"./module.mjs\"); 1');" "SELECT js_eval('String(globalThis.moduleRan === true)');"

# --- AC12: sqlite-js and sqlite-brotli load together ---------------------------

if "$SQLITE3" -bail -batch :memory: "$LOAD_BROTLI" "SELECT 1;" >/dev/null 2>&1; then
	BOTH="SELECT CAST(decodeBrotli(encodeBrotli(js_eval('\"ab\".repeat(5000)'))) AS TEXT) = js_eval('\"ab\".repeat(5000)'),
	        js_eval('(function () { const r = db.exec(\"SELECT length(decodeBrotli(encodeBrotli(?)))\", \"hello\"); r.next(); return r.get(0); })()');"
	expect "AC12: sqlite-js, then sqlite-brotli: both work in one session" "1|5" "$LOAD_BROTLI" "$BOTH"
	got=$("$SQLITE3" -bail -batch -noheader -cmd "$LOAD_BROTLI" -cmd "$LOAD_EXT" "$DB" "$BOTH" 2>&1)
	if [[ $got == "1|5" ]]; then
		ok "AC12: sqlite-brotli, then sqlite-js: both work in one session"
	else
		not_ok "AC12: sqlite-brotli, then sqlite-js: both work in one session" "got: $got"
	fi
else
	not_ok "AC12: sqlite-js and sqlite-brotli load together" \
		"cannot load $BROTLI_EXT; install the sqlite-brotli package or set BROTLI_EXT"
fi

echo "1..$n"
if [[ $failed -ne 0 ]]; then
	echo "# FAILED $failed of $n"
	exit 1
fi
echo "# passed all $n"
