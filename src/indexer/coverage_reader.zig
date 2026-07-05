const std = @import("std");
const db_mod = @import("../db.zig");

/// Parse SimpleCov `.resultset.json` and persist into `coverage_lines`.
///
/// SimpleCov v0.20+ structure (we accept both):
///   {
///     "<command_name>": {
///       "coverage": {
///         "<absolute path>.rb": { "lines": [null, 1, 0, 5, ...] }
///       },
///       "timestamp": 1714000000
///     }
///   }
///
/// `lines` array is 0-indexed by source line - 1 (i.e. element 0 is line 1).
/// Values: `null` = not executable, `int` = hit count.
///
/// Older format used `coverage` mapped directly to a flat array per file —
/// we handle that too via `coverageFromValue`.
pub fn ingest(
    alloc: std.mem.Allocator,
    db: db_mod.Db,
    db_mu: *std.Io.Mutex,
    workspace_id: ?i64,
    json_bytes: []const u8,
    run_id: ?i64,
) !u32 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return 0;

    var rows: u32 = 0;
    var top_it = parsed.value.object.iterator();
    while (top_it.next()) |entry| {
        const inner = entry.value_ptr.*;
        if (inner != .object) continue;
        const cov_v = inner.object.get("coverage") orelse continue;
        if (cov_v != .object) continue;
        var cov_it = cov_v.object.iterator();
        while (cov_it.next()) |fe| {
            const path = fe.key_ptr.*;
            const lines_arr = coverageFromValue(fe.value_ptr.*) orelse continue;
            rows += try writeCoverage(alloc, db, db_mu, workspace_id, path, lines_arr, run_id);
        }
    }
    return rows;
}

fn coverageFromValue(v: std.json.Value) ?[]std.json.Value {
    return switch (v) {
        .array => |arr| arr.items,
        .object => |obj| blk: {
            const lines = obj.get("lines") orelse break :blk null;
            if (lines != .array) break :blk null;
            break :blk lines.array.items;
        },
        else => null,
    };
}

fn writeCoverage(
    alloc: std.mem.Allocator,
    db: db_mod.Db,
    db_mu: *std.Io.Mutex,
    workspace_id: ?i64,
    path: []const u8,
    lines: []std.json.Value,
    run_id: ?i64,
) !u32 {
    db_mu.lockUncancelable(std.Options.debug_io);
    defer db_mu.unlock(std.Options.debug_io);

    // Resolve file_id, inserting a placeholder row if absent.
    const file_id = blk: {
        const sel = try db.prepare("SELECT id FROM files WHERE path = ?");
        defer sel.finalize();
        sel.bind_text(1, path);
        if (try sel.step()) break :blk sel.column_int(0);
        const ins = try db.prepare("INSERT INTO files(path, mtime) VALUES(?, 0)");
        defer ins.finalize();
        ins.bind_text(1, path);
        _ = try ins.step();
        break :blk db.last_insert_rowid();
    };

    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds(), std.time.ns_per_us));

    // Wipe-then-insert must be atomic so a partial failure never leaves the
    // file with old coverage gone and new coverage incomplete.
    try db.begin();
    errdefer db.rollback() catch {};

    // Wipe any previous coverage for this file so re-ingestion is idempotent.
    {
        const del = try db.prepare("DELETE FROM coverage_lines WHERE file_id = ?");
        defer del.finalize();
        del.bind_int(1, file_id);
        _ = try del.step();
    }

    const ins = try db.prepare("INSERT INTO coverage_lines(workspace_id, file_id, line, hits, run_id, ts_us) VALUES(?,?,?,?,?,?)");
    defer ins.finalize();

    var written: u32 = 0;
    var line_no: i64 = 1;
    for (lines) |v| {
        defer line_no += 1;
        const hits: i64 = switch (v) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => continue, // null = non-executable, skip
        };
        ins.reset();
        if (workspace_id) |w| ins.bind_int(1, w) else ins.bind_null(1);
        ins.bind_int(2, file_id);
        ins.bind_int(3, line_no);
        ins.bind_int(4, hits);
        if (run_id) |r| ins.bind_int(5, r) else ins.bind_null(5);
        ins.bind_int(6, ts);
        _ = ins.step() catch continue;
        written += 1;
    }
    try db.commit();
    _ = alloc; // reserved for future per-line context allocations
    return written;
}

test "ingest stores per-line hits, skips null, idempotent" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    var mu: std.Io.Mutex = std.Io.Mutex.init;

    const json =
        \\{"RSpec":{"coverage":{"app/foo.rb":{"lines":[null,1,0,5,null,2]}},"timestamp":1714000000}}
    ;
    const wrote = try ingest(alloc, db, &mu, null, json, null);
    try std.testing.expectEqual(@as(u32, 4), wrote); // 4 executable lines (2,3,4,6)

    const sel = try db.prepare(
        "SELECT line, hits FROM coverage_lines WHERE file_id IN (SELECT id FROM files WHERE path='app/foo.rb') ORDER BY line",
    );
    defer sel.finalize();
    var seen: u32 = 0;
    var saw_zero = false;
    while (try sel.step()) {
        seen += 1;
        if (sel.column_int(1) == 0) saw_zero = true;
    }
    try std.testing.expectEqual(@as(u32, 4), seen);
    try std.testing.expect(saw_zero);

    // Re-ingest replaces, not duplicates.
    _ = try ingest(alloc, db, &mu, null, json, null);
    const cnt_stmt = try db.prepare("SELECT COUNT(*) FROM coverage_lines");
    defer cnt_stmt.finalize();
    try std.testing.expect(try cnt_stmt.step());
    try std.testing.expectEqual(@as(i64, 4), cnt_stmt.column_int(0));
}

test "ingest tolerates legacy flat-array format" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    var mu: std.Io.Mutex = std.Io.Mutex.init;

    const json =
        \\{"Old":{"coverage":{"lib/x.rb":[null,1,2]}}}
    ;
    const wrote = try ingest(alloc, db, &mu, null, json, null);
    try std.testing.expectEqual(@as(u32, 2), wrote);
}
