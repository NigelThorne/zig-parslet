/// Offsets are zero-based bytes. The CLI renders one-based line and byte columns.
pub const Diagnostic = struct {
    kind: Kind,
    offset: usize,
    message: []const u8,
    grammar_offset: ?usize = null,
    rule: ?[]const u8 = null,
    expected: []const Expectation = &.{},
    expected_truncated: bool = false,

    pub const Kind = enum { grammar, input, transform, limit };
};

/// One expected alternative at the reported input position.
pub const Expectation = struct {
    message: []const u8,
    grammar_offset: usize,
    rule: ?[]const u8 = null,
};

/// A successful attempt may later be discarded by backtracking.
pub const TraceEvent = struct {
    rule: []const u8,
    start: usize,
    end: usize,
    matched: bool,
    depth: usize,
};
