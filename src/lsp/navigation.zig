const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const types = @import("types.zig");
const db_mod = @import("../db.zig");
const erb_mapping = @import("erb_mapping.zig");
const editing = @import("editing.zig");

const extractTextDocumentUri = S.extractTextDocumentUri;
const extractParamsObject = S.extractParamsObject;
const extractPosition = S.extractPosition;
const uriToPath = S.uriToPath;
const emptyResult = S.emptyResult;
const writeEscapedJsonContent = S.writeEscapedJsonContent;
const writeEscapedJson = S.writeEscapedJson;
const writePathAsUri = S.writePathAsUri;
const getLineSlice = S.getLineSlice;
const extractWord = S.extractWord;
const extractQualifiedName = S.extractQualifiedName;
const extractBaseClass = S.extractBaseClass;
const utf8ColToUtf16 = S.utf8ColToUtf16;
const isInStringOrComment = S.isInStringOrComment;
const frcGet = S.frcGet;
const resolveRequireTarget = S.resolveRequireTarget;
const pathToUri = S.pathToUri;
const isRubyIdent = S.isRubyIdent;
const empty_json_array = S.empty_json_array;

pub fn handleDefinition(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
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
        const target_uri = pathToUri(self.alloc, target_path) catch return emptyResult(msg);
        defer self.alloc.free(target_uri);
        var req_aw = std.Io.Writer.Allocating.init(self.alloc);
        const rw = &req_aw.writer;
        if (self.client_caps_def_link) {
            // Scan for the enclosing quote characters to build originSelectionRange
            var qs = offset;
            while (qs > 0 and source[qs - 1] != '"' and source[qs - 1] != '\'' and source[qs - 1] != '\n') qs -= 1;
            if (qs > 0) qs -= 1; // include the opening quote
            var qe = offset;
            while (qe < source.len and source[qe] != '"' and source[qe] != '\'' and source[qe] != '\n') qe += 1;
            if (qe < source.len and (source[qe] == '"' or source[qe] == '\'')) qe += 1; // include closing quote
            const origin_sc = self.offsetToClientChar(source, qs, line);
            const origin_ec = self.offsetToClientChar(source, qe, line);
            try rw.print(
                "[{{\"targetUri\":\"{s}\",\"targetRange\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}},\"targetSelectionRange\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}},\"originSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}]",
                .{ target_uri, line, origin_sc, line, origin_ec },
            );
        } else {
            try rw.print("[{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}}}}]", .{target_uri});
        }
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try req_aw.toOwnedSlice(), .@"error" = null };
    }

    const word = extractWord(source, offset);
    if (word.len == 0) return emptyResult(msg);

    // Compute origin selection range for LocationLink support
    const word_start_offset = @intFromPtr(word.ptr) - @intFromPtr(source.ptr);
    const origin_char = self.offsetToClientChar(source, word_start_offset, line);
    const origin_end_char = self.offsetToClientChar(source, word_start_offset + word.len, line);
    const def_origin = DefOrigin{ .line = line, .start_char = origin_char, .end_char = origin_end_char };

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');
    var found_any = false;
    var frc_def: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var frc_it = frc_def.iterator();
        while (frc_it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        frc_def.deinit(self.alloc);
    }

    try queryAndEmitDefinitions(self, w, word, &found_any, &frc_def, def_origin);

    if (!found_any) {
        const qualified = extractQualifiedName(source, offset);
        if (!std.mem.eql(u8, qualified, word)) {
            try queryAndEmitDefinitions(self, w, qualified, &found_any, &frc_def, def_origin);
        }
    }

    if (!found_any) {
        const cursor_line: i64 = @intCast(line + 1);

        var def_word_start: usize = offset;
        while (def_word_start > 0 and isRubyIdent(source[def_word_start - 1])) def_word_start -= 1;
        var def_line_start: usize = 0;
        var dj: usize = 0;
        while (dj < def_word_start) : (dj += 1) {
            if (source[dj] == '\n') def_line_start = dj + 1;
        }
        const def_col_0: i64 = @intCast(def_word_start - def_line_start);

        const f_stmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
        defer f_stmt.finalize();
        f_stmt.bind_text(1, path);
        if (try f_stmt.step()) {
            const fid = f_stmt.column_int(0);
            const scope_opt = editing.resolveScopeId(self, fid, word, cursor_line, def_col_0);
            const lv_stmt = if (scope_opt) |sid| blk: {
                if (sid != 0) {
                    const s = try self.db.prepare(
                        \\SELECT name, line, col FROM local_vars
                        \\WHERE file_id=? AND name=? AND scope_id=?
                        \\ORDER BY line DESC LIMIT 1
                    );
                    s.bind_int(1, fid);
                    s.bind_text(2, word);
                    s.bind_int(3, sid);
                    break :blk s;
                } else {
                    const s = try self.db.prepare(
                        \\SELECT name, line, col FROM local_vars
                        \\WHERE file_id=? AND name=? AND scope_id IS NULL
                        \\ORDER BY line DESC LIMIT 1
                    );
                    s.bind_int(1, fid);
                    s.bind_text(2, word);
                    break :blk s;
                }
            } else blk: {
                const s = try self.db.prepare(
                    \\SELECT name, line, col FROM local_vars
                    \\WHERE file_id = ? AND name = ? AND line <= ?
                    \\ORDER BY line DESC LIMIT 1
                );
                s.bind_int(1, fid);
                s.bind_text(2, word);
                s.bind_int(3, cursor_line);
                break :blk s;
            };
            defer lv_stmt.finalize();
            if (try lv_stmt.step()) {
                const lv_name = lv_stmt.column_text(0);
                const lv_line = lv_stmt.column_int(1);
                const lv_col = lv_stmt.column_int(2);
                const lv_line_src = getLineSlice(source, @intCast(lv_line - 1));
                const lv_start = self.toClientCol(lv_line_src, @intCast(lv_col));
                try w.writeAll("{\"uri\":\"file://");
                try writePathAsUri(w, path);
                try w.writeAll("\",\"range\":{\"start\":{\"line\":");
                try w.print("{d}", .{lv_line - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{lv_start});
                try w.writeAll("},\"end\":{\"line\":");
                try w.print("{d}", .{lv_line - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{lv_start + @as(u32, @intCast(lv_name.len))});
                try w.writeAll("}}}");
            }
        }
    }

    try w.writeByte(']');

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn handleImplementation(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    self.flushDirtyUris();
    if (self.isCancelled(msg.id)) return null;
    self.db_mutex.lock();
    defer self.db_mutex.unlock();
    const uri = extractTextDocumentUri(msg.params) orelse return emptyResult(msg);
    const pos = extractPosition(msg.params) orelse return emptyResult(msg);
    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);
    if (!self.pathInBounds(path)) return emptyResult(msg);
    const source = self.readSourceForUri(uri, path) catch return emptyResult(msg);
    defer self.alloc.free(source);
    const offset = self.clientPosToOffset(source, pos.line, pos.character);
    const word = extractWord(source, offset);
    if (word.len == 0) return emptyResult(msg);

    // Find the parent class of the method at cursor to identify its context
    var parent_name: []const u8 = "";
    {
        const ctx_stmt = self.db.prepare(
            \\SELECT s.parent_name FROM symbols s
            \\JOIN files f ON f.id = s.file_id
            \\WHERE f.path = ? AND s.name = ? AND s.kind IN ('def','classdef')
            \\LIMIT 1
        ) catch return emptyResult(msg);
        defer ctx_stmt.finalize();
        ctx_stmt.bind_text(1, path);
        ctx_stmt.bind_text(2, word);
        if (ctx_stmt.step() catch false) {
            parent_name = ctx_stmt.column_text(0);
        }
    }

    // Find all overriding implementations: same method name in subclasses or includers
    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');
    var first = true;

    const impl_stmt = self.db.prepare(
        \\SELECT s.name, s.line, s.col, f.path, s.parent_name
        \\FROM symbols s JOIN files f ON f.id = s.file_id
        \\WHERE s.name = ? AND s.kind IN ('def','classdef') AND s.parent_name != ?
        \\LIMIT 50
    ) catch {
        try w.writeByte(']');
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    };
    defer impl_stmt.finalize();
    impl_stmt.bind_text(1, word);
    impl_stmt.bind_text(2, if (parent_name.len > 0) parent_name else "\x00");

    var frc_impl: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var frc_it = frc_impl.iterator();
        while (frc_it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        frc_impl.deinit(self.alloc);
    }

    while (impl_stmt.step() catch false) {
        if (!first) try w.writeByte(',');
        first = false;
        const sym_name = impl_stmt.column_text(0);
        const sym_line = impl_stmt.column_int(1);
        const sym_col = impl_stmt.column_int(2);
        const sym_path = impl_stmt.column_text(3);
        const start_char = self.toClientColFromPath(&frc_impl, sym_path, sym_line - 1, sym_col);
        try w.writeAll("{\"uri\":\"file://");
        try writePathAsUri(w, sym_path);
        try w.writeAll("\",\"range\":{\"start\":{\"line\":");
        try w.print("{d}", .{sym_line - 1});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{start_char});
        try w.writeAll("},\"end\":{\"line\":");
        try w.print("{d}", .{sym_line - 1});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{start_char + @as(u32, @intCast(sym_name.len))});
        try w.writeAll("}}}");
    }

    try w.writeByte(']');
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}

