const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const types = @import("types.zig");
const db_mod = @import("../db.zig");

const extractTextDocumentUri = S.extractTextDocumentUri;
const extractParamsObject = S.extractParamsObject;
const extractPosition = S.extractPosition;
const uriToPath = S.uriToPath;
const emptyResult = S.emptyResult;
const writeEscapedJsonContent = S.writeEscapedJsonContent;
const writePathAsUri = S.writePathAsUri;
const getLineSlice = S.getLineSlice;
const extractWord = S.extractWord;
const writeEscapedJson = S.writeEscapedJson;
const emitSelRange = S.emitSelRange;
const utf8ColToUtf16 = S.utf8ColToUtf16;
const matchesCamelInitials = S.matchesCamelInitials;
const isSubsequence = S.isSubsequence;
const buildQueryPattern = S.buildQueryPattern;
const buildPrefixPattern = S.buildPrefixPattern;
const frcGet = S.frcGet;

pub fn handleWorkspaceSymbol(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    self.flushIncrPaths();
    self.flushDirtyUris();
    {
        // Bounded wait so workspace/symbol doesn't query a half-built index
        // immediately after server start (or after forceReindex).
        var waited_ms: u32 = 0;
        while (waited_ms < 200 and !self.bg_indexing_done.load(.acquire)) : (waited_ms += 10) {
            {
                var _sleep_ts: std.c.timespec = .{ .sec = @intCast((10 * std.time.ns_per_ms) / std.time.ns_per_s), .nsec = @intCast((10 * std.time.ns_per_ms) % std.time.ns_per_s) };
                _ = std.c.nanosleep(&_sleep_ts, null);
            }
        }
    }
    if (self.isCancelled(msg.id)) return self.cancelledResponse(msg.id);
    self.db_mutex.lockUncancelable(std.Options.debug_io);
    defer self.db_mutex.unlock(std.Options.debug_io);
    const query = blk: {
        if (msg.params) |params| {
            switch (params) {
                .object => |obj| {
                    if (obj.get("query")) |q| {
                        switch (q) {
                            .string => |s| break :blk s,
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        break :blk "";
    };

    const pattern = try buildQueryPattern(self.alloc, query);
    defer self.alloc.free(pattern);
    const prefix_pattern = try buildPrefixPattern(self.alloc, query);
    defer self.alloc.free(prefix_pattern);

    // Parse optional LSP symbol kind filter (1=File,2=Module,3=Namespace,4=Package,5=Class,
    // 6=Method,7=Property,8=Field,9=Constructor,10=Enum,11=Interface,12=Function,
    // 13=Variable,14=Constant,15=String,16=Number,17=Boolean,18=Array,23=Struct,26=TypeParameter)
    // Map LSP kind → DB kind string. null = no filter.
    const lsp_kind_filter: ?[]const u8 = blk: {
        if (msg.params) |params| {
            switch (params) {
                .object => |obj| {
                    if (obj.get("filter")) |filter_val| {
                        switch (filter_val) {
                            .object => |fobj| {
                                if (fobj.get("kind")) |kv| {
                                    switch (kv) {
                                        .integer => |k| break :blk switch (k) {
                                            2 => @as(?[]const u8, "module"),
                                            5 => "class",
                                            6 => "def",
                                            12 => "classdef",
                                            else => null,
                                        },
                                        else => {},
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        break :blk null;
    };

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');
    var first = true;
    var result_count: usize = 0;
    var frc_ws: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var frc_it = frc_ws.iterator();
        while (frc_it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        frc_ws.deinit(self.alloc);
    }

    // @-prefixed word: search local_vars for instance variable type hints
    if (query.len > 0 and query[0] == '@') {
        const iv_stmt = try self.db.prepare(
            \\SELECT DISTINCT lv.name, lv.line, lv.col, f.path
            \\FROM local_vars lv JOIN files f ON lv.file_id=f.id
            \\WHERE lv.name LIKE ? ESCAPE '\' AND lv.name LIKE '@%' AND f.is_gem = 0
            \\LIMIT 100
        );
        defer iv_stmt.finalize();
        iv_stmt.bind_text(1, pattern);
        while (try iv_stmt.step()) {
            if (!first) try w.writeByte(',');
            first = false;
            result_count += 1;
            const name = iv_stmt.column_text(0);
            const line = iv_stmt.column_int(1);
            const col = iv_stmt.column_int(2);
            const path = iv_stmt.column_text(3);
            const start_char = self.toClientColFromPath(&frc_ws, path, line - 1, col);
            try w.writeAll("{\"name\":");
            try writeEscapedJson(w, name);
            try w.print(",\"kind\":7,\"location\":{{\"uri\":\"file://", .{});
            try writePathAsUri(w, path);
            try w.writeAll("\",\"range\":{\"start\":{\"line\":");
            try w.print("{d}", .{line - 1});
            try w.writeAll(",\"character\":");
            try w.print("{d}", .{start_char});
            try w.writeAll("},\"end\":{\"line\":");
            try w.print("{d}", .{line - 1});
            try w.writeAll(",\"character\":");
            try w.print("{d}", .{start_char + @as(u32, @intCast(name.len))});
            try w.writeAll("}}}}");
        }
    } else if (query.len > 0 and query[0] == '$') {
        // $-prefixed query → search local_vars for global variables
        const gv_ws_stmt = try self.db.prepare(
            \\SELECT DISTINCT lv.name, lv.line, lv.col, f.path
            \\FROM local_vars lv JOIN files f ON lv.file_id=f.id
            \\WHERE lv.name LIKE ? ESCAPE '\' AND lv.name LIKE '$%' AND f.is_gem = 0
            \\ORDER BY lv.name LIMIT 100
        );
        defer gv_ws_stmt.finalize();
        gv_ws_stmt.bind_text(1, pattern);
        while (try gv_ws_stmt.step()) {
            if (!first) try w.writeByte(',');
            first = false;
            result_count += 1;
            const gv_name = gv_ws_stmt.column_text(0);
            const gv_line = gv_ws_stmt.column_int(1);
            const gv_col = gv_ws_stmt.column_int(2);
            const gv_path = gv_ws_stmt.column_text(3);
            const gv_start_char = self.toClientColFromPath(&frc_ws, gv_path, gv_line - 1, gv_col);
            try w.writeAll("{\"name\":");
            try writeEscapedJson(w, gv_name);
            try w.print(",\"kind\":13,\"location\":{{\"uri\":\"file://", .{});
            try writePathAsUri(w, gv_path);
            try w.writeAll("\",\"range\":{\"start\":{\"line\":");
            try w.print("{d}", .{gv_line - 1});
            try w.writeAll(",\"character\":");
            try w.print("{d}", .{gv_start_char});
            try w.writeAll("},\"end\":{\"line\":");
            try w.print("{d}", .{gv_line - 1});
            try w.writeAll(",\"character\":");
            try w.print("{d}", .{gv_start_char + @as(u32, @intCast(gv_name.len))});
            try w.writeAll("}}}}");
        }
    } else {
        // Build SQL dynamically to apply optional kind filter.
        // Relevance-aware ORDER BY: exact match → prefix match → rest, then length, then name.
        var sql_buf: [1024]u8 = undefined;
        const sql = if (query.len > 0) blk: {
            if (lsp_kind_filter) |kf| {
                _ = kf;
                break :blk try std.fmt.bufPrintZ(&sql_buf, "SELECT s.name, s.kind, s.line, s.col, f.path, s.parent_name FROM symbols s JOIN files f ON s.file_id = f.id WHERE s.name LIKE ? ESCAPE '\\' AND s.kind = ? AND f.is_gem = 0 ORDER BY CASE WHEN lower(s.name)=lower(?) THEN 0 WHEN s.name LIKE ? ESCAPE '\\' THEN 1 ELSE 2 END, length(s.name), s.name LIMIT 500", .{});
            } else {
                break :blk try std.fmt.bufPrintZ(&sql_buf, "SELECT s.name, s.kind, s.line, s.col, f.path, s.parent_name FROM symbols s JOIN files f ON s.file_id = f.id WHERE s.name LIKE ? ESCAPE '\\' AND f.is_gem = 0 ORDER BY CASE WHEN lower(s.name)=lower(?) THEN 0 WHEN s.name LIKE ? ESCAPE '\\' THEN 1 ELSE 2 END, length(s.name), s.name LIMIT 500", .{});
            }
        } else "SELECT s.name, s.kind, s.line, s.col, f.path, s.parent_name FROM symbols s JOIN files f ON s.file_id = f.id WHERE f.is_gem = 0 ORDER BY s.name LIMIT 100";
        const stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        if (query.len > 0) {
            stmt.bind_text(1, prefix_pattern);
            if (lsp_kind_filter) |kf| {
                stmt.bind_text(2, kf);
                stmt.bind_text(3, query); // exact match check
                stmt.bind_text(4, prefix_pattern); // prefix match check
            } else {
                stmt.bind_text(2, query); // exact match check
                stmt.bind_text(3, prefix_pattern); // prefix match check
            }
        }
        while (try stmt.step()) {
            if (!first) try w.writeByte(',');
            first = false;
            result_count += 1;
            const name = stmt.column_text(0);
            const kind_str = stmt.column_text(1);
            const line = stmt.column_int(2);
            const col = stmt.column_int(3);
            const path = stmt.column_text(4);
            const cname = stmt.column_text(5);
            const kind_num: u8 = if (std.mem.eql(u8, kind_str, "class")) 5 else if (std.mem.eql(u8, kind_str, "module")) 2 else if (std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) 6 else if (std.mem.eql(u8, kind_str, "constant")) 13 else 14;
            const start_char = self.toClientColFromPath(&frc_ws, path, line - 1, col);
            try w.writeAll("{\"name\":");
            try writeEscapedJson(w, name);
            try w.print(",\"kind\":{d},\"location\":{{\"uri\":\"file://", .{kind_num});
            try writePathAsUri(w, path);
            try w.writeAll("\",\"range\":{\"start\":{\"line\":");
            try w.print("{d}", .{line - 1});
            try w.writeAll(",\"character\":");
            try w.print("{d}", .{start_char});
            try w.writeAll("},\"end\":{\"line\":");
            try w.print("{d}", .{line - 1});
            try w.writeAll(",\"character\":");
            try w.print("{d}", .{start_char + @as(u32, @intCast(name.len))});
            try w.writeAll("}}}");
            if (cname.len > 0) {
                try w.writeAll(",\"containerName\":");
                try writeEscapedJson(w, cname);
            }
            try w.writeByte('}');
        }

        // Infix fallback: add symbols where query appears anywhere but not as prefix
        if (result_count < 10 and query.len > 0) {
            const infix_stmt = try self.db.prepare(
                \\SELECT s.name, s.kind, s.line, s.col, f.path, s.parent_name
                \\FROM symbols s JOIN files f ON s.file_id = f.id
                \\WHERE s.name LIKE ? ESCAPE '\' AND s.name NOT LIKE ? ESCAPE '\' AND f.is_gem = 0
                \\LIMIT 100
            );
            defer infix_stmt.finalize();
            infix_stmt.bind_text(1, pattern);
            infix_stmt.bind_text(2, prefix_pattern);
            while (try infix_stmt.step()) {
                if (!first) try w.writeByte(',');
                first = false;
                const name = infix_stmt.column_text(0);
                const kind_str = infix_stmt.column_text(1);
                const line = infix_stmt.column_int(2);
                const col = infix_stmt.column_int(3);
                const path = infix_stmt.column_text(4);
                const cname = infix_stmt.column_text(5);
                const kind_num: u8 = if (std.mem.eql(u8, kind_str, "class")) 5 else if (std.mem.eql(u8, kind_str, "module")) 2 else if (std.mem.eql(u8, kind_str, "def")) 6 else if (std.mem.eql(u8, kind_str, "constant")) 13 else 14;
                const start_char = self.toClientColFromPath(&frc_ws, path, line - 1, col);
                try w.writeAll("{\"name\":");
                try writeEscapedJson(w, name);
                try w.print(",\"kind\":{d},\"location\":{{\"uri\":\"file://", .{kind_num});
                try writePathAsUri(w, path);
                try w.writeAll("\",\"range\":{\"start\":{\"line\":");
                try w.print("{d}", .{line - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{start_char});
                try w.writeAll("},\"end\":{\"line\":");
                try w.print("{d}", .{line - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{start_char + @as(u32, @intCast(name.len))});
                try w.writeAll("}}}");
                if (cname.len > 0) {
                    try w.writeAll(",\"containerName\":");
                    try writeEscapedJson(w, cname);
                }
                try w.writeByte('}');
            }
        }

        // Fuzzy: CamelCase initials + subsequence (for queries like "UC" → UserController)
        if (result_count < 10 and query.len >= 2) {
            const fuzzy_exclude = try buildQueryPattern(self.alloc, query);
            defer self.alloc.free(fuzzy_exclude);
            const fuzzy_stmt = try self.db.prepare(
                \\SELECT s.name, s.kind, s.line, s.col, f.path, s.parent_name
                \\FROM symbols s JOIN files f ON s.file_id = f.id
                \\WHERE s.name NOT LIKE ? ESCAPE '\' AND f.is_gem = 0
                \\LIMIT 500
            );
            defer fuzzy_stmt.finalize();
            fuzzy_stmt.bind_text(1, fuzzy_exclude);
            while (try fuzzy_stmt.step()) {
                const fname = fuzzy_stmt.column_text(0);
                if (!matchesCamelInitials(query, fname) and !isSubsequence(query, fname)) continue;
                if (!first) try w.writeByte(',');
                first = false;
                result_count += 1;
                const fkind_str = fuzzy_stmt.column_text(1);
                const fline = fuzzy_stmt.column_int(2);
                const fcol = fuzzy_stmt.column_int(3);
                const fpath = fuzzy_stmt.column_text(4);
                const fcname = fuzzy_stmt.column_text(5);
                const fkind_num: u8 = if (std.mem.eql(u8, fkind_str, "class")) 5 else if (std.mem.eql(u8, fkind_str, "module")) 2 else if (std.mem.eql(u8, fkind_str, "def") or std.mem.eql(u8, fkind_str, "classdef")) 6 else if (std.mem.eql(u8, fkind_str, "constant")) 13 else 14;
                const fstart_char = self.toClientColFromPath(&frc_ws, fpath, fline - 1, fcol);
                try w.writeAll("{\"name\":");
                try writeEscapedJson(w, fname);
                try w.print(",\"kind\":{d},\"location\":{{\"uri\":\"file://", .{fkind_num});
                try writePathAsUri(w, fpath);
                try w.writeAll("\",\"range\":{\"start\":{\"line\":");
                try w.print("{d}", .{fline - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{fstart_char});
                try w.writeAll("},\"end\":{\"line\":");
                try w.print("{d}", .{fline - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{fstart_char + @as(u32, @intCast(fname.len))});
                try w.writeAll("}}}");
                if (fcname.len > 0) {
                    try w.writeAll(",\"containerName\":");
                    try writeEscapedJson(w, fcname);
                }
                try w.writeByte('}');
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

pub fn handleDocumentSymbol(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    if (self.isCancelled(msg.id)) return self.cancelledResponse(msg.id);
    self.db_mutex.lockUncancelable(std.Options.debug_io);
    defer self.db_mutex.unlock(std.Options.debug_io);
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
    if (!self.pathInBounds(path)) return emptyResult(msg);

    const stmt = try self.db.prepare(
        \\SELECT s.name, s.kind, s.line, s.col, s.return_type, s.end_line
        \\FROM symbols s JOIN files f ON s.file_id = f.id
        \\WHERE f.path = ? ORDER BY s.line
    );
    defer stmt.finalize();
    stmt.bind_text(1, path);

    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const src_opt: ?[]u8 = self.readSourceForUri(uri, path) catch null;
    defer if (src_opt) |s| self.alloc.free(s);
    const doc_src = src_opt orelse "";

    const DocSym = struct { name: []const u8, kind: []const u8, line: i64, col: i64, return_type: []const u8, end_line: i64 };
    var syms = std.ArrayList(DocSym).empty;
    while (try stmt.step()) {
        try syms.append(a, .{
            .name = try a.dupe(u8, stmt.column_text(0)),
            .kind = try a.dupe(u8, stmt.column_text(1)),
            .line = stmt.column_int(2),
            .col = stmt.column_int(3),
            .return_type = try a.dupe(u8, stmt.column_text(4)),
            .end_line = stmt.column_int(5),
        });
    }

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');

    var first_top = true;
    var si: usize = 0;
    while (si < syms.items.len) {
        const s = syms.items[si];
        const is_container = std.mem.eql(u8, s.kind, "class") or std.mem.eql(u8, s.kind, "module");
        if (is_container) {
            var next_ci: usize = si + 1;
            while (next_ci < syms.items.len) : (next_ci += 1) {
                const nk = syms.items[next_ci].kind;
                if (std.mem.eql(u8, nk, "class") or std.mem.eql(u8, nk, "module")) break;
            }
            const end_line: i64 = @max(s.line + 1, if (s.end_line > 0) s.end_line else if (next_ci < syms.items.len) syms.items[next_ci].line - 1 else s.line + 50);
            const kind_num: u8 = if (std.mem.eql(u8, s.kind, "class")) 5 else 2;
            if (!first_top) try w.writeByte(',');
            first_top = false;
            try w.writeAll("{\"name\":");
            try writeEscapedJson(w, s.name);
            try w.print(",\"kind\":{d}", .{kind_num});
            try w.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}}", .{ s.line - 1, end_line - 1 });
            emitSelRange(w, doc_src, self, s.line, s.col, s.name);
            try w.writeAll(",\"children\":[");
            var first_child = true;
            var ci: usize = si + 1;
            while (ci < next_ci) : (ci += 1) {
                const c = syms.items[ci];
                if (std.mem.eql(u8, c.kind, "def") or std.mem.eql(u8, c.kind, "classdef") or std.mem.eql(u8, c.kind, "constant")) {
                    const ck: u8 = if (std.mem.eql(u8, c.kind, "constant")) 13 else 6;
                    if (!first_child) try w.writeByte(',');
                    first_child = false;
                    try w.writeAll("{\"name\":");
                    try writeEscapedJson(w, c.name);
                    try w.print(",\"kind\":{d}", .{ck});
                    if (c.return_type.len > 0) {
                        try w.writeAll(",\"detail\":");
                        try writeEscapedJson(w, c.return_type);
                    }
                    const c_end: i64 = @max(c.line, if (c.end_line > 0) c.end_line - 1 else c.line - 1);
                    try w.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}}", .{ c.line - 1, c_end });
                    emitSelRange(w, doc_src, self, c.line, c.col, c.name);
                    try w.writeByte('}');
                }
            }
            try w.writeAll("]}");
            si = next_ci;
        } else {
            const kind_num: u8 = if (std.mem.eql(u8, s.kind, "def") or std.mem.eql(u8, s.kind, "classdef")) 6 else if (std.mem.eql(u8, s.kind, "constant")) 13 else 14;
            if (!first_top) try w.writeByte(',');
            first_top = false;
            try w.writeAll("{\"name\":");
            try writeEscapedJson(w, s.name);
            try w.print(",\"kind\":{d}", .{kind_num});
            if (s.return_type.len > 0) {
                try w.writeAll(",\"detail\":");
                try writeEscapedJson(w, s.return_type);
            }
            const s_end: i64 = @max(s.line, if (s.end_line > 0) s.end_line - 1 else s.line - 1);
            try w.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}}", .{ s.line - 1, s_end });
            emitSelRange(w, doc_src, self, s.line, s.col, s.name);
            try w.writeByte('}');
            si += 1;
        }
    }

    try w.writeByte(']');
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}
