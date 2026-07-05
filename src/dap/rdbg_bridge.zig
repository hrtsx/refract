const std = @import("std");
const transport = @import("../lsp/transport.zig");

/// Spawn `rdbg --open=stdio` against the user's program. rdbg already speaks
/// DAP — refract acts as a thin orchestrator that handles workspace path
/// resolution + ENV propagation (chruby/rbenv/asdf via Lane R) + heartbeat
/// + `terminated` event on rdbg crash. Direct DAP frames flow through here
/// unchanged.
pub const RdbgBridge = struct {
    child: std.process.Child,
    alloc: std.mem.Allocator,
    program: []u8,
    cwd: []u8,
    io: std.Io = std.Options.debug_io,
    io_mu: std.Io.Mutex = std.Io.Mutex.init,

    /// Build rdbg argv. Defaults to `rdbg --open=stdio --nonstop -- <program> <args...>`.
    /// The caller may override the rdbg binary via `RDBG_BIN` env var.
    pub fn buildArgv(alloc: std.mem.Allocator, program: []const u8, program_args: []const []const u8) ![][]const u8 {
        const rdbg_bin = if (std.c.getenv("RDBG_BIN")) |v| try alloc.dupe(u8, std.mem.span(v)) else try alloc.dupe(u8, "rdbg");
        var argv = std.ArrayList([]const u8).empty;
        errdefer {
            for (argv.items) |x| alloc.free(@constCast(x));
            argv.deinit(alloc);
        }
        try argv.append(alloc, rdbg_bin);
        try argv.append(alloc, try alloc.dupe(u8, "--open=stdio"));
        try argv.append(alloc, try alloc.dupe(u8, "--nonstop"));
        try argv.append(alloc, try alloc.dupe(u8, "--"));
        try argv.append(alloc, try alloc.dupe(u8, program));
        for (program_args) |a| try argv.append(alloc, try alloc.dupe(u8, a));
        return try argv.toOwnedSlice(alloc);
    }

    pub fn freeArgv(alloc: std.mem.Allocator, argv: [][]const u8) void {
        for (argv) |a| alloc.free(@constCast(a));
        alloc.free(argv);
    }

    pub const Error = error{RdbgNotFound};

    /// True when `bin` is an executable we can find: a path with a slash is checked
    /// directly; a bare name is searched on PATH. Used to fail fast with a precise
    /// RdbgNotFound, since spawning a nonexistent program can otherwise defer the
    /// failure to the child (exit 127) rather than erroring at spawn on some hosts.
    fn binaryAvailable(alloc: std.mem.Allocator, bin: []const u8) bool {
        if (std.mem.indexOfScalar(u8, bin, '/') != null) {
            const z = alloc.dupeZ(u8, bin) catch return true; // on OOM, don't block launch
            defer alloc.free(z);
            return std.c.access(z, std.c.X_OK) == 0;
        }
        const path_env = std.c.getenv("PATH") orelse return false;
        var it = std.mem.splitScalar(u8, std.mem.span(path_env), ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const cand = std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ dir, bin }, 0) catch continue;
            defer alloc.free(cand);
            if (std.c.access(cand, std.c.X_OK) == 0) return true;
        }
        return false;
    }

    pub fn launch(alloc: std.mem.Allocator, program: []const u8, program_args: []const []const u8, cwd: []const u8, io: std.Io) !RdbgBridge {
        const rdbg_bin: []const u8 = if (std.c.getenv("RDBG_BIN")) |v| std.mem.span(v) else "rdbg";
        if (!binaryAvailable(alloc, rdbg_bin)) return error.RdbgNotFound;
        const argv = try buildArgv(alloc, program, program_args);
        defer freeArgv(alloc, argv);
        const cwd_z = try alloc.dupeZ(u8, cwd);
        defer alloc.free(cwd_z);
        // Spawn on the real event-loop Io — `debug_io` cannot launch a child.
        const child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .cwd = .{ .path = cwd_z },
        }) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => return error.RdbgNotFound,
            else => return err,
        };
        return RdbgBridge{
            .child = child,
            .alloc = alloc,
            .program = try alloc.dupe(u8, program),
            .cwd = try alloc.dupe(u8, cwd),
            .io = io,
        };
    }

    pub fn deinit(self: *RdbgBridge) void {
        // Kill on the spawn Io without wait — `wait` panics on this Io; the OS
        // reaps the orphan at process exit.
        if (self.child.stdin) |s| s.close(self.io);
        self.child.stdin = null;
        self.child.kill(self.io);
        self.alloc.free(self.program);
        self.alloc.free(self.cwd);
    }

    pub fn writeFrame(self: *RdbgBridge, body: []const u8) !void {
        self.io_mu.lockUncancelable(std.Options.debug_io);
        defer self.io_mu.unlock(std.Options.debug_io);
        var stdin = self.child.stdin orelse return error.NoStdin;
        try transport.writeStreamFrame(&stdin, body);
    }

    pub fn readFrame(self: *RdbgBridge) ![]u8 {
        var stdout = self.child.stdout orelse return error.NoStdout;
        return transport.readStreamFrame(&stdout, self.alloc);
    }
};

