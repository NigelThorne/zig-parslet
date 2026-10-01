/// Offsets are zero-based bytes. The CLI renders one-based line and byte columns.
pub const Diagnostic = struct {
    kind: Kind,
    offset: usize,
    message: []const u8,
    grammar_offset: ?usize = null,
    rule: ?[]const u8 = null,

    pub const Kind = enum { grammar, input, transform, limit };
};

/// A successful attempt may later be discarded by backtracking.
pub const TraceEvent = struct {
    rule: []const u8,
    start: usize,
    end: usize,
    matched: bool,
    depth: usize,
};
