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

pub fn findReferences(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const name = getStrArg(args, "name") orelse return srv.buildToolError(id, "missing 'name'");
    const ref_kind = getStrArg(args, "ref_kind");
    var offset = getIntArg(args, "offset") orelse 0;
    if (offset < 0) offset = 0;

    const stmt = if (ref_kind != null)
        srv.db.prepare(
            \\SELECT f.path, r.line, r.col FROM refs r
            \\JOIN files f ON f.id = r.file_id
            \\WHERE r.name = ? AND r.kind = ?
            \\ORDER BY f.path, r.line LIMIT 201 OFFSET ?
        ) catch return srv.buildToolError(id, "database error")
    else
        srv.db.prepare(
            \\SELECT f.path, r.line, r.col FROM refs r
            \\JOIN files f ON f.id = r.file_id
            \\WHERE r.name = ?
            \\ORDER BY f.path, r.line LIMIT 201 OFFSET ?
        ) catch return srv.buildToolError(id, "database error");
    defer stmt.finalize();
    var param_idx: c_int = 1;
    stmt.bind_text(param_idx, name);
    param_idx += 1;
    if (ref_kind) |kind| {
        stmt.bind_text(param_idx, kind);
        param_idx += 1;
    }
    stmt.bind_int(param_idx, offset);

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"name\":");
    try writeJsonStr(w, name);
    try w.writeAll(",\"references\":[");

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
        if (row_count >= 200) break;
        if (row_count > 0) try w.writeByte(',');
        row_count += 1;
        const fpath = stmt.column_text(0);
        const rline = stmt.column_int(1);
        const rcol = stmt.column_int(2);
        try w.writeAll("{\"file\":");
        try writeJsonStr(w, fpath);
        try w.print(",\"line\":{d},\"col\":{d}", .{ rline, rcol });
        const ctx_line = srv.readFileLineFromCache(&file_cache, fpath, rline);
        defer if (ctx_line) |cl| srv.alloc.free(cl);
        if (ctx_line) |cl| {
            try w.writeAll(",\"context\":");
            try writeJsonStr(w, cl);
        }
        try w.writeByte('}');
    }
    const has_more = stmt.step() catch false;
    try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

pub fn findImplementations(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const method_name = getStrArg(args, "method_name") orelse return srv.buildToolError(id, "missing 'method_name'");
    var offset = getIntArg(args, "offset") orelse 0;
    if (offset < 0) offset = 0;

    const stmt = srv.db.prepare(
        \\SELECT DISTINCT COALESCE(s.parent_name, '<top-level>'), f.path, s.line, s.return_type
        \\FROM symbols s JOIN files f ON f.id = s.file_id
        \\WHERE s.name = ? AND s.kind IN ('def','classdef')
        \\ORDER BY COALESCE(s.parent_name, '<top-level>'), f.path LIMIT 101 OFFSET ?
    ) catch return srv.buildToolError(id, "database error");
    defer stmt.finalize();
    stmt.bind_text(1, method_name);
    stmt.bind_int(2, offset);

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"method\":");
    try writeJsonStr(w, method_name);
    try w.writeAll(",\"implementations\":[");

    var row_count: usize = 0;
    while (stmt.step() catch |e| stepLog(e)) {
        if (row_count >= 100) break;
        if (row_count > 0) try w.writeByte(',');
        row_count += 1;
        const iclass = stmt.column_text(0);
        const ifile = stmt.column_text(1);
        const iline = stmt.column_int(2);
        const iret = stmt.column_text(3);
        try w.writeAll("{\"class\":");
        try writeJsonStr(w, iclass);
        try w.writeAll(",\"file\":");
        try writeJsonStr(w, ifile);
        try w.print(",\"line\":{d},\"return_type\":", .{iline});
        if (iret.len > 0) try writeJsonStr(w, iret) else try w.writeAll("null");
        try w.writeByte('}');
    }
    const has_more = stmt.step() catch false;
    try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