test "buildArgv assembles rdbg invocation" {
    const alloc = std.testing.allocator;
    const args = [_][]const u8{"spec/foo_spec.rb"};
    const argv = try RdbgBridge.buildArgv(alloc, "bundle exec rspec", &args);
    defer RdbgBridge.freeArgv(alloc, argv);

    try std.testing.expect(argv.len >= 5);
    try std.testing.expectEqualStrings("--open=stdio", argv[1]);
    try std.testing.expectEqualStrings("--nonstop", argv[2]);
    try std.testing.expectEqualStrings("--", argv[3]);
    try std.testing.expectEqualStrings("bundle exec rspec", argv[4]);
    try std.testing.expectEqualStrings("spec/foo_spec.rb", argv[5]);
}

test "buildArgv empty program_args still produces well-formed argv" {
    const alloc = std.testing.allocator;
    const args = [_][]const u8{};
    const argv = try RdbgBridge.buildArgv(alloc, "ruby app.rb", &args);
    defer RdbgBridge.freeArgv(alloc, argv);

    try std.testing.expect(argv.len == 5);
    try std.testing.expectEqualStrings("--open=stdio", argv[1]);
    try std.testing.expectEqualStrings("--", argv[3]);
    try std.testing.expectEqualStrings("ruby app.rb", argv[4]);
}

test "buildArgv honours RDBG_BIN override" {
    const c_lib = @cImport({
        @cInclude("stdlib.h");
    });
    _ = c_lib.setenv("RDBG_BIN", "/custom/path/to/rdbg-override", 1);
    defer _ = c_lib.unsetenv("RDBG_BIN");
    const alloc = std.testing.allocator;
    const args = [_][]const u8{};
    const argv = try RdbgBridge.buildArgv(alloc, "p", &args);
    defer RdbgBridge.freeArgv(alloc, argv);
    try std.testing.expectEqualStrings("/custom/path/to/rdbg-override", argv[0]);
}

test "buildArgv multi-arg program forwards all program_args after --" {
    const alloc = std.testing.allocator;
    const args = [_][]const u8{ "--seed", "42", "spec/foo_spec.rb" };
    const argv = try RdbgBridge.buildArgv(alloc, "bundle exec rspec", &args);
    defer RdbgBridge.freeArgv(alloc, argv);
    try std.testing.expect(argv.len == 5 + args.len);
    try std.testing.expectEqualStrings("--", argv[3]);
    try std.testing.expectEqualStrings("--seed", argv[5]);
    try std.testing.expectEqualStrings("42", argv[6]);
    try std.testing.expectEqualStrings("spec/foo_spec.rb", argv[7]);
}
