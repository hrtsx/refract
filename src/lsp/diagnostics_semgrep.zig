const std = @import("std");
const db_mod = @import("../db.zig");

/// Parse a `semgrep --json` payload and persist findings into `semgrep_findings`.
/// Schema (semgrep 1.x):
///   { "results": [
///       { "check_id": "...", "path": "app/x.rb",
///         "start": { "line": 12, "col": 4 },
///         "end":   { "line": 12, "col": 32 },
///         "extra": { "message": "...", "severity": "ERROR|WARNING|INFO" } }, ...
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
    const results = parsed.value.object.get("results") orelse return 0;
    if (results != .array) return 0;

    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds(), std.time.ns_per_us));

    db_mu.lockUncancelable(std.Options.debug_io);
    defer db_mu.unlock(std.Options.debug_io);

    const ins = try db.prepare(
        "INSERT INTO semgrep_findings(file_id, line, rule_id, severity, message, fingerprint, run_id, ts_us) VALUES(?,?,?,?,?,?,?,?)",
    );
    defer ins.finalize();

    var rows: u32 = 0;
    for (results.array.items) |r| {
        if (r != .object) continue;
        const o = r.object;
        const path_v = o.get("path") orelse continue;
        if (path_v != .string) continue;
        const rule_v = o.get("check_id") orelse continue;
        if (rule_v != .string) continue;
        const start_v = o.get("start") orelse continue;
        if (start_v != .object) continue;
        const line_v = start_v.object.get("line") orelse continue;
        const line: i64 = switch (line_v) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => continue,
        };
        const extra_v = o.get("extra");
        const message: []const u8 = blk: {
            if (extra_v) |ev| if (ev == .object) {
                if (ev.object.get("message")) |m| if (m == .string) break :blk m.string;
            };
            break :blk rule_v.string;
        };
        const sev: i64 = blk: {
            if (extra_v) |ev| if (ev == .object) {
                if (ev.object.get("severity")) |s| if (s == .string) break :blk severityFromString(s.string);
            };
            break :blk 2;
        };

        const fp = std.fmt.allocPrint(alloc, "{s}:{s}:{d}", .{ rule_v.string, path_v.string, line }) catch continue;
        defer alloc.free(fp);

        const file_id = upsertFile(db, workspace_root, alloc, path_v.string) catch continue;

        ins.reset();
        ins.bind_int(1, file_id);
        ins.bind_int(2, line);
        ins.bind_text(3, rule_v.string);
        ins.bind_int(4, sev);
        ins.bind_text(5, message);
        ins.bind_text(6, fp);
        if (run_id) |rid| ins.bind_int(7, rid) else ins.bind_null(7);
        ins.bind_int(8, ts);
        _ = ins.step() catch continue;
        rows += 1;
    }
    return rows;
}

fn severityFromString(s: []const u8) i64 {
    if (std.ascii.eqlIgnoreCase(s, "ERROR")) return 1;
    if (std.ascii.eqlIgnoreCase(s, "WARNING")) return 2;
    return 3; // INFO / unknown
}

fn upsertFile(db: db_mod.Db, workspace_root: []const u8, alloc: std.mem.Allocator, file_rel: []const u8) !i64 {
    const abs = if (std.fs.path.isAbsolute(file_rel))
        try alloc.dupe(u8, file_rel)
    else
        try std.fs.path.join(alloc, &.{ workspace_root, file_rel });
    defer alloc.free(abs);
    // INSERT OR IGNORE then SELECT is race-safe: a concurrent insert can't make
    // us hand back a wrong id or trip the UNIQUE(path) constraint.
    const ins = try db.prepare("INSERT OR IGNORE INTO files(path, mtime) VALUES(?, 0)");
    defer ins.finalize();
    ins.bind_text(1, abs);
    _ = try ins.step();
    const sel = try db.prepare("SELECT id FROM files WHERE path = ?");
    defer sel.finalize();
    sel.bind_text(1, abs);
    if (try sel.step()) return sel.column_int(0);
    return error.FileUpsertFailed;
}

test "ingest stores semgrep result with severity mapping" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    var mu: std.Io.Mutex = std.Io.Mutex.init;
    const json =
        \\{"results":[
        \\  {"check_id":"ruby.lang.security.sql","path":"app/m.rb","start":{"line":15,"col":1},"end":{"line":15,"col":40},"extra":{"message":"sql injection","severity":"ERROR"}},
        \\  {"check_id":"ruby.lang.style.naming","path":"app/v.rb","start":{"line":3,"col":1},"end":{"line":3,"col":10},"extra":{"severity":"INFO"}}
        \\]}
    ;
    const rows = try ingest(alloc, db, &mu, "/tmp/ws", json, null);
    try std.testing.expectEqual(@as(u32, 2), rows);

    const sel = try db.prepare("SELECT severity, rule_id FROM semgrep_findings ORDER BY line");
    defer sel.finalize();
    try std.testing.expect(try sel.step());
    try std.testing.expectEqual(@as(i64, 3), sel.column_int(0)); // INFO
    try std.testing.expect(try sel.step());
    try std.testing.expectEqual(@as(i64, 1), sel.column_int(0)); // ERROR
    try std.testing.expectEqualStrings("ruby.lang.security.sql", sel.column_text(1));
}
