const std = @import("std");
const dap_server = @import("../dap/server.zig");
const transport = @import("../lsp/transport.zig");
const c = @cImport({
    @cInclude("stdlib.h");
});

test "dispatch unknown command returns success:false with correct format" {
    const alloc = std.testing.allocator;
    var s = dap_server.Server.init(alloc, std.Options.debug_io);

    var out_bytes: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_bytes);

    const req =
        \\{"seq":1,"type":"request","command":"unknownCmd","arguments":{}}
    ;
    try s.dispatch(req, &w);

    const written = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"success\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "command not supported: unknownCmd") != null);
}

test "initialize emits both response and initialized event" {
    const alloc = std.testing.allocator;
    var s = dap_server.Server.init(alloc, std.Options.debug_io);

    var out_bytes: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_bytes);

    const req =
        \\{"seq":1,"type":"request","command":"initialize","arguments":{}}
    ;
    try s.dispatch(req, &w);

    const written = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"command\":\"initialize\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"event\":\"initialized\"") != null);
    try std.testing.expect(s.initialized);
}

test "setBreakpoints without bridge returns no debug session error" {
    const alloc = std.testing.allocator;
    var s = dap_server.Server.init(alloc, std.Options.debug_io);

    var out_bytes: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_bytes);

    const req =
        \\{"seq":2,"type":"request","command":"setBreakpoints","arguments":{"source":{"path":"/tmp/test.rb"},"breakpoints":[]}}
    ;
    try s.dispatch(req, &w);

    const written = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"success\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "no debug session") != null);
}

test "launch with missing rdbg emits output event with install hint before failure response" {
    const alloc = std.testing.allocator;
    _ = c.setenv("RDBG_BIN", "/nonexistent/refract-test-rdbg-binary", 1);
    defer _ = c.unsetenv("RDBG_BIN");

    var s = dap_server.Server.init(alloc, std.Options.debug_io);
    var out_bytes: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_bytes);

    const req =
        \\{"seq":3,"type":"request","command":"launch","arguments":{"program":"/bin/true","cwd":"/tmp"}}
    ;
    try s.dispatch(req, &w);

    const written = w.buffered();
    const out_idx = std.mem.indexOf(u8, written, "\"event\":\"output\"") orelse return error.MissingOutputEvent;
    const hint_idx = std.mem.indexOf(u8, written, "gem install debug") orelse return error.MissingInstallHint;
    const launch_resp_idx = std.mem.indexOf(u8, written, "\"command\":\"launch\"") orelse return error.MissingLaunchResponse;
    try std.testing.expect(out_idx < launch_resp_idx);
    try std.testing.expect(hint_idx < launch_resp_idx);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"success\":false") != null);
}
