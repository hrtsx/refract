const std = @import("std");
const db_mod = @import("../db.zig");
const refactor_mod = @import("../lsp/refactor.zig");
const overlay = @import("../lsp/overlay.zig");
const git_branch = @import("../lsp/git_branch.zig");
const indexer = @import("../indexer/index.zig");
const build_meta = @import("build_meta");
const server = @import("server.zig");
const Server = server.Server;
const overlayTable = Server.overlayTable;
const nowS = Server.nowS;
const gateMsg = Server.gateMsg;
const nowUs = Server.nowUs;
const MAX_LINE_BODY_BYTES = server.MAX_LINE_BODY_BYTES;
const countLines = server.countLines;
const ftsQuote = server.ftsQuote;
const getIntArg = server.getIntArg;
const getStrArg = server.getStrArg;
const normalizeFileArg = server.normalizeFileArg;
const regexMatchLine = server.regexMatchLine;
const splitQualified = server.splitQualified;
const stepLog = server.stepLog;
const validateGlobPattern = server.validateGlobPattern;
const writeJsonStr = server.writeJsonStr;
const writeJsonStrCapped = server.writeJsonStrCapped;

pub fn workspaceSymbols(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const query = getStrArg(args, "query") orelse return srv.buildToolError(id, "missing 'query'");
    const kind_filter = getStrArg(args, "kind");
    var offset = getIntArg(args, "offset") orelse 0;
    if (offset < 0) offset = 0;

    const q_trim = std.mem.trim(u8, query, " \t\r\n");
    const use_fts = q_trim.len >= 3;

    // Substring search ('%q%') can't use the name B-tree (leading wildcard) and
    // full-scans symbols. The trigram FTS makes it index-backed; LIKE remains
    // for queries shorter than the 3-char trigram floor.
    const match_or_like = if (use_fts)
        ftsQuote(srv.alloc, q_trim) catch return srv.buildToolError(id, "OOM")
    else
        std.fmt.allocPrint(srv.alloc, "%{s}%", .{query}) catch return srv.buildToolError(id, "OOM");
    defer srv.alloc.free(match_or_like);

    // Rank by kind first — classes/modules, then constants/defs — so a query for
    // "Product" surfaces the Spree::Product class above local variables and RSpec
    // example descriptions (both indexed as symbols but rarely what a search wants).
    // Within a kind tier: exact-name hit, then shorter names, then alphabetical.
    // ?4 is the trimmed query for the exact-match tiebreak; ?5 is the offset.
    const stmt = srv.db.prepare(if (use_fts)
        \\SELECT s.name, s.kind, s.parent_name, s.return_type, f.path, s.line
        \\FROM symbols_fts
        \\JOIN symbols s ON s.id = symbols_fts.rowid
        \\JOIN files f ON f.id = s.file_id
        \\WHERE symbols_fts MATCH ?1 AND (?2 IS NULL OR s.kind = ?3)
        \\ORDER BY CASE s.kind WHEN 'class' THEN 0 WHEN 'module' THEN 0 WHEN 'constant' THEN 1 WHEN 'classdef' THEN 1 WHEN 'def' THEN 1 WHEN 'variable' THEN 8 WHEN 'test' THEN 9 ELSE 4 END, (s.name = ?4) DESC, (substr(s.name, 1, 1) GLOB '[A-Z]') DESC, length(s.name), s.name LIMIT 501 OFFSET ?5
    else
        \\SELECT s.name, s.kind, s.parent_name, s.return_type, f.path, s.line
        \\FROM symbols s JOIN files f ON f.id = s.file_id
        \\WHERE s.name LIKE ?1 AND (?2 IS NULL OR s.kind = ?3)
        \\ORDER BY CASE s.kind WHEN 'class' THEN 0 WHEN 'module' THEN 0 WHEN 'constant' THEN 1 WHEN 'classdef' THEN 1 WHEN 'def' THEN 1 WHEN 'variable' THEN 8 WHEN 'test' THEN 9 ELSE 4 END, (s.name = ?4) DESC, (substr(s.name, 1, 1) GLOB '[A-Z]') DESC, length(s.name), s.name LIMIT 501 OFFSET ?5
    ) catch return srv.buildToolError(id, "database error");
    defer stmt.finalize();
    stmt.bind_text(1, match_or_like);
    if (kind_filter) |kf| {
        stmt.bind_text(2, kf);
        stmt.bind_text(3, kf);
    } else {
        stmt.bind_null(2);
        stmt.bind_null(3);
    }
    stmt.bind_text(4, q_trim);
    stmt.bind_int(5, offset);

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"symbols\":[");

    var row_count: usize = 0;
    while (stmt.step() catch |e| stepLog(e)) {
        if (row_count >= 500) break;
        if (row_count > 0) try w.writeByte(',');
        row_count += 1;
        const sname = stmt.column_text(0);
        const skind = stmt.column_text(1);
        const sparent = stmt.column_text(2);
        const sret = stmt.column_text(3);
        const spath = stmt.column_text(4);
        const sline = stmt.column_int(5);
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, sname);
        try w.writeAll(",\"kind\":");
        try writeJsonStr(w, skind);
        try w.writeAll(",\"parent_name\":");
        if (sparent.len > 0) try writeJsonStr(w, sparent) else try w.writeAll("null");
        try w.writeAll(",\"return_type\":");
        if (sret.len > 0) try writeJsonStr(w, sret) else try w.writeAll("null");
        try w.writeAll(",\"file\":");
        try writeJsonStr(w, spath);
        try w.print(",\"line\":{d}}}", .{sline});
    }
    const has_more = stmt.step() catch false;
    try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

