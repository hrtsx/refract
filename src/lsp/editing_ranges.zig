const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const types = @import("types.zig");
const db_mod = @import("../db.zig");
const prism_mod = @import("../prism.zig");
const erb_mapping = @import("erb_mapping.zig");
const refactor = @import("refactor.zig");

const extractTextDocumentUri = S.extractTextDocumentUri;
const extractParamsObject = S.extractParamsObject;
const extractPosition = S.extractPosition;
const uriToPath = S.uriToPath;
const pathToUri = S.pathToUri;
const emptyResult = S.emptyResult;
const writeEscapedJsonContent = S.writeEscapedJsonContent;
const writeEscapedJson = S.writeEscapedJson;
const writePathAsUri = S.writePathAsUri;
const getLineSlice = S.getLineSlice;
const extractWord = S.extractWord;
const extractQualifiedName = S.extractQualifiedName;
const utf8ColToUtf16 = S.utf8ColToUtf16;
const isRubyIdent = S.isRubyIdent;
const isValidRubyIdent = S.isValidRubyIdent;
const isInStringOrComment = S.isInStringOrComment;
const frcGet = S.frcGet;
const emitSelRange = S.emitSelRange;
const resolveRequireTarget = S.resolveRequireTarget;
const paramHintVisitor = S.paramHintVisitor;
const ParamHintCtx = S.ParamHintCtx;

const ruby_block_keywords = S.ruby_block_keywords;

