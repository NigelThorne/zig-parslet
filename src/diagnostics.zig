const std = @import("std");
pub const Location = struct { line: usize, column: usize };

pub fn location(source: []const u8, offset: usize) Location {
    var result: Location = .{ .line = 1, .column = 1 };
    for (source[0..@min(offset, source.len)]) |byte| {
        if (byte == '\n') {
            result.line += 1;
            result.column = 1;
        } else result.column += 1;
    }
    return result;
}

/// Bounded ASCII rendering prevents document text from injecting terminal controls.
/// Non-ASCII bytes are escaped, so the caret remains exact for byte-based parsing.
pub fn highlight(allocator: std.mem.Allocator, name: []const u8, source: []const u8, offset: usize) ![]const u8 {
    const pos = @min(offset, source.len);
    const loc = location(source, pos);
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..pos], '\n')) |i| i + 1 else 0;
    const line_end = if (std.mem.indexOfScalarPos(u8, source, pos, '\n')) |i| i else source.len;
    const start = @max(line_start, pos -| 60);
    const end = @min(line_end, pos +| 100);
    var text: std.Io.Writer.Allocating = .init(allocator);
    var caret: usize = 0;
    if (start > line_start) {
        try text.writer.writeAll("...");
        caret += 3;
    }
    for (source[start..end], start..) |byte, i| {
        const width: usize = if (byte >= 32 and byte < 127) 1 else 4;
        if (i < pos) caret += width;
        if (width == 1) try text.writer.writeByte(byte) else try text.writer.print("\\x{x:0>2}", .{byte});
    }
    if (end < line_end) try text.writer.writeAll("...");
    var output: std.Io.Writer.Allocating = .init(allocator);
    const safe_name = try escape(allocator, name);
    try output.writer.print("{s}:{d}:{d}\n  {s}\n  ", .{ safe_name, loc.line, loc.column, text.written() });
    try output.writer.splatByteAll(' ', caret);
    try output.writer.writeAll("^\n");
    return output.toOwnedSlice();
}

pub fn escape(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    for (text) |byte| {
        if (byte >= 32 and byte < 127) try output.writer.writeByte(byte) else try output.writer.print("\\x{x:0>2}", .{byte});
    }
    return output.toOwnedSlice();
}

pub fn equal(a: std.json.Value, b: std.json.Value) bool {
    return equalAt(a, b, 0);
}

fn equalAt(a: std.json.Value, b: std.json.Value, depth: usize) bool {
    if (depth > 512 or std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| v == b.float,
        .number_string => |v| std.mem.eql(u8, v, b.number_string),
        .string => |v| std.mem.eql(u8, v, b.string),
        .array => |v| blk: {
            if (v.items.len != b.array.items.len) break :blk false;
            for (v.items, b.array.items) |left, right| {
                if (!equalAt(left, right, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .object => |v| blk: {
            if (v.count() != b.object.count()) break :blk false;
            var it = v.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!equalAt(entry.value_ptr.*, other, depth + 1)) break :blk false;
            }
            break :blk true;
        },
    };
}
