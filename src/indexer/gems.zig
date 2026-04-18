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
    expired: std.atomic.Value(bool) = .{ .raw = false },
    timeout_ns: u64,
    fn run(ctx: *GemTimeoutCtx) void {
        var e: u64 = 0;
        while (e < ctx.timeout_ns) {
            {
                var _sleep_ts: std.c.timespec = .{ .sec = @intCast((100 * std.time.ns_per_ms) / std.time.ns_per_s), .nsec = @intCast((100 * std.time.ns_per_ms) % std.time.ns_per_s) };
                _ = std.c.nanosleep(&_sleep_ts, null);
            }
            e += 100 * std.time.ns_per_ms;
            if (ctx.done.load(.acquire)) return;
        }
        ctx.expired.store(true, .release);
        ctx.child.kill(std.Options.debug_io);
    }
};

// Runs a ruby subprocess and returns stdout as an owned slice.
fn runRubyCmd(io: std.Io, root_path: []const u8, alloc: std.mem.Allocator, argv: []const []const u8, timeout_ns: u64) ![]u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = root_path },
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "refract: gem subprocess spawn failed: {s}\n", .{@errorName(e)}) catch "refract: gem subprocess spawn failed\n";
        std.debug.print("{s}", .{msg});
        return error.RubyFailed;
    };

    var gtctx = GemTimeoutCtx{ .child = &child, .done = std.atomic.Value(bool).init(false), .timeout_ns = timeout_ns };
    const tkill = std.Thread.spawn(.{}, GemTimeoutCtx.run, .{&gtctx}) catch null;

    var out = std.ArrayList(u8).empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = child.stdout.?.readStreaming(std.Options.debug_io, &.{buf[0..]}) catch break;
        if (n == 0) break;
        out.appendSlice(alloc, buf[0..n]) catch break;
    }
    child.stdout.?.close(std.Options.debug_io);
    child.stdout = null;
    while (true) {
        const n = child.stderr.?.readStreaming(std.Options.debug_io, &.{buf[0..]}) catch break;
        if (n == 0) break;
    }
    child.stderr.?.close(std.Options.debug_io);
    child.stderr = null;
    const term = child.wait(std.Options.debug_io) catch |e| {
        gtctx.done.store(true, .release);
        if (tkill) |t| t.join();
        out.deinit(alloc);
        var ebuf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&ebuf, "refract: gem subprocess wait failed: {s}\n", .{@errorName(e)}) catch "refract: gem subprocess wait failed\n";
        std.debug.print("{s}", .{msg});
        return error.RubyFailed;
    };
    gtctx.done.store(true, .release);
    if (tkill) |t| t.join();
    const did_timeout = gtctx.expired.load(.acquire);
    switch (term) {
        .exited => |code| if (code != 0) {
            var cbuf: [256]u8 = undefined;
            const msg = if (did_timeout)
                std.fmt.bufPrint(&cbuf, "refract: gem subprocess timed out after {d}s\n", .{timeout_ns / std.time.ns_per_s}) catch "refract: gem subprocess timed out\n"
            else
                std.fmt.bufPrint(&cbuf, "refract: gem subprocess exited with code {d}\n", .{code}) catch "refract: gem subprocess failed\n";
            std.debug.print("{s}", .{msg});
            out.deinit(alloc);
            return error.RubyFailed;
        },
        else => {
            if (did_timeout) {
                var cbuf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&cbuf, "refract: gem subprocess timed out after {d}s\n", .{timeout_ns / std.time.ns_per_s}) catch "refract: gem subprocess timed out\n";
                std.debug.print("{s}", .{msg});
            } else {
                std.debug.print("{s}", .{"refract: gem subprocess failed\n"});
            }
            out.deinit(alloc);
            return error.RubyFailed;
        },
    }
    return out.toOwnedSlice(alloc);
}

fn collectPathsFromOutput(raw: []const u8, alloc: std.mem.Allocator, gem_only: bool) ![][]u8 {
    var all_paths = std.ArrayList([]u8).empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (!isProjectGemPath(trimmed)) continue;
        if (gem_only and !isGemInstallPath(trimmed)) continue;
        std.Io.Dir.cwd().access(std.Options.debug_io, trimmed, .{}) catch continue;
        const dir_paths = scanner.scan(trimmed, alloc, &.{}) catch continue;
        for (dir_paths) |p| {
            all_paths.append(alloc, p) catch continue;
        }
        alloc.free(dir_paths);
    }
    return all_paths.toOwnedSlice(alloc);
}

