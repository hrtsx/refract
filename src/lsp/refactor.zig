const std = @import("std");
const db_mod = @import("../db.zig");
const srv = @import("server.zig");

pub const RefactorKind = enum {
    extract_method,
    extract_variable,
    extract_constant,
    inline_variable,
    convert_string_style,
};

pub const RefactorEdit = struct {
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
    new_text: []const u8,
};

pub const RefactorResult = struct {
    edits: []RefactorEdit,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *RefactorResult) void {
        for (self.edits) |e| self.alloc.free(e.new_text);
        self.alloc.free(self.edits);
    }
};

fn lineAt(source: []const u8, line_0: u32) []const u8 {
    var cur: u32 = 0;
    var i: usize = 0;
    while (i < source.len and cur < line_0) : (i += 1) {
        if (source[i] == '\n') cur += 1;
    }
    const start = i;
    while (i < source.len and source[i] != '\n') i += 1;
    return source[start..i];
}

fn lineOffset(source: []const u8, line_0: u32) usize {
    var cur: u32 = 0;
    var i: usize = 0;
    while (i < source.len and cur < line_0) : (i += 1) {
        if (source[i] == '\n') cur += 1;
    }
    return i;
}

fn countLines(source: []const u8) u32 {
    var count: u32 = 0;
    for (source) |c| {
        if (c == '\n') count += 1;
    }
    return count + 1;
}

fn getIndent(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return line[0..i];
}