pub fn handleReferences(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
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

    const word = extractWord(source, offset);
    if (word.len == 0) return emptyResult(msg);

    const cursor_line_1based: i64 = @intCast(line + 1);
    var ref_word_start: usize = offset;
    while (ref_word_start > 0 and isRubyIdent(source[ref_word_start - 1])) ref_word_start -= 1;
    var ref_line_start: usize = 0;
    var ri: usize = 0;
    while (ri < ref_word_start) : (ri += 1) {
        if (source[ri] == '\n') ref_line_start = ri + 1;
    }
    const ref_col_0: i64 = @intCast(ref_word_start - ref_line_start);

    // Check if cursor is on a local variable; if so, scope the query
    const file_stmt_ref = try self.db.prepare("SELECT id FROM files WHERE path = ?");
    defer file_stmt_ref.finalize();
    file_stmt_ref.bind_text(1, path);
    var ref_scope_id: ?i64 = null;
    var is_local_ref = false;
    if (try file_stmt_ref.step()) {
        const fid = file_stmt_ref.column_int(0);
        if (editing.resolveScopeId(self, fid, word, cursor_line_1based, ref_col_0)) |sid| {
            is_local_ref = true;
            ref_scope_id = if (sid != 0) sid else null;
        }
    }

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');
    var first = true;
    var frc_ref: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var frc_it = frc_ref.iterator();
        while (frc_it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        frc_ref.deinit(self.alloc);
    }

    if (is_local_ref) {
        if (ref_scope_id) |sid| {
            // Scoped: emit local_var writes + scoped refs for this scope only
            const lv_stmt = try self.db.prepare(
                \\SELECT f.path, lv.line, lv.col FROM local_vars lv JOIN files f ON lv.file_id=f.id
                \\WHERE lv.name=? AND lv.scope_id=?
            );
            defer lv_stmt.finalize();
            lv_stmt.bind_text(1, word);
            lv_stmt.bind_int(2, sid);
            while (try lv_stmt.step()) {
                if (!first) try w.writeByte(',');
                first = false;
                const rp = lv_stmt.column_text(0);
                const rl = lv_stmt.column_int(1);
                const rc = lv_stmt.column_int(2);
                const rc_client = self.toClientColFromPath(&frc_ref, rp, rl - 1, rc);
                try w.writeAll("{\"uri\":\"file://");
                try writePathAsUri(w, rp);
                try w.writeAll("\",\"range\":{\"start\":{\"line\":");
                try w.print("{d}", .{rl - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{rc_client});
                try w.writeAll("},\"end\":{\"line\":");
                try w.print("{d}", .{rl - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{rc_client + @as(u32, @intCast(word.len))});
                try w.writeAll("}}}");
            }
            const scoped_ref = try self.db.prepare(
                \\SELECT f.path, r.line, r.col FROM refs r JOIN files f ON r.file_id=f.id
                \\WHERE r.name=? AND r.scope_id=?
            );
            defer scoped_ref.finalize();
            scoped_ref.bind_text(1, word);
            scoped_ref.bind_int(2, sid);
            while (try scoped_ref.step()) {
                if (!first) try w.writeByte(',');
                first = false;
                const rp = scoped_ref.column_text(0);
                const rl = scoped_ref.column_int(1);
                const rc = scoped_ref.column_int(2);
                const rc_client = self.toClientColFromPath(&frc_ref, rp, rl - 1, rc);
                try w.writeAll("{\"uri\":\"file://");
                try writePathAsUri(w, rp);
                try w.writeAll("\",\"range\":{\"start\":{\"line\":");
                try w.print("{d}", .{rl - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{rc_client});
                try w.writeAll("},\"end\":{\"line\":");
                try w.print("{d}", .{rl - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{rc_client + @as(u32, @intCast(word.len))});
                try w.writeAll("}}}");
            }
        }
        // else top-level local — no cross-file refs, return empty
    } else {
        // Global: all refs across all files
        const stmt = try self.db.prepare(
            \\SELECT f.path, r.line, r.col
            \\FROM refs r JOIN files f ON r.file_id = f.id
            \\WHERE r.name = ?
        );
        defer stmt.finalize();
        stmt.bind_text(1, word);
        while (try stmt.step()) {
            if (!first) try w.writeByte(',');
            first = false;
            const ref_path = stmt.column_text(0);
            const ref_line = stmt.column_int(1);
            const ref_col = stmt.column_int(2);
            const ref_col_client = self.toClientColFromPath(&frc_ref, ref_path, ref_line - 1, ref_col);
            try w.writeAll("{\"uri\":\"file://");
            try writePathAsUri(w, ref_path);
            try w.writeAll("\",\"range\":{\"start\":{\"line\":");
            try w.print("{d}", .{ref_line - 1});
            try w.writeAll(",\"character\":");
            try w.print("{d}", .{ref_col_client});
            try w.writeAll("},\"end\":{\"line\":");
            try w.print("{d}", .{ref_line - 1});
            try w.writeAll(",\"character\":");
            try w.print("{d}", .{ref_col_client + @as(u32, @intCast(word.len))});
            try w.writeAll("}}}");
        }
    }
    try w.writeByte(']');

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn handleTypeDefinition(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    self.db_mutex.lock();
    defer self.db_mutex.unlock();
    const params = msg.params orelse return emptyResult(msg);
    const obj = switch (params) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const td_val = obj.get("textDocument") orelse return emptyResult(msg);
    const td = switch (td_val) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const uri_val = td.get("uri") orelse return emptyResult(msg);
    const uri = switch (uri_val) {
        .string => |s| s,
        else => return emptyResult(msg),
    };
    const pos_val = obj.get("position") orelse return emptyResult(msg);
    const pos = switch (pos_val) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const line_val = pos.get("line") orelse return emptyResult(msg);
    const line: u32 = switch (line_val) {
        .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
        else => return emptyResult(msg),
    };
    const char_val = pos.get("character") orelse return emptyResult(msg);
    const character: u32 = switch (char_val) {
        .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
        else => return emptyResult(msg),
    };

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);
    const source = self.readSourceForUri(uri, path) catch
        return emptyResult(msg);
    defer self.alloc.free(source);

    const offset = self.clientPosToOffset(source, line, character);
    const word = extractWord(source, offset);
    if (word.len == 0) return emptyResult(msg);

    const cursor_line: i64 = @intCast(line + 1); // 1-based for DB

    // Check local_vars for type_hint
    const file_stmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
    defer file_stmt.finalize();
    file_stmt.bind_text(1, path);
    if (!(try file_stmt.step())) return emptyResult(msg);
    const file_id = file_stmt.column_int(0);

    var type_name: ?[]const u8 = null;

    const lv_stmt = try self.db.prepare(
        \\SELECT type_hint FROM local_vars
        \\WHERE file_id = ? AND name = ? AND line <= ? AND type_hint IS NOT NULL
        \\ORDER BY line DESC LIMIT 1
    );
    defer lv_stmt.finalize();
    lv_stmt.bind_int(1, file_id);
    lv_stmt.bind_text(2, word);
    lv_stmt.bind_int(3, cursor_line);
    if (try lv_stmt.step()) {
        type_name = lv_stmt.column_text(0);
    }

    // If no local var, check if word is itself a class/module
    if (type_name == null) {
        type_name = word;
    }

    const tn = type_name.?;

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');
    var found_any = false;
    var frc_td: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var frc_it = frc_td.iterator();
        while (frc_it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        frc_td.deinit(self.alloc);
    }

    const sym_stmt = try self.db.prepare(
        \\SELECT s.name, s.line, s.col, f.path
        \\FROM symbols s JOIN files f ON s.file_id = f.id
        \\WHERE s.name = ? AND s.kind IN ('class', 'module') LIMIT 5
    );
    defer sym_stmt.finalize();
    sym_stmt.bind_text(1, tn);
    while (try sym_stmt.step()) {
        if (found_any) try w.writeByte(',');
        found_any = true;
        const sym_name = sym_stmt.column_text(0);
        const sym_line = sym_stmt.column_int(1);
        const sym_col = sym_stmt.column_int(2);
        const sym_path = sym_stmt.column_text(3);
        const start_char = self.toClientColFromPath(&frc_td, sym_path, sym_line - 1, sym_col);
        try w.writeAll("{\"uri\":\"file://");
        try writePathAsUri(w, sym_path);
        try w.writeAll("\",\"range\":{\"start\":{\"line\":");
        try w.print("{d}", .{sym_line - 1});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{start_char});
        try w.writeAll("},\"end\":{\"line\":");
        try w.print("{d}", .{sym_line - 1});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{start_char + @as(u32, @intCast(sym_name.len))});
        try w.writeAll("}}}");
    }
    try w.writeByte(']');

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}

pub const DefOrigin = struct {
    line: u32,
    start_char: u32,
    end_char: u32,
};

pub fn queryAndEmitDefinitions(self: *Server, w: *std.Io.Writer, name: []const u8, found_any: *bool, frc: *std.StringHashMapUnmanaged([]const u8), origin: ?DefOrigin) !void {
    const stmt = try self.db.prepare(
        \\SELECT s.name, s.line, s.col, f.path
        \\FROM symbols s JOIN files f ON s.file_id = f.id
        \\WHERE s.name = ?
        \\UNION
        \\SELECT s2.name, s2.line, s2.col, f2.path
        \\FROM symbols s2 JOIN files f2 ON s2.file_id = f2.id
        \\JOIN mixins m ON s2.file_id IN (
        \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=m.module_name
        \\)
        \\WHERE s2.name = ? AND s2.kind = 'def'
        \\LIMIT 10
    );
    defer stmt.finalize();
    stmt.bind_text(1, name);
    stmt.bind_text(2, name);
    while (try stmt.step()) {
        if (found_any.*) try w.writeByte(',');
        found_any.* = true;
        const sym_name = stmt.column_text(0);
        const sym_line = stmt.column_int(1);
        const sym_col = stmt.column_int(2);
        const sym_path = stmt.column_text(3);
        const start_char = self.toClientColFromPath(frc, sym_path, sym_line - 1, sym_col);
        if (self.client_caps_def_link) {
            // LocationLink format (LSP 3.14+)
            try w.writeAll("{\"targetUri\":\"file://");
            try writePathAsUri(w, sym_path);
            try w.print("\",\"targetRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                sym_line - 1, start_char, sym_line - 1, start_char + @as(u32, @intCast(sym_name.len)),
            });
            try w.print(",\"targetSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                sym_line - 1, start_char, sym_line - 1, start_char + @as(u32, @intCast(sym_name.len)),
            });
            if (origin) |orig| {
                try w.print(",\"originSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                    orig.line, orig.start_char, orig.line, orig.end_char,
                });
            }
            try w.writeByte('}');
        } else {
            // Location format (legacy)
            try w.writeAll("{\"uri\":\"file://");
            try writePathAsUri(w, sym_path);
            try w.writeAll("\",\"range\":{\"start\":{\"line\":");
            try w.print("{d}", .{sym_line - 1});
            try w.writeAll(",\"character\":");
            try w.print("{d}", .{start_char});
            try w.writeAll("},\"end\":{\"line\":");
            try w.print("{d}", .{sym_line - 1});
            try w.writeAll(",\"character\":");
            try w.print("{d}", .{start_char + @as(u32, @intCast(sym_name.len))});
            try w.writeAll("}}}");
        }
    }
}

