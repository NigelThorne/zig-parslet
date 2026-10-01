const std = @import("std");
const common = @import("common.zig");
const numbers = @import("numbers.zig");

pub const TestCase = struct {
    name: []const u8,
    input: []const u8,
    expect: ?std.json.Value = null,
    reject: bool = false,
    source_offset: usize,
};

const ClassRange = struct { first: u8, last: u8 };

const Expr = union(enum) {
    literal: struct { text: []const u8, offset: usize },
    class: struct { ranges: []const ClassRange, inverted: bool, offset: usize, expected: []const u8 },
    any: usize,
    reference: struct { name: []const u8, offset: usize },
    sequence: []const *Expr,
    choice: []const *Expr,
    repeat: struct { child: *Expr, min: usize, max: ?usize, offset: usize },
    not: struct { child: *Expr, offset: usize },
    and_: struct { child: *Expr, offset: usize },
    capture: struct { name: []const u8, child: *Expr, offset: usize },
};

const Rule = struct { name: []const u8, expr: *Expr, offset: usize };

pub const Grammar = struct {
    tests: []const TestCase,
    rules: []const Rule,
    root: usize,
};

pub const ParseResult = struct {
    value: ?std.json.Value = null,
    diagnostic: ?common.Diagnostic = null,
    trace: []const common.TraceEvent = &.{},
};

