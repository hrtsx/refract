// Index lifecycle CLI: list / gc / vacuum-all over the per-project databases
// under the refract data dir. Derived dbs are rebuildable and may be evicted
// (LRU by size cap and/or age); databases that still hold live overlay tweaks
// are never auto-evicted — those are the precious, hard-to-recreate layer.

const std = @import("std");
const db_mod = @import("../db.zig");
const server = @import("../lsp/server.zig");
const io = std.Options.debug_io;

const ProjectInfo = struct {
    name: []u8, // db filename
    path: []u8, // absolute db path
    size: u64,
    mtime_ns: i128,
    files: i64 = 0,
    symbols: i64 = 0,
    overlay: i64 = 0,
    project_id: []u8,
    branch: []u8,

    fn deinit(self: ProjectInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.path);
        alloc.free(self.project_id);
        alloc.free(self.branch);
    }
};

fn out(s: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, s) catch {};
}

fn metaStr(db: db_mod.Db, alloc: std.mem.Allocator, key: []const u8) []u8 {
    const stmt = db.prepare("SELECT value FROM meta WHERE key=?") catch return alloc.dupe(u8, "") catch @constCast("");
    defer stmt.finalize();
    stmt.bind_text(1, key);
    if (stmt.step() catch false) return alloc.dupe(u8, stmt.column_text(0)) catch @constCast("");
    return alloc.dupe(u8, "") catch @constCast("");
}

fn scalar(db: db_mod.Db, sql: [*:0]const u8) i64 {
    const stmt = db.prepare(sql) catch return 0;
    defer stmt.finalize();
    if (stmt.step() catch false) return stmt.column_int(0);
    return 0;
}

/// Collect info for every *.db under the data dir. Caller frees each item.
fn collect(alloc: std.mem.Allocator) !std.ArrayListUnmanaged(ProjectInfo) {
    var list: std.ArrayListUnmanaged(ProjectInfo) = .empty;
    const dir_path = try server.computeDataDir(alloc);
    defer alloc.free(dir_path);
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return list;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".db")) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        const full = std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ dir_path, entry.name }, 0) catch continue;
        var info = ProjectInfo{
            .name = alloc.dupe(u8, entry.name) catch continue,
            .path = full,
            .size = stat.size,
            .mtime_ns = stat.mtime.toNanoseconds(),
            .project_id = @constCast(""),
            .branch = @constCast(""),
        };
        if (db_mod.Db.openReadOnly(full)) |db| {
            defer db.close();
            info.files = scalar(db, "SELECT COUNT(*) FROM files WHERE is_gem=0");
            info.symbols = scalar(db, "SELECT COUNT(*) FROM symbols");
            info.overlay = scalar(db,
                \\SELECT
                \\ (SELECT COUNT(*) FROM overlay_nodes WHERE revoked_at IS NULL)
                \\+(SELECT COUNT(*) FROM overlay_edges WHERE revoked_at IS NULL)
                \\+(SELECT COUNT(*) FROM overlay_types WHERE revoked_at IS NULL)
                \\+(SELECT COUNT(*) FROM overlay_suppress WHERE revoked_at IS NULL)
            );
            info.project_id = metaStr(db, alloc, "project_id");
            info.branch = metaStr(db, alloc, "git_branch");
        } else |_| {}
        try list.append(alloc, info);
    }
    return list;
}

fn fmtSize(buf: []u8, bytes: u64) []const u8 {
    const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
    return std.fmt.bufPrint(buf, "{d:.1}MB", .{mb}) catch "?";
}

