const std = @import("std");
const common = @import("common.zig");
const transform = @import("transform.zig");

fn parseJson(allocator: std.mem.Allocator, source: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    return parsed.value;
}

fn expectValue(expected: std.json.Value, actual: std.json.Value) !void {
    if (!deepEqual(expected, actual)) return error.TestExpectedEqual;
}

fn deepEqual(a: std.json.Value, b: std.json.Value) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| v == b.float,
        .number_string => |v| std.mem.eql(u8, v, b.number_string),
        .string => |v| std.mem.eql(u8, v, b.string),
        .array => |v| blk: {
            if (v.items.len != b.array.items.len) break :blk false;
            for (v.items, b.array.items) |left, right| if (!deepEqual(left, right)) break :blk false;
            break :blk true;
        },
        .object => |v| blk: {
            if (v.count() != b.object.count()) break :blk false;
            var it = v.iterator();
            while (it.next()) |entry| {
                const right = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!deepEqual(entry.value_ptr.*, right)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn run(source: []const u8, input_text: []const u8, expected_text: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const input = try parseJson(allocator, input_text);
    const expected = try parseJson(allocator, expected_text);
    var diagnostic: ?common.Diagnostic = null;
    const actual = try transform.apply(allocator, source, input, &diagnostic);
    try std.testing.expectEqual(@as(?common.Diagnostic, null), diagnostic);
    try expectValue(expected, actual);
}

test "email transform applies children before parent using first matching rule" {
    try run(
        \\# Ruby email transform chain
        \\{ dot: simple(d), word: simple(w) } => concat(".", w)
        \\{ word: simple(w) } => w
        \\{ username: sequence(parts) } => concat(join(parts), "@")
        \\{ username: simple(name) } => concat(name, "@")
        \\{ email: sequence(parts) } => join(parts)
    ,
        \\{"email":[{"username":[{"word":"first"},{"dot":".","word":"last"}]},{"word":"example"},{"dot":".","word":"com"}]}
    , "\"first.last@example.com\"");
}

test "patterns match exact shape, arrays and repeated deep-equal bindings" {
    try run(
        \\{ pair: [subtree(x), subtree(x)] } => { same: true, value: x }
        \\{ pair: subtree(x), extra: subtree(y) } => false
    , "{\"pair\":[{\"n\":1},{\"n\":1}]}", "{\"same\":true,\"value\":{\"n\":1}}");
    try run("{ pair: [subtree(x), subtree(x)] } => true", "{\"pair\":[1,2]}", "{\"pair\":[1,2]}");
    try run("{ value: 3 } => [\"ok\", 4, null]", "{\"value\":3}", "[\"ok\",4,null]");
}

test "conversion functions and string escapes" {
    try run(
        \\{ values: sequence(xs) } => [int("42"), float("2.5"), bool("true"), concat("a\n", join(xs))]
    , "{\"values\":[\"b\",\"c\"]}", "[42,2.5,true,\"a\\nbc\"]");
}

test "unused invalid rules are rejected with transform diagnostics" {
    const cases = [_][]const u8{
        "{ x: simple(a) } => missing",
        "{ x: simple(a) } => mystery(a)",
        "{ x: simple(a) } => int(a, a)",
        "{ x: 1 } => { duplicate: 1, duplicate: 2 }",
        "{ x: simple(a) => a",
    };
    for (cases) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var diagnostic: ?common.Diagnostic = null;
        const input = try parseJson(allocator, "null");
        try std.testing.expectError(error.InvalidTransformRules, transform.apply(allocator, source, input, &diagnostic));
        try std.testing.expect(diagnostic != null);
        try std.testing.expectEqual(common.Diagnostic.Kind.transform, diagnostic.?.kind);
        try std.testing.expect(diagnostic.?.offset <= source.len);
    }
}

test "new output helpers transform strings numbers arrays and entries" {
    try run("{ x: simple(v) } => unquote(v)", "{\"x\":\"\\\"line\\\\n\\\\uD83D\\\\uDE00\\\"\"}", "\"line\\n😀\"");
    try run("{ x: subtree(v) } => pluck(v, \"dynamic-key\")", "{\"x\":[{\"dynamic-key\":1},{\"dynamic-key\":{\"nested\":[true]}}]}", "[1,{\"nested\":[true]}]");
    try run("{ x: subtree(v) } => pluck(v, \"key\")", "{\"x\":[]}", "[]");
    try run("{ x: subtree(v) } => from_entries(v)", "{\"x\":[{\"key\":\"a\",\"value\":1},{\"key\":\"a\",\"value\":{\"nested\":true}},{\"key\":\"any key\",\"value\":[]}]}", "{\"a\":{\"nested\":true},\"any key\":[]}");
    try run("{ x: subtree(v) } => from_entries(v)", "{\"x\":[]}", "{}");
}

test "number preserves the original lexeme when serialized" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const lexeme = "123456789012345678901234567890.123456789e+40";
    const input = try parseJson(allocator, "{\"x\":\"123456789012345678901234567890.123456789e+40\"}");
    var diagnostic: ?common.Diagnostic = null;
    const actual = try transform.apply(allocator, "{ x: simple(v) } => number(v)", input, &diagnostic);
    const serialized = try std.json.Stringify.valueAlloc(allocator, actual, .{});
    try std.testing.expectEqualStrings(lexeme, serialized);
}