pub fn handlePrepareTypeHierarchy(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    self.db_mutex.lock();
    defer self.db_mutex.unlock();
    const params = msg.params orelse return emptyResult(msg);
    const obj = switch (params) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const td = switch (obj.get("textDocument") orelse return emptyResult(msg)) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const uri = switch (td.get("uri") orelse return emptyResult(msg)) {
        .string => |s| s,
        else => return emptyResult(msg),
    };
    const pos_val = obj.get("position") orelse return emptyResult(msg);
    const pos = switch (pos_val) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const line: u32 = switch (pos.get("line") orelse return emptyResult(msg)) {
        .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
        else => return emptyResult(msg),
    };
    const character: u32 = switch (pos.get("character") orelse return emptyResult(msg)) {
        .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
        else => return emptyResult(msg),
    };

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);
    if (!self.pathInBounds(path)) return emptyResult(msg);
    const source = self.readSourceForUri(uri, path) catch return emptyResult(msg);
    defer self.alloc.free(source);
    const offset = self.clientPosToOffset(source, line, character);
    const word = extractWord(source, offset);
    if (word.len == 0) return emptyResult(msg);

    const stmt = try self.db.prepare("SELECT s.id, s.name, s.kind, s.line, s.col, f.path FROM symbols s JOIN files f ON s.file_id=f.id WHERE s.name=? AND s.kind IN ('class','module','classdef') LIMIT 1");
    defer stmt.finalize();
    stmt.bind_text(1, word);
    if (!(try stmt.step())) return emptyResult(msg);
    const sym_id = stmt.column_int(0);
    const sym_name = stmt.column_text(1);
    const sym_kind = stmt.column_text(2);
    const sym_line = stmt.column_int(3);
    const sym_col = stmt.column_int(4);
    const sym_path = stmt.column_text(5);
    const kind_num: u8 = if (std.mem.eql(u8, sym_kind, "class")) 5 else 2;
    var frc_pth: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var frc_it = frc_pth.iterator();
        while (frc_it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        frc_pth.deinit(self.alloc);
    }
    const sym_col_client = self.toClientColFromPath(&frc_pth, sym_path, sym_line - 1, sym_col);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');
    try w.writeAll("{\"name\":");
    try writeEscapedJson(w, sym_name);
    try w.print(",\"kind\":{d},\"uri\":\"file://", .{kind_num});
    try writePathAsUri(w, sym_path);
    try w.print("\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"data\":{{\"symbol_id\":{d}}}}}", .{
        sym_line - 1, sym_col_client, sym_line - 1, sym_col_client + @as(u32, @intCast(sym_name.len)),
        sym_line - 1, sym_col_client, sym_line - 1, sym_col_client + @as(u32, @intCast(sym_name.len)),
        sym_id,
    });
    try w.writeByte(']');
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}

