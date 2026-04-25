const std = @import("std");

/// Walk backward from `dot_offset` (the offset of the `.` in `receiver.method`)
/// in `source` and return the slice covering a literal token immediately
/// preceding the dot, or null if the byte before the dot is anything else
/// (identifier, closing paren, semicolon, etc.). Recognized literals:
///   "..." | '...'        → quoted string
///   [...]                 → array literal (bracket-balanced)
///   {...}                 → hash/block literal (brace-balanced)
///   :ident                → symbol literal
///   42 | 42.0 | 1_000 etc → numeric literal (digits + optional underscores)
pub fn extractLiteralReceiver(source: []const u8, dot_offset: usize) ?[]const u8 {
    if (dot_offset == 0 or dot_offset > source.len) return null;
    var end = dot_offset; // exclusive end of literal (the `.` itself)
    while (end > 0 and (source[end - 1] == ' ' or source[end - 1] == '\t')) end -= 1;
    if (end == 0) return null;
    const last = source[end - 1];

    if (last == '"' or last == '\'') {
        const quote = last;
        if (end < 2) return null;
        var j: usize = end - 1; // start of search; closing quote is at end-1
        while (j > 0) : (j -= 1) {
            const c = source[j - 1];
            if (c == quote and (j < 2 or source[j - 2] != '\\')) {
                return source[j - 1 .. end];
            }
        }
        return null;
    }

    if (last == ']' or last == '}') {
        const close = last;
        const open: u8 = if (close == ']') '[' else '{';
        var depth: i32 = 0;
        var i: usize = end;
        while (i > 0) {
            i -= 1;
            const c = source[i];
            if (c == close) depth += 1;
            if (c == open) {
                depth -= 1;
                if (depth == 0) return source[i..end];
            }
        }
        return null;
    }

    if (std.ascii.isDigit(last)) {
        var i: usize = end;
        while (i > 0) {
            const c = source[i - 1];
            if (std.ascii.isDigit(c) or c == '_' or c == '.') {
                i -= 1;
            } else if (c == 'x' or c == 'X' or c == 'b' or c == 'B' or c == 'o' or c == 'O') {
                if (i >= 2 and source[i - 2] == '0') {
                    i -= 2;
                } else break;
            } else if ((c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) {
                i -= 1;
            } else break;
        }
        if (i < end) return source[i..end];
        return null;
    }

    if (isIdentChar(last)) {
        var i: usize = end;
        while (i > 0 and isIdentChar(source[i - 1])) i -= 1;
        if (i > 0 and source[i - 1] == ':' and (i == 1 or source[i - 2] != ':')) {
            return source[i - 1 .. end];
        }
        return null;
    }

    return null;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Map a literal token (as returned by `extractLiteralReceiver`) to a Ruby
/// class name. Mirrors `inferLiteralType` at `src/indexer/index.zig:124-165`
/// but operates on source text. Returns null when the literal is unrecognized.
pub fn classifyLiteralType(literal: []const u8) ?[]const u8 {
    if (literal.len == 0) return null;
    const first = literal[0];
    const last = literal[literal.len - 1];

    if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) return "String";
    if (first == '[' and last == ']') return "Array";
    if (first == '{' and last == '}') return "Hash";
    if (first == ':' and literal.len > 1) return "Symbol";

    if (std.ascii.isDigit(first)) {
        for (literal) |c| {
            if (c == '.') return "Float";
        }
        return "Integer";
    }
    return null;
}

test "extractLiteralReceiver string" {
    const src = "\"hello\".upcase";
    const dot = std.mem.indexOfScalar(u8, src, '.').?;
    const lit = extractLiteralReceiver(src, dot).?;
    try std.testing.expectEqualStrings("\"hello\"", lit);
    try std.testing.expectEqualStrings("String", classifyLiteralType(lit).?);
}

test "extractLiteralReceiver array" {
    const src = "[1, 2, 3].first";
    const dot = std.mem.indexOfScalar(u8, src, '.').?;
    const lit = extractLiteralReceiver(src, dot).?;
    try std.testing.expectEqualStrings("[1, 2, 3]", lit);
    try std.testing.expectEqualStrings("Array", classifyLiteralType(lit).?);
}

test "extractLiteralReceiver array nested" {
    const src = "[[1, 2], [3, 4]].first";
    const dot = std.mem.lastIndexOfScalar(u8, src, '.').?;
    const lit = extractLiteralReceiver(src, dot).?;
    try std.testing.expectEqualStrings("[[1, 2], [3, 4]]", lit);
    try std.testing.expectEqualStrings("Array", classifyLiteralType(lit).?);
}

test "extractLiteralReceiver hash" {
    const src = "{a: 1}.fetch(:a)";
    const dot = std.mem.indexOfScalar(u8, src, '.').?;
    const lit = extractLiteralReceiver(src, dot).?;
    try std.testing.expectEqualStrings("{a: 1}", lit);
    try std.testing.expectEqualStrings("Hash", classifyLiteralType(lit).?);
}

test "extractLiteralReceiver integer" {
    const src = "42.to_s";
    const dot = std.mem.indexOfScalar(u8, src, '.').?;
    const lit = extractLiteralReceiver(src, dot).?;
    try std.testing.expectEqualStrings("42", lit);
    try std.testing.expectEqualStrings("Integer", classifyLiteralType(lit).?);
}

test "extractLiteralReceiver float" {
    const src = "42.0.to_s";
    const dot = std.mem.lastIndexOfScalar(u8, src, '.').?;
    const lit = extractLiteralReceiver(src, dot).?;
    try std.testing.expectEqualStrings("42.0", lit);
    try std.testing.expectEqualStrings("Float", classifyLiteralType(lit).?);
}

test "extractLiteralReceiver symbol" {
    const src = ":foo.to_s";
    const dot = std.mem.indexOfScalar(u8, src, '.').?;
    const lit = extractLiteralReceiver(src, dot).?;
    try std.testing.expectEqualStrings(":foo", lit);
    try std.testing.expectEqualStrings("Symbol", classifyLiteralType(lit).?);
}

test "extractLiteralReceiver identifier returns null" {
    const src = "foo.bar";
    const dot = std.mem.indexOfScalar(u8, src, '.').?;
    try std.testing.expectEqual(@as(?[]const u8, null), extractLiteralReceiver(src, dot));
}

test "extractLiteralReceiver const colon-colon returns null" {
    const src = "Foo::Bar.baz";
    const dot = std.mem.lastIndexOfScalar(u8, src, '.').?;
    try std.testing.expectEqual(@as(?[]const u8, null), extractLiteralReceiver(src, dot));
}
