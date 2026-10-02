# Zig Parslet

Three command-line tools for parsing documents with PEG grammars, testing those grammars, and transforming capture trees. Written in Zig 0.16.0 with no runtime dependencies.

```text
                         .peg + document
                                |
                    +-----------+-----------+
                    |                       |
                peg_test                peg_parse
             tests / diagnostics            |
                                          JSON
                                            |
                           .pegtx --> peg_transform
                                            |
                                       cleaned JSON
```

Inspired by [ElixirParslet](https://github.com/NigelThorne/ElixirParslet) and [Ruby Parslet](https://github.com/kschiess/parslet). This is a new implementation, not an API-compatible port.

## Build and try it

```sh
mise install
mise exec -- zig build -Doptimize=ReleaseSafe

# Grammar regression tests.
./zig-out/bin/peg_test examples/email.peg

# Parse, then transform.
./zig-out/bin/peg_parse examples/email.peg examples/email.txt |
  ./zig-out/bin/peg_transform examples/email.pegtx
# "a.b@gmail.com"

# Diagnose a document against a grammar.
printf 'a@!' | ./zig-out/bin/peg_test examples/email.peg -
```

Binaries are in `zig-out/bin`. Optional installation to your own prefix:

```sh
mise exec -- zig build -Doptimize=ReleaseSafe --prefix "$HOME/.local"
```

Use `mise exec -- zig`, not an unrelated Zig version on PATH.

## JSON round trip

```sh
./zig-out/bin/peg_test examples/json.peg
./zig-out/bin/peg_parse examples/json.peg examples/json.json |
  ./zig-out/bin/peg_transform examples/json.pegtx
```

The grammar parses JSON into a capture tree. The transform then decodes strings, converts scalar values and builds arrays and objects. It handles empty/singleton/nested containers, escaped keys, Unicode and precise numbers. Numeric tokens retain their original spelling, including large integers and long decimals. Duplicate object keys use the last value.

This example validates UTF-8 and requires paired UTF-16 surrogate escapes. It rejects raw controls, malformed escapes, invalid numbers and trailing commas. It uses explicit byte ranges for Unicode validation; the PEG engine itself remains byte-oriented. The normal parser depth/work limits still apply.

## CSV to rows

```sh
./zig-out/bin/peg_test examples/csv.peg
./zig-out/bin/peg_parse examples/csv.peg examples/csv.csv |
  ./zig-out/bin/peg_transform examples/csv.pegtx
```

The result is an array of rows, each containing strings. Quoted commas, doubled quotes and multiline cells work. LF, CRLF and CR record endings are accepted. Newlines inside quoted cells are preserved.

| Input | Result |
| --- | --- |
| Empty document | `[]` |
| One blank line | `[[]]` |
| `""` | `[[""]]` |
| `,` | `[["", ""]]` |
| `00123,false` | `[["00123", "false"]]` |

No header inference, type conversion, trimming or BOM stripping occurs. Rows may have different field counts. A final newline does not create an extra row. Quoting is strict: quotes must begin a field, and closing quotes must be followed by a delimiter, record ending or EOF. The example requires valid UTF-8.

The transform uses only existing pattern rules and `join`. No CSV-specific runtime helper is involved.

## XML to element trees

```sh
./zig-out/bin/peg_test examples/xml.peg
set -o pipefail
./zig-out/bin/peg_parse examples/xml.peg examples/xml.xml |
  ./zig-out/bin/peg_transform examples/xml.pegtx
```

This is an explicit XML subset, not a general XML parser. It supports one root element, nested and self-closing elements, mixed text, and the five predefined entities. Names use ASCII letters/underscore followed by letters, digits, underscore, dot or hyphen. Exterior XML whitespace is ignored. Text whitespace and child order are preserved; CRLF and CR normalize to LF. Literal characters must satisfy XML 1.0 and valid UTF-8.

```text
<a>Hello<b/> &amp; goodbye</a>
                 ↓
{"tag":"a","children":["Hello",{"tag":"b","children":[]}," & goodbye"]}
```

Empty elements always have `children: []`. Adjacent text fragments and decoded entities join into one string. Entity decoding happens once, so `&amp;lt;` becomes literal `&lt;`, not `<`.

Attributes, namespaces, XML declarations, processing instructions, comments, CDATA, DTDs and numeric character references are outside this subset and rejected. No external entities are loaded.

**Both stages are required for validation.** The grammar recognizes tag structure; the transform uses `require_equal` to reject unequal opening/closing names. Thus `peg_parse` alone accepts `<a></b>`, while `peg_transform` exits 1 without a partial result. Embedded grammar tests assert capture trees, not this semantic check. Mismatch diagnostics point to the transform rule, not the XML source tag.

## Commands

| Command | Input | Output |
| --- | --- | --- |
| `peg_parse grammar.peg [input|-]` | Grammar and document | JSON capture tree, or document-focused error |
| `peg_test grammar.peg` | Grammar with embedded tests | Pass/fail report, tree differences and parse diagnostics |
| `peg_test grammar.peg input` | Grammar and document | Document and grammar highlights, rule attempt trace |
| `peg_transform rules.pegtx [tree|-]` | Rules and JSON tree | Transformed JSON |

Omitted input for `peg_parse` and `peg_transform` reads stdin. Use `-` explicitly to diagnose stdin with `peg_test`. Grammar and transform definitions must be files.

Every command accepts `--help`, `--json` and `--` to end option parsing. Unknown flags are errors.

- `peg_parse` and `peg_transform` write only JSON results to stdout. Human-readable errors go to stderr.
- `peg_test` writes its human-readable report to stdout.
- `--json` selects structured reports/errors on stdout. Successful parse/transform output remains a bare JSON value.
- Exit **0** means success. **1** means parse, test or transform failure. **2** means invalid usage, grammar/rules syntax, unreadable files, malformed input JSON or a system error.
- An empty embedded test suite reports that no tests were found, with exit 0.

For shell pipelines that must fail if either command fails, enable `set -o pipefail`. Do not pipe `--json` error reports into transforms as though they were capture trees.

## Write a grammar

```peg
root greeting
greeting <- salutation:("Hello" / "Hi") " "+ who:[a-zA-Z]+ excited:"!"?
```

Input `Hi World!` produces:

```json
{"salutation":"Hi","who":"World","excited":"!"}
```

Rules start on their own line and can span multiple lines. Whitespace in the grammar separates expressions; it does not match document whitespace. `#` starts a grammar comment.

| Syntax | Meaning |
| --- | --- |
| `"text"`, `'text'` | Literal text |
| `[a-z0-9]`, `[^"]` | Byte class, or inverted class |
| `[\\x00-\\x1f]` | Hex byte range, exactly two hex digits per escape |
| `.` | Any byte |
| `name` | Rule reference |
| `a b` | Sequence |
| `a / b` | Ordered choice, first successful alternative wins |
| `(a b)` | Grouping |
| `a*`, `a+`, `a?` | Zero or more, one or more, optional |
| `!a`, `&a` | Negative/positive lookahead, consumes nothing |
| `label:a` | Named capture |

`label:[a-z]+` captures the entire repeated word. To repeat individual captures, write `(label:[a-z])+`.

Parsing must consume the entire document. Backtracking follows PEG ordered-choice semantics, not regex alternation. A choice that succeeds is not revisited merely because a later expression fails.

### Capture trees

- With no named captures, return the matched text.
- Once a sequence contains captures, discard its uncaptured text.
- Merge adjacent capture objects in a sequence. Later duplicate capture names replace earlier ones.
- Repeated captured items form arrays, including a single item. A sequence with a captured array combines its structured results in order.
- A capture around another capture wraps its existing tree rather than recovering discarded text.

See `examples/email.peg` for a nested capture tree and `.pegtx` rules that reduce it to an email address.

## Keep tests with the grammar

```peg
root greeting
greeting <- "Hi " who:[a-zA-Z]+

@test "captures the name" {
  input: "Hi World"
  expect: { who: "World" }
}

@test "rejects a missing name" {
  input: "Hi "
  reject: true
}
```

```sh
peg_test greeting.peg
# PASS captures the name: passed
# PASS rejects a missing name: passed
# 2 passed, 0 failed
```

Test values use JSON-style data with bare object keys and optional commas. Numeric literals must follow JSON number syntax, so `01`, `1.` and `1.e2` are errors. Use `\n` for newlines inside an input string. Each test requires `input` and exactly one of `expect` or `reject: true`.

To test a helper rule without matching the whole document, put its name in parentheses:

```peg
root document
document <- "Subject: " subject
subject <- subject:[A-Za-z]+
eols <- ([\r\n][ ]*)+

@test(subject) "plain subject" {
  input: "Hello"
  expect: { subject: "Hello" }
}
@test(eols) "newline and spaces" { input: "\n  " expect: "\n  " }
@test(subject) "rejects digits" { input: "123" reject: true }
```

Plain `@test "name"` still starts at the document root. `@test(rule)` starts at that rule and still requires the entire test input to match. Rules may be defined after their tests. An unknown test rule is a definition error when running embedded tests. The root declaration is still required. Human reports show `[rule]` for explicitly selected rules; JSON test reports include the effective `rule` for every test.

`expect` compares the whole capture tree, ignoring object key order. A `reject` test passes only for a document mismatch, not for a parser resource limit or broken grammar.

`peg_parse` skips balanced `@test` blocks, including `@test(rule)` blocks without resolving their target rule. Unfinished assertions inside a balanced block do not affect production parsing. An unterminated block remains a grammar syntax error because its end cannot be located.

## Transform a tree

Rules in `.pegtx` files match tree shapes and produce replacement values:

```text
{ dot: simple(d), word: simple(w) } => concat(".", w)
{ word: simple(w) } => w
{ username: sequence(parts) } => concat(join(parts), "@")
{ username: simple(name) } => concat(name, "@")
{ email: sequence(parts) } => join(parts)
```

Children transform before their parent. At each node, the **first matching rule** applies once. Unmatched nodes stay unchanged. Replacements are not recursively transformed again.

| Pattern | Matches |
| --- | --- |
| `simple(x)` | String, number, boolean or null |
| `sequence(xs)` | Array containing only scalar values |
| `subtree(x)` | Any value, including nested objects/arrays |
| `{ key: pattern }` | Object with exactly those keys |
| `[pattern, pattern]` | Array of exactly that length |
| `"text"`, `42`, `true`, `null` | Literal value |

Repeated binding names require equal values. For example, `{ left: simple(x), right: simple(x) }` only matches when both sides are equal. Number equality is representation-sensitive: an integer literal does not match a floating-point value or a token-preserving `number()` result. Use `int()` or `float()` when you need those numeric representations.

Output expressions can use bound names, literals, arrays, objects and these functions:

| Function | Result |
| --- | --- |
| `concat(a, b, ...)` | Scalar values converted to text and joined |
| `join(array[, separator])` | Scalar array joined as text, default separator `""` |
| `int(value)` | Signed 64-bit integer; rejects fractional or out-of-range values |
| `float(value)` | Finite double-precision number |
| `bool(value)` | Boolean, or conversion of `"true"`/`"false"` |
| `unquote(text)` | Decode one complete quoted JSON string, including escapes |
| `number(text)` | Validate a JSON numeric token and emit it unchanged as a number |
| `pluck(array, key)` | Extract a named field from each object, preserving order |
| `from_entries(array)` | Build an object from exact `{key: string, value: any}` entries |
| `require_equal(a, b)` | Return `a` if deeply equal to `b`; otherwise fail |

`pluck` rejects missing keys or non-object elements. `from_entries` rejects malformed entries, returns `{}` for an empty array and keeps the last value for duplicate keys. Neither operation changes its input. `unquote` rejects arrays, objects and other non-string JSON values; it does not parse whole JSON documents. `number` preserves precision rather than converting through a floating-point value. Explicit `int(number(...))` and `float(number(...))` conversions still enforce their normal limits.

`require_equal` uses the same representation-sensitive deep equality as repeated bindings, ignoring object key order. Unlike a repeated binding, unequal values cause a runtime error rather than a non-matching rule. It requires exactly two arguments.

Transform strings use JSON escapes, including Unicode escapes. Numeric literals follow JSON number syntax, including signed exponents such as `1e+2`. Object fields and function arguments require commas. `#` starts a comment. Unknown bindings/functions are errors even when their rule would not match. Rules cannot run host-language code.

## Diagnostics and limits

`peg_parse` reports the document failure location and expected alternatives. For example, `"yes" / "no"` reports `expected literal "yes" or literal "no"`. Tied failures retain up to 16 distinct expectations; repeated expectations appear once, and truncation is reported. Failures from successful choices and optional/lookahead probes do not leak into later errors. Repetition ignores normal termination at the next item's start, but retains deeper failures from incomplete items, such as an unfinished quoted CSV field.

`peg_test` also highlights the grammar expressions for those alternatives and shows a bounded trace of rule attempts. A successful attempt can later be discarded by backtracking; the trace is not a list of committed matches.

Locations use zero-based byte offsets in JSON and one-based line/byte columns in human output. Highlights escape control and non-ASCII bytes so terminal controls cannot run and carets remain aligned with byte positions.

This first version uses byte-oriented matching, not Unicode character classes. UTF-8 literals work. `.` and character classes consume bytes. There is no regex engine, left-recursion support, recovery parser, packrat memoization or performance guarantee. Recursion/work limits reject pathological parses instead of treating them as ordinary mismatches. Files/stdin are limited to 16 MiB each; grammar source has a separate 4 MiB compiler limit. The compiler limits grammar nesting to 512 and expression count to 100,000. Parsing limits expression depth to 256 and work to 1,000,000 expression visits. Transforms limit nesting to 256. The trace retains at most 1,024 attempts and human output shows the last 40 recorded.

The email example demonstrates captures and transforms. It is not an RFC-complete validator.

## Verification

```sh
mise exec -- zig fmt --check build.zig src
mise exec -- zig build test
mise exec -- zig build
python3 tests/cli_test.py
python3 tests/fuzz_test.py
```

The Python standard-library tests exercise the real executables, including stdin, pipelines, embedded tests, diagnostics, bad arguments and transform errors. JSON round trips include a reproducible 60-document generated corpus checked against Python's JSON decoder, plus malformed document, Unicode and exact numeric-token cases. CSV has a separate reproducible 60-document corpus checked against Python's CSV reader, with empty fields, mixed row widths, quotes and multiline data. XML adds a reproducible 60-document corpus compared with Python's ElementTree, plus mismatched tags, malformed UTF-8, entities and mixed-content cases. No Python package installation is needed.

### Reproducible fuzz/property tests

`tests/fuzz_test.py` runs bounded randomized checks against the built executables. It uses only Python's standard library. Each subprocess has a five-second timeout; failure reports include the seed, case and payload.

- Compare generated PEG operator combinations with an independent recognition model, across all a/b strings through length two, an outsider byte, and a longer random input.
- Mutate grammar and transform definitions, checking exit codes, JSON output and diagnostic escaping. Grammar mutations also exercise embedded-test loading.
- Compare mutated JSON acceptance and values with Python's JSON decoder, enforcing this project's strict Unicode-scalar policy and excluding non-JSON constants.
- Check successful mutated XML pipelines against ElementTree. Unsupported XML features may be rejected; a transform rejection after structural parsing must also be invalid XML.
- Exercise compiler nesting, left recursion, nullable repetition, parse depth and exponential-backtracking work guards.

```sh
# Default seed 8173, 100 cases per randomized test.
python3 tests/fuzz_test.py

# Larger run or exact replay of a reported seed/method.
PEG_FUZZ_SEED=42 PEG_FUZZ_CASES=500 python3 tests/fuzz_test.py
PEG_FUZZ_SEED=42 PEG_FUZZ_CASES=500 python3 tests/fuzz_test.py \
  FuzzTests.test_mutated_json_matches_strict_python
```

Case counts must be between 1 and 10,000. Rebuild in Debug or ReleaseSafe to exercise that configuration; the Python tests use `zig-out/bin`. A run is finite and deterministic for a given Python runtime, seed and count. This is mutation/property testing, not coverage-guided fuzzing, a benchmark, or proof that no defects remain. CSV's generated valid-document comparisons remain in `cli_test.py`.

## CI and releases

GitHub Actions runs formatting, unit tests, CLI acceptance tests and the deterministic fuzz suite on Ubuntu 24.04 and macOS 15, in Debug and ReleaseSafe. CI runs for pull requests and pushes to `main`, and can be started manually. Action dependencies are pinned to commit hashes. The Zig version comes from `mise.toml`.

Pushing a stable version tag such as `v0.1.0` starts the release workflow. It requires a tag on `main` history, reruns the full CI matrix, then cross-compiles ReleaseSafe archives for:

| Archive target | Platform |
| --- | --- |
| `x86_64-linux-musl` | Linux, Intel/AMD 64-bit, static binaries |
| `aarch64-linux-musl` | Linux, ARM64, static binaries |
| `x86_64-macos` | macOS, Intel |
| `aarch64-macos` | macOS, Apple Silicon |

Every `.tar.gz` includes the three commands, examples, README and specification. Releases include `SHA256SUMS`; after downloading the archives and checksum file, run `sha256sum -c SHA256SUMS`, or `shasum -a 256 -c SHA256SUMS` on macOS. Native CI covers the hosted Linux/macOS runners, not every cross-compiled architecture. Windows builds, macOS signing/notarization and installation packages are not included.

Only the final publishing job has `contents: write`. It does not check out source or execute binaries. It publishes artifacts from the same workflow run and checks that the tag still identifies the tested commit. CI/build jobs are read-only and do not retain checkout credentials. There is no deployment on an ordinary commit, no automatic tag creation, and no overwrite of an existing release.

To release an explicitly approved version from a verified `main` commit:

```sh
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

Do not move published tags. A failed build creates no release. If publication itself fails, inspect GitHub for a partial release before taking further action; reruns deliberately do not overwrite releases. Correct a shipped defect with a new version. Reverting or removing the workflow stops future automation but does not remove already-public history or release downloads.

## Library

`src/root.zig` exports `engine`, `transform`, `Diagnostic`, `Expectation` and `TraceEvent`. APIs accept an allocator; use an arena for each operation and keep source/input buffers alive while using the results. See [SPEC.md](SPEC.md) for interfaces and syntax details.
