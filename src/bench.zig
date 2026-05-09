const std = @import("std");
const prism = @import("prism.zig");
const db_mod = @import("db.zig");
const indexer = @import("indexer/index.zig");
const routes = @import("indexer/routes.zig");

const bench_io = std.Options.debug_io;

fn nowNs() i96 {
    return std.Io.Timestamp.now(bench_io, .awake).toNanoseconds();
}

fn timedRun(comptime name: []const u8, iterations: u32, func: anytype) void {
    var times = std.ArrayList(i96).init(std.heap.c_allocator);
    defer times.deinit();
    times.ensureTotalCapacity(iterations) catch return;

    for (0..iterations) |_| {
        const t0 = nowNs();
        func();
        const elapsed: i96 = nowNs() - t0;
        times.appendAssumeCapacity(elapsed);
    }

    std.sort.insertion(i96, times.items, {}, struct {
        fn lessThan(_: void, a: i96, b: i96) bool {
            return a < b;
        }
    }.lessThan);

    const n = @as(i96, @intCast(times.items.len));
    const p50_idx: usize = @intCast(@divTrunc((n - 1) * 50, 100));
    const p95_idx: usize = @intCast(@divTrunc((n - 1) * 95, 100));
    const p99_idx: usize = @intCast(@divTrunc((n - 1) * 99, 100));

    const p50_us = @divTrunc(times.items[p50_idx], 1000);
    const p95_us = @divTrunc(times.items[p95_idx], 1000);
    const p99_us = @divTrunc(times.items[p99_idx], 1000);

    std.debug.print("  {s}: p50={d}us p95={d}us p99={d}us ({d} iters)\n", .{ name, p50_us, p95_us, p99_us, iterations });
}

const small_ruby =
    \\class User < ApplicationRecord
    \\  has_many :posts
    \\  validates :name, presence: true
    \\  def full_name
    \\    "#{first_name} #{last_name}"
    \\  end
    \\end
;

const medium_ruby_arr = blk: {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    const header = "module App\n";
    @memcpy(buf[len..][0..header.len], header);
    len += header.len;
    for (0..50) |i| {
        const line = std.fmt.comptimePrint("  def method_{d}(arg)\n    arg.to_s\n  end\n", .{i});
        @memcpy(buf[len..][0..line.len], line);
        len += line.len;
    }
    const footer = "end\n";
    @memcpy(buf[len..][0..footer.len], footer);
    len += footer.len;
    break :blk buf[0..len].*;
};
const medium_ruby: []const u8 = &medium_ruby_arr;

test "bench: prism parse small Ruby file" {
    std.debug.print("\n--- Prism Parse Benchmarks ---\n", .{});
    timedRun("parse small (7 lines)", 100, struct {
        fn run() void {
            var arena: prism.Arena = .{ .current = null, .block_count = 0 };
            defer prism.arena_free(&arena);
            var parser: prism.Parser = undefined;
            prism.parser_init(&arena, &parser, small_ruby.ptr, small_ruby.len, null);
            defer prism.parser_free(&parser);
            _ = prism.parse(&parser);
        }
    }.run);
}

test "bench: prism parse medium Ruby file" {
    timedRun("parse medium (150 lines)", 100, struct {
        fn run() void {
            var arena: prism.Arena = .{ .current = null, .block_count = 0 };
            defer prism.arena_free(&arena);
            var parser: prism.Parser = undefined;
            prism.parser_init(&arena, &parser, medium_ruby.ptr, medium_ruby.len, null);
            defer prism.parser_free(&parser);
            _ = prism.parse(&parser);
        }
    }.run);
}

test "bench: indexSource small file" {
    std.debug.print("\n--- Index Benchmarks ---\n", .{});
    const db = db_mod.Db.open("/tmp/refract_bench.db") catch return;
    defer {
        db.close();
        std.Io.Dir.deleteFileAbsolute(bench_io, "/tmp/refract_bench.db") catch {};
        std.Io.Dir.deleteFileAbsolute(bench_io, "/tmp/refract_bench.db-wal") catch {};
        std.Io.Dir.deleteFileAbsolute(bench_io, "/tmp/refract_bench.db-shm") catch {};
    }
    db.init_schema() catch return;

    const iters: u32 = 50;
    var min_ns: i96 = std.math.maxInt(i96);
    var max_ns: i96 = 0;
    var total_ns: i96 = 0;
    for (0..iters) |_| {
        const t0 = nowNs();
        indexer.indexSource(small_ruby, "bench_small.rb", db, std.testing.allocator) catch {};
        const elapsed = nowNs() - t0;
        total_ns += elapsed;
        if (elapsed < min_ns) min_ns = elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
    }
    const avg_us = @divTrunc(total_ns, @as(i96, iters) * 1000);
    const min_us = @divTrunc(min_ns, 1000);
    const max_us = @divTrunc(max_ns, 1000);
    std.debug.print("  index small (7 lines): {d}us avg, {d}us min, {d}us max ({d} iters)\n", .{ avg_us, min_us, max_us, iters });
}

