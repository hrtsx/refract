const std = @import("std");
const scanner = @import("scanner.zig");

fn isProjectGemPath(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    const system_prefixes = [_][]const u8{ "/usr/lib", "/usr/local/lib", "/System/", "/Library/" };
    for (system_prefixes) |pfx| {
        if (std.mem.startsWith(u8, path, pfx)) return false;
    }
    return true;
}

fn isGemInstallPath(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/gems/") != null;
}

const GemTimeoutCtx = struct {
    child: *std.process.Child,
    done: std.atomic.Value(bool),
    timeout_ns: u64,
    fn run(ctx: *GemTimeoutCtx) void {
        var e: u64 = 0;
        while (e < ctx.timeout_ns) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            e += 100 * std.time.ns_per_ms;
            if (ctx.done.load(.acquire)) return;
        }
        _ = ctx.child.kill() catch {};
    }
};

// Runs a ruby subprocess and returns stdout as an owned slice.
fn runRubyCmd(root_path: []const u8, alloc: std.mem.Allocator, argv: []const []const u8, timeout_ns: u64) ![]u8 {
    var child = std.process.Child.init(argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = root_path;
    child.spawn() catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "refract: gem subprocess spawn failed: {s}\n", .{@errorName(e)}) catch "refract: gem subprocess spawn failed\n";
        std.fs.File.stderr().writeAll(msg) catch {};
        return error.RubyFailed;
    };

    var gtctx = GemTimeoutCtx{ .child = &child, .done = std.atomic.Value(bool).init(false), .timeout_ns = timeout_ns };
    const tkill = std.Thread.spawn(.{}, GemTimeoutCtx.run, .{&gtctx}) catch null;

    var out = std.ArrayList(u8){};
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = child.stdout.?.read(&buf) catch break;
        if (n == 0) break;
        out.appendSlice(alloc, buf[0..n]) catch break;
    }
    child.stdout.?.close();
    child.stdout = null;
    while (true) {
        const n = child.stderr.?.read(&buf) catch break;
        if (n == 0) break;
    }
    child.stderr.?.close();
    child.stderr = null;
    const term = child.wait() catch |e| {
        gtctx.done.store(true, .release);
        if (tkill) |t| t.join();
        out.deinit(alloc);
        var ebuf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&ebuf, "refract: gem subprocess wait failed: {s}\n", .{@errorName(e)}) catch "refract: gem subprocess wait failed\n";
        std.fs.File.stderr().writeAll(msg) catch {};
        return error.RubyFailed;
    };
    gtctx.done.store(true, .release);
    if (tkill) |t| t.join();
    switch (term) {
        .Exited => |code| if (code != 0) {
            var cbuf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&cbuf, "refract: gem subprocess exited with code {d}\n", .{code}) catch "refract: gem subprocess failed\n";
            std.fs.File.stderr().writeAll(msg) catch {};
            out.deinit(alloc);
            return error.RubyFailed;
        },
        else => {
            std.fs.File.stderr().writeAll("refract: gem subprocess failed\n") catch {};
            out.deinit(alloc);
            return error.RubyFailed;
        },
    }
    return out.toOwnedSlice(alloc);
}

fn collectPathsFromOutput(raw: []const u8, alloc: std.mem.Allocator, gem_only: bool) ![][]u8 {
    var all_paths = std.ArrayList([]u8){};
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (!isProjectGemPath(trimmed)) continue;
        if (gem_only and !isGemInstallPath(trimmed)) continue;
        std.fs.cwd().access(trimmed, .{}) catch continue;
        const dir_paths = scanner.scan(trimmed, alloc, &.{}) catch continue;
        for (dir_paths) |p| {
            all_paths.append(alloc, p) catch continue;
        }
        alloc.free(dir_paths);
    }
    return all_paths.toOwnedSlice(alloc);
}