pub fn handleTypeHierarchySupertypes(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    self.db_mutex.lock();
    defer self.db_mutex.unlock();
    const params = msg.params orelse return emptyResult(msg);
    const obj = switch (params) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const item = switch (obj.get("item") orelse return emptyResult(msg)) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const name_val = item.get("name") orelse return emptyResult(msg);
    const class_name = switch (name_val) {
        .string => |s| s,
        else => return emptyResult(msg),
    };

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');
    var first = true;

    const mro_stmt = self.db.prepare(
        \\WITH RECURSIVE mro(name, depth) AS (
        \\  SELECT parent_name, 1 FROM symbols WHERE name=? AND kind IN ('class','module')
        \\  UNION ALL
        \\  SELECT s.parent_name, m.depth+1 FROM mro m
        \\  JOIN symbols s ON s.name=m.name AND s.kind IN ('class','module')
        \\  WHERE m.depth < 8
        \\) SELECT DISTINCT name FROM mro WHERE name IS NOT NULL
    ) catch {
        try w.writeByte(']');
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    };
    defer mro_stmt.finalize();
    mro_stmt.bind_text(1, class_name);

    var seen_arena = std.heap.ArenaAllocator.init(self.alloc);
    defer seen_arena.deinit();
    var seen_parents = std.StringHashMap(void).init(seen_arena.allocator());

    while (mro_stmt.step() catch false) {
        const parent_name_raw = mro_stmt.column_text(0);
        if (parent_name_raw.len == 0 or seen_parents.contains(parent_name_raw)) continue;
        try seen_parents.put(seen_arena.allocator().dupe(u8, parent_name_raw) catch continue, {});

        const sym_stmt = self.db.prepare("SELECT s.id, s.name, s.kind, s.line, s.col, f.path FROM symbols s JOIN files f ON s.file_id=f.id WHERE s.name=? AND s.kind IN ('class','module') LIMIT 1") catch continue;
        defer sym_stmt.finalize();
        sym_stmt.bind_text(1, parent_name_raw);
        if (!(sym_stmt.step() catch false)) {
            // Parent exists in DB but no file — emit minimal item
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"name\":");
            try writeEscapedJson(w, parent_name_raw);
            try w.writeAll(",\"kind\":5,\"uri\":\"\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}}}");
            continue;
        }
        const sym_id = sym_stmt.column_int(0);
        const sym_name = sym_stmt.column_text(1);
        const sym_kind = sym_stmt.column_text(2);
        const sym_line = sym_stmt.column_int(3);
        const sym_col = sym_stmt.column_int(4);
        const sym_path = sym_stmt.column_text(5);
        const kind_num: u8 = if (std.mem.eql(u8, sym_kind, "class")) 5 else 2;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"name\":");
        try writeEscapedJson(w, sym_name);
        try w.print(",\"kind\":{d},\"uri\":\"file://", .{kind_num});
        try writePathAsUri(w, sym_path);
        try w.print("\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"data\":{{\"symbol_id\":{d}}}}}", .{
            sym_line - 1, sym_col, sym_line - 1, sym_col + @as(i64, @intCast(sym_name.len)),
            sym_line - 1, sym_col, sym_line - 1, sym_col + @as(i64, @intCast(sym_name.len)),
            sym_id,
        });
    }
    // Also include mixins as supertypes
    const mix_stmt = self.db.prepare("SELECT m.module_name FROM mixins m JOIN symbols s ON m.class_id=s.id WHERE s.name=?") catch {
        try w.writeByte(']');
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    };
    defer mix_stmt.finalize();
    mix_stmt.bind_text(1, class_name);
    while (mix_stmt.step() catch false) {
        const mod_name = mix_stmt.column_text(0);
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"name\":");
        try writeEscapedJson(w, mod_name);
        try w.writeAll(",\"kind\":2,\"uri\":\"\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}}}");
    }
    try w.writeByte(']');
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}