fn isRubyIdent(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

fn isUpperCase(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn scanLocalsInRange(source: []const u8, start: usize, end: usize, alloc: std.mem.Allocator) ![][]const u8 {
    var locals = std.StringHashMap(void).init(alloc);
    defer locals.deinit();
    var i = start;
    while (i < end and i < source.len) {
        if (isRubyIdent(source[i]) and (i == 0 or !isRubyIdent(source[i - 1]))) {
            const word_start = i;
            while (i < end and i < source.len and isRubyIdent(source[i])) i += 1;
            const word = source[word_start..i];
            if (word.len > 0 and !isUpperCase(word[0]) and !isKeyword(word)) {
                locals.put(word, {}) catch srv.logOomOnce("refactor.locals");
            }
        } else {
            i += 1;
        }
    }
    var result = std.ArrayList([]const u8).empty;
    var it = locals.keyIterator();
    while (it.next()) |k| {
        result.append(alloc, k.*) catch srv.logOomOnce("refactor.result");
    }
    return result.toOwnedSlice(alloc);
}

fn isKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{
        "def",           "end",    "class",   "module",  "if",        "else",   "elsif",       "unless",
        "while",         "until",  "for",     "do",      "begin",     "rescue", "ensure",      "raise",
        "return",        "yield",  "self",    "nil",     "true",      "false",  "and",         "or",
        "not",           "then",   "when",    "case",    "in",        "super",  "require",     "require_relative",
        "include",       "extend", "prepend", "private", "protected", "public", "attr_reader", "attr_writer",
        "attr_accessor",
    };
    for (keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

pub fn extractMethod(
    alloc: std.mem.Allocator,
    source: []const u8,
    start_line: u32,
    end_line: u32,
    method_name: []const u8,
) !RefactorResult {
    var edits = std.ArrayList(RefactorEdit).empty;

    const sel_start = lineOffset(source, start_line);
    const sel_end = if (end_line + 1 < countLines(source))
        lineOffset(source, end_line + 1)
    else
        source.len;

    const selected = source[sel_start..sel_end];
    const first_line = lineAt(source, start_line);
    const indent = getIndent(first_line);

    const def_start = findEnclosingDefStart(source, sel_start);
    const def_end_offset = if (def_start) |ds|
        findMatchingEnd(source, ds)
    else
        null;

    const outer_locals = if (def_start) |ds|
        try scanLocalsInRange(source, ds, sel_start, alloc)
    else
        try alloc.alloc([]const u8, 0);
    defer alloc.free(outer_locals);

    const inner_locals = try scanLocalsInRange(source, sel_start, sel_end, alloc);
    defer alloc.free(inner_locals);

    var params = std.ArrayList([]const u8).empty;
    defer params.deinit(alloc);
    for (inner_locals) |local| {
        for (outer_locals) |outer| {
            if (std.mem.eql(u8, local, outer)) {
                params.append(alloc, local) catch srv.logOomOnce("refactor.params");
                break;
            }
        }
    }

    var written_after = std.ArrayList([]const u8).empty;
    defer written_after.deinit(alloc);
    for (inner_locals) |local| {
        if (sel_end < source.len) {
            const after_end = if (def_end_offset) |de| @min(de, source.len) else source.len;
            if (sel_end <= after_end and std.mem.indexOf(u8, source[sel_end..after_end], local) != null) {
                written_after.append(alloc, local) catch srv.logOomOnce("refactor.written_after");
            }
        }
    }

    var method_def = std.ArrayList(u8).empty;
    defer method_def.deinit(alloc);
    try method_def.appendSlice(alloc, indent);
    try method_def.appendSlice(alloc, "def ");
    try method_def.appendSlice(alloc, method_name);
    if (params.items.len > 0) {
        try method_def.append(alloc, '(');
        for (params.items, 0..) |p, i| {
            if (i > 0) try method_def.appendSlice(alloc, ", ");
            try method_def.appendSlice(alloc, p);
        }
        try method_def.append(alloc, ')');
    }
    try method_def.append(alloc, '\n');
    var split_iter = std.mem.splitScalar(u8, std.mem.trimEnd(u8, selected, "\n"), '\n');
    while (split_iter.next()) |line| {
        try method_def.appendSlice(alloc, indent);
        try method_def.appendSlice(alloc, "  ");
        try method_def.appendSlice(alloc, std.mem.trimStart(u8, line, " \t"));
        try method_def.append(alloc, '\n');
    }
    try method_def.appendSlice(alloc, indent);
    try method_def.appendSlice(alloc, "end\n\n");

    var call = std.ArrayList(u8).empty;
    defer call.deinit(alloc);
    try call.appendSlice(alloc, indent);
    if (written_after.items.len == 1) {
        try call.appendSlice(alloc, written_after.items[0]);
        try call.appendSlice(alloc, " = ");
    } else if (written_after.items.len > 1) {
        for (written_after.items, 0..) |wa, i| {
            if (i > 0) try call.appendSlice(alloc, ", ");
            try call.appendSlice(alloc, wa);
        }
        try call.appendSlice(alloc, " = ");
    }
    try call.appendSlice(alloc, method_name);
    if (params.items.len > 0) {
        try call.append(alloc, '(');
        for (params.items, 0..) |p, i| {
            if (i > 0) try call.appendSlice(alloc, ", ");
            try call.appendSlice(alloc, p);
        }
        try call.append(alloc, ')');
    }
    try call.append(alloc, '\n');

    const insert_line = if (def_end_offset) |de| blk: {
        var l: u32 = 0;
        var idx: usize = 0;
        while (idx < de and idx < source.len) : (idx += 1) {
            if (source[idx] == '\n') l += 1;
        }
        break :blk l + 1;
    } else start_line;

    try edits.append(alloc, .{
        .start_line = start_line,
        .start_col = 0,
        .end_line = end_line + 1,
        .end_col = 0,
        .new_text = try alloc.dupe(u8, call.items),
    });

    try edits.append(alloc, .{
        .start_line = insert_line,
        .start_col = 0,
        .end_line = insert_line,
        .end_col = 0,
        .new_text = try alloc.dupe(u8, method_def.items),
    });

    return .{
        .edits = try edits.toOwnedSlice(alloc),
        .alloc = alloc,
    };
}

pub fn extractVariable(
    alloc: std.mem.Allocator,
    source: []const u8,
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
    var_name: []const u8,
) !RefactorResult {
    var edits = std.ArrayList(RefactorEdit).empty;

    const sel_start = lineOffset(source, start_line) + start_col;
    const sel_end_line_off = lineOffset(source, end_line);
    const sel_end = sel_end_line_off + end_col;

    if (sel_start >= source.len or sel_end > source.len or sel_start >= sel_end) {
        return .{ .edits = try edits.toOwnedSlice(alloc), .alloc = alloc };
    }

    const selected = source[sel_start..sel_end];
    const line_text = lineAt(source, start_line);
    const indent = getIndent(line_text);

    var assign = std.ArrayList(u8).empty;
    defer assign.deinit(alloc);
    try assign.appendSlice(alloc, indent);
    try assign.appendSlice(alloc, var_name);
    try assign.appendSlice(alloc, " = ");
    try assign.appendSlice(alloc, selected);
    try assign.append(alloc, '\n');

    try edits.append(alloc, .{
        .start_line = start_line,
        .start_col = 0,
        .end_line = start_line,
        .end_col = 0,
        .new_text = try alloc.dupe(u8, assign.items),
    });

    try edits.append(alloc, .{
        .start_line = start_line,
        .start_col = start_col,
        .end_line = end_line,
        .end_col = end_col,
        .new_text = try alloc.dupe(u8, var_name),
    });

    return .{
        .edits = try edits.toOwnedSlice(alloc),
        .alloc = alloc,
    };
}

pub fn extractConstant(
    alloc: std.mem.Allocator,
    source: []const u8,
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
    const_name: []const u8,
) !RefactorResult {
    var edits = std.ArrayList(RefactorEdit).empty;

    const sel_start = lineOffset(source, start_line) + start_col;
    const sel_end_line_off = lineOffset(source, end_line);
    const sel_end = sel_end_line_off + end_col;

    if (sel_start >= source.len or sel_end > source.len or sel_start >= sel_end) {
        return .{ .edits = try edits.toOwnedSlice(alloc), .alloc = alloc };
    }

    const selected = source[sel_start..sel_end];

    if (!isPureLiteral(selected)) {
        return .{ .edits = try edits.toOwnedSlice(alloc), .alloc = alloc };
    }

    const class_line = findEnclosingClassLine(source, sel_start);
    const insert_line = if (class_line) |cl| cl + 1 else 0;
    const class_indent = if (class_line) |cl|
        getIndent(lineAt(source, cl))
    else
        "";

    var assign = std.ArrayList(u8).empty;
    defer assign.deinit(alloc);
    try assign.appendSlice(alloc, class_indent);
    try assign.appendSlice(alloc, "  ");
    try assign.appendSlice(alloc, const_name);
    try assign.appendSlice(alloc, " = ");
    try assign.appendSlice(alloc, selected);
    try assign.appendSlice(alloc, ".freeze\n");

    try edits.append(alloc, .{
        .start_line = insert_line,
        .start_col = 0,
        .end_line = insert_line,
        .end_col = 0,
        .new_text = try alloc.dupe(u8, assign.items),
    });

    try edits.append(alloc, .{
        .start_line = start_line + 1,
        .start_col = start_col,
        .end_line = end_line + 1,
        .end_col = end_col,
        .new_text = try alloc.dupe(u8, const_name),
    });

    return .{
        .edits = try edits.toOwnedSlice(alloc),
        .alloc = alloc,
    };
}

pub fn inlineVariable(
    alloc: std.mem.Allocator,
    source: []const u8,
    target_line: u32,
    target_col: u32,
) !RefactorResult {
    var edits = std.ArrayList(RefactorEdit).empty;

    const line_text = lineAt(source, target_line);
    const trimmed = std.mem.trim(u8, line_text, " \t");

    const eq_pos = std.mem.indexOf(u8, trimmed, " = ") orelse {
        return .{ .edits = try edits.toOwnedSlice(alloc), .alloc = alloc };
    };

    _ = target_col;
    const var_name = trimmed[0..eq_pos];
    const rhs = trimmed[eq_pos + 3 ..];

    if (var_name.len == 0 or rhs.len == 0) {
        return .{ .edits = try edits.toOwnedSlice(alloc), .alloc = alloc };
    }

    for (var_name) |c| {
        if (!isRubyIdent(c)) return .{ .edits = try edits.toOwnedSlice(alloc), .alloc = alloc };
    }

    const def_start = findEnclosingDefStart(source, lineOffset(source, target_line));
    const scope_end = if (def_start) |ds|
        findMatchingEnd(source, ds) orelse source.len
    else
        source.len;

    const after_assignment = lineOffset(source, target_line + 1);
    if (after_assignment >= scope_end) {
        return .{ .edits = try edits.toOwnedSlice(alloc), .alloc = alloc };
    }

    const scope_text = source[after_assignment..scope_end];
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, scope_text, pos, var_name)) |idx| {
        const abs = idx;
        const before_ok = abs == 0 or !isRubyIdent(scope_text[abs - 1]);
        const after_ok = abs + var_name.len >= scope_text.len or !isRubyIdent(scope_text[abs + var_name.len]);
        if (before_ok and after_ok) count += 1;
        pos = idx + var_name.len;
    }

    if (count == 0) {
        return .{ .edits = try edits.toOwnedSlice(alloc), .alloc = alloc };
    }

    try edits.append(alloc, .{
        .start_line = target_line,
        .start_col = 0,
        .end_line = target_line + 1,
        .end_col = 0,
        .new_text = try alloc.dupe(u8, ""),
    });

    var replaced = std.ArrayList(u8).empty;
    defer replaced.deinit(alloc);
    pos = 0;
    while (pos < scope_text.len) {
        if (std.mem.indexOfPos(u8, scope_text, pos, var_name)) |idx| {
            const before_ok = idx == 0 or !isRubyIdent(scope_text[idx - 1]);
            const after_ok = idx + var_name.len >= scope_text.len or !isRubyIdent(scope_text[idx + var_name.len]);
            if (before_ok and after_ok) {
                try replaced.appendSlice(alloc, scope_text[pos..idx]);
                try replaced.appendSlice(alloc, rhs);
                pos = idx + var_name.len;
                continue;
            }
        }
        try replaced.appendSlice(alloc, scope_text[pos..]);
        break;
    }

    const replace_start_line = target_line + 1;
    var replace_end_line: u32 = replace_start_line;
    {
        var off: usize = after_assignment;
        while (off < scope_end and off < source.len) : (off += 1) {
            if (source[off] == '\n') replace_end_line += 1;
        }
    }

    try edits.append(alloc, .{
        .start_line = replace_start_line,
        .start_col = 0,
        .end_line = replace_end_line,
        .end_col = 0,
        .new_text = try alloc.dupe(u8, replaced.items),
    });

    return .{
        .edits = try edits.toOwnedSlice(alloc),
        .alloc = alloc,
    };
}

pub const StringStyle = enum { single_to_double, double_to_single, string_to_symbol };

pub fn convertStringStyle(
    alloc: std.mem.Allocator,
    source: []const u8,
    line: u32,
    col: u32,
    style: StringStyle,
) !RefactorResult {
    var edits = std.ArrayList(RefactorEdit).empty;

    const offset = lineOffset(source, line) + col;
    if (offset >= source.len) {
        return .{ .edits = try edits.toOwnedSlice(alloc), .alloc = alloc };
    }

    const ch = source[offset];
    var str_start = offset;
    var str_end = offset + 1;

    if (ch == '\'' or ch == '"') {
        str_start = offset;
        while (str_end < source.len and source[str_end] != ch) {
            if (source[str_end] == '\\') str_end += 1;
            str_end += 1;
        }
        if (str_end < source.len) str_end += 1;
    } else if (ch == ':' and offset + 1 < source.len and isRubyIdent(source[offset + 1])) {
        str_start = offset;
        str_end = offset + 1;
        while (str_end < source.len and isRubyIdent(source[str_end])) str_end += 1;
    } else {
        return .{ .edits = try edits.toOwnedSlice(alloc), .alloc = alloc };
    }

    const original = source[str_start..str_end];
    var new_text = std.ArrayList(u8).empty;
    defer new_text.deinit(alloc);

    switch (style) {
        .single_to_double => {
            if (original.len < 2 or original[0] != '\'') {
                return .{ .edits = try edits.toOwnedSlice(alloc), .alloc = alloc };
            }
            try new_text.append(alloc, '"');
            for (original[1 .. original.len - 1]) |c| {
                if (c == '"') try new_text.append(alloc, '\\');
                try new_text.append(alloc, c);
            }
            try new_text.append(alloc, '"');
        },
        .double_to_single => {
            if (original.len < 2 or original[0] != '"') {
                return .{ .edits = try edits.toOwnedSlice(alloc), .alloc = alloc };
            }
            var has_interpolation = false;
            var j: usize = 1;
            while (j < original.len - 1) : (j += 1) {
                if (original[j] == '#' and j + 1 < original.len - 1 and original[j + 1] == '{') {
                    has_interpolation = true;
                    break;
                }
            }
            if (has_interpolation) {
                return .{ .edits = try edits.toOwnedSlice(alloc), .alloc = alloc };
            }
            try new_text.append(alloc, '\'');
            for (original[1 .. original.len - 1]) |c| {
                if (c == '\'') try new_text.append(alloc, '\\');
                try new_text.append(alloc, c);
            }
            try new_text.append(alloc, '\'');
        },
        .string_to_symbol => {
            if (original.len < 2 or (original[0] != '"' and original[0] != '\'')) {
                return .{ .edits = try edits.toOwnedSlice(alloc), .alloc = alloc };
            }
            const inner = original[1 .. original.len - 1];
            var valid_sym = inner.len > 0;
            for (inner) |c| {
                if (!isRubyIdent(c)) {
                    valid_sym = false;
                    break;
                }
            }
            if (valid_sym) {
                try new_text.append(alloc, ':');
                try new_text.appendSlice(alloc, inner);
            } else {
                try new_text.appendSlice(alloc, ":\"");
                try new_text.appendSlice(alloc, inner);
                try new_text.append(alloc, '"');
            }
        },
    }

    const end_line = line + countNewlines(original);
    const end_col: u32 = if (end_line > line)
        @intCast(original.len - (std.mem.lastIndexOfScalar(u8, original, '\n') orelse 0) - 1)
    else
        col + @as(u32, @intCast(original.len));

    try edits.append(alloc, .{
        .start_line = line,
        .start_col = col,
        .end_line = end_line,
        .end_col = end_col,
        .new_text = try alloc.dupe(u8, new_text.items),
    });

    return .{
        .edits = try edits.toOwnedSlice(alloc),
        .alloc = alloc,
    };
}

fn countNewlines(s: []const u8) u32 {
    var c: u32 = 0;
    for (s) |ch| if (ch == '\n') {
        c += 1;
    };
    return c;
}

fn isPureLiteral(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '\'' or s[0] == '"') return s.len >= 2 and s[s.len - 1] == s[0];
    if (s[0] == ':') return s.len >= 2;
    if (s[0] >= '0' and s[0] <= '9') return true;
    if (s[0] == '-' and s.len >= 2 and s[1] >= '0' and s[1] <= '9') return true;
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "nil")) return true;
    if (s[0] == '[' and s[s.len - 1] == ']') return true;
    if (s[0] == '{' and s[s.len - 1] == '}') return true;
    return false;
}

