# sqlite-brotli

A SQLite loadable extension that adds two functions, for maintaining databases
that store Brotli-compressed content, such as Code on the Go's
`documentation.db` (ADFA-6635).

```text
encodeBrotli(data [, dictionary [, quality [, lgwin]]])  -> BLOB
decodeBrotli(data [, dictionary])                         -> BLOB
```

## Load it

```text
$ sqlite3 documentation.db
sqlite> .load sqlite-brotli
```

If `.load sqlite-brotli` reports that it cannot find the file, give the full
path, which `echo $PREFIX/lib/sqlite-brotli` prints. (`.load` does not expand
`$PREFIX` itself.)

To have the functions in every `sqlite3` session, put the `.load` line in
`~/.sqliterc`:

```text
$ echo ".load $PREFIX/lib/sqlite-brotli" >> ~/.sqliterc
```

## Arguments

| Argument     | Meaning                                                              |
|--------------|----------------------------------------------------------------------|
| `data`       | BLOB or TEXT to compress; BLOB to decompress. NULL returns NULL.     |
| `dictionary` | BLOB with a raw (LZ77 prefix) dictionary. NULL or omitted: none.     |
| `quality`    | INTEGER from 0 to 11. NULL or omitted: 11.                           |
| `lgwin`      | INTEGER from 10 to 24, base-2 log of the window size. NULL or omitted: 22. |

- The dictionary is the same kind `brotli -D FILE` and brotli4j's
  `PreparedDictionary` use, so data moves freely between this extension, the
  `brotli` tool and the app.
- TEXT is compressed as its bytes in the database's encoding, the bytes
  `CAST(x AS BLOB)` gives. `decodeBrotli` always returns a BLOB, so compare
  decoded text with `CAST(decodeBrotli(...) AS TEXT)`.
- Invalid arguments, corrupt or truncated input, and trailing bytes after the
  stream are SQL errors. So is a decoded result over SQLite's length limit
  (`SQLITE_LIMIT_LENGTH`, 1,000,000,000 bytes by default).
- Code on the Go's documentation pipeline encodes with quality 11 and
  `lgwin` 24. Pass both to match it: `encodeBrotli(x, dict, 11, 24)`.

## Decode with the dictionary the data was encoded with

A Brotli stream carries no checksum and no record of its dictionary. Decoding
with no dictionary, or the wrong one, usually fails with an SQL error, but can
succeed and return wrong bytes. Measured on the 23,094 Brotli rows of a
documentation database (2026-11-09):

| Decoded with                                      | SQL error | Correct | Wrong, no error |
|---------------------------------------------------|----------:|--------:|----------------:|
| its own dictionary                                |         0 |  23,094 |               0 |
| no dictionary                                     |    23,091 |       3 |               0 |
| another database version's dictionary (same size) |    18,317 |       3 |           4,774 |

The reverse also holds: data encoded without a dictionary can decode wrongly
when one is supplied. A scalar subquery that finds no row gives NULL, which
means "no dictionary", so check that the dictionary row exists before a bulk
`INSERT ... SELECT encodeBrotli(...)`.

## Examples

Decode a row to a file, using the custom dictionary:

```sql
SELECT WRITEFILE('foo.html',
                 decodeBrotli(C.content, CD.data))
FROM   Content AS C,
       CompressionDictionary AS CD
WHERE  C.id = 1234
  AND  CD.id = 1;
```

Encode a file into a row, using the custom dictionary:

```sql
INSERT INTO Content (path, languageId, contentTypeId, templateId, content)
VALUES ('q/x.html', 1, 12, 0,
        encodeBrotli(READFILE('q/x.html'),
                     (SELECT data FROM CompressionDictionary WHERE id = 1)));
```

Encode with the built-in dictionary only, at explicit quality and window size:

```sql
SELECT encodeBrotli(READFILE('q/x.html'), NULL, 11, 22);
```

## Tests

The package installs its acceptance tests. They need the `sqlite` and
`brotli` packages:

```text
$ bash $PREFIX/share/sqlite-brotli/run-tests.sh
$ bash $PREFIX/share/sqlite-brotli/run-tests.sh -d path/to/documentation.db
```

`-d` also decodes every Brotli row of a documentation database. Run with `-h`
for the other options.
