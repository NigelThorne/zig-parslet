const std = @import("std");

/// JSON number syntax, independent of representable numeric range.
pub fn isLiteral(text: []const u8) bool {
    var i: usize = 0;
    if (i < text.len and text[i] == '-') i += 1;
    if (i == text.len) return false;
    if (text[i] == '0') {
        i += 1;
    } else if (text[i] >= '1' and text[i] <= '9') {
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    } else return false;
    if (i < text.len and text[i] == '.') {
        i += 1;
        const start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i == start) return false;
    }
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
        const start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i == start) return false;
    }
    return i == text.len;
}
