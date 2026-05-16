const std = @import("std");
const builtin = @import("builtin");

pub const Config = struct {
    allow_network: bool = false,
    allow_fs_write: []const []const u8 = &.{},
};

pub const Error = error{
    PrctlFailed,
    SeccompFailed,
    LandlockUnavailable,
    LandlockFailed,
    SandboxInitFailed,
    SetrlimitFailed,
    UnsupportedPlatform,
};

extern "c" fn prctl(option: c_int, arg2: c_ulong, arg3: c_ulong, arg4: c_ulong, arg5: c_ulong) c_int;
extern "c" fn setrlimit(resource: c_int, rlim: *const RLimit) c_int;
extern "c" fn syscall(number: c_long, ...) c_long;

const RLimit = extern struct {
    cur: u64,
    max: u64,
};

const linux_rlimits = struct {
    pub const CPU: c_int = 0;
    pub const CORE: c_int = 4;
    pub const NPROC: c_int = 6;
    pub const NOFILE: c_int = 7;
    pub const AS: c_int = 9;
};

const macos_rlimits = struct {
    pub const CPU: c_int = 0;
    pub const CORE: c_int = 4;
    pub const AS: c_int = 5;
    pub const NPROC: c_int = 7;
    pub const NOFILE: c_int = 8;
};

const RL = switch (builtin.os.tag) {
    .macos => macos_rlimits,
    else => linux_rlimits,
};

/// Cap virtual address space / fds / processes / core dumps. Linux+macOS.
fn applyRlimits() Error!void {
    const limits = [_]struct { res: c_int, cur: u64, max: u64 }{
        .{ .res = RL.AS, .cur = 2 * 1024 * 1024 * 1024, .max = 2 * 1024 * 1024 * 1024 }, // 2 GiB
        .{ .res = RL.NOFILE, .cur = 256, .max = 256 },
        .{ .res = RL.NPROC, .cur = 64, .max = 64 },
        .{ .res = RL.CORE, .cur = 0, .max = 0 },
    };
    for (limits) |l| {
        const rl = RLimit{ .cur = l.cur, .max = l.max };
        if (setrlimit(l.res, &rl) != 0) {
            // NPROC may not be settable in some user-namespaced containers;
            // tolerate failure on NPROC/AS only, hard-fail on CORE/NOFILE.
            if (l.res == RL.NPROC or l.res == RL.AS) continue;
            return error.SetrlimitFailed;
        }
    }
}

// -------- Linux: seccomp-bpf --------

const PR_SET_NO_NEW_PRIVS: c_int = 38;
const PR_SET_SECCOMP: c_int = 22;
const SECCOMP_MODE_FILTER: c_ulong = 2;

const sock_filter = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

const sock_fprog = extern struct {
    len: u16,
    filter: [*]const sock_filter,
};

const BPF_LD_W_ABS: u16 = 0x20;
const BPF_JMP_JEQ_K: u16 = 0x15;
const BPF_RET_K: u16 = 0x06;

const SECCOMP_RET_ALLOW: u32 = 0x7fff_0000;
const SECCOMP_RET_ERRNO: u32 = 0x0005_0000;
const EACCES: u32 = 13;

const x86_64_nr = struct {
    pub const socket: u32 = 41;
    pub const connect: u32 = 42;
    pub const accept: u32 = 43;
    pub const sendto: u32 = 44;
    pub const recvfrom: u32 = 45;
    pub const sendmsg: u32 = 46;
    pub const recvmsg: u32 = 47;
    pub const bind: u32 = 49;
    pub const listen: u32 = 50;
    pub const getsockname: u32 = 51;
    pub const getpeername: u32 = 52;
    pub const socketpair: u32 = 53;
    pub const setsockopt: u32 = 54;
    pub const getsockopt: u32 = 55;
    pub const accept4: u32 = 288;
};

