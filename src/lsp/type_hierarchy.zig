const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const types = @import("types.zig");

const emptyResult = S.emptyResult;
const uriToPath = S.uriToPath;
const extractWord = S.extractWord;
const writeEscapedJson = S.writeEscapedJson;
const writePathAsUri = S.writePathAsUri;

pub fn handlePrepareTypeHierarchy(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    const rtx = self.beginRead();
    defer rtx.end();
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
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else return emptyResult(msg),
        else => return emptyResult(msg),
    };
    const character: u32 = switch (pos.get("character") orelse return emptyResult(msg)) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else return emptyResult(msg),
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

    const stmt = try self.cachedStmt("SELECT s.id, s.name, s.kind, s.line, s.col, f.path FROM symbols s JOIN files f ON s.file_id=f.id WHERE s.name=? AND s.kind IN ('class','module','classdef') LIMIT 1");
    defer stmt.reset();
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
    const rtx = self.beginRead();
    defer rtx.end();
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

    const mro_stmt = self.cachedStmt(
        \\WITH RECURSIVE mro(name, depth) AS (
        \\  SELECT parent_name, 1 FROM symbols WHERE name=? AND kind IN ('class','module')
        \\  UNION ALL
        \\  SELECT s.parent_name, m.depth+1 FROM mro m
        \\  JOIN symbols s ON s.name=m.name AND s.kind IN ('class','module')
        \\  WHERE m.depth < 8
        \\) SELECT DISTINCT m.name, s.id, s.kind, s.line, s.col, f.path
        \\  FROM mro m
        \\  LEFT JOIN symbols s ON s.name=m.name AND s.kind IN ('class','module')
        \\  LEFT JOIN files f ON s.file_id=f.id
        \\  WHERE m.name IS NOT NULL
    ) catch {
        try w.writeByte(']');
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    };
    defer mro_stmt.reset();
    mro_stmt.bind_text(1, class_name);

    var seen_arena = std.heap.ArenaAllocator.init(self.alloc);
    defer seen_arena.deinit();
    var seen_parents = std.StringHashMap(void).init(seen_arena.allocator());

    while (mro_stmt.step() catch false) {
        const parent_name_raw = mro_stmt.column_text(0);
        if (parent_name_raw.len == 0 or seen_parents.contains(parent_name_raw)) continue;
        try seen_parents.put(seen_arena.allocator().dupe(u8, parent_name_raw) catch continue, {});

        // LEFT JOIN: an empty path means no indexed symbol-with-file for this
        // parent — emit the minimal item, matching the old INNER-JOIN miss.
        const sym_path = mro_stmt.column_text(5);
        if (sym_path.len == 0) {
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"name\":");
            try writeEscapedJson(w, parent_name_raw);
            try w.writeAll(",\"kind\":5,\"uri\":\"\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}}}");
            continue;
        }
        const sym_id = mro_stmt.column_int(1);
        const sym_name = parent_name_raw;
        const sym_kind = mro_stmt.column_text(2);
        const sym_line = mro_stmt.column_int(3);
        const sym_col = mro_stmt.column_int(4);
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
    const mix_stmt = self.cachedStmt("SELECT m.module_name FROM mixins m JOIN symbols s ON m.class_id=s.id WHERE s.name=?") catch {
        try w.writeByte(']');
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    };
    defer mix_stmt.reset();
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
    const rtx = self.beginRead();
    defer rtx.end();
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

    const stmt = try self.cachedStmt("SELECT s.id, s.name, s.kind, s.line, s.col, f.path FROM symbols s JOIN files f ON s.file_id=f.id WHERE s.parent_name=? AND s.kind='class' LIMIT 50");
    defer stmt.reset();
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
