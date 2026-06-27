// Overlay layer — the only agent/user-writable surface over the derived graph.
//
// Rows are keyed by (project_id, branch): branch == null is project-global,
// otherwise branch-scoped. Reads resolve "effective" values as branch-specific
// first, then global, newest live row wins (revoked_at IS NULL). Writes are
// gated (allowed kinds, required reason, size caps) and reversible (soft-delete
// via revoked_at). Derived tables are never touched.

const std = @import("std");
const db_mod = @import("../db.zig");
const io = std.Options.debug_io;

pub const MAX_LABEL = 256;
pub const MAX_CONTENT = 4096;
pub const MAX_TYPE = 512;
pub const MAX_REASON = 512;

pub const CONF_AGENT = 70;
pub const CONF_USER = 100;

pub const GateError = error{ ReasonRequired, ReasonTooLong, PayloadTooLong, BadOp, MissingTarget };

pub const Op = enum { note, tag, concept, edge, override, suppress };

pub fn parseOp(s: []const u8) ?Op {
    inline for (std.meta.fields(Op)) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

fn checkReason(reason: []const u8) GateError!void {
    if (std.mem.trim(u8, reason, " \t\r\n").len == 0) return GateError.ReasonRequired;
    if (reason.len > MAX_REASON) return GateError.ReasonTooLong;
}

fn bindOptText(stmt: anytype, col: c_int, val: ?[]const u8) void {
    if (val) |v| stmt.bind_text(col, v) else stmt.bind_null(col);
}

/// Log an overlay write failure to stderr. A null return from a write otherwise
/// looks identical to a gate rejection; surface the DB cause so a real failure
/// (locked db, I/O error) is not silently swallowed and the agent's edit lost.
fn logOverlayDbError(op: []const u8, e: anyerror) void {
    std.debug.print("refract: overlay {s} write failed: {s}\n", .{ op, @errorName(e) });
}

/// Insert returning the new row id. Caller holds db_mutex.
fn insertReturningId(stmt: db_mod.Stmt) ?i64 {
    if (stmt.step() catch |e| {
        logOverlayDbError("insert", e);
        return null;
    }) return stmt.column_int(0);
    return null;
}

// ---- writes (caller holds db_mutex) ----

pub fn addNode(
    db: db_mod.Db,
    pid: []const u8,
    branch: ?[]const u8,
    fqn: []const u8,
    kind: []const u8, // concept|note|tag|todo|risk
    label: ?[]const u8,
    content: ?[]const u8,
    is_user: bool,
    reason: []const u8,
    now_s: i64,
) GateError!?i64 {
    try checkReason(reason);
    if (label) |l| if (l.len > MAX_LABEL) return GateError.PayloadTooLong;
    if (content) |c| if (c.len > MAX_CONTENT) return GateError.PayloadTooLong;
    const stmt = db.prepare(
        \\INSERT INTO overlay_nodes(project_id,branch,fqn,kind,label,content,source,confidence,reason,created_at)
        \\VALUES(?,?,?,?,?,?,?,?,?,?) RETURNING id
    ) catch |e| {
        logOverlayDbError("addNode", e);
        return null;
    };
    defer stmt.finalize();
    stmt.bind_text(1, pid);
    bindOptText(stmt, 2, branch);
    stmt.bind_text(3, fqn);
    stmt.bind_text(4, kind);
    bindOptText(stmt, 5, label);
    bindOptText(stmt, 6, content);
    stmt.bind_text(7, if (is_user) "USER" else "AGENT");
    stmt.bind_int(8, if (is_user) CONF_USER else CONF_AGENT);
    stmt.bind_text(9, reason);
    stmt.bind_int(10, now_s);
    return insertReturningId(stmt);
}

pub fn addEdge(
    db: db_mod.Db,
    pid: []const u8,
    branch: ?[]const u8,
    from_fqn: []const u8,
    to_fqn: []const u8,
    kind: []const u8,
    label: ?[]const u8,
    is_user: bool,
    reason: []const u8,
    now_s: i64,
) GateError!?i64 {
    try checkReason(reason);
    if (label) |l| if (l.len > MAX_LABEL) return GateError.PayloadTooLong;
    const stmt = db.prepare(
        \\INSERT INTO overlay_edges(project_id,branch,from_fqn,to_fqn,kind,label,source,confidence,reason,created_at)
        \\VALUES(?,?,?,?,?,?,?,?,?,?) RETURNING id
    ) catch |e| {
        logOverlayDbError("addEdge", e);
        return null;
    };
    defer stmt.finalize();
    stmt.bind_text(1, pid);
    bindOptText(stmt, 2, branch);
    stmt.bind_text(3, from_fqn);
    stmt.bind_text(4, to_fqn);
    stmt.bind_text(5, kind);
    bindOptText(stmt, 6, label);
    stmt.bind_text(7, if (is_user) "USER" else "AGENT");
    stmt.bind_int(8, if (is_user) CONF_USER else CONF_AGENT);
    stmt.bind_text(9, reason);
    stmt.bind_int(10, now_s);
    return insertReturningId(stmt);
}

pub fn addType(
    db: db_mod.Db,
    pid: []const u8,
    branch: ?[]const u8,
    fqn: []const u8,
    method_name: ?[]const u8,
    param_pos: i64,
    type_str: []const u8,
    is_user: bool,
    reason: []const u8,
    now_s: i64,
) GateError!?i64 {
    try checkReason(reason);
    if (type_str.len == 0) return GateError.MissingTarget;
    if (type_str.len > MAX_TYPE) return GateError.PayloadTooLong;
    const stmt = db.prepare(
        \\INSERT INTO overlay_types(project_id,branch,fqn,method_name,param_pos,type_str,source,confidence,reason,created_at)
        \\VALUES(?,?,?,?,?,?,?,?,?,?) RETURNING id
    ) catch |e| {
        logOverlayDbError("addType", e);
        return null;
    };
    defer stmt.finalize();
    stmt.bind_text(1, pid);
    bindOptText(stmt, 2, branch);
    stmt.bind_text(3, fqn);
    bindOptText(stmt, 4, method_name);
    stmt.bind_int(5, param_pos);
    stmt.bind_text(6, type_str);
    stmt.bind_text(7, if (is_user) "USER" else "AGENT");
    stmt.bind_int(8, if (is_user) CONF_USER else CONF_AGENT);
    stmt.bind_text(9, reason);
    stmt.bind_int(10, now_s);
    return insertReturningId(stmt);
}

pub fn addSuppress(
    db: db_mod.Db,
    pid: []const u8,
    branch: ?[]const u8,
    fqn: ?[]const u8,
    file_path: ?[]const u8,
    diag_code: []const u8,
    line: ?i64,
    is_user: bool,
    reason: []const u8,
    now_s: i64,
) GateError!?i64 {
    try checkReason(reason);
    if (diag_code.len == 0) return GateError.MissingTarget;
    if (fqn == null and file_path == null) return GateError.MissingTarget;
    const stmt = db.prepare(
        \\INSERT INTO overlay_suppress(project_id,branch,fqn,file_path,diag_code,line,source,confidence,reason,created_at)
        \\VALUES(?,?,?,?,?,?,?,?,?,?) RETURNING id
    ) catch |e| {
        logOverlayDbError("addSuppress", e);
        return null;
    };
    defer stmt.finalize();
    stmt.bind_text(1, pid);
    bindOptText(stmt, 2, branch);
    bindOptText(stmt, 3, fqn);
    bindOptText(stmt, 4, file_path);
    stmt.bind_text(5, diag_code);
    if (line) |l| stmt.bind_int(6, l) else stmt.bind_null(6);
    stmt.bind_text(7, if (is_user) "USER" else "AGENT");
    stmt.bind_int(8, if (is_user) CONF_USER else CONF_AGENT);
    stmt.bind_text(9, reason);
    stmt.bind_int(10, now_s);
    return insertReturningId(stmt);
}

const TABLES = [_][]const u8{ "overlay_nodes", "overlay_edges", "overlay_types", "overlay_suppress" };

fn validTable(t: []const u8) bool {
    for (TABLES) |x| if (std.mem.eql(u8, x, t)) return true;
    return false;
}

/// Soft-delete a row by id (revert). Returns true if a live row was revoked.
pub fn revoke(db: db_mod.Db, alloc: std.mem.Allocator, table: []const u8, id: i64, now_s: i64) bool {
    if (!validTable(table)) return false;
    const sql = std.fmt.allocPrintSentinel(alloc, "UPDATE {s} SET revoked_at=? WHERE id=? AND revoked_at IS NULL", .{table}, 0) catch return false;
    defer alloc.free(sql);
    const stmt = db.prepare(sql) catch return false;
    defer stmt.finalize();
    stmt.bind_int(1, now_s);
    stmt.bind_int(2, id);
    _ = stmt.step() catch return false;
    return db.changes() > 0;
}

/// Promote live branch-scoped rows to project-global (branch = NULL) by
/// re-inserting a global copy, skipping any whose semantic twin already exists
/// globally (NULL-safe match on every column but `created_at`, which promote
/// re-stamps). Idempotent across repeated promotes. Returns count promoted.
pub fn promote(db: db_mod.Db, alloc: std.mem.Allocator, pid: []const u8, from_branch: []const u8, now_s: i64) u32 {
    var total: u32 = 0;
    const specs = [_]struct { table: []const u8, cols: []const []const u8 }{
        .{ .table = "overlay_nodes", .cols = &.{ "fqn", "kind", "label", "content", "source", "confidence", "reason" } },
        .{ .table = "overlay_edges", .cols = &.{ "from_fqn", "to_fqn", "kind", "label", "source", "confidence", "reason" } },
        .{ .table = "overlay_types", .cols = &.{ "fqn", "method_name", "param_pos", "type_str", "source", "confidence", "reason" } },
        .{ .table = "overlay_suppress", .cols = &.{ "fqn", "file_path", "diag_code", "line", "source", "confidence", "reason" } },
    };
    for (specs) |s| {
        var plain = std.Io.Writer.Allocating.init(alloc);
        defer plain.deinit();
        var sel = std.Io.Writer.Allocating.init(alloc);
        defer sel.deinit();
        var match = std.Io.Writer.Allocating.init(alloc);
        defer match.deinit();
        for (s.cols, 0..) |c, i| {
            if (i > 0) {
                plain.writer.writeByte(',') catch break;
                sel.writer.writeByte(',') catch break;
                match.writer.writeAll(" AND ") catch break;
            }
            plain.writer.writeAll(c) catch break;
            sel.writer.print("s.{s}", .{c}) catch break;
            match.writer.print("g.{s} IS s.{s}", .{ c, c }) catch break;
        }
        const sql = std.fmt.allocPrintSentinel(
            alloc,
            "INSERT INTO {s}(project_id,branch,{s},created_at) SELECT s.project_id,NULL,{s},? FROM {s} s WHERE s.project_id=? AND s.branch=? AND s.revoked_at IS NULL AND NOT EXISTS (SELECT 1 FROM {s} g WHERE g.project_id=s.project_id AND g.branch IS NULL AND g.revoked_at IS NULL AND {s})",
            .{ s.table, plain.written(), sel.written(), s.table, s.table, match.written() },
            0,
        ) catch continue;
        defer alloc.free(sql);
        const stmt = db.prepare(sql) catch continue;
        defer stmt.finalize();
        stmt.bind_int(1, now_s);
        stmt.bind_text(2, pid);
        stmt.bind_text(3, from_branch);
        _ = stmt.step() catch continue;
        total += @intCast(db.changes());
    }
    return total;
}

// ---- effective reads ----

/// Effective type override for a (fqn, method, param_pos): branch-specific
/// wins over global, newest live row wins. Caller owns the returned slice.
pub fn effectiveType(
    db: db_mod.Db,
    alloc: std.mem.Allocator,
    pid: []const u8,
    branch: ?[]const u8,
    fqn: []const u8,
    method_name: ?[]const u8,
    param_pos: i64,
) ?[]u8 {
    const stmt = db.prepare(
        \\SELECT type_str FROM overlay_types
        \\WHERE project_id=? AND fqn=? AND IFNULL(method_name,'')=? AND param_pos=?
        \\  AND (branch IS NULL OR branch=?) AND revoked_at IS NULL
        \\ORDER BY (branch IS NULL) ASC, created_at DESC LIMIT 1
    ) catch return null;
    defer stmt.finalize();
    stmt.bind_text(1, pid);
    stmt.bind_text(2, fqn);
    stmt.bind_text(3, method_name orelse "");
    stmt.bind_int(4, param_pos);
    stmt.bind_text(5, branch orelse "");
    if (stmt.step() catch false) {
        return alloc.dupe(u8, stmt.column_text(0)) catch null;
    }
    return null;
}

/// True if a live suppression matches this diagnostic. Matches by diag_code and
/// either fqn or (file_path [+ line]); branch-specific or global.
pub fn isSuppressed(
    db: db_mod.Db,
    pid: []const u8,
    branch: ?[]const u8,
    diag_code: []const u8,
    file_path: ?[]const u8,
    line: ?i64,
    fqn: ?[]const u8,
) bool {
    const stmt = db.prepare(
        \\SELECT 1 FROM overlay_suppress
        \\WHERE project_id=? AND diag_code=? AND revoked_at IS NULL
        \\  AND (branch IS NULL OR branch=?)
        \\  AND ( (fqn IS NOT NULL AND fqn=?)
        \\     OR (file_path IS NOT NULL AND file_path=? AND (line IS NULL OR line=?)) )
        \\LIMIT 1
    ) catch return false;
    defer stmt.finalize();
    stmt.bind_text(1, pid);
    stmt.bind_text(2, diag_code);
    stmt.bind_text(3, branch orelse "");
    stmt.bind_text(4, fqn orelse "\x00");
    stmt.bind_text(5, file_path orelse "\x00");
    if (line) |l| stmt.bind_int(6, l) else stmt.bind_int(6, -1);
    return stmt.step() catch false;
}

// ---- listing + JSON portability ----

fn jsonStr(w: *std.Io.Writer, s: []const u8) void {
    w.writeByte('"') catch return;
    for (s) |ch| switch (ch) {
        '"' => w.writeAll("\\\"") catch return,
        '\\' => w.writeAll("\\\\") catch return,
        '\n' => w.writeAll("\\n") catch return,
        '\r' => w.writeAll("\\r") catch return,
        '\t' => w.writeAll("\\t") catch return,
        else => if (ch < 0x20) {
            w.print("\\u{x:0>4}", .{ch}) catch return;
        } else w.writeByte(ch) catch return,
    };
    w.writeByte('"') catch return;
}

/// Write a JSON array of live overlay rows for a kind to `w`. `branch` null →
/// all branches (global + every branch); else global + that branch.
pub fn listJson(
    db: db_mod.Db,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    pid: []const u8,
    table: []const u8,
    branch: ?[]const u8,
    all_branches: bool,
) void {
    if (!validTable(table)) {
        w.writeAll("[]") catch return;
        return;
    }
    const where_branch: []const u8 = if (all_branches) "" else " AND (branch IS NULL OR branch=?)";
    const extras = listExtras(table);
    // Build the per-table subject column list appended after the common envelope.
    var extra_sql = std.Io.Writer.Allocating.init(alloc);
    defer extra_sql.deinit();
    for (extras) |e| {
        extra_sql.writer.writeByte(',') catch return;
        extra_sql.writer.writeAll(e.col) catch return;
    }
    const sql = std.fmt.allocPrintSentinel(
        alloc,
        "SELECT id,branch,source,confidence,reason,created_at{s} FROM {s} WHERE project_id=? AND revoked_at IS NULL{s} ORDER BY created_at DESC",
        .{ extra_sql.written(), table, where_branch },
        0,
    ) catch {
        w.writeAll("[]") catch return;
        return;
    };
    defer alloc.free(sql);
    const stmt = db.prepare(sql) catch {
        w.writeAll("[]") catch return;
        return;
    };
    defer stmt.finalize();
    stmt.bind_text(1, pid);
    if (!all_branches) stmt.bind_text(2, branch orelse "");
    w.writeByte('[') catch return;
    var i: usize = 0;
    while (stmt.step() catch false) : (i += 1) {
        if (i > 0) w.writeByte(',') catch return;
        w.print("{{\"id\":{d},\"branch\":", .{stmt.column_int(0)}) catch return;
        const b = stmt.column_text(1);
        if (b.len == 0) w.writeAll("null") catch return else jsonStr(w, b);
        w.writeAll(",\"source\":") catch return;
        jsonStr(w, stmt.column_text(2));
        w.print(",\"confidence\":{d},\"reason\":", .{stmt.column_int(3)}) catch return;
        jsonStr(w, stmt.column_text(4));
        w.print(",\"created_at\":{d}", .{stmt.column_int(5)}) catch return;
        for (extras, 0..) |e, j| {
            const col: c_int = @intCast(6 + j);
            w.writeByte(',') catch return;
            jsonStr(w, e.key);
            w.writeByte(':') catch return;
            if (e.is_int) {
                if (stmt.column_type(col) == 5) w.writeAll("null") catch return // SQLITE_NULL
                else w.print("{d}", .{stmt.column_int(col)}) catch return;
            } else {
                const v = stmt.column_text(col);
                if (v.len == 0) w.writeAll("null") catch return else jsonStr(w, v);
            }
        }
        w.writeByte('}') catch return;
    }
    w.writeByte(']') catch return;
}

const ListExtra = struct { key: []const u8, col: []const u8, is_int: bool };
fn listExtras(table: []const u8) []const ListExtra {
    if (std.mem.eql(u8, table, "overlay_nodes")) return &.{
        .{ .key = "fqn", .col = "fqn", .is_int = false },
        .{ .key = "kind", .col = "kind", .is_int = false },
        .{ .key = "label", .col = "label", .is_int = false },
    };
    if (std.mem.eql(u8, table, "overlay_edges")) return &.{
        .{ .key = "from_fqn", .col = "from_fqn", .is_int = false },
        .{ .key = "to_fqn", .col = "to_fqn", .is_int = false },
        .{ .key = "kind", .col = "kind", .is_int = false },
        .{ .key = "label", .col = "label", .is_int = false },
    };
    if (std.mem.eql(u8, table, "overlay_types")) return &.{
        .{ .key = "fqn", .col = "fqn", .is_int = false },
        .{ .key = "method_name", .col = "method_name", .is_int = false },
        .{ .key = "type", .col = "type_str", .is_int = false },
    };
    if (std.mem.eql(u8, table, "overlay_suppress")) return &.{
        .{ .key = "fqn", .col = "fqn", .is_int = false },
        .{ .key = "file_path", .col = "file_path", .is_int = false },
        .{ .key = "diag_code", .col = "diag_code", .is_int = false },
        .{ .key = "line", .col = "line", .is_int = true },
    };
    return &.{};
}

/// Export project-global overlay rows AND branch-scoped rows to a portable JSON
/// file at `path`. Includes project_id so clones re-link deterministically.
// Column spec per table for full-fidelity export/import. `ints` marks which
// emitted columns are integers (vs text/nullable-text).
const ExportSpec = struct { key: []const u8, table: []const u8, cols: []const []const u8, ints: []const []const u8 };
const EXPORT_SPECS = [_]ExportSpec{
    .{ .key = "nodes", .table = "overlay_nodes", .cols = &.{ "branch", "fqn", "kind", "label", "content", "source", "confidence", "reason", "created_at" }, .ints = &.{ "confidence", "created_at" } },
    .{ .key = "edges", .table = "overlay_edges", .cols = &.{ "branch", "from_fqn", "to_fqn", "kind", "label", "source", "confidence", "reason", "created_at" }, .ints = &.{ "confidence", "created_at" } },
    .{ .key = "types", .table = "overlay_types", .cols = &.{ "branch", "fqn", "method_name", "param_pos", "type_str", "source", "confidence", "reason", "created_at" }, .ints = &.{ "param_pos", "confidence", "created_at" } },
    .{ .key = "suppress", .table = "overlay_suppress", .cols = &.{ "branch", "fqn", "file_path", "diag_code", "line", "source", "confidence", "reason", "created_at" }, .ints = &.{ "line", "confidence", "created_at" } },
};

fn isInt(spec: ExportSpec, col: []const u8) bool {
    for (spec.ints) |i| if (std.mem.eql(u8, i, col)) return true;
    return false;
}

fn emitTable(db: db_mod.Db, alloc: std.mem.Allocator, w: *std.Io.Writer, pid: []const u8, spec: ExportSpec) void {
    var collist = std.Io.Writer.Allocating.init(alloc);
    defer collist.deinit();
    for (spec.cols, 0..) |c, i| {
        if (i > 0) collist.writer.writeByte(',') catch return;
        collist.writer.writeAll(c) catch return;
    }
    const sql = std.fmt.allocPrintSentinel(alloc, "SELECT {s} FROM {s} WHERE project_id=? AND revoked_at IS NULL ORDER BY created_at", .{ collist.written(), spec.table }, 0) catch {
        w.writeAll("[]") catch return;
        return;
    };
    defer alloc.free(sql);
    const stmt = db.prepare(sql) catch {
        w.writeAll("[]") catch return;
        return;
    };
    defer stmt.finalize();
    stmt.bind_text(1, pid);
    w.writeByte('[') catch return;
    var n: usize = 0;
    while (stmt.step() catch false) : (n += 1) {
        if (n > 0) w.writeByte(',') catch return;
        w.writeByte('{') catch return;
        for (spec.cols, 0..) |col, ci| {
            if (ci > 0) w.writeByte(',') catch return;
            jsonStr(w, col);
            w.writeByte(':') catch return;
            const ctype = stmt.column_type(@intCast(ci));
            if (ctype == 5) { // SQLITE_NULL
                w.writeAll("null") catch return;
            } else if (isInt(spec, col)) {
                w.print("{d}", .{stmt.column_int(@intCast(ci))}) catch return;
            } else {
                jsonStr(w, stmt.column_text(@intCast(ci)));
            }
        }
        w.writeByte('}') catch return;
    }
    w.writeByte(']') catch return;
}

/// Export all live overlay rows (global + branch-scoped) to a portable JSON
/// file. Includes project_id so clones re-link deterministically.
pub fn exportJson(db: db_mod.Db, alloc: std.mem.Allocator, pid: []const u8, path: []const u8) !void {
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"schema\":1,\"project_id\":");
    jsonStr(w, pid);
    for (EXPORT_SPECS) |spec| {
        try w.writeByte(',');
        jsonStr(w, spec.key);
        try w.writeByte(':');
        emitTable(db, alloc, w, pid, spec);
    }
    try w.writeAll("}\n");
    const data = try aw.toOwnedSlice();
    defer alloc.free(data);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn getJsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getJsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

/// Import overlay rows from a portable JSON file, merging into the local db.
/// Trusted-file path: bypasses write gating but preserves source/confidence/
/// branch/created_at. A live row whose every column equals an incoming row is
/// skipped (exact-identity check, see `liveRowExists`), so re-importing the same
/// file is a no-op and repeated imports are idempotent. Returns rows added.
/// Refuses files whose `schema` is present and not 1.
pub fn importJson(db: db_mod.Db, alloc: std.mem.Allocator, pid: []const u8, path: []const u8) !u32 {
    const body = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, std.Io.Limit.limited(64 * 1024 * 1024)) catch return 0;
    defer alloc.free(body);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return 0;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return 0,
    };
    if (root.get("schema")) |sv| {
        const ver = switch (sv) {
            .integer => |i| i,
            else => return 0,
        };
        if (ver != 1) return 0;
    }
    var added: u32 = 0;
    for (EXPORT_SPECS) |spec| {
        const arr_v = root.get(spec.key) orelse continue;
        const arr = switch (arr_v) {
            .array => |a| a,
            else => continue,
        };
        for (arr.items) |row_v| {
            const row = switch (row_v) {
                .object => |o| o,
                else => continue,
            };
            if (importRow(db, alloc, pid, spec, row)) added += 1;
        }
    }
    return added;
}

