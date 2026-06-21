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

pub fn listRoutes(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const prefix = getStrArg(args, "prefix");
    var offset = getIntArg(args, "offset") orelse 0;
    if (offset < 0) offset = 0;
    const limit: i64 = 100;

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"routes\":[");

    var has_more = false;
    if (prefix) |pfx| {
        var pat_buf: [256]u8 = undefined;
        const pat_len = @min(pfx.len, pat_buf.len - 2);
        @memcpy(pat_buf[0..pat_len], pfx[0..pat_len]);
        pat_buf[pat_len] = '%';
        const pattern = pat_buf[0 .. pat_len + 1];

        const stmt = srv.db.prepare(
            \\SELECT r.helper_name, r.http_method, r.path_pattern, r.controller, r.action, r.line
            \\FROM routes r WHERE r.helper_name LIKE ? ESCAPE '\'
            \\ORDER BY r.helper_name LIMIT ? OFFSET ?
        ) catch return srv.buildToolError(id, "database error");
        defer stmt.finalize();
        stmt.bind_text(1, pattern);
        stmt.bind_int(2, limit + 1);
        stmt.bind_int(3, offset);

        var row_count: usize = 0;
        var first = true;
        while (stmt.step() catch |e| stepLog(e)) {
            if (row_count >= limit) {
                has_more = true;
                break;
            }
            if (!first) try w.writeByte(',');
            first = false;
            row_count += 1;
            try w.writeAll("{\"helper\":");
            try writeJsonStr(w, stmt.column_text(0));
            const method = stmt.column_text(1);
            if (method.len > 0) {
                try w.writeAll(",\"method\":");
                try writeJsonStr(w, method);
            }
            const ctrl = stmt.column_text(3);
            if (ctrl.len > 0) {
                try w.writeAll(",\"controller\":");
                try writeJsonStr(w, ctrl);
            }
            const action = stmt.column_text(4);
            if (action.len > 0) {
                try w.writeAll(",\"action\":");
                try writeJsonStr(w, action);
            }
            try w.print(",\"line\":{d}}}", .{stmt.column_int(5)});
        }
    } else {
        const stmt = srv.db.prepare(
            \\SELECT r.helper_name, r.http_method, r.path_pattern, r.controller, r.action, r.line
            \\FROM routes r ORDER BY r.helper_name LIMIT ? OFFSET ?
        ) catch return srv.buildToolError(id, "database error");
        defer stmt.finalize();
        stmt.bind_int(1, limit + 1);
        stmt.bind_int(2, offset);

        var row_count: usize = 0;
        var first = true;
        while (stmt.step() catch |e| stepLog(e)) {
            if (row_count >= limit) {
                has_more = true;
                break;
            }
            if (!first) try w.writeByte(',');
            first = false;
            row_count += 1;
            try w.writeAll("{\"helper\":");
            try writeJsonStr(w, stmt.column_text(0));
            const method = stmt.column_text(1);
            if (method.len > 0) {
                try w.writeAll(",\"method\":");
                try writeJsonStr(w, method);
            }
            const ctrl = stmt.column_text(3);
            if (ctrl.len > 0) {
                try w.writeAll(",\"controller\":");
                try writeJsonStr(w, ctrl);
            }
            const action = stmt.column_text(4);
            if (action.len > 0) {
                try w.writeAll(",\"action\":");
                try writeJsonStr(w, action);
            }
            try w.print(",\"line\":{d}}}", .{stmt.column_int(5)});
        }
    }

    try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
    const txt = try aw.toOwnedSlice();
    defer srv.alloc.free(txt);
    return srv.buildToolResult(id, txt);
}

