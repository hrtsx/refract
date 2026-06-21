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

pub fn resolveType(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const file = getStrArg(args, "file") orelse return srv.buildToolError(id, "missing 'file' argument");
    const line = getIntArg(args, "line") orelse return srv.buildToolError(id, "missing 'line' argument");
    const col = getIntArg(args, "col") orelse 0;
    const resolved = normalizeFileArg(srv.alloc, file) orelse return srv.buildToolError(id, "cannot resolve file path");
    defer srv.alloc.free(resolved);

    const stmt = srv.db.prepare(
        \\SELECT lv.name, lv.type_hint, lv.confidence
        \\FROM local_vars lv JOIN files f ON f.id = lv.file_id
        \\WHERE f.path = ? AND lv.line = ? AND lv.type_hint IS NOT NULL
        \\ORDER BY ABS(lv.col - ?) LIMIT 1
    ) catch return srv.buildToolError(id, "database error");
    defer stmt.finalize();
    stmt.bind_text(1, resolved);
    stmt.bind_int(2, line);
    stmt.bind_int(3, col);

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    if (stmt.step() catch |e| stepLog(e)) {
        const var_name = stmt.column_text(0);
        const type_hint = stmt.column_text(1);
        const confidence = stmt.column_int(2);
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, var_name);
        try w.writeAll(",\"type_hint\":");
        try writeJsonStr(w, type_hint);
        try w.print(",\"confidence\":{d}", .{confidence});
        // Describe confidence source
        const source_label: []const u8 = if (confidence >= 90) "rbs_annotation" else if (confidence >= 85) "literal_or_guard" else if (confidence >= 75) "method_return" else if (confidence >= 55) "chain_1" else if (confidence >= 38) "chain_2" else "inferred";
        try w.writeAll(",\"source\":");
        try writeJsonStr(w, source_label);
        // Split union components
        if (std.mem.indexOf(u8, type_hint, " | ")) |_| {
            try w.writeAll(",\"union_components\":[");
            var union_it = std.mem.splitSequence(u8, type_hint, " | ");
            var uf = true;
            while (union_it.next()) |part| {
                if (!uf) try w.writeByte(',');
                uf = false;
                try writeJsonStr(w, std.mem.trim(u8, part, " \t"));
            }
            try w.writeByte(']');
        }
        try w.print(",\"line\":{d}}}", .{line});
    } else {
        // Fallback: check symbols table for method return types at this line
        const sym_stmt = srv.db.prepare(
            \\SELECT s.name, s.return_type
            \\FROM symbols s JOIN files f ON f.id = s.file_id
            \\WHERE f.path = ? AND s.line = ? AND s.return_type IS NOT NULL
            \\LIMIT 1
        ) catch null;
        if (sym_stmt) |ss| {
            defer ss.finalize();
            ss.bind_text(1, file);
            ss.bind_int(2, line);
            if (ss.step() catch |e| stepLog(e)) {
                try w.writeAll("{\"name\":");
                try writeJsonStr(w, ss.column_text(0));
                try w.writeAll(",\"type_hint\":");
                try writeJsonStr(w, ss.column_text(1));
                try w.print(",\"source\":\"method_return_type\",\"line\":{d}}}", .{line});
            } else {
                try w.print("{{\"line\":{d},\"type_hint\":null}}", .{line});
            }
        } else {
            try w.print("{{\"line\":{d},\"type_hint\":null}}", .{line});
        }
    }
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