pub fn findUnused(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const kind_filter = getStrArg(args, "kind");
    const parent_filter = getStrArg(args, "parent_name");

    const stmt = srv.db.prepare(
        \\SELECT s.name, s.kind, s.parent_name, f.path, s.line
        \\FROM symbols s JOIN files f ON f.id = s.file_id
        \\LEFT JOIN refs r ON r.name = s.name
        \\WHERE r.name IS NULL
        \\  AND s.kind = COALESCE(?, 'def')
        \\  AND (? IS NULL OR s.parent_name = ?)
        \\  AND f.is_gem = 0
        \\  AND s.visibility != 'private'
        \\ORDER BY f.path, s.line LIMIT 100
    ) catch return srv.buildToolError(id, "database error");
    defer stmt.finalize();
    if (kind_filter) |kf| stmt.bind_text(1, kf) else stmt.bind_null(1);
    if (parent_filter) |pf| {
        stmt.bind_text(2, pf);
        stmt.bind_text(3, pf);
    } else {
        stmt.bind_null(2);
        stmt.bind_null(3);
    }

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"unused\":[");

    var row_count: usize = 0;
    while (stmt.step() catch |e| stepLog(e)) {
        if (row_count > 0) try w.writeByte(',');
        row_count += 1;
        const sname = stmt.column_text(0);
        const skind = stmt.column_text(1);
        const sparent = stmt.column_text(2);
        const spath = stmt.column_text(3);
        const sline = stmt.column_int(4);
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, sname);
        try w.writeAll(",\"kind\":");
        try writeJsonStr(w, skind);
        try w.writeAll(",\"parent_name\":");
        if (sparent.len > 0) try writeJsonStr(w, sparent) else try w.writeAll("null");
        try w.writeAll(",\"file\":");
        try writeJsonStr(w, spath);
        try w.print(",\"line\":{d}}}", .{sline});
    }
    try w.print("],\"has_more\":{s},\"note\":\"static approximation only\"}}", .{if (row_count >= 100) "true" else "false"});
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

pub fn typeHierarchy(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const class_name = getStrArg(args, "class_name") orelse return srv.buildToolError(id, "missing 'class_name'");
    var ancestors_offset = getIntArg(args, "ancestors_offset") orelse 0;
    var descendants_offset = getIntArg(args, "descendants_offset") orelse 0;
    if (ancestors_offset < 0) ancestors_offset = 0;
    if (descendants_offset < 0) descendants_offset = 0;

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"class\":");
    try writeJsonStr(w, class_name);
    try w.writeAll(",\"ancestors\":[");

    // Recursive CTE walking class inheritance (parent_name), STI, and mixin inclusion
    const anc_stmt = srv.db.prepare(
        \\WITH RECURSIVE anc(cn, depth) AS (
        \\  SELECT ?, 0
        \\  UNION ALL
        \\  SELECT s.parent_name, anc.depth + 1
        \\  FROM symbols s JOIN anc ON s.name = anc.cn
        \\  WHERE s.parent_name IS NOT NULL AND s.kind IN ('class','module') AND anc.depth < 20
        \\  UNION ALL
        \\  SELECT m.module_name, anc.depth + 1
        \\  FROM mixins m JOIN symbols s ON s.id = m.class_id
        \\  JOIN anc ON s.name = anc.cn
        \\  WHERE anc.depth < 20
        \\)
        \\SELECT cn, MIN(depth) as depth FROM anc WHERE depth > 0
        \\GROUP BY cn ORDER BY depth, cn LIMIT 51 OFFSET ?
    ) catch {
        try w.writeAll("],\"descendants\":[]}");
        const text = try aw.toOwnedSlice();
        defer srv.alloc.free(text);
        return srv.buildToolResult(id, text);
    };
    defer anc_stmt.finalize();
    anc_stmt.bind_text(1, class_name);
    anc_stmt.bind_int(2, ancestors_offset);

    var anc_count: usize = 0;
    while (anc_stmt.step() catch |e| stepLog(e)) {
        if (anc_count >= 50) break;
        if (anc_count > 0) try w.writeByte(',');
        anc_count += 1;
        const cn = anc_stmt.column_text(0);
        const depth = anc_stmt.column_int(1);
        try w.print("{{\"name\":", .{});
        try writeJsonStr(w, cn);
        try w.print(",\"depth\":{d}}}", .{depth});
    }
    const anc_has_more = anc_stmt.step() catch false;
    try w.print("],\"ancestors_has_more\":{s},\"ancestors_offset\":{d},\"descendants\":[", .{ if (anc_has_more) "true" else "false", ancestors_offset });

    // Find classes that include this class/module
    const desc_stmt = srv.db.prepare(
        \\SELECT DISTINCT s.name FROM symbols s
        \\JOIN mixins m ON m.class_id = s.id
        \\WHERE m.module_name = ? AND s.kind IN ('class','module')
        \\ORDER BY s.name LIMIT 51 OFFSET ?
    ) catch {
        try w.writeAll("]}");
        const text = try aw.toOwnedSlice();
        defer srv.alloc.free(text);
        return srv.buildToolResult(id, text);
    };
    defer desc_stmt.finalize();
    desc_stmt.bind_text(1, class_name);
    desc_stmt.bind_int(2, descendants_offset);

    var desc_count: usize = 0;
    while (desc_stmt.step() catch |e| stepLog(e)) {
        if (desc_count >= 50) break;
        if (desc_count > 0) try w.writeByte(',');
        desc_count += 1;
        try writeJsonStr(w, desc_stmt.column_text(0));
    }
    const desc_has_more = desc_stmt.step() catch false;
    try w.print("],\"descendants_has_more\":{s},\"descendants_offset\":{d}}}", .{ if (desc_has_more) "true" else "false", descendants_offset });
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

