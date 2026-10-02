/// Offsets are zero-based bytes. The CLI renders one-based line and byte columns.
pub const Diagnostic = struct {
    kind: Kind,
    offset: usize,
    message: []const u8,
    grammar_offset: ?usize = null,
    grammar_end: ?usize = null,
    rule: ?[]const u8 = null,
    expected: []const Expectation = &.{},
    expected_truncated: bool = false,

    pub const Kind = enum { grammar, input, transform, limit };
};

/// One expected alternative at the reported input position.
pub const Expectation = struct {
    message: []const u8,
    grammar_offset: usize,
    grammar_end: ?usize = null,
    attempt_id: ?usize = null,
    rule: ?[]const u8 = null,
};

/// A successful attempt may later be discarded by backtracking.
pub const TraceEvent = struct {
    rule: []const u8,
    start: usize,
    end: usize,
    matched: bool,
    depth: usize,
    id: usize = 0,
    parent_id: ?usize = null,
    grammar_offset: usize = 0,
    grammar_end: usize = 0,
    furthest: usize = 0,
    outcome: enum { matched, failed, limit } = .failed,
    disposition: enum { retained, backtracked, lookahead } = .retained,
    lookahead: bool = false,
    backtracked: bool = false,
};

pub const FailureSite = struct {
    offset: usize,
    rule: ?[]const u8 = null,
    attempt_id: ?usize = null,
    grammar_offset: ?usize = null,
    grammar_end: ?usize = null,
    synthetic_eof: bool = false,
};

pub const TraceSummary = struct {
    total_attempts: usize = 0,
    recorded_attempts: usize = 0,
    omitted_attempts: usize = 0,
    trace_truncated: bool = false,
    furthest_attempt: ?TraceEvent = null,
    last_success: ?TraceEvent = null,
    final_failure: ?FailureSite = null,
};
