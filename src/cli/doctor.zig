const std = @import("std");
const db_mod = @import("../db.zig");
const build_meta = @import("build_meta");

pub const Status = enum {
    ok,
    warn,
    fail,
};

pub const Check = struct {
    name: []const u8,
    status: Status,
    detail: []const u8,
    fix: ?[]const u8 = null,
};

pub const DoctorOptions = struct {
    json: bool = false,
    repair: bool = false,
    no_color: bool = false,
};

pub fn runDoctor(
    io: std.Io,
    db_path: []const u8,
    _: []const u8,
    opts: DoctorOptions,
    alloc: std.mem.Allocator,
) !void {
    var checks = std.ArrayList(Check).empty;
    defer {
        for (checks.items) |c| {
            alloc.free(c.name);
            alloc.free(c.detail);
            if (c.fix) |f| alloc.free(f);
        }
        checks.deinit(alloc);
    }

    try checkBasics(alloc, &checks);
    try checkDatabase(io, db_path, alloc, &checks);

    if (opts.repair) {
        try performRepairs(io, db_path, alloc);
    }

    if (opts.json) {
        try outputJson(io, checks.items, alloc);
    } else {
        try outputFormatted(io, checks.items, opts.no_color);
    }
}

fn checkBasics(alloc: std.mem.Allocator, checks: *std.ArrayList(Check)) !void {
    try checks.append(alloc, .{
        .name = try alloc.dupe(u8, "Refract version"),
        .status = .ok,
        .detail = try alloc.dupe(u8, build_meta.version),
    });

    try checks.append(alloc, .{
        .name = try alloc.dupe(u8, "Git commit"),
        .status = .ok,
        .detail = try alloc.dupe(u8, build_meta.git_sha),
    });

    try checks.append(alloc, .{
        .name = try alloc.dupe(u8, "Zig version"),
        .status = .ok,
        .detail = try alloc.dupe(u8, build_meta.zig_version),
    });

    const os_name = @tagName(@import("builtin").os.tag);
    try checks.append(alloc, .{
        .name = try alloc.dupe(u8, "Operating system"),
        .status = .ok,
        .detail = try alloc.dupe(u8, os_name),
    });
}

fn checkDatabase(
    io: std.Io,
    db_path: []const u8,
    alloc: std.mem.Allocator,
    checks: *std.ArrayList(Check),
) !void {
    const db_pathz = try alloc.dupeZ(u8, db_path);
    defer alloc.free(db_pathz);

    const db = db_mod.Db.open(db_pathz) catch {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Database"),
            .status = .fail,
            .detail = try alloc.dupe(u8, "Could not open database"),
            .fix = try alloc.dupe(u8, "Run `refract --reset-db` to rebuild the database"),
        });
        return;
    };
    defer db.close();

    db.init_schema() catch {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Database"),
            .status = .fail,
            .detail = try alloc.dupe(u8, "Database schema initialization failed"),
            .fix = try alloc.dupe(u8, "Run `refract --reset-db` to rebuild the database"),
        });
        return;
    };

    try checks.append(alloc, .{
        .name = try alloc.dupe(u8, "Database"),
        .status = .ok,
        .detail = try alloc.dupe(u8, db_path),
    });

    const schema_ver = db.getSchemaVersion() orelse 0;
    if (schema_ver == 5) {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Database schema"),
            .status = .ok,
            .detail = try std.fmt.allocPrint(alloc, "v{d}", .{schema_ver}),
        });
    } else {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Database schema"),
            .status = .fail,
            .detail = try std.fmt.allocPrint(alloc, "v{d} (expected v5)", .{schema_ver}),
            .fix = try alloc.dupe(u8, "Run `refract --reset-db` to rebuild the database"),
        });
    }

    const stat = std.Io.Dir.cwd().statFile(io, db_path, .{}) catch |e| {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Database size"),
            .status = .warn,
            .detail = try std.fmt.allocPrint(alloc, "Could not stat: {s}", .{@errorName(e)}),
        });
        return;
    };

    const size_mb = @as(f64, @floatFromInt(stat.size)) / (1024.0 * 1024.0);
    if (size_mb < 1024.0) {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Database size"),
            .status = .ok,
            .detail = try std.fmt.allocPrint(alloc, "{d:.1} MB", .{size_mb}),
        });
    } else {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Database size"),
            .status = .warn,
            .detail = try std.fmt.allocPrint(alloc, "{d:.1} MB", .{size_mb}),
            .fix = try alloc.dupe(u8, "Run `refract doctor --repair` to checkpoint the WAL file"),
        });
    }

    var symbol_count: i64 = 0;
    if (db.prepare("SELECT COUNT(*) FROM symbols")) |stmt| {
        defer stmt.finalize();
        if (try stmt.step()) {
            symbol_count = stmt.column_int(0);
        }
    } else |_| {}

    if (symbol_count > 0) {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Hot index"),
            .status = .ok,
            .detail = try std.fmt.allocPrint(alloc, "{d} symbols", .{symbol_count}),
        });
    } else {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Hot index"),
            .status = .warn,
            .detail = try alloc.dupe(u8, "No symbols indexed"),
            .fix = try alloc.dupe(u8, "Run `refract --index-only` to index your workspace"),
        });
    }
}