pub fn listByKind(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const kind = getStrArg(args, "kind") orelse return srv.buildToolError(id, "missing 'kind'");
    const allowed_kinds = [_][]const u8{ "class", "module", "def", "constant", "association", "route_helper" };
    var kind_ok = false;
    for (allowed_kinds) |k| {
        if (std.mem.eql(u8, kind, k)) {
            kind_ok = true;
            break;
        }
    }
    if (!kind_ok) return srv.buildToolError(id, "invalid 'kind' (expected class|module|def|constant|association|route_helper)");
    const name_filter = getStrArg(args, "name_filter");
    var offset = getIntArg(args, "offset") orelse 0;
    if (offset < 0) offset = 0;

    const like_pat: ?[]u8 = if (name_filter) |nf|
        std.fmt.allocPrint(srv.alloc, "{s}%", .{nf}) catch null
    else
        null;
    defer if (like_pat) |lp| srv.alloc.free(lp);

    const stmt = srv.db.prepare(
        \\SELECT DISTINCT s.name, f.path, s.line
        \\FROM symbols s JOIN files f ON f.id = s.file_id
        \\WHERE s.kind = ? AND (? IS NULL OR s.name LIKE ?) AND f.is_gem = 0
        \\ORDER BY s.name LIMIT 201 OFFSET ?
    ) catch return srv.buildToolError(id, "database error");
    defer stmt.finalize();
    stmt.bind_text(1, kind);
    if (like_pat) |lp| {
        stmt.bind_text(2, lp);
        stmt.bind_text(3, lp);
    } else {
        stmt.bind_null(2);
        stmt.bind_null(3);
    }
    stmt.bind_int(4, offset);

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"kind\":");
    try writeJsonStr(w, kind);
    try w.writeAll(",\"symbols\":[");

    var row_count: usize = 0;
    while (stmt.step() catch |e| stepLog(e)) {
        if (row_count >= 200) break;
        if (row_count > 0) try w.writeByte(',');
        row_count += 1;
        const sname = stmt.column_text(0);
        const spath = stmt.column_text(1);
        const sline = stmt.column_int(2);
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, sname);
        try w.writeAll(",\"file\":");
        try writeJsonStr(w, spath);
        try w.print(",\"line\":{d}}}", .{sline});
    }
    const has_more = stmt.step() catch false;
    try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