fn findEnclosingDefStart(source: []const u8, offset: usize) ?usize {
    var i: usize = offset;
    var depth: i32 = 0;
    while (i > 0) {
        i -= 1;
        if (i + 3 <= source.len and std.mem.eql(u8, source[i .. i + 3], "end")) {
            if (i == 0 or !isRubyIdent(source[i - 1])) {
                if (i + 3 >= source.len or !isRubyIdent(source[i + 3])) {
                    depth += 1;
                }
            }
        }
        if (i + 3 <= source.len and std.mem.eql(u8, source[i .. i + 3], "def")) {
            if (i == 0 or !isRubyIdent(source[i - 1])) {
                if (i + 3 < source.len and source[i + 3] == ' ') {
                    if (depth == 0) return i;
                    depth -= 1;
                }
            }
        }
    }
    return null;
}

fn findMatchingEnd(source: []const u8, def_start: usize) ?usize {
    var i: usize = def_start + 3;
    var depth: i32 = 1;
    while (i < source.len) {
        if (i + 3 <= source.len and std.mem.eql(u8, source[i .. i + 3], "def")) {
            if ((i == 0 or !isRubyIdent(source[i - 1])) and
                (i + 3 < source.len and source[i + 3] == ' '))
            {
                depth += 1;
            }
        }
        if (source[i] == '\n') {
            const next_line_start = i + 1;
            var j = next_line_start;
            while (j < source.len and (source[j] == ' ' or source[j] == '\t')) j += 1;
            if (j + 3 <= source.len and std.mem.eql(u8, source[j .. j + 3], "end")) {
                if (j + 3 >= source.len or !isRubyIdent(source[j + 3])) {
                    depth -= 1;
                    if (depth == 0) return j + 3;
                }
            }
            if (j + 5 <= source.len and std.mem.eql(u8, source[j .. j + 5], "class")) {
                if (j + 5 < source.len and source[j + 5] == ' ') depth += 1;
            }
            if (j + 6 <= source.len and std.mem.eql(u8, source[j .. j + 6], "module")) {
                if (j + 6 < source.len and source[j + 6] == ' ') depth += 1;
            }
            if (j + 2 <= source.len and std.mem.eql(u8, source[j .. j + 2], "if")) {
                if ((j + 2 < source.len and source[j + 2] == ' ') and
                    (j == next_line_start or source[j - 1] == '\n' or source[j - 1] == ' '))
                    depth += 1;
            }
        }
        i += 1;
    }
    return null;
}