pub fn explainTypeChain(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const file = getStrArg(args, "file") orelse return srv.buildToolError(id, "missing 'file' argument");
    const line = getIntArg(args, "line") orelse return srv.buildToolError(id, "missing 'line' argument");
    const col = getIntArg(args, "col") orelse 0;

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"chain\":[");

    const stmt = srv.db.prepare(
        \\SELECT lv.name, lv.type_hint, lv.confidence, lv.line, lv.col
        \\FROM local_vars lv JOIN files f ON f.id = lv.file_id
        \\WHERE (f.path = ? OR f.path LIKE '%/' || ?) AND lv.name = (
        \\  SELECT lv2.name FROM local_vars lv2 JOIN files f2 ON f2.id = lv2.file_id
        \\  WHERE (f2.path = ? OR f2.path LIKE '%/' || ?) AND lv2.line = ? ORDER BY ABS(lv2.col - ?) LIMIT 1
        \\) AND lv.type_hint IS NOT NULL
        \\ORDER BY lv.confidence DESC, lv.line ASC
    ) catch return srv.buildToolError(id, "database error");
    defer stmt.finalize();
    stmt.bind_text(1, file);
    stmt.bind_text(2, file);
    stmt.bind_text(3, file);
    stmt.bind_text(4, file);
    stmt.bind_int(5, line);
    stmt.bind_int(6, col);

    var first = true;
    while (stmt.step() catch false) {
        if (!first) try w.writeByte(',');
        first = false;
        const var_name = stmt.column_text(0);
        const type_hint = stmt.column_text(1);
        const confidence = stmt.column_int(2);
        const src_line = stmt.column_int(3);
        const source_label: []const u8 = if (confidence >= 90) "rbs" else if (confidence >= 85) "literal_or_guard" else if (confidence >= 75) "method_return" else if (confidence >= 55) "chain_1_level" else if (confidence >= 30) "chain_multi_level" else "inferred";
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, var_name);
        try w.writeAll(",\"type\":");
        try writeJsonStr(w, type_hint);
        try w.print(",\"confidence\":{d},\"source\":", .{confidence});
        try writeJsonStr(w, source_label);
        try w.print(",\"line\":{d}}}", .{src_line});
    }
    if (first) {
        try w.writeAll("],\"note\":\"No type information found at this location. The indexer may not have resolved the type for this assignment.\"}");
    } else {
        try w.writeAll("]}");
    }
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