/// True if a live row already matches `row` on every exported column for this
/// project. Null-safe per column (text via IFNULL '', ints via a sentinel), so
/// a re-imported row is recognised even where label/method/line are absent.
fn liveRowExists(db: db_mod.Db, alloc: std.mem.Allocator, pid: []const u8, spec: ExportSpec, row: std.json.ObjectMap) bool {
    var clauses = std.Io.Writer.Allocating.init(alloc);
    defer clauses.deinit();
    for (spec.cols) |c| {
        if (isInt(spec, c)) {
            clauses.writer.print(" AND IFNULL({s},-999999999)=IFNULL(?,-999999999)", .{c}) catch return false;
        } else {
            clauses.writer.print(" AND IFNULL({s},'')=IFNULL(?,'')", .{c}) catch return false;
        }
    }
    const sql = std.fmt.allocPrintSentinel(alloc, "SELECT 1 FROM {s} WHERE project_id=? AND revoked_at IS NULL{s} LIMIT 1", .{ spec.table, clauses.written() }, 0) catch return false;
    defer alloc.free(sql);
    const stmt = db.prepare(sql) catch return false;
    defer stmt.finalize();
    stmt.bind_text(1, pid);
    var col_idx: c_int = 2;
    for (spec.cols) |col| {
        if (isInt(spec, col)) {
            if (getJsonInt(row, col)) |iv| stmt.bind_int(col_idx, iv) else stmt.bind_null(col_idx);
        } else {
            if (getJsonStr(row, col)) |sv| stmt.bind_text(col_idx, sv) else stmt.bind_null(col_idx);
        }
        col_idx += 1;
    }
    return stmt.step() catch false;
}