test "number strings convert explicitly with bounded int and float conversions" {
    try run("{ x: simple(v) } => int(number(v))", "{\"x\":\"42\"}", "42");
    try run("{ x: simple(v) } => float(number(v))", "{\"x\":\"2.5e1\"}", "25.0");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diagnostic: ?common.Diagnostic = null;
    const input = try parseJson(allocator, "{\"x\":\"9223372036854775808\"}");
    try std.testing.expectError(error.InvalidTransform, transform.apply(allocator, "{ x: simple(v) } => int(number(v))", input, &diagnostic));
}

test "replacement values are not transformed again" {
    try run(
        \\{ x: simple(v) } => { generated: unquote(v) }
        \\{ generated: subtree(v) } => "wrong"
    , "{\"x\":\"\\\"ok\\\"\"}", "{\"generated\":\"ok\"}");
}

test "new output helper names and arity are validated before matching" {
    const cases = [_][]const u8{
        "{ x: 1 } => unquote()",
        "{ x: 1 } => number(\"1\", \"2\")",
        "{ x: 1 } => pluck([])",
        "{ x: 1 } => pluck([], \"key\", \"extra\")",
        "{ x: 1 } => from_entries([], [])",
        "{ x: 1 } => require_equal()",
        "{ x: 1 } => require_equal(1)",
        "{ x: 1 } => require_equal(1, 1, 1)",
    };
    for (cases) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var diagnostic: ?common.Diagnostic = null;
        try std.testing.expectError(error.InvalidTransformRules, transform.apply(allocator, source, .null, &diagnostic));
        try std.testing.expectEqual(common.Diagnostic.Kind.transform, diagnostic.?.kind);
    }
}