const GrammarParser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    pos: usize = 0,
    diagnostic: *?common.Diagnostic,
    rules: std.ArrayList(Rule) = .empty,
    tests: std.ArrayList(TestCase) = .empty,
    root_name: ?[]const u8 = null,
    root_offset: usize = 0,
    load_tests: bool,
    nesting: usize = 0,
    work: usize = 0,

    fn fail(self: *GrammarParser, at: usize, message: []const u8) error{InvalidGrammar} {
        self.diagnostic.* = .{ .kind = .grammar, .offset = at, .message = message };
        return error.InvalidGrammar;
    }

    fn eof(self: *const GrammarParser) bool {
        return self.pos >= self.source.len;
    }
    fn peek(self: *const GrammarParser) u8 {
        return self.source[self.pos];
    }

    fn skipSpace(self: *GrammarParser) void {
        while (!self.eof()) {
            if (std.ascii.isWhitespace(self.peek())) {
                self.pos += 1;
                continue;
            }
            if (self.peek() == '#') {
                while (!self.eof() and self.peek() != '\n') self.pos += 1;
                continue;
            }
            break;
        }
    }

    fn identifier(self: *GrammarParser) ?[]const u8 {
        if (self.eof() or !(std.ascii.isAlphabetic(self.peek()) or self.peek() == '_')) return null;
        const start = self.pos;
        self.pos += 1;
        while (!self.eof() and (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_')) self.pos += 1;
        return self.source[start..self.pos];
    }

    fn starts(self: *const GrammarParser, s: []const u8) bool {
        return std.mem.startsWith(u8, self.source[self.pos..], s);
    }

    fn isDeclaration(self: *GrammarParser) bool {
        var p = self.pos;
        while (p > 0 and (self.source[p - 1] == ' ' or self.source[p - 1] == '\t' or self.source[p - 1] == '\r')) p -= 1;
        if (p > 0 and self.source[p - 1] != '\n') return false;
        if (self.starts("@test") or self.starts("root ")) return true;
        var q = self.pos;
        if (q >= self.source.len or !(std.ascii.isAlphabetic(self.source[q]) or self.source[q] == '_')) return false;
        q += 1;
        while (q < self.source.len and (std.ascii.isAlphanumeric(self.source[q]) or self.source[q] == '_')) q += 1;
        while (q < self.source.len and (self.source[q] == ' ' or self.source[q] == '\t')) q += 1;
        return q + 1 < self.source.len and self.source[q] == '<' and self.source[q + 1] == '-';
    }

    fn node(self: *GrammarParser, value: Expr) !*Expr {
        self.work += 1;
        if (self.work > 100_000) return self.fail(self.pos, "grammar work limit exceeded");
        const result = try self.allocator.create(Expr);
        result.* = value;
        return result;
    }

    fn hex4(self: *GrammarParser, at: usize) !u16 {
        if (self.pos + 4 > self.source.len) return self.fail(at, "incomplete unicode escape");
        const value = std.fmt.parseInt(u16, self.source[self.pos .. self.pos + 4], 16) catch return self.fail(at, "invalid unicode escape");
        self.pos += 4;
        return value;
    }

    fn appendCodepoint(self: *GrammarParser, out: *std.ArrayList(u8), cp: u21, at: usize) !void {
        var bytes: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &bytes) catch return self.fail(at, "invalid unicode codepoint");
        try out.appendSlice(self.allocator, bytes[0..len]);
    }

    fn parseString(self: *GrammarParser) ![]const u8 {
        const quote = self.peek();
        const at = self.pos;
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (!self.eof()) {
            const c = self.peek();
            self.pos += 1;
            if (c == quote) return try out.toOwnedSlice(self.allocator);
            if (c != '\\') {
                if (c < 0x20) return self.fail(self.pos - 1, "unescaped control character in string");
                try out.append(self.allocator, c);
                continue;
            }
            if (self.eof()) return self.fail(at, "unterminated string");
            const escape_at = self.pos - 1;
            const e = self.peek();
            self.pos += 1;
            switch (e) {
                'n' => try out.append(self.allocator, '\n'),
                'r' => try out.append(self.allocator, '\r'),
                't' => try out.append(self.allocator, '\t'),
                'b' => try out.append(self.allocator, 0x08),
                'f' => try out.append(self.allocator, 0x0c),
                '\\' => try out.append(self.allocator, '\\'),
                '/' => try out.append(self.allocator, '/'),
                '"' => try out.append(self.allocator, '"'),
                '\'' => try out.append(self.allocator, '\''),
                'u' => {
                    const first = try self.hex4(escape_at);
                    var cp: u21 = first;
                    if (first >= 0xD800 and first <= 0xDBFF) {
                        if (self.pos + 2 > self.source.len or self.source[self.pos] != '\\' or self.source[self.pos + 1] != 'u') return self.fail(escape_at, "high surrogate requires low surrogate");
                        self.pos += 2;
                        const second = try self.hex4(escape_at);
                        if (second < 0xDC00 or second > 0xDFFF) return self.fail(escape_at, "invalid low surrogate");
                        cp = @intCast(0x10000 + ((@as(u32, first) - 0xD800) << 10) + (@as(u32, second) - 0xDC00));
                    } else if (first >= 0xDC00 and first <= 0xDFFF) return self.fail(escape_at, "unexpected low surrogate");
                    try self.appendCodepoint(&out, cp, escape_at);
                },
                else => return self.fail(escape_at, "unknown string escape"),
            }
        }
        return self.fail(at, "unterminated string");
    }

    fn classAtom(self: *GrammarParser, at: usize) !struct { byte: u8, escaped: bool } {
        if (self.eof() or self.peek() == ']') return self.fail(at, "expected character class atom");
        var c = self.peek();
        self.pos += 1;
        if (c != '\\') return .{ .byte = c, .escaped = false };
        if (self.eof()) return self.fail(at, "malformed character class escape");
        c = self.peek();
        self.pos += 1;
        return .{ .byte = switch (c) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            ']' => ']',
            '-' => '-',
            '\\' => '\\',
            'x' => blk: {
                const escape_at = self.pos - 2;
                if (self.pos + 2 > self.source.len or !std.ascii.isHex(self.source[self.pos]) or !std.ascii.isHex(self.source[self.pos + 1])) return self.fail(escape_at, "hex byte escape requires two hex digits");
                const byte = std.fmt.parseInt(u8, self.source[self.pos .. self.pos + 2], 16) catch unreachable;
                self.pos += 2;
                break :blk byte;
            },
            else => return self.fail(self.pos - 2, "unknown character class escape"),
        }, .escaped = true };
    }

    fn parseClass(self: *GrammarParser, at: usize) !*Expr {
        self.pos += 1;
        const inverted = !self.eof() and self.peek() == '^';
        if (inverted) self.pos += 1;
        var ranges: std.ArrayList(ClassRange) = .empty;
        while (!self.eof() and self.peek() != ']') {
            const first = try self.classAtom(at);
            if (!self.eof() and self.peek() == '-' and self.pos + 1 < self.source.len and self.source[self.pos + 1] != ']') {
                self.pos += 1;
                const last = try self.classAtom(at);
                if (first.byte > last.byte) return self.fail(at, "reversed character class range");
                try ranges.append(self.allocator, .{ .first = first.byte, .last = last.byte });
            } else {
                try ranges.append(self.allocator, .{ .first = first.byte, .last = first.byte });
            }
        }
        if (self.eof()) return self.fail(at, "unterminated character class");
        self.pos += 1;
        return self.node(.{ .class = .{
            .ranges = try ranges.toOwnedSlice(self.allocator),
            .inverted = inverted,
            .offset = at,
            .expected = try std.fmt.allocPrint(self.allocator, "expected character class {s}", .{self.source[at..self.pos]}),
        } });
    }

    fn primary(self: *GrammarParser) anyerror!*Expr {
        self.skipSpace();
        if (self.eof()) return self.fail(self.pos, "expected expression");
        const at = self.pos;
        if (self.peek() == '"' or self.peek() == '\'') return self.node(.{ .literal = .{ .text = try self.parseString(), .offset = at } });
        if (self.peek() == '[') return self.parseClass(at);
        if (self.peek() == '.') {
            self.pos += 1;
            return self.node(.{ .any = at });
        }
        if (self.peek() == '(') {
            self.pos += 1;
            self.nesting += 1;
            if (self.nesting > 512) return self.fail(at, "grammar nesting limit exceeded");
            defer self.nesting -= 1;
            const inner = try self.expression();
            self.skipSpace();
            if (self.eof() or self.peek() != ')') return self.fail(at, "expected ')'");
            self.pos += 1;
            return inner;
        }
        const name = self.identifier() orelse return self.fail(at, "expected expression");
        self.skipSpace();
        if (!self.eof() and self.peek() == ':') {
            self.pos += 1;
            return self.node(.{ .capture = .{ .name = name, .child = try self.prefixed(), .offset = at } });
        }
        return self.node(.{ .reference = .{ .name = name, .offset = at } });
    }

    fn suffixed(self: *GrammarParser) anyerror!*Expr {
        var child = try self.primary();
        self.skipSpace();
        if (!self.eof()) {
            const c = self.peek();
            if (c == '*' or c == '+' or c == '?') {
                self.pos += 1;
                child = try self.node(.{ .repeat = .{ .child = child, .min = if (c == '+') 1 else 0, .max = if (c == '?') 1 else null, .offset = self.pos - 1 } });
            }
        }
        return child;
    }

    fn prefixed(self: *GrammarParser) anyerror!*Expr {
        self.nesting += 1;
        if (self.nesting > 512) return self.fail(self.pos, "grammar nesting limit exceeded");
        defer self.nesting -= 1;
        self.skipSpace();
        if (!self.eof() and (self.peek() == '!' or self.peek() == '&')) {
            const c = self.peek();
            const at = self.pos;
            self.pos += 1;
            const child = try self.prefixed();
            return self.node(if (c == '!') .{ .not = .{ .child = child, .offset = at } } else .{ .and_ = .{ .child = child, .offset = at } });
        }
        return self.suffixed();
    }

    fn sequence(self: *GrammarParser) anyerror!*Expr {
        var items: std.ArrayList(*Expr) = .empty;
        while (true) {
            self.skipSpace();
            if (self.eof() or self.peek() == ')' or self.peek() == '/' or self.isDeclaration()) break;
            try items.append(self.allocator, try self.prefixed());
        }
        if (items.items.len == 0) return self.fail(self.pos, "expected expression");
        if (items.items.len == 1) return items.items[0];
        return self.node(.{ .sequence = try items.toOwnedSlice(self.allocator) });
    }

    fn expression(self: *GrammarParser) anyerror!*Expr {
        var choices: std.ArrayList(*Expr) = .empty;
        try choices.append(self.allocator, try self.sequence());
        while (true) {
            self.skipSpace();
            if (self.eof() or self.peek() != '/') break;
            self.pos += 1;
            try choices.append(self.allocator, try self.sequence());
        }
        if (choices.items.len == 1) return choices.items[0];
        return self.node(.{ .choice = try choices.toOwnedSlice(self.allocator) });
    }

    fn skipBalancedTest(self: *GrammarParser) !void {
        var depth: usize = 1;
        var quote: ?u8 = null;
        var escaped = false;
        var work: usize = 0;
        while (!self.eof() and depth > 0) {
            work += 1;
            if (work > 1_000_000 or depth > 512) return self.fail(self.pos, "test block limit exceeded");
            const c = self.peek();
            self.pos += 1;
            if (quote) |q| {
                if (!escaped and c == q) quote = null;
                escaped = !escaped and c == '\\';
                if (c != '\\') escaped = false;
            } else if (c == '"' or c == '\'') quote = c else if (c == '#') {
                while (!self.eof() and self.peek() != '\n') self.pos += 1;
            } else if (c == '{') depth += 1 else if (c == '}') depth -= 1;
        }
        if (depth != 0) return self.fail(self.pos, "unterminated test block");
    }

    fn relaxedValue(self: *GrammarParser) anyerror!std.json.Value {
        self.nesting += 1;
        if (self.nesting > 512) return self.fail(self.pos, "test value nesting limit exceeded");
        defer self.nesting -= 1;
        self.work += 1;
        if (self.work > 100_000) return self.fail(self.pos, "grammar work limit exceeded");
        self.skipSpace();
        if (self.eof()) return self.fail(self.pos, "expected test value");
        if (self.peek() == '"' or self.peek() == '\'') return .{ .string = try self.parseString() };
        if (self.peek() == '{') {
            self.pos += 1;
            var map: std.json.ObjectMap = .empty;
            while (true) {
                self.skipSpace();
                if (!self.eof() and self.peek() == '}') {
                    self.pos += 1;
                    return .{ .object = map };
                }
                const key = if (!self.eof() and (self.peek() == '"' or self.peek() == '\'')) try self.parseString() else self.identifier() orelse return self.fail(self.pos, "expected object key");
                if (map.contains(key)) return self.fail(self.pos, "duplicate object key");
                self.skipSpace();
                if (self.eof() or self.peek() != ':') return self.fail(self.pos, "expected ':'");
                self.pos += 1;
                try map.put(self.allocator, key, try self.relaxedValue());
                self.skipSpace();
                if (!self.eof() and self.peek() == ',') self.pos += 1;
            }
        }
        if (self.peek() == '[') {
            self.pos += 1;
            var array = std.json.Array.init(self.allocator);
            while (true) {
                self.skipSpace();
                if (!self.eof() and self.peek() == ']') {
                    self.pos += 1;
                    return .{ .array = array };
                }
                try array.append(try self.relaxedValue());
                self.skipSpace();
                if (!self.eof() and self.peek() == ',') self.pos += 1;
            }
        }
        if (self.peek() == '-' or std.ascii.isDigit(self.peek())) {
            const start = self.pos;
            if (self.peek() == '-') self.pos += 1;
            while (!self.eof() and std.ascii.isDigit(self.peek())) self.pos += 1;
            if (!self.eof() and self.peek() == '.') {
                self.pos += 1;
                while (!self.eof() and std.ascii.isDigit(self.peek())) self.pos += 1;
            }
            if (!self.eof() and (self.peek() == 'e' or self.peek() == 'E')) {
                self.pos += 1;
                if (!self.eof() and (self.peek() == '+' or self.peek() == '-')) self.pos += 1;
                while (!self.eof() and std.ascii.isDigit(self.peek())) self.pos += 1;
            }
            const text = self.source[start..self.pos];
            if (!numbers.isLiteral(text)) return self.fail(start, "invalid number: expected JSON number syntax");
            return std.json.Value.parseFromNumberSlice(text);
        }
        const word = self.identifier() orelse return self.fail(self.pos, "expected test value");
        if (std.mem.eql(u8, word, "true")) return .{ .bool = true };
        if (std.mem.eql(u8, word, "false")) return .{ .bool = false };
        if (std.mem.eql(u8, word, "null")) return .null;
        return self.fail(self.pos, "invalid test value");
    }

    fn parseTest(self: *GrammarParser) !void {
        const at = self.pos;
        self.pos += "@test".len;
        self.skipSpace();
        if (self.eof() or (self.peek() != '"' and self.peek() != '\'')) return self.fail(self.pos, "expected test name");
        const name = try self.parseString();
        self.skipSpace();
        if (self.eof() or self.peek() != '{') return self.fail(self.pos, "expected test block");
        self.pos += 1;
        if (!self.load_tests) return self.skipBalancedTest();
        var input: ?[]const u8 = null;
        var expect: ?std.json.Value = null;
        var reject = false;
        var has_input = false;
        var has_expect = false;
        var has_reject = false;
        while (true) {
            self.skipSpace();
            if (self.eof()) return self.fail(at, "unterminated test block");
            if (self.peek() == '}') {
                self.pos += 1;
                break;
            }
            const key = self.identifier() orelse return self.fail(self.pos, "expected test field");
            self.skipSpace();
            if (self.eof() or self.peek() != ':') return self.fail(self.pos, "expected ':'");
            self.pos += 1;
            const value = try self.relaxedValue();
            if (std.mem.eql(u8, key, "input")) {
                if (has_input) return self.fail(self.pos, "duplicate test field");
                has_input = true;
                input = switch (value) {
                    .string => |s| s,
                    else => return self.fail(self.pos, "input must be a string"),
                };
            } else if (std.mem.eql(u8, key, "expect")) {
                if (has_expect) return self.fail(self.pos, "duplicate test field");
                has_expect = true;
                expect = value;
            } else if (std.mem.eql(u8, key, "reject")) {
                if (has_reject) return self.fail(self.pos, "duplicate test field");
                has_reject = true;
                reject = switch (value) {
                    .bool => |b| b,
                    else => return self.fail(self.pos, "reject must be boolean"),
                };
                if (!reject) return self.fail(self.pos, "reject must be true");
            } else return self.fail(self.pos, "unknown test field");
            self.skipSpace();
            if (!self.eof() and self.peek() == ',') self.pos += 1;
        }
        if (input == null or (has_expect == has_reject)) return self.fail(at, "test requires input and exactly one expect or reject: true");
        try self.tests.append(self.allocator, .{ .name = name, .input = input.?, .expect = expect, .reject = reject, .source_offset = at });
    }

    fn parseAll(self: *GrammarParser) !Grammar {
        while (true) {
            self.skipSpace();
            if (self.eof()) break;
            if (self.starts("@test")) {
                try self.parseTest();
                continue;
            }
            const at = self.pos;
            const name = self.identifier() orelse return self.fail(at, "expected root, rule, or test");
            if (std.mem.eql(u8, name, "root")) {
                if (self.root_name != null) return self.fail(at, "duplicate root declaration");
                self.skipSpace();
                self.root_offset = at;
                self.root_name = self.identifier() orelse return self.fail(self.pos, "expected root rule name");
                continue;
            }
            for (self.rules.items) |r| if (std.mem.eql(u8, r.name, name)) return self.fail(at, "duplicate rule");
            self.skipSpace();
            if (!self.starts("<-")) return self.fail(self.pos, "expected '<-'");
            self.pos += 2;
            try self.rules.append(self.allocator, .{ .name = name, .expr = try self.expression(), .offset = at });
        }
        const root_name = self.root_name orelse return self.fail(0, "missing root declaration");
        var root: ?usize = null;
        for (self.rules.items, 0..) |r, i| {
            if (std.mem.eql(u8, r.name, root_name)) root = i;
        }
        if (root == null) return self.fail(self.root_offset, "root references unknown rule");
        for (self.rules.items) |r| try self.validateRefs(r.expr);
        return .{ .tests = try self.tests.toOwnedSlice(self.allocator), .rules = try self.rules.toOwnedSlice(self.allocator), .root = root.? };
    }

    fn validateRefs(self: *GrammarParser, expr: *const Expr) !void {
        switch (expr.*) {
            .reference => |ref| {
                for (self.rules.items) |r| if (std.mem.eql(u8, r.name, ref.name)) return;
                return self.fail(ref.offset, "unknown rule");
            },
            .sequence, .choice => |xs| for (xs) |x| try self.validateRefs(x),
            .repeat => |x| try self.validateRefs(x.child),
            .not => |x| try self.validateRefs(x.child),
            .and_ => |x| try self.validateRefs(x.child),
            .capture => |x| try self.validateRefs(x.child),
            else => {},
        }
    }
};