fn performRepairs(
    _: std.Io,
    db_path: []const u8,
    alloc: std.mem.Allocator,
) !void {
    const db_pathz = try alloc.dupeZ(u8, db_path);
    defer alloc.free(db_pathz);

    const db = db_mod.Db.open(db_pathz) catch return;
    defer db.close();

    db.init_schema() catch return;

    db.checkpoint();
    std.debug.print("[repaired] Database WAL checkpoint\n", .{});
}

fn outputFormatted(io: std.Io, checks: []const Check, no_color: bool) !void {
    const stdout = std.Io.File.stdout();
    var buf: [8192]u8 = undefined;
    var fw = stdout.writerStreaming(io, &buf);
    const w = &fw.interface;

    try w.writeAll("refract --doctor\n");
    try w.writeAll("================\n\n");

    for (checks) |check| {
        const status_marker = switch (check.status) {
            .ok => if (no_color) "[ok]" else "\x1b[32m✓\x1b[0m",
            .warn => if (no_color) "[warn]" else "\x1b[33m⚠\x1b[0m",
            .fail => if (no_color) "[fail]" else "\x1b[31m✗\x1b[0m",
        };

        var line_buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "{s} {s:30} {s}\n", .{ status_marker, check.name, check.detail });
        try w.writeAll(line);

        if (check.fix) |fix| {
            var fix_buf: [256]u8 = undefined;
            const fix_line = try std.fmt.bufPrint(&fix_buf, "  → {s}\n", .{fix});
            try w.writeAll(fix_line);
        }
    }

    try w.flush();
}

fn outputJson(io: std.Io, checks: []const Check, alloc: std.mem.Allocator) !void {
    var aw = std.Io.Writer.Allocating.init(alloc);
    const w = &aw.writer;

    try w.writeAll("{\"refract\":\"");
    try w.writeAll(build_meta.version);
    try w.writeAll("\",\"git\":\"");
    try w.writeAll(build_meta.git_sha);
    try w.writeAll("\",\"checks\":[");

    for (checks, 0..) |check, idx| {
        if (idx > 0) try w.writeAll(",");

        try w.writeAll("{\"name\":\"");
        try w.writeAll(check.name);
        try w.writeAll("\",\"status\":\"");
        try w.writeAll(@tagName(check.status));
        try w.writeAll("\",\"detail\":\"");
        try writeJsonEscape(w, check.detail);
        try w.writeAll("\"");

        if (check.fix) |fix| {
            try w.writeAll(",\"fix\":\"");
            try writeJsonEscape(w, fix);
            try w.writeAll("\"");
        }

        try w.writeAll("}");
    }

    try w.writeAll("]}");
    const result = try aw.toOwnedSlice();
    defer alloc.free(result);
    try std.Io.File.stdout().writeStreamingAll(io, result);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

fn writeJsonEscape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
}