fn findEnclosingClassLine(source: []const u8, offset: usize) ?u32 {
    var i: usize = offset;
    while (i > 0) {
        i -= 1;
        if (i + 5 <= source.len and std.mem.eql(u8, source[i .. i + 5], "class")) {
            if (i == 0 or source[i - 1] == '\n') {
                var line: u32 = 0;
                for (source[0..i]) |c| {
                    if (c == '\n') line += 1;
                }
                return line;
            }
        }
    }
    return null;
}

pub fn availableRefactors(
    source: []const u8,
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
) []const RefactorKind {
    const S = struct {
        var buf: [5]RefactorKind = undefined;
    };
    var count: usize = 0;

    if (start_line != end_line or start_col != end_col) {
        S.buf[count] = .extract_method;
        count += 1;
        S.buf[count] = .extract_variable;
        count += 1;

        const sel_start = lineOffset(source, start_line) + start_col;
        const sel_end_line_off = lineOffset(source, end_line);
        const sel_end = sel_end_line_off + end_col;
        if (sel_start < source.len and sel_end <= source.len) {
            const selected = source[sel_start..sel_end];
            if (isPureLiteral(selected)) {
                S.buf[count] = .extract_constant;
                count += 1;
            }
        }
    }

    if (start_line == end_line) {
        const line_text = lineAt(source, start_line);
        const trimmed = std.mem.trim(u8, line_text, " \t");
        if (std.mem.indexOf(u8, trimmed, " = ") != null) {
            S.buf[count] = .inline_variable;
            count += 1;
        }

        const offset = lineOffset(source, start_line) + start_col;
        if (offset < source.len) {
            const ch = source[offset];
            if (ch == '\'' or ch == '"' or ch == ':') {
                S.buf[count] = .convert_string_style;
                count += 1;
            }
        }
    }

    return S.buf[0..count];
}

