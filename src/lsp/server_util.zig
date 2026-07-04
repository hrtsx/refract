const std = @import("std");
const builtin = @import("builtin");
const db_mod = @import("../db.zig");
const types = @import("types.zig");
const refactor = @import("refactor.zig");

/// Directory holding all per-project databases. Caller owns the result.
pub fn computeDataDir(alloc: std.mem.Allocator) ![]u8 {
    const home: []const u8 = if (std.c.getenv("HOME")) |p| std.mem.span(p) else "/tmp";
    return if (std.c.getenv("XDG_DATA_HOME")) |xdg|
        try std.fmt.allocPrint(alloc, "{s}/refract", .{std.mem.span(xdg)})
    else if (builtin.os.tag == .macos)
        try std.fmt.allocPrint(alloc, "{s}/Library/Application Support/refract", .{home})
    else
        try std.fmt.allocPrint(alloc, "{s}/.local/share/refract", .{home});
}

pub fn computeDbPath(alloc: std.mem.Allocator, root_path: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(root_path);
    const hash = hasher.final();

    const data_dir = try computeDataDir(alloc);
    defer alloc.free(data_dir);

    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, data_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    return std.fmt.allocPrint(alloc, "{s}/{x}.db", .{ data_dir, hash });
}

pub fn uriToPath(alloc: std.mem.Allocator, uri: []const u8) ![]u8 {
    const rest = if (std.mem.startsWith(u8, uri, "file://")) uri[7..] else uri;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < rest.len) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            const hi = std.fmt.charToDigit(rest[i + 1], 16) catch std.math.maxInt(u8);
            const lo = std.fmt.charToDigit(rest[i + 2], 16) catch std.math.maxInt(u8);
            if (hi < 16 and lo < 16) {
                try out.append(alloc, @intCast(hi * 16 + lo));
                i += 3;
                continue;
            }
        }
        try out.append(alloc, rest[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

pub fn pathToUri(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "file://");
    for (path) |c| {
        const safe = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '/' or c == '.' or c == '_' or c == '-' or c == '~' or
            c == ':' or c == '@' or c == '!' or c == '$' or c == '&' or
            c == '\'' or c == '(' or c == ')' or c == '*' or c == '+' or
            c == ',' or c == ';' or c == '=';
        if (safe) {
            try out.append(alloc, c);
        } else {
            var hex_buf: [3]u8 = undefined;
            const hex = try std.fmt.bufPrint(&hex_buf, "%{X:0>2}", .{c});
            try out.appendSlice(alloc, hex);
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn resolveRequireTarget(alloc: std.mem.Allocator, db: db_mod.Db, source: []const u8, cursor_offset: usize, current_file: []const u8) ?[]u8 {
    // Find line bounds containing cursor
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < cursor_offset) : (i += 1) {
        if (source[i] == '\n') line_start = i + 1;
    }
    var line_end = cursor_offset;
    while (line_end < source.len and source[line_end] != '\n') line_end += 1;
    const line_src = source[line_start..line_end];

    // Match require or require_relative with a string literal
    const rel_prefix = "require_relative";
    const req_prefix = "require";
    var is_relative = false;
    var rest: []const u8 = undefined;

    const trimmed = std.mem.trimStart(u8, line_src, " \t");
    if (std.mem.startsWith(u8, trimmed, rel_prefix)) {
        is_relative = true;
        rest = std.mem.trimStart(u8, trimmed[rel_prefix.len..], " \t");
    } else if (std.mem.startsWith(u8, trimmed, req_prefix)) {
        rest = std.mem.trimStart(u8, trimmed[req_prefix.len..], " \t");
    } else return null;

    if (rest.len < 2) return null;
    const quote = rest[0];
    if (quote != '\'' and quote != '"') return null;
    const close = std.mem.indexOfScalarPos(u8, rest, 1, quote) orelse return null;
    const req_str = rest[1..close];
    if (req_str.len == 0) return null;

    // Check cursor is within the string literal
    const str_abs_start = line_start + (@intFromPtr(rest.ptr) - @intFromPtr(line_src.ptr)) + 1;
    const str_abs_end = str_abs_start + req_str.len;
    if (cursor_offset < str_abs_start - 1 or cursor_offset > str_abs_end + 1) return null;

    if (is_relative) {
        const dir = std.fs.path.dirname(current_file) orelse return null;
        const candidate = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, req_str }) catch return null;
        defer alloc.free(candidate);
        // Try with .rb extension if not already present
        if (std.mem.endsWith(u8, candidate, ".rb")) {
            std.Io.Dir.accessAbsolute(std.Options.debug_io, candidate, .{}) catch return null;
            return alloc.dupe(u8, candidate) catch null;
        }
        const with_rb = std.fmt.allocPrint(alloc, "{s}.rb", .{candidate}) catch return null;
        defer alloc.free(with_rb);
        std.Io.Dir.accessAbsolute(std.Options.debug_io, with_rb, .{}) catch return null;
        return alloc.dupe(u8, with_rb) catch null;
    } else {
        // Search workspace DB
        const stmt = db.prepare("SELECT f.path FROM files f WHERE f.is_gem=0 AND f.path LIKE ? LIMIT 5") catch return null;
        defer stmt.finalize();
        const pattern = std.fmt.allocPrint(alloc, "%/{s}.rb", .{req_str}) catch return null;
        defer alloc.free(pattern);
        stmt.bind_text(1, pattern);
        if (stmt.step() catch false) {
            return alloc.dupe(u8, stmt.column_text(0)) catch null;
        }
        return null;
    }
}

pub fn normalizeCRLF(buf: []u8) []u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '\r' and i + 1 < buf.len and buf[i + 1] == '\n') continue;
        buf[w] = buf[i];
        w += 1;
    }
    return buf[0..w];
}

