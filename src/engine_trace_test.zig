const std = @import("std");
const engine = @import("engine.zig");
const common = @import("common.zig");

fn compile(a: std.mem.Allocator, source: []const u8) !engine.Grammar {
    var diagnostic: ?common.Diagnostic = null;
    return engine.compile(a, source, false, &diagnostic);
}

fn event(result: engine.ParseResult, name: []const u8) !common.TraceEvent {
    for (result.trace) |item| if (std.mem.eql(u8, item.rule, name)) return item;
    return error.MissingEvent;
}

test "abandoned successes retain local reach and invocation ancestry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\root document
        \\document <- header (first / second)
        \\header <- "Hi "
        \\first <- prefix "X"
        \\prefix <- "abc"
        \\second <- "ab" "Y"
    ;
    const grammar = try compile(a, source);
    const result = try engine.parse(a, &grammar, "Hi abcZ", true);
    try std.testing.expectEqual(@as(usize, 6), result.diagnostic.?.offset);
    const first = try event(result, "first");
    const prefix = try event(result, "prefix");
    try std.testing.expectEqual(@as(usize, 3), first.end);
    try std.testing.expectEqual(@as(usize, 6), first.furthest);
    try std.testing.expectEqual(@as(usize, 5), (try event(result, "second")).furthest);
    try std.testing.expectEqual(first.id, prefix.parent_id.?);
    try std.testing.expect(prefix.matched and prefix.backtracked);
    try std.testing.expectEqual(.backtracked, prefix.disposition);
    try std.testing.expectEqual(prefix.id, result.summary.?.furthest_attempt.?.id);
    try std.testing.expectEqual(prefix.id, result.summary.?.last_success.?.id);
    try std.testing.expect(result.summary.?.last_success.?.backtracked);
    try std.testing.expectEqual(first.id, result.summary.?.final_failure.?.attempt_id.?);
    const expected = result.diagnostic.?.expected[0];
    try std.testing.expectEqualStrings("\"X\"", source[expected.grammar_offset..expected.grammar_end.?]);
}

test "lookahead reach is not the retained error or consumption" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grammar = try compile(a, "root document\ndocument <- &probe \"Z\"\nprobe <- \"abcdef\"\n");
    const result = try engine.parse(a, &grammar, "abcdef", true);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostic.?.offset);
    const probe = try event(result, "probe");
    try std.testing.expect(probe.matched and probe.lookahead);
    try std.testing.expectEqual(.lookahead, probe.disposition);
    try std.testing.expectEqual(@as(usize, 6), result.summary.?.furthest_attempt.?.furthest);
    try std.testing.expectEqual(@as(usize, 0), result.summary.?.final_failure.?.offset);
}

test "EOF failure is synthetic and separate from locally matched root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grammar = try compile(a, "root document\ndocument <- \"Hi\"\n");
    const result = try engine.parse(a, &grammar, "Hi!", true);
    try std.testing.expect(result.value == null);
    try std.testing.expect(result.trace[0].matched);
    try std.testing.expectEqual(@as(usize, 2), result.summary.?.final_failure.?.offset);
    try std.testing.expect(result.summary.?.final_failure.?.synthetic_eof);
    try std.testing.expectEqual(result.trace[0].id, result.summary.?.final_failure.?.attempt_id.?);
}

test "execution summaries survive truncation and later rollback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grammar = try compile(a, "root document\ndocument <- part* \"Z\"\npart <- \"a\"\n");
    const input = try a.alloc(u8, 1101);
    @memset(input[0..1100], 'a');
    input[1100] = 'X';
    const result = try engine.parse(a, &grammar, input, true);
    const summary = result.summary.?;
    try std.testing.expectEqual(@as(usize, 1024), result.trace.len);
    try std.testing.expect(summary.trace_truncated);
    try std.testing.expectEqual(@as(usize, 1102), summary.total_attempts);
    try std.testing.expectEqual(summary.total_attempts - 1024, summary.omitted_attempts);
    try std.testing.expectEqual(@as(usize, 1100), summary.furthest_attempt.?.furthest);
    try std.testing.expectEqual(@as(usize, 1100), summary.last_success.?.end);
    try std.testing.expect(summary.last_success.?.backtracked);
    try std.testing.expect(summary.last_success.?.id > result.trace[1023].id);
}

test "partial literal comparisons and repeated calls have distinct IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grammar = try compile(a, "root document\ndocument <- part part\npart <- \"abcdef\"\n");
    const result = try engine.parse(a, &grammar, "abcdefabcX", true);
    try std.testing.expectEqual(@as(usize, 9), result.diagnostic.?.offset);
    try std.testing.expectEqual(@as(usize, 9), result.summary.?.furthest_attempt.?.furthest);
    try std.testing.expect(result.trace[0].id != result.trace[1].id);
    try std.testing.expectEqual(result.trace[0].parent_id, result.trace[1].parent_id);
    try std.testing.expectEqual(@as(usize, 6), result.trace[1].end);
}

test "successful choices preserve abandoned branches without polluting errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grammar = try compile(a, "root document\ndocument <- (first / second) \"!\"\nfirst <- prefix \"X\"\nprefix <- \"ab\"\nsecond <- \"a\"\n");
    const result = try engine.parse(a, &grammar, "abZ", true);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostic.?.offset);
    try std.testing.expectEqual(@as(usize, 2), result.summary.?.furthest_attempt.?.furthest);
    try std.testing.expect((try event(result, "prefix")).backtracked);
    try std.testing.expectEqualStrings("second", result.summary.?.last_success.?.rule);
}

