const std = @import("std");
const common = @import("common.zig");

const max_depth = 256;

const Node = struct {
    offset: usize,
    data: union(enum) {
        literal: std.json.Value,
        variable: []const u8,
        array: []*Node,
        object: []Field,
        call: Call,
    },
};

const Field = struct { key: []const u8, value: *Node, offset: usize };
const Call = struct { name: []const u8, args: []*Node };
const Rule = struct { pattern: *Node, output: *Node };

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    pos: usize = 0,
    diagnostic: *?common.Diagnostic,

    fn fail(self: *Parser, offset: usize, message: []const u8) error{InvalidTransform} {
        self.diagnostic.* = .{ .kind = .transform, .offset = offset, .message = message };
        return error.InvalidTransform;
    }

    fn space(self: *Parser) void {
        while (self.pos < self.source.len) {
            if (std.ascii.isWhitespace(self.source[self.pos])) {
                self.pos += 1;
            } else if (self.source[self.pos] == '#') {
                while (self.pos < self.source.len and self.source[self.pos] != '\n') self.pos += 1;
            } else break;
        }
    }

    fn take(self: *Parser, c: u8) bool {
        self.space();
        if (self.pos < self.source.len and self.source[self.pos] == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn identifier(self: *Parser) ![]const u8 {
        self.space();
        const start = self.pos;
        if (self.pos >= self.source.len or !(std.ascii.isAlphabetic(self.source[self.pos]) or self.source[self.pos] == '_'))
            return self.fail(self.pos, "expected identifier");
        self.pos += 1;
        while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) self.pos += 1;
        return self.source[start..self.pos];
    }

    fn string(self: *Parser) ![]const u8 {
        self.space();
        const start = self.pos;
        if (!self.take('"')) return self.fail(start, "expected string");
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            self.pos += 1;
            if (c == '"') {
                return std.json.parseFromSliceLeaky([]const u8, self.allocator, self.source[start..self.pos], .{ .allocate = .alloc_always }) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return self.fail(start, "invalid string or escape"),
                };
            }
            if (c == '\\' and self.pos < self.source.len) self.pos += 1;
        }
        return self.fail(start, "unterminated string");
    }

    fn node(self: *Parser, depth: usize) anyerror!*Node {
        if (depth > max_depth) return self.fail(self.pos, "transform nesting limit exceeded");
        self.space();
        const start = self.pos;
        const result = try self.allocator.create(Node);
        if (self.pos >= self.source.len) return self.fail(start, "expected expression");
        if (self.source[self.pos] == '{') {
            self.pos += 1;
            var fields: std.ArrayList(Field) = .empty;
            self.space();
            while (!self.take('}')) {
                const key_offset = self.pos;
                const key = if (self.pos < self.source.len and self.source[self.pos] == '"') try self.string() else try self.identifier();
                for (fields.items) |field| if (std.mem.eql(u8, field.key, key)) return self.fail(key_offset, "duplicate object key");
                if (!self.take(':')) return self.fail(self.pos, "expected ':'");
                try fields.append(self.allocator, .{ .key = key, .value = try self.node(depth + 1), .offset = key_offset });
                if (self.take('}')) break;
                if (!self.take(',')) return self.fail(self.pos, "expected ',' or '}'");
            }
            result.* = .{ .offset = start, .data = .{ .object = try fields.toOwnedSlice(self.allocator) } };
            return result;
        }
        if (self.source[self.pos] == '[') {
            self.pos += 1;
            var items: std.ArrayList(*Node) = .empty;
            self.space();
            while (!self.take(']')) {
                try items.append(self.allocator, try self.node(depth + 1));
                if (self.take(']')) break;
                if (!self.take(',')) return self.fail(self.pos, "expected ',' or ']'");
            }
            result.* = .{ .offset = start, .data = .{ .array = try items.toOwnedSlice(self.allocator) } };
            return result;
        }
        if (self.source[self.pos] == '"') {
            result.* = .{ .offset = start, .data = .{ .literal = .{ .string = try self.string() } } };
            return result;
        }
        if (self.source[self.pos] == '-' or std.ascii.isDigit(self.source[self.pos])) {
            if (self.source[self.pos] == '-') self.pos += 1;
            while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) self.pos += 1;
            var is_float = false;
            if (self.pos < self.source.len and self.source[self.pos] == '.') {
                is_float = true;
                self.pos += 1;
                while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) self.pos += 1;
            }
            if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
                is_float = true;
                self.pos += 1;
                if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) self.pos += 1;
                while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) self.pos += 1;
            }
            const text = self.source[start..self.pos];
            const value: std.json.Value = if (is_float)
                .{ .float = std.fmt.parseFloat(f64, text) catch return self.fail(start, "invalid number") }
            else
                .{ .integer = std.fmt.parseInt(i64, text, 10) catch return self.fail(start, "invalid number") };
            if (value == .float and !std.math.isFinite(value.float)) return self.fail(start, "number must be finite");
            result.* = .{ .offset = start, .data = .{ .literal = value } };
            return result;
        }
        const name = try self.identifier();
        if (std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false") or std.mem.eql(u8, name, "null")) {
            const value: std.json.Value = if (std.mem.eql(u8, name, "true")) .{ .bool = true } else if (std.mem.eql(u8, name, "false")) .{ .bool = false } else .null;
            result.* = .{ .offset = start, .data = .{ .literal = value } };
        } else if (self.take('(')) {
            var args: std.ArrayList(*Node) = .empty;
            while (!self.take(')')) {
                try args.append(self.allocator, try self.node(depth + 1));
                if (self.take(')')) break;
                if (!self.take(',')) return self.fail(self.pos, "expected ',' or ')'");
            }
            result.* = .{ .offset = start, .data = .{ .call = .{ .name = name, .args = try args.toOwnedSlice(self.allocator) } } };
        } else result.* = .{ .offset = start, .data = .{ .variable = name } };
        return result;
    }

    fn rules(self: *Parser) ![]Rule {
        var result: std.ArrayList(Rule) = .empty;
        self.space();
        while (self.pos < self.source.len) {
            const pattern = try self.node(0);
            self.space();
            if (self.pos + 2 > self.source.len or !std.mem.eql(u8, self.source[self.pos .. self.pos + 2], "=>")) return self.fail(self.pos, "expected '=>'");
            self.pos += 2;
            const output = try self.node(0);
            try validateRule(self, pattern, output);
            try result.append(self.allocator, .{ .pattern = pattern, .output = output });
            self.space();
        }
        return result.toOwnedSlice(self.allocator);
    }
};

