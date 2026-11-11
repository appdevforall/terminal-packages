#!/usr/bin/env bash
#
# Acceptance tests for the sqlite-brotli extension (ADFA-6635).
#
# Runs in Code on the Go's terminal with the sqlite, brotli and sqlite-brotli
# packages installed, and on a Linux host against a local build.
#
# Usage: bash run-tests.sh [-d DOCS_DB] [-x HELLO_EXT]
#
#   -d DOCS_DB    Also decode every Brotli row of this documentation database
#                 with its CompressionDictionary. Opened read-only.
#   -x HELLO_EXT  Also load this hello-world extension and call hello().
#
# Environment:
#   SQLITE3  the sqlite3 shell to test           (default: sqlite3)
#   BROTLI   the brotli command-line tool        (default: brotli)
#   EXT      the extension, as given to .load    (default: sqlite-brotli)
#
# Prints TAP. Exits 0 only if every test passes.

set -u

SQLITE3=${SQLITE3:-sqlite3}
BROTLI=${BROTLI:-brotli}
EXT=${EXT:-sqlite-brotli}
DOCS_DB=
HELLO_EXT=
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

usage() {
	sed -n '3,19s/^# \{0,1\}//p' "$0"
}

while getopts d:x:h opt; do
	case $opt in
	d) DOCS_DB=$(cd "$(dirname "$OPTARG")" && pwd)/$(basename "$OPTARG") ;;
	x) HELLO_EXT=$(cd "$(dirname "$OPTARG")" && pwd)/$(basename "$OPTARG") ;;
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

