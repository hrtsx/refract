const std = @import("std");
const db_mod = @import("../db.zig");
const visit_ctx = @import("visit_ctx.zig");
const VisitCtx = visit_ctx.VisitCtx;

pub fn insertRef(db: db_mod.Db, file_id: i64, name: []const u8, line: i32, col: u32, scope_id: ?i64, kind: ?[]const u8, ref_ns: ?[]const u8) !void {
    const stmt = try db.prepare(
        \\INSERT OR IGNORE INTO refs (file_id, name, line, col, scope_id, kind, ref_ns)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_text(2, name);
    stmt.bind_int(3, line);
    stmt.bind_int(4, @intCast(col));
    if (scope_id) |sid| stmt.bind_int(5, sid) else stmt.bind_null(5);
    if (kind) |k| stmt.bind_text(6, k) else stmt.bind_null(6);
    if (ref_ns) |ns| (if (ns.len > 0) stmt.bind_text(7, ns) else stmt.bind_null(7)) else stmt.bind_null(7);
    _ = try stmt.step();
}

// Variant for ref insertions where call-site context is known (positional arg count and,
// when resolvable, receiver static type). The type checker reads these columns.
pub fn insertCallRef(
    db: db_mod.Db,
    file_id: i64,
    name: []const u8,
    line: i32,
    col: u32,
    scope_id: ?i64,
    arg_count: i64,
    receiver_type: ?[]const u8,
    is_self_send: bool,
) !void {
    const stmt = try db.prepare(
        \\INSERT OR IGNORE INTO refs (file_id, name, line, col, scope_id, arg_count, receiver_type, kind)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_text(2, name);
    stmt.bind_int(3, line);
    stmt.bind_int(4, @intCast(col));
    if (scope_id) |sid| stmt.bind_int(5, sid) else stmt.bind_null(5);
    stmt.bind_int(6, arg_count);
    if (receiver_type) |rt| stmt.bind_text(7, rt) else stmt.bind_null(7);
    stmt.bind_text(8, if (is_self_send) "self_call" else "call");
    _ = try stmt.step();
}

pub fn insertSymbol(ctx: *VisitCtx, kind: []const u8, name: []const u8, line: i32, col: u32, _: ?[]const u8) !void {
    const stmt = try ctx.db.prepare(
        \\INSERT OR IGNORE INTO symbols (file_id, name, kind, line, col)
        \\VALUES (?, ?, ?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, ctx.file_id);
    stmt.bind_text(2, name);
    stmt.bind_text(3, kind);
    stmt.bind_int(4, line);
    stmt.bind_int(5, @intCast(col));
    _ = try stmt.step();
}

pub fn insertSymbolWithReturn(ctx: *VisitCtx, kind: []const u8, name: []const u8, line: i32, col: u32, return_type: ?[]const u8, doc: ?[]const u8, parent_name: ?[]const u8, value_snippet: ?[]const u8) !void {
    const stmt = try ctx.db.prepare(
        \\INSERT OR IGNORE INTO symbols (file_id, name, kind, line, col, return_type, doc, parent_name, value_snippet)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, ctx.file_id);
    stmt.bind_text(2, name);
    stmt.bind_text(3, kind);
    stmt.bind_int(4, line);
    stmt.bind_int(5, @intCast(col));
    if (return_type) |rt| stmt.bind_text(6, rt) else stmt.bind_null(6);
    if (doc) |d| stmt.bind_text(7, d) else stmt.bind_null(7);
    if (parent_name) |pn| stmt.bind_text(8, pn) else stmt.bind_null(8);
    if (value_snippet) |vs| stmt.bind_text(9, vs) else stmt.bind_null(9);
    _ = try stmt.step();
}

pub fn insertSymbolGetId(ctx: *VisitCtx, kind: []const u8, name: []const u8, line: i32, col: u32, doc: ?[]const u8, end_line: ?i64, visibility: []const u8, parent_name: ?[]const u8) !i64 {
    const stmt = try ctx.db.prepare(
        \\INSERT INTO symbols (file_id, name, kind, line, col, doc, end_line, visibility, parent_name, deprecated)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        \\RETURNING id
    );
    defer stmt.finalize();
    stmt.bind_int(1, ctx.file_id);
    stmt.bind_text(2, name);
    stmt.bind_text(3, kind);
    stmt.bind_int(4, line);
    stmt.bind_int(5, @intCast(col));
    if (doc) |d| stmt.bind_text(6, d) else stmt.bind_null(6);
    if (end_line) |el| stmt.bind_int(7, el) else stmt.bind_null(7);
    stmt.bind_text(8, visibility);
    if (parent_name) |pn| stmt.bind_text(9, pn) else stmt.bind_null(9);
    const deprecated: i64 = if (doc) |d| (if (std.mem.indexOf(u8, d, "@deprecated") != null) 1 else 0) else 0;
    stmt.bind_int(10, deprecated);
    if (try stmt.step()) return stmt.column_int(0);
    return ctx.db.last_insert_rowid();
}

pub fn namespaceFromStack(ctx: *const VisitCtx, buf: []u8) []const u8 {
    var pos: usize = 0;
    for (ctx.namespace_stack[0..ctx.namespace_stack_len], 0..) |ns, i| {
        if (i > 0) {
            if (pos + 2 > buf.len) return buf[0..pos];
            buf[pos] = ':';
            buf[pos + 1] = ':';
            pos += 2;
        }
        if (pos + ns.len > buf.len) return buf[0..pos];
        @memcpy(buf[pos..][0..ns.len], ns);
        pos += ns.len;
    }
    return buf[0..pos];
}

pub fn insertParam(db: db_mod.Db, symbol_id: i64, position: u32, name: []const u8, kind: []const u8, type_hint: ?[]const u8, confidence: u8) !void {
    const stmt = try db.prepare(
        \\INSERT INTO params (symbol_id, position, name, kind, type_hint, confidence)
        \\VALUES (?, ?, ?, ?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, symbol_id);
    stmt.bind_int(2, @intCast(position));
    stmt.bind_text(3, name);
    stmt.bind_text(4, kind);
    if (type_hint) |th| stmt.bind_text(5, th) else stmt.bind_null(5);
    stmt.bind_int(6, @intCast(confidence));
    _ = try stmt.step();
}

pub fn insertLocalVar(db: db_mod.Db, file_id: i64, name: []const u8, line: i32, col: u32, type_hint: ?[]const u8, confidence: u8, scope_id: ?i64) !void {
    const stmt = try db.prepare(
        \\INSERT INTO local_vars (file_id, name, line, col, type_hint, confidence, scope_id)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(file_id, name, line, col) DO UPDATE SET
        \\  type_hint = CASE WHEN excluded.confidence > local_vars.confidence THEN excluded.type_hint ELSE local_vars.type_hint END,
        \\  confidence = MAX(excluded.confidence, local_vars.confidence)
    );
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_text(2, name);
    stmt.bind_int(3, line);
    stmt.bind_int(4, @intCast(col));
    if (type_hint) |th| stmt.bind_text(5, th) else stmt.bind_null(5);
    stmt.bind_int(6, @intCast(confidence));
    if (scope_id) |sid| stmt.bind_int(7, sid) else stmt.bind_null(7);
    _ = try stmt.step();
}

pub fn insertLocalVarClassId(db: db_mod.Db, file_id: i64, name: []const u8, line: i32, col: u32, type_hint: ?[]const u8, confidence: u8, class_id: ?i64) !void {
    const stmt = try db.prepare(
        \\INSERT INTO local_vars (file_id, name, line, col, type_hint, confidence, class_id)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(file_id, name, line, col) DO UPDATE SET
        \\  type_hint = CASE WHEN excluded.confidence > local_vars.confidence THEN excluded.type_hint ELSE local_vars.type_hint END,
        \\  confidence = MAX(excluded.confidence, local_vars.confidence),
        \\  class_id = CASE WHEN excluded.class_id IS NOT NULL THEN excluded.class_id ELSE local_vars.class_id END
    );
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_text(2, name);
    stmt.bind_int(3, line);
    stmt.bind_int(4, @intCast(col));
    if (type_hint) |th| stmt.bind_text(5, th) else stmt.bind_null(5);
    stmt.bind_int(6, @intCast(confidence));
    if (class_id) |cid| stmt.bind_int(7, cid) else stmt.bind_null(7);
    _ = try stmt.step();
}

pub fn insertMixin(db: db_mod.Db, class_id: i64, module_name: []const u8, kind: []const u8) !void {
    const stmt = try db.prepare(
        \\INSERT INTO mixins (class_id, module_name, kind) VALUES (?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, class_id);
    stmt.bind_text(2, module_name);
    stmt.bind_text(3, kind);
    _ = try stmt.step();
}
