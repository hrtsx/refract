const std = @import("std");
const builtin = @import("builtin");
const build_meta = @import("build_meta");

const RING_SIZE: u32 = 100;
const METHOD_MAX: usize = 48;
const MAX_CRASH_FILES: usize = 5;

const LoggedMsg = struct {
    method_buf: [METHOD_MAX]u8 = .{0} ** METHOD_MAX,
    method_len: u8 = 0,
    has_id: bool = false,
    id_int: i64 = 0,
    timestamp_ms: i64 = 0,
};

var g_ring: [RING_SIZE]LoggedMsg = .{LoggedMsg{}} ** RING_SIZE;
var g_ring_head: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

pub fn recordMessage(method: []const u8, id: ?std.json.Value) void {
    const idx = g_ring_head.fetchAdd(1, .acq_rel) % RING_SIZE;
    var slot: LoggedMsg = .{};
    const copy_len = @min(method.len, METHOD_MAX);
    @memcpy(slot.method_buf[0..copy_len], method[0..copy_len]);
    slot.method_len = @intCast(copy_len);
    if (id) |idv| switch (idv) {
        .integer => |i| {
            slot.has_id = true;
            slot.id_int = i;
        },
        else => {},
    };
    slot.timestamp_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds();
    g_ring[idx] = slot;
}

const FdWriter = struct {
    fd: std.c.fd_t,
    buf: [2048]u8 = undefined,
    len: usize = 0,

    fn flush(self: *FdWriter) void {
        if (self.len == 0) return;
        var off: usize = 0;
        while (off < self.len) {
            const n = std.c.write(self.fd, self.buf[off..self.len].ptr, self.len - off);
            if (n <= 0) break;
            off += @intCast(n);
        }
        self.len = 0;
    }

    fn writeAll(self: *FdWriter, s: []const u8) void {
        var rem = s;
        while (rem.len > 0) {
            const space = self.buf.len - self.len;
            if (space == 0) {
                self.flush();
                continue;
            }
            const take = @min(space, rem.len);
            @memcpy(self.buf[self.len..][0..take], rem[0..take]);
            self.len += take;
            rem = rem[take..];
        }
    }

    fn print(self: *FdWriter, comptime fmt: []const u8, args: anytype) void {
        var tmp: [512]u8 = undefined;
        const formatted = std.fmt.bufPrint(&tmp, fmt, args) catch return;
        self.writeAll(formatted);
    }
};

fn dumpRingTo(w: *FdWriter) void {
    const head = g_ring_head.load(.acquire);
    if (head == 0) {
        w.writeAll("(no messages recorded)\n");
        return;
    }
    const start: u32 = if (head > RING_SIZE) head - RING_SIZE else 0;
    var i: u32 = start;
    while (i < head) : (i += 1) {
        const slot = g_ring[i % RING_SIZE];
        if (slot.method_len == 0) continue;
        w.print("[{d}] {s}", .{ slot.timestamp_ms, slot.method_buf[0..slot.method_len] });
        if (slot.has_id) w.print(" id={d}", .{slot.id_int});
        w.writeAll("\n");
    }
}

fn getEnvSpan(name: [*:0]const u8) ?[]const u8 {
    const p = std.c.getenv(name) orelse return null;
    return std.mem.span(p);
}

fn computeStateDir(buf: []u8) ?[]const u8 {
    if (getEnvSpan("XDG_STATE_HOME")) |x| {
        if (x.len > 0) return std.fmt.bufPrint(buf, "{s}/refract", .{x}) catch null;
    }
    const home = getEnvSpan("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/refract", .{home}) catch null;
}

fn ensureDirPosix(path: []const u8) void {
    var pathz_buf: [512]u8 = undefined;
    if (path.len >= pathz_buf.len) return;
    @memcpy(pathz_buf[0..path.len], path);
    pathz_buf[path.len] = 0;
    const pathz: [*:0]const u8 = @ptrCast(&pathz_buf);
    if (std.c.mkdir(pathz, 0o755) == 0) return;
    if (std.c.errno(-1) == .EXIST) return;
    // try to create parent then retry
    if (std.fs.path.dirname(path)) |parent| {
        var pbuf: [512]u8 = undefined;
        if (parent.len >= pbuf.len) return;
        @memcpy(pbuf[0..parent.len], parent);
        pbuf[parent.len] = 0;
        _ = std.c.mkdir(@ptrCast(&pbuf), 0o755);
        _ = std.c.mkdir(pathz, 0o755);
    }
}