fn importRow(db: db_mod.Db, alloc: std.mem.Allocator, pid: []const u8, spec: ExportSpec, row: std.json.ObjectMap) bool {
    if (liveRowExists(db, alloc, pid, spec, row)) return false;
    var names = std.Io.Writer.Allocating.init(alloc);
    defer names.deinit();
    var holes = std.Io.Writer.Allocating.init(alloc);
    defer holes.deinit();
    names.writer.writeAll("project_id") catch return false;
    holes.writer.writeAll("?") catch return false;
    for (spec.cols) |c| {
        names.writer.print(",{s}", .{c}) catch return false;
        holes.writer.writeAll(",?") catch return false;
    }
    const sql = std.fmt.allocPrintSentinel(alloc, "INSERT INTO {s}({s}) VALUES({s})", .{ spec.table, names.written(), holes.written() }, 0) catch return false;
    defer alloc.free(sql);
    const stmt = db.prepare(sql) catch return false;
    defer stmt.finalize();
    stmt.bind_text(1, pid);
    var col_idx: c_int = 2;
    for (spec.cols) |col| {
        if (isInt(spec, col)) {
            if (getJsonInt(row, col)) |iv| stmt.bind_int(col_idx, iv) else stmt.bind_null(col_idx);
        } else {
            if (getJsonStr(row, col)) |sv| stmt.bind_text(col_idx, sv) else stmt.bind_null(col_idx);
        }
        col_idx += 1;
    }
    _ = stmt.step() catch return false;
    return db.changes() > 0;
}