const aarch64_nr = struct {
    pub const socket: u32 = 198;
    pub const bind: u32 = 200;
    pub const listen: u32 = 201;
    pub const accept: u32 = 202;
    pub const connect: u32 = 203;
    pub const getsockname: u32 = 204;
    pub const getpeername: u32 = 205;
    pub const sendto: u32 = 206;
    pub const recvfrom: u32 = 207;
    pub const setsockopt: u32 = 208;
    pub const getsockopt: u32 = 209;
    pub const sendmsg: u32 = 211;
    pub const recvmsg: u32 = 212;
    pub const accept4: u32 = 242;
    pub const socketpair: u32 = 199;
};

const NR = switch (builtin.cpu.arch) {
    .aarch64 => aarch64_nr,
    else => x86_64_nr,
};

fn applyLinuxSeccomp(allow_network: bool) Error!void {
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return error.PrctlFailed;
    if (allow_network) return;

    const banned = [_]u32{
        NR.socket,     NR.connect,     NR.accept,      NR.sendto,
        NR.recvfrom,   NR.sendmsg,     NR.recvmsg,     NR.bind,
        NR.listen,     NR.getsockname, NR.getpeername, NR.socketpair,
        NR.setsockopt, NR.getsockopt,  NR.accept4,
    };

    // Layout: 1 LD + per-banned (JEQ jf=1 / RET ERRNO) + final RET ALLOW.
    const insn_count = 1 + 2 * banned.len + 1;
    var insns: [insn_count]sock_filter = undefined;
    var idx: usize = 0;
    // load seccomp_data.nr at offset 0 (4 bytes)
    insns[idx] = .{ .code = BPF_LD_W_ABS, .jt = 0, .jf = 0, .k = 0 };
    idx += 1;
    for (banned) |nr| {
        // if A == nr: fallthrough → RET ERRNO; else skip 1 → next JEQ
        insns[idx] = .{ .code = BPF_JMP_JEQ_K, .jt = 0, .jf = 1, .k = nr };
        idx += 1;
        insns[idx] = .{ .code = BPF_RET_K, .jt = 0, .jf = 0, .k = SECCOMP_RET_ERRNO | EACCES };
        idx += 1;
    }
    insns[idx] = .{ .code = BPF_RET_K, .jt = 0, .jf = 0, .k = SECCOMP_RET_ALLOW };

    const prog = sock_fprog{ .len = @intCast(insns.len), .filter = &insns };
    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, @intFromPtr(&prog), 0, 0) != 0) return error.SeccompFailed;
}

// -------- Linux: Landlock (kernel ≥5.13) --------

const landlock_ruleset_attr = extern struct {
    handled_access_fs: u64,
};

const landlock_path_beneath_attr = extern struct {
    allowed_access: u64,
    parent_fd: i32,
};

const LL_FS_EXECUTE: u64 = 1 << 0;
const LL_FS_WRITE_FILE: u64 = 1 << 1;
const LL_FS_READ_FILE: u64 = 1 << 2;
const LL_FS_READ_DIR: u64 = 1 << 3;
const LL_FS_REMOVE_DIR: u64 = 1 << 4;
const LL_FS_REMOVE_FILE: u64 = 1 << 5;
const LL_FS_MAKE_CHAR: u64 = 1 << 6;
const LL_FS_MAKE_DIR: u64 = 1 << 7;
const LL_FS_MAKE_REG: u64 = 1 << 8;
const LL_FS_MAKE_SOCK: u64 = 1 << 9;
const LL_FS_MAKE_FIFO: u64 = 1 << 10;
const LL_FS_MAKE_BLOCK: u64 = 1 << 11;
const LL_FS_MAKE_SYM: u64 = 1 << 12;
const LL_FS_TRUNCATE: u64 = 1 << 14;

const NR_LANDLOCK_CREATE_RULESET: c_long = 444;
const NR_LANDLOCK_ADD_RULE: c_long = 445;
const NR_LANDLOCK_RESTRICT_SELF: c_long = 446;

const LANDLOCK_RULE_PATH_BENEATH: c_int = 1;
const LANDLOCK_ABI_LATEST: c_int = 4;

extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;

const O_PATH: c_int = 0o10000000;
const O_CLOEXEC: c_int = 0o2000000;

fn applyLandlock(allow_fs_write: []const []const u8) !void {
    const write_access: u64 = LL_FS_WRITE_FILE | LL_FS_REMOVE_DIR | LL_FS_REMOVE_FILE |
        LL_FS_MAKE_CHAR | LL_FS_MAKE_DIR | LL_FS_MAKE_REG | LL_FS_MAKE_SOCK |
        LL_FS_MAKE_FIFO | LL_FS_MAKE_BLOCK | LL_FS_MAKE_SYM | LL_FS_TRUNCATE;
    const read_access: u64 = LL_FS_EXECUTE | LL_FS_READ_FILE | LL_FS_READ_DIR;
    const all_access: u64 = read_access | write_access;

    var attr = landlock_ruleset_attr{ .handled_access_fs = all_access };
    const attr_size: c_ulong = @sizeOf(landlock_ruleset_attr);
    const ruleset_rv = syscall(NR_LANDLOCK_CREATE_RULESET, &attr, attr_size, @as(c_uint, 0));
    if (ruleset_rv < 0) return error.LandlockUnavailable;
    const ruleset_fd: c_int = @intCast(ruleset_rv);
    defer _ = close(ruleset_fd);

    // Allow read+execute everywhere by adding rule on "/".
    {
        const root_fd = open("/", O_PATH | O_CLOEXEC, 0);
        if (root_fd >= 0) {
            defer _ = close(root_fd);
            var rule = landlock_path_beneath_attr{ .allowed_access = read_access, .parent_fd = root_fd };
            _ = syscall(NR_LANDLOCK_ADD_RULE, @as(c_int, ruleset_fd), @as(c_int, LANDLOCK_RULE_PATH_BENEATH), &rule, @as(c_uint, 0));
        }
    }

    // Always allow writes under /tmp (Ruby tempfiles, plugin scratch).
    var path_buf: [4096]u8 = undefined;
    {
        const tmp_fd = open("/tmp", O_PATH | O_CLOEXEC, 0);
        if (tmp_fd >= 0) {
            defer _ = close(tmp_fd);
            var rule = landlock_path_beneath_attr{ .allowed_access = all_access, .parent_fd = tmp_fd };
            _ = syscall(NR_LANDLOCK_ADD_RULE, @as(c_int, ruleset_fd), @as(c_int, LANDLOCK_RULE_PATH_BENEATH), &rule, @as(c_uint, 0));
        }
    }

    // Allow read+write on each path in allow_fs_write.
    for (allow_fs_write) |path| {
        if (path.len == 0 or path.len >= path_buf.len) continue;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&path_buf);
        const pfd = open(path_z, O_PATH | O_CLOEXEC, 0);
        if (pfd < 0) continue;
        defer _ = close(pfd);
        var rule = landlock_path_beneath_attr{ .allowed_access = all_access, .parent_fd = pfd };
        _ = syscall(NR_LANDLOCK_ADD_RULE, @as(c_int, ruleset_fd), @as(c_int, LANDLOCK_RULE_PATH_BENEATH), &rule, @as(c_uint, 0));
    }

    const restrict_rv = syscall(NR_LANDLOCK_RESTRICT_SELF, @as(c_int, ruleset_fd), @as(c_uint, 0));
    if (restrict_rv < 0) return error.LandlockFailed;
}

// -------- macOS: sandbox_init --------

extern "c" fn sandbox_init(profile: [*:0]const u8, flags: u64, errorbuf: *?[*:0]u8) c_int;
extern "c" fn sandbox_free_error(errorbuf: [*:0]u8) void;

