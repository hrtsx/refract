const std = @import("std");
const dap_server = @import("../dap/server.zig");
const transport = @import("../lsp/transport.zig");

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
