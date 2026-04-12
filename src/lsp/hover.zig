const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const types = @import("types.zig");
const db_mod = @import("../db.zig");
const erb_mapping = @import("erb_mapping.zig");

const extractTextDocumentUri = S.extractTextDocumentUri;
const extractPosition = S.extractPosition;
const uriToPath = S.uriToPath;
const emptyResult = S.emptyResult;
const writeEscapedJsonContent = S.writeEscapedJsonContent;
const resolveRequireTarget = S.resolveRequireTarget;
const getLineSlice = S.getLineSlice;
const extractWord = S.extractWord;
const extractQualifiedName = S.extractQualifiedName;
const utf8ColToUtf16 = S.utf8ColToUtf16;

pub fn handleHover(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    self.flushDirtyUris();
    if (self.isCancelled(msg.id)) return null;
    self.db_mutex.lock();
    defer self.db_mutex.unlock();
    const uri = extractTextDocumentUri(msg.params) orelse return emptyResult(msg);
    const pos = extractPosition(msg.params) orelse return emptyResult(msg);
    const line: u32 = pos.line;
    const character: u32 = pos.character;

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);
    if (!self.pathInBounds(path)) return emptyResult(msg);
    const source = self.readSourceForUri(uri, path) catch
        return emptyResult(msg);
    defer self.alloc.free(source);

    const offset = self.clientPosToOffset(source, line, character);

    if (std.mem.endsWith(u8, path, ".erb") and !erb_mapping.isErbRubyContext(source, offset))
        return emptyResult(msg);

    if (resolveRequireTarget(self.alloc, self.db, source, offset, path)) |target_path| {
        defer self.alloc.free(target_path);
        var rq_aw = std.Io.Writer.Allocating.init(self.alloc);
        const rq_w = &rq_aw.writer;
        try rq_w.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":\"**Requires:** `");
        try writeEscapedJsonContent(rq_w, target_path);
        try rq_w.writeAll("`\"}");
        try rq_w.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":999}}}}}}", .{ line, line });
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try rq_aw.toOwnedSlice(), .@"error" = null };
    }

    if (Server.detectI18nContext(source, offset)) {
        const hover_line_src = getLineSlice(source, line);
        var key_start = offset;
        while (key_start > 0 and source[key_start - 1] != '"' and source[key_start - 1] != '\'') {
            key_start -= 1;
        }
        if (key_start > 0) key_start -= 1;
        var key_end = offset;
        while (key_end < source.len and source[key_end] != '"' and source[key_end] != '\'') {
            key_end += 1;
        }
        const word_col_byte = if (key_start < hover_line_src.len) key_start else 0;
        const hover_wc16 = self.toClientCol(hover_line_src, word_col_byte);
        const hover_we16 = hover_wc16 + @as(u32, @intCast(key_end - key_start));
        return try hoverI18n(self, msg, source, offset, line, hover_wc16, hover_we16);
    }

    const word = extractWord(source, offset);
    if (word.len == 0) return emptyResult(msg);

    const hover_line_src = getLineSlice(source, line);
    const word_col_byte = if (@intFromPtr(word.ptr) >= @intFromPtr(hover_line_src.ptr))
        @intFromPtr(word.ptr) - @intFromPtr(hover_line_src.ptr)
    else
        0;
    const hover_wc16 = self.toClientCol(hover_line_src, word_col_byte);
    const hover_we16 = utf8ColToUtf16(hover_line_src, @min(word_col_byte + word.len, hover_line_src.len));

    // Check local_vars first for concrete inferred types
    const cursor_line: i64 = @intCast(line + 1);
    const fstmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
    defer fstmt.finalize();
    fstmt.bind_text(1, path);
    if (try fstmt.step()) {
        const fid = fstmt.column_int(0);
        const lv_stmt = try self.db.prepare("SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND line<=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 10");
        defer lv_stmt.finalize();
        lv_stmt.bind_int(1, fid);
        lv_stmt.bind_text(2, word);
        lv_stmt.bind_int(3, cursor_line);
        var type_hints: [3][]u8 = undefined;
        var hint_count: usize = 0;
        while (try lv_stmt.step()) {
            const th = lv_stmt.column_text(0);
            var found = false;
            for (type_hints[0..hint_count]) |s| {
                if (std.mem.eql(u8, s, th)) {
                    found = true;
                    break;
                }
            }
            if (!found and hint_count < 3) {
                type_hints[hint_count] = self.alloc.dupe(u8, th) catch break;
                hint_count += 1;
            }
        }
        defer for (type_hints[0..hint_count]) |t| self.alloc.free(t);
        if (hint_count > 0) {
            var aw = std.Io.Writer.Allocating.init(self.alloc);
            const w = &aw.writer;
            try w.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":\"`");
            try writeEscapedJsonContent(w, word);
            try w.writeAll("`: ");
            for (type_hints[0..hint_count], 0..) |th, ti| {
                if (ti > 0) try w.writeAll(" | ");
                try writeEscapedJsonContent(w, th);
            }
            try w.writeAll("\"}");
            try w.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ line, hover_wc16, line, hover_we16 });
            return types.ResponseMessage{
                .id = msg.id,
                .result = null,
                .raw_result = try aw.toOwnedSlice(),
                .@"error" = null,
            };
        }
        // Check for untyped local var
        const lv_exist = try self.db.prepare("SELECT 1 FROM local_vars WHERE file_id=? AND name=? AND line<=? LIMIT 1");
        defer lv_exist.finalize();
        lv_exist.bind_int(1, fid);
        lv_exist.bind_text(2, word);
        lv_exist.bind_int(3, cursor_line);
        if (try lv_exist.step()) {
            var aw_lv = std.Io.Writer.Allocating.init(self.alloc);
            const w_lv = &aw_lv.writer;
            try w_lv.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":\"*(local variable)* `");
            try writeEscapedJsonContent(w_lv, word);
            try w_lv.writeAll("\"}");
            try w_lv.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ line, hover_wc16, line, hover_we16 });
            return types.ResponseMessage{
                .id = msg.id,
                .result = null,
                .raw_result = try aw_lv.toOwnedSlice(),
                .@"error" = null,
            };
        }
    }

    if (try hoverLookup(self, msg, word, path, line, hover_wc16, hover_we16)) |r| return r;

    const qualified = extractQualifiedName(source, offset);
    if (!std.mem.eql(u8, qualified, word)) {
        if (try hoverLookup(self, msg, qualified, path, line, hover_wc16, hover_we16)) |r| return r;
    }

    return emptyResult(msg);
}

