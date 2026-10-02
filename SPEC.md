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

Expressions: string literals, character classes/ranges/inversion with `\xHH` byte escapes, `.`, rule references, sequences, ordered `/` choice, grouping, `*`, `+`, `?`, negative `!` and positive `&` lookahead, named captures `name:expression`. Capture applies to the following suffixed expression, so `name:[a-z]+` captures the whole word. `#` comments and multiline rules supported. Top-level `root NAME` selects the required entry rule. Matching is byte-oriented on UTF-8 input; source columns are byte columns. Unicode literals work; classes/dot match bytes, not Unicode code points. No regex engine or host-language actions.

Without captures, matching returns matched text. In sequences, captures discard uncaptured text; adjacent capture objects merge, with later duplicate keys winning. Repetitions with captured items produce arrays, including singleton arrays. A sequence combining capture objects and arrays flattens them into an array of structured items. Empty uncaptured matches produce an empty string. These are Parslet-inspired rules, not a promise of bug-for-bug Elixir/Ruby compatibility.

`@test(rule_name) "label" { ... }` selects a rule as the test entry point. Plain `@test "label"` uses the root. Both require complete input consumption and retain existing capture/rejection semantics. Targets resolve after all rule declarations, allowing forward references. Unknown targets fail grammar loading only when tests are loaded; parse-only mode validates the optional selector syntax but skips its resolution and the balanced test body. A root declaration remains mandatory. Test execution does not mutate the grammar's document root. Human named-rule reports append `[rule]`. JSON reports include top-level `root_rule`; each case includes its effective `rule`, `assertion` (`expect` or `reject`), `is_root` (effective rule equals the document root), `summary` and `trace`. Explicitly selecting the root still sets `is_root: true`.

Test blocks use relaxed JSON values, with bare object keys and optional commas. Numeric literals follow JSON number syntax, including fraction/exponent digits and no leading zeros. Each test requires a string input and exactly one `expect` tree or `reject: true`. peg_parse skips balanced test blocks without validating their contents. peg_test validates them and reports expected/actual mismatch or unexpected success. Unknown rules, duplicates and invalid roots are errors. Left recursion, zero-width repeat and excessive recursion/work must fail rather than hang.

## Transform

```text
{ dot: simple(d), word: simple(w) } => concat(".", w)
{ word: simple(w) } => w
{ username: sequence(parts) } => concat(join(parts), "@")
{ username: simple(name) } => concat(name, "@")
{ email: sequence(parts) } => join(parts)
```

Object patterns match exact keys. Patterns also support arrays, scalar literals, `simple(name)` for scalar values, `sequence(name)` for arrays of scalars, and `subtree(name)` for any value. Repeated bindings must be deeply equal. Children transform before parents, then the first matching rule applies once; replacement values are not traversed again. Unmatched nodes are unchanged.

Output expressions support bindings, literals, arrays, objects and `concat`, `join`, `int`, `float`, `bool`, `unquote`, `number`, `pluck`, `from_entries`, `require_equal`. Numeric literals follow JSON number syntax; conversion functions retain their separate string-conversion semantics. No arbitrary code. Unknown variables/functions and malformed rules are diagnosed. Invalid conversions fail, not silently coerce to zero.

New JSON-oriented helpers:

- `unquote(text)` decodes exactly one quoted JSON string token, allowing surrounding JSON whitespace. Reject arrays and all other non-string JSON values.
- `number(text)` validates JSON number syntax and returns a numeric token without rounding or changing its spelling. Library representation is `std.json.Value.number_string`. Explicit int/float conversions accept it and enforce their existing limits.
- `pluck(array, key)` requires an array of objects and a string key. Missing keys and non-object elements are errors; arbitrary selected values are preserved.
- `from_entries(array)` requires exact `{key: STRING, value: ANY}` entries. It creates an object, with the last value winning for duplicate keys. Empty input creates an empty object.

`require_equal(a, b)` takes exactly two values, returns the first unchanged when deeply equal, and fails with `error.InvalidTransform` otherwise. Equality matches repeated-binding semantics, including representation-sensitive numbers and order-insensitive object keys. Mismatch diagnostics identify the function expression in the transform source. Unmatched pattern behavior remains unchanged.

All helper names and arities are validated when loading rules. Replacement values are not re-transformed. The JSON example retains entry/element wrappers until container reduction to avoid confusing singleton nested containers or user keys with parser tags.

## XML example contract