pub fn classSummary(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const class_name = getStrArg(args, "class_name") orelse return srv.buildToolError(id, "missing 'class_name'");

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"class\":");
    try writeJsonStr(w, class_name);
    try w.writeAll(",\"methods\":[");

    const sym_stmt = srv.db.prepare(
        \\SELECT name, kind, return_type, doc, line, end_line, visibility
        \\FROM symbols WHERE parent_name = ? AND kind IN ('def','classdef')
        \\ORDER BY kind, name LIMIT 200
    ) catch return srv.buildToolError(id, "database error");
    defer sym_stmt.finalize();
    sym_stmt.bind_text(1, class_name);

    var meth_count: usize = 0;
    while (sym_stmt.step() catch |e| stepLog(e)) {
        if (meth_count > 0) try w.writeByte(',');
        meth_count += 1;
        const sname = sym_stmt.column_text(0);
        const skind = sym_stmt.column_text(1);
        const sret = sym_stmt.column_text(2);
        const sdoc = sym_stmt.column_text(3);
        const sline = sym_stmt.column_int(4);
        const svis = sym_stmt.column_text(6);
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, sname);
        try w.writeAll(",\"kind\":");
        try writeJsonStr(w, skind);
        try w.writeAll(",\"return_type\":");
        if (sret.len > 0) try writeJsonStr(w, sret) else try w.writeAll("null");
        try w.writeAll(",\"doc\":");
        if (sdoc.len > 0) try writeJsonStr(w, sdoc) else try w.writeAll("null");
        try w.print(",\"line\":{d},\"visibility\":", .{sline});
        try writeJsonStr(w, svis);
        try w.writeByte('}');
    }
    try w.print("],\"has_more\":{s},\"mixins\":[", .{if (meth_count >= 200) "true" else "false"});

    const mix_stmt = srv.db.prepare(
        \\SELECT m.module_name, m.kind FROM mixins m
        \\JOIN symbols s ON s.id = m.class_id
        \\WHERE s.name = ? AND s.kind IN ('class','module')
        \\LIMIT 50
    ) catch {
        try w.writeAll("],\"instance_variables\":[]}");
        const text = try aw.toOwnedSlice();
        defer srv.alloc.free(text);
        return srv.buildToolResult(id, text);
    };
    defer mix_stmt.finalize();
    mix_stmt.bind_text(1, class_name);

    var mfirst = true;
    while (mix_stmt.step() catch |e| stepLog(e)) {
        if (!mfirst) try w.writeByte(',');
        mfirst = false;
        const mname = mix_stmt.column_text(0);
        const mkind = mix_stmt.column_text(1);
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, mname);
        try w.writeAll(",\"kind\":");
        try writeJsonStr(w, mkind);
        try w.writeByte('}');
    }
    try w.writeAll("],\"instance_variables\":[");

    const ivar_stmt = srv.db.prepare(
        \\SELECT DISTINCT lv.name, lv.type_hint
        \\FROM local_vars lv
        \\JOIN symbols s ON s.id = lv.class_id
        \\WHERE s.name = ? AND s.kind IN ('class','module') AND lv.name LIKE '@%'
        \\ORDER BY lv.name
        \\LIMIT 100
    ) catch {
        try w.writeAll("]}");
        const text = try aw.toOwnedSlice();
        defer srv.alloc.free(text);
        return srv.buildToolResult(id, text);
    };
    defer ivar_stmt.finalize();
    ivar_stmt.bind_text(1, class_name);

    var ivfirst = true;
    while (ivar_stmt.step() catch |e| stepLog(e)) {
        if (!ivfirst) try w.writeByte(',');
        ivfirst = false;
        const ivname = ivar_stmt.column_text(0);
        const ivhint = ivar_stmt.column_text(1);
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, ivname);
        try w.writeAll(",\"type_hint\":");
        if (ivhint.len > 0) try writeJsonStr(w, ivhint) else try w.writeAll("null");
        try w.writeByte('}');
    }
    try w.writeAll("],\"callbacks\":[");

    const cb_stmt = srv.db.prepare(
        \\SELECT name, doc, line FROM symbols
        \\WHERE parent_name = ? AND kind = 'callback'
        \\ORDER BY line LIMIT 50
    ) catch {
        try w.writeAll("],\"scopes\":[]}");
        const text2 = try aw.toOwnedSlice();
        defer srv.alloc.free(text2);
        return srv.buildToolResult(id, text2);
    };
    defer cb_stmt.finalize();
    cb_stmt.bind_text(1, class_name);

    var cbfirst = true;
    while (cb_stmt.step() catch |e| stepLog(e)) {
        if (!cbfirst) try w.writeByte(',');
        cbfirst = false;
        const cname = cb_stmt.column_text(0);
        const cdoc = cb_stmt.column_text(1);
        const cline = cb_stmt.column_int(2);
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, cname);
        try w.writeAll(",\"callback_type\":");
        if (cdoc.len > 0) try writeJsonStr(w, cdoc) else try w.writeAll("null");
        try w.print(",\"line\":{d}}}", .{cline});
    }
    try w.writeAll("],\"scopes\":[");

    const sc_stmt = srv.db.prepare(
        \\SELECT name, return_type, line FROM symbols
        \\WHERE parent_name = ? AND kind = 'classdef'
        \\ORDER BY name LIMIT 50
    ) catch {
        try w.writeAll("]}");
        const text3 = try aw.toOwnedSlice();
        defer srv.alloc.free(text3);
        return srv.buildToolResult(id, text3);
    };
    defer sc_stmt.finalize();
    sc_stmt.bind_text(1, class_name);

    var scfirst = true;
    while (sc_stmt.step() catch |e| stepLog(e)) {
        if (!scfirst) try w.writeByte(',');
        scfirst = false;
        const sname = sc_stmt.column_text(0);
        const sret = sc_stmt.column_text(1);
        const sline = sc_stmt.column_int(2);
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, sname);
        try w.writeAll(",\"return_type\":");
        if (sret.len > 0) try writeJsonStr(w, sret) else try w.writeAll("null");
        try w.print(",\"line\":{d}}}", .{sline});
    }
    try w.writeAll("],\"constants\":[");

    // Constants are listed separately, not folded into `methods` — a constant
    // is not callable, and method_signature/explain resolve them via a distinct
    // path. Keeping them out of `methods` stops consumers probing a constant as
    // a method (which silently failed before).
    const const_stmt = srv.db.prepare(
        \\SELECT name, line FROM symbols
        \\WHERE parent_name = ? AND kind = 'constant'
        \\ORDER BY name LIMIT 100
    ) catch {
        try w.writeAll("]}");
        const text4 = try aw.toOwnedSlice();
        defer srv.alloc.free(text4);
        return srv.buildToolResult(id, text4);
    };
    defer const_stmt.finalize();
    const_stmt.bind_text(1, class_name);

    var kfirst = true;
    while (const_stmt.step() catch |e| stepLog(e)) {
        if (!kfirst) try w.writeByte(',');
        kfirst = false;
        const kname = const_stmt.column_text(0);
        const kline = const_stmt.column_int(1);
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, kname);
        try w.print(",\"line\":{d}}}", .{kline});
    }
    try w.writeAll("]}");
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