pub fn getFileOverview(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const file = getStrArg(args, "file") orelse return srv.buildToolError(id, "missing 'file'");
    const resolved = normalizeFileArg(srv.alloc, file) orelse return srv.buildToolError(id, "cannot resolve file path");
    defer srv.alloc.free(resolved);

    const stmt = srv.db.prepare(
        \\SELECT name, kind, line, parent_name, return_type, visibility
        \\FROM symbols
        \\WHERE file_id = (SELECT id FROM files WHERE path = ?)
        \\ORDER BY line
        \\LIMIT 500
    ) catch return srv.buildToolError(id, "database error");
    defer stmt.finalize();
    stmt.bind_text(1, resolved);

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"file\":");
    try writeJsonStr(w, file);
    try w.writeAll(",\"symbols\":[");

    var row_count: usize = 0;
    while (stmt.step() catch |e| stepLog(e)) {
        if (row_count > 0) try w.writeByte(',');
        row_count += 1;
        const sname = stmt.column_text(0);
        const skind = stmt.column_text(1);
        const sline = stmt.column_int(2);
        const sparent = stmt.column_text(3);
        const sret = stmt.column_text(4);
        const svis = stmt.column_text(5);
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, sname);
        try w.writeAll(",\"kind\":");
        try writeJsonStr(w, skind);
        try w.print(",\"line\":{d},\"parent_name\":", .{sline});
        if (sparent.len > 0) try writeJsonStr(w, sparent) else try w.writeAll("null");
        try w.writeAll(",\"return_type\":");
        if (sret.len > 0) try writeJsonStr(w, sret) else try w.writeAll("null");
        try w.writeAll(",\"visibility\":");
        try writeJsonStr(w, svis);
        try w.writeByte('}');
    }
    try w.print("],\"has_more\":{s}}}", .{if (row_count >= 500) "true" else "false"});
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

pub fn getSymbolSource(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const class_name = getStrArg(args, "class_name") orelse return srv.buildToolError(id, "missing 'class_name'");
    const method_name = getStrArg(args, "method_name") orelse return srv.buildToolError(id, "missing 'method_name'");

    const sym_stmt = srv.db.prepare(
        \\SELECT f.path, s.line, s.end_line
        \\FROM symbols s JOIN files f ON f.id = s.file_id
        \\WHERE s.parent_name = ? AND s.name = ?
        \\  AND s.kind IN ('def','classdef')
        \\LIMIT 1
    ) catch return srv.buildToolError(id, "database error");
    defer sym_stmt.finalize();
    sym_stmt.bind_text(1, class_name);
    sym_stmt.bind_text(2, method_name);

    if (!(sym_stmt.step() catch |e| stepLog(e))) {
        return srv.buildToolResult(id, "{\"found\":false}");
    }
    const fpath = sym_stmt.column_text(0);
    const sym_line = sym_stmt.column_int(1);
    var end_line = sym_stmt.column_int(2);
    if (end_line == 0) end_line = sym_line;

    const raw = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, fpath, srv.alloc, std.Io.Limit.limited(8 * 1024 * 1024)) catch
        return srv.buildToolError(id, "cannot read file");
    defer srv.alloc.free(raw);

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"found\":true,\"class\":");
    try writeJsonStr(w, class_name);
    try w.writeAll(",\"method\":");
    try writeJsonStr(w, method_name);
    try w.writeAll(",\"file\":");
    try writeJsonStr(w, fpath);
    try w.print(",\"line\":{d},\"end_line\":{d},\"source\":", .{ sym_line, end_line });

    // Extract lines sym_line..end_line (1-based), cap at 200 lines
    const cap_end = @min(end_line, sym_line + 199);
    var src_buf = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer src_buf.deinit();
    const sw = &src_buf.writer;
    var lineno: i64 = 1;
    var i: usize = 0;
    while (i <= raw.len) {
        const line_start = i;
        while (i < raw.len and raw[i] != '\n') i += 1;
        const line_end = i;
        if (lineno >= sym_line and lineno <= cap_end) {
            try sw.print("{d}: ", .{lineno});
            try sw.writeAll(raw[line_start..line_end]);
            try sw.writeByte('\n');
        }
        if (i >= raw.len) break;
        i += 1; // skip '\n'
        lineno += 1;
        if (lineno > cap_end) break;
    }
    const src_text = try src_buf.toOwnedSlice();
    defer srv.alloc.free(src_text);
    try writeJsonStr(w, src_text);
    try w.writeByte('}');
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