pub fn hoverLookup(self: *Server, msg: types.RequestMessage, name: []const u8, current_path: []const u8, hover_line: u32, wc16: u32, we16: u32) !?types.ResponseMessage {
    const stmt = try self.db.prepare(
        \\SELECT s.kind, s.line, s.return_type, s.doc, f.path, s.id, s.value_snippet, s.parent_name
        \\FROM symbols s JOIN files f ON s.file_id = f.id
        \\WHERE s.name = ?
        \\ORDER BY CASE WHEN f.path = ? THEN 0 ELSE 1 END, s.id
        \\LIMIT 1
    );
    defer stmt.finalize();
    stmt.bind_text(1, name);
    stmt.bind_text(2, current_path);

    if (!(try stmt.step())) return null;

    const kind_str = stmt.column_text(0);
    const sym_line = stmt.column_int(1);
    const return_type = stmt.column_text(2);
    const doc = stmt.column_text(3);
    const sym_path = stmt.column_text(4);
    const sym_id = stmt.column_int(5);
    const value_snippet = stmt.column_text(6);
    const parent_name = stmt.column_text(7);

    const kind_label: []const u8 = if (std.mem.eql(u8, kind_str, "classdef")) "def self" else kind_str;

    // Fetch parameter signature for def symbols
    var param_sig_buf = std.ArrayList(u8){};
    defer param_sig_buf.deinit(self.alloc);
    if (std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) {
        const ps = self.db.prepare(
            \\SELECT GROUP_CONCAT(
            \\  CASE p.kind WHEN 'keyword' THEN p.name||':' WHEN 'rest' THEN '*'||p.name
            \\  WHEN 'keyword_rest' THEN '**'||p.name WHEN 'block' THEN '&'||p.name
            \\  ELSE p.name END, ', ')
            \\FROM params p WHERE p.symbol_id=? ORDER BY p.position
        ) catch null;
        if (ps) |s| {
            defer s.finalize();
            s.bind_int(1, sym_id);
            if (s.step() catch false) {
                const sig = s.column_text(0);
                if (sig.len > 0) param_sig_buf.appendSlice(self.alloc, sig) catch {}; // OOM: signature building
            }
        }
    }

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":\"*(");
    try writeEscapedJsonContent(w, kind_label);
    try w.writeAll(")* `");
    try writeEscapedJsonContent(w, name);
    if (param_sig_buf.items.len > 0) {
        try w.writeAll("(");
        try writeEscapedJsonContent(w, param_sig_buf.items);
        try w.writeAll(")");
    }
    try w.writeByte('`');
    if ((std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) and return_type.len > 0) {
        try w.writeAll(" \\u2192 ");
        try writeEscapedJsonContent(w, return_type);
        if (self.isNilableMethod(name)) {
            try w.writeAll(" | nil");
        }
    }
    if (std.mem.eql(u8, kind_str, "constant") and value_snippet.len > 0) {
        try w.writeAll(" = `");
        try writeEscapedJsonContent(w, value_snippet);
        try w.writeByte('`');
    }
    try w.writeAll("\\n\\n\\u2192 ");
    try writeEscapedJsonContent(w, sym_path);
    try w.print(":{d}", .{sym_line});
    if (doc.len > 0) {
        try w.writeAll("\\n\\n");
        try writeEscapedJsonContent(w, doc);
    }
    if (std.mem.eql(u8, kind_str, "class") or std.mem.eql(u8, kind_str, "module")) {
        if (parent_name.len > 0 and !std.mem.eql(u8, parent_name, "Object")) {
            try w.writeAll("\\n\\n**Inherits:** `");
            try writeEscapedJsonContent(w, parent_name);
            try w.writeByte('`');
        }
        const mx_stmt = self.db.prepare("SELECT module_name FROM mixins WHERE class_id = ? AND kind IN ('include','prepend') ORDER BY rowid") catch null;
        if (mx_stmt) |ms| {
            defer ms.finalize();
            ms.bind_int(1, sym_id);
            var first_mx = true;
            while (ms.step() catch false) {
                const mod = ms.column_text(0);
                if (first_mx) {
                    try w.writeAll("\\n\\n**Includes:** `");
                    first_mx = false;
                } else {
                    try w.writeAll("`, `");
                }
                try writeEscapedJsonContent(w, mod);
            }
            if (!first_mx) try w.writeByte('`');
        }
    }
    try w.writeAll("\"}");
    try w.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ hover_line, wc16, hover_line, we16 });

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn hoverI18n(self: *Server, msg: types.RequestMessage, source: []const u8, offset: usize, hover_line: u32, wc16: u32, we16: u32) !?types.ResponseMessage {
    var key_start = offset;
    while (key_start > 0 and source[key_start - 1] != '"' and source[key_start - 1] != '\'') {
        key_start -= 1;
    }
    if (key_start > 0) key_start -= 1;
    if (key_start >= source.len) return null;
    key_start += 1;
    var key_end = offset;
    while (key_end < source.len and source[key_end] != '"' and source[key_end] != '\'') {
        key_end += 1;
    }
    const full_key = source[key_start..key_end];

    const stmt = self.db.prepare(
        \\SELECT value, locale FROM i18n_keys WHERE key = ?
        \\ORDER BY locale LIMIT 10
    ) catch return null;
    defer stmt.finalize();
    stmt.bind_text(1, full_key);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":");

    var found_any = false;
    try w.writeAll("\"**");
    try writeEscapedJsonContent(w, full_key);
    try w.writeAll("**");
    try w.writeAll("\\n\\n");

    while (try stmt.step()) {
        const value = stmt.column_text(0);
        const locale = stmt.column_text(1);
        found_any = true;
        try w.writeAll("_");
        try writeEscapedJsonContent(w, locale);
        try w.writeAll("_: ");
        try writeEscapedJsonContent(w, value);
        try w.writeAll("\\n\\n");
    }

    if (!found_any) {
        try w.writeAll("_(no translations found)_");
    }

    try w.writeAll("\"");
    try w.print("}},\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ hover_line, wc16, hover_line, we16 });

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}