pub fn compile(allocator: std.mem.Allocator, source: []const u8, load_tests: bool, diagnostic: *?common.Diagnostic) anyerror!Grammar {
    diagnostic.* = null;
    if (source.len > 4 * 1024 * 1024) {
        diagnostic.* = .{ .kind = .grammar, .offset = 4 * 1024 * 1024, .message = "grammar size limit exceeded" };
        return error.InvalidGrammar;
    }
    var parser = GrammarParser{ .allocator = allocator, .source = source, .diagnostic = diagnostic, .load_tests = load_tests };
    return parser.parseAll();
}

const Match = struct { pos: usize, value: std.json.Value, structured: bool };
const Active = struct { rule: usize, pos: usize };
const Runtime = struct {
    allocator: std.mem.Allocator,
    grammar: *const Grammar,
    input: []const u8,
    failed: Failure = .{},
    work: usize = 0,
    trace_enabled: bool,
    traces: std.ArrayList(common.TraceEvent) = .empty,
    active: std.ArrayList(Active) = .empty,
    limit_message: ?[]const u8 = null,

    fn emptyString() std.json.Value {
        return .{ .string = "" };
    }
    // Immutable slices make snapshots safe across speculative branches and probes.
    const Failure = struct {
        offset: usize = 0,
        expected: []const common.Expectation = &.{},
        truncated: bool = false,
    };

    fn failure(self: *Runtime) Failure {
        return self.failed;
    }
    fn restoreFailure(self: *Runtime, saved: Failure) void {
        self.failed = saved;
    }
    fn failAt(self: *Runtime, pos: usize, grammar_offset: usize, expected: []const u8) !?Match {
        if (pos < self.failed.offset) return null;
        if (pos > self.failed.offset) self.failed = .{ .offset = pos };
        for (self.failed.expected) |item| {
            if (std.mem.eql(u8, item.message, expected)) return null;
        }
        if (self.failed.expected.len == 16) {
            self.failed.truncated = true;
            return null;
        }
        const items = try self.allocator.alloc(common.Expectation, self.failed.expected.len + 1);
        @memcpy(items[0..self.failed.expected.len], self.failed.expected);
        items[self.failed.expected.len] = .{
            .message = expected,
            .grammar_offset = grammar_offset,
            .rule = if (self.active.items.len == 0) null else self.grammar.rules[self.active.items[self.active.items.len - 1].rule].name,
        };
        self.failed.expected = items;
        return null;
    }

    fn diagnostic(self: *Runtime) !common.Diagnostic {
        const first: ?common.Expectation = if (self.failed.expected.len > 0) self.failed.expected[0] else null;
        var message: std.Io.Writer.Allocating = .init(self.allocator);
        if (self.limit_message) |limit| {
            try message.writer.writeAll(limit);
        } else if (self.failed.expected.len == 0) {
            try message.writer.writeAll("input did not match grammar");
        } else {
            for (self.failed.expected, 0..) |item, index| {
                if (index != 0) try message.writer.writeAll(" or ");
                const text = if (index != 0 and std.mem.startsWith(u8, item.message, "expected ")) item.message[9..] else item.message;
                try message.writer.writeAll(text);
            }
            if (self.failed.truncated) try message.writer.writeAll(" or other alternatives (list capped at 16)");
        }
        return .{
            .kind = if (self.limit_message != null) .limit else .input,
            .offset = self.failed.offset,
            .message = try message.toOwnedSlice(),
            .grammar_offset = if (first) |item| item.grammar_offset else null,
            .rule = if (first) |item| item.rule else null,
            .expected = if (self.limit_message != null) &.{} else self.failed.expected,
            .expected_truncated = self.limit_message == null and self.failed.truncated,
        };
    }
    fn ruleIndex(self: *Runtime, name: []const u8) usize {
        for (self.grammar.rules, 0..) |r, i| if (std.mem.eql(u8, r.name, name)) return i;
        unreachable;
    }
    fn appendTrace(self: *Runtime, event: common.TraceEvent) !void {
        if (self.trace_enabled and self.traces.items.len < 1024) try self.traces.append(self.allocator, event);
    }

    fn matchRule(self: *Runtime, index: usize, pos: usize, depth: usize) anyerror!?Match {
        if (depth > 256 or self.work > 1_000_000) {
            self.limit_message = "parse work limit exceeded";
            return null;
        }
        for (self.active.items) |a| if (a.rule == index and a.pos == pos) {
            self.limit_message = "left recursion detected";
            return null;
        };
        try self.active.append(self.allocator, .{ .rule = index, .pos = pos });
        defer _ = self.active.pop();
        const result = try self.matchExpr(self.grammar.rules[index].expr, pos, depth + 1);
        try self.appendTrace(.{ .rule = self.grammar.rules[index].name, .start = pos, .end = if (result) |m| m.pos else pos, .matched = result != null, .depth = depth });
        return result;
    }

    fn classContains(ranges: []const ClassRange, byte: u8) bool {
        for (ranges) |range| if (byte >= range.first and byte <= range.last) return true;
        return false;
    }

    fn mergeSequence(self: *Runtime, values: []const Match, start: usize, end: usize) !Match {
        var count: usize = 0;
        var has_array = false;
        var has_object = false;
        for (values) |v| if (v.structured) {
            count += 1;
            if (v.value == .array) has_array = true else if (v.value == .object) has_object = true;
        };
        if (count == 0) return .{ .pos = end, .value = .{ .string = self.input[start..end] }, .structured = false };
        if (has_array) {
            var array = std.json.Array.init(self.allocator);
            for (values) |v| if (v.structured) switch (v.value) {
                .array => |a| try array.appendSlice(a.items),
                else => try array.append(v.value),
            };
            return .{ .pos = end, .value = .{ .array = array }, .structured = true };
        }
        if (has_object) {
            var object: std.json.ObjectMap = .empty;
            for (values) |v| if (v.structured) switch (v.value) {
                .object => |o| {
                    var it = o.iterator();
                    while (it.next()) |entry| try object.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
                },
                else => {},
            };
            return .{ .pos = end, .value = .{ .object = object }, .structured = true };
        }
        for (values) |v| if (v.structured) return .{ .pos = end, .value = v.value, .structured = true };
        unreachable;
    }

    fn matchExpr(self: *Runtime, expr: *const Expr, pos: usize, depth: usize) anyerror!?Match {
        self.work += 1;
        if (depth > 256 or self.work > 1_000_000) {
            self.limit_message = "parse work limit exceeded";
            return null;
        }
        if (self.limit_message != null) return null;
        return switch (expr.*) {
            .literal => |x| blk: {
                var matched: usize = 0;
                while (matched < x.text.len and pos + matched < self.input.len and self.input[pos + matched] == x.text[matched]) matched += 1;
                if (matched == x.text.len) break :blk Match{ .pos = pos + matched, .value = .{ .string = self.input[pos .. pos + matched] }, .structured = false };
                const expected = try std.fmt.allocPrint(self.allocator, "expected literal \"{s}\"", .{x.text});
                break :blk self.failAt(pos + matched, x.offset, expected);
            },
            .any => |at| if (pos < self.input.len) .{ .pos = pos + 1, .value = .{ .string = self.input[pos .. pos + 1] }, .structured = false } else self.failAt(pos, at, "expected any byte"),
            .class => |x| if (pos < self.input.len and (classContains(x.ranges, self.input[pos]) != x.inverted)) .{ .pos = pos + 1, .value = .{ .string = self.input[pos .. pos + 1] }, .structured = false } else self.failAt(pos, x.offset, x.expected),
            .reference => |x| self.matchRule(self.ruleIndex(x.name), pos, depth),
            .choice => |xs| blk: {
                const saved = self.failure();
                for (xs) |x| if (try self.matchExpr(x, pos, depth + 1)) |m| {
                    self.restoreFailure(saved);
                    break :blk m;
                };
                break :blk null;
            },
            .sequence => |xs| blk: {
                var matches: std.ArrayList(Match) = .empty;
                var p = pos;
                for (xs) |x| {
                    const m = (try self.matchExpr(x, p, depth + 1)) orelse break :blk null;
                    try matches.append(self.allocator, m);
                    p = m.pos;
                }
                break :blk try self.mergeSequence(matches.items, pos, p);
            },
            .not => |x| blk: {
                const saved = self.failure();
                const matched = try self.matchExpr(x.child, pos, depth + 1);
                if (self.limit_message != null) break :blk null;
                self.restoreFailure(saved);
                if (matched == null) break :blk Match{ .pos = pos, .value = emptyString(), .structured = false };
                break :blk self.failAt(pos, x.offset, "expected negative lookahead not to match");
            },
            .and_ => |x| blk: {
                const saved = self.failure();
                const matched = try self.matchExpr(x.child, pos, depth + 1);
                if (matched) |_| {
                    self.restoreFailure(saved);
                    break :blk Match{ .pos = pos, .value = emptyString(), .structured = false };
                }
                break :blk null;
            },
            .capture => |x| blk: {
                const m = (try self.matchExpr(x.child, pos, depth + 1)) orelse break :blk null;
                var object: std.json.ObjectMap = .empty;
                try object.put(self.allocator, x.name, if (m.structured) m.value else .{ .string = self.input[pos..m.pos] });
                break :blk Match{ .pos = m.pos, .value = .{ .object = object }, .structured = true };
            },
            .repeat => |x| blk: {
                var p = pos;
                var n: usize = 0;
                var items = std.json.Array.init(self.allocator);
                var structured = false;
                var direct: ?Match = null;
                while (x.max == null or n < x.max.?) {
                    const saved = self.failure();
                    const maybe = try self.matchExpr(x.child, p, depth + 1);
                    if (self.limit_message != null) break :blk null;
                    const m = maybe orelse {
                        // A normal stop failed at the next item's start. Keep
                        // deeper failures from incomplete repeated items, but
                        // optional expressions still discard their probes.
                        if (n >= x.min and (x.max != null or self.failed.offset <= p)) self.restoreFailure(saved);
                        break;
                    };
                    if (m.pos == p and x.max == null) {
                        self.limit_message = "zero-width repetition";
                        break :blk null;
                    }
                    direct = m;
                    if (m.structured) {
                        structured = true;
                        switch (m.value) {
                            .array => |a| try items.appendSlice(a.items),
                            else => try items.append(m.value),
                        }
                    }
                    p = m.pos;
                    n += 1;
                }
                if (n < x.min) break :blk null;
                if (x.max != null and x.max.? == 1 and direct != null) break :blk direct.?;
                break :blk Match{ .pos = p, .value = if (structured) .{ .array = items } else .{ .string = self.input[pos..p] }, .structured = structured };
            },
        };
    }
};

pub fn parse(allocator: std.mem.Allocator, grammar: *const Grammar, input: []const u8, trace: bool) anyerror!ParseResult {
    var runtime = Runtime{ .allocator = allocator, .grammar = grammar, .input = input, .trace_enabled = trace };
    const matched = try runtime.matchRule(grammar.root, 0, 0);
    const events = try runtime.traces.toOwnedSlice(allocator);
    if (runtime.limit_message != null) return .{ .diagnostic = try runtime.diagnostic(), .trace = events };
    if (matched) |m| {
        if (m.pos == input.len) return .{ .value = m.value, .trace = events };
        runtime.failed = .{
            .offset = m.pos,
            .expected = try allocator.dupe(common.Expectation, &.{.{
                .message = "expected end of input",
                .grammar_offset = grammar.rules[grammar.root].offset,
                .rule = grammar.rules[grammar.root].name,
            }}),
        };
        return .{ .diagnostic = try runtime.diagnostic(), .trace = events };
    }
    return .{ .diagnostic = try runtime.diagnostic(), .trace = events };
}