pub fn handleFoldingRange(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    if (self.isCancelled(msg.id)) return self.cancelledResponse(msg.id);
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

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);

    const file_stmt = try self.queryDb().prepare("SELECT id FROM files WHERE path = ?");
    defer file_stmt.finalize();
    file_stmt.bind_text(1, path);
    if (!(try file_stmt.step())) return emptyResult(msg);
    const file_id = file_stmt.column_int(0);

    const stmt = try self.queryDb().prepare("SELECT kind, line, end_line FROM symbols WHERE file_id=? ORDER BY line");
    defer stmt.finalize();
    stmt.bind_int(1, file_id);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeAll("[");
    var first = true;

    var sym_ranges = std.ArrayList(struct { start: i64, end: i64 }).empty;
    defer sym_ranges.deinit(self.alloc);

    while (try stmt.step()) {
        const kind = stmt.column_text(0);
        const sym_line = stmt.column_int(1);
        const sym_end = stmt.column_int(2);
        if ((std.mem.eql(u8, kind, "class") or std.mem.eql(u8, kind, "module") or std.mem.eql(u8, kind, "def") or std.mem.eql(u8, kind, "classdef")) and sym_end > sym_line) {
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("{{\"startLine\":{d},\"endLine\":{d},\"kind\":\"region\"}}", .{ sym_line - 1, sym_end - 1 });
            sym_ranges.append(self.alloc, .{ .start = sym_line - 1, .end = sym_end - 1 }) catch S.logOomOnce("folding.sym_ranges");
        }
    }

    const source = self.readSourceForUri(uri, path) catch null;
    if (source) |src| {
        defer self.alloc.free(src);
        var line_list = std.ArrayList([]const u8).empty;
        defer line_list.deinit(self.alloc);
        var lit = std.mem.splitScalar(u8, src, '\n');
        while (lit.next()) |ln| {
            line_list.append(self.alloc, ln) catch break;
        }
        const lines = line_list.items;

        var stack_lines = std.ArrayList(i64).empty;
        defer stack_lines.deinit(self.alloc);

        for (lines, 0..) |raw_line, li| {
            const trimmed = std.mem.trim(u8, raw_line, " \t\r");
            const is_do = std.mem.endsWith(u8, trimmed, " do") or
                (std.mem.indexOfScalar(u8, trimmed, '|') != null and std.mem.endsWith(u8, trimmed, "|"));
            var is_kw = false;
            for (ruby_block_keywords) |k| {
                if (std.mem.startsWith(u8, trimmed, k)) {
                    is_kw = true;
                    break;
                }
            }
            if (is_do or is_kw) {
                stack_lines.append(self.alloc, @intCast(li)) catch S.logOomOnce("folding.stack_lines");
            } else if (std.mem.eql(u8, trimmed, "end") or
                std.mem.startsWith(u8, trimmed, "end ") or
                std.mem.startsWith(u8, trimmed, "end#"))
            {
                if (stack_lines.items.len > 0) {
                    const start_l = stack_lines.pop() orelse continue;
                    const end_l: i64 = @intCast(li);
                    if (end_l > start_l + 1) {
                        var dup = false;
                        for (sym_ranges.items) |sr| {
                            if (sr.start == start_l and sr.end == end_l) {
                                dup = true;
                                break;
                            }
                        }
                        if (!dup) {
                            if (!first) try w.writeByte(',');
                            first = false;
                            try w.print("{{\"startLine\":{d},\"endLine\":{d},\"kind\":\"region\"}}", .{ start_l, end_l - 1 });
                        }
                    }
                }
            }
        }

        // Comment block folding: fold 3 or more consecutive '#'-prefixed comment lines
        var comment_start: ?usize = null;
        for (lines, 0..) |raw_line, li| {
            const trimmed = std.mem.trim(u8, raw_line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "#")) {
                if (comment_start == null) comment_start = li;
            } else {
                if (comment_start) |cs| {
                    if (li - cs >= 3) {
                        if (!first) try w.writeByte(',');
                        first = false;
                        try w.print("{{\"startLine\":{d},\"endLine\":{d},\"kind\":\"comment\"}}", .{ cs, li - 1 });
                    }
                    comment_start = null;
                }
            }
        }
        if (comment_start) |cs| {
            if (lines.len - cs >= 3) {
                if (!first) try w.writeByte(',');
                first = false;
                try w.print("{{\"startLine\":{d},\"endLine\":{d},\"kind\":\"comment\"}}", .{ cs, lines.len - 1 });
            }
        }

        // Require block folding: fold 2 or more consecutive require/require_relative lines
        var req_start: ?usize = null;
        var req_end: usize = 0;
        var req_count: usize = 0;
        for (lines, 0..) |raw_line, li| {
            const trimmed = std.mem.trim(u8, raw_line, " \t\r");
            const is_req = std.mem.startsWith(u8, trimmed, "require ") or
                std.mem.startsWith(u8, trimmed, "require_relative ");
            if (is_req) {
                if (req_start == null) req_start = li;
                req_end = li;
                req_count += 1;
            } else if (trimmed.len > 0) {
                if (req_start) |rs| {
                    if (req_count >= 2) {
                        if (!first) try w.writeByte(',');
                        first = false;
                        try w.print("{{\"startLine\":{d},\"endLine\":{d},\"kind\":\"imports\"}}", .{ rs, req_end });
                    }
                    req_start = null;
                    req_count = 0;
                }
            }
        }
        if (req_start) |rs| {
            if (req_count >= 2) {
                if (!first) try w.writeByte(',');
                first = false;
                try w.print("{{\"startLine\":{d},\"endLine\":{d},\"kind\":\"imports\"}}", .{ rs, req_end });
            }
        }
    }

    try w.writeAll("]");
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}