fn validateRule(parser: *Parser, pattern: *Node, output: *Node) !void {
    var names = std.StringHashMap(void).init(parser.allocator);
    try validatePattern(parser, pattern, &names, 0);
    try validateOutput(parser, output, &names, 0);
}

fn validatePattern(parser: *Parser, node: *Node, names: *std.StringHashMap(void), depth: usize) anyerror!void {
    if (depth > max_depth) return parser.fail(node.offset, "transform nesting limit exceeded");
    switch (node.data) {
        .literal => {},
        .array => |items| for (items) |item| try validatePattern(parser, item, names, depth + 1),
        .object => |fields| for (fields) |field| try validatePattern(parser, field.value, names, depth + 1),
        .variable => return parser.fail(node.offset, "bare variables are not valid patterns"),
        .call => |call| {
            if (!(std.mem.eql(u8, call.name, "simple") or std.mem.eql(u8, call.name, "sequence") or std.mem.eql(u8, call.name, "subtree"))) return parser.fail(node.offset, "unknown pattern function");
            if (call.args.len != 1) return parser.fail(node.offset, "pattern function requires one binding");
            const name = switch (call.args[0].data) {
                .variable => |name| name,
                else => return parser.fail(call.args[0].offset, "expected binding name"),
            };
            try names.put(name, {});
        },
    }
}

fn validateOutput(parser: *Parser, node: *Node, names: *const std.StringHashMap(void), depth: usize) anyerror!void {
    if (depth > max_depth) return parser.fail(node.offset, "transform nesting limit exceeded");
    switch (node.data) {
        .literal => {},
        .variable => |name| if (!names.contains(name)) return parser.fail(node.offset, "unbound variable"),
        .array => |items| for (items) |item| try validateOutput(parser, item, names, depth + 1),
        .object => |fields| for (fields) |field| try validateOutput(parser, field.value, names, depth + 1),
        .call => |call| {
            const is_join = std.mem.eql(u8, call.name, "join");
            const is_conversion = std.mem.eql(u8, call.name, "int") or std.mem.eql(u8, call.name, "float") or std.mem.eql(u8, call.name, "bool");
            if (!(std.mem.eql(u8, call.name, "concat") or is_join or is_conversion)) return parser.fail(node.offset, "unknown output function");
            if (is_join and (call.args.len < 1 or call.args.len > 2)) return parser.fail(node.offset, "join expects one or two arguments");
            if (is_conversion and call.args.len != 1) return parser.fail(node.offset, "conversion expects one argument");
            for (call.args) |arg| try validateOutput(parser, arg, names, depth + 1);
        },
    }
}