pub fn isInStringOrComment(source: []const u8, offset: usize) bool {
    var in_string: u8 = 0;
    var interp_depth: u32 = 0;
    var in_comment = false;
    var in_heredoc = false;
    var heredoc_term: []const u8 = "";
    var i: usize = 0;
    while (i < offset and i < source.len) : (i += 1) {
        const c = source[i];
        const at_line_start = (i == 0 or source[i - 1] == '\n');
        if (in_comment) {
            if (c == '\n') in_comment = false;
        } else if (in_heredoc) {
            if (at_line_start and heredoc_term.len > 0 and
                i + heredoc_term.len <= source.len and
                std.mem.eql(u8, source[i .. i + heredoc_term.len], heredoc_term))
            {
                const after = i + heredoc_term.len;
                if (after >= source.len or source[after] == '\n') {
                    in_heredoc = false;
                    i = after - 1;
                }
            }
        } else if (in_string != 0) {
            if (c == '\\' and i + 1 < source.len) {
                i += 1;
            } else if (in_string == '"' and c == '#' and i + 1 < source.len and source[i + 1] == '{') {
                interp_depth += 1;
                i += 1;
            } else if (interp_depth > 0 and c == '}') {
                interp_depth -= 1;
            } else if (interp_depth == 0 and c == in_string) {
                in_string = 0;
            }
        } else {
            if (c == '#') {
                in_comment = true;
            } else if (c == '\'' or c == '"') {
                in_string = c;
            } else if (c == '<' and i + 1 < source.len and source[i + 1] == '<') {
                var j = i + 2;
                if (j < source.len and (source[j] == '-' or source[j] == '~')) j += 1;
                const close_quote: u8 = if (j < source.len and (source[j] == '\'' or source[j] == '"')) blk: {
                    const q = source[j];
                    j += 1;
                    break :blk q;
                } else 0;
                const term_start = j;
                while (j < source.len and source[j] != '\n') {
                    if (close_quote != 0 and source[j] == close_quote) break;
                    if (close_quote == 0 and (source[j] == ' ' or source[j] == '\t' or
                        source[j] == ';' or source[j] == ',' or source[j] == ')')) break;
                    j += 1;
                }
                if (j > term_start) {
                    heredoc_term = source[term_start..j];
                    while (j < source.len and source[j] != '\n') j += 1;
                    in_heredoc = true;
                    i = j;
                }
            }
        }
    }
    return (in_string != 0 and interp_depth == 0) or in_comment or in_heredoc;
}

pub fn writePathAsUri(w: *std.Io.Writer, path: []const u8) !void {
    for (path) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '/' => try w.writeByte(c),
            else => try w.print("%{X:0>2}", .{c}),
        }
    }
}

