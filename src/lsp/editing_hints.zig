const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const types = @import("types.zig");
const db_mod = @import("../db.zig");
const prism_mod = @import("../prism.zig");
const erb_mapping = @import("erb_mapping.zig");
const refactor = @import("refactor.zig");
const editing = @import("editing.zig");

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

pub fn handleSignatureHelp(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
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

    const sym_stmt = try self.queryDb().prepare(
        \\SELECT id, return_type, doc FROM symbols WHERE name = ? AND kind = 'def' LIMIT 1
    );
    defer sym_stmt.finalize();
    sym_stmt.bind_text(1, method_name);
    if (!(try sym_stmt.step())) return emptyResult(msg);
    const symbol_id = sym_stmt.column_int(0);

    const param_stmt = try self.queryDb().prepare(
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

    var param_labels = std.ArrayList([]u8).empty;
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

    const file_stmt = try self.queryDb().prepare("SELECT id FROM files WHERE path = ?");
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

    const stmt = try self.queryDb().prepare(
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
    const def_stmt = try self.queryDb().prepare(
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
                    .db = self.queryDb(),
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
    if (self.isCancelled(msg.id)) return self.cancelledResponse(msg.id);
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
        const trimmed = std.mem.trimStart(u8, line_src, " \t");
        const trimmed_offset = @intFromPtr(trimmed.ptr) - @intFromPtr(line_src.ptr);

        const rel_prefix = "require_relative";
        const req_prefix = "require";
        var rest: ?[]const u8 = null;

        if (std.mem.startsWith(u8, trimmed, rel_prefix)) {
            rest = std.mem.trimStart(u8, trimmed[rel_prefix.len..], " \t");
        } else if (std.mem.startsWith(u8, trimmed, req_prefix)) {
            rest = std.mem.trimStart(u8, trimmed[req_prefix.len..], " \t");
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

                            if (resolveRequireTarget(self.alloc, self.queryDb(), source, str_start_offset, path)) |target_path| {
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

    const file_stmt = try self.queryDb().prepare("SELECT id FROM files WHERE path = ?");
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
    const hl_scope_id = editing.resolveScopeId(self, file_id, word, cursor_line_1based_hl, hl_col_0);
    const is_hl_local = hl_scope_id != null;

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');
    var first = true;

    // Symbol definitions in this file
    const sym_stmt = try self.queryDb().prepare(
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
            const s = try self.queryDb().prepare(
                \\SELECT line, col FROM refs WHERE file_id=? AND name=? AND scope_id=?
            );
            s.bind_int(1, file_id);
            s.bind_text(2, word);
            s.bind_int(3, sid);
            break :blk s;
        } else {
            const s = try self.queryDb().prepare(
                \\SELECT line, col FROM refs WHERE file_id=? AND name=? AND scope_id IS NULL
            );
            s.bind_int(1, file_id);
            s.bind_text(2, word);
            break :blk s;
        }
    } else blk: {
        const s = try self.queryDb().prepare(
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
            try self.queryDb().prepare(
                \\SELECT line, col FROM local_vars WHERE file_id=? AND name=? AND scope_id=?
            )
        else
            try self.queryDb().prepare(
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

pub fn handleCodeLens(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
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

    const file_stmt = try self.queryDb().prepare("SELECT id FROM files WHERE path=?");
    defer file_stmt.finalize();
    file_stmt.bind_text(1, path);
    if (!(try file_stmt.step())) {
        var aw2 = std.Io.Writer.Allocating.init(self.alloc);
        try aw2.writer.writeAll("[]");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw2.toOwnedSlice(), .@"error" = null };
    }
    const file_id = file_stmt.column_int(0);

    const sym_stmt = try self.queryDb().prepare(
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
        if (self.bg_cancelled.load(.acquire)) break;
        const sym_name = sym_stmt.column_text(1);
        const sym_kind = sym_stmt.column_text(2);
        const sym_line = sym_stmt.column_int(3);
        const lsp_line = sym_line - 1;

        const ref_stmt = self.queryDb().prepare("SELECT (file_id=?) as local, COUNT(*) FROM refs WHERE name=? GROUP BY local") catch continue;
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