pub fn resolveConstant(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const name = getStrArg(args, "name") orelse return srv.buildToolError(id, "missing 'name'");
    // nesting: outermost-first array; the innermost (last) entry is the enclosing
    // scope path. Mirrors the ref_ns captured at index time.
    var ref_ns: []const u8 = "";
    if (args) |a| {
        if (a.get("nesting")) |nv| {
            if (nv == .array and nv.array.items.len > 0) {
                const last = nv.array.items[nv.array.items.len - 1];
                if (last == .string) ref_ns = last.string;
            }
        }
    }

    const sym_id = indexer.resolveConstantNested(srv.db, name, ref_ns, srv.alloc);

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"query\":");
    try writeJsonStr(w, name);
    try w.writeAll(",\"nesting\":");
    try writeJsonStr(w, ref_ns);
    if (sym_id == 0) {
        try w.writeAll(",\"resolved\":false}");
    } else {
        const stmt = srv.db.prepare(
            \\SELECT s.name, s.kind, s.parent_name, s.line, s.col, f.path, s.deprecated
            \\FROM symbols s JOIN files f ON f.id = s.file_id WHERE s.id = ?
        ) catch return srv.buildToolError(id, "database error");
        defer stmt.finalize();
        stmt.bind_int(1, sym_id);
        if (stmt.step() catch false) {
            const sname = stmt.column_text(0);
            const skind = stmt.column_text(1);
            const sparent = stmt.column_text(2);
            const sline = stmt.column_int(3);
            const scol = stmt.column_int(4);
            const spath = stmt.column_text(5);
            const sdeprecated = stmt.column_int(6);
            // Fully-qualified name: a constant stores its namespace in parent_name
            // and only the simple name in `name`; class/module names are already
            // qualified. Join only when the name isn't already qualified.
            try w.writeAll(",\"resolved\":true,\"fqn\":");
            if (std.mem.eql(u8, skind, "constant") and sparent.len > 0 and std.mem.indexOf(u8, sname, "::") == null) {
                var fqn_buf = std.Io.Writer.Allocating.init(srv.alloc);
                defer fqn_buf.deinit();
                try fqn_buf.writer.print("{s}::{s}", .{ sparent, sname });
                try writeJsonStr(w, fqn_buf.written());
            } else {
                try writeJsonStr(w, sname);
            }
            try w.writeAll(",\"kind\":");
            try writeJsonStr(w, skind);
            try w.writeAll(",\"file\":");
            try writeJsonStr(w, spath);
            try w.print(",\"line\":{d},\"col\":{d},\"deprecated\":{s}}}", .{ sline, scol, if (sdeprecated != 0) "true" else "false" });
        } else {
            try w.writeAll(",\"resolved\":false}");
        }
    }
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