pub fn extractParamsObject(params: ?std.json.Value) ?std.json.ObjectMap {
    return switch (params orelse return null) {
        .object => |o| o,
        else => null,
    };
}

pub fn extractTextDocumentUri(params: ?std.json.Value) ?[]const u8 {
    const obj = extractParamsObject(params) orelse return null;
    const td = switch (obj.get("textDocument") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return switch (td.get("uri") orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn extractPosition(params: ?std.json.Value) ?struct { line: u32, character: u32 } {
    const obj = extractParamsObject(params) orelse return null;
    const pos = switch (obj.get("position") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const ln = switch (pos.get("line") orelse return null) {
        .integer => |i| i,
        else => return null,
    };
    const ch = switch (pos.get("character") orelse return null) {
        .integer => |i| i,
        else => return null,
    };
    if (ln < 0 or ch < 0) return null;
    return .{ .line = @intCast(ln), .character = @intCast(ch) };
}

pub fn matchesCamelInitials(query: []const u8, name: []const u8) bool {
    if (query.len == 0) return true;
    var qi: usize = 0;
    for (name) |c| {
        if (qi >= query.len) break;
        if (std.ascii.toUpper(c) == std.ascii.toUpper(query[qi])) qi += 1;
    }
    return qi == query.len;
}

pub fn isSubsequence(query: []const u8, name: []const u8) bool {
    if (query.len == 0) return true;
    var qi: usize = 0;
    for (name) |c| {
        if (qi >= query.len) break;
        if (std.ascii.toLower(c) == std.ascii.toLower(query[qi])) qi += 1;
    }
    return qi == query.len;
}

pub fn buildQueryPattern(alloc: std.mem.Allocator, query: []const u8) ![]u8 {
    if (query.len == 0) return alloc.dupe(u8, "%");
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);
    const short = query.len <= 3;
    if (!short) try buf.append(alloc, '%');
    for (query) |c| {
        if (c == '%' or c == '_' or c == '\\') try buf.append(alloc, '\\');
        try buf.append(alloc, c);
    }
    try buf.append(alloc, '%');
    return buf.toOwnedSlice(alloc);
}

pub fn buildPrefixPattern(alloc: std.mem.Allocator, word: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);
    for (word) |c| {
        if (c == '%' or c == '_' or c == '\\') try buf.append(alloc, '\\');
        try buf.append(alloc, c);
    }
    try buf.append(alloc, '%');
    return buf.toOwnedSlice(alloc);
}

pub fn emptyResult(msg: types.RequestMessage) ?types.ResponseMessage {
    return types.ResponseMessage{ .id = msg.id, .result = null, .@"error" = null };
}

pub fn posToOffset(source: []const u8, line: u32, character: u32) usize {
    var cur_line: u32 = 0;
    var i: usize = 0;
    while (i < source.len and cur_line < line) : (i += 1) {
        if (source[i] == '\n') cur_line += 1;
    }
    return @min(i + character, source.len);
}

pub fn utf16ColToUtf8(line_src: []const u8, utf16_col: u32) usize {
    var units: u32 = 0;
    var i: usize = 0;
    while (i < line_src.len and units < utf16_col) {
        const b = line_src[i];
        const seq: usize = if (b < 0x80) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
        units += if (seq == 4) 2 else 1;
        i += seq;
    }
    // If utf16_col extends past the line, carry the overshoot through so posToOffset
    // clamps to source.len — matching the UTF-8 path behaviour for out-of-range positions.
    return i + (utf16_col - @min(utf16_col, units));
}

pub fn utf8ColToUtf16(line_src: []const u8, utf8_col: usize) u32 {
    var utf16: u32 = 0;
    var i: usize = 0;
    while (i < utf8_col and i < line_src.len) {
        const b = line_src[i];
        const seq: usize = if (b < 0x80) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
        utf16 += if (seq == 4) 2 else 1;
        i += seq;
    }
    return utf16;
}

pub fn convertSemBlobToUtf16(blob: []const u8, source: []const u8, alloc: std.mem.Allocator) ![]u8 {
    if (blob.len == 0) return alloc.dupe(u8, &.{});
    const n = blob.len / 20;
    const out = try alloc.alloc(u8, blob.len);
    var prev_utf16_col: u32 = 0;
    var abs_line: u32 = 0;
    var abs_col: u32 = 0;
    for (0..n) |i| {
        const dl = std.mem.readInt(u32, blob[i * 20 ..][0..4], .little);
        const dc = std.mem.readInt(u32, blob[i * 20 + 4 ..][0..4], .little);
        const lb = std.mem.readInt(u32, blob[i * 20 + 8 ..][0..4], .little);
        const tt = std.mem.readInt(u32, blob[i * 20 + 12 ..][0..4], .little);
        const tm = std.mem.readInt(u32, blob[i * 20 + 16 ..][0..4], .little);
        abs_line += dl;
        abs_col = if (dl == 0) abs_col + dc else dc;
        const ln = getLineSlice(source, abs_line);
        const col16 = utf8ColToUtf16(ln, @min(abs_col, ln.len));
        const end16 = utf8ColToUtf16(ln, @min(abs_col + lb, ln.len));
        const len16 = end16 - col16;
        const odc: u32 = if (dl == 0) col16 - prev_utf16_col else col16;
        prev_utf16_col = col16;
        std.mem.writeInt(u32, out[i * 20 ..][0..4], dl, .little);
        std.mem.writeInt(u32, out[i * 20 + 4 ..][0..4], odc, .little);
        std.mem.writeInt(u32, out[i * 20 + 8 ..][0..4], len16, .little);
        std.mem.writeInt(u32, out[i * 20 + 12 ..][0..4], tt, .little);
        std.mem.writeInt(u32, out[i * 20 + 16 ..][0..4], tm, .little);
    }
    return out;
}

pub fn getLineSlice(source: []const u8, line_0: u32) []const u8 {
    var l: u32 = 0;
    var i: usize = 0;
    while (i < source.len and l < line_0) : (i += 1) {
        if (source[i] == '\n') l += 1;
    }
    const start = i;
    while (i < source.len and source[i] != '\n') : (i += 1) {}
    return source[start..i];
}

pub fn frcGet(frc: *std.StringHashMapUnmanaged([]const u8), alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    if (frc.get(path)) |src| return src;
    const src = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, alloc, std.Io.Limit.limited(1 << 24)) catch return null;
    const owned_path = alloc.dupe(u8, path) catch {
        alloc.free(src);
        return null;
    };
    frc.put(alloc, owned_path, src) catch {
        alloc.free(owned_path);
        alloc.free(src);
        return null;
    };
    return src;
}

pub fn extractWord(source: []const u8, offset: usize) []const u8 {
    if (offset >= source.len) return "";
    var start = offset;
    while (start > 0 and isRubyIdent(source[start - 1])) start -= 1;
    var end = offset;
    while (end < source.len and isRubyIdent(source[end])) end += 1;
    return source[start..end];
}

pub fn extractQualifiedName(source: []const u8, offset: usize) []const u8 {
    if (offset >= source.len) return "";
    var end = offset;
    while (end < source.len and isRubyIdent(source[end])) end += 1;
    var start = offset;
    // `!`/`?` are valid only as the TRAILING char of a method name (`save!`, `ok?`);
    // they never start or sit inside an identifier. The forward scan above already
    // captured any trailing one, so the backward scan must exclude them — otherwise a
    // unary-`!` prefix (`!current_user.confirmed?`) gets swallowed into the receiver
    // word (`!current_user`), which then matches no class and yields no completion.
    while (start > 0 and isRubyIdent(source[start - 1]) and source[start - 1] != '!' and source[start - 1] != '?') start -= 1;
    while (start >= 2 and source[start - 1] == ':' and source[start - 2] == ':') {
        var new_start = start - 2;
        while (new_start > 0 and isRubyIdent(source[new_start - 1])) new_start -= 1;
        if (new_start == start - 2) break;
        start = new_start;
    }
    return source[start..end];
}

pub fn extractBaseClass(type_str: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, type_str, '[')) |bracket| {
        return std.mem.trim(u8, type_str[0..bracket], " \t");
    }
    return std.mem.trim(u8, type_str, " \t");
}

