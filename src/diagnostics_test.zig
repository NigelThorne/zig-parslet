const std = @import("std");
const diagnostics = @import("diagnostics.zig");

test "locations are one based with byte columns and EOF support" {
    const loc = diagnostics.location("one\ntwo", 5);
    try std.testing.expectEqual(@as(usize, 2), loc.line);
    try std.testing.expectEqual(@as(usize, 2), loc.column);
    const eof = diagnostics.location("one\n", 4);
    try std.testing.expectEqual(@as(usize, 2), eof.line);
    try std.testing.expectEqual(@as(usize, 1), eof.column);
}

test "highlight escapes terminal controls and marks EOF" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const output = try diagnostics.highlight(arena.allocator(), "input.txt", "a\x1bb", 2);
    try std.testing.expect(std.mem.indexOf(u8, output, "input.txt:1:3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\\x1b") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, output, 0x1b) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, output, '^') != null);
}

test "JSON comparison ignores object key ordering" {
    const a = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"a\":1,\"b\":[true,null]}", .{});
    defer a.deinit();
    const b = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"b\":[true,null],\"a\":1}", .{});
    defer b.deinit();
    try std.testing.expect(diagnostics.equal(a.value, b.value));
}