test "extract method generates def and call" {
    const alloc = std.testing.allocator;
    const src = "class Foo\n  def bar\n    x = 1\n    y = 2\n  end\nend\n";
    var result = try extractMethod(alloc, src, 2, 3, "compute");
    defer result.deinit();
    try std.testing.expect(result.edits.len >= 1);
}

test "extract variable generates assignment" {
    const alloc = std.testing.allocator;
    const src = "x = foo.bar.baz\n";
    var result = try extractVariable(alloc, src, 0, 4, 0, 15, "result");
    defer result.deinit();
    try std.testing.expect(result.edits.len >= 1);
}

test "extract constant from string literal" {
    const alloc = std.testing.allocator;
    const src = "class Foo\n  def bar\n    x = \"hello\"\n  end\nend\n";
    var result = try extractConstant(alloc, src, 2, 8, 2, 15, "GREETING");
    defer result.deinit();
    try std.testing.expect(result.edits.len >= 1);
}

test "inline variable replaces usages" {
    const alloc = std.testing.allocator;
    const src = "def foo\n  x = 42\n  puts x\nend\n";
    var result = try inlineVariable(alloc, src, 1, 2);
    defer result.deinit();
    try std.testing.expect(result.edits.len >= 1);
}

test "convert single to double quotes" {
    const alloc = std.testing.allocator;
    const src = "'hello'\n";
    var result = try convertStringStyle(alloc, src, 0, 0, .single_to_double);
    defer result.deinit();
    try std.testing.expect(result.edits.len == 1);
    try std.testing.expectEqualStrings("\"hello\"", result.edits[0].new_text);
}

