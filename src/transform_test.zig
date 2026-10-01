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
