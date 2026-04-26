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

    pub fn launch(alloc: std.mem.Allocator, program: []const u8, program_args: []const []const u8, cwd: []const u8) !RdbgBridge {
        const argv = try buildArgv(alloc, program, program_args);
        defer freeArgv(alloc, argv);
        const cwd_z = try alloc.dupeZ(u8, cwd);
        defer alloc.free(cwd_z);
        const child = std.process.spawn(std.Options.debug_io, .{
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
        };
    }

    pub fn deinit(self: *RdbgBridge) void {
        if (self.child.stdin) |s| s.close(std.Options.debug_io);
        self.child.stdin = null;
        self.child.kill(std.Options.debug_io);
        _ = self.child.wait(std.Options.debug_io) catch {};
        self.alloc.free(self.program);
        self.alloc.free(self.cwd);
    }

    pub fn writeFrame(self: *RdbgBridge, body: []const u8) !void {
        self.io_mu.lockUncancelable(std.Options.debug_io);
        defer self.io_mu.unlock(std.Options.debug_io);
        var stdin = self.child.stdin orelse return error.NoStdin;
        var sbuf: [256]u8 = undefined;
        const header = try std.fmt.bufPrint(&sbuf, "Content-Length: {d}\r\n\r\n", .{body.len});
        try stdin.writeStreamingAll(std.Options.debug_io, header);
        try stdin.writeStreamingAll(std.Options.debug_io, body);
    }

    pub fn readFrame(self: *RdbgBridge) ![]u8 {
        var stdout = self.child.stdout orelse return error.NoStdout;
        var hdr_buf: [256]u8 = undefined;
        var hdr_len: usize = 0;
        while (hdr_len < hdr_buf.len) {
            const n = try stdout.readStreaming(std.Options.debug_io, &.{hdr_buf[hdr_len .. hdr_len + 1]});
            if (n == 0) return error.EndOfStream;
            hdr_len += n;
            if (hdr_len >= 4 and std.mem.eql(u8, hdr_buf[hdr_len - 4 .. hdr_len], "\r\n\r\n")) break;
        }
        var content_len: usize = 0;
        var it = std.mem.splitSequence(u8, hdr_buf[0..hdr_len], "\r\n");
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "Content-Length: ")) {
                content_len = std.fmt.parseInt(usize, line["Content-Length: ".len..], 10) catch 0;
            }
        }
        if (content_len == 0 or content_len > 16 * 1024 * 1024) return error.InvalidContentLength;
        const body = try self.alloc.alloc(u8, content_len);
        var got: usize = 0;
        while (got < content_len) {
            const n = try stdout.readStreaming(std.Options.debug_io, &.{body[got..]});
            if (n == 0) {
                self.alloc.free(body);
                return error.EndOfStream;
            }
            got += n;
        }
        return body;
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