test "convert double to single quotes" {
    const alloc = std.testing.allocator;
    const src = "\"hello\"\n";
    var result = try convertStringStyle(alloc, src, 0, 0, .double_to_single);
    defer result.deinit();
    try std.testing.expect(result.edits.len == 1);
    try std.testing.expectEqualStrings("'hello'", result.edits[0].new_text);
}

test "convert string to symbol" {
    const alloc = std.testing.allocator;
    const src = "\"name\"\n";
    var result = try convertStringStyle(alloc, src, 0, 0, .string_to_symbol);
    defer result.deinit();
    try std.testing.expect(result.edits.len == 1);
    try std.testing.expectEqualStrings(":name", result.edits[0].new_text);
}

test "isPureLiteral" {
    try std.testing.expect(isPureLiteral("42"));
    try std.testing.expect(isPureLiteral("\"hello\""));
    try std.testing.expect(isPureLiteral("'world'"));
    try std.testing.expect(isPureLiteral(":foo"));
    try std.testing.expect(isPureLiteral("true"));
    try std.testing.expect(isPureLiteral("[1,2]"));
    try std.testing.expect(!isPureLiteral("foo.bar"));
    try std.testing.expect(!isPureLiteral(""));
}

test "available refactors for selection" {
    const src = "x = 42\ny = x + 1\n";
    const kinds = availableRefactors(src, 0, 4, 0, 6);
    try std.testing.expect(kinds.len >= 2);
}