test "nested probes record independent lookahead and rollback flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grammar = try compile(a, "root document\ndocument <- !probe \"a\"\nprobe <- part \"X\"\npart <- \"a\"\n");
    const result = try engine.parse(a, &grammar, "a", true);
    try std.testing.expect(result.diagnostic == null);
    const part = try event(result, "part");
    try std.testing.expect(part.lookahead and part.backtracked and part.matched);
    try std.testing.expectEqual(.lookahead, part.disposition);
    try std.testing.expectEqualStrings("document", result.summary.?.last_success.?.rule);
    try std.testing.expectEqual(.retained, result.summary.?.last_success.?.disposition);
}

test "authoring work limit stays bounded and counts every completed attempt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grammar = try compile(a, "root s\ns <- \"a\" s \"b\" / \"a\" s \"c\" / \"\"\n");
    const input = "aaaaaaaaaaaaaaaaaaaaaaaaaX";
    const plain = try engine.parse(a, &grammar, input, false);
    const author = try engine.parse(a, &grammar, input, true);
    try std.testing.expectEqual(common.Diagnostic.Kind.limit, author.diagnostic.?.kind);
    try std.testing.expectEqual(plain.diagnostic.?.offset, author.diagnostic.?.offset);
    try std.testing.expectEqualStrings(plain.diagnostic.?.message, author.diagnostic.?.message);
    try std.testing.expect(author.summary.?.trace_truncated);
    try std.testing.expectEqual(@as(usize, 1024), author.trace.len);
}

test "maximum rule depth returns a limit rather than overflowing observer frames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source: std.Io.Writer.Allocating = .init(a);
    try source.writer.writeAll("root r0\n");
    for (0..300) |i| try source.writer.print("r{d} <- r{d}\n", .{ i, i + 1 });
    try source.writer.writeAll("r300 <- \"a\"\n");
    const grammar = try compile(a, source.written());
    const result = try engine.parse(a, &grammar, "a", true);
    try std.testing.expectEqual(common.Diagnostic.Kind.limit, result.diagnostic.?.kind);
    // The depth-256 rule enters, then its depth-257 expression hits the guard.
    try std.testing.expectEqual(@as(usize, 257), result.summary.?.total_attempts);
    try std.testing.expectEqual(.limit, result.trace[0].outcome);
    try std.testing.expectEqual(@as(usize, 256), result.trace[0].depth);
}

test "recorder storage caps and does not preallocate the full trace for small tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var recorder = @import("trace.zig").Recorder.init(a);
    try recorder.enter("root", 0, 4, 0, 0);
    try std.testing.expect(recorder.events.capacity < 1024);
    for (0..2000) |i| {
        try recorder.enter("part", 5, 9, i, 1);
        recorder.touch(i + 1);
        recorder.leave(i + 1, false);
    }
    recorder.leave(null, false);
    const summary = recorder.finish(null);
    try std.testing.expectEqual(@as(usize, 1024), recorder.events.capacity);
    try std.testing.expect(recorder.frames.capacity <= 258);
    try std.testing.expectEqual(@as(usize, 2001), summary.total_attempts);
    try std.testing.expectEqual(@as(usize, 2000), summary.last_success.?.end);
}

test "production and authoring modes preserve values errors and limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expressions = [_][]const u8{
        "value:[a-z]+",         "(\"ab\" / \"a\") \"X\"", "(\"a\" \"b\")* \"X\"",
        "(\"a\" \"b\")? \"X\"", "&\"abc\" \"X\"",         "!\"abc\" .+",
        "\"Hi\"",               "document",               "(\"a\"?)*",
        "(x:\"a\")+",           "(x:\"a\" / y:\"b\")*",   "!(!\"a\") \"a\"",
    };
    for (expressions) |expression| {
        const source = try std.fmt.allocPrint(a, "root document\ndocument <- {s}\n", .{expression});
        const grammar = try compile(a, source);
        for ([_][]const u8{ "", "a", "abX", "abc", "Hi!", "aX", "bbb", "Hi" }) |input| {
            const plain = try engine.parse(a, &grammar, input, false);
            const author = try engine.parse(a, &grammar, input, true);
            try std.testing.expect(plain.summary == null and plain.trace.len == 0);
            try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, plain.value, .{}), try std.json.Stringify.valueAlloc(a, author.value, .{}));
            try std.testing.expectEqual(plain.diagnostic == null, author.diagnostic == null);
            if (plain.diagnostic) |expected| {
                const actual = author.diagnostic.?;
                try std.testing.expectEqual(expected.kind, actual.kind);
                try std.testing.expectEqual(expected.offset, actual.offset);
                try std.testing.expectEqual(expected.grammar_offset, actual.grammar_offset);
                try std.testing.expectEqual(expected.grammar_end, actual.grammar_end);
                try std.testing.expectEqualStrings(expected.message, actual.message);
                try std.testing.expectEqual(expected.expected.len, actual.expected.len);
                for (expected.expected, actual.expected) |left, right| {
                    try std.testing.expectEqualStrings(left.message, right.message);
                    try std.testing.expectEqual(left.grammar_offset, right.grammar_offset);
                    try std.testing.expectEqual(left.grammar_end, right.grammar_end);
                }
            }
        }
    }
}
