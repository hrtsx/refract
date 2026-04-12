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

pub const ruby_block_keywords = S.ruby_block_keywords;

pub fn handleFoldingRange(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    if (self.isCancelled(msg.id)) return null;
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

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);

    const file_stmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
    defer file_stmt.finalize();
    file_stmt.bind_text(1, path);
    if (!(try file_stmt.step())) return emptyResult(msg);
    const file_id = file_stmt.column_int(0);

    const stmt = try self.db.prepare("SELECT kind, line, end_line FROM symbols WHERE file_id=? ORDER BY line");
    defer stmt.finalize();
    stmt.bind_int(1, file_id);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeAll("[");
    var first = true;

    var sym_ranges = std.ArrayList(struct { start: i64, end: i64 }){};
    defer sym_ranges.deinit(self.alloc);

    while (try stmt.step()) {
        const kind = stmt.column_text(0);
        const sym_line = stmt.column_int(1);
        const sym_end = stmt.column_int(2);
        if ((std.mem.eql(u8, kind, "class") or std.mem.eql(u8, kind, "module") or std.mem.eql(u8, kind, "def") or std.mem.eql(u8, kind, "classdef")) and sym_end > sym_line) {
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("{{\"startLine\":{d},\"endLine\":{d},\"kind\":\"region\"}}", .{ sym_line - 1, sym_end - 1 });
            sym_ranges.append(self.alloc, .{ .start = sym_line - 1, .end = sym_end - 1 }) catch {}; // OOM: range list
        }
    }

    const source = self.readSourceForUri(uri, path) catch null;
    if (source) |src| {
        defer self.alloc.free(src);
        var line_list = std.ArrayList([]const u8){};
        defer line_list.deinit(self.alloc);
        var lit = std.mem.splitScalar(u8, src, '\n');
        while (lit.next()) |ln| {
            line_list.append(self.alloc, ln) catch break;
        }
        const lines = line_list.items;

        var stack_lines = std.ArrayList(i64){};
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
                stack_lines.append(self.alloc, @intCast(li)) catch {}; // OOM: stack
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

pub fn handleSignatureHelp(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
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

    // Find enclosing call: walk backward for unmatched '('
    var active_param: u32 = 0;
    var depth: i32 = 0;
    var call_offset: ?usize = null;
    var i: usize = offset;
    while (i > 0) {
        i -= 1;
        switch (source[i]) {
            ')', ']', '}' => depth += 1,
            '(' => {
                if (depth > 0) {
                    depth -= 1;
                } else {
                    call_offset = i;
                    break;
                }
            },
            '[', '{' => if (depth > 0) {
                depth -= 1;
            },
            ',' => if (depth == 0) {
                active_param += 1;
            },
            else => {},
        }
    }

    const co = call_offset orelse return emptyResult(msg);

    // Detect keyword argument context: scan backward for `word:` at paren depth 0
    var kw_active_param: ?u32 = null;
    var kw_name_buf: [128]u8 = undefined;
    var kw_name_len: usize = 0;
    {
        var scan: usize = if (offset > 0) offset - 1 else 0;
        var kw_depth: i32 = 0;
        kw_scan: while (scan > co) : (scan -= 1) {
            const ch = source[scan];
            if (ch == ')') kw_depth += 1;
            if (ch == '(') {
                if (kw_depth == 0) break;
                kw_depth -= 1;
            }
            if (kw_depth > 0) continue;
            if (ch == ',') break;
            if (ch == ':' and scan > 0 and source[scan - 1] != ':') {
                const ne = scan;
                var ns = ne;
                while (ns > 0 and (std.ascii.isAlphanumeric(source[ns - 1]) or source[ns - 1] == '_')) ns -= 1;
                const kw = source[ns..ne];
                if (kw.len > 0 and kw.len <= kw_name_buf.len) {
                    @memcpy(kw_name_buf[0..kw.len], kw);
                    kw_name_len = kw.len;
                }
                break :kw_scan;
            }
        }
    }
    // Extract method name before '('
    const method_name = extractWord(source, if (co > 0) co - 1 else 0);
    if (method_name.len == 0) return emptyResult(msg);

    const sym_stmt = try self.db.prepare(
        \\SELECT id, return_type, doc FROM symbols WHERE name = ? AND kind = 'def' LIMIT 1
    );
    defer sym_stmt.finalize();
    sym_stmt.bind_text(1, method_name);
    if (!(try sym_stmt.step())) return emptyResult(msg);
    const symbol_id = sym_stmt.column_int(0);

    const param_stmt = try self.db.prepare(
        \\SELECT name, kind, type_hint FROM params WHERE symbol_id = ? ORDER BY position
    );
    defer param_stmt.finalize();
    param_stmt.bind_int(1, symbol_id);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;

    // Build label and parameters array
    var label_aw = std.Io.Writer.Allocating.init(self.alloc);
    const lw = &label_aw.writer;
    try lw.writeAll(method_name);
    try lw.writeByte('(');

    var param_labels = std.ArrayList([]u8){};
    defer {
        for (param_labels.items) |p| self.alloc.free(p);
        param_labels.deinit(self.alloc);
    }

    var param_index: u32 = 0;
    var first_param = true;
    while (try param_stmt.step()) {
        const pname = param_stmt.column_text(0);
        const pkind = param_stmt.column_text(1);
        // Match the active parameter by keyword argument name
        if (kw_name_len > 0 and kw_active_param == null) {
            if ((std.mem.eql(u8, pkind, "keyword") or std.mem.eql(u8, pkind, "optional")) and
                std.mem.eql(u8, pname, kw_name_buf[0..kw_name_len]))
            {
                kw_active_param = param_index;
            }
        }
        const ptype = param_stmt.column_text(2);

        if (!first_param) try lw.writeByte(',');
        first_param = false;

        var plw = std.Io.Writer.Allocating.init(self.alloc);
        const pw = &plw.writer;

        if (std.mem.eql(u8, pkind, "rest")) {
            try pw.print("*{s}", .{pname});
        } else if (std.mem.eql(u8, pkind, "keyword_rest")) {
            try pw.print("**{s}", .{pname});
        } else if (std.mem.eql(u8, pkind, "block")) {
            try pw.print("&{s}", .{pname});
        } else if (std.mem.eql(u8, pkind, "keyword")) {
            if (ptype.len > 0) {
                try pw.print("{s}: {s}", .{ pname, ptype });
            } else {
                try pw.print("{s}:", .{pname});
            }
        } else if (std.mem.eql(u8, pkind, "optional")) {
            if (ptype.len > 0) {
                try pw.print("{s}?: {s}", .{ pname, ptype });
            } else {
                try pw.print("{s}?", .{pname});
            }
        } else {
            if (ptype.len > 0) {
                try pw.print("{s}: {s}", .{ pname, ptype });
            } else {
                try pw.writeAll(pname);
            }
        }

        const pl = try plw.toOwnedSlice();
        try lw.writeAll(pl);
        try param_labels.append(self.alloc, pl);
        param_index += 1;
    }
    // Apply keyword-argument-matched active parameter index if found
    if (kw_active_param) |kwap| active_param = kwap;
    try lw.writeByte(')');

    const sig_return_type = sym_stmt.column_text(1);
    if (sig_return_type.len > 0) {
        try lw.writeAll(" \xe2\x86\x92 ");
        try lw.writeAll(sig_return_type);
    }

    const label = try label_aw.toOwnedSlice();
    defer self.alloc.free(label);

    const sym_doc = sym_stmt.column_text(2);

    try w.writeAll("{\"signatures\":[{\"label\":");
    try writeEscapedJson(w, label);
    try w.writeAll(",\"parameters\":[");
    for (param_labels.items, 0..) |pl, idx| {
        if (idx > 0) try w.writeByte(',');
        try w.writeAll("{\"label\":");
        try writeEscapedJson(w, pl);
        try w.writeByte('}');
    }
    try w.writeAll("],\"documentation\":\"");
    if (sym_doc.len > 0) {
        try writeEscapedJsonContent(w, sym_doc);
    }
    try w.writeAll("\"}],\"activeSignature\":0,\"activeParameter\":");
    try w.print("{d}", .{active_param});
    try w.writeByte('}');

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn handleInlayHint(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
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
    const range_val = obj.get("range") orelse return emptyResult(msg);
    const range = switch (range_val) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const start_val = range.get("start") orelse return emptyResult(msg);
    const start = switch (start_val) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const end_val = range.get("end") orelse return emptyResult(msg);
    const end_range = switch (end_val) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const start_line_val = start.get("line") orelse return emptyResult(msg);
    const start_line: i64 = switch (start_line_val) {
        .integer => |i| i,
        else => return emptyResult(msg),
    };
    const end_line_val = end_range.get("line") orelse return emptyResult(msg);
    const end_line: i64 = switch (end_line_val) {
        .integer => |i| i,
        else => return emptyResult(msg),
    };

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);

    const file_stmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
    defer file_stmt.finalize();
    file_stmt.bind_text(1, path);
    if (!(try file_stmt.step())) {
        var aw2 = std.Io.Writer.Allocating.init(self.alloc);
        try aw2.writer.writeAll("[]");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw2.toOwnedSlice(), .@"error" = null };
    }
    const file_id = file_stmt.column_int(0);

    // LSP lines are 0-based; DB stores 1-based
    const db_start = start_line + 1;
    const db_end = end_line + 1;

    const stmt = try self.db.prepare(
        \\SELECT name, line, type_hint, col FROM local_vars
        \\WHERE file_id = ? AND type_hint IS NOT NULL AND line BETWEEN ? AND ?
        \\ORDER BY line
    );
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_int(2, db_start);
    stmt.bind_int(3, db_end);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');
    var first = true;
    while (try stmt.step()) {
        if (!first) try w.writeByte(',');
        first = false;
        const vname = stmt.column_text(0);
        const vline = stmt.column_int(1);
        const vtype = stmt.column_text(2);
        const vcol = stmt.column_int(3);
        const lsp_line = vline - 1;
        const vlen: i64 = @intCast(vname.len);
        try w.print("{{\"position\":{{\"line\":{d},\"character\":{d}}},\"label\":\"", .{ lsp_line, vcol + vlen });
        try writeEscapedJsonContent(w, ": ");
        try writeEscapedJsonContent(w, vtype);
        try w.writeAll("\",\"kind\":1,\"paddingLeft\":false,\"paddingRight\":true}");
    }

    // Return type hints for def methods
    const def_stmt = try self.db.prepare(
        \\SELECT name, line, col, return_type
        \\FROM symbols
        \\WHERE file_id = ? AND kind = 'def' AND return_type IS NOT NULL
        \\  AND line BETWEEN ? AND ?
        \\ORDER BY line
    );
    defer def_stmt.finalize();
    def_stmt.bind_int(1, file_id);
    def_stmt.bind_int(2, db_start);
    def_stmt.bind_int(3, db_end);
    while (try def_stmt.step()) {
        if (!first) try w.writeByte(',');
        first = false;
        const dname = def_stmt.column_text(0);
        const dline = def_stmt.column_int(1);
        const dcol = def_stmt.column_int(2);
        const dret = def_stmt.column_text(3);
        const dlsp_line = dline - 1;
        const dlen: i64 = @intCast(dname.len);
        try w.print("{{\"position\":{{\"line\":{d},\"character\":{d}}},\"label\":\"", .{ dlsp_line, dcol + dlen });
        try writeEscapedJsonContent(w, "\u{2192} ");
        try writeEscapedJsonContent(w, dret);
        try w.writeAll("\",\"kind\":1,\"paddingLeft\":true,\"paddingRight\":false}");
    }

    // Parameter name hints at call sites (AST-based, avoids source scanning bugs)
    const source = self.readSourceForUri(uri, path) catch null;
    defer if (source) |s| self.alloc.free(s);
    if (source) |src| {
        // Need null-terminated source for Prism
        const src_z = self.alloc.allocSentinel(u8, src.len, 0) catch null;
        defer if (src_z) |sz| self.alloc.free(sz);
        if (src_z) |sz| {
            @memcpy(sz, src);
            var arena = prism_mod.Arena{ .current = null, .block_count = 0 };
            defer prism_mod.arena_free(&arena);
            var pparser: prism_mod.Parser = undefined;
            prism_mod.parser_init(&arena, &pparser, sz.ptr, src.len, null);
            defer prism_mod.parser_free(&pparser);
            const root = prism_mod.parse(&pparser);
            if (root != null) {
                var hint_ctx = ParamHintCtx{
                    .db = self.db,
                    .alloc = self.alloc,
                    .parser = &pparser,
                    .w = w,
                    .file_id = file_id,
                    .db_start = db_start,
                    .db_end = db_end,
                    .first_ptr = &first,
                    .source = src,
                    .encoding_utf8 = self.encoding_utf8,
                };
                prism_mod.visit_node(root, paramHintVisitor, &hint_ctx);
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

pub fn handleDocumentLink(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    const uri = extractTextDocumentUri(msg.params) orelse return emptyResult(msg);
    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);
    if (!self.pathInBounds(path)) return emptyResult(msg);
    const source = self.readSourceForUri(uri, path) catch return emptyResult(msg);
    defer self.alloc.free(source);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');
    var first = true;

    var line_num: i64 = 0;
    var i: usize = 0;

    while (i < source.len) {
        var line_end = i;
        while (line_end < source.len and source[line_end] != '\n') line_end += 1;

        const line_src = source[i..line_end];
        const trimmed = std.mem.trimLeft(u8, line_src, " \t");
        const trimmed_offset = @intFromPtr(trimmed.ptr) - @intFromPtr(line_src.ptr);

        const rel_prefix = "require_relative";
        const req_prefix = "require";
        var rest: ?[]const u8 = null;

        if (std.mem.startsWith(u8, trimmed, rel_prefix)) {
            rest = std.mem.trimLeft(u8, trimmed[rel_prefix.len..], " \t");
        } else if (std.mem.startsWith(u8, trimmed, req_prefix)) {
            rest = std.mem.trimLeft(u8, trimmed[req_prefix.len..], " \t");
        }

        if (rest) |r| {
            if (r.len >= 2) {
                const quote = r[0];
                if ((quote == '\'' or quote == '"') and std.mem.indexOfScalarPos(u8, r, 1, quote) != null) {
                    if (std.mem.indexOfScalarPos(u8, r, 1, quote)) |close| {
                        const req_str = r[1..close];
                        if (req_str.len > 0) {
                            const rest_offset_in_line = trimmed_offset + (@intFromPtr(r.ptr) - @intFromPtr(trimmed.ptr));
                            const str_start_in_line = rest_offset_in_line + 1;
                            const str_start_offset = i + str_start_in_line;
                            const str_end_offset = str_start_offset + req_str.len;

                            if (resolveRequireTarget(self.alloc, self.db, source, str_start_offset, path)) |target_path| {
                                defer self.alloc.free(target_path);

                                if (!first) try w.writeByte(',');
                                first = false;

                                const start_char = self.offsetToClientChar(source, str_start_offset, @intCast(line_num));
                                const end_char = self.offsetToClientChar(source, str_end_offset, @intCast(line_num));

                                const target_uri = pathToUri(self.alloc, target_path) catch continue;
                                defer self.alloc.free(target_uri);

                                try w.print("{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"target\":\"", .{ line_num, start_char, line_num, end_char });
                                try writeEscapedJson(w, target_uri);
                                try w.writeAll("\"}");
                            }
                        }
                    }
                }
            }
        }

        if (line_end < source.len) i = line_end + 1;
        line_num += 1;
    }

    try w.writeByte(']');
    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn handleDocumentHighlight(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
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

    const file_stmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
    defer file_stmt.finalize();
    file_stmt.bind_text(1, path);
    if (!(try file_stmt.step())) return emptyResult(msg);
    const file_id = file_stmt.column_int(0);

    // Resolve scope for local-var-aware highlight
    const cursor_line_1based_hl: i64 = @intCast(line + 1);
    var hl_word_start: usize = offset;
    while (hl_word_start > 0 and isRubyIdent(source[hl_word_start - 1])) hl_word_start -= 1;
    var hl_line_start: usize = 0;
    var hi: usize = 0;
    while (hi < hl_word_start) : (hi += 1) {
        if (source[hi] == '\n') hl_line_start = hi + 1;
    }
    const hl_col_0: i64 = @intCast(hl_word_start - hl_line_start);
    const hl_scope_id = resolveScopeId(self, file_id, word, cursor_line_1based_hl, hl_col_0);
    const is_hl_local = hl_scope_id != null;

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');
    var first = true;

    // Symbol definitions in this file
    const sym_stmt = try self.db.prepare(
        \\SELECT line, col FROM symbols WHERE file_id=? AND name=?
    );
    defer sym_stmt.finalize();
    sym_stmt.bind_int(1, file_id);
    sym_stmt.bind_text(2, word);
    while (try sym_stmt.step()) {
        if (!first) try w.writeByte(',');
        first = false;
        const hl = sym_stmt.column_int(0);
        const hc = sym_stmt.column_int(1);
        const hl_line_src = getLineSlice(source, @intCast(hl - 1));
        const hc_client = self.toClientCol(hl_line_src, @intCast(hc));
        try w.writeAll("{\"range\":{\"start\":{\"line\":");
        try w.print("{d}", .{hl - 1});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{hc_client});
        try w.writeAll("},\"end\":{\"line\":");
        try w.print("{d}", .{hl - 1});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{hc_client + @as(u32, @intCast(word.len))});
        try w.writeAll("}},\"kind\":1}");
    }

    // Refs in this file (scope-filtered for local vars to avoid cross-method highlights)
    const ref_stmt = if (is_hl_local) blk: {
        const sid = hl_scope_id.?;
        if (sid != 0) {
            const s = try self.db.prepare(
                \\SELECT line, col FROM refs WHERE file_id=? AND name=? AND scope_id=?
            );
            s.bind_int(1, file_id);
            s.bind_text(2, word);
            s.bind_int(3, sid);
            break :blk s;
        } else {
            const s = try self.db.prepare(
                \\SELECT line, col FROM refs WHERE file_id=? AND name=? AND scope_id IS NULL
            );
            s.bind_int(1, file_id);
            s.bind_text(2, word);
            break :blk s;
        }
    } else blk: {
        const s = try self.db.prepare(
            \\SELECT line, col FROM refs WHERE file_id=? AND name=?
        );
        s.bind_int(1, file_id);
        s.bind_text(2, word);
        break :blk s;
    };
    defer ref_stmt.finalize();
    while (try ref_stmt.step()) {
        if (!first) try w.writeByte(',');
        first = false;
        const hl = ref_stmt.column_int(0);
        const hc = ref_stmt.column_int(1);
        const hl_line_src = getLineSlice(source, @intCast(hl - 1));
        const hc_client = self.toClientCol(hl_line_src, @intCast(hc));
        try w.writeAll("{\"range\":{\"start\":{\"line\":");
        try w.print("{d}", .{hl - 1});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{hc_client});
        try w.writeAll("},\"end\":{\"line\":");
        try w.print("{d}", .{hl - 1});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{hc_client + @as(u32, @intCast(word.len))});
        const ref_kind: u32 = if (is_hl_local) 2 else 1;
        try w.print("}}}},\"kind\":{d}}}", .{ref_kind});
    }

    // Local var writes in this file (scope-filtered to avoid cross-method highlights)
    if (is_hl_local) {
        const sid = hl_scope_id.?;
        const lv_stmt = if (sid != 0)
            try self.db.prepare(
                \\SELECT line, col FROM local_vars WHERE file_id=? AND name=? AND scope_id=?
            )
        else
            try self.db.prepare(
                \\SELECT line, col FROM local_vars WHERE file_id=? AND name=? AND scope_id IS NULL
            );
        defer lv_stmt.finalize();
        lv_stmt.bind_int(1, file_id);
        lv_stmt.bind_text(2, word);
        if (sid != 0) lv_stmt.bind_int(3, sid);
        while (try lv_stmt.step()) {
            if (!first) try w.writeByte(',');
            first = false;
            const hl = lv_stmt.column_int(0);
            const hc = lv_stmt.column_int(1);
            const hl_line_src = getLineSlice(source, @intCast(hl - 1));
            const hc_client = self.toClientCol(hl_line_src, @intCast(hc));
            try w.writeAll("{\"range\":{\"start\":{\"line\":");
            try w.print("{d}", .{hl - 1});
            try w.writeAll(",\"character\":");
            try w.print("{d}", .{hc_client});
            try w.writeAll("},\"end\":{\"line\":");
            try w.print("{d}", .{hl - 1});
            try w.writeAll(",\"character\":");
            try w.print("{d}", .{hc_client + @as(u32, @intCast(word.len))});
            try w.writeAll("}},\"kind\":3}");
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

pub fn resolveScopeId(self: *Server, file_id: i64, name: []const u8, cursor_line_1based: i64, cursor_col: i64) ?i64 {
    // Check local_vars writes at/before cursor (closest one wins)
    const lv = self.db.prepare(
        \\SELECT scope_id FROM local_vars
        \\WHERE file_id=? AND name=? AND line<=?
        \\ORDER BY line DESC LIMIT 1
    ) catch return null;
    defer lv.finalize();
    lv.bind_int(1, file_id);
    lv.bind_text(2, name);
    lv.bind_int(3, cursor_line_1based);
    if (lv.step() catch false) {
        if (lv.column_type(0) != 5) return lv.column_int(0); // SQLITE_NULL=5
        return 0; // scope_id IS NULL means top-level local
    }
    // Check scoped refs at cursor position
    const rf = self.db.prepare(
        \\SELECT scope_id FROM refs
        \\WHERE file_id=? AND name=? AND line=? AND col<=? AND scope_id IS NOT NULL
        \\LIMIT 1
    ) catch return null;
    defer rf.finalize();
    rf.bind_int(1, file_id);
    rf.bind_text(2, name);
    rf.bind_int(3, cursor_line_1based);
    rf.bind_int(4, cursor_col);
    if (rf.step() catch false) {
        if (rf.column_type(0) != 5) return rf.column_int(0);
    }
    return null;
}

pub fn handleSelectionRange(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
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
        .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
        else => return emptyResult(msg),
    };
    _ = switch (pos.get("character") orelse return emptyResult(msg)) {
        .integer => |i| if (i >= 0) @as(u32, @intCast(i)) else return emptyResult(msg),
        else => return emptyResult(msg),
    };

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);

    const file_stmt = try self.db.prepare("SELECT id FROM files WHERE path=?");
    defer file_stmt.finalize();
    file_stmt.bind_text(1, path);
    if (!(try file_stmt.step())) return emptyResult(msg);
    const file_id = file_stmt.column_int(0);

    const db_line: i64 = @intCast(line + 1);
    // Find innermost symbol containing cursor
    const sym_stmt = try self.db.prepare(
        \\SELECT name, line, col, end_line FROM symbols WHERE file_id=? AND line<=? AND end_line>=? ORDER BY (end_line-line) ASC LIMIT 1
    );
    defer sym_stmt.finalize();
    sym_stmt.bind_int(1, file_id);
    sym_stmt.bind_int(2, db_line);
    sym_stmt.bind_int(3, db_line);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');

    if (try sym_stmt.step()) {
        const sym_name = sym_stmt.column_text(0);
        const sym_line = sym_stmt.column_int(1);
        const sym_col = sym_stmt.column_int(2);
        const sym_end = sym_stmt.column_int(3);

        // Word range (innermost)
        const word_end_col = sym_col + @as(i64, @intCast(sym_name.len));
        // Method body range (parent)
        try w.print("{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":999}}}},\"parent\":{{\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":999}}}}}}}}", .{
            sym_line - 1, sym_col,
            sym_line - 1, sym_line - 1,
            sym_end - 1,
        });
        _ = word_end_col;
    }

    try w.writeByte(']');
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}

