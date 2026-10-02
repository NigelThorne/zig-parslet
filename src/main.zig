const std = @import("std");
const engine = @import("engine.zig");
const transform = @import("transform.zig");
const common = @import("common.zig");
const diag = @import("diagnostics.zig");
const command = @import("options").command;
const is_test = std.mem.eql(u8, command, "peg_test");
const is_transform = std.mem.eql(u8, command, "peg_transform");
const max_bytes = 16 * 1024 * 1024;

const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    json: bool = false,
    events: []const common.TraceEvent = &.{},

    fn emit(self: Context, text: []const u8, stderr: bool) !void {
        const file: std.Io.File = if (stderr) .stderr() else .stdout();
        try file.writeStreamingAll(self.io, text);
    }

    fn jsonValue(self: Context, value: anytype) !void {
        const text = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        try self.emit(text, false);
        try self.emit("\n", false);
    }

    fn problem(self: Context, message: []const u8, usage: bool) !u8 {
        if (self.json) {
            try self.jsonValue(.{ .@"error" = .{ .message = message, .help = command ++ " --help" } });
        } else {
            try self.emit(try std.fmt.allocPrint(self.allocator, "error: {s}\nhelp: {s} --help\n", .{
                try diag.escape(self.allocator, message), command,
            }), true);
            if (usage) try self.emit(help, true);
        }
        return 2;
    }

    fn read(self: Context, path: []const u8) ![]const u8 {
        if (std.mem.eql(u8, path, "-")) {
            var buffer: [4096]u8 = undefined;
            var reader = std.Io.File.stdin().readerStreaming(self.io, &buffer);
            return reader.interface.allocRemaining(self.allocator, .limited(max_bytes));
        }
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(max_bytes));
    }

    fn ioProblem(self: Context, path: []const u8, err: anyerror) !u8 {
        return self.problem(try std.fmt.allocPrint(self.allocator, "cannot read '{s}': {s} (maximum input 16 MiB)", .{ path, @errorName(err) }), false);
    }

    fn diagnostic(self: Context, problem_value: common.Diagnostic, source_name: []const u8, source: []const u8, grammar_name: []const u8, grammar_source: []const u8, author: bool) !void {
        if (self.json) {
            const loc = diag.location(source, problem_value.offset);
            const grammar_loc: ?diag.Location = if (problem_value.grammar_offset) |offset| diag.location(grammar_source, offset) else null;
            try self.jsonValue(.{ .@"error" = .{
                .kind = @tagName(problem_value.kind),
                .message = problem_value.message,
                .source = source_name,
                .offset = problem_value.offset,
                .line = loc.line,
                .column = loc.column,
                .rule = problem_value.rule,
                .grammar_source = if (grammar_loc != null) grammar_name else null,
                .grammar_location = grammar_loc,
                .expected = problem_value.expected,
                .expected_truncated = problem_value.expected_truncated,
            }, .trace = if (author) self.events else &.{} });
            return;
        }
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        try output.writer.print("error: {s}\n", .{try diag.escape(self.allocator, problem_value.message)});
        try output.writer.writeAll(try diag.highlight(self.allocator, source_name, source, problem_value.offset));
        if (problem_value.rule) |rule| try output.writer.print("rule: {s}\n", .{try diag.escape(self.allocator, rule)});
        if (author) {
            if (problem_value.grammar_offset) |offset| {
                try output.writer.writeAll("grammar expression:\n");
                try output.writer.writeAll(try diag.highlight(self.allocator, grammar_name, grammar_source, offset));
            }
            for (problem_value.expected) |expected| {
                if (problem_value.grammar_offset == expected.grammar_offset) continue;
                try output.writer.print("alternative: {s}\n", .{try diag.escape(self.allocator, expected.message)});
                try output.writer.writeAll(try diag.highlight(self.allocator, grammar_name, grammar_source, expected.grammar_offset));
            }
        }
        try self.emit(output.written(), !is_test);
    }

    fn trace(self: Context, events: []const common.TraceEvent) !void {
        if (events.len == 0) return;
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        try output.writer.writeAll("Rule attempts (matches may later be backtracked; last 40 recorded):\n");
        for (events[events.len -| 40..]) |event| {
            try output.writer.splatByteAll(' ', @as(usize, @min(event.depth, 12)) * 2);
            try output.writer.print("{s} {s} bytes {d}..{d}\n", .{
                if (event.matched) "MATCH" else "FAIL",
                try diag.escape(self.allocator, event.rule),
                event.start,
                event.end,
            });
        }
        try self.emit(output.written(), false);
    }
};