pub fn handleSelectionRange(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    if (self.isCancelled(msg.id)) return self.cancelledResponse(msg.id);
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
    const positions_val = obj.get("positions") orelse return emptyResult(msg);
    const positions = switch (positions_val) {
        .array => |a| a,
        else => return emptyResult(msg),
    };
    if (positions.items.len == 0) return emptyResult(msg);
    const pos = switch (positions.items[0]) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const line: u32 = switch (pos.get("line") orelse return emptyResult(msg)) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else return emptyResult(msg),
        else => return emptyResult(msg),
    };
    _ = switch (pos.get("character") orelse return emptyResult(msg)) {
        .integer => |i| if (i >= 0) @as(u32, @intCast(i)) else return emptyResult(msg),
        else => return emptyResult(msg),
    };

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);

    const file_stmt = try self.queryDb().prepare("SELECT id FROM files WHERE path=?");
    defer file_stmt.finalize();
    file_stmt.bind_text(1, path);
    if (!(try file_stmt.step())) return emptyResult(msg);
    const file_id = file_stmt.column_int(0);

    const db_line: i64 = @intCast(line + 1);
    // Collect all symbols that contain the cursor, ordered from innermost (smallest span) to outermost
    const sym_stmt = try self.queryDb().prepare(
        \\SELECT name, line, col, end_line FROM symbols WHERE file_id=? AND line<=? AND end_line>=? ORDER BY (end_line-line) ASC
    );
    defer sym_stmt.finalize();
    sym_stmt.bind_int(1, file_id);
    sym_stmt.bind_int(2, db_line);
    sym_stmt.bind_int(3, db_line);

    // Collect rows into a list
    const SRange = struct { sym_line: i64, sym_col: i64, sym_end: i64, name_len: i64 };
    var ranges = std.ArrayList(SRange).empty;
    defer ranges.deinit(self.alloc);
    while (try sym_stmt.step()) {
        const sym_name = sym_stmt.column_text(0);
        try ranges.append(self.alloc, .{
            .sym_line = sym_stmt.column_int(1),
            .sym_col = sym_stmt.column_int(2),
            .sym_end = sym_stmt.column_int(3),
            .name_len = @intCast(sym_name.len),
        });
    }

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');

    if (ranges.items.len > 0) {
        const innermost = ranges.items[0];
        const word_end_col = innermost.sym_col + innermost.name_len;

        // Open the outermost levels first (we write from innermost, so open braces accumulate)
        // Word range as innermost (leaf)
        try w.print("{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
            innermost.sym_line - 1, innermost.sym_col,
            innermost.sym_line - 1, word_end_col,
        });

        // Each DB row adds a parent level (the symbol's full body span)
        for (ranges.items) |r| {
            try w.print(",\"parent\":{{\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":999}}}}", .{
                r.sym_line - 1,
                r.sym_end - 1,
            });
        }

        // Close all the nested parent objects
        for (0..ranges.items.len) |_| {
            try w.writeByte('}');
        }
        // Close the root object
        try w.writeByte('}');
    }

    try w.writeByte(']');
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}

pub fn handleLinkedEditingRange(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    if (self.isCancelled(msg.id)) return self.cancelledResponse(msg.id);
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
    const pos = switch (obj.get("position") orelse return emptyResult(msg)) {
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

    const file_stmt = try self.queryDb().prepare("SELECT id FROM files WHERE path=?");
    defer file_stmt.finalize();
    file_stmt.bind_text(1, path);
    if (!(try file_stmt.step())) return emptyResult(msg);
    const file_id = file_stmt.column_int(0);

    // Find scope_id for the variable at this position
    const scope_stmt = try self.queryDb().prepare("SELECT scope_id FROM local_vars WHERE file_id=? AND name=? " ++
        "AND line<=? ORDER BY line DESC LIMIT 1");
    defer scope_stmt.finalize();
    scope_stmt.bind_int(1, file_id);
    scope_stmt.bind_text(2, word);
    scope_stmt.bind_int(3, @intCast(line + 1));
    var scope_id_opt: ?i64 = null;
    if (try scope_stmt.step()) {
        const sv = scope_stmt.column_int(0);
        if (scope_stmt.column_type(0) != 5) scope_id_opt = sv; // 5 = SQLITE_NULL
    }

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeAll("{\"ranges\":[");
    var first = true;

    const has_scope = scope_id_opt != null;
    const q: [*:0]const u8 = if (has_scope)
        "SELECT line, col FROM local_vars WHERE file_id=? AND name=? AND scope_id=? ORDER BY line"
    else
        "SELECT line, col FROM local_vars WHERE file_id=? AND name=? AND scope_id IS NULL ORDER BY line";
    const occ_stmt = try self.queryDb().prepare(q);
    defer occ_stmt.finalize();
    occ_stmt.bind_int(1, file_id);
    occ_stmt.bind_text(2, word);
    if (has_scope) occ_stmt.bind_int(3, scope_id_opt.?);

    while (try occ_stmt.step()) {
        const ln = occ_stmt.column_int(0) - 1;
        const col = occ_stmt.column_int(1);
        const ln_src = getLineSlice(source, @intCast(ln));
        const start_char = self.toClientCol(ln_src, @intCast(col));
        const end_char = start_char + @as(u32, @intCast(word.len));
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{ ln, start_char, ln, end_char });
    }
    try w.writeAll("]}");
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}