pub fn handleLinkedEditingRange(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    if (self.isCancelled(msg.id)) return null;
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
    const pos = switch (obj.get("position") orelse return emptyResult(msg)) {
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

    const file_stmt = try self.db.prepare("SELECT id FROM files WHERE path=?");
    defer file_stmt.finalize();
    file_stmt.bind_text(1, path);
    if (!(try file_stmt.step())) return emptyResult(msg);
    const file_id = file_stmt.column_int(0);

    // Find scope_id for the variable at this position
    const scope_stmt = try self.db.prepare("SELECT scope_id FROM local_vars WHERE file_id=? AND name=? " ++
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
    const occ_stmt = try self.db.prepare(q);
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

pub fn handleCodeLens(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
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
    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);

    const file_stmt = try self.db.prepare("SELECT id FROM files WHERE path=?");
    defer file_stmt.finalize();
    file_stmt.bind_text(1, path);
    if (!(try file_stmt.step())) {
        var aw2 = std.Io.Writer.Allocating.init(self.alloc);
        try aw2.writer.writeAll("[]");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw2.toOwnedSlice(), .@"error" = null };
    }
    const file_id = file_stmt.column_int(0);

    const sym_stmt = try self.db.prepare(
        \\SELECT s.id, s.name, s.kind, s.line FROM symbols s WHERE s.file_id=?
        \\ORDER BY s.line LIMIT 5000
    );
    defer sym_stmt.finalize();
    sym_stmt.bind_int(1, file_id);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');
    var first = true;

    while (try sym_stmt.step()) {
        const sym_name = sym_stmt.column_text(1);
        const sym_kind = sym_stmt.column_text(2);
        const sym_line = sym_stmt.column_int(3);
        const lsp_line = sym_line - 1;

        const ref_stmt = self.db.prepare("SELECT (file_id=?) as local, COUNT(*) FROM refs WHERE name=? GROUP BY local") catch continue;
        defer ref_stmt.finalize();
        ref_stmt.bind_int(1, file_id);
        ref_stmt.bind_text(2, sym_name);
        var local_count: i64 = 0;
        var other_count: i64 = 0;
        while (try ref_stmt.step()) {
            const is_local = ref_stmt.column_int(0);
            const cnt = ref_stmt.column_int(1);
            if (is_local != 0) local_count += cnt else other_count += cnt;
        }
        const ref_count = local_count + other_count;

        if (!first) try w.writeByte(',');
        first = false;
        try w.print("{{\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}},\"command\":{{\"title\":", .{ lsp_line, lsp_line });
        const ref_label = if (other_count > 0)
            try std.fmt.allocPrint(self.alloc, "{d} refs ({d} files)", .{ ref_count, other_count })
        else
            try std.fmt.allocPrint(self.alloc, "{d} ref{s}", .{ ref_count, if (ref_count == 1) "" else "s" });
        defer self.alloc.free(ref_label);
        try writeEscapedJson(w, ref_label);
        try w.writeAll(",\"command\":\"refract.showReferences\",\"arguments\":[");
        try writeEscapedJson(w, uri);
        try w.print(",{{\"line\":{d},\"character\":0}}]}}}}", .{lsp_line});

        if (std.mem.eql(u8, sym_kind, "test") or std.mem.startsWith(u8, sym_name, "test_")) {
            try w.writeByte(',');
            try w.print("{{\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}},\"command\":{{\"title\":\"\u{25b6} Run\",\"command\":\"refract.runTest\",\"arguments\":[", .{ lsp_line, lsp_line });
            try writeEscapedJson(w, uri);
            try w.print(",{d}]}}}}", .{sym_line});
        }
    }
    try w.writeByte(']');
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}