/// A method resolved either directly on a class or via its ancestors/mixins.
/// `owner` is null for a direct hit; otherwise the (alloc'd) name of the
/// ancestor/module that actually defines the method — caller frees it.
pub fn methodSignature(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    var class_name: []const u8 = "";
    var method_name: []const u8 = "";
    if (getStrArg(args, "symbol")) |sym| {
        if (splitQualified(sym)) |q| {
            class_name = q.class_name;
            method_name = q.method_name;
        } else return srv.buildToolError(id, "'symbol' must be 'Class#method'");
    } else {
        class_name = getStrArg(args, "class_name") orelse return srv.buildToolError(id, "missing 'class_name' (or pass 'symbol':'Class#method')");
        method_name = getStrArg(args, "method_name") orelse return srv.buildToolError(id, "missing 'method_name' (or pass 'symbol':'Class#method')");
    }

    const resolved = srv.resolveMethodSym(class_name, method_name) orelse
        return srv.buildToolResult(id, "{\"found\":false}");
    defer if (resolved.owner) |o| srv.alloc.free(o);

    const sym_stmt = srv.db.prepare(
        \\SELECT return_type, doc, line, visibility FROM symbols WHERE id = ? LIMIT 1
    ) catch return srv.buildToolError(id, "database error");
    defer sym_stmt.finalize();
    sym_stmt.bind_int(1, resolved.sym_id);
    if (!(sym_stmt.step() catch |e| stepLog(e))) {
        return srv.buildToolResult(id, "{\"found\":false}");
    }
    const ret_type = sym_stmt.column_text(0);
    const doc = sym_stmt.column_text(1);
    const line = sym_stmt.column_int(2);
    const vis = sym_stmt.column_text(3);

    // Overlay correction: a user/agent type-override on this method's return
    // type supersedes the derived value. Keyed by the qualified "Class#method".
    const ctx = srv.overlayCtx();
    defer if (ctx) |c| c.deinit();
    const qualified = try std.fmt.allocPrint(srv.alloc, "{s}#{s}", .{ class_name, method_name });
    defer srv.alloc.free(qualified);
    const ov_ret: ?[]u8 = if (ctx) |c| overlay.effectiveType(srv.db, srv.alloc, c.pid, c.branch, qualified, null, -1) else null;
    defer if (ov_ret) |o| srv.alloc.free(o);

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"found\":true,\"class\":");
    try writeJsonStr(w, class_name);
    try w.writeAll(",\"method\":");
    try writeJsonStr(w, method_name);
    try w.writeAll(",\"inherited_from\":");
    if (resolved.owner) |o| try writeJsonStr(w, o) else try w.writeAll("null");
    try w.print(",\"line\":{d},\"visibility\":", .{line});
    try writeJsonStr(w, vis);
    try w.writeAll(",\"return_type\":");
    if (ov_ret) |o| {
        try writeJsonStr(w, o);
        try w.writeAll(",\"return_type_source\":\"overlay\"");
    } else if (ret_type.len > 0) try writeJsonStr(w, ret_type) else try w.writeAll("null");
    try w.writeAll(",\"doc\":");
    if (doc.len > 0) try writeJsonStr(w, doc) else try w.writeAll("null");
    try w.writeAll(",\"params\":[");
    try srv.writeMethodParams(w, resolved.sym_id);
    try w.writeAll("]}");
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

