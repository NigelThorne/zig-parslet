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

`expect` compares the whole capture tree, ignoring object key order. A `reject` test passes only for a document mismatch, not for a parser resource limit or broken grammar.

`peg_parse` skips balanced `@test` blocks. Unfinished assertions inside a balanced block do not affect production parsing. An unterminated block remains a grammar syntax error because its end cannot be located.

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

`pluck` rejects missing keys or non-object elements. `from_entries` rejects malformed entries, returns `{}` for an empty array and keeps the last value for duplicate keys. Neither operation changes its input. `unquote` rejects arrays, objects and other non-string JSON values; it does not parse whole JSON documents. `number` preserves precision rather than converting through a floating-point value. Explicit `int(number(...))` and `float(number(...))` conversions still enforce their normal limits.

Transform strings use JSON escapes, including Unicode escapes. Numeric literals follow JSON number syntax, including signed exponents such as `1e+2`. Object fields and function arguments require commas. `#` starts a comment. Unknown bindings/functions are errors even when their rule would not match. Rules cannot run host-language code.

## Diagnostics and limits

`peg_parse` reports the document failure location and expected alternatives. For example, `"yes" / "no"` reports `expected literal "yes" or literal "no"`. Tied failures retain up to 16 distinct expectations; repeated expectations appear once, and truncation is reported. Failures from successful choices and optional/lookahead probes do not leak into later errors.

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
```

The Python standard-library tests exercise the real executables, including stdin, pipelines, embedded tests, diagnostics, bad arguments and transform errors. JSON round trips include a reproducible 60-document generated corpus checked against Python's JSON decoder, plus malformed document, Unicode and exact numeric-token cases. No Python package installation is needed.

## Library

`src/root.zig` exports `engine`, `transform`, `Diagnostic`, `Expectation` and `TraceEvent`. APIs accept an allocator; use an arena for each operation and keep source/input buffers alive while using the results. See [SPEC.md](SPEC.md) for interfaces and syntax details.
