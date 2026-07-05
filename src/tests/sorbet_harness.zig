const std = @import("std");
const transport = @import("../lsp/transport.zig");

pub const ServerKind = enum {
    sorbet,
    steep,

    pub fn argv(self: ServerKind, project_root: []const u8, alloc: std.mem.Allocator) ![]const []const u8 {
        _ = project_root;
        return switch (self) {
            .sorbet => try alloc.dupe([]const u8, &.{ "bundle", "exec", "srb", "tc", "--lsp", "--disable-watchman" }),
            .steep => try alloc.dupe([]const u8, &.{ "bundle", "exec", "steep", "langserver" }),
        };
    }
};

pub const Harness = struct {
    kind: ServerKind,
    child: std.process.Child,
    alloc: std.mem.Allocator,
    next_id: i64 = 1,
    project_root: []u8,
    io: std.Io,

    pub fn launch(kind: ServerKind, project_root: []const u8, alloc: std.mem.Allocator, io: std.Io) !Harness {
        const args = try kind.argv(project_root, alloc);
        defer alloc.free(args);
        const cwd_z = try alloc.dupeZ(u8, project_root);
        defer alloc.free(cwd_z);
        // Spawn on the real event-loop Io — `debug_io` cannot launch a child.
        const child = try std.process.spawn(io, .{
            .argv = args,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .cwd = .{ .path = cwd_z },
        });
        return Harness{
            .kind = kind,
            .child = child,
            .alloc = alloc,
            .project_root = try alloc.dupe(u8, project_root),
            .io = io,
        };
    }

    /// Full LSP handshake: initialize (await id-matched response) then the
    /// required `initialized` notification, so the server leaves loading state.
    pub fn sendInitialize(self: *Harness, root_uri: []const u8) !void {
        const id = self.next_id;
        self.next_id += 1;
        const body = try std.fmt.allocPrint(
            self.alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"processId\":null,\"rootUri\":\"{s}\",\"capabilities\":{{}},\"initializationOptions\":{{}}}}}}",
            .{ id, root_uri },
        );
        defer self.alloc.free(body);
        try self.writeFrame(body);
        const resp = try self.readResponse(id);
        self.alloc.free(resp);
        const initd = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}";
        try self.writeFrame(initd);
    }

    /// Read frames, skipping interleaved notifications, until the id-matched
    /// response. Caller frees the returned bytes.
    fn readResponse(self: *Harness, id: i64) ![]u8 {
        var stdout = self.child.stdout orelse return error.NoStdout;
        return transport.readResponseById(&stdout, self.alloc, id);
    }

    pub fn sendShutdown(self: *Harness) !void {
        const id = self.next_id;
        self.next_id += 1;
        var buf: [128]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"shutdown\"}}", .{id});
        try self.writeFrame(body);
    }

    /// Send a request, await a response by id, return latency in microseconds.
    pub fn measureRequest(self: *Harness, method: []const u8, params_json: []const u8) !u64 {
        const id = self.next_id;
        self.next_id += 1;
        const body = try std.fmt.allocPrint(
            self.alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
            .{ id, method, params_json },
        );
        defer self.alloc.free(body);
        const start_ns = std.Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds();
        try self.writeFrame(body);
        const resp = try self.readResponse(id);
        self.alloc.free(resp);
        const end_ns = std.Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds();
        const elapsed_ns: u64 = if (end_ns > start_ns) @intCast(end_ns - start_ns) else 0;
        return elapsed_ns / std.time.ns_per_us;
    }

    fn writeFrame(self: *Harness, body: []const u8) !void {
        var stdin = self.child.stdin orelse return error.NoStdin;
        try transport.writeStreamFrame(&stdin, body);
    }

    pub fn deinit(self: *Harness) void {
        // Child ops must use the spawn Io. Kill without wait — `wait` on this Io
        // panics (reached unreachable); the OS reaps the orphan at exit, matching
        // the proven selfTestProbe teardown.
        if (self.child.stdin) |s| s.close(self.io);
        self.child.stdin = null;
        self.child.kill(self.io);
        self.alloc.free(self.project_root);
    }
};

test "argv builds for both kinds" {
    const alloc = std.testing.allocator;
    const a1 = try ServerKind.sorbet.argv("/tmp/x", alloc);
    defer alloc.free(a1);
    try std.testing.expect(a1.len > 0);
    try std.testing.expectEqualStrings("srb", a1[2]);

    const a2 = try ServerKind.steep.argv("/tmp/x", alloc);
    defer alloc.free(a2);
    try std.testing.expect(a2.len > 0);
    try std.testing.expectEqualStrings("steep", a2[2]);
}