test "new output helpers reject invalid syntax and argument types without partial results" {
    const Case = struct { source: []const u8, input: []const u8 };
    const cases = [_]Case{
        .{ .source = "{ x: subtree(v) } => unquote(v)", .input = "{\"x\":1}" },
        .{ .source = "{ x: simple(v) } => unquote(v)", .input = "{\"x\":\"true\"}" },
        .{ .source = "{ x: simple(v) } => unquote(v)", .input = "{\"x\":\"\\\"a\\\" trailing\"}" },
        .{ .source = "{ x: subtree(v) } => number(v)", .input = "{\"x\":false}" },
        .{ .source = "{ x: simple(v) } => number(v)", .input = "{\"x\":\"01\"}" },
        .{ .source = "{ x: subtree(v) } => pluck(v, \"k\")", .input = "{\"x\":{}}" },
        .{ .source = "{ x: subtree(v) } => pluck(v, \"k\")", .input = "{\"x\":[{\"k\":1},2]}" },
        .{ .source = "{ x: subtree(v) } => pluck(v, \"k\")", .input = "{\"x\":[{\"k\":1},{}]}" },
        .{ .source = "{ x: subtree(v) } => pluck(v, 1)", .input = "{\"x\":[]}" },
        .{ .source = "{ x: subtree(v) } => from_entries(v)", .input = "{\"x\":{}}" },
        .{ .source = "{ x: subtree(v) } => from_entries(v)", .input = "{\"x\":[{\"key\":\"a\",\"value\":1},{\"key\":\"b\"}]}" },
        .{ .source = "{ x: subtree(v) } => from_entries(v)", .input = "{\"x\":[{\"key\":1,\"value\":2}]}" },
        .{ .source = "{ x: subtree(v) } => from_entries(v)", .input = "{\"x\":[{\"key\":\"a\",\"value\":1,\"extra\":2}]}" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var diagnostic: ?common.Diagnostic = null;
        const input = try parseJson(allocator, case.input);
        try std.testing.expectError(error.InvalidTransform, transform.apply(allocator, case.source, input, &diagnostic));
        try std.testing.expectEqual(common.Diagnostic.Kind.transform, diagnostic.?.kind);
        try std.testing.expect(diagnostic.?.offset < case.source.len);
    }
}

test "require_equal returns equal values and preserves nested structure" {
    try run("{ a: subtree(a), b: subtree(b) } => require_equal(a, b)", "{\"a\":{\"items\":[1,null,true]},\"b\":{\"items\":[1,null,true]}}", "{\"items\":[1,null,true]}");
    try run("{ a: simple(a), b: simple(b) } => require_equal(a, b)", "{\"a\":\"tag\",\"b\":\"tag\"}", "\"tag\"");
    try run("{ a: subtree(a), b: subtree(b) } => require_equal(a, b)", "{\"a\":{\"x\":1,\"y\":2},\"b\":{\"y\":2,\"x\":1}}", "{\"x\":1,\"y\":2}");
}

test "require_equal rejects mismatches with function source offset" {
    const source = "{ a: subtree(a), b: subtree(b) } => require_equal(a, b)";
    const inputs = [_][]const u8{
        "{\"a\":\"a\",\"b\":\"b\"}",
        "{\"a\":[1],\"b\":[1,2]}",
        "{\"a\":{\"nested\":1},\"b\":{\"nested\":2}}",
        "{\"a\":1,\"b\":1.0}",
        "{\"a\":null,\"b\":false}",
    };
    for (inputs) |input_text| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var diagnostic: ?common.Diagnostic = null;
        const input = try parseJson(allocator, input_text);
        try std.testing.expectError(error.InvalidTransform, transform.apply(allocator, source, input, &diagnostic));
        try std.testing.expectEqual(common.Diagnostic.Kind.transform, diagnostic.?.kind);
        try std.testing.expectEqual(std.mem.indexOf(u8, source, "require_equal").?, diagnostic.?.offset);
        try std.testing.expectEqualStrings("require_equal values differ", diagnostic.?.message);
    }
}

test "type errors report the expression source offset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "{ x: simple(v) } => int(v)";
    var diagnostic: ?common.Diagnostic = null;
    const input = try parseJson(allocator, "{\"x\":\"nope\"}");
    try std.testing.expectError(error.InvalidTransform, transform.apply(allocator, source, input, &diagnostic));
    try std.testing.expect(diagnostic != null);
    try std.testing.expectEqual(common.Diagnostic.Kind.transform, diagnostic.?.kind);
    try std.testing.expectEqual(@as(usize, 20), diagnostic.?.offset);
}