const help = if (is_transform)
    \\peg_transform - recursively reshape a JSON capture tree with .pegtx rules
    \\Usage: peg_transform [--json] RULES.pegtx [TREE.json|-]
    \\  Omitted TREE or '-' reads stdin. Success writes one JSON value.
    \\  --json     Write structured errors to stdout instead of stderr.
    \\  --help     Show this help.
    \\  --         End flag parsing, allowing filenames that start with '-'.
    \\Examples:
    \\  peg_transform email.pegtx tree.json
    \\  peg_parse email.peg input.txt | peg_transform email.pegtx
    \\Exit: 0 success, 1 transform failure, 2 usage/input error. Input limit: 16 MiB.
    \\
else if (is_test)
    \\peg_test - test and diagnose PEG grammars
    \\Usage: peg_test [--json] GRAMMAR.peg [INPUT|-]
    \\  Without INPUT, run embedded @test cases; @test(rule) selects a named rule.
    \\  With INPUT, show document/grammar locations and rule attempts.
    \\  --json     Write a machine-readable test report or diagnostic.
    \\  --help     Show this help.
    \\  --         End flag parsing, allowing filenames that start with '-'.
    \\Examples:
    \\  peg_test email.peg
    \\  peg_test email.peg bad-email.txt
    \\Exit: 0 success, 1 failed test/parse, 2 usage/grammar error. Input limit: 16 MiB.
    \\
else
    \\peg_parse - parse an entire document using a .peg grammar
    \\Usage: peg_parse [--json] GRAMMAR.peg [INPUT|-]
    \\  Omitted INPUT or '-' reads stdin. Success writes one JSON capture tree.
    \\  Embedded @test blocks are ignored. No partial parses are returned.
    \\  --json     Write structured errors to stdout instead of stderr.
    \\  --help     Show this help.
    \\  --         End flag parsing, allowing filenames that start with '-'.
    \\Examples:
    \\  peg_parse email.peg input.txt
    \\  peg_parse email.peg input.txt | peg_transform email.pegtx
    \\Exit: 0 success, 1 parse failure, 2 usage/grammar error. Input limit: 16 MiB.
    \\
;

pub fn main(init: std.process.Init) void {
    var context: Context = .{ .allocator = init.arena.allocator(), .io = init.io };
    const code = run(&context, init) catch |err| blk: {
        context.emit("error: operation failed: " ++ command ++ "\n", true) catch {};
        context.emit(@errorName(err), true) catch {};
        context.emit("\n", true) catch {};
        break :blk @as(u8, 2);
    };
    if (code != 0) std.process.exit(code);
}

fn run(context: *Context, init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(context.allocator);
    // Discover formatting first, but respect the end-of-options marker.
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "--json")) context.json = true;
    }
    var positional: [2][]const u8 = undefined;
    var count: usize = 0;
    var flags = true;
    var wants_help = false;
    for (args[1..]) |arg| {
        if (flags and std.mem.eql(u8, arg, "--")) {
            flags = false;
        } else if (flags and std.mem.eql(u8, arg, "--help")) {
            wants_help = true;
        } else if (flags and std.mem.eql(u8, arg, "--json")) {
            continue;
        } else if (flags and arg.len > 1 and arg[0] == '-') {
            return context.problem(try std.fmt.allocPrint(context.allocator, "unknown flag '{s}'; valid flags: --json, --help, --", .{arg}), true);
        } else {
            if (count == positional.len) return context.problem("too many arguments", true);
            positional[count] = arg;
            count += 1;
        }
    }
    if (wants_help) {
        try context.emit(help, false);
        return 0;
    }
    if (count == 0) return context.problem("a grammar or transform rules file is required", true);
    if (std.mem.eql(u8, positional[0], "-")) return context.problem("grammar/rules must be a file; stdin is reserved for input", true);
    const rules_name = positional[0];
    const rules_source = context.read(rules_name) catch |err| return context.ioProblem(rules_name, err);
    if (is_transform) return transformCommand(context.*, rules_name, rules_source, if (count == 2) positional[1] else "-");

    var diagnostic: ?common.Diagnostic = null;
    const grammar = engine.compile(context.allocator, rules_source, is_test and count == 1, &diagnostic) catch |err| {
        if (diagnostic) |d| {
            try context.diagnostic(d, rules_name, rules_source, rules_name, rules_source, false);
            return 2;
        }
        return err;
    };
    if (is_test and count == 1) return embeddedTests(context.*, &grammar, rules_name, rules_source);
    const input_name = if (count == 2) positional[1] else "-";
    const input = context.read(input_name) catch |err| return context.ioProblem(input_name, err);
    const result = try engine.parse(context.allocator, &grammar, input, is_test);
    context.events = result.trace;
    if (result.diagnostic) |d| {
        try context.diagnostic(d, if (std.mem.eql(u8, input_name, "-")) "<stdin>" else input_name, input, rules_name, rules_source, is_test);
        if (is_test and !context.json) try context.trace(result.trace);
        return 1;
    }
    if (is_test) {
        if (context.json) {
            try context.jsonValue(.{ .matched = true, .value = result.value.?, .trace = result.trace });
        } else {
            try context.emit(try std.fmt.allocPrint(context.allocator, "PASS: matched all {d} input bytes\n", .{input.len}), false);
            try context.jsonValue(result.value.?);
            try context.trace(result.trace);
        }
    } else try context.jsonValue(result.value.?);
    return 0;
}