pub fn handleTypeHierarchySubtypes(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    self.db_mutex.lock();
    defer self.db_mutex.unlock();
    const params = msg.params orelse return emptyResult(msg);
    const obj = switch (params) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const item = switch (obj.get("item") orelse return emptyResult(msg)) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const name_val = item.get("name") orelse return emptyResult(msg);
    const class_name = switch (name_val) {
        .string => |s| s,
        else => return emptyResult(msg),
    };

    const stmt = try self.db.prepare("SELECT s.id, s.name, s.kind, s.line, s.col, f.path FROM symbols s JOIN files f ON s.file_id=f.id WHERE s.parent_name=? AND s.kind='class' LIMIT 50");
    defer stmt.finalize();
    stmt.bind_text(1, class_name);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');
    var first = true;
    while (try stmt.step()) {
        const sym_id = stmt.column_int(0);
        const sym_name = stmt.column_text(1);
        const sym_line = stmt.column_int(3);
        const sym_col = stmt.column_int(4);
        const sym_path = stmt.column_text(5);
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"name\":");
        try writeEscapedJson(w, sym_name);
        try w.writeAll(",\"kind\":5,\"uri\":\"file://");
        try writePathAsUri(w, sym_path);
        try w.print("\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"data\":{{\"symbol_id\":{d}}}}}", .{
            sym_line - 1, sym_col, sym_line - 1, sym_col + @as(i64, @intCast(sym_name.len)),
            sym_line - 1, sym_col, sym_line - 1, sym_col + @as(i64, @intCast(sym_name.len)),
            sym_id,
        });
    }
    try w.writeByte(']');
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}

