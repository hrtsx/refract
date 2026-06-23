const std = @import("std");
const exe_path_util = @import("../exe_path.zig");
const sorbet_harness = @import("../tests/sorbet_harness.zig");
const sandbox = @import("../lsp/sandbox.zig");

fn selfExePath(buf: []u8) ?[]const u8 {
    return exe_path_util.selfExePath(buf);
}

fn selfTestProbe(io: std.Io, alloc: std.mem.Allocator, label: []const u8, exe_path: []const u8, extra_arg: ?[]const u8, db_path: []const u8, cwd_path: []const u8, request_body: []const u8, expect_substr: []const u8, lsp_framing: bool) bool {
    var stderr = std.Io.File.stderr();

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(alloc);
    argv.append(alloc, exe_path) catch return false;
    if (extra_arg) |a| argv.append(alloc, a) catch return false;
    argv.append(alloc, "--db-path") catch return false;
    argv.append(alloc, db_path) catch return false;

    const cwd_z = alloc.dupeZ(u8, cwd_path) catch return false;
    defer alloc.free(cwd_z);

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .cwd = .{ .path = cwd_z },
    }) catch return false;
    defer child.kill(io);

    if (child.stdin) |*sin| {
        if (lsp_framing) {
            var hdr_buf: [128]u8 = undefined;
            const hdr = std.fmt.bufPrint(&hdr_buf, "Content-Length: {d}\r\n\r\n", .{request_body.len}) catch return false;
            sin.writeStreamingAll(io, hdr) catch return false;
            sin.writeStreamingAll(io, request_body) catch return false;
        } else {
            sin.writeStreamingAll(io, request_body) catch return false;
            sin.writeStreamingAll(io, "\n") catch return false;
        }
    }

    var out_buf: [16384]u8 = undefined;
    var got: usize = 0;
    const start = std.Io.Timestamp.now(io, .real).toMilliseconds();
    while (got < out_buf.len) {
        const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
        if (now - start > 5000) break;
        if (child.stdout) |*sout| {
            const n = sout.readStreaming(io, &.{out_buf[got..]}) catch break;
            if (n == 0) break;
            got += n;
            if (std.mem.indexOf(u8, out_buf[0..got], expect_substr) != null) {
                stderr.writeStreamingAll(io, "  ✓ ") catch {};
                stderr.writeStreamingAll(io, label) catch {};
                stderr.writeStreamingAll(io, "\n") catch {};
                return true;
            }
        } else break;
    }
    stderr.writeStreamingAll(io, "  ✗ ") catch {};
    stderr.writeStreamingAll(io, label) catch {};
    stderr.writeStreamingAll(io, " (no expected response within 5s)\n") catch {};
    return false;
}

pub fn runSelfTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var stderr = std.Io.File.stderr();
    try stderr.writeStreamingAll(io, "refract --self-test\n===================\n");

    var exe_buf: [4096]u8 = undefined;
    const exe_path = selfExePath(&exe_buf) orelse {
        try stderr.writeStreamingAll(io, "  ✗ could not resolve self exe path\n");
        return error.SelfExePath;
    };

    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const rid = std.mem.readInt(u64, &rnd, .little);

    const lsp_db = try std.fmt.allocPrint(alloc, "/tmp/refract_selftest_lsp_{x}.db", .{rid});
    defer alloc.free(lsp_db);
    const mcp_db = try std.fmt.allocPrint(alloc, "/tmp/refract_selftest_mcp_{x}.db", .{rid});
    defer alloc.free(mcp_db);
    const ws = try std.fmt.allocPrint(alloc, "/tmp/refract_selftest_ws_{x}", .{rid});
    defer alloc.free(ws);
    std.Io.Dir.createDirAbsolute(io, ws, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, ws) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, lsp_db) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, mcp_db) catch {};

    const lsp_req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":"file:///tmp","capabilities":{},"initializationOptions":{"disableGemIndex":true,"disableRubocop":true}}}
    ;
    const mcp_req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"refract-self-test","version":"1"}}}
    ;

    var ok = true;
    if (!selfTestProbe(io, alloc, "LSP initialize handshake", exe_path, null, lsp_db, ws, lsp_req, "\"capabilities\"", true)) ok = false;
    if (!selfTestProbe(io, alloc, "MCP initialize handshake", exe_path, "--mcp", mcp_db, ws, mcp_req, "\"protocolVersion\"", false)) ok = false;

    if (ok) {
        try stderr.writeStreamingAll(io, "self-test OK\n");
    } else {
        try stderr.writeStreamingAll(io, "self-test FAILED\n");
        return error.SelfTestFailed;
    }
}

