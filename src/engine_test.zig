const std = @import("std");
const engine = @import("engine.zig");

fn compileOk(allocator: std.mem.Allocator, source: []const u8, load_tests: bool) !engine.Grammar {
    var diagnostic: ?@import("common.zig").Diagnostic = null;
    return engine.compile(allocator, source, load_tests, &diagnostic) catch |err| {
        if (diagnostic) |d| std.debug.print("compile diagnostic at {d}: {s}\n", .{ d.offset, d.message });
        return err;
    };
}

fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| v == b.float,
        .number_string => |v| std.mem.eql(u8, v, b.number_string),
        .string => |v| std.mem.eql(u8, v, b.string),
        .array => |v| blk: {
            if (v.items.len != b.array.items.len) break :blk false;
            for (v.items, b.array.items) |x, y| if (!jsonEqual(x, y)) break :blk false;
            break :blk true;
        },
        .object => |v| blk: {
            if (v.count() != b.object.count()) break :blk false;
            var it = v.iterator();
            while (it.next()) |entry| if (!jsonEqual(entry.value_ptr.*, b.object.get(entry.key_ptr.*) orelse break :blk false)) break :blk false;
            break :blk true;
        },
    };
}

fn expectJsonEqual(expected: []const u8, actual: std.json.Value) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, expected, .{});
    defer parsed.deinit();
    if (!jsonEqual(parsed.value, actual)) {
        actual.dump();
        std.debug.print("\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "literal grammar parses whole input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grammar = try compileOk(a, "root greeting\ngreeting <- \"Hi\"", false);
    const result = try engine.parse(a, &grammar, "Hi", false);
    try std.testing.expect(result.diagnostic == null);
    try expectJsonEqual("\"Hi\"", result.value.?);
    const trailing = try engine.parse(a, &grammar, "Hi!", false);
    try std.testing.expectEqual(@import("common.zig").Diagnostic.Kind.input, trailing.diagnostic.?.kind);
    try std.testing.expectEqual(@as(usize, 2), trailing.diagnostic.?.offset);
}

test "operators, references, lookahead, and comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\# greeting
        \\root greeting
        \\greeting <- "Hi" (" " / "-") &[^0-9] !"bad" [a-zA-Z]+ "."?
    ;
    const grammar = try compileOk(a, source, false);
    try std.testing.expect((try engine.parse(a, &grammar, "Hi World.", false)).diagnostic == null);
    try std.testing.expect((try engine.parse(a, &grammar, "Hi 7", false)).diagnostic != null);
    try std.testing.expect((try engine.parse(a, &grammar, "Hi bad", false)).diagnostic != null);
}

test "captures aggregate across sequences and repetitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\root email
        \\email <- username:(part (dot part)*) "@" host:[a-z]+
        \\part <- word:[a-z]+
        \\dot <- dot:"."
    ;
    const grammar = try compileOk(a, source, false);
    const result = try engine.parse(a, &grammar, "first.last@example", false);
    try std.testing.expect(result.diagnostic == null);
    try expectJsonEqual("{\"username\":[{\"word\":\"first\"},{\"dot\":\".\",\"word\":\"last\"}],\"host\":\"example\"}", result.value.?);
}

test "embedded relaxed-json tests load or skip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\root word
        \\word <- value:[a-z]+
        \\@test "works" { input: "yes" expect: { value: "yes" } }
        \\@test "rejects" { input: "12", reject: true, }
    ;
    const loaded = try compileOk(a, source, true);
    try std.testing.expectEqual(@as(usize, 2), loaded.tests.len);
    try std.testing.expectEqualStrings("works", loaded.tests[0].name);
    try expectJsonEqual("{\"value\":\"yes\"}", loaded.tests[0].expect.?);
    const skipped = try compileOk(a, source, false);
    try std.testing.expectEqual(@as(usize, 0), skipped.tests.len);
}

test "relaxed-json test expectations support arrays and scalar numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grammar = try compileOk(a,
        \\root value
        \\value <- [0-9]+
        \\@test "tree" { input: "1" expect: {items: [1, -2.5, true, null]}}
    , true);
    try expectJsonEqual("{\"items\":[1,-2.5,true,null]}", grammar.tests[0].expect.?);
}

test "compile rejects invalid grammar relationships" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const u8{
        "root missing\nrule <- \"x\"",
        "root a\na <- b",
        "root a\na <- \"x\"\na <- \"y\"",
    };
    for (cases) |source| {
        var diagnostic: ?@import("common.zig").Diagnostic = null;
        try std.testing.expectError(error.InvalidGrammar, engine.compile(a, source, false, &diagnostic));
        try std.testing.expect(diagnostic != null);
        try std.testing.expectEqual(@import("common.zig").Diagnostic.Kind.grammar, diagnostic.?.kind);
    }
}

test "runtime guards left recursion and nullable repetition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const left = try compileOk(a, "root a\na <- a / \"x\"", false);
    try std.testing.expectEqual(@import("common.zig").Diagnostic.Kind.limit, (try engine.parse(a, &left, "x", false)).diagnostic.?.kind);
    const nullable = try compileOk(a, "root a\na <- (\"x\"?)*", false);
    try std.testing.expectEqual(@import("common.zig").Diagnostic.Kind.limit, (try engine.parse(a, &nullable, "", false)).diagnostic.?.kind);
}