pub fn findRbsStdlibPaths(io: std.Io, root_path: []const u8, alloc: std.mem.Allocator, timeout_ns: u64) ![][]u8 {
    // Try: ruby -e "require 'rbs'; puts RBS::EnvironmentLoader::DEFAULT_CORE_ROOT"
    // Also print the stdlib root (sibling of core/)
    const rbs_argv = &[_][]const u8{ "ruby", "-e", "require 'rbs'; d = RBS::EnvironmentLoader::DEFAULT_CORE_ROOT.to_s; puts d; puts d.sub(/\\/core$/, '/stdlib')" };
    if (runRubyCmd(io, root_path, alloc, rbs_argv, timeout_ns)) |raw| {
        defer alloc.free(raw);
        var rbs_paths = std.ArrayList([]u8).empty;
        var rlines = std.mem.splitScalar(u8, raw, '\n');
        while (rlines.next()) |rline| {
            const trimmed = std.mem.trim(u8, rline, " \t\r");
            if (trimmed.len == 0) continue;
            if (!std.fs.path.isAbsolute(trimmed)) continue;
            std.Io.Dir.cwd().access(std.Options.debug_io, trimmed, .{}) catch continue;
            const dir_paths = scanner.scan(trimmed, alloc, &.{".rbs"}) catch continue;
            for (dir_paths) |p| rbs_paths.append(alloc, p) catch continue;
            alloc.free(dir_paths);
        }
        if (rbs_paths.items.len > 0) return rbs_paths.toOwnedSlice(alloc);
        rbs_paths.deinit(alloc);
    } else |_| {}
    // Fallback: ruby -e "require 'rbconfig'; puts RbConfig::CONFIG['rubylibdir']"
    const rbcfg_argv = &[_][]const u8{ "ruby", "--disable-gems", "-e", "require 'rbconfig'; puts RbConfig::CONFIG['rubylibdir']" };
    if (runRubyCmd(io, root_path, alloc, rbcfg_argv, timeout_ns)) |raw2| {
        defer alloc.free(raw2);
        var rbs_paths2 = std.ArrayList([]u8).empty;
        var flines = std.mem.splitScalar(u8, raw2, '\n');
        while (flines.next()) |fline| {
            const trimmed2 = std.mem.trim(u8, fline, " \t\r");
            if (trimmed2.len == 0) continue;
            if (!std.fs.path.isAbsolute(trimmed2)) continue;
            // Look for an rbs/ subdirectory adjacent to rubylibdir
            const rbs_dir = std.fmt.allocPrint(alloc, "{s}/../rbs", .{trimmed2}) catch continue;
            defer alloc.free(rbs_dir);
            std.Io.Dir.cwd().access(std.Options.debug_io, rbs_dir, .{}) catch continue;
            const dir_paths2 = scanner.scan(rbs_dir, alloc, &.{".rbs"}) catch continue;
            for (dir_paths2) |p| rbs_paths2.append(alloc, p) catch continue;
            alloc.free(dir_paths2);
        }
        if (rbs_paths2.items.len > 0) return rbs_paths2.toOwnedSlice(alloc);
        rbs_paths2.deinit(alloc);
    } else |_| {}
    return &.{};
}

pub fn findRbsCollectionPaths(root_path: []const u8, alloc: std.mem.Allocator) ![][]u8 {
    // Parse rbs_collection.lock.yaml (preferred) or .rbs_collection.yaml for gem RBS paths
    const lock_names = [_][]const u8{ "rbs_collection.lock.yaml", ".rbs_collection.lock.yaml" };
    for (lock_names) |lock_name| {
        const lock_path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ root_path, lock_name }) catch continue;
        defer alloc.free(lock_path);
        const source = std.Io.Dir.cwd().readFileAllocOptions(std.Options.debug_io, lock_path, alloc, std.Io.Limit.limited(2 * 1024 * 1024), .@"1", 0) catch continue;
        defer alloc.free(source);

        // Line-by-line YAML parse: extract `path:` entries under `gems:` section
        var rbs_paths = std.ArrayList([]u8).empty;
        var lines = std.mem.splitScalar(u8, source, '\n');
        var in_gems = false;
        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const content = std.mem.trim(u8, line, " \t");
            if (std.mem.eql(u8, content, "gems:")) {
                in_gems = true;
                continue;
            }
            if (!in_gems) continue;
            // Detect top-level keys (no indent) to exit gems section
            if (line.len > 0 and line[0] != ' ' and line[0] != '-') {
                in_gems = false;
                continue;
            }
            if (std.mem.startsWith(u8, content, "path:")) {
                const path_val = std.mem.trim(u8, content[5..], " \t\"'");
                if (path_val.len == 0) continue;
                // Resolve relative paths against root
                const full_path = if (std.fs.path.isAbsolute(path_val))
                    alloc.dupe(u8, path_val) catch continue
                else
                    std.fmt.allocPrint(alloc, "{s}/{s}", .{ root_path, path_val }) catch continue;
                std.Io.Dir.cwd().access(std.Options.debug_io, full_path, .{}) catch {
                    alloc.free(full_path);
                    continue;
                };
                const dir_paths = scanner.scan(full_path, alloc, &.{".rbs"}) catch {
                    alloc.free(full_path);
                    continue;
                };
                alloc.free(full_path);
                for (dir_paths) |p| rbs_paths.append(alloc, p) catch continue;
                alloc.free(dir_paths);
            }
        }
        if (rbs_paths.items.len > 0) return rbs_paths.toOwnedSlice(alloc);
        rbs_paths.deinit(alloc);
    }
    return &.{};
}

pub fn findGemPaths(io: std.Io, root_path: []const u8, alloc: std.mem.Allocator, timeout_ns: u64) ![][]u8 {
    const lock_path = try std.fmt.allocPrint(alloc, "{s}/Gemfile.lock", .{root_path});
    defer alloc.free(lock_path);
    const has_gemfile_lock = if (std.Io.Dir.cwd().access(std.Options.debug_io, lock_path, .{})) true else |_| false;

    if (has_gemfile_lock) {
        const bundle_argv = &[_][]const u8{ "bundle", "exec", "ruby", "--disable=gems", "-e", "puts $LOAD_PATH" };
        if (runRubyCmd(io, root_path, alloc, bundle_argv, timeout_ns)) |raw| {
            defer alloc.free(raw);
            if (collectPathsFromOutput(raw, alloc, false)) |paths| {
                if (paths.len > 0) return paths;
                alloc.free(paths);
            } else |_| {}
        } else |_| {}
    }

    // Non-bundler fallback: plain ruby $LOAD_PATH filtered to gem install dirs only
    const plain_argv = &[_][]const u8{ "ruby", "--disable-gems", "-e", "puts $LOAD_PATH" };
    const raw = runRubyCmd(io, root_path, alloc, plain_argv, timeout_ns) catch return &.{};
    defer alloc.free(raw);
    return collectPathsFromOutput(raw, alloc, true);
}