# A relative extension path must survive the cd into the work directory.
if [[ $EXT == */* && $EXT != /* ]]; then
	EXT=$(cd "$(dirname "$EXT")" && pwd)/$(basename "$EXT")
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sqlite-brotli-tests.XXXXXX") || exit 1
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

# Runs SQL against the test database, with the extension loaded.
sql() {
	"$SQLITE3" -bail -batch -noheader -cmd ".load '$EXT'" "$DB" "$@"
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
# result code (1, or 18 for SQLITE_TOOBIG); 128 and up means a signal, a crash.
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

# expect_cmd NAME COMMAND...: the command must succeed.
expect_cmd() {
	local name=$1 got rc
	shift
	got=$("$@" 2>&1)
	rc=$?
	if [[ $rc -eq 0 ]]; then
		ok "$name"
	else
		not_ok "$name" "exit status $rc" "command: $*" "output: $got"
	fi
}

note "sqlite3: $(command -v "$SQLITE3") $("$SQLITE3" --version | cut -d' ' -f1)"
note "brotli:  $(command -v "$BROTLI") $("$BROTLI" --version 2>&1)"
note "extension: $EXT"

# --- Acceptance criterion 1: the hello-world extension loads ----------------

if [[ -n $HELLO_EXT ]]; then
	got=$("$SQLITE3" -bail -batch :memory: ".load '$HELLO_EXT'" "SELECT hello();" 2>&1)
	if [[ $got == "Hello, world" ]]; then
		ok "AC1: hello-world extension loads and hello() runs"
	else
		not_ok "AC1: hello-world extension loads and hello() runs" "got: $got"
	fi
else
	note "AC1 skipped: no -x HELLO_EXT given"
fi

# --- Acceptance criterion 2: the extension loads and registers both ---------

expect "AC2: loads in a fresh session; function_list shows both functions" \
	"decodebrotli|1,2;encodebrotli|1,2,3,4" \
	"SELECT group_concat(f, ';') FROM (SELECT name || '|' || group_concat(narg, ',') AS f FROM (SELECT name, narg FROM pragma_function_list WHERE name IN ('encodebrotli', 'decodebrotli') ORDER BY name, narg) GROUP BY name ORDER BY name);"

expect "loading the extension twice in one session is harmless" "1" \
	".load '$EXT'" "SELECT decodeBrotli(encodeBrotli('x', x'0102030405060708')) IS NOT NULL;"

# --- Test data ---------------------------------------------------------------
#
# d is 192 KiB of random hex text. "dictionary text" copies two long runs out
# of it, so the encoder must reference the dictionary, and the first run sits
# so far back in the dictionary that no decoder can resolve it without d.

sql "
CREATE TABLE dicts (name TEXT PRIMARY KEY, d BLOB NOT NULL);
INSERT INTO dicts VALUES
  ('d',        CAST(hex(randomblob(98304)) AS BLOB)),
  ('other',    CAST(hex(randomblob(65536)) AS BLOB)),
  ('same len', CAST(hex(randomblob(98304)) AS BLOB));

CREATE TABLE inputs (name TEXT PRIMARY KEY, big INTEGER NOT NULL, x);
INSERT INTO inputs VALUES
  ('text',        0, 'The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog.'),
  ('unicode',     0, 'Grüße aus Zürich — 世界 ✓ ünïcödé'),
  ('empty text',  0, ''),
  ('empty blob',  0, x''),
  ('one byte',    0, x'00'),
  ('binary',      0, randomblob(4096)),
  ('zeros',       0, zeroblob(100000)),
  ('256 KiB hex text',        0, hex(randomblob(131072))),
  ('3 MiB random binary',     1, randomblob(3145728)),
  ('4 MiB hex text',          1, hex(randomblob(2097152))),
  ('5 MB repeated text',      1, printf('%.*c', 5000000, 'a'));
INSERT INTO inputs
  SELECT 'dictionary text', 0,
         CAST(substr(d, 1, 30000) || ' new text ' || substr(d, 120001, 30000) AS BLOB)
  FROM dicts WHERE name = 'd';
" || {
	echo "Bail out! could not create the test database"
	exit 1
}

# --- Acceptance criterion 3: round trip without a dictionary ----------------

expect "AC3: decodeBrotli(encodeBrotli(x)) = x for every input" \
	"$(sql "SELECT count(*) FROM inputs;")" \
	"SELECT count(*) FROM inputs WHERE decodeBrotli(encodeBrotli(x)) = CAST(x AS BLOB);"

expect "AC3: text round-trips to identical text after CAST AS TEXT" "1|1" \
	"SELECT CAST(decodeBrotli(encodeBrotli(x)) AS TEXT) = x, typeof(decodeBrotli(encodeBrotli(x))) = 'blob' FROM inputs WHERE name = 'unicode';"

expect "AC3: empty input decodes to an empty blob, not NULL" "X''|X''" \
	"SELECT quote(decodeBrotli(encodeBrotli(x''))), quote(decodeBrotli(encodeBrotli('')));"

expect "compressible input gets smaller" "1" \
	"SELECT length(encodeBrotli(x)) * 100 < length(x) FROM inputs WHERE name = '5 MB repeated text';"

# --- Acceptance criterion 4: round trip with the custom dictionary ----------

expect "AC4: decodeBrotli(encodeBrotli(x, d), d) = x for every input" \
	"$(sql "SELECT count(*) FROM inputs;")" \
	"SELECT count(*) FROM inputs, dicts WHERE dicts.name = 'd' AND decodeBrotli(encodeBrotli(x, d), d) = CAST(x AS BLOB);"

expect "AC4: the dictionary is used (dictionary text compresses much better with it)" "1" \
	"SELECT length(encodeBrotli(x, d)) * 10 < length(encodeBrotli(x)) FROM inputs, dicts WHERE inputs.name = 'dictionary text' AND dicts.name = 'd';"

expect "a statement that alternates dictionaries round-trips every row" "40" \
	"WITH RECURSIVE i(k) AS (SELECT 1 UNION ALL SELECT k + 1 FROM i WHERE k < 40),
	 e AS (SELECT k, D.d AS d, encodeBrotli(x, D.d) AS c FROM i, inputs, dicts D
	       WHERE inputs.name = 'dictionary text' AND D.name = CASE k % 2 WHEN 0 THEN 'd' ELSE 'other' END)
	 SELECT count(*) FROM e, inputs WHERE inputs.name = 'dictionary text' AND decodeBrotli(c, d) = x;"

# --- Acceptance criterion 5: decoding needs the encoding dictionary --------

expect_error "AC5: data encoded with d, decoded without a dictionary, is an SQL error" \
	"decodeBrotli: invalid Brotli stream" \
	"SELECT decodeBrotli(encodeBrotli(x, d)) FROM inputs, dicts WHERE inputs.name = 'dictionary text' AND dicts.name = 'd';"

expect_error "AC5: data encoded with d, decoded with NULL dictionary, is an SQL error" \
	"decodeBrotli: invalid Brotli stream" \
	"SELECT decodeBrotli(encodeBrotli(x, d), NULL) FROM inputs, dicts WHERE inputs.name = 'dictionary text' AND dicts.name = 'd';"

expect_error "AC5: data encoded with d, decoded with a different, shorter dictionary, is an SQL error" \
	"decodeBrotli: invalid Brotli stream" \
	"SELECT decodeBrotli(encodeBrotli(x, D1.d), D2.d) FROM inputs, dicts D1, dicts D2 WHERE inputs.name = 'dictionary text' AND D1.name = 'd' AND D2.name = 'other';"

# A Brotli stream carries no checksum and no dictionary id. A different
# dictionary of the same length gives the decoder valid bytes at every offset
# the stream references, so it can return wrong output without an error. AC5
# (amended 2026-11-10) asks only that this never crashes and that it usually
# errors, so accept an SQL error or a result, and report which.
got=$(sql "SELECT CASE WHEN decodeBrotli(encodeBrotli(x, D1.d), D2.d) = x THEN 'same output' ELSE 'wrong output, no error' END FROM inputs, dicts D1, dicts D2 WHERE inputs.name = 'dictionary text' AND D1.name = 'd' AND D2.name = 'same len';" 2>&1)
rc=$?
if [[ ($rc -eq 0 && $got =~ ^(same output|wrong output, no error)$) ||
	($rc -ge 1 && $rc -lt 128 && $got =~ decodeBrotli:) ]]; then
	ok "AC5: data encoded with d, decoded with a different dictionary of the same length, does not crash"
	note "decoding with a different dictionary of the same length gave: $got"
else
	not_ok "AC5: data encoded with d, decoded with a different dictionary of the same length, does not crash" \
		"exit status $rc" "got: $got"
fi

# --- Acceptance criterion 6: invalid input is an SQL error ------------------

expect_error "AC6: random bytes are an SQL error" "decodeBrotli: (invalid Brotli stream|the Brotli stream is truncated|.*trailing data)" \
	"SELECT decodeBrotli(x'deadbeefdeadbeefdeadbeef');"
expect_error "AC6: 64 KiB of random bytes are an SQL error" "decodeBrotli: " \
	"SELECT decodeBrotli(randomblob(65536));"
expect_error "AC6: a truncated stream is an SQL error" "decodeBrotli: the Brotli stream is truncated" \
	"SELECT decodeBrotli(substr(encodeBrotli(x), 1, 1000)) FROM inputs WHERE name = '4 MiB hex text';"
expect_error "AC6: trailing bytes after the stream are an SQL error" "decodeBrotli: 3 bytes of trailing data" \
	"SELECT decodeBrotli(CAST(encodeBrotli('abc') || x'010203' AS BLOB));"
expect_error "AC6: an empty blob is an SQL error" "decodeBrotli: data is empty" \
	"SELECT decodeBrotli(x'');"
expect_error "AC6: a stream with an invalid header byte is an SQL error" "decodeBrotli: invalid Brotli stream \\(FORMAT_WINDOW_BITS\\)" \
	"SELECT decodeBrotli(CAST(x'11' || substr(encodeBrotli(x), 2) AS BLOB)) FROM inputs WHERE name = 'text';"

# One changed byte can leave a stream valid but different, since Brotli has
# no checksum, so a corrupted stream may decode without an error. What must
# never happen is a crash. The stream is of this script: varied text gives
# varied Brotli codes, where random hex mostly gives fixed-length literal
# codes that any byte change leaves valid. (|| yields TEXT, hence the CASTs.)
sql "CREATE TABLE corrupt AS SELECT encodeBrotli(readfile('$SELF')) AS c;"
corrupt_len=$(sql "SELECT length(c) FROM corrupt;")
corrupt_errors=0
corrupt_decoded=0
corrupt_crashes=0
for ((i = 0; i < 40; i++)); do
	off=$((1 + i * (corrupt_len - 1) / 40))
	sql "SELECT length(decodeBrotli(CAST(substr(c, 1, $off - 1) || CASE WHEN substr(c, $off, 1) = x'ff' THEN x'00' ELSE x'ff' END || substr(c, $off + 1) AS BLOB))) FROM corrupt;" >/dev/null 2>&1
	rc=$?
	if [[ $rc -eq 0 ]]; then
		corrupt_decoded=$((corrupt_decoded + 1))
	elif [[ $rc -lt 128 ]]; then
		corrupt_errors=$((corrupt_errors + 1))
	else
		corrupt_crashes=$((corrupt_crashes + 1))
	fi
done
if [[ $corrupt_crashes -eq 0 ]]; then
	ok "AC6: 40 one-byte corruptions spread over a stream never crash ($corrupt_errors SQL errors, $corrupt_decoded decoded)"
else
	not_ok "AC6: 40 one-byte corruptions spread over a stream never crash" "$corrupt_crashes crashed"
fi
expect_error "decodeBrotli rejects TEXT data" "decodeBrotli: data must be a blob" \
	"SELECT decodeBrotli('abc');"
expect_error "decodeBrotli rejects INTEGER data" "decodeBrotli: data must be a blob" \
	"SELECT decodeBrotli(42);"
expect_error "encodeBrotli rejects INTEGER data" "encodeBrotli: data must be a blob or text" \
	"SELECT encodeBrotli(42);"
expect_error "encodeBrotli rejects REAL data" "encodeBrotli: data must be a blob or text" \
	"SELECT encodeBrotli(4.2);"
expect_error "a TEXT dictionary is an SQL error" "encodeBrotli: dictionary must be a blob or NULL" \
	"SELECT encodeBrotli('abc', 'dictionary');"
expect_error "an empty dictionary is an SQL error (encode)" "encodeBrotli: dictionary must not be empty" \
	"SELECT encodeBrotli('abc', x'');"
expect_error "an empty dictionary is an SQL error (decode)" "decodeBrotli: dictionary must not be empty" \
	"SELECT decodeBrotli(encodeBrotli('abc'), x'');"
# The encoded blob is made before the limit is lowered: zeroblob() would hit
# the limit itself and never reach the decoder.
sql "CREATE TABLE bomb AS SELECT encodeBrotli(zeroblob(2000000)) AS c;"
# .limit prints the new limit on a line of its own, straight to stdout.
got=$(sql ".limit length 3000000" "SELECT length(decodeBrotli(c)) FROM bomb;" 2>&1)
rc=$?
if [[ $rc -eq 0 && ${got##*$'\n'} == 2000000 ]]; then
	ok "a decoded size under SQLITE_LIMIT_LENGTH decodes (control for the next test)"
else
	not_ok "a decoded size under SQLITE_LIMIT_LENGTH decodes (control for the next test)" "exit status $rc" "got: $got"
fi
expect_error "a decoded size over SQLITE_LIMIT_LENGTH is an SQL error, not an allocation" \
	"string or blob too big" \
	".limit length 1000000" "SELECT length(c) < 1000, length(decodeBrotli(c)) FROM bomb;"
expect_error "decodeBrotli with three arguments is a prepare error" "wrong number of arguments to function decodeBrotli" \
	"SELECT decodeBrotli(x'00', NULL, 1);"
expect_error "encodeBrotli with five arguments is a prepare error" "wrong number of arguments to function encodeBrotli" \
	"SELECT encodeBrotli('a', NULL, 11, 22, 0);"

# --- Acceptance criterion 7: NULL handling ----------------------------------

expect "AC7: NULL data returns NULL from both functions" "null|null|null|null" \
	"SELECT typeof(encodeBrotli(NULL)), typeof(encodeBrotli(NULL, x'0102', 5, 20)), typeof(decodeBrotli(NULL)), typeof(decodeBrotli(NULL, x'0102'));"
expect "AC7: a NULL or omitted dictionary means the built-in dictionary only" "1|1|1" \
	"SELECT encodeBrotli(x) = encodeBrotli(x, NULL), decodeBrotli(encodeBrotli(x)) = decodeBrotli(encodeBrotli(x), NULL), encodeBrotli(x, NULL) = encodeBrotli(x, NULL, 11, 22) FROM inputs WHERE name = 'text';"
expect "NULL quality or lgwin means the default" "1|1" \
	"SELECT encodeBrotli(x, NULL, NULL) = encodeBrotli(x, NULL, 11), encodeBrotli(x, NULL, 5, NULL) = encodeBrotli(x, NULL, 5, 22) FROM inputs WHERE name = 'text';"

# --- Acceptance criterion 8: quality and lgwin ------------------------------

for name in "dictionary text" "binary" "256 KiB hex text"; do
	expect "AC8: '$name' round-trips at every quality 0-11 x lgwin 10/16/22/24, with and without d" "96" \
		"WITH RECURSIVE q(v) AS (SELECT 0 UNION ALL SELECT v + 1 FROM q WHERE v < 11),
		 w(v) AS (VALUES (10), (16), (22), (24)),
		 dd(d) AS (SELECT NULL UNION ALL SELECT d FROM dicts WHERE name = 'd')
		 SELECT count(*) FROM q, w, dd, inputs
		 WHERE inputs.name = '$name' AND decodeBrotli(encodeBrotli(x, dd.d, q.v, w.v), dd.d) = CAST(x AS BLOB);"
done
expect "AC8: quality changes the output (0 and 11 differ)" "1" \
	"SELECT encodeBrotli(x, NULL, 0) <> encodeBrotli(x, NULL, 11) FROM inputs WHERE name = '4 MiB hex text';"
expect "AC8: lgwin changes the output (10 and 24 differ)" "1" \
	"SELECT encodeBrotli(x, NULL, 11, 10) <> encodeBrotli(x, NULL, 11, 24) FROM inputs WHERE name = '4 MiB hex text';"
for bad in -1 12 4294967307; do
	expect_error "AC8: quality $bad is an SQL error" "encodeBrotli: quality $bad is out of range; it must be from 0 to 11" \
		"SELECT encodeBrotli('abc', NULL, $bad);"
done
for bad in 9 25 -22; do
	expect_error "AC8: lgwin $bad is an SQL error" "encodeBrotli: lgwin $bad is out of range; it must be from 10 to 24" \
		"SELECT encodeBrotli('abc', NULL, 11, $bad);"
done
for bad in "'11'" "11.0" "x'0b'"; do
	expect_error "AC8: quality $bad (not an INTEGER) is an SQL error" "encodeBrotli: quality must be an integer from 0 to 11" \
		"SELECT encodeBrotli('abc', NULL, $bad);"
	expect_error "AC8: lgwin $bad (not an INTEGER) is an SQL error" "encodeBrotli: lgwin must be an integer from 10 to 24" \
		"SELECT encodeBrotli('abc', NULL, 11, $bad);"
done

# --- Acceptance criterion 9: interoperability with the brotli tool ---------

if command -v "$BROTLI" >/dev/null 2>&1; then
	sql "SELECT writefile('d.dict', d) FROM dicts WHERE name = 'd';" >/dev/null
	for name in "dictionary text" "unicode" "binary" "empty blob" "4 MiB hex text" "3 MiB random binary"; do
		f=$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_')
		sql "SELECT writefile('$f.in', CAST(x AS BLOB)),
		            writefile('$f.ext.br', encodeBrotli(x)),
		            writefile('$f.ext-d.br', encodeBrotli(x, d, 9, 18))
		     FROM inputs, dicts WHERE inputs.name = '$name' AND dicts.name = 'd';" >/dev/null
		rm -f "$f.out" "$f.out-d"
		"$BROTLI" -d -o "$f.out" "$f.ext.br" && "$BROTLI" -d -D d.dict -o "$f.out-d" "$f.ext-d.br" &&
			cmp -s "$f.in" "$f.out" && cmp -s "$f.in" "$f.out-d"
		if [[ $? -eq 0 ]]; then
			ok "AC9: brotli -d decodes encodeBrotli output of '$name', with and without -D"
		else
			not_ok "AC9: brotli -d decodes encodeBrotli output of '$name', with and without -D"
		fi
		"$BROTLI" -f -q 11 -w 24 -o "$f.cli.br" "$f.in" && "$BROTLI" -f -q 11 -w 24 -D d.dict -o "$f.cli-d.br" "$f.in"
		expect "AC9: decodeBrotli decodes brotli output of '$name', with and without -D" "1|1" \
			"SELECT decodeBrotli(readfile('$f.cli.br')) = readfile('$f.in'), decodeBrotli(readfile('$f.cli-d.br'), readfile('d.dict')) = readfile('$f.in');"
	done
	expect "AC9: encodeBrotli at q11 w24 with d produces the same bytes as brotli -q 11 -w 24 -D" "1" \
		"SELECT encodeBrotli(readfile('dictionary_text.in'), readfile('d.dict'), 11, 24) = readfile('dictionary_text.cli-d.br');"
else
	not_ok "AC9: interoperability" "$BROTLI not found; install the brotli package"
fi

# --- Optional: every Brotli row of a real documentation database -----------

if [[ -n $DOCS_DB ]]; then
	# Content over 1 MiB is split across rows named path, path-1, ...; the
	# pieces are not complete streams, so the rows of chunked content are
	# left out. SQLite may evaluate WHERE terms in any order, and may flatten a
	# subquery into its parent, so the rows are picked in a MATERIALIZED CTE
	# first: otherwise decodeBrotli can run on rows the other terms exclude.
	# The dictionary stays out of r, which would otherwise store a copy of it
	# in every row; the uncorrelated scalar subquery dict is evaluated once.
	dict="(SELECT data FROM docs.CompressionDictionary WHERE id = 1)"
	rows="
	  heads AS MATERIALIZED (SELECT path FROM docs.Content WHERE length(content) = 1048576),
	  r AS MATERIALIZED (
	    SELECT C.content
	    FROM docs.Content C
	    JOIN docs.ContentTypes T ON T.id = C.contentTypeID
	    WHERE T.compression = 'brotli'
	      AND length(C.content) < 1048576
	      AND NOT EXISTS (SELECT 1 FROM heads H WHERE C.path GLOB H.path || '-[0-9]*'))"
	attach="ATTACH 'file:$DOCS_DB?mode=ro' AS docs;"
	total=$(sql "$attach" "WITH $rows SELECT count(*) FROM r;")
	expect "documentation database: all $total Brotli rows decode with its dictionary" "$total" \
		"$attach" "WITH $rows SELECT count(*) FROM r WHERE decodeBrotli(content, $dict) IS NOT NULL;"
	expect "documentation database: 50 rows re-encoded at q11 w24 with its dictionary round-trip" "50" \
		"$attach" "WITH $rows SELECT count(*) FROM (SELECT decodeBrotli(content, $dict) AS x FROM r LIMIT 50) WHERE decodeBrotli(encodeBrotli(x, $dict, 11, 24), $dict) = x;"
fi

# --- Acceptance criterion 10: the ticket's examples, as written -------------

rm -f "$DB"
mkdir -p q
printf '<!doctype html>\n<title>x</title>\n<p>Example page for ADFA-6635.</p>\n' >q/x.html
sql "
CREATE TABLE Content (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL,
        languageID INTEGER NOT NULL,
        content BLOB NOT NULL,
        contentTypeID INTEGER NOT NULL,
        templateId INTEGER NOT NULL DEFAULT 0,
        UNIQUE(path)
    );
CREATE TABLE CompressionDictionary (
    id   INTEGER PRIMARY KEY CHECK (id = 1),
    data BLOB NOT NULL
);
INSERT INTO CompressionDictionary VALUES (1, CAST(hex(randomblob(4096)) AS BLOB));
INSERT INTO Content (id, path, languageID, content, contentTypeID)
  SELECT 1234, 'p/foo.html', 1, encodeBrotli('<p>foo ' || hex(substr(data, 1, 200)) || '</p>', data), 12
  FROM CompressionDictionary;
" || not_ok "AC10: create the example database"

expect "AC10: example 1 (decode a row to a file) runs as written" "$(sql "SELECT length(decodeBrotli(C.content, CD.data)) FROM Content C, CompressionDictionary CD WHERE C.id = 1234 AND CD.id = 1;")" "
SELECT WRITEFILE('foo.html',
                 decodeBrotli(C.content, CD.data))
FROM   Content AS C,
       CompressionDictionary AS CD
WHERE  C.id = 1234
  AND  CD.id = 1;"
expect "AC10: example 1 wrote the decoded row" "1" \
	"SELECT readfile('foo.html') = decodeBrotli(C.content, CD.data) AND readfile('foo.html') LIKE '<p>foo %' FROM Content C, CompressionDictionary CD WHERE C.id = 1234 AND CD.id = 1;"

expect "AC10: example 2 (encode a file into a row) runs as written" "" "
INSERT INTO Content (
  path,
  languageId,
  contentTypeId,
  templateId,
  content
)
VALUES (
  'q/x.html',
  1,
  12,
  0,
  encodeBrotli(READFILE('q/x.html'),
               (SELECT data
                FROM   CompressionDictionary
                WHERE  id = 1))
);"
expect "AC10: example 2's row decodes to the file" "1" \
	"SELECT decodeBrotli(content, (SELECT data FROM CompressionDictionary WHERE id = 1)) = readfile('q/x.html') FROM Content WHERE path = 'q/x.html';"

expect_cmd "AC10: example 3 (built-in dictionary, explicit quality and window) runs as written" \
	"$SQLITE3" -bail -batch -noheader -cmd ".load '$EXT'" "$DB" \
	"SELECT encodeBrotli(READFILE('q/x.html'), NULL, 11, 22);"
expect "AC10: example 3's output decodes to the file" "1" \
	"SELECT decodeBrotli(encodeBrotli(READFILE('q/x.html'), NULL, 11, 22)) = readfile('q/x.html');"

echo "1..$n"
if [[ $failed -ne 0 ]]; then
	echo "# FAILED $failed of $n"
	exit 1
fi
echo "# passed all $n"