fn transformCommand(context: Context, rules_name: []const u8, rules_source: []const u8, input_name: []const u8) !u8 {
    const input = context.read(input_name) catch |err| return context.ioProblem(input_name, err);
    const tree = std.json.parseFromSlice(std.json.Value, context.allocator, input, .{ .allocate = .alloc_always }) catch |err| {
        return context.problem(try std.fmt.allocPrint(context.allocator, "invalid JSON input '{s}': {s}", .{ input_name, @errorName(err) }), false);
    };
    var diagnostic: ?common.Diagnostic = null;
    const result = transform.apply(context.allocator, rules_source, tree.value, &diagnostic) catch |err| {
        if (diagnostic) |d| {
            try context.diagnostic(d, rules_name, rules_source, rules_name, rules_source, false);
            return if (err == error.InvalidTransformRules) 2 else 1;
        }
        return err;
    };
    try context.jsonValue(result);
    return 0;
}

const TestReport = struct {
    name: []const u8,
    rule: []const u8,
    passed: bool,
    message: []const u8,
    expected: ?std.json.Value,
    actual: ?std.json.Value,
    diagnostic: ?common.Diagnostic,
};

fn embeddedTests(context: Context, grammar: *const engine.Grammar, grammar_name: []const u8, grammar_source: []const u8) !u8 {
    var reports: std.ArrayList(TestReport) = .empty;
    var passed: usize = 0;
    for (grammar.tests) |case| {
        var test_grammar = grammar.*;
        test_grammar.root = case.rule_index orelse grammar.root;
        const result = try engine.parse(context.allocator, &test_grammar, case.input, true);
        const ok = if (case.reject)
            result.diagnostic != null and result.diagnostic.?.kind == .input
        else
            result.value != null and case.expect != null and diag.equal(case.expect.?, result.value.?);
        const message = if (ok) "passed" else if (case.reject and result.value != null)
            "unexpected successful parse; expected rejection"
        else if (result.diagnostic != null)
            "parse failed"
        else
            "capture tree mismatch";
        if (ok) passed += 1;
        try reports.append(context.allocator, .{
            .name = case.name,
            .rule = grammar.rules[test_grammar.root].name,
            .passed = ok,
            .message = message,
            .expected = case.expect,
            .actual = result.value,
            .diagnostic = result.diagnostic,
        });
        if (!context.json) {
            const label = if (case.rule_name) |name|
                try std.fmt.allocPrint(context.allocator, "{s} [{s}]", .{ case.name, name })
            else
                case.name;
            try context.emit(try std.fmt.allocPrint(context.allocator, "{s} {s}: {s}\n", .{
                if (ok) "PASS" else "FAIL", try diag.escape(context.allocator, label), message,
            }), false);
            if (!ok) {
                if (result.diagnostic) |d| {
                    const source_name = try std.fmt.allocPrint(context.allocator, "test '{s}' input", .{case.name});
                    try context.diagnostic(d, source_name, case.input, grammar_name, grammar_source, true);
                    try context.trace(result.trace);
                } else {
                    if (case.expect) |expected| {
                        try context.emit("  expected: ", false);
                        try context.jsonValue(expected);
                    }
                    if (result.value) |actual| {
                        try context.emit("  actual:   ", false);
                        try context.jsonValue(actual);
                    }
                }
            }
        }
    }
    const failed = grammar.tests.len - passed;
    if (context.json) {
        try context.jsonValue(.{ .passed = passed, .failed = failed, .tests = reports.items });
    } else if (grammar.tests.len == 0) {
        try context.emit("No embedded tests. Add @test cases to this .peg file.\n", false);
    } else {
        try context.emit(try std.fmt.allocPrint(context.allocator, "{d} passed, {d} failed\n", .{ passed, failed }), false);
    }
    return if (failed == 0) 0 else 1;
}
