const std = @import("std");
const db_mod = @import("../db.zig");
const build_meta = @import("build_meta");
const ruby_env = @import("../indexer/ruby_env.zig");
const coverage_reader = @import("../indexer/coverage_reader.zig");
const TimeoutCtx = @import("../lsp/server.zig").TimeoutCtx;

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
    cwd: []const u8,
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
    try checkRdbg(alloc, &checks);
    try checkRubyEnv(alloc, cwd, &checks);
    try checkPrismVendor(alloc, &checks);
    try checkOtlpEndpoint(alloc, &checks);
    try checkDbLock(alloc, db_path, &checks);
    try checkSchemaIntegrity(alloc, db_path, &checks);
    try checkGemCoverage(alloc, db_path, &checks);

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
    const expected: u32 = 7;
    if (schema_ver == expected) {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Database schema version"),
            .status = .ok,
            .detail = try std.fmt.allocPrint(alloc, "v{d}", .{schema_ver}),
        });
    } else {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Database schema version"),
            .status = .fail,
            .detail = try std.fmt.allocPrint(alloc, "v{d} (expected v{d})", .{ schema_ver, expected }),
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

fn checkRdbg(alloc: std.mem.Allocator, checks: *std.ArrayList(Check)) !void {
    const rdbg_bin: []const u8 = if (std.c.getenv("RDBG_BIN")) |v| std.mem.span(v) else "rdbg";
    const argv: []const []const u8 = &.{ rdbg_bin, "--version" };

    var child = std.process.spawn(std.Options.debug_io, .{
        .argv = argv,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "rdbg"),
            .status = .warn,
            .detail = try alloc.dupe(u8, "not found"),
            .fix = try alloc.dupe(u8, "gem install debug"),
        });
        return;
    };
    var ctx = TimeoutCtx{
        .child = &child,
        .done = std.atomic.Value(bool).init(false),
        .timeout_ns = 2 * std.time.ns_per_s,
    };
    const kill_thread = std.Thread.spawn(.{}, TimeoutCtx.run, .{&ctx}) catch null;
    const wait_result = child.wait(std.Options.debug_io) catch null;
    ctx.done.store(true, .release);
    if (kill_thread) |t| t.join();

    if (wait_result != null and wait_result.? == .exited and wait_result.?.exited == 0) {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "rdbg"),
            .status = .ok,
            .detail = try alloc.dupe(u8, "found on PATH"),
        });
    } else {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "rdbg"),
            .status = .warn,
            .detail = try alloc.dupe(u8, "not found"),
            .fix = try alloc.dupe(u8, "gem install debug"),
        });
    }
}

fn checkRubyEnv(alloc: std.mem.Allocator, cwd: []const u8, checks: *std.ArrayList(Check)) !void {
    if (cwd.len > 0) {
        const env = ruby_env.detect(alloc, cwd) catch {
            try checks.append(alloc, .{
                .name = try alloc.dupe(u8, "Ruby environment"),
                .status = .warn,
                .detail = try alloc.dupe(u8, "detection failed"),
                .fix = try alloc.dupe(u8, "install chruby/rbenv/asdf/mise or set RUBYBIN"),
            });
            return;
        };
        defer {
            if (env.version) |v| alloc.free(v);
            if (env.ruby_path) |p| alloc.free(p);
        }

        if (env.source == .path_default) {
            try checks.append(alloc, .{
                .name = try alloc.dupe(u8, "Ruby environment"),
                .status = .warn,
                .detail = try alloc.dupe(u8, "no version manager detected"),
                .fix = try alloc.dupe(u8, "install chruby/rbenv/asdf/mise or set RUBYBIN"),
            });
        } else {
            const detail = try std.fmt.allocPrint(alloc, "{s} ({s})", .{
                if (env.version) |v| v else "default",
                env.source.label(),
            });
            try checks.append(alloc, .{
                .name = try alloc.dupe(u8, "Ruby environment"),
                .status = .ok,
                .detail = detail,
            });
        }
    } else {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Ruby environment"),
            .status = .warn,
            .detail = try alloc.dupe(u8, "workspace unknown"),
            .fix = try alloc.dupe(u8, "install chruby/rbenv/asdf/mise or set RUBYBIN"),
        });
    }
}