pub fn handleCallHierarchyPrepare(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    self.db_mutex.lock();
    defer self.db_mutex.unlock();
    const params = msg.params orelse return emptyResult(msg);
    const obj = switch (params) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const td_val = obj.get("textDocument") orelse return emptyResult(msg);
    const td = switch (td_val) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const uri_val = td.get("uri") orelse return emptyResult(msg);
    const uri = switch (uri_val) {
        .string => |s| s,
        else => return emptyResult(msg),
    };
    const pos_val = obj.get("position") orelse return emptyResult(msg);
    const pos = switch (pos_val) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const line_val = pos.get("line") orelse return emptyResult(msg);
    const line: u32 = switch (line_val) {
        .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
        else => return emptyResult(msg),
    };
    const char_val = pos.get("character") orelse return emptyResult(msg);
    const character: u32 = switch (char_val) {
        .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
        else => return emptyResult(msg),
    };

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);
    if (!self.pathInBounds(path)) return emptyResult(msg);
    const source = self.readSourceForUri(uri, path) catch
        return emptyResult(msg);
    defer self.alloc.free(source);

    const offset = self.clientPosToOffset(source, line, character);
    const word = extractWord(source, offset);
    if (word.len == 0) return emptyResult(msg);

    const stmt = try self.db.prepare(
        \\SELECT s.name, s.kind, s.line, s.col, f.path
        \\FROM symbols s JOIN files f ON s.file_id=f.id
        \\WHERE s.name=? LIMIT 1
    );
    defer stmt.finalize();
    stmt.bind_text(1, word);
    if (!(try stmt.step())) return emptyResult(msg);

    const sym_name = stmt.column_text(0);
    const sym_kind = stmt.column_text(1);
    const sym_line = stmt.column_int(2);
    const sym_col = stmt.column_int(3);
    const sym_path = stmt.column_text(4);

    const kind_num: u8 = if (std.mem.eql(u8, sym_kind, "class")) 5 else if (std.mem.eql(u8, sym_kind, "module")) 2 else 6;
    var frc_chp: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var frc_it = frc_chp.iterator();
        while (frc_it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        frc_chp.deinit(self.alloc);
    }
    const sym_col_client = self.toClientColFromPath(&frc_chp, sym_path, sym_line - 1, sym_col);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeAll("[{\"name\":");
    try writeEscapedJson(w, sym_name);
    try w.print(",\"kind\":{d},\"uri\":\"file://", .{kind_num});
    try writePathAsUri(w, sym_path);
    try w.print("\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
        sym_line - 1, sym_col_client, sym_line - 1, sym_col_client + @as(u32, @intCast(sym_name.len)),
    });
    try w.print(",\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
        sym_line - 1, sym_col_client, sym_line - 1, sym_col_client + @as(u32, @intCast(sym_name.len)),
    });
    try w.writeAll("}]");

    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}