test "failure diagnostics identify expectation, rule, grammar offset, and mismatch byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grammar = try compileOk(a, "root greeting\ngreeting <- \"hello\" [0-9]", false);
    const literal = (try engine.parse(a, &grammar, "hez", false)).diagnostic.?;
    try std.testing.expectEqual(@as(usize, 2), literal.offset);
    try std.testing.expectEqualStrings("greeting", literal.rule.?);
    try std.testing.expect(literal.grammar_offset != null);
    try std.testing.expect(std.mem.indexOf(u8, literal.message, "hello") != null);
    const class = (try engine.parse(a, &grammar, "hello x", false)).diagnostic.?;
    try std.testing.expect(std.mem.indexOf(u8, class.message, "character class") != null);
    const end_grammar = try compileOk(a, "root word\nword <- \"ok\"", false);
    const ending = (try engine.parse(a, &end_grammar, "ok!", false)).diagnostic.?;
    try std.testing.expectEqualStrings("expected end of input", ending.message);
    try std.testing.expectEqualStrings("word", ending.rule.?);
}

test "successful probes do not pollute required failure diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grammar = try compileOk(a, "root a\na <- !\"forbidden-long\" \"yes\"? \"required\"", false);
    const diagnostic = (try engine.parse(a, &grammar, "no", false)).diagnostic.?;
    try std.testing.expectEqual(@as(usize, 0), diagnostic.offset);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "required") != null);
}

test "grammar and runtime expression nesting are bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(a, "root a\na <- ");
    for (0..600) |_| try source.append(a, '(');
    try source.appendSlice(a, "\"x\"");
    for (0..600) |_| try source.append(a, ')');
    var diagnostic: ?@import("common.zig").Diagnostic = null;
    try std.testing.expectError(error.InvalidGrammar, engine.compile(a, source.items, false, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.message, "limit") != null);

    var runtime_source: std.ArrayList(u8) = .empty;
    try runtime_source.appendSlice(a, "root a\na <- ");
    for (0..300) |_| try runtime_source.append(a, '&');
    try runtime_source.appendSlice(a, "\"x\"");
    const runtime_grammar = try compileOk(a, runtime_source.items, false);
    const result = try engine.parse(a, &runtime_grammar, "x", false);
    try std.testing.expectEqual(@import("common.zig").Diagnostic.Kind.limit, result.diagnostic.?.kind);
}

test "character classes and strings decode escapes without silent corruption" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grammar = try compileOk(a, "root a\na <- [\\n][\\r][\\t][\\]][\\-][\\\\] \"\\u263A\" \"\\uD83D\\uDE00\"", false);
    try std.testing.expect((try engine.parse(a, &grammar, "\n\r\t]-\\☺😀", false)).diagnostic == null);
    const bad_classes = [_][]const u8{ "root a\na <- [z-a]", "root a\na <- [\\q]", "root a\na <- [a-" };
    for (bad_classes) |source_bad| {
        var diagnostic: ?@import("common.zig").Diagnostic = null;
        try std.testing.expectError(error.InvalidGrammar, engine.compile(a, source_bad, false, &diagnostic));
    }
    var bad_escape: ?@import("common.zig").Diagnostic = null;
    try std.testing.expectError(error.InvalidGrammar, engine.compile(a, "root a\na <- \"\\q\"", false, &bad_escape));
}

test "character classes support exact hex byte escapes and ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grammar = try compileOk(a, "root r\nr <- [\\x00-\\x1f] [\\x80-\\xFF] [\\x2d]", false);
    try std.testing.expect((try engine.parse(a, &grammar, &.{ 0, 128, '-' }, false)).diagnostic == null);
    const invalid = [_][]const u8{ "[\\x]", "[\\x0]", "[\\xGG]", "[\\x+f]", "[\\xff-\\x00]" };
    for (invalid) |class| {
        const source = try std.fmt.allocPrint(a, "root r\nr <- {s}", .{class});
        var diagnostic: ?@import("common.zig").Diagnostic = null;
        try std.testing.expectError(error.InvalidGrammar, engine.compile(a, source, false, &diagnostic));
        try std.testing.expect(diagnostic != null);
    }
}

test "hyphen at either edge of a character class is literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "root r\nr <- [_-]+", "root r\nr <- [-_]+" }) |source| {
        const grammar = try compileOk(a, source, false);
        const result = try engine.parse(a, &grammar, "_-_-", false);
        try std.testing.expect(result.diagnostic == null);
    }
}

test "optional permits zero width and preserves direct captures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zero = try compileOk(a, "root a\na <- (&\"x\")? \"x\"", false);
    try std.testing.expect((try engine.parse(a, &zero, "x", false)).diagnostic == null);
    const captured = try compileOk(a, "root a\na <- value:\"x\"?", false);
    const result = try engine.parse(a, &captured, "x", false);
    try expectJsonEqual("{\"value\":\"x\"}", result.value.?);
}

test "skipped tests ignore braces in comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grammar = try compileOk(a,
        \\root a
        \\a <- "x"
        \\@test "ignored" { # } } comment braces
        \\ nonsense: { still: ignored }
        \\}
    , false);
    try std.testing.expectEqual(@as(usize, 0), grammar.tests.len);
}

test "test validation rejects false rejection and duplicate fields or keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const u8{
        "root a\na <- \"x\"\n@test \"bad\" {input:\"x\" reject:false}",
        "root a\na <- \"x\"\n@test \"bad\" {input:\"x\" input:\"y\" reject:true}",
        "root a\na <- \"x\"\n@test \"bad\" {input:\"x\" expect:{a:1 a:2}}",
    };
    for (cases) |source| {
        var diagnostic: ?@import("common.zig").Diagnostic = null;
        try std.testing.expectError(error.InvalidGrammar, engine.compile(a, source, true, &diagnostic));
    }
}

test "trace is bounded and includes rule attempts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grammar = try compileOk(a, "root a\na <- b / \"x\"\nb <- \"y\"", false);
    const result = try engine.parse(a, &grammar, "x", true);
    try std.testing.expect(result.diagnostic == null);
    try std.testing.expect(result.trace.len >= 2);
    try std.testing.expect(result.trace.len <= 1024);
}
