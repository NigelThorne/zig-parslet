const std = @import("std");
const common = @import("common.zig");

/// Authoring-only recorder. Rule IDs count entries; retained events count completions.
/// Storage stays bounded even when callers make millions of speculative attempts.
pub const Recorder = struct {
    const event_limit = 1024;
    const frame_limit = 258; // Runtime rejects expression depth > 256.

    allocator: std.mem.Allocator,
    frames: std.ArrayList(common.TraceEvent) = .empty,
    events: std.ArrayList(common.TraceEvent) = .empty,
    next_id: usize = 0,
    max_recorded_id: usize = 0,
    probe_depth: usize = 0,
    summary: common.TraceSummary = .{},

    pub fn init(allocator: std.mem.Allocator) Recorder {
        return .{ .allocator = allocator };
    }

    pub fn enter(self: *Recorder, rule: []const u8, grammar_offset: usize, grammar_end: usize, pos: usize, depth: usize) !void {
        const parent_id = self.currentId();
        std.debug.assert(self.frames.items.len < frame_limit);
        // Reserve completion space before entering so leave() cannot allocate.
        // Grow geometrically, not a full 1024-event buffer for every tiny test.
        if (self.events.capacity < event_limit and self.next_id >= self.events.capacity) {
            try self.events.ensureTotalCapacityPrecise(self.allocator, @min(event_limit, @max(8, self.events.capacity * 2)));
        }
        if (self.frames.items.len == self.frames.capacity) {
            try self.frames.ensureTotalCapacityPrecise(self.allocator, @min(frame_limit, @max(8, self.frames.capacity * 2)));
        }
        self.frames.appendAssumeCapacity(.{
            .id = self.next_id,
            .parent_id = parent_id,
            .rule = rule,
            .grammar_offset = grammar_offset,
            .grammar_end = grammar_end,
            .start = pos,
            .end = pos,
            .furthest = pos,
            .depth = depth,
            .matched = false,
            .lookahead = self.probe_depth > 0,
            .disposition = if (self.probe_depth > 0) .lookahead else .retained,
        });
        self.next_id += 1;
    }

    pub fn currentId(self: *const Recorder) ?usize {
        if (self.frames.items.len == 0) return null;
        return self.frames.items[self.frames.items.len - 1].id;
    }

    pub fn touch(self: *Recorder, pos: usize) void {
        if (self.frames.items.len > 0) {
            const frame = &self.frames.items[self.frames.items.len - 1];
            frame.furthest = @max(frame.furthest, pos);
        }
    }

    pub fn leave(self: *Recorder, end: ?usize, limited: bool) void {
        var event = self.frames.pop().?;
        event.matched = end != null;
        event.end = end orelse event.start;
        event.furthest = @max(event.furthest, event.end);
        event.outcome = if (limited) .limit else if (end != null) .matched else .failed;
        self.touch(event.furthest);
        if (self.events.items.len < event_limit) {
            self.events.appendAssumeCapacity(event);
            self.max_recorded_id = @max(self.max_recorded_id, event.id);
        }
        const old = self.summary.furthest_attempt;
        if (old == null or event.furthest > old.?.furthest or
            (event.furthest == old.?.furthest and (event.depth > old.?.depth or
                (event.depth == old.?.depth and event.id < old.?.id))))
        {
            self.summary.furthest_attempt = event;
        }
        if (event.matched) self.summary.last_success = event;
    }

    fn abandon(event: *common.TraceEvent, first_id: usize) void {
        if (event.id < first_id) return;
        event.backtracked = true;
        event.disposition = if (event.lookahead) .lookahead else .backtracked;
    }

    /// All completed invocations entered since this checkpoint were rolled back.
    pub fn rollback(self: *Recorder, first_id: usize) void {
        if (first_id <= self.max_recorded_id) {
            for (self.events.items) |*event| abandon(event, first_id);
        }
        if (self.summary.furthest_attempt) |*event| abandon(event, first_id);
        if (self.summary.last_success) |*event| abandon(event, first_id);
    }

    pub fn finish(self: *Recorder, failure: ?common.FailureSite) common.TraceSummary {
        self.summary.total_attempts = self.next_id;
        self.summary.recorded_attempts = self.events.items.len;
        self.summary.omitted_attempts = self.next_id - self.events.items.len;
        self.summary.trace_truncated = self.summary.omitted_attempts > 0;
        self.summary.final_failure = failure;
        return self.summary;
    }
};