fn applyMacosSandbox(config: Config) Error!void {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.heap.page_allocator);
    const w = buf.writer(std.heap.page_allocator);

    // SBPL profile: read-only by default; deny network; allow specific writes.
    w.print(
        \\(version 1)
        \\(deny default)
        \\(allow process-fork)
        \\(allow process-exec)
        \\(allow signal (target self))
        \\(allow sysctl-read)
        \\(allow mach-lookup)
        \\(allow file-read*)
        \\(allow ipc-posix-shm)
    , .{}) catch return error.SandboxInitFailed;

    if (config.allow_network) {
        w.print("\n(allow network*)", .{}) catch return error.SandboxInitFailed;
    }

    for (config.allow_fs_write) |p| {
        w.print("\n(allow file-write* (subpath \"{s}\"))", .{p}) catch return error.SandboxInitFailed;
    }
    // Always allow writes under /tmp (plugin tempfiles) and /dev/null.
    w.print("\n(allow file-write* (subpath \"/tmp\"))", .{}) catch return error.SandboxInitFailed;
    w.print("\n(allow file-write-data (literal \"/dev/null\"))", .{}) catch return error.SandboxInitFailed;
    buf.append(std.heap.page_allocator, 0) catch return error.SandboxInitFailed;

    var err: ?[*:0]u8 = null;
    const profile_z: [*:0]const u8 = @ptrCast(buf.items.ptr);
    if (sandbox_init(profile_z, 0, &err) != 0) {
        if (err) |e| sandbox_free_error(e);
        return error.SandboxInitFailed;
    }
}

/// Apply sandbox to current process. Idempotent within a process. The
/// trampoline pattern: call this *before* `execve` of the plugin entry — the
/// seccomp filter, Landlock ruleset, and rlimits persist across exec.
pub fn apply(config: Config) Error!void {
    try applyRlimits();
    switch (builtin.os.tag) {
        .linux => {
            try applyLinuxSeccomp(config.allow_network);
            applyLandlock(config.allow_fs_write) catch |e| switch (e) {
                error.LandlockUnavailable => {}, // pre-5.13 kernel; seccomp+rlimits floor stands
                else => return error.LandlockFailed,
            };
        },
        .macos => try applyMacosSandbox(config),
        else => return error.UnsupportedPlatform,
    }
}

test "Config defaults" {
    const c = Config{};
    try std.testing.expectEqual(false, c.allow_network);
    try std.testing.expectEqual(@as(usize, 0), c.allow_fs_write.len);
}

extern "c" fn fork() c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn socket(domain: c_int, type_: c_int, protocol: c_int) c_int;

test "Linux seccomp blocks AF_INET socket() in child" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const pid = fork();
    if (pid < 0) return error.SkipZigTest;
    if (pid == 0) {
        // Child: apply sandbox, then try to open an AF_INET socket. Filter
        // should return EACCES → fd<0 → exit 0 (sandboxed). If fd≥0 the
        // filter didn't take effect → exit 1 (failure).
        applyLinuxSeccomp(false) catch std.process.exit(2);
        const fd = socket(2, 1, 0); // AF_INET=2, SOCK_STREAM=1
        std.process.exit(if (fd < 0) 0 else 1);
    }
    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);
    // POSIX: low 7 bits = signal-on-termination (0 if exited cleanly);
    // bits 8-15 = exit status.
    const exited_cleanly = (status & 0x7f) == 0;
    const exit_code = (status >> 8) & 0xff;
    try std.testing.expect(exited_cleanly);
    try std.testing.expectEqual(@as(c_int, 0), exit_code);
}

test "Linux seccomp allow_network lets AF_INET socket() succeed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const pid = fork();
    if (pid < 0) return error.SkipZigTest;
    if (pid == 0) {
        applyLinuxSeccomp(true) catch std.process.exit(2);
        const fd = socket(2, 1, 0);
        std.process.exit(if (fd >= 0) 0 else 1);
    }
    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);
    const exited_cleanly = (status & 0x7f) == 0;
    const exit_code = (status >> 8) & 0xff;
    try std.testing.expect(exited_cleanly);
    try std.testing.expectEqual(@as(c_int, 0), exit_code);
}
