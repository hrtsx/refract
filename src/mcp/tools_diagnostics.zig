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

pub fn diagnostics(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const file = getStrArg(args, "file") orelse return srv.buildToolError(id, "missing 'file'");
    const resolved = normalizeFileArg(srv.alloc, file) orelse return srv.buildToolError(id, "cannot resolve file path");
    defer srv.alloc.free(resolved);

    var diags = srv.fileDiags(resolved);
    defer {
        for (diags.items) |d| srv.alloc.free(d.message);
        diags.deinit(srv.alloc);
    }

    // Overlay correction: drop diagnostics matched by a live suppression rule.
    const ctx = srv.overlayCtx();
    defer if (ctx) |c| c.deinit();

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"file\":");
    try writeJsonStr(w, resolved);
    try w.writeAll(",\"errors\":[");

    var first_d = true;
    for (diags.items) |d| {
        if (ctx) |c| {
            const dl: i64 = if (d.line > 0) d.line else 0;
            if (overlay.isSuppressed(srv.db, c.pid, c.branch, d.code, resolved, dl, null)) continue;
        }
        if (!first_d) try w.writeByte(',');
        first_d = false;
        try w.print("{{\"line\":{d},\"col\":{d},\"severity\":{d},\"message\":", .{ d.line, d.col, d.severity });
        try writeJsonStr(w, d.message);
        if (d.code.len > 0) {
            try w.writeAll(",\"code\":");
            try writeJsonStr(w, d.code);
        }
        try w.writeAll(",\"source\":");
        try writeJsonStr(w, d.source);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

pub fn workspaceHealth(srv: *Server, id: ?std.json.Value) !?[]u8 {
    var total_files: i64 = 0;
    var total_symbols: i64 = 0;
    var typed_vars: i64 = 0;
    var total_vars: i64 = 0;
    var unused_defs: i64 = 0;
    var schema_ver: []const u8 = "unknown";
    var schema_ver_allocated = false;
    defer if (schema_ver_allocated) srv.alloc.free(schema_ver);

    if (srv.db.prepare("SELECT COUNT(*) FROM files WHERE is_gem=0")) |s| {
        defer s.finalize();
        if (s.step() catch |e| stepLog(e)) total_files = s.column_int(0);
    } else |_| {}
    if (srv.db.prepare("SELECT COUNT(*) FROM symbols")) |s| {
        defer s.finalize();
        if (s.step() catch |e| stepLog(e)) total_symbols = s.column_int(0);
    } else |_| {}
    if (srv.db.prepare("SELECT COUNT(*) FROM local_vars WHERE type_hint IS NOT NULL")) |s| {
        defer s.finalize();
        if (s.step() catch |e| stepLog(e)) typed_vars = s.column_int(0);
    } else |_| {}
    if (srv.db.prepare("SELECT COUNT(*) FROM local_vars")) |s| {
        defer s.finalize();
        if (s.step() catch |e| stepLog(e)) total_vars = s.column_int(0);
    } else |_| {}
    if (srv.db.prepare(
        \\SELECT COUNT(*) FROM symbols s
        \\WHERE s.kind = 'def' AND s.visibility = 'public'
        \\  AND NOT EXISTS (SELECT 1 FROM refs r WHERE r.name = s.name)
    )) |s| {
        defer s.finalize();
        if (s.step() catch |e| stepLog(e)) unused_defs = s.column_int(0);
    } else |_| {}
    if (srv.db.prepare("SELECT value FROM meta WHERE key='schema_version'")) |s| {
        defer s.finalize();
        if (s.step() catch |e| stepLog(e)) {
            schema_ver = srv.alloc.dupe(u8, s.column_text(0)) catch "unknown";
            schema_ver_allocated = !std.mem.eql(u8, schema_ver, "unknown");
        }
    } else |_| {}

    const typed_pct: f64 = if (total_vars > 0)
        @as(f64, @floatFromInt(typed_vars)) / @as(f64, @floatFromInt(total_vars)) * 100.0
    else
        0.0;

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\"total_files\":{d},\"total_symbols\":{d},\"typed_local_var_pct\":{d:.1},\"unused_def_count\":{d}", .{
        total_files, total_symbols, typed_pct, unused_defs,
    });

    try w.writeAll(",\"schema_version\":");
    try writeJsonStr(w, schema_ver);
    try w.writeByte('}');

    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

pub fn testSummary(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const file = getStrArg(args, "file") orelse return srv.buildToolError(id, "missing 'file' argument");
    const resolved = normalizeFileArg(srv.alloc, file) orelse return srv.buildToolError(id, "cannot resolve file path");
    defer srv.alloc.free(resolved);
    const stmt = srv.db.prepare(
        \\SELECT s.name, s.kind, s.line, s.end_line
        \\FROM symbols s JOIN files f ON f.id = s.file_id
        \\WHERE f.path = ? AND s.kind = 'test'
        \\ORDER BY s.line LIMIT 500
    ) catch return srv.buildToolError(id, "database error");
    defer stmt.finalize();
    stmt.bind_text(1, resolved);

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"file\":");
    try writeJsonStr(w, file);
    try w.writeAll(",\"tests\":[");
    var first = true;
    while (stmt.step() catch |e| stepLog(e)) {
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, stmt.column_text(0));
        try w.writeAll(",\"kind\":");
        try writeJsonStr(w, stmt.column_text(1));
        try w.print(",\"line\":{d}", .{stmt.column_int(2)});
        if (stmt.column_type(3) != 5) {
            try w.print(",\"end_line\":{d}", .{stmt.column_int(3)});
        }
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    const txt = try aw.toOwnedSlice();
    defer srv.alloc.free(txt);
    return srv.buildToolResult(id, txt);
}