fn writeCrashFilePosix(panic_msg: []const u8, first_trace_addr: ?usize) void {
    var dir_buf: [512]u8 = undefined;
    const dir_path = computeStateDir(&dir_buf) orelse return;
    ensureDirPosix(dir_path);

    var path_buf: [640]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/crash-{d}.log", .{ dir_path, std.c.getpid() }) catch return;
    if (file_path.len >= path_buf.len - 1) return;
    var pathz_buf: [640]u8 = undefined;
    @memcpy(pathz_buf[0..file_path.len], file_path);
    pathz_buf[file_path.len] = 0;
    const pathz: [*:0]const u8 = @ptrCast(&pathz_buf);

    const fd = std.c.open(pathz, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);

    var w: FdWriter = .{ .fd = fd };
    w.writeAll("refract crash report\n");
    w.writeAll("====================\n");
    w.print("version:     {s}\n", .{build_meta.version});
    w.print("git:         {s}\n", .{build_meta.git_sha});
    w.print("zig:         {s}\n", .{build_meta.zig_version});
    w.print("os:          {s}\n", .{@tagName(builtin.os.tag)});
    w.print("arch:        {s}\n", .{@tagName(builtin.cpu.arch)});
    w.print("pid:         {d}\n", .{std.c.getpid()});
    w.print("timestamp:   {d}\n", .{std.Io.Timestamp.now(std.Options.debug_io, .real).toSeconds()});
    w.writeAll("\npanic message\n-------------\n");
    w.writeAll(panic_msg);
    w.writeAll("\n\nstack trace\n-----------\n");
    if (first_trace_addr) |addr| {
        w.print("first trace addr: 0x{x}\n", .{addr});
    } else {
        w.writeAll("(no trace addr)\n");
    }
    w.writeAll("\nrecent LSP messages\n-------------------\n");
    dumpRingTo(&w);
    w.flush();
}

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    writeCrashFilePosix(msg, first_trace_addr);
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub const Panic = std.debug.FullPanic(panicHandler);

pub fn stateDir(alloc: std.mem.Allocator) ?[]u8 {
    if (getEnvSpan("XDG_STATE_HOME")) |x| {
        if (x.len > 0) return std.fmt.allocPrint(alloc, "{s}/refract", .{x}) catch null;
    }
    const home = getEnvSpan("HOME") orelse return null;
    return std.fmt.allocPrint(alloc, "{s}/.local/state/refract", .{home}) catch null;
}

pub fn dumpLastCrash(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    const dir_path = stateDir(alloc) orelse return error.NoStateDir;
    defer alloc.free(dir_path);

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return error.NoCrashLog;
    defer dir.close(io);

    var newest_name: [128]u8 = undefined;
    var newest_len: usize = 0;
    var newest_mtime: i96 = std.math.minInt(i96);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "crash-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".log")) continue;
        if (entry.name.len > 128) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        const mt_ns = stat.mtime.toNanoseconds();
        if (mt_ns > newest_mtime) {
            newest_mtime = mt_ns;
            @memcpy(newest_name[0..entry.name.len], entry.name);
            newest_len = entry.name.len;
        }
    }
    if (newest_len == 0) return error.NoCrashLog;

    var f = try dir.openFile(io, newest_name[0..newest_len], .{});
    defer f.close(io);
    var rbuf: [4096]u8 = undefined;
    var fr = f.readerStreaming(io, &rbuf);
    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = fr.interface.readSliceShort(&read_buf) catch break;
        if (n == 0) break;
        try w.writeAll(read_buf[0..n]);
    }
}

pub fn lastCrashMtime(io: std.Io, alloc: std.mem.Allocator) ?i96 {
    const dir_path = stateDir(alloc) orelse return null;
    defer alloc.free(dir_path);
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var newest: i96 = std.math.minInt(i96);
    var found = false;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "crash-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".log")) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        const mt_ns = stat.mtime.toNanoseconds();
        if (mt_ns > newest) {
            newest = mt_ns;
            found = true;
        }
    }
    return if (found) newest else null;
}

pub fn rotateOldCrashLogs(io: std.Io, alloc: std.mem.Allocator) void {
    const dir_path = stateDir(alloc) orelse return;
    defer alloc.free(dir_path);
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    const Entry = struct { name_buf: [128]u8, name_len: usize, mtime: i96 };
    var entries: [32]Entry = undefined;
    var n: usize = 0;

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "crash-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".log")) continue;
        if (entry.name.len > 128) continue;
        if (n >= entries.len) break;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        var e: Entry = .{ .name_buf = undefined, .name_len = entry.name.len, .mtime = stat.mtime.toNanoseconds() };
        @memcpy(e.name_buf[0..entry.name.len], entry.name);
        entries[n] = e;
        n += 1;
    }
    if (n <= MAX_CRASH_FILES) return;

    std.mem.sort(Entry, entries[0..n], {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.mtime > b.mtime;
        }
    }.lessThan);

    var i: usize = MAX_CRASH_FILES;
    while (i < n) : (i += 1) {
        dir.deleteFile(io, entries[i].name_buf[0..entries[i].name_len]) catch {};
    }
}