pub fn findRbsStdlibPaths(root_path: []const u8, alloc: std.mem.Allocator, timeout_ns: u64) ![][]u8 {
    // Try: ruby -e "require 'rbs'; puts RBS::EnvironmentLoader::DEFAULT_CORE_ROOT"
    const rbs_argv = &[_][]const u8{ "ruby", "--disable-gems", "-e",
        "begin; require 'rbs'; puts RBS::EnvironmentLoader::DEFAULT_CORE_ROOT; rescue => e; end" };
    if (runRubyCmd(root_path, alloc, rbs_argv, timeout_ns)) |raw| {
        defer alloc.free(raw);
        var rbs_paths = std.ArrayList([]u8){};
        var rlines = std.mem.splitScalar(u8, raw, '\n');
        while (rlines.next()) |rline| {
            const trimmed = std.mem.trim(u8, rline, " \t\r");
            if (trimmed.len == 0) continue;
            if (!isProjectGemPath(trimmed)) continue;
            std.fs.cwd().access(trimmed, .{}) catch continue;
            const dir_paths = scanner.scan(trimmed, alloc, &.{".rbs"}) catch continue;
            for (dir_paths) |p| rbs_paths.append(alloc, p) catch continue;
            alloc.free(dir_paths);
        }
        if (rbs_paths.items.len > 0) return rbs_paths.toOwnedSlice(alloc);
        rbs_paths.deinit(alloc);
    } else |_| {}
    // Fallback: ruby -e "require 'rbconfig'; puts RbConfig::CONFIG['rubylibdir']"
    const rbcfg_argv = &[_][]const u8{ "ruby", "--disable-gems", "-e",
        "require 'rbconfig'; puts RbConfig::CONFIG['rubylibdir']" };
    if (runRubyCmd(root_path, alloc, rbcfg_argv, timeout_ns)) |raw2| {
        defer alloc.free(raw2);
        var rbs_paths2 = std.ArrayList([]u8){};
        var flines = std.mem.splitScalar(u8, raw2, '\n');
        while (flines.next()) |fline| {
            const trimmed2 = std.mem.trim(u8, fline, " \t\r");
            if (trimmed2.len == 0) continue;
            if (!isProjectGemPath(trimmed2)) continue;
            // Look for an rbs/ subdirectory adjacent to rubylibdir
            const rbs_dir = std.fmt.allocPrint(alloc, "{s}/../rbs", .{trimmed2}) catch continue;
            defer alloc.free(rbs_dir);
            std.fs.cwd().access(rbs_dir, .{}) catch continue;
            const dir_paths2 = scanner.scan(rbs_dir, alloc, &.{".rbs"}) catch continue;
            for (dir_paths2) |p| rbs_paths2.append(alloc, p) catch continue;
            alloc.free(dir_paths2);
        }
        if (rbs_paths2.items.len > 0) return rbs_paths2.toOwnedSlice(alloc);
        rbs_paths2.deinit(alloc);
    } else |_| {}
    return &.{};
}

pub fn findGemPaths(root_path: []const u8, alloc: std.mem.Allocator, timeout_ns: u64) ![][]u8 {
    const lock_path = try std.fmt.allocPrint(alloc, "{s}/Gemfile.lock", .{root_path});
    defer alloc.free(lock_path);
    const has_gemfile_lock = if (std.fs.cwd().access(lock_path, .{})) true else |_| false;

    if (has_gemfile_lock) {
        const bundle_argv = &[_][]const u8{ "bundle", "exec", "ruby", "--disable=gems", "-e", "puts $LOAD_PATH" };
        if (runRubyCmd(root_path, alloc, bundle_argv, timeout_ns)) |raw| {
            defer alloc.free(raw);
            if (collectPathsFromOutput(raw, alloc, false)) |paths| {
                if (paths.len > 0) return paths;
                alloc.free(paths);
            } else |_| {}
        } else |_| {}
    }

    // Non-bundler fallback: plain ruby $LOAD_PATH filtered to gem install dirs only
    const plain_argv = &[_][]const u8{ "ruby", "--disable-gems", "-e", "puts $LOAD_PATH" };
    const raw = runRubyCmd(root_path, alloc, plain_argv, timeout_ns) catch return &.{};
    defer alloc.free(raw);
    return collectPathsFromOutput(raw, alloc, true);
}
