const std = @import("std");
const transport = @import("../lsp/transport.zig");

pub const ServerKind = enum {
    sorbet,
    steep,

    pub fn argv(self: ServerKind, project_root: []const u8, alloc: std.mem.Allocator) ![]const []const u8 {
        _ = project_root;
        return switch (self) {
            .sorbet => try alloc.dupe([]const u8, &.{ "bundle", "exec", "srb", "tc", "--lsp", "--no-config-file" }),
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

    pub fn launch(kind: ServerKind, project_root: []const u8, alloc: std.mem.Allocator) !Harness {
        const args = try kind.argv(project_root, alloc);
        defer alloc.free(args);
        const cwd_z = try alloc.dupeZ(u8, project_root);
        defer alloc.free(cwd_z);
        const child = try std.process.spawn(std.Options.debug_io, .{
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
        };
    }

    pub fn sendInitialize(self: *Harness, root_uri: []const u8) !void {
        const id = self.next_id;
        self.next_id += 1;
        const body = try std.fmt.allocPrint(
            self.alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"rootUri\":\"{s}\",\"capabilities\":{{}}}}}}",
            .{ id, root_uri },
        );
        defer self.alloc.free(body);
        try self.writeFrame(body);
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
        const start_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds();
        try self.writeFrame(body);
        const resp = try self.readFrame();
        self.alloc.free(resp);
        const end_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds();
        const elapsed_ms: u64 = if (end_ms > start_ms) @intCast(end_ms - start_ms) else 0;
        return elapsed_ms * 1000;
    }

    fn writeFrame(self: *Harness, body: []const u8) !void {
        var stdin = self.child.stdin orelse return error.NoStdin;
        var sbuf: [256]u8 = undefined;
        const header = try std.fmt.bufPrint(&sbuf, "Content-Length: {d}\r\n\r\n", .{body.len});
        try stdin.writeStreamingAll(std.Options.debug_io, header);
        try stdin.writeStreamingAll(std.Options.debug_io, body);
    }

    fn readFrame(self: *Harness) ![]u8 {
        var stdout = self.child.stdout orelse return error.NoStdout;
        var hdr_buf: [256]u8 = undefined;
        var hdr_len: usize = 0;
        while (hdr_len < hdr_buf.len) {
            const n = try stdout.readStreaming(std.Options.debug_io, &.{hdr_buf[hdr_len .. hdr_len + 1]});
            if (n == 0) return error.EndOfStream;
            hdr_len += n;
            if (hdr_len >= 4 and std.mem.eql(u8, hdr_buf[hdr_len - 4 .. hdr_len], "\r\n\r\n")) break;
        }
        const header_str = hdr_buf[0..hdr_len];
        var content_len: usize = 0;
        var it = std.mem.splitSequence(u8, header_str, "\r\n");
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

    pub fn deinit(self: *Harness) void {
        if (self.child.stdin) |s| s.close(std.Options.debug_io);
        self.child.stdin = null;
        self.child.kill(std.Options.debug_io);
        _ = self.child.wait(std.Options.debug_io) catch {};
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