pub fn handleCallHierarchyIncomingCalls(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    self.db_mutex.lock();
    defer self.db_mutex.unlock();
    const params = msg.params orelse return emptyResult(msg);
    const obj = switch (params) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const item_val = obj.get("item") orelse return emptyResult(msg);
    const item = switch (item_val) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const name_val = item.get("name") orelse return emptyResult(msg);
    const name = switch (name_val) {
        .string => |s| s,
        else => return emptyResult(msg),
    };

    const ref_stmt = try self.db.prepare(
        \\SELECT r.line, r.col, f.path FROM refs r JOIN files f ON r.file_id=f.id
        \\WHERE r.name=? ORDER BY f.path, r.line LIMIT 100
    );
    defer ref_stmt.finalize();
    ref_stmt.bind_text(1, name);

    // Enclosing-method lookup: given (path, line), find innermost def/classdef/test
    const enc_stmt = self.db.prepare(
        \\SELECT s.name, s.kind FROM symbols s JOIN files f ON s.file_id=f.id
        \\WHERE f.path=? AND s.kind IN ('def','classdef','test') AND s.line<=?
        \\ORDER BY s.line DESC LIMIT 1
    ) catch null;
    defer if (enc_stmt) |es| es.finalize();

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    var frc_chi: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var frc_it = frc_chi.iterator();
        while (frc_it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        frc_chi.deinit(self.alloc);
    }
    try w.writeAll("[");
    var first = true;
    while (try ref_stmt.step()) {
        const ref_line = ref_stmt.column_int(0);
        const ref_col = ref_stmt.column_int(1);
        const ref_path = ref_stmt.column_text(2);
        const ref_col_client = self.toClientColFromPath(&frc_chi, ref_path, ref_line - 1, ref_col);
        // Resolve the enclosing method name; fall back to file basename
        var from_name_buf: [256]u8 = undefined;
        var from_name: []const u8 = std.fs.path.basename(ref_path);
        var from_kind: u32 = 1; // File fallback
        if (enc_stmt) |es| {
            es.reset();
            es.bind_text(1, ref_path);
            es.bind_int(2, ref_line);
            if (es.step() catch false) {
                const enc_name = es.column_text(0);
                const enc_kind_str = es.column_text(1);
                if (enc_name.len > 0 and enc_name.len <= from_name_buf.len) {
                    @memcpy(from_name_buf[0..enc_name.len], enc_name);
                    from_name = from_name_buf[0..enc_name.len];
                }
                from_kind = if (std.mem.eql(u8, enc_kind_str, "classdef")) 5 else 6;
            }
        }
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"from\":{\"name\":");
        try writeEscapedJson(w, from_name);
        try w.print(",\"kind\":{d},\"uri\":\"file://", .{from_kind});
        try writePathAsUri(w, ref_path);
        try w.print("\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
            ref_line - 1, ref_col_client, ref_line - 1, ref_col_client,
        });
        try w.print(",\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
            ref_line - 1, ref_col_client, ref_line - 1, ref_col_client,
        });
        try w.print("}},\"fromRanges\":[{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}]}}", .{
            ref_line - 1, ref_col_client, ref_line - 1, ref_col_client + @as(u32, @intCast(name.len)),
        });
    }
    try w.writeAll("]");

    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}