test "available refactors for single line with assignment" {
    const src = "x = foo\n";
    const kinds = availableRefactors(src, 0, 0, 0, 0);
    var has_inline = false;
    for (kinds) |k| {
        if (k == .inline_variable) has_inline = true;
    }
    try std.testing.expect(has_inline);
}

test "extract constant rejects non-literal" {
    const alloc = std.testing.allocator;
    const src = "class Foo\n  x = foo.bar\nend\n";
    var result = try extractConstant(alloc, src, 1, 6, 1, 13, "CONST");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.edits.len);
}

test "inline variable no assignment" {
    const alloc = std.testing.allocator;
    const src = "def foo\n  puts 'hi'\nend\n";
    var result = try inlineVariable(alloc, src, 1, 2);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.edits.len);
}

test "convert double to single rejects interpolation" {
    const alloc = std.testing.allocator;
    const src = "\"hello #{name}\"\n";
    var result = try convertStringStyle(alloc, src, 0, 0, .double_to_single);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.edits.len);
}

test "findEnclosingDefStart" {
    const src = "class Foo\n  def bar\n    x = 1\n  end\nend\n";
    const pos = findEnclosingDefStart(src, 25);
    try std.testing.expect(pos != null);
}

test "findMatchingEnd" {
    const src = "def foo\n  x = 1\nend\n";
    const ds = findEnclosingDefStart(src, 10);
    try std.testing.expect(ds != null);
    const me = findMatchingEnd(src, ds.?);
    try std.testing.expect(me != null);
}

test "lineAt returns correct line" {
    const src = "line0\nline1\nline2\n";
    try std.testing.expectEqualStrings("line0", lineAt(src, 0));
    try std.testing.expectEqualStrings("line1", lineAt(src, 1));
    try std.testing.expectEqualStrings("line2", lineAt(src, 2));
}

test "getIndent extracts leading whitespace" {
    try std.testing.expectEqualStrings("  ", getIndent("  def foo"));
    try std.testing.expectEqualStrings("", getIndent("def foo"));
    try std.testing.expectEqualStrings("\t", getIndent("\tdef foo"));
}
