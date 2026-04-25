const std = @import("std");
const db_mod = @import("../db.zig");

/// Parse a Brakeman `--format json` payload and persist findings into
/// `brakeman_findings`. Schema (Brakeman 7.x):
///   { "warnings": [
///       { "warning_code": 14, "warning_type": "...", "check_name": "...",
///         "message": "...", "file": "app/x.rb", "line": 12,
///         "fingerprint": "...", "confidence": "High|Medium|Weak" }, ...
///   ] }
pub fn ingest(
    alloc: std.mem.Allocator,
    db: db_mod.Db,
    db_mu: *std.Io.Mutex,
    workspace_root: []const u8,
    json_bytes: []const u8,
    run_id: ?i64,
) !u32 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return 0;
    const warnings = parsed.value.object.get("warnings") orelse return 0;
    if (warnings != .array) return 0;

    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds(), std.time.ns_per_us));

    db_mu.lockUncancelable(std.Options.debug_io);
    defer db_mu.unlock(std.Options.debug_io);

    const ins = try db.prepare(
        "INSERT INTO brakeman_findings(file_id, line, code, severity, message, fingerprint, run_id, ts_us) VALUES(?,?,?,?,?,?,?,?)",
    );
    defer ins.finalize();

    var rows: u32 = 0;
    for (warnings.array.items) |w| {
        if (w != .object) continue;
        const o = w.object;
        const file_v = o.get("file") orelse continue;
        if (file_v != .string) continue;
        const file_rel = file_v.string;
        const line_v = o.get("line") orelse continue;
        const line: i64 = switch (line_v) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => continue,
        };
        const msg_v = o.get("message") orelse continue;
        if (msg_v != .string) continue;
        const code_v = o.get("warning_type");
        const code_str: []const u8 = if (code_v) |cv| (if (cv == .string) cv.string else "brakeman") else "brakeman";
        const conf_v = o.get("confidence");
        const sev: i64 = if (conf_v) |c|
            (if (c == .string) confidenceToSeverity(c.string) else 2)
        else
            2;
        const fp_v = o.get("fingerprint");
        const fp: []const u8 = if (fp_v) |fpv| (if (fpv == .string) fpv.string else "") else "";

        const file_id = upsertFile(db, workspace_root, alloc, file_rel) catch continue;

        ins.reset();
        ins.bind_int(1, file_id);
        ins.bind_int(2, line);
        ins.bind_text(3, code_str);
        ins.bind_int(4, sev);
        ins.bind_text(5, msg_v.string);
        if (fp.len > 0) ins.bind_text(6, fp) else ins.bind_null(6);
        if (run_id) |r| ins.bind_int(7, r) else ins.bind_null(7);
        ins.bind_int(8, ts);
        _ = ins.step() catch continue;
        rows += 1;
    }
    return rows;
}

/// Brakeman `confidence` → LSP severity. High → 1 (Error), Medium → 2 (Warning),
/// Weak → 3 (Information).
fn confidenceToSeverity(s: []const u8) i64 {
    if (std.ascii.eqlIgnoreCase(s, "high")) return 1;
    if (std.ascii.eqlIgnoreCase(s, "medium")) return 2;
    return 3;
}

fn upsertFile(db: db_mod.Db, workspace_root: []const u8, alloc: std.mem.Allocator, file_rel: []const u8) !i64 {
    const abs = if (std.fs.path.isAbsolute(file_rel))
        try alloc.dupe(u8, file_rel)
    else
        try std.fs.path.join(alloc, &.{ workspace_root, file_rel });
    defer alloc.free(abs);
    const sel = try db.prepare("SELECT id FROM files WHERE path = ?");
    defer sel.finalize();
    sel.bind_text(1, abs);
    if (try sel.step()) return sel.column_int(0);
    const ins = try db.prepare("INSERT INTO files(path, mtime) VALUES(?, 0)");
    defer ins.finalize();
    ins.bind_text(1, abs);
    _ = try ins.step();
    return db.last_insert_rowid();
}

test "ingest stores brakeman warning with severity from confidence" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    var mu: std.Io.Mutex = std.Io.Mutex.init;
    const json =
        \\{"warnings":[
        \\  {"warning_type":"SQL","message":"unscoped find","file":"app/m.rb","line":10,"fingerprint":"abc","confidence":"High"},
        \\  {"warning_type":"XSS","message":"raw output","file":"app/v.rb","line":3,"confidence":"Weak"}
        \\]}
    ;
    const rows = try ingest(alloc, db, &mu, "/tmp/ws", json, null);
    try std.testing.expectEqual(@as(u32, 2), rows);

    const sel = try db.prepare("SELECT severity, code, fingerprint FROM brakeman_findings ORDER BY line");
    defer sel.finalize();
    try std.testing.expect(try sel.step());
    try std.testing.expectEqual(@as(i64, 3), sel.column_int(0)); // line 3 = XSS, weak → 3
    try std.testing.expectEqualStrings("XSS", sel.column_text(1));
    try std.testing.expect(try sel.step());
    try std.testing.expectEqual(@as(i64, 1), sel.column_int(0));
    try std.testing.expectEqualStrings("SQL", sel.column_text(1));
    try std.testing.expectEqualStrings("abc", sel.column_text(2));
}