pub fn associationGraph(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const class_name = getStrArg(args, "class_name") orelse return srv.buildToolError(id, "missing 'class_name'");
    var offset = getIntArg(args, "offset") orelse 0;
    if (offset < 0) offset = 0;

    const stmt = srv.db.prepare(
        \\SELECT name, kind, return_type, doc, value_snippet FROM symbols
        \\WHERE parent_name = ? AND kind IN ('association','scope')
        \\ORDER BY name LIMIT 101 OFFSET ?
    ) catch return srv.buildToolError(id, "database error");
    defer stmt.finalize();
    stmt.bind_text(1, class_name);
    stmt.bind_int(2, offset);

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"class\":");
    try writeJsonStr(w, class_name);
    try w.writeAll(",\"associations\":[");

    var row_count: usize = 0;
    while (stmt.step() catch |e| stepLog(e)) {
        if (row_count >= 100) break;
        if (row_count > 0) try w.writeByte(',');
        row_count += 1;
        const aname = stmt.column_text(0);
        const akind = stmt.column_text(1);
        const aret = stmt.column_text(2);
        const adoc = stmt.column_text(3);
        const avs = stmt.column_text(4);
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, aname);
        try w.writeAll(",\"association_type\":");
        if (adoc.len > 0) try writeJsonStr(w, adoc) else try writeJsonStr(w, akind);
        try w.writeAll(",\"return_type\":");
        if (aret.len > 0) try writeJsonStr(w, aret) else try w.writeAll("null");
        if (std.mem.startsWith(u8, avs, "through:")) {
            try w.writeAll(",\"through\":");
            try writeJsonStr(w, avs["through:".len..]);
        }
        try w.writeByte('}');
    }
    try w.writeAll("]");
    if (row_count == 0) {
        try w.writeAll(",\"note\":\"No associations detected. Supported: ActiveRecord (has_many, belongs_to, has_one), Sequel (one_to_many, many_to_one, many_to_many, one_to_one).\"");
    }
    const has_more = stmt.step() catch false;
    try w.print(",\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

// Compute a file's diagnostics on demand (the same engine the LSP uses): Prism
// parse diagnostics + refract semantic checks (nil-receiver, wrong-arity), merged
// into one owned list. Nothing is persisted to a table, so this is the only source.
// Caller owns the result: free each `.message`, then `deinit(srv.alloc)`.
// DiagEntry.line/col are 1-based, matching the rest of the MCP surface.
// Look up a file's id, tolerant of symlink/canonicalisation differences between
// the path the indexer stored and the path passed here (e.g. macOS /tmp vs the
// realpath /private/tmp). Tries the path as-is, then its realpath. 0 = not indexed.

pub fn concernUsage(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const module_name = getStrArg(args, "module_name") orelse return srv.buildToolError(id, "missing 'module_name'");
    var offset = getIntArg(args, "offset") orelse 0;
    if (offset < 0) offset = 0;

    const stmt = srv.db.prepare(
        \\SELECT s.name, f.path, m.kind FROM symbols s
        \\JOIN files f ON f.id = s.file_id
        \\JOIN mixins m ON m.class_id = s.id
        \\WHERE (m.module_name = ? OR m.module_name LIKE '%::' || ?)
        \\  AND m.kind IN ('include','prepend','extend')
        \\ORDER BY s.name LIMIT 101 OFFSET ?
    ) catch return srv.buildToolError(id, "database error");
    defer stmt.finalize();
    stmt.bind_text(1, module_name);
    stmt.bind_text(2, module_name);
    stmt.bind_int(3, offset);

    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"module\":");
    try writeJsonStr(w, module_name);
    try w.writeAll(",\"used_by\":[");

    var row_count: usize = 0;
    while (stmt.step() catch |e| stepLog(e)) {
        if (row_count >= 100) break;
        if (row_count > 0) try w.writeByte(',');
        row_count += 1;
        const sname = stmt.column_text(0);
        const fpath = stmt.column_text(1);
        const mkind = stmt.column_text(2);
        try w.writeAll("{\"class\":");
        try writeJsonStr(w, sname);
        try w.writeAll(",\"file\":");
        try writeJsonStr(w, fpath);
        try w.writeAll(",\"kind\":");
        try writeJsonStr(w, mkind);
        try w.writeByte('}');
    }
    const has_more = stmt.step() catch false;
    try w.print("],\"has_more\":{s},\"offset\":{d}}}", .{ if (has_more) "true" else "false", offset });
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}