pub fn grepSource(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const query = getStrArg(args, "query") orelse return srv.buildToolError(id, "missing 'query'");
    if (query.len == 0) return srv.buildToolError(id, "'query' must be non-empty");
    const file_pattern = getStrArg(args, "file_pattern");
    if (file_pattern) |fp| {
        if (validateGlobPattern(fp)) |err_reason| {
            const err_msg = try std.fmt.allocPrint(srv.alloc, "invalid file_pattern: {s}", .{err_reason});
            defer srv.alloc.free(err_msg);
            return srv.buildToolError(id, err_msg);
        }
    }
    const ctx_n: usize = @intCast(@min(getIntArg(args, "context_lines") orelse 1, 5));
    const use_regex = if (args) |a| if (a.get("use_regex")) |v| switch (v) {
        .bool => |b| b,
        else => false,
    } else false else false;
    var offset_raw = getIntArg(args, "offset") orelse 0;
    if (offset_raw < 0) offset_raw = 0;
    const offset: usize = @intCast(offset_raw);

    const query_lower = try srv.alloc.alloc(u8, query.len);
    defer srv.alloc.free(query_lower);
    for (query, 0..) |c, i| query_lower[i] = std.ascii.toLower(c);

    const files_stmt = srv.db.prepare(
        \\SELECT path FROM files WHERE is_gem=0 ORDER BY path LIMIT 5000
    ) catch return srv.buildToolError(id, "database error");
    defer files_stmt.finalize();

    var results_buf = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer results_buf.deinit();
    const rw = &results_buf.writer;

    var total: usize = 0;
    var skipped: usize = 0;
    var files_checked: usize = 0;
    var results_first = true;

    while (files_stmt.step() catch |e| stepLog(e)) {
        if (total >= 100) break;
        files_checked += 1;
        if (files_checked > 2000) break;
        const fpath = files_stmt.column_text(0);
        if (file_pattern) |fp| {
            const matched = blk: {
                if (std.mem.indexOf(u8, fp, "*")) |star_idx| {
                    // Simple glob: split on * and require all parts present in path in order
                    const prefix = fp[0..star_idx];
                    const suffix = fp[star_idx + 1 ..];
                    if (prefix.len > 0 and !std.mem.containsAtLeast(u8, fpath, 1, prefix)) break :blk false;
                    if (suffix.len > 0 and !std.mem.endsWith(u8, fpath, suffix)) break :blk false;
                    break :blk true;
                } else {
                    break :blk std.mem.endsWith(u8, fpath, fp);
                }
            };
            if (!matched) continue;
        }
        if (!srv.pathInWorkspace(fpath)) continue;
        const raw = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, fpath, srv.alloc, std.Io.Limit.limited(8 * 1024 * 1024)) catch continue;
        defer srv.alloc.free(raw);

        var lines = std.ArrayList([]const u8).empty;
        defer lines.deinit(srv.alloc);
        var seg_start: usize = 0;
        for (raw, 0..) |ch, i| {
            if (ch == '\n') {
                try lines.append(srv.alloc, raw[seg_start..i]);
                seg_start = i + 1;
            }
        }
        if (seg_start < raw.len) try lines.append(srv.alloc, raw[seg_start..]);

        for (lines.items, 0..) |line, li| {
            if (total >= 100) break;
            const line_lower = try srv.alloc.alloc(u8, line.len);
            defer srv.alloc.free(line_lower);
            for (line, 0..) |c, ci| line_lower[ci] = std.ascii.toLower(c);
            const matched = if (use_regex)
                regexMatchLine(line, query)
            else
                std.mem.indexOf(u8, line_lower, query_lower) != null;
            if (!matched) continue;
            if (skipped < offset) {
                skipped += 1;
                continue;
            }

            total += 1;
            if (!results_first) try rw.writeByte(',');
            results_first = false;
            try rw.writeAll("{\"file\":");
            try writeJsonStr(rw, fpath);
            try rw.print(",\"line\":{d},\"match\":", .{li + 1});
            try writeJsonStrCapped(rw, line, MAX_LINE_BODY_BYTES);
            try rw.writeAll(",\"context_before\":[");
            const before_start: usize = if (li >= ctx_n) li - ctx_n else 0;
            var first_b = true;
            var bi: usize = before_start;
            while (bi < li) : (bi += 1) {
                if (!first_b) try rw.writeByte(',');
                first_b = false;
                try writeJsonStrCapped(rw, lines.items[bi], MAX_LINE_BODY_BYTES);
            }
            try rw.writeAll("],\"context_after\":[");
            const after_end = @min(li + ctx_n + 1, lines.items.len);
            var first_a = true;
            var ai: usize = li + 1;
            while (ai < after_end) : (ai += 1) {
                if (!first_a) try rw.writeByte(',');
                first_a = false;
                try writeJsonStrCapped(rw, lines.items[ai], MAX_LINE_BODY_BYTES);
            }
            try rw.writeAll("]}");
        }
    }
    const results_json = try results_buf.toOwnedSlice();
    defer srv.alloc.free(results_json);

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"query\":");
    try writeJsonStr(w, query);
    const results_truncated = total >= 100;
    const file_limit_hit = files_checked > 2000;
    try w.print(",\"total\":{d},\"has_more\":{s},\"offset\":{d},\"files_checked\":{d},\"results_truncated\":{s}", .{
        total,
        if (results_truncated) "true" else "false",
        offset,
        files_checked,
        if (file_limit_hit and !results_truncated) "true" else "false",
    });
    try w.writeAll(",\"results\":[");
    try w.writeAll(results_json);
    try w.writeAll("]}");
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