pub fn runBenchSorbetSteep(io: std.Io, alloc: std.mem.Allocator, sorbet_root: ?[]const u8, steep_root: ?[]const u8) !void {
    var stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, "server,method,iter,latency_us\n");
    if (sorbet_root) |root| {
        runOneServer(io, alloc, .sorbet, root, &stdout) catch |err| {
            var ebuf: [256]u8 = undefined;
            const m = std.fmt.bufPrint(&ebuf, "refract: sorbet bench failed: {s}\n", .{@errorName(err)}) catch "refract: sorbet bench failed\n";
            try std.Io.File.stderr().writeStreamingAll(io, m);
        };
    }
    if (steep_root) |root| {
        runOneServer(io, alloc, .steep, root, &stdout) catch |err| {
            var ebuf: [256]u8 = undefined;
            const m = std.fmt.bufPrint(&ebuf, "refract: steep bench failed: {s}\n", .{@errorName(err)}) catch "refract: steep bench failed\n";
            try std.Io.File.stderr().writeStreamingAll(io, m);
        };
    }
}

fn runOneServer(io: std.Io, alloc: std.mem.Allocator, kind: sorbet_harness.ServerKind, root: []const u8, stdout: *std.Io.File) !void {
    var h = try sorbet_harness.Harness.launch(kind, root, alloc);
    defer h.deinit();
    var uri_buf: [1024]u8 = undefined;
    const root_uri = try std.fmt.bufPrint(&uri_buf, "file://{s}", .{root});
    try h.sendInitialize(root_uri);
    const probe_count: u32 = 10;
    var i: u32 = 0;
    while (i < probe_count) : (i += 1) {
        const us = h.measureRequest("textDocument/hover", "{}") catch 0;
        var lbuf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&lbuf, "{s},hover,{d},{d}\n", .{ @tagName(kind), i, us });
        try stdout.writeStreamingAll(io, line);
    }
    h.sendShutdown() catch {};
}

/// Sandbox trampoline. Parses --allow-network / --allow-fs-write=PATH flags,
/// then everything after `--` is the plugin argv. Applies sandbox to current
/// process and execve's the plugin. Filter persists across exec.
pub fn runSandboxExec(alloc: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    var allow_network = false;
    var allow_fs_write_list = std.ArrayList([]const u8).empty;
    defer allow_fs_write_list.deinit(alloc);

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        } else if (std.mem.eql(u8, a, "--allow-network")) {
            allow_network = true;
        } else if (std.mem.startsWith(u8, a, "--allow-fs-write=")) {
            try allow_fs_write_list.append(alloc, a["--allow-fs-write=".len..]);
        } else {
            try std.Io.File.stderr().writeStreamingAll(io, "refract --sandbox-exec: unknown flag\n");
            std.process.exit(2);
        }
    }
    if (i >= args.len) {
        try std.Io.File.stderr().writeStreamingAll(io, "refract --sandbox-exec: missing plugin entry after --\n");
        std.process.exit(2);
    }

    const config = sandbox.Config{
        .allow_network = allow_network,
        .allow_fs_write = allow_fs_write_list.items,
    };
    sandbox.apply(config) catch |e| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "refract --sandbox-exec: sandbox init failed: {s}\n", .{@errorName(e)}) catch "refract: sandbox init failed\n";
        try std.Io.File.stderr().writeStreamingAll(io, msg);
        std.process.exit(3);
    };

    // Build NULL-terminated argv for execve. Entries are already :0 in our
    // args (Zig CLI args are sentinel-terminated), so we can reuse the
    // pointers directly without re-duping.
    const child_argv = args[i..];
    const argv_z = try alloc.alloc(?[*:0]const u8, child_argv.len + 1);
    defer alloc.free(argv_z);
    for (child_argv, 0..) |arg, idx| argv_z[idx] = arg.ptr;
    argv_z[child_argv.len] = null;

    const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv_z.ptr);
    const envp_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&std.c.environ[0]);
    _ = std.c.execve(child_argv[0].ptr, argv_ptr, envp_ptr);
    // If we reach here, execve failed.
    try std.Io.File.stderr().writeStreamingAll(io, "refract --sandbox-exec: execve failed\n");
    std.process.exit(4);
}
