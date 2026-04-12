const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const types = @import("types.zig");
const db_mod = @import("../db.zig");
const editing = @import("editing.zig");

const uriToPath = S.uriToPath;
const emptyResult = S.emptyResult;
const writeEscapedJson = S.writeEscapedJson;
const writeEscapedJsonContent = S.writeEscapedJsonContent;
const writePathAsUri = S.writePathAsUri;
const extractWord = S.extractWord;
const getLineSlice = S.getLineSlice;
const isRubyIdent = S.isRubyIdent;
const isValidRubyIdent = S.isValidRubyIdent;

pub fn handlePrepareRename(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
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

    var word_start = offset;
    while (word_start > 0 and isRubyIdent(source[word_start - 1])) word_start -= 1;

    var line_start: usize = 0;
    var j: usize = 0;
    while (j < word_start) : (j += 1) {
        if (source[j] == '\n') line_start = j + 1;
    }
    const word_col: usize = word_start - line_start;
    const word_line_src = getLineSlice(source, line);
    const word_col_client = self.toClientCol(word_line_src, word_col);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeAll("{\"range\":{\"start\":{\"line\":");
    try w.print("{d}", .{line});
    try w.writeAll(",\"character\":");
    try w.print("{d}", .{word_col_client});
    try w.writeAll("},\"end\":{\"line\":");
    try w.print("{d}", .{line});
    try w.writeAll(",\"character\":");
    try w.print("{d}", .{word_col_client + @as(u32, @intCast(word.len))});
    try w.writeAll("}},\"placeholder\":\"");
    for (word) |wc| {
        if (wc == '"' or wc == '\\') try w.writeByte('\\');
        try w.writeByte(wc);
    }
    try w.writeAll("\"}");

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn handleRename(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
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
    const new_name_val = obj.get("newName") orelse return emptyResult(msg);
    const new_name = switch (new_name_val) {
        .string => |s| s,
        else => return emptyResult(msg),
    };

    if (!isValidRubyIdent(new_name)) {
        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .@"error" = .{ .code = -32602, .message = "Invalid Ruby identifier" },
        };
    }

    const path_for_conflict = uriToPath(self.alloc, uri) catch null;
    defer if (path_for_conflict) |p| self.alloc.free(p);
    if (path_for_conflict) |pfc| {
        if (self.db.prepare("SELECT 1 FROM symbols WHERE name=? AND file_id=(SELECT id FROM files WHERE path=?)")) |cs| {
            defer cs.finalize();
            cs.bind_text(1, new_name);
            cs.bind_text(2, pfc);
            if (cs.step() catch false) {
                return types.ResponseMessage{
                    .id = msg.id,
                    .result = null,
                    .@"error" = .{ .code = -32600, .message = "Name already exists in this file" },
                };
            }
        } else |_| {}
    }

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);
    if (!self.pathInBounds(path)) return emptyResult(msg);
    const source = self.readSourceForUri(uri, path) catch
        return emptyResult(msg);
    defer self.alloc.free(source);

    const offset = self.clientPosToOffset(source, line, character);
    const word = extractWord(source, offset);
    if (word.len == 0) return emptyResult(msg);

    const Edit = struct { line: i64, col: i64 };
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var edits_map = std.StringHashMap(std.ArrayList(Edit)).init(a);

    const cursor_line_1based: i64 = @intCast(line + 1);

    var word_col_start: usize = offset;
    while (word_col_start > 0 and isRubyIdent(source[word_col_start - 1])) word_col_start -= 1;
    var rename_line_start: usize = 0;
    var rj: usize = 0;
    while (rj < word_col_start) : (rj += 1) {
        if (source[rj] == '\n') rename_line_start = rj + 1;
    }
    const cursor_col_0: i64 = @intCast(word_col_start - rename_line_start);

    var is_local_rename = false;
    var rename_scope_id: ?i64 = null;

    const fid_check = try self.db.prepare("SELECT id FROM files WHERE path=?");
    defer fid_check.finalize();
    fid_check.bind_text(1, path);
    if (try fid_check.step()) {
        const fid = fid_check.column_int(0);
        if (editing.resolveScopeId(self, fid, word, cursor_line_1based, cursor_col_0)) |sid| {
            is_local_rename = true;
            rename_scope_id = if (sid != 0) sid else null;
        }
    }

    if (!is_local_rename) {
        var method_parent: ?[]const u8 = null;
        defer if (method_parent) |mp| self.alloc.free(mp);
        if (self.db.prepare(
            "SELECT parent_name FROM symbols WHERE name=? AND kind IN ('def','classdef') AND parent_name IS NOT NULL LIMIT 1",
        )) |ps| {
            defer ps.finalize();
            ps.bind_text(1, word);
            if (ps.step() catch false) {
                const pn = ps.column_text(0);
                if (pn.len > 0) method_parent = self.alloc.dupe(u8, pn) catch null;
            }
        } else |_| {}

        if (method_parent) |mp| {
            var related_classes = std.StringHashMap(void).init(a);
            try related_classes.put(try a.dupe(u8, mp), {});

            var depth: u8 = 0;
            while (depth < 4) : (depth += 1) {
                var new_names = std.ArrayList([]const u8){};
                var it = related_classes.keyIterator();
                while (it.next()) |kp| {
                    if (self.db.prepare(
                        \\SELECT DISTINCT s.name FROM symbols s
                        \\JOIN mixins m ON m.class_id = s.id
                        \\WHERE m.module_name = ? AND s.kind IN ('class','module') AND s.file_id IN (SELECT id FROM files WHERE is_gem=0)
                    )) |inc_stmt| {
                        defer inc_stmt.finalize();
                        inc_stmt.bind_text(1, kp.*);
                        while (inc_stmt.step() catch false) {
                            const cn = inc_stmt.column_text(0);
                            if (cn.len > 0 and !related_classes.contains(cn)) {
                                new_names.append(a, a.dupe(u8, cn) catch continue) catch {}; // OOM: name list
                            }
                        }
                    } else |_| {}
                    if (self.db.prepare(
                        \\SELECT DISTINCT name FROM symbols
                        \\WHERE parent_name = ? AND kind IN ('class','module') AND file_id IN (SELECT id FROM files WHERE is_gem=0)
                    )) |sub_stmt| {
                        defer sub_stmt.finalize();
                        sub_stmt.bind_text(1, kp.*);
                        while (sub_stmt.step() catch false) {
                            const cn = sub_stmt.column_text(0);
                            if (cn.len > 0 and !related_classes.contains(cn)) {
                                new_names.append(a, a.dupe(u8, cn) catch continue) catch {}; // OOM: name list
                            }
                        }
                    } else |_| {}
                }
                if (new_names.items.len == 0) break;
                for (new_names.items) |nn| related_classes.put(nn, {}) catch {}; // OOM: name set
            }

            var rc_it = related_classes.keyIterator();
            while (rc_it.next()) |class_name_ptr| {
                const cn = class_name_ptr.*;
                const sym_stmt = self.db.prepare(
                    \\SELECT s.line, s.col, f.path FROM symbols s JOIN files f ON s.file_id=f.id
                    \\WHERE s.name=? AND f.is_gem=0 AND s.file_id IN (
                    \\  SELECT file_id FROM symbols WHERE name=? AND kind IN ('class','module','classdef','def')
                    \\)
                ) catch continue;
                defer sym_stmt.finalize();
                sym_stmt.bind_text(1, word);
                sym_stmt.bind_text(2, cn);
                while (sym_stmt.step() catch false) {
                    const sym_line = sym_stmt.column_int(0);
                    const sym_col = sym_stmt.column_int(1);
                    const sym_path = sym_stmt.column_text(2);
                    const key = try a.dupe(u8, sym_path);
                    const gop = try edits_map.getOrPut(key);
                    if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Edit){};
                    try gop.value_ptr.append(a, .{ .line = sym_line, .col = sym_col });
                }
                const ref_stmt = self.db.prepare(
                    \\SELECT r.line, r.col, f.path FROM refs r JOIN files f ON r.file_id=f.id
                    \\WHERE r.name=? AND f.is_gem=0 AND r.file_id IN (
                    \\  SELECT file_id FROM symbols WHERE name=? AND kind IN ('class','module','classdef','def')
                    \\)
                ) catch continue;
                defer ref_stmt.finalize();
                ref_stmt.bind_text(1, word);
                ref_stmt.bind_text(2, cn);
                while (ref_stmt.step() catch false) {
                    const ref_line = ref_stmt.column_int(0);
                    const ref_col = ref_stmt.column_int(1);
                    const ref_path = ref_stmt.column_text(2);
                    const key = try a.dupe(u8, ref_path);
                    const gop = try edits_map.getOrPut(key);
                    if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Edit){};
                    try gop.value_ptr.append(a, .{ .line = ref_line, .col = ref_col });
                }
            }

            const global_ref = self.db.prepare(
                \\SELECT r.line, r.col, f.path FROM refs r JOIN files f ON r.file_id=f.id
                \\WHERE r.name=? AND f.is_gem=0
            ) catch null;
            if (global_ref) |gr| {
                defer gr.finalize();
                gr.bind_text(1, word);
                while (gr.step() catch false) {
                    const rl = gr.column_int(0);
                    const rc = gr.column_int(1);
                    const rp = gr.column_text(2);
                    const key = try a.dupe(u8, rp);
                    const gop = try edits_map.getOrPut(key);
                    if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Edit){};
                    var exists = false;
                    for (gop.value_ptr.items) |existing| {
                        if (existing.line == rl and existing.col == rc) {
                            exists = true;
                            break;
                        }
                    }
                    if (!exists) try gop.value_ptr.append(a, .{ .line = rl, .col = rc });
                }
            }
        } else {
            const sym_stmt = try self.db.prepare(
                \\SELECT s.line, s.col, f.path FROM symbols s JOIN files f ON s.file_id=f.id WHERE s.name=? AND f.is_gem=0
            );
            defer sym_stmt.finalize();
            sym_stmt.bind_text(1, word);
            while (try sym_stmt.step()) {
                const sym_line = sym_stmt.column_int(0);
                const sym_col = sym_stmt.column_int(1);
                const sym_path = sym_stmt.column_text(2);
                const key = try a.dupe(u8, sym_path);
                const gop = try edits_map.getOrPut(key);
                if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Edit){};
                try gop.value_ptr.append(a, .{ .line = sym_line, .col = sym_col });
            }

            const ref_stmt = try self.db.prepare(
                \\SELECT r.line, r.col, f.path FROM refs r JOIN files f ON r.file_id=f.id WHERE r.name=? AND f.is_gem=0
            );
            defer ref_stmt.finalize();
            ref_stmt.bind_text(1, word);
            while (try ref_stmt.step()) {
                const ref_line = ref_stmt.column_int(0);
                const ref_col = ref_stmt.column_int(1);
                const ref_path = ref_stmt.column_text(2);
                const key = try a.dupe(u8, ref_path);
                const gop = try edits_map.getOrPut(key);
                if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Edit){};
                try gop.value_ptr.append(a, .{ .line = ref_line, .col = ref_col });
            }
        }
    } else {
        if (rename_scope_id) |sid| {
            const lv_stmt = try self.db.prepare(
                \\SELECT lv.line, lv.col, f.path FROM local_vars lv JOIN files f ON lv.file_id=f.id
                \\WHERE lv.name=? AND lv.scope_id=?
            );
            defer lv_stmt.finalize();
            lv_stmt.bind_text(1, word);
            lv_stmt.bind_int(2, sid);
            while (try lv_stmt.step()) {
                const lv_line = lv_stmt.column_int(0);
                const lv_col = lv_stmt.column_int(1);
                const lv_path = lv_stmt.column_text(2);
                const key = try a.dupe(u8, lv_path);
                const gop = try edits_map.getOrPut(key);
                if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Edit){};
                try gop.value_ptr.append(a, .{ .line = lv_line, .col = lv_col });
            }

            const ref_stmt = try self.db.prepare(
                \\SELECT r.line, r.col, f.path FROM refs r JOIN files f ON r.file_id=f.id
                \\WHERE r.name=? AND r.scope_id=?
            );
            defer ref_stmt.finalize();
            ref_stmt.bind_text(1, word);
            ref_stmt.bind_int(2, sid);
            while (try ref_stmt.step()) {
                const ref_line = ref_stmt.column_int(0);
                const ref_col = ref_stmt.column_int(1);
                const ref_path = ref_stmt.column_text(2);
                const key = try a.dupe(u8, ref_path);
                const gop = try edits_map.getOrPut(key);
                if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Edit){};
                try gop.value_ptr.append(a, .{ .line = ref_line, .col = ref_col });
            }
        } else {
            const fid_stmt2 = try self.db.prepare("SELECT id FROM files WHERE path=?");
            defer fid_stmt2.finalize();
            fid_stmt2.bind_text(1, path);
            if (try fid_stmt2.step()) {
                const fid = fid_stmt2.column_int(0);
                const lv_stmt = try self.db.prepare(
                    \\SELECT lv.line, lv.col, f.path FROM local_vars lv JOIN files f ON lv.file_id=f.id
                    \\WHERE lv.name=? AND lv.file_id=? AND lv.scope_id IS NULL
                );
                defer lv_stmt.finalize();
                lv_stmt.bind_text(1, word);
                lv_stmt.bind_int(2, fid);
                while (try lv_stmt.step()) {
                    const lv_line = lv_stmt.column_int(0);
                    const lv_col = lv_stmt.column_int(1);
                    const lv_path = lv_stmt.column_text(2);
                    const key = try a.dupe(u8, lv_path);
                    const gop = try edits_map.getOrPut(key);
                    if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Edit){};
                    try gop.value_ptr.append(a, .{ .line = lv_line, .col = lv_col });
                }

                const ref_stmt = try self.db.prepare(
                    \\SELECT r.line, r.col, f.path FROM refs r JOIN files f ON r.file_id=f.id
                    \\WHERE r.name=? AND r.file_id=? AND r.scope_id IS NULL
                );
                defer ref_stmt.finalize();
                ref_stmt.bind_text(1, word);
                ref_stmt.bind_int(2, fid);
                while (try ref_stmt.step()) {
                    const ref_line = ref_stmt.column_int(0);
                    const ref_col = ref_stmt.column_int(1);
                    const ref_path = ref_stmt.column_text(2);
                    const key = try a.dupe(u8, ref_path);
                    const gop = try edits_map.getOrPut(key);
                    if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Edit){};
                    try gop.value_ptr.append(a, .{ .line = ref_line, .col = ref_col });
                }
            }
        }
    }

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    var frc_rn: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var frc_it = frc_rn.iterator();
        while (frc_it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        frc_rn.deinit(self.alloc);
    }
    var it = edits_map.iterator();
    if (self.client_caps_doc_changes) {
        try w.writeAll("{\"documentChanges\":[");
        var first_path = true;
        while (it.next()) |entry| {
            if (!first_path) try w.writeByte(',');
            first_path = false;
            try w.writeAll("{\"textDocument\":{\"uri\":\"file://");
            try writePathAsUri(w, entry.key_ptr.*);
            try w.writeAll("\",\"version\":1},\"edits\":[");
            var first_edit = true;
            for (entry.value_ptr.items) |edit| {
                if (!first_edit) try w.writeByte(',');
                first_edit = false;
                const edit_start = self.toClientColFromPath(&frc_rn, entry.key_ptr.*, edit.line - 1, edit.col);
                try w.writeAll("{\"range\":{\"start\":{\"line\":");
                try w.print("{d}", .{edit.line - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{edit_start});
                try w.writeAll("},\"end\":{\"line\":");
                try w.print("{d}", .{edit.line - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{edit_start + @as(u32, @intCast(word.len))});
                try w.writeAll("}},\"newText\":");
                try writeEscapedJson(w, new_name);
                try w.writeByte('}');
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
    } else {
        try w.writeAll("{\"changes\":{");
        var first_path = true;
        while (it.next()) |entry| {
            if (!first_path) try w.writeByte(',');
            first_path = false;
            try w.writeAll("\"file://");
            try writePathAsUri(w, entry.key_ptr.*);
            try w.writeAll("\":[");
            var first_edit = true;
            for (entry.value_ptr.items) |edit| {
                if (!first_edit) try w.writeByte(',');
                first_edit = false;
                const edit_start = self.toClientColFromPath(&frc_rn, entry.key_ptr.*, edit.line - 1, edit.col);
                try w.writeAll("{\"range\":{\"start\":{\"line\":");
                try w.print("{d}", .{edit.line - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{edit_start});
                try w.writeAll("},\"end\":{\"line\":");
                try w.print("{d}", .{edit.line - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{edit_start + @as(u32, @intCast(word.len))});
                try w.writeAll("}},\"newText\":");
                try writeEscapedJson(w, new_name);
                try w.writeByte('}');
            }
            try w.writeByte(']');
        }
        try w.writeAll("}}");
    }

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn handleWillRenameFiles(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    const params = msg.params orelse {
        var aw0 = std.Io.Writer.Allocating.init(self.alloc);
        try aw0.writer.writeAll("{\"changes\":{}}");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw0.toOwnedSlice(), .@"error" = null };
    };
    const obj = switch (params) {
        .object => |o| o,
        else => {
            var aw0 = std.Io.Writer.Allocating.init(self.alloc);
            try aw0.writer.writeAll("{\"changes\":{}}");
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw0.toOwnedSlice(), .@"error" = null };
        },
    };
    const files_val = obj.get("files") orelse {
        var aw0 = std.Io.Writer.Allocating.init(self.alloc);
        try aw0.writer.writeAll("{\"changes\":{}}");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw0.toOwnedSlice(), .@"error" = null };
    };
    const files = switch (files_val) {
        .array => |a| a,
        else => {
            var aw0 = std.Io.Writer.Allocating.init(self.alloc);
            try aw0.writer.writeAll("{\"changes\":{}}");
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw0.toOwnedSlice(), .@"error" = null };
        },
    };

    var changes_map = std.StringHashMap(std.ArrayList(struct { line: i64, col_start: usize, col_end: usize, new_text: []const u8 })).init(self.alloc);
    defer {
        var cit = changes_map.iterator();
        while (cit.next()) |e| {
            for (e.value_ptr.items) |edit| self.alloc.free(@constCast(edit.new_text));
            e.value_ptr.deinit(self.alloc);
            self.alloc.free(e.key_ptr.*);
        }
        changes_map.deinit();
    }

    for (files.items) |file_val| {
        const file_obj = switch (file_val) {
            .object => |o| o,
            else => continue,
        };
        const old_uri_val = file_obj.get("oldUri") orelse continue;
        const new_uri_val = file_obj.get("newUri") orelse continue;
        const old_uri = switch (old_uri_val) {
            .string => |s| s,
            else => continue,
        };
        const new_uri = switch (new_uri_val) {
            .string => |s| s,
            else => continue,
        };

        if (!std.mem.endsWith(u8, old_uri, ".rb") or !std.mem.endsWith(u8, new_uri, ".rb")) continue;

        const old_base = std.fs.path.basename(old_uri);
        const new_base = std.fs.path.basename(new_uri);
        if (old_base.len < 3 or new_base.len < 3) continue;
        const old_stem = old_base[0 .. old_base.len - 3];
        const new_stem = new_base[0 .. new_base.len - 3];
        if (std.mem.eql(u8, old_stem, new_stem)) continue;

        self.db_mutex.lock();
        const fstmt = self.db.prepare("SELECT path FROM files WHERE is_gem=0") catch {
            self.db_mutex.unlock();
            continue;
        };
        defer fstmt.finalize();
        var caller_paths = std.ArrayList([]u8){};
        defer {
            for (caller_paths.items) |p| self.alloc.free(p);
            caller_paths.deinit(self.alloc);
        }
        while (fstmt.step() catch false) {
            const p = fstmt.column_text(0);
            if (p.len > 0) {
                caller_paths.append(self.alloc, self.alloc.dupe(u8, p) catch continue) catch {}; // OOM: path list
            }
        }
        self.db_mutex.unlock();

        for (caller_paths.items) |cpath| {
            const content = std.fs.cwd().readFileAlloc(self.alloc, cpath, self.max_file_size.load(.monotonic)) catch continue;
            defer self.alloc.free(content);

            var line_num: i64 = 0;
            var line_start: usize = 0;
            while (line_start <= content.len) {
                const line_end = std.mem.indexOfScalar(u8, content[line_start..], '\n') orelse content.len - line_start;
                const line_slice = content[line_start .. line_start + line_end];

                if (std.mem.indexOf(u8, line_slice, "require_relative") != null) {
                    var col: usize = 0;
                    while (col < line_slice.len) {
                        if (line_slice[col] == '\'' or line_slice[col] == '"') {
                            const quote = line_slice[col];
                            const str_start = col + 1;
                            const str_end = std.mem.indexOfScalarPos(u8, line_slice, str_start, quote) orelse break;
                            const str = line_slice[str_start..str_end];
                            const last_sep = std.mem.lastIndexOfScalar(u8, str, '/') orelse 0;
                            const final = if (last_sep > 0) str[last_sep + 1 ..] else str;
                            if (std.mem.eql(u8, final, old_stem)) {
                                const new_str = if (last_sep > 0)
                                    std.fmt.allocPrint(self.alloc, "{c}{s}/{s}{c}", .{ quote, str[0..last_sep], new_stem, quote }) catch break
                                else
                                    std.fmt.allocPrint(self.alloc, "{c}{s}{c}", .{ quote, new_stem, quote }) catch break;

                                const file_uri = std.fmt.allocPrint(self.alloc, "file://{s}", .{cpath}) catch {
                                    self.alloc.free(new_str);
                                    break;
                                };
                                const gop = changes_map.getOrPut(file_uri) catch {
                                    self.alloc.free(new_str);
                                    self.alloc.free(file_uri);
                                    break;
                                };
                                if (!gop.found_existing) {
                                    gop.value_ptr.* = .{};
                                } else {
                                    self.alloc.free(file_uri);
                                }
                                gop.value_ptr.append(self.alloc, .{
                                    .line = line_num,
                                    .col_start = col,
                                    .col_end = str_end + 1,
                                    .new_text = new_str,
                                }) catch {
                                    self.alloc.free(new_str);
                                };
                            }
                            col = str_end + 1;
                        } else {
                            col += 1;
                        }
                    }
                }

                if (line_start + line_end >= content.len) break;
                line_start += line_end + 1;
                line_num += 1;
            }
        }
    }

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    var cit2 = changes_map.iterator();
    if (self.client_caps_doc_changes) {
        try w.writeAll("{\"documentChanges\":[");
        var first_file = true;
        while (cit2.next()) |e| {
            if (!first_file) try w.writeByte(',');
            first_file = false;
            try w.writeAll("{\"textDocument\":{\"uri\":");
            try writeEscapedJson(w, e.key_ptr.*);
            try w.writeAll(",\"version\":1},\"edits\":[");
            var first_edit = true;
            for (e.value_ptr.items) |edit| {
                if (!first_edit) try w.writeByte(',');
                first_edit = false;
                try w.print(
                    "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":",
                    .{ edit.line, edit.col_start, edit.line, edit.col_end },
                );
                try writeEscapedJson(w, edit.new_text);
                try w.writeByte('}');
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
    } else {
        try w.writeAll("{\"changes\":{");
        var first_file = true;
        while (cit2.next()) |e| {
            if (!first_file) try w.writeByte(',');
            first_file = false;
            try writeEscapedJson(w, e.key_ptr.*);
            try w.writeAll(":[");
            var first_edit = true;
            for (e.value_ptr.items) |edit| {
                if (!first_edit) try w.writeByte(',');
                first_edit = false;
                try w.print(
                    "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":",
                    .{ edit.line, edit.col_start, edit.line, edit.col_end },
                );
                try writeEscapedJson(w, edit.new_text);
                try w.writeByte('}');
            }
            try w.writeByte(']');
        }
        try w.writeAll("}}");
    }
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}