pub fn explainSymbol(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    var class_name: []const u8 = "";
    var method_name: []const u8 = "";
    if (getStrArg(args, "symbol")) |sym| {
        if (splitQualified(sym)) |q| {
            class_name = q.class_name;
            method_name = q.method_name;
        } else return srv.buildToolError(id, "'symbol' must be 'Class#method'");
    } else {
        class_name = getStrArg(args, "class_name") orelse return srv.buildToolError(id, "missing 'class_name' (or pass 'symbol':'Class#method')");
        method_name = getStrArg(args, "method_name") orelse return srv.buildToolError(id, "missing 'method_name' (or pass 'symbol':'Class#method')");
    }

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"class\":");
    try writeJsonStr(w, class_name);
    try w.writeAll(",\"method\":");
    try writeJsonStr(w, method_name);

    // Signature fields — resolve directly or via ancestors/mixins.
    const resolved = srv.resolveMethodSym(class_name, method_name);
    if (resolved == null) {
        try w.writeAll(",\"found\":false}");
        const text = try aw.toOwnedSlice();
        defer srv.alloc.free(text);
        return srv.buildToolResult(id, text);
    }
    const rm = resolved.?;
    defer if (rm.owner) |o| srv.alloc.free(o);

    const sym_stmt = srv.db.prepare(
        \\SELECT s.return_type, s.visibility, f.path, s.line, s.doc
        \\FROM symbols s JOIN files f ON f.id = s.file_id
        \\WHERE s.id = ? LIMIT 1
    ) catch {
        try w.writeAll(",\"found\":false}");
        const text = try aw.toOwnedSlice();
        defer srv.alloc.free(text);
        return srv.buildToolResult(id, text);
    };
    defer sym_stmt.finalize();
    sym_stmt.bind_int(1, rm.sym_id);

    var def_file: []const u8 = "";
    var def_line: i64 = 0;
    if (sym_stmt.step() catch |e| stepLog(e)) {
        const ret = sym_stmt.column_text(0);
        const vis = sym_stmt.column_text(1);
        def_file = sym_stmt.column_text(2);
        def_line = sym_stmt.column_int(3);
        const yard = sym_stmt.column_text(4);
        // Overlay correction: type-override on this method's return type wins.
        const ctx = srv.overlayCtx();
        defer if (ctx) |c| c.deinit();
        const qualified = try std.fmt.allocPrint(srv.alloc, "{s}#{s}", .{ class_name, method_name });
        defer srv.alloc.free(qualified);
        const ov_ret: ?[]u8 = if (ctx) |c| overlay.effectiveType(srv.db, srv.alloc, c.pid, c.branch, qualified, null, -1) else null;
        defer if (ov_ret) |o| srv.alloc.free(o);
        try w.writeAll(",\"found\":true,\"inherited_from\":");
        if (rm.owner) |o| try writeJsonStr(w, o) else try w.writeAll("null");
        try w.writeAll(",\"return_type\":");
        if (ov_ret) |o| {
            try writeJsonStr(w, o);
            try w.writeAll(",\"return_type_source\":\"overlay\"");
        } else if (ret.len > 0) try writeJsonStr(w, ret) else try w.writeAll("null");
        try w.writeAll(",\"visibility\":");
        try writeJsonStr(w, vis);
        try w.writeAll(",\"defined_at\":{\"file\":");
        try writeJsonStr(w, def_file);
        try w.print(",\"line\":{d}}}", .{def_line});
        if (yard.len > 0) {
            try w.writeAll(",\"yard_doc\":");
            try writeJsonStr(w, yard);
        }
    } else {
        try w.writeAll(",\"found\":false}");
        const text = try aw.toOwnedSlice();
        defer srv.alloc.free(text);
        return srv.buildToolResult(id, text);
    }

    // Parameter list (shared helper; queries by symbol_id).
    try w.writeAll(",\"params\":[");
    try srv.writeMethodParams(w, rm.sym_id);
    try w.writeByte(']');

    // Caller count + up to 3 sample sites
    var caller_count: i64 = 0;
    if (srv.db.prepare(
        \\SELECT COUNT(*) FROM refs r WHERE r.name = ?
    )) |cs| {
        defer cs.finalize();
        cs.bind_text(1, method_name);
        if (cs.step() catch |e| stepLog(e)) caller_count = cs.column_int(0);
    } else |_| {}
    try w.print(",\"caller_count\":{d}", .{caller_count});

    const sample_stmt = srv.db.prepare(
        \\SELECT f.path, r.line FROM refs r
        \\JOIN files f ON f.id = r.file_id
        \\WHERE r.name = ?
        \\ORDER BY f.path, r.line LIMIT 3
    ) catch null;
    try w.writeAll(",\"sample_callers\":[");
    if (sample_stmt) |ss| {
        defer ss.finalize();
        ss.bind_text(1, method_name);
        var sfirst = true;
        while (ss.step() catch |e| stepLog(e)) {
            if (!sfirst) try w.writeByte(',');
            sfirst = false;
            try w.writeAll("{\"file\":");
            try writeJsonStr(w, ss.column_text(0));
            try w.print(",\"line\":{d}}}", .{ss.column_int(1)});
        }
    }
    try w.writeByte(']');

    // Diagnostics on the defining file — computed on demand (parse + semantic).
    try w.writeAll(",\"diagnostics\":[");
    if (def_file.len > 0) {
        var diags = srv.fileDiags(def_file);
        defer {
            for (diags.items) |d| srv.alloc.free(d.message);
            diags.deinit(srv.alloc);
        }
        var dfirst = true;
        var demitted: usize = 0;
        for (diags.items) |d| {
            if (demitted >= 10) break;
            if (!dfirst) try w.writeByte(',');
            dfirst = false;
            demitted += 1;
            try w.writeAll("{\"message\":");
            try writeJsonStr(w, d.message);
            try w.print(",\"severity\":{d},\"line\":{d}", .{ d.severity, d.line });
            if (d.code.len > 0) {
                try w.writeAll(",\"code\":");
                try writeJsonStr(w, d.code);
            }
            try w.writeByte('}');
        }
    }
    try w.writeAll("]}");
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}