const Bindings = std.StringHashMap(std.json.Value);

pub fn apply(allocator: std.mem.Allocator, source: []const u8, input: std.json.Value, diagnostic: *?common.Diagnostic) anyerror!std.json.Value {
    diagnostic.* = null;
    var parser = Parser{ .allocator = allocator, .source = source, .diagnostic = diagnostic };
    const rules = parser.rules() catch |err| switch (err) {
        error.InvalidTransform => return error.InvalidTransformRules,
        else => return err,
    };
    return transformValue(allocator, rules, input, diagnostic, 0);
}

fn transformValue(allocator: std.mem.Allocator, rules: []const Rule, input: std.json.Value, diagnostic: *?common.Diagnostic, depth: usize) anyerror!std.json.Value {
    if (depth > max_depth) {
        diagnostic.* = .{ .kind = .limit, .offset = 0, .message = "transform recursion limit exceeded" };
        return error.TransformLimit;
    }
    const value: std.json.Value = switch (input) {
        .array => |array| blk: {
            var out = std.json.Array.init(allocator);
            for (array.items) |item| try out.append(try transformValue(allocator, rules, item, diagnostic, depth + 1));
            break :blk .{ .array = out };
        },
        .object => |object| blk: {
            var out: std.json.ObjectMap = .{};
            var it = object.iterator();
            while (it.next()) |entry| try out.put(allocator, entry.key_ptr.*, try transformValue(allocator, rules, entry.value_ptr.*, diagnostic, depth + 1));
            break :blk .{ .object = out };
        },
        else => input,
    };
    for (rules) |rule| {
        var bindings = Bindings.init(allocator);
        const matched = match(rule.pattern, value, &bindings, depth) catch |err| switch (err) {
            error.TransformLimit => return runtimeFail(diagnostic, rule.pattern.offset, "transform matching limit exceeded", err),
            else => return err,
        };
        if (matched) return evaluate(allocator, rule.output, &bindings, diagnostic, depth);
    }
    return value;
}