/// Ensure `<root>/.refract/overlay.json` is git-committable: create the dir and
/// whitelist the file in .refract/.gitignore (which otherwise ignores all).
/// Returns the overlay.json path (caller owns).
pub fn portablePath(alloc: std.mem.Allocator, root: []const u8) ?[]u8 {
    const dir = std.fmt.allocPrint(alloc, "{s}/.refract", .{root}) catch return null;
    defer alloc.free(dir);
    std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return null,
    };
    const gi = std.fmt.allocPrint(alloc, "{s}/.gitignore", .{dir}) catch return null;
    defer alloc.free(gi);
    const existing = std.Io.Dir.cwd().readFileAlloc(io, gi, alloc, std.Io.Limit.limited(64 * 1024)) catch null;
    if (existing) |body| {
        defer alloc.free(body);
        if (std.mem.indexOf(u8, body, "!overlay.json") == null) {
            const merged = std.fmt.allocPrint(alloc, "{s}\n!overlay.json\n", .{std.mem.trimEnd(u8, body, "\n")}) catch null;
            if (merged) |m| {
                defer alloc.free(m);
                std.Io.Dir.cwd().writeFile(io, .{ .sub_path = gi, .data = m }) catch {};
            }
        }
    } else {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = gi, .data = "*\n!.gitignore\n!overlay.json\n" }) catch {};
    }
    return std.fmt.allocPrint(alloc, "{s}/overlay.json", .{dir}) catch null;
}

test "gating rejects empty reason and oversize" {
    try std.testing.expectError(GateError.ReasonRequired, checkReason("   "));
    try std.testing.expectError(GateError.ReasonTooLong, checkReason("x" ** (MAX_REASON + 1)));
    try checkReason("valid reason");
    try std.testing.expect(parseOp("override").? == .override);
    try std.testing.expect(parseOp("bogus") == null);
}