pub fn i18nLookup(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const query = getStrArg(args, "query") orelse return srv.buildToolError(id, "missing 'query'");
    var offset = getIntArg(args, "offset") orelse 0;
    if (offset < 0) offset = 0;
    const like_pat = std.fmt.allocPrint(srv.alloc, "%{s}%", .{query}) catch return srv.buildToolError(id, "OOM");
    defer srv.alloc.free(like_pat);

    const stmt = srv.db.prepare(
        \\SELECT key, value, locale FROM i18n_keys WHERE key LIKE ? ORDER BY key LIMIT 101 OFFSET ?
    ) catch return srv.buildToolError(id, "database error");
    defer stmt.finalize();
    stmt.bind_text(1, like_pat);
    stmt.bind_int(2, offset);

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"keys\":[");

    var row_count: usize = 0;
    while (stmt.step() catch |e| stepLog(e)) {
        if (row_count >= 100) break;
        if (row_count > 0) try w.writeByte(',');
        row_count += 1;
        const key = stmt.column_text(0);
        const value = stmt.column_text(1);
        const locale = stmt.column_text(2);
        try w.writeAll("{\"key\":");
        try writeJsonStr(w, key);
        try w.writeAll(",\"value\":");
        if (value.len > 0) try writeJsonStr(w, value) else try w.writeAll("null");
        try w.writeAll(",\"locale\":");
        try writeJsonStr(w, locale);
        try w.writeByte('}');
    }
    const has_more = stmt.step() catch false;
    try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}