`examples/xml.peg` and `examples/xml.pegtx` implement a bounded XML subset inspired by the ElixirParslet example. The output is `{tag: string, children: [string | element]}`. Child order and text whitespace are preserved. Text fragments join, entities decode once, and literal CRLF/CR normalize to LF. Empty paired and self-closing elements both have empty child arrays.

Require one root with optional exterior XML whitespace. Names are `[A-Za-z_][A-Za-z0-9_.-]*`. Support nested elements, mixed content and `&lt;`, `&gt;`, `&amp;`, `&quot;`, `&apos;`. Validate UTF-8 and XML 1.0 literal character ranges; reject literal `]]>` in text.

Reject attributes, namespaces, declarations, processing instructions, comments, CDATA, DTDs and numeric character references. No external entity access. Normal engine depth/work limits apply.

The grammar checks structure only. Tag-name equality is checked in the transform with `require_equal`; mismatches fail with exit 1 and no partial JSON output in normal mode. Parse-only success is not proof of well-formed XML. Transform diagnostics refer to `.pegtx` source rather than document tag positions.

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
    rule_name: ?[]const u8 = null,
    rule_index: ?usize = null, // resolved named target; null selects grammar.root
};
pub const Grammar = struct {
    // additional implementation fields allowed
    tests: []const TestCase,
};
pub const ParseResult = struct {
    value: ?std.json.Value = null,
    diagnostic: ?common.Diagnostic = null,
    trace: []const common.TraceEvent = &.{},
    summary: ?common.TraceSummary = null,
};
pub fn compile(allocator: std.mem.Allocator, source: []const u8,
    load_tests: bool, diagnostic: *?common.Diagnostic) anyerror!Grammar;
pub fn parse(allocator: std.mem.Allocator, grammar: *const Grammar,
    input: []const u8, trace: bool) anyerror!ParseResult;
```

Compilation failure sets diagnostic and returns an error. Parse mismatch returns a diagnostic in ParseResult, not an exception. Diagnostic offset refers to grammar text on compile error, input text on parse failure; optional grammar_offset refers to failing expression. Diagnostic.expected contains up to 16 distinct expectations at the farthest failing input byte, each with a message, grammar_offset and optional rule. Identical messages are deduplicated, retaining their first grammar location. expected_truncated indicates further distinct alternatives were omitted. Successful choices and successful optional/lookahead probes discard their speculative failures. Repetition discards failures at the next item's starting position, but retains deeper failures from incomplete items if the overall parse fails. Rule trace is bounded, and attempts may have been backtracked even when they matched.

`peg_test --json` adds `summary` and `trace` to document success and failure reports; embedded JSON includes them for each case. Input diagnostics include `grammar_end`; expectations include `grammar_end` and `attempt_id` when known. `peg_parse` success remains a bare capture tree. Attempt `id` starts at zero on rule entry; `parent_id` points to the invoking rule attempt. Events include grammar byte span `grammar_offset`..`grammar_end`, input `start`, local returned `end`, independent deepest `furthest`, `outcome` (`matched`, `failed`, `limit`), `disposition` (`retained`, `backtracked`, `lookahead`), legacy `matched` and `depth`, and independent `lookahead` and `backtracked` flags. A failed attempt returns locally to `start` despite deeper progress. A successful local match need not be committed.

The summary counts `total_attempts`, `recorded_attempts` and `omitted_attempts`. `trace_truncated` marks attempts beyond the first 1,024 completed events recorded. `furthest_attempt` selects greatest progress, then greatest depth, then earliest ID. `last_success` is the latest completed local match, even if discarded later. Both cover attempts beyond the trace cap. `final_failure` records offset, rule, attempt ID, grammar span and `synthetic_eof` when available. A root that matches only a prefix remains a local success; its whole-document failure is synthetic EOF. The recorder observes the same parse, not a separate diagnostic algorithm. The shared evaluator has compile-time production and authoring specializations; the production specialization has no recorder or invocation tracking. `retained` means no enclosing evaluation rolled back that attempt, not that the document matched. `lookahead` takes precedence in `disposition`; its separate `backtracked` flag still records any enclosing rollback. A parent ID may refer to an omitted event after truncation. IDs and summaries are scoped to one parse, so each embedded test starts at ID zero. `final_failure` refers to the first retained expected alternative; the full tied set remains in `diagnostic.expected`. Grammar spans are half-open byte ranges; predicate failures highlight the predicate operator, and synthetic EOF uses the root declaration.

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
