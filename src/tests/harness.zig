const std = @import("std");
const build_opts = @import("build_opts");

pub const refract_bin = build_opts.refract_bin;

pub fn frame(alloc: std.mem.Allocator, json: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n{s}", .{ json.len, json });
}

pub const Session = struct {
    alloc: std.mem.Allocator,
    input: std.ArrayList(u8),
    db_path: []u8,

    pub fn init(alloc: std.mem.Allocator) !Session {
        const rand_id = std.crypto.random.int(u64);
        const db_path = try std.fmt.allocPrint(alloc, "/tmp/refract_test_{x}.db", .{rand_id});
        return .{ .alloc = alloc, .input = std.ArrayList(u8){}, .db_path = db_path };
    }

    pub fn deinit(self: *Session) void {
        self.input.deinit(self.alloc);
        std.fs.deleteFileAbsolute(self.db_path) catch {};
        var wal_buf: [256]u8 = undefined;
        if (std.fmt.bufPrint(&wal_buf, "{s}-wal", .{self.db_path})) |wal| {
            std.fs.deleteFileAbsolute(wal) catch {};
        } else |_| {}
        if (std.fmt.bufPrint(&wal_buf, "{s}-shm", .{self.db_path})) |shm| {
            std.fs.deleteFileAbsolute(shm) catch {};
        } else |_| {}
        if (std.fmt.bufPrint(&wal_buf, "{s}.lock", .{self.db_path})) |lck| {
            std.fs.deleteFileAbsolute(lck) catch {};
        } else |_| {}
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
        var argv = std.ArrayList([]const u8){};
        defer argv.deinit(self.alloc);
        try argv.append(self.alloc, refract_bin);
        try argv.append(self.alloc, "--db-path");
        try argv.append(self.alloc, self.db_path);
        for (extra_args) |a| try argv.append(self.alloc, a);
        var child = std.process.Child.init(argv.items, self.alloc);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();

        var timeout_done = std.atomic.Value(bool).init(false);
        const child_pid = child.id;
        var thr = std.Thread.spawn(.{}, struct {
            fn run(pid: std.process.Child.Id, done: *std.atomic.Value(bool)) void {
                var elapsed: u32 = 0;
                while (elapsed < 15_000) : (elapsed += 100) {
                    if (done.load(.acquire)) return;
                    std.Thread.sleep(100 * std.time.ns_per_ms);
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

        try child.stdin.?.writeAll(self.input.items);
        child.stdin.?.close();
        child.stdin = null;

        var output = std.ArrayList(u8){};
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = child.stdout.?.read(&buf) catch break;
            if (n == 0) break;
            try output.appendSlice(self.alloc, buf[0..n]);
        }

        var stderr_content: []u8 = &.{};
        if (child.stderr) |stderr_pipe| {
            stderr_content = stderr_pipe.readToEndAlloc(self.alloc, 1024 * 1024) catch &.{};
        }
        defer if (stderr_content.len > 0) self.alloc.free(stderr_content);

        timeout_done.store(true, .release);
        if (thr) |t| {
            t.join();
            thr = null;
        }
        if (comptime @import("builtin").os.tag == .linux) {
            var wstatus: u32 = 0;
            _ = std.os.linux.waitpid(child.id, &wstatus, 0);
        }
        if (stderr_content.len > 0) {
            std.debug.print("refract stderr:\n{s}\n", .{stderr_content});
        }
        return output.toOwnedSlice(self.alloc);
    }
};

pub fn extractResponses(alloc: std.mem.Allocator, raw: []const u8) ![]std.json.Parsed(std.json.Value) {
    var results = std.ArrayList(std.json.Parsed(std.json.Value)){};
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