pub fn extractGenericElement(type_str: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, type_str, '[') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, type_str, ']') orelse return null;
    if (close <= open + 1) return null;
    const inner = std.mem.trim(u8, type_str[open + 1 .. close], " \t");
    if (std.mem.indexOfScalar(u8, inner, ',')) |comma| {
        return std.mem.trim(u8, inner[0..comma], " \t");
    }
    return inner;
}

pub fn isRubyIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '?' or c == '!' or c == '@' or c == '$' or c >= 0x80;
}

pub fn isValidRubyIdent(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_' and name[0] < 0x80) return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '?' and c != '!' and c < 0x80) return false;
    }
    return true;
}

pub fn writeEscapedJsonContent(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
}

pub fn writeEscapedJson(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    try writeEscapedJsonContent(w, s);
    try w.writeByte('"');
}

pub fn writeCodeActionEdits(w: *std.Io.Writer, title: []const u8, kind: []const u8, uri: []const u8, edits: []const refactor.RefactorEdit) !void {
    try w.writeAll("{\"title\":");
    try writeEscapedJson(w, title);
    try w.writeAll(",\"kind\":");
    try writeEscapedJson(w, kind);
    try w.writeAll(",\"edit\":{\"changes\":{");
    try writeEscapedJson(w, uri);
    try w.writeAll(":[");
    for (edits, 0..) |edit, ei| {
        if (ei > 0) try w.writeByte(',');
        try w.print("{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":", .{
            edit.start_line, edit.start_col, edit.end_line, edit.end_col,
        });
        try writeEscapedJson(w, edit.new_text);
        try w.writeByte('}');
    }
    try w.writeAll("]}}}");
}

