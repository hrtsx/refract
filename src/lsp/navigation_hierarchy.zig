const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const types = @import("types.zig");
const db_mod = @import("../db.zig");
const erb_mapping = @import("erb_mapping.zig");
const editing = @import("editing.zig");
const hot_index_mod = @import("hot_index.zig");
const literal_receiver = @import("literal_receiver.zig");
const type_resolver = @import("type_resolver.zig");

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

const nav_symbols = @import("navigation_symbols.zig");
const writeLoc = nav_symbols.writeLoc;
const DefOrigin = nav_symbols.DefOrigin;
const emitOneDef = nav_symbols.emitOneDef;
const emitDefinitionOnClass = nav_symbols.emitDefinitionOnClass;
const tryEmitFromHotIndex = nav_symbols.tryEmitFromHotIndex;
const queryAndEmitDefinitions = nav_symbols.queryAndEmitDefinitions;

pub fn handleCallHierarchyPrepare(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    const rtx = self.beginRead();
    defer rtx.end();
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
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else return emptyResult(msg),
        else => return emptyResult(msg),
    };
    const char_val = pos.get("character") orelse return emptyResult(msg);
    const character: u32 = switch (char_val) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else return emptyResult(msg),
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

    const stmt = try self.cachedStmt(
        \\SELECT s.name, s.kind, s.line, s.col, f.path
        \\FROM symbols s JOIN files f ON s.file_id=f.id
        \\WHERE s.name=? LIMIT 1
    );
    defer stmt.reset();
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
    if (self.isCancelled(msg.id)) return self.cancelledResponse(msg.id);
    const rtx = self.beginRead();
    defer rtx.end();
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

    const ref_stmt = try self.cachedStmt(
        \\SELECT r.line, r.col, f.path FROM refs r JOIN files f ON r.file_id=f.id
        \\WHERE r.name=? ORDER BY f.path, r.line LIMIT 100
    );
    defer ref_stmt.reset();
    ref_stmt.bind_text(1, name);

    // Enclosing-method lookup: given (path, line), find innermost def/classdef/test
    const enc_stmt = self.cachedStmt(
        \\SELECT s.name, s.kind FROM symbols s JOIN files f ON s.file_id=f.id
        \\WHERE f.path=? AND s.kind IN ('def','classdef','test') AND s.line<=?
        \\ORDER BY s.line DESC LIMIT 1
    ) catch null;
    defer if (enc_stmt) |es| es.reset();

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
    var chi_i: usize = 0;
    while (try ref_stmt.step()) {
        chi_i += 1;
        if ((chi_i & 0xFF) == 0 and self.isCancelled(msg.id)) {
            aw.deinit();
            return self.cancelledResponse(msg.id);
        }
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
    if (self.isCancelled(msg.id)) return self.cancelledResponse(msg.id);
    const RefPos = struct { line: i64, col: i64 };
    const rtx = self.beginRead();
    defer rtx.end();
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

    const fid_stmt = try self.cachedStmt("SELECT id FROM files WHERE path = ?");
    defer fid_stmt.reset();
    fid_stmt.bind_text(1, path);
    if (!(try fid_stmt.step())) {
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try self.alloc.dupe(u8, empty_json_array), .@"error" = null };
    }
    const file_id = fid_stmt.column_int(0);

    const db_start_line: i64 = start_line + 1;
    const db_end_line: i64 = end_line + 1;

    const ref_stmt = try self.cachedStmt(
        \\SELECT DISTINCT r.name, r.line, r.col FROM refs r
        \\WHERE r.file_id = ? AND r.line BETWEEN ? AND ?
    );
    defer ref_stmt.reset();
    ref_stmt.bind_int(1, file_id);
    ref_stmt.bind_int(2, db_start_line);
    ref_stmt.bind_int(3, db_end_line);

    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var ref_names = std.StringHashMap(std.ArrayList(RefPos)).init(a);

    while (try ref_stmt.step()) {
        // column_text aliases SQLite's row buffer — invalidated on the next
        // step()/reset(). These keys outlive the ref_stmt loop (used during
        // serialization below), so dupe into the arena. Without this, musl's
        // allocator reuses the buffer and emits garbage method names.
        const ref_name = ref_stmt.column_text(0);
        const ref_line = ref_stmt.column_int(1);
        const ref_col = ref_stmt.column_int(2);
        const gop = try ref_names.getOrPut(ref_name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try a.dupe(u8, ref_name);
            gop.value_ptr.* = std.ArrayList(RefPos).empty;
        }
        try gop.value_ptr.append(a, .{ .line = ref_line, .col = ref_col });
    }

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeAll("[");
    var first = true;

    const def_stmt = try self.cachedStmt(
        \\SELECT s.name, s.line, s.col, f.path FROM symbols s JOIN files f ON s.file_id=f.id
        \\WHERE s.name = ? AND s.kind = 'def' LIMIT 1
    );
    defer def_stmt.reset();

    var iter = ref_names.iterator();
    while (iter.next()) |entry| {
        const ref_name = entry.key_ptr.*;
        const ref_positions = entry.value_ptr.*;

        def_stmt.reset();
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
        try w.print(",\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
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

test "navigation typeDef uses type_resolver.stripWrapper indirectly" {
    const alloc = std.testing.allocator;
    const s = try type_resolver.stripWrapper(alloc, "Class<User>");
    defer alloc.free(s);
    try std.testing.expectEqualStrings("User", s);
}
