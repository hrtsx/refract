const std = @import("std");

pub fn countLines(source: []const u8) u32 {
    var count: u32 = 1;
    for (source) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

pub fn writeJsonStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    try writeJsonEscaped(w, s);
    try w.writeByte('"');
}

pub fn writeJsonStrCapped(w: *std.Io.Writer, s: []const u8, max_bytes: usize) !void {
    try w.writeByte('"');
    if (s.len <= max_bytes) {
        try writeJsonEscaped(w, s);
    } else {
        try writeJsonEscaped(w, s[0..max_bytes]);
        try w.writeAll("\\u2026");
    }
    try w.writeByte('"');
}

fn writeJsonEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => try w.print("\\u{x:0>4}", .{ch}),
            else => try w.writeByte(ch),
        }
    }
}

pub fn writeJsonValue(w: *std.Io.Writer, val: std.json.Value) !void {
    switch (val) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try writeJsonStr(w, s),
        else => try w.writeAll("null"),
    }
}

pub fn getStrArg(args: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const map = args orelse return null;
    const val = map.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

pub const QualifiedSymbol = struct { class_name: []const u8, method_name: []const u8 };

pub fn splitQualified(s: []const u8) ?QualifiedSymbol {
    const i = std.mem.lastIndexOfScalar(u8, s, '#') orelse return null;
    if (i == 0 or i + 1 >= s.len) return null;
    return .{ .class_name = s[0..i], .method_name = s[i + 1 ..] };
}

/// Wrap a user query as an FTS5 double-quoted string literal so the trigram
/// tokenizer matches it as a literal substring (any embedded special chars,
/// including `"`, are neutralized). Caller frees.
pub fn ftsQuote(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);
    try buf.append(alloc, '"');
    for (s) |c| {
        if (c == '"') try buf.append(alloc, '"');
        try buf.append(alloc, c);
    }
    try buf.append(alloc, '"');
    return buf.toOwnedSlice(alloc);
}

pub fn normalizeFileArg(alloc: std.mem.Allocator, file: []const u8) ?[:0]u8 {
    if (file.len == 0) return null;
    // Reject parent-dir traversal segments outright. Even though SQL bindings
    // and file reads are downstream-scoped to the indexed workspace, refusing
    // "../" up front gives a uniform answer regardless of where the value
    // flows.
    if (containsTraversalSegment(file)) return null;
    // Absolute paths: trust as-is (indexer records absolute paths and we
    // look them up parametrized). Relative paths: resolve against cwd.
    if (file[0] == '/') return alloc.dupeZ(u8, file) catch null;
    return std.Io.Dir.cwd().realPathFileAlloc(std.Options.debug_io, file, alloc) catch null;
}

fn containsTraversalSegment(file: []const u8) bool {
    var i: usize = 0;
    while (i < file.len) {
        const start = i;
        while (i < file.len and file[i] != '/') i += 1;
        const seg = file[start..i];
        if (std.mem.eql(u8, seg, "..")) return true;
        if (i < file.len) i += 1;
    }
    return false;
}

pub fn getIntArg(args: ?std.json.ObjectMap, key: []const u8) ?i64 {
    const map = args orelse return null;
    const val = map.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        .float => |f| blk: {
            if (@abs(f) > 1_000_000_000_000.0) return null;
            break :blk @as(i64, @intFromFloat(f));
        },
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

pub fn stepLog(err: anyerror) bool {
    std.debug.print("{s}", .{"refract: mcp sql step: "});
    std.debug.print("{s}", .{@errorName(err)});
    std.debug.print("{s}", .{"\n"});
    return false;
}

fn regexCharMatch(ch: u8, pat: u8) bool {
    return pat == '.' or ch == pat;
}

fn regexAt(line: []const u8, li: usize, pat: []const u8, pi: usize) bool {
    if (pi >= pat.len) return true;
    if (pat[pi] == '$') return li == line.len;

    const has_quant = pi + 1 < pat.len and (pat[pi + 1] == '*' or pat[pi + 1] == '+');
    if (has_quant) {
        const is_plus = pat[pi + 1] == '+';
        var count: usize = 0;
        while (li + count < line.len and regexCharMatch(line[li + count], pat[pi])) {
            count += 1;
        }
        const min_c: usize = if (is_plus) 1 else 0;
        if (count < min_c) return false;
        var k: usize = count;
        while (true) {
            if (regexAt(line, li + k, pat, pi + 2)) return true;
            if (k == 0) break;
            k -= 1;
        }
        return false;
    }

    if (li >= line.len) return false;
    if (!regexCharMatch(line[li], pat[pi])) return false;
    return regexAt(line, li + 1, pat, pi + 1);
}

pub fn regexMatchLine(line: []const u8, pattern: []const u8) bool {
    if (pattern.len > 0 and pattern[0] == '^') {
        return regexAt(line, 0, pattern[1..], 0);
    }
    var i: usize = 0;
    while (i <= line.len) : (i += 1) {
        if (regexAt(line, i, pattern, 0)) return true;
    }
    return false;
}

pub fn validateGlobPattern(pattern: []const u8) ?[]const u8 {
    for (pattern) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '/', '.', '*', '?', '[', ']', '!' => {},
            else => {
                return "contains invalid character";
            },
        }
    }
    return null;
}