pub fn listProjects(parent_alloc: std.mem.Allocator, json: bool) !void {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const list = try collect(alloc);
    if (json) {
        var aw = std.Io.Writer.Allocating.init(alloc);
        defer aw.deinit();
        const w = &aw.writer;
        try w.writeByte('[');
        for (list.items, 0..) |p, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{{\"db\":\"{s}\",\"size_bytes\":{d},\"files\":{d},\"symbols\":{d},\"overlay\":{d},\"project_id\":\"{s}\",\"branch\":\"{s}\"}}", .{ p.name, p.size, p.files, p.symbols, p.overlay, p.project_id, p.branch });
        }
        try w.writeAll("]\n");
        out(aw.written());
        return;
    }
    var total: u64 = 0;
    var hdr: [256]u8 = undefined;
    out(std.fmt.bufPrint(&hdr, "{s:<18} {s:>9}  {s}\n", .{ "DB", "SIZE", "COUNTS / PROJECT / BRANCH" }) catch "");
    for (list.items) |p| {
        total += p.size;
        var szbuf: [32]u8 = undefined;
        var line: [512]u8 = undefined;
        const tag = if (p.overlay > 0) " *" else "";
        const pid_short = if (p.project_id.len > 16) p.project_id[0..16] else p.project_id;
        out(std.fmt.bufPrint(&line, "{s:<18} {s:>9}  files={d} symbols={d} overlay={d}{s}  {s} {s}\n", .{ p.name, fmtSize(&szbuf, p.size), p.files, p.symbols, p.overlay, tag, pid_short, p.branch }) catch "");
    }
    var foot: [128]u8 = undefined;
    var tbuf: [32]u8 = undefined;
    out(std.fmt.bufPrint(&foot, "{d} project(s), {s} total. (* = has overlay tweaks, never auto-evicted)\n", .{ list.items.len, fmtSize(&tbuf, total) }) catch "");
}

pub const GcOptions = struct {
    size_cap_mb: ?u64 = null,
    age_days: ?u32 = null,
    dry_run: bool = false,
    now_ns: i128,
};

fn removeDb(path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var buf: [512]u8 = undefined;
    const sufs = [_][]const u8{ "-wal", "-shm" };
    for (sufs) |suf| {
        const p = std.fmt.bufPrint(&buf, "{s}{s}", .{ path, suf }) catch continue;
        std.Io.Dir.cwd().deleteFile(io, p) catch {};
    }
}

pub fn gc(parent_alloc: std.mem.Allocator, opts: GcOptions) !void {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const list = try collect(alloc);
    // LRU order: oldest first.
    std.mem.sort(ProjectInfo, list.items, {}, struct {
        fn lt(_: void, a: ProjectInfo, b: ProjectInfo) bool {
            return a.mtime_ns < b.mtime_ns;
        }
    }.lt);

    var total: u64 = 0;
    for (list.items) |p| total += p.size;
    const cap_bytes: ?u64 = if (opts.size_cap_mb) |m| m * 1024 * 1024 else null;
    const age_cutoff: ?i128 = if (opts.age_days) |d| opts.now_ns - @as(i128, d) * 24 * 60 * 60 * std.time.ns_per_s else null;

    var freed: u64 = 0;
    var evicted: usize = 0;
    var line: [512]u8 = undefined;
    for (list.items) |p| {
        if (p.overlay > 0) continue; // never auto-evict overlay-bearing dbs
        var reason: ?[]const u8 = null;
        if (age_cutoff) |c| {
            if (p.mtime_ns < c) reason = "age";
        }
        if (reason == null and cap_bytes != null and (total - freed) > cap_bytes.?) {
            reason = "size-cap";
        }
        if (reason) |r| {
            var szbuf: [32]u8 = undefined;
            const verb = if (opts.dry_run) "would evict" else "evict";
            out(std.fmt.bufPrint(&line, "{s} {s} ({s}, {s})\n", .{ verb, p.name, fmtSize(&szbuf, p.size), r }) catch "");
            if (!opts.dry_run) removeDb(p.path);
            freed += p.size;
            evicted += 1;
        }
    }
    var foot: [128]u8 = undefined;
    var fbuf: [32]u8 = undefined;
    const verb = if (opts.dry_run) "would free" else "freed";
    out(std.fmt.bufPrint(&foot, "{d} db(s) {s}, {s} {s}.\n", .{ evicted, if (opts.dry_run) "to evict" else "evicted", verb, fmtSize(&fbuf, freed) }) catch "");
}

pub fn vacuumAll(parent_alloc: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const list = try collect(alloc);
    var n: usize = 0;
    for (list.items) |p| {
        const pz = std.fmt.allocPrintSentinel(alloc, "{s}", .{p.path}, 0) catch continue;
        defer alloc.free(pz);
        const db = db_mod.Db.open(pz) catch continue;
        defer db.close();
        db.runOptimize();
        db.runVacuum();
        db.checkpoint();
        n += 1;
    }
    var foot: [96]u8 = undefined;
    out(std.fmt.bufPrint(&foot, "vacuumed {d} database(s).\n", .{n}) catch "");
}