pub const init_caps_before_enc =
    \\{"capabilities":{"textDocumentSync":{"change":1,"save":{"includeText":true},"openClose":true},"workspaceSymbolProvider":true,"definitionProvider":true,"implementationProvider":true,"declarationProvider":true,"documentSymbolProvider":true,"hoverProvider":true,"completionProvider":{"triggerCharacters":[".","::", "@","$"],"resolveProvider":true},"inlineCompletionProvider":{},"referencesProvider":true,"signatureHelpProvider":{"triggerCharacters":["(",","]},"typeDefinitionProvider":true,"inlayHintProvider":true,"semanticTokensProvider":{"legend":{"tokenTypes":["class","namespace","method","parameter","variable","type"],"tokenModifiers":["declaration","readonly","deprecated","static"]},"full":{"delta":true},"range":true},"renameProvider":true,"prepareRenameProvider":true,"documentHighlightProvider":true,"documentLinkProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix","refactor.extract","refactor.inline","refactor.rewrite"]},"foldingRangeProvider":true,"documentRangeFormattingProvider":true,"callHierarchyProvider":true,"codeLensProvider":{"resolveProvider":false},"typeHierarchyProvider":true,"selectionRangeProvider":true,"linkedEditingRangeProvider":true,"diagnosticProvider":{"identifier":"refract","interFileDependencies":false,"workspaceDiagnostics":false},"executeCommandProvider":{"commands":["refract.restartIndexer","refract.forceReindex","refract.toggleGemIndex","refract.showReferences","refract.runTest","refract.debugTest","refract.recheckRubocop","refract.disableDiagnostic"]},"experimental":{"refract":{"dap":true,"plugins":true,"inlineCompletion":true}},"workspace":{"workspaceFolders":{"supported":true,"changeNotifications":true},"didChangeConfiguration":{"dynamicRegistration":true},"fileOperations":{"didCreate":{"filters":[{"scheme":"file","pattern":{"glob":"**/*.{rb,rbs,rbi,erb,rake,gemspec,ru}"}}]},"didDelete":{"filters":[{"scheme":"file","pattern":{"glob":"**/*.{rb,rbs,rbi,erb,rake,gemspec,ru}"}}]},"didChange":{"filters":[{"scheme":"file","pattern":{"glob":"**/*.{rb,rbs,rbi,erb,rake,gemspec,ru}"}}]},"willRename":{"filters":[{"scheme":"file","pattern":{"glob":"**/*.{rb,rbs,rbi,erb,rake,gemspec,ru}"}}]}}},"positionEncoding":
;
pub const init_caps_after_enc =
    \\},"serverInfo":{"name":"refract","version":"
;