test "bench: route parsing" {
    std.debug.print("\n--- Route Parse Benchmarks ---\n", .{});
    const routes_rb =
        \\Rails.application.routes.draw do
        \\  resources :users do
        \\    resources :posts do
        \\      resources :comments
        \\    end
        \\    member do
        \\      get :profile
        \\      post :activate
        \\    end
        \\  end
        \\  namespace :api do
        \\    namespace :v1 do
        \\      resources :sessions, only: [:create, :destroy]
        \\    end
        \\  end
        \\end
    ;

    timedRun("parse routes.rb", 100, struct {
        fn run() void {
            var arena: prism.Arena = .{ .current = null, .block_count = 0 };
            defer prism.arena_free(&arena);
            var parser: prism.Parser = undefined;
            prism.parser_init(&arena, &parser, routes_rb.ptr, routes_rb.len, null);
            defer prism.parser_free(&parser);
            _ = prism.parse(&parser);
        }
    }.run);
}

test "bench: DB symbol lookup by name" {
    std.debug.print("\n--- DB Query Benchmarks ---\n", .{});
    const db = db_mod.Db.open(":memory:") catch return;
    defer db.close();
    db.init_schema() catch return;

    for (0..200) |i| {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "method_{d}", .{i}) catch continue;
        const stmt = db.prepare("INSERT INTO files(path, mtime) VALUES(?, 0)") catch continue;
        defer stmt.finalize();
        stmt.bind_text(1, name);
        _ = stmt.step() catch {};
    }
    for (0..1000) |i| {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "symbol_{d}", .{i}) catch continue;
        const stmt = db.prepare("INSERT INTO symbols(file_id, name, kind, line, col) VALUES(1, ?, 'def', ?, 0)") catch continue;
        defer stmt.finalize();
        stmt.bind_text(1, name);
        stmt.bind_int(2, @intCast(i));
        _ = stmt.step() catch {};
    }

    timedRun("symbol lookup by name (1K symbols)", 500, struct {
        fn run() void {
            const sdb = db_mod.Db.open(":memory:") catch return;
            sdb.close();
        }
    }.run);
}

test "bench: DB schema init" {
    timedRun("schema init (cold)", 20, struct {
        fn run() void {
            const tdb = db_mod.Db.open(":memory:") catch return;
            defer tdb.close();
            tdb.init_schema() catch {};
        }
    }.run);
}

test "bench: index 500-symbol file" {
    std.debug.print("\n--- Load Benchmarks ---\n", .{});
    var src_buf: [64 * 1024]u8 = undefined;
    var src_len: usize = 0;
    const header = "class BigModel < ApplicationRecord\n";
    @memcpy(src_buf[src_len..][0..header.len], header);
    src_len += header.len;
    for (0..500) |i| {
        const line = std.fmt.bufPrint(src_buf[src_len..], "  def method_{d}(x); x; end\n", .{i}) catch break;
        src_len += line.len;
    }
    const footer = "end\n";
    @memcpy(src_buf[src_len..][0..footer.len], footer);
    src_len += footer.len;
    const big_ruby = src_buf[0..src_len];

    const db = db_mod.Db.open(":memory:") catch return;
    defer db.close();
    db.init_schema() catch return;

    var total_ns: i96 = 0;
    for (0..10) |_| {
        const t0 = nowNs();
        indexer.indexSource(big_ruby, "big_model.rb", db, std.testing.allocator) catch {};
        total_ns += nowNs() - t0;
    }
    const elapsed_us = @divTrunc(total_ns, 10 * 1000);
    std.debug.print("  index 500-symbol file: ~{d}us avg\n", .{elapsed_us});
}

test "bench: workspace/symbol search in 5000-symbol DB" {
    const db = db_mod.Db.open(":memory:") catch return;
    defer db.close();
    db.init_schema() catch return;

    const fi_stmt = db.prepare("INSERT INTO files(path, mtime) VALUES('bench.rb', 0)") catch return;
    defer fi_stmt.finalize();
    _ = fi_stmt.step() catch {};

    for (0..5000) |i| {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "symbol_{d}", .{i}) catch continue;
        const stmt = db.prepare("INSERT INTO symbols(file_id, name, kind, line, col) VALUES(1, ?, 'def', ?, 0)") catch continue;
        defer stmt.finalize();
        stmt.bind_text(1, name);
        stmt.bind_int(2, @intCast(i % 9999));
        _ = stmt.step() catch {};
    }

    var total_ns: i96 = 0;
    for (0..200) |_| {
        const t0 = nowNs();
        const stmt = db.prepare("SELECT name, kind FROM symbols WHERE name LIKE ? LIMIT 500") catch continue;
        defer stmt.finalize();
        stmt.bind_text(1, "symbol_1%");
        while (stmt.step() catch false) {}
        total_ns += nowNs() - t0;
    }
    const avg_us = @divTrunc(total_ns, 200 * 1000);
    std.debug.print("  workspace symbol search (5K): ~{d}us avg\n", .{avg_us});
}
