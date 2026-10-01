# Zig Parslet contract

Three commands share a Zig 0.16.0 library:

- `peg_parse GRAMMAR [INPUT|-]`: strict whole-document parsing, JSON tree on stdout.
- `peg_test GRAMMAR`: run embedded tests; `peg_test GRAMMAR INPUT`: diagnose that document, with grammar source locations and a bounded attempt trace.
- `peg_transform RULES [TREE|-]`: JSON tree in and out, recursive bottom-up transformation.

`.peg` grammar files and `.pegtx` transform files are text. Missing input for parse/transform means stdin. Exit 0 for success, 1 for document mismatch/test failure/runtime transform failure, 2 for invalid usage, unreadable files, malformed input JSON, or invalid grammar/transform definitions. `--help` and `--json` are supported. Ordinary parse/transform diagnostics go to stderr to keep pipelines clean; --json emits structured diagnostics to stdout.

## Grammar

```peg
root greeting
greeting <- "Hi " who:[a-zA-Z]+

@test "captures name" {
  input: "Hi World"
  expect: { who: "World" }
}
@test "missing name" {
  input: "Hi "
  reject: true
}
```

Expressions: string literals, character classes/ranges/inversion, `.`, rule references, sequences, ordered `/` choice, grouping, `*`, `+`, `?`, negative `!` and positive `&` lookahead, named captures `name:expression`. Capture applies to the following suffixed expression, so `name:[a-z]+` captures the whole word. `#` comments and multiline rules supported. Top-level `root NAME` selects the required entry rule. Matching is byte-oriented on UTF-8 input; source columns are byte columns. Unicode literals work; classes/dot match bytes, not Unicode code points. No regex engine or host-language actions.

Without captures, matching returns matched text. In sequences, captures discard uncaptured text; adjacent capture objects merge, with later duplicate keys winning. Repetitions with captured items produce arrays, including singleton arrays. A sequence combining capture objects and arrays flattens them into an array of structured items. Empty uncaptured matches produce an empty string. These are Parslet-inspired rules, not a promise of bug-for-bug Elixir/Ruby compatibility.

Test blocks use relaxed JSON values, with bare object keys and optional commas. Each test requires a string input and exactly one `expect` tree or `reject: true`. peg_parse skips balanced test blocks without validating their contents. peg_test validates them and reports expected/actual mismatch or unexpected success. Unknown rules, duplicates and invalid roots are errors. Left recursion, zero-width repeat and excessive recursion/work must fail rather than hang.

## Transform

```text
{ dot: simple(d), word: simple(w) } => concat(".", w)
{ word: simple(w) } => w
{ username: sequence(parts) } => concat(join(parts), "@")
{ username: simple(name) } => concat(name, "@")
{ email: sequence(parts) } => join(parts)
```

Object patterns match exact keys. Patterns also support arrays, scalar literals, `simple(name)` for scalar values, `sequence(name)` for arrays of scalars, and `subtree(name)` for any value. Repeated bindings must be deeply equal. Children transform before parents, then the first matching rule applies once; replacement values are not traversed again. Unmatched nodes are unchanged.

Output expressions support bindings, literals, arrays, objects and `concat`, `join`, `int`, `float`, `bool`. No arbitrary code. Unknown variables/functions and malformed rules are diagnosed. Invalid conversions fail, not silently coerce to zero.

## Internal interfaces

All allocations belong to the supplied allocator. CLI calls use arenas. Input strings and rule source must remain alive for result lifetime.

Shared `src/common.zig` defines `Diagnostic` and `TraceEvent`.

Engine (`src/engine.zig`):

```zig
pub const TestCase = struct {
    name: []const u8,
    input: []const u8,
    expect: ?std.json.Value = null,
    reject: bool = false,
    source_offset: usize,
};
pub const Grammar = struct {
    // additional implementation fields allowed
    tests: []const TestCase,
};
pub const ParseResult = struct {
    value: ?std.json.Value = null,
    diagnostic: ?common.Diagnostic = null,
    trace: []const common.TraceEvent = &.{},
};
pub fn compile(allocator: std.mem.Allocator, source: []const u8,
    load_tests: bool, diagnostic: *?common.Diagnostic) anyerror!Grammar;
pub fn parse(allocator: std.mem.Allocator, grammar: *const Grammar,
    input: []const u8, trace: bool) anyerror!ParseResult;
```

Compilation failure sets diagnostic and returns an error. Parse mismatch returns a diagnostic in ParseResult, not an exception. Diagnostic offset refers to grammar text on compile error, input text on parse failure; optional grammar_offset refers to failing expression. Rule trace is bounded, and attempts may have been backtracked even when they matched.

Transform (`src/transform.zig`):

```zig
pub fn apply(allocator: std.mem.Allocator, source: []const u8,
    input: std.json.Value, diagnostic: *?common.Diagnostic) anyerror!std.json.Value;
```

Transform diagnostic offset refers to .pegtx source. Use shared diagnostic kind transform or limit. No dependency on engine.

## References

- https://github.com/NigelThorne/ElixirParslet
- https://github.com/kschiess/parslet
- https://github.com/kschiess/parslet/blob/master/example/email_parser.rb
