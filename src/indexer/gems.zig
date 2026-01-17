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

pub fn findGemPaths(root_path: []const u8, alloc: std.mem.Allocator, timeout_ns: u64) ![][]u8 {
    const lock_path = try std.fmt.allocPrint(alloc, "{s}/Gemfile.lock", .{root_path});
    defer alloc.free(lock_path);
    std.fs.cwd().access(lock_path, .{}) catch return &.{};

    var child = std.process.Child.init(
        &.{ "bundle", "exec", "ruby", "--disable=gems", "-e", "puts $LOAD_PATH" },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.cwd = root_path;
    child.spawn() catch return &.{};

    var gtctx = GemTimeoutCtx{ .child = &child, .done = std.atomic.Value(bool).init(false), .timeout_ns = timeout_ns };
    const tkill = std.Thread.spawn(.{}, GemTimeoutCtx.run, .{&gtctx}) catch null;

    var output = std.ArrayList(u8){};
    defer output.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = child.stdout.?.read(&buf) catch break;
        if (n == 0) break;
        output.appendSlice(alloc, buf[0..n]) catch break;
    }
    child.stdout.?.close();
    child.stdout = null;
    const term = child.wait() catch {
        gtctx.done.store(true, .release);
        if (tkill) |t| t.join();
        return error.BundleExecFailed;
    };
    gtctx.done.store(true, .release);
    if (tkill) |t| t.join();
    switch (term) {
        .Exited => |code| if (code != 0) return error.BundleExecFailed,
        else => return error.BundleExecFailed,
    }

    var all_paths = std.ArrayList([]u8){};
    var lines = std.mem.splitScalar(u8, output.items, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (!isProjectGemPath(trimmed)) continue;
        std.fs.cwd().access(trimmed, .{}) catch continue;
        const dir_paths = scanner.scan(trimmed, alloc, &.{}) catch continue;
        for (dir_paths) |p| {
            all_paths.append(alloc, p) catch continue;
        }
        alloc.free(dir_paths);
    }

    return all_paths.toOwnedSlice(alloc);
}