pub fn listValidations(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const class_name = getStrArg(args, "class_name") orelse return srv.buildToolError(id, "missing 'class_name'");

    const stmt = srv.db.prepare(
        \\SELECT r.name, r.line, r.col, f.path
        \\FROM refs r
        \\JOIN files f ON f.id = r.file_id
        \\JOIN symbols s ON s.file_id = f.id AND s.name = ? AND s.kind IN ('class','module')
        \\WHERE r.file_id = s.file_id
        \\  AND r.name IN ('validates','validate','validates_presence_of','validates_uniqueness_of',
        \\                 'validates_format_of','validates_length_of','validates_numericality_of',
        \\                 'validates_inclusion_of','validates_exclusion_of','validates_with',
        \\                 'validates_presence','validates_unique','validates_format',
        \\                 'validates_type','validates_not_null','validates_exact_length',
        \\                 'validates_min_length','validates_max_length','validates_integer',
        \\                 'validates_numeric','validates_includes','validates_schema_types')
        \\ORDER BY r.line
        \\LIMIT 100
    ) catch return srv.buildToolError(id, "database error");
    defer stmt.finalize();
    stmt.bind_text(1, class_name);

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"class\":");
    try writeJsonStr(w, class_name);
    try w.writeAll(",\"validations\":[");

    var file_cache = std.StringHashMap([]const u8).init(srv.alloc);
    defer {
        var it = file_cache.iterator();
        while (it.next()) |entry| {
            srv.alloc.free(entry.key_ptr.*);
            srv.alloc.free(entry.value_ptr.*);
        }
        file_cache.deinit();
    }

    var row_count: usize = 0;
    while (stmt.step() catch |e| stepLog(e)) {
        if (row_count > 0) try w.writeByte(',');
        row_count += 1;
        const vname = stmt.column_text(0);
        const vline = stmt.column_int(1);
        const vcol = stmt.column_int(2);
        const vpath = stmt.column_text(3);
        try w.print("{{\"name\":", .{});
        try writeJsonStr(w, vname);
        try w.print(",\"line\":{d},\"col\":{d}", .{ vline, vcol });
        const ctx_line = srv.readFileLineFromCache(&file_cache, vpath, vline);
        defer if (ctx_line) |cl| srv.alloc.free(cl);
        if (ctx_line) |cl| {
            try w.writeAll(",\"context\":");
            try writeJsonStr(w, cl);
        }
        try w.writeByte('}');
    }
    try w.print("],\"has_more\":{s}}}", .{if (row_count >= 100) "true" else "false"});
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

pub fn listCallbacks(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const class_name = getStrArg(args, "class_name") orelse return srv.buildToolError(id, "missing 'class_name'");
    const callback_type = getStrArg(args, "callback_type");
    var offset = getIntArg(args, "offset") orelse 0;
    if (offset < 0) offset = 0;

    const stmt = srv.db.prepare(
        \\SELECT name, doc, line FROM symbols
        \\WHERE parent_name = ? AND kind = 'callback'
        \\  AND (? IS NULL OR name = ?)
        \\ORDER BY line LIMIT 101 OFFSET ?
    ) catch return srv.buildToolError(id, "database error");
    defer stmt.finalize();
    stmt.bind_text(1, class_name);
    if (callback_type) |ct| {
        stmt.bind_text(2, ct);
        stmt.bind_text(3, ct);
    } else {
        stmt.bind_null(2);
        stmt.bind_null(3);
    }
    stmt.bind_int(4, offset);

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"class\":");
    try writeJsonStr(w, class_name);
    try w.writeAll(",\"callbacks\":[");

    var row_count: usize = 0;
    while (stmt.step() catch |e| stepLog(e)) {
        if (row_count >= 100) break;
        if (row_count > 0) try w.writeByte(',');
        row_count += 1;
        const cname = stmt.column_text(0);
        const cdoc = stmt.column_text(1);
        const cline = stmt.column_int(2);
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, cname);
        try w.writeAll(",\"callback_type\":");
        if (cdoc.len > 0) try writeJsonStr(w, cdoc) else try w.writeAll("null");
        try w.print(",\"line\":{d}}}", .{cline});
    }
    const has_more = stmt.step() catch false;
    try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}
