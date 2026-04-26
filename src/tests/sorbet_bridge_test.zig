const std = @import("std");
const sorbet_bridge = @import("../lsp/sorbet_bridge.zig");

test "P50 T50.1 ServerKind.sorbet argv returns expected args" {
    const argv = sorbet_bridge.ServerKind.sorbet.argv();
    try std.testing.expect(argv.len >= 2);
    try std.testing.expectEqualSlices(u8, argv[0], "bundle");
}

test "P50 T50.2 ServerKind.steep argv returns expected args" {
    const argv = sorbet_bridge.ServerKind.steep.argv();
    try std.testing.expect(argv.len >= 2);
    try std.testing.expectEqualSlices(u8, argv[0], "bundle");
}

test "P50 T50.3 ServerKind.sorbet label matches" {
    const label = sorbet_bridge.ServerKind.sorbet.label();
    try std.testing.expectEqualSlices(u8, label, "sorbet");
}

test "P50 T50.4 ServerKind.steep label matches" {
    const label = sorbet_bridge.ServerKind.steep.label();
    try std.testing.expectEqualSlices(u8, label, "steep");
}

test "P50 T50.5 ServerKind.sorbet tableName returns correct table" {
    const table = sorbet_bridge.ServerKind.sorbet.tableName();
    try std.testing.expectEqualSlices(u8, table, "sorbet_results");
}

test "P50 T50.6 ServerKind.steep tableName returns correct table" {
    const table = sorbet_bridge.ServerKind.steep.tableName();
    try std.testing.expectEqualSlices(u8, table, "steep_results");
}

test "P50 T50.7 workspaceHasSorbet returns false for nonexistent path" {
    const alloc = std.testing.allocator;
    const has_sorbet = sorbet_bridge.workspaceHasSorbet("/nonexistent/path", alloc);
    try std.testing.expect(!has_sorbet);
}

test "P50 T50.8 workspaceHasSteep returns false for nonexistent path" {
    const alloc = std.testing.allocator;
    const has_steep = sorbet_bridge.workspaceHasSteep("/nonexistent/path", alloc);
    try std.testing.expect(!has_steep);
}

test "P50 T50.9 JSON LSP response parsing handles valid response" {
    const alloc = std.testing.allocator;
    const response =
        \\{
        \\  "result": {
        \\    "contents": "String"
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("result");
    try std.testing.expect(result != null);
}

test "P50 T50.10 JSON error response parsing" {
    const alloc = std.testing.allocator;
    const response =
        \\{
        \\  "error": {
        \\    "code": -32601,
        \\    "message": "Method not found"
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response, .{});
    defer parsed.deinit();

    const err = parsed.value.object.get("error");
    try std.testing.expect(err != null);
}