fn checkPrismVendor(alloc: std.mem.Allocator, checks: *std.ArrayList(Check)) !void {
    const header_path = "vendor/prism/include/prism.h";
    const source_path = "vendor/prism/src/prism.c";

    const h_stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, header_path, .{}) catch null;
    const c_stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, source_path, .{}) catch null;

    if (h_stat != null and c_stat != null and h_stat.?.size > 0 and c_stat.?.size > 0) {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Prism vendor"),
            .status = .ok,
            .detail = try std.fmt.allocPrint(alloc, "{d} + {d} bytes", .{ h_stat.?.size, c_stat.?.size }),
        });
    } else {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Prism vendor"),
            .status = .fail,
            .detail = try alloc.dupe(u8, "missing or empty"),
            .fix = try alloc.dupe(u8, "git submodule update --init"),
        });
    }
}

fn checkOtlpEndpoint(alloc: std.mem.Allocator, checks: *std.ArrayList(Check)) !void {
    const endpoint = std.c.getenv("OTEL_EXPORTER_OTLP_ENDPOINT") orelse {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "OTLP endpoint"),
            .status = .ok,
            .detail = try alloc.dupe(u8, "disabled"),
        });
        return;
    };

    const endpoint_str = std.mem.span(endpoint);
    const scheme_end: usize = if (std.mem.startsWith(u8, endpoint_str, "https://")) 8 else if (std.mem.startsWith(u8, endpoint_str, "http://")) 7 else 0;

    if (scheme_end == 0) {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "OTLP endpoint"),
            .status = .warn,
            .detail = try std.fmt.allocPrint(alloc, "invalid scheme: {s}", .{endpoint_str}),
        });
        return;
    }

    try checks.append(alloc, .{
        .name = try alloc.dupe(u8, "OTLP endpoint"),
        .status = .ok,
        .detail = try std.fmt.allocPrint(alloc, "configured: {s}", .{endpoint_str}),
    });
}

fn checkDbLock(alloc: std.mem.Allocator, db_path: []const u8, checks: *std.ArrayList(Check)) !void {
    const db_pathz = try alloc.dupeZ(u8, db_path);
    defer alloc.free(db_pathz);

    const db = db_mod.Db.open(db_pathz) catch {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Database lock"),
            .status = .warn,
            .detail = try alloc.dupe(u8, "cannot open"),
        });
        return;
    };
    defer db.close();

    const stmt = db.prepare("BEGIN IMMEDIATE") catch |err| {
        if (err == db_mod.DbError.Busy) {
            try checks.append(alloc, .{
                .name = try alloc.dupe(u8, "Database lock"),
                .status = .warn,
                .detail = try alloc.dupe(u8, "database is locked"),
                .fix = try alloc.dupe(u8, "another refract instance is running, or stale lock"),
            });
        } else {
            try checks.append(alloc, .{
                .name = try alloc.dupe(u8, "Database lock"),
                .status = .warn,
                .detail = try alloc.dupe(u8, "lock probe failed"),
            });
        }
        return;
    };

    _ = stmt.step() catch {};
    stmt.finalize();

    if (db.prepare("ROLLBACK")) |rollback| {
        defer rollback.finalize();
        _ = rollback.step() catch {};
    } else |_| {}

    try checks.append(alloc, .{
        .name = try alloc.dupe(u8, "Database lock"),
        .status = .ok,
        .detail = try alloc.dupe(u8, "no exclusive lock held"),
    });
}