pub fn handleCallHierarchyOutgoingCalls(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    const RefPos = struct { line: i64, col: i64 };
    self.db_mutex.lock();
    defer self.db_mutex.unlock();
    const params = msg.params orelse return emptyResult(msg);
    const obj = switch (params) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const item_val = obj.get("item") orelse return emptyResult(msg);
    const item = switch (item_val) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const uri_val = item.get("uri") orelse return emptyResult(msg);
    const uri = switch (uri_val) {
        .string => |s| s,
        else => return emptyResult(msg),
    };
    const range_val = item.get("range") orelse return emptyResult(msg);
    const range = switch (range_val) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const start_val = range.get("start") orelse return emptyResult(msg);
    const start_obj = switch (start_val) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const start_line_val = start_obj.get("line") orelse return emptyResult(msg);
    const start_line: i64 = switch (start_line_val) {
        .integer => |i| i,
        else => return emptyResult(msg),
    };
    const end_val = range.get("end") orelse return emptyResult(msg);
    const end_obj = switch (end_val) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const end_line_val = end_obj.get("line") orelse return emptyResult(msg);
    const end_line: i64 = switch (end_line_val) {
        .integer => |i| i,
        else => return emptyResult(msg),
    };

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);

    const fid_stmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
    defer fid_stmt.finalize();
    fid_stmt.bind_text(1, path);
    if (!(try fid_stmt.step())) {
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try self.alloc.dupe(u8, empty_json_array), .@"error" = null };
    }
    const file_id = fid_stmt.column_int(0);

    const db_start_line: i64 = start_line + 1;
    const db_end_line: i64 = end_line + 1;

    const ref_stmt = try self.db.prepare(
        \\SELECT DISTINCT r.name, r.line, r.col FROM refs r
        \\WHERE r.file_id = ? AND r.line BETWEEN ? AND ?
    );
    defer ref_stmt.finalize();
    ref_stmt.bind_int(1, file_id);
    ref_stmt.bind_int(2, db_start_line);
    ref_stmt.bind_int(3, db_end_line);

    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var ref_names = std.StringHashMap(std.ArrayList(RefPos)).init(a);

    while (try ref_stmt.step()) {
        const ref_name = ref_stmt.column_text(0);
        const ref_line = ref_stmt.column_int(1);
        const ref_col = ref_stmt.column_int(2);
        const gop = try ref_names.getOrPut(ref_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(RefPos){};
        }
        try gop.value_ptr.append(a, .{ .line = ref_line, .col = ref_col });
    }

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeAll("[");
    var first = true;

    var iter = ref_names.iterator();
    while (iter.next()) |entry| {
        const ref_name = entry.key_ptr.*;
        const ref_positions = entry.value_ptr.*;

        const def_stmt = try self.db.prepare(
            \\SELECT s.name, s.line, s.col, f.path FROM symbols s JOIN files f ON s.file_id=f.id
            \\WHERE s.name = ? AND s.kind = 'def' LIMIT 1
        );
        defer def_stmt.finalize();
        def_stmt.bind_text(1, ref_name);
        if (!(try def_stmt.step())) continue;

        const def_name = def_stmt.column_text(0);
        const def_line = def_stmt.column_int(1);
        const def_col = def_stmt.column_int(2);
        const def_path = def_stmt.column_text(3);

        if (!first) try w.writeByte(',');
        first = false;

        try w.writeAll("{\"to\":{\"name\":");
        try writeEscapedJson(w, def_name);
        try w.print(",\"kind\":12,\"uri\":\"file://", .{});
        try writePathAsUri(w, def_path);
        try w.print("\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
            def_line - 1, def_col, def_line - 1, def_col,
        });
        try w.print(",\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{
            def_line - 1, def_col, def_line - 1, def_col + @as(i64, @intCast(def_name.len)),
        });
        try w.writeAll("},\"fromRanges\":[");
        for (ref_positions.items, 0..) |pos, idx| {
            if (idx > 0) try w.writeByte(',');
            try w.print("{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                pos.line - 1, pos.col, pos.line - 1, pos.col + @as(i64, @intCast(ref_name.len)),
            });
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");

    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}
