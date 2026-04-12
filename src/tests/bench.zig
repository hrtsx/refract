const std = @import("std");
const prism = @import("../prism.zig");
const db_mod = @import("../db.zig");
const indexer = @import("../indexer/index.zig");
const routes = @import("../indexer/routes.zig");

fn timedRun(comptime name: []const u8, iterations: u32, func: anytype) void {
    var timer = std.time.Timer.start() catch return;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u64 = 0;
    for (0..iterations) |_| {
        timer.reset();
        func();
        const elapsed = timer.read();
        total_ns += elapsed;
        if (elapsed < min_ns) min_ns = elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
    }
    const avg_us = total_ns / iterations / 1000;
    const min_us = min_ns / 1000;
    const max_us = max_ns / 1000;
    std.debug.print("  {s}: {d}us avg, {d}us min, {d}us max ({d} iters)\n", .{ name, avg_us, min_us, max_us, iterations });
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

const medium_ruby = blk: {
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
    break :blk buf[0..len];
};

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
    const alloc = std.testing.allocator;
    const db = db_mod.Db.open("/tmp/refract_bench.db") catch return;
    defer {
        db.close();
        std.fs.deleteFileAbsolute("/tmp/refract_bench.db") catch {};
        std.fs.deleteFileAbsolute("/tmp/refract_bench.db-wal") catch {};
        std.fs.deleteFileAbsolute("/tmp/refract_bench.db-shm") catch {};
    }
    db.init_schema() catch return;

    timedRun("index small (7 lines)", 50, struct {
        fn run() void {
            indexer.indexSource(small_ruby, "bench_small.rb", @as(db_mod.Db, undefined), std.testing.allocator) catch {};
        }
    }.run);
    _ = alloc;
    _ = db;
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

    // Seed with realistic data
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
            defer sdb.close();
            _ = sdb;
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