pub fn availableCodeActions(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const file = getStrArg(args, "file") orelse return srv.buildToolError(id, "missing 'file'");
    const line = getIntArg(args, "line") orelse return srv.buildToolError(id, "missing 'line'");
    _ = getIntArg(args, "character");

    const source = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file, srv.alloc, std.Io.Limit.limited(1 << 20)) catch return srv.buildToolError(id, "cannot read file");
    defer srv.alloc.free(source);

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("[");

    var first = true;
    if (@as(u32, @intCast(line)) < countLines(source)) {
        if (!first) try w.writeByte(',');
        try writeJsonStr(w, "extract_method");
        first = false;
    }

    var has_pragma = false;
    var line_iter = std.mem.splitSequence(u8, source, "\n");
    var line_num: u32 = 0;
    while (line_iter.next()) |l| : (line_num += 1) {
        if (std.mem.indexOf(u8, l, "frozen_string_literal")) |_| {
            has_pragma = true;
            break;
        }
    }

    if (!has_pragma and std.mem.endsWith(u8, file, ".rb")) {
        if (!first) try w.writeByte(',');
        try writeJsonStr(w, "add_frozen_string_literal");
        first = false;
    }

    try w.writeAll("]");
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

pub fn refactor(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const file = getStrArg(args, "file") orelse return srv.buildToolError(id, "missing 'file'");
    const start_line = getIntArg(args, "start_line") orelse return srv.buildToolError(id, "missing 'start_line'");
    const end_line = getIntArg(args, "end_line") orelse return srv.buildToolError(id, "missing 'end_line'");
    const kind = getStrArg(args, "kind") orelse return srv.buildToolError(id, "missing 'kind'");

    const source = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file, srv.alloc, std.Io.Limit.limited(1 << 20)) catch return srv.buildToolError(id, "cannot read file");
    defer srv.alloc.free(source);

    var result = if (std.mem.eql(u8, kind, "extract_method"))
        refactor_mod.extractMethod(srv.alloc, source, @intCast(start_line), @intCast(end_line), "extracted_method") catch return srv.buildToolError(id, "refactor failed")
    else if (std.mem.eql(u8, kind, "extract_variable"))
        refactor_mod.extractVariable(srv.alloc, source, @intCast(start_line), 0, @intCast(end_line), 0, "extracted_var") catch return srv.buildToolError(id, "refactor failed")
    else
        return srv.buildToolError(id, "unsupported kind");

    defer result.deinit();

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("[");

    for (result.edits, 0..) |edit, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"start_line\":{d},\"start_col\":{d},\"end_line\":{d},\"end_col\":{d},\"new_text\":", .{
            edit.start_line, edit.start_col, edit.end_line, edit.end_col,
        });
        try writeJsonStr(w, edit.new_text);
        try w.writeAll("}");
    }
    try w.writeAll("]");

    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}