fn checkSchemaIntegrity(alloc: std.mem.Allocator, db_path: []const u8, checks: *std.ArrayList(Check)) !void {
    const db_pathz = try alloc.dupeZ(u8, db_path);
    defer alloc.free(db_pathz);

    const db = db_mod.Db.openReadOnly(db_pathz) catch {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Database schema"),
            .status = .warn,
            .detail = try alloc.dupe(u8, "cannot open read-only"),
        });
        return;
    };
    defer db.close();

    var table_count: i64 = 0;
    var index_count: i64 = 0;

    if (db.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='table'")) |stmt| {
        defer stmt.finalize();
        if (try stmt.step()) {
            table_count = stmt.column_int(0);
        }
    } else |_| {}

    if (db.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type='index'")) |stmt| {
        defer stmt.finalize();
        if (try stmt.step()) {
            index_count = stmt.column_int(0);
        }
    } else |_| {}

    if (table_count > 0 and index_count > 0) {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Database schema"),
            .status = .ok,
            .detail = try std.fmt.allocPrint(alloc, "{d} tables, {d} indexes", .{ table_count, index_count }),
        });
    } else {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Database schema"),
            .status = .fail,
            .detail = try std.fmt.allocPrint(alloc, "{d} tables, {d} indexes (incomplete)", .{ table_count, index_count }),
            .fix = try alloc.dupe(u8, "Run `refract --reset-db` to rebuild the database"),
        });
    }
}

fn checkGemCoverage(alloc: std.mem.Allocator, db_path: []const u8, checks: *std.ArrayList(Check)) !void {
    const db_pathz = try alloc.dupeZ(u8, db_path);
    defer alloc.free(db_pathz);

    const db = db_mod.Db.openReadOnly(db_pathz) catch {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Gem coverage"),
            .status = .ok,
            .detail = try alloc.dupe(u8, "database unavailable (skipped)"),
        });
        return;
    };
    defer db.close();

    var avg_coverage: f64 = 0;
    const gem_count: i64 = 0;

    if (db.prepare("SELECT CAST(COUNT(DISTINCT file_id) AS REAL) / NULLIF(SUM(CASE WHEN hits > 0 THEN 1 ELSE 0 END), 0) * 100 FROM coverage_lines")) |stmt| {
        defer stmt.finalize();
        if (try stmt.step()) {
            const val: f64 = @floatFromInt(stmt.column_int(0));
            if (val >= 0) avg_coverage = val;
        }
    } else |_| {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Gem coverage"),
            .status = .ok,
            .detail = try alloc.dupe(u8, "no coverage data"),
        });
        return;
    }

    if (gem_count == 0 and avg_coverage == 0) {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Gem coverage"),
            .status = .ok,
            .detail = try alloc.dupe(u8, "no coverage data"),
        });
        return;
    }

    if (avg_coverage < 80.0) {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Gem coverage"),
            .status = .warn,
            .detail = try std.fmt.allocPrint(alloc, "{d:.1}% average", .{avg_coverage}),
            .fix = try alloc.dupe(u8, "expand test suite"),
        });
    } else {
        try checks.append(alloc, .{
            .name = try alloc.dupe(u8, "Gem coverage"),
            .status = .ok,
            .detail = try std.fmt.allocPrint(alloc, "{d:.1}% average", .{avg_coverage}),
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

test "schema integrity on memory db" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const c = @cImport({
        @cInclude("sqlite3.h");
    });

    var db_handle: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open(":memory:", &db_handle);
    if (rc != c.SQLITE_OK) return;
    defer _ = c.sqlite3_close(db_handle);

    var checks = std.ArrayList(Check).empty;
    defer {
        for (checks.items) |ch| {
            alloc.free(ch.name);
            alloc.free(ch.detail);
            if (ch.fix) |f| alloc.free(f);
        }
        checks.deinit(alloc);
    }

    try checkSchemaIntegrity(alloc, ":memory:", &checks);

    if (checks.items.len > 0) {
        const check = checks.items[checks.items.len - 1];
        try std.testing.expectEqualStrings(check.name, "Database schema");
        try std.testing.expectEqual(check.status, .fail);
    }
}