fn match(node: *const Node, value: std.json.Value, bindings: *Bindings, depth: usize) !bool {
    if (depth > max_depth) return error.TransformLimit;
    return switch (node.data) {
        .literal => |literal| deepEqual(literal, value),
        .variable => false,
        .call => |call| blk: {
            const acceptable = if (std.mem.eql(u8, call.name, "simple")) isScalar(value) else if (std.mem.eql(u8, call.name, "sequence")) isScalarArray(value) else true;
            if (!acceptable) break :blk false;
            const name = call.args[0].data.variable;
            if (bindings.get(name)) |bound| break :blk deepEqual(bound, value);
            try bindings.put(name, value);
            break :blk true;
        },
        .array => |items| blk: {
            if (value != .array or items.len != value.array.items.len) break :blk false;
            for (items, value.array.items) |item, actual| if (!try match(item, actual, bindings, depth + 1)) break :blk false;
            break :blk true;
        },
        .object => |fields| blk: {
            if (value != .object or fields.len != value.object.count()) break :blk false;
            for (fields) |field| {
                const actual = value.object.get(field.key) orelse break :blk false;
                if (!try match(field.value, actual, bindings, depth + 1)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn evaluate(allocator: std.mem.Allocator, node: *const Node, bindings: *const Bindings, diagnostic: *?common.Diagnostic, depth: usize) anyerror!std.json.Value {
    if (depth > max_depth) return runtimeFail(diagnostic, node.offset, "transform recursion limit exceeded", error.TransformLimit);
    return switch (node.data) {
        .literal => |value| value,
        .variable => |name| bindings.get(name).?,
        .array => |items| blk: {
            var out = std.json.Array.init(allocator);
            for (items) |item| try out.append(try evaluate(allocator, item, bindings, diagnostic, depth + 1));
            break :blk .{ .array = out };
        },
        .object => |fields| blk: {
            var out: std.json.ObjectMap = .{};
            for (fields) |field| try out.put(allocator, field.key, try evaluate(allocator, field.value, bindings, diagnostic, depth + 1));
            break :blk .{ .object = out };
        },
        .call => |call| evaluateCall(allocator, node.offset, call, bindings, diagnostic, depth + 1),
    };
}

fn evaluateCall(allocator: std.mem.Allocator, offset: usize, call: Call, bindings: *const Bindings, diagnostic: *?common.Diagnostic, depth: usize) anyerror!std.json.Value {
    if (std.mem.eql(u8, call.name, "concat")) {
        var out: std.ArrayList(u8) = .empty;
        for (call.args) |arg| {
            const value = try evaluate(allocator, arg, bindings, diagnostic, depth);
            const text = scalarText(allocator, value) catch return runtimeFail(diagnostic, offset, "concat expects scalar arguments", error.InvalidTransform);
            try out.appendSlice(allocator, text);
        }
        return .{ .string = try out.toOwnedSlice(allocator) };
    }
    if (std.mem.eql(u8, call.name, "join")) {
        if (call.args.len < 1 or call.args.len > 2) return runtimeFail(diagnostic, offset, "join expects an array and optional separator", error.InvalidTransform);
        const value = try evaluate(allocator, call.args[0], bindings, diagnostic, depth);
        if (value != .array) return runtimeFail(diagnostic, offset, "join expects an array", error.InvalidTransform);
        const separator = if (call.args.len == 2) scalarText(allocator, try evaluate(allocator, call.args[1], bindings, diagnostic, depth)) catch return runtimeFail(diagnostic, offset, "join separator must be scalar", error.InvalidTransform) else "";
        var out: std.ArrayList(u8) = .empty;
        for (value.array.items, 0..) |item, index| {
            if (index != 0) try out.appendSlice(allocator, separator);
            const text = scalarText(allocator, item) catch return runtimeFail(diagnostic, offset, "join array must contain scalars", error.InvalidTransform);
            try out.appendSlice(allocator, text);
        }
        return .{ .string = try out.toOwnedSlice(allocator) };
    }
    if (call.args.len != 1) return runtimeFail(diagnostic, offset, "conversion requires one argument", error.InvalidTransform);
    const value = try evaluate(allocator, call.args[0], bindings, diagnostic, depth);
    if (std.mem.eql(u8, call.name, "int")) return toInt(value) catch return runtimeFail(diagnostic, offset, "invalid integer conversion", error.InvalidTransform);
    if (std.mem.eql(u8, call.name, "float")) return toFloat(value) catch return runtimeFail(diagnostic, offset, "invalid float conversion", error.InvalidTransform);
    return toBool(value) catch return runtimeFail(diagnostic, offset, "invalid boolean conversion", error.InvalidTransform);
}

fn runtimeFail(diagnostic: *?common.Diagnostic, offset: usize, message: []const u8, err: anyerror) anyerror {
    diagnostic.* = .{ .kind = if (err == error.TransformLimit) .limit else .transform, .offset = offset, .message = message };
    return err;
}

fn toInt(value: std.json.Value) !std.json.Value {
    return switch (value) {
        .integer => value,
        .float => |v| if (std.math.isFinite(v) and @floor(v) == v and v >= -0x1p63 and v < 0x1p63) .{ .integer = @intFromFloat(v) } else error.InvalidConversion,
        .string => |v| .{ .integer = try std.fmt.parseInt(i64, v, 10) },
        else => error.InvalidConversion,
    };
}

fn toFloat(value: std.json.Value) !std.json.Value {
    const number: f64 = switch (value) {
        .float => |v| v,
        .integer => |v| @floatFromInt(v),
        .string => |v| try std.fmt.parseFloat(f64, v),
        else => return error.InvalidConversion,
    };
    if (!std.math.isFinite(number)) return error.InvalidConversion;
    return .{ .float = number };
}

fn toBool(value: std.json.Value) !std.json.Value {
    return switch (value) {
        .bool => value,
        .string => |v| if (std.mem.eql(u8, v, "true")) .{ .bool = true } else if (std.mem.eql(u8, v, "false")) .{ .bool = false } else error.InvalidConversion,
        else => error.InvalidConversion,
    };
}

fn scalarText(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |v| v,
        .number_string => |v| v,
        .integer => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .float => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .bool => |v| if (v) "true" else "false",
        .null => "null",
        else => error.NotScalar,
    };
}

fn isScalar(value: std.json.Value) bool {
    return switch (value) {
        .array, .object => false,
        else => true,
    };
}

fn isScalarArray(value: std.json.Value) bool {
    if (value != .array) return false;
    for (value.array.items) |item| if (!isScalar(item)) return false;
    return true;
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
