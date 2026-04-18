const std = @import("std");
const build_opts = @import("build_opts");

pub const refract_bin = build_opts.refract_bin;

var session_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

const template_path = "/tmp/refract_test_stdlib_template.db";

fn templateAvailable() bool {
    const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, template_path, .{}) catch return false;
    // Sanity: a real warmed DB is multi-MB. Anything tiny is a stale leftover
    // or a failed warmup.
    return stat.size > 100 * 1024;
}

fn cleanupDbFiles(db_path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, db_path) catch {};
    var buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{s}-wal", .{db_path})) |wal| {
        std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, wal) catch {};
    } else |_| {}
    if (std.fmt.bufPrint(&buf, "{s}-shm", .{db_path})) |shm| {
        std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, shm) catch {};
    } else |_| {}
    if (std.fmt.bufPrint(&buf, "{s}.lock", .{db_path})) |lck| {
        std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, lck) catch {};
    } else |_| {}
}

pub fn frame(alloc: std.mem.Allocator, json: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n{s}", .{ json.len, json });
}

pub const Session = struct {
    alloc: std.mem.Allocator,
    input: std.ArrayList(u8),
    db_path: []u8,

    pub fn init(alloc: std.mem.Allocator) !Session {
        const ts = std.Io.Timestamp.now(std.Options.debug_io, .real).toMicroseconds();
        const n = session_counter.fetchAdd(1, .monotonic);
        var _rnd_bytes: [8]u8 = undefined;
        std.Options.debug_io.random(&_rnd_bytes);
        const rand_id = std.mem.readInt(u64, &_rnd_bytes, .little);
        const db_path = try std.fmt.allocPrint(alloc, "/tmp/refract_test_t{d}_n{d}_{x}.db", .{ ts, n, rand_id });
        cleanupDbFiles(db_path);
        if (templateAvailable()) {
            std.Io.Dir.copyFileAbsolute(template_path, db_path, std.Options.debug_io, .{}) catch {};
        }
        return .{ .alloc = alloc, .input = std.ArrayList(u8).empty, .db_path = db_path };
    }

    pub fn deinit(self: *Session) void {
        self.input.deinit(self.alloc);
        cleanupDbFiles(self.db_path);
        self.alloc.free(self.db_path);
    }

    pub fn send(self: *Session, json: []const u8) !void {
        const f = try frame(self.alloc, json);
        defer self.alloc.free(f);
        try self.input.appendSlice(self.alloc, f);
    }

    pub fn sendLine(self: *Session, json: []const u8) !void {
        try self.input.appendSlice(self.alloc, json);
        try self.input.append(self.alloc, '\n');
    }

    pub fn run(self: *Session) ![]u8 {
        return self.runWithArgs(&.{});
    }

    pub fn runWithArgs(self: *Session, extra_args: []const []const u8) ![]u8 {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.alloc);
        try argv.append(self.alloc, refract_bin);
        try argv.append(self.alloc, "--db-path");
        try argv.append(self.alloc, self.db_path);
        for (extra_args) |a| try argv.append(self.alloc, a);
        var child = try std.process.spawn(std.testing.io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });

        var timeout_done = std.atomic.Value(bool).init(false);
        const child_pid = child.id.?;
        var thr = std.Thread.spawn(.{}, struct {
            fn run(pid: std.process.Child.Id, done: *std.atomic.Value(bool)) void {
                var elapsed: u32 = 0;
                while (elapsed < 15_000) : (elapsed += 100) {
                    if (done.load(.acquire)) return;
                    {
                        var _sleep_ts: std.c.timespec = .{ .sec = @intCast((100 * std.time.ns_per_ms) / std.time.ns_per_s), .nsec = @intCast((100 * std.time.ns_per_ms) % std.time.ns_per_s) };
                        _ = std.c.nanosleep(&_sleep_ts, null);
                    }
                }
                if (!done.load(.acquire)) {
                    std.posix.kill(pid, std.posix.SIG.KILL) catch {};
                }
            }
        }.run, .{ child_pid, &timeout_done }) catch null;
        defer {
            timeout_done.store(true, .release);
            if (thr) |t| t.join();
        }

        try child.stdin.?.writeStreamingAll(std.Options.debug_io, self.input.items);
        child.stdin.?.close(std.Options.debug_io);
        child.stdin = null;

        var output = std.ArrayList(u8).empty;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = child.stdout.?.readStreaming(std.Options.debug_io, &.{buf[0..]}) catch break;
            if (n == 0) break;
            try output.appendSlice(self.alloc, buf[0..n]);
        }

        var stderr_content: []u8 = &.{};
        if (child.stderr) |stderr_pipe| {
            var sbuf: [4096]u8 = undefined;
            var sbytes = std.ArrayList(u8).empty;
            while (true) {
                const sn = stderr_pipe.readStreaming(std.Options.debug_io, &.{sbuf[0..]}) catch break;
                if (sn == 0) break;
                sbytes.appendSlice(self.alloc, sbuf[0..sn]) catch break;
            }
            stderr_content = sbytes.toOwnedSlice(self.alloc) catch &.{};
        }
        defer if (stderr_content.len > 0) self.alloc.free(stderr_content);

        timeout_done.store(true, .release);
        if (thr) |t| {
            t.join();
            thr = null;
        }
        _ = child.wait(std.Options.debug_io) catch {};
        if (stderr_content.len > 0) {
            std.debug.print("refract stderr:\n{s}\n", .{stderr_content});
        }
        return output.toOwnedSlice(self.alloc);
    }
};

pub fn extractResponses(alloc: std.mem.Allocator, raw: []const u8) ![]std.json.Parsed(std.json.Value) {
    var results = std.ArrayList(std.json.Parsed(std.json.Value)).empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (!std.mem.startsWith(u8, raw[i..], "Content-Length: ")) break;
        const header_end = std.mem.indexOf(u8, raw[i..], "\r\n\r\n") orelse break;
        const length_str = raw[i + "Content-Length: ".len .. i + header_end];
        const length = std.fmt.parseInt(usize, length_str, 10) catch break;
        const body_start = i + header_end + 4;
        if (body_start + length > raw.len) break;
        const body = raw[body_start .. body_start + length];
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        try results.append(alloc, parsed);
        i = body_start + length;
    }
    return results.toOwnedSlice(alloc);
}

pub fn getNotificationByMethod(responses: []std.json.Parsed(std.json.Value), method: []const u8) ?std.json.Value {
    for (responses) |r| {
        const obj = switch (r.value) {
            .object => |o| o,
            else => continue,
        };
        const m = obj.get("method") orelse continue;
        const ms = switch (m) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, ms, method)) return r.value;
    }
    return null;
}

pub fn getResponseById(responses: []std.json.Parsed(std.json.Value), id: i64) ?std.json.Value {
    for (responses) |r| {
        const obj = switch (r.value) {
            .object => |o| o,
            else => continue,
        };
        const id_val = obj.get("id") orelse continue;
        const rid = switch (id_val) {
            .integer => |i| i,
            else => continue,
        };
        if (rid == id) return r.value;
    }
    return null;
}

pub const base_init =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":"file:///tmp/refract_test","capabilities":{}}}
;
pub const base_initialized =
    \\{"jsonrpc":"2.0","method":"initialized","params":{}}
;
pub const base_shutdown =
    \\{"jsonrpc":"2.0","id":99,"method":"shutdown","params":null}
;
pub const base_exit =
    \\{"jsonrpc":"2.0","method":"exit","params":null}
;
