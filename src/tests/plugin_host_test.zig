const std = @import("std");
const plugin_host = @import("../lsp/plugin_host.zig");

test "P49 T49.1 validateManifest rejects empty id" {
    try std.testing.expectError(
        plugin_host.ManifestValidationError.EmptyId,
        plugin_host.validateManifest(.{
            .id = "",
            .version = "1.0.0",
            .entry = "/bin/plugin",
            .lsp_requests = &.{},
            .lsp_notifications = &.{},
            .mcp_tools = &.{},
            .initialize_ms = 5000,
            .request_ms = 2000,
            .shutdown_ms = 1000,
            .allow_network = false,
            .allow_fs_write = &.{},
        }),
    );
}

test "P49 T49.2 validateManifest rejects invalid id chars" {
    try std.testing.expectError(
        plugin_host.ManifestValidationError.InvalidIdChars,
        plugin_host.validateManifest(.{
            .id = "test@plugin",
            .version = "1.0.0",
            .entry = "/bin/plugin",
            .lsp_requests = &.{},
            .lsp_notifications = &.{},
            .mcp_tools = &.{},
            .initialize_ms = 5000,
            .request_ms = 2000,
            .shutdown_ms = 1000,
            .allow_network = false,
            .allow_fs_write = &.{},
        }),
    );
}

test "P49 T49.3 validateManifest rejects empty version" {
    try std.testing.expectError(
        plugin_host.ManifestValidationError.EmptyVersion,
        plugin_host.validateManifest(.{
            .id = "test-plugin",
            .version = "",
            .entry = "/bin/plugin",
            .lsp_requests = &.{},
            .lsp_notifications = &.{},
            .mcp_tools = &.{},
            .initialize_ms = 5000,
            .request_ms = 2000,
            .shutdown_ms = 1000,
            .allow_network = false,
            .allow_fs_write = &.{},
        }),
    );
}

test "P49 T49.4 validateManifest rejects empty entry" {
    try std.testing.expectError(
        plugin_host.ManifestValidationError.EmptyEntry,
        plugin_host.validateManifest(.{
            .id = "test-plugin",
            .version = "1.0.0",
            .entry = "",
            .lsp_requests = &.{},
            .lsp_notifications = &.{},
            .mcp_tools = &.{},
            .initialize_ms = 5000,
            .request_ms = 2000,
            .shutdown_ms = 1000,
            .allow_network = false,
            .allow_fs_write = &.{},
        }),
    );
}

test "P49 T49.5 validateManifest rejects reserved lsp_requests" {
    try std.testing.expectError(
        plugin_host.ManifestValidationError.ReservedMethod,
        plugin_host.validateManifest(.{
            .id = "test-plugin",
            .version = "1.0.0",
            .entry = "/bin/plugin",
            .lsp_requests = &.{"initialize"},
            .lsp_notifications = &.{},
            .mcp_tools = &.{},
            .initialize_ms = 5000,
            .request_ms = 2000,
            .shutdown_ms = 1000,
            .allow_network = false,
            .allow_fs_write = &.{},
        }),
    );
}

test "P49 T49.6 validateManifest rejects methods without namespace" {
    try std.testing.expectError(
        plugin_host.ManifestValidationError.InvalidNamespace,
        plugin_host.validateManifest(.{
            .id = "test-plugin",
            .version = "1.0.0",
            .entry = "/bin/plugin",
            .lsp_requests = &.{"customMethod"},
            .lsp_notifications = &.{},
            .mcp_tools = &.{},
            .initialize_ms = 5000,
            .request_ms = 2000,
            .shutdown_ms = 1000,
            .allow_network = false,
            .allow_fs_write = &.{},
        }),
    );
}

test "P49 T49.7 validateManifest accepts refract-namespaced methods" {
    const alloc = std.testing.allocator;
    var requests = try alloc.alloc([]const u8, 1);
    defer alloc.free(requests);
    requests[0] = "refract.test-plugin.customMethod";

    try plugin_host.validateManifest(.{
        .id = "test-plugin",
        .version = "1.0.0",
        .entry = "/bin/plugin",
        .lsp_requests = requests,
        .lsp_notifications = &.{},
        .mcp_tools = &.{},
        .initialize_ms = 5000,
        .request_ms = 2000,
        .shutdown_ms = 1000,
        .allow_network = false,
        .allow_fs_write = &.{},
    });
}

test "P49 T49.8 validateManifest accepts experimental-namespaced methods" {
    const alloc = std.testing.allocator;
    var notifs = try alloc.alloc([]const u8, 1);
    defer alloc.free(notifs);
    notifs[0] = "experimental.test-plugin.customNotif";

    try plugin_host.validateManifest(.{
        .id = "test-plugin",
        .version = "1.0.0",
        .entry = "/bin/plugin",
        .lsp_requests = &.{},
        .lsp_notifications = notifs,
        .mcp_tools = &.{},
        .initialize_ms = 5000,
        .request_ms = 2000,
        .shutdown_ms = 1000,
        .allow_network = false,
        .allow_fs_write = &.{},
    });
}

test "P49 T49.9 parseManifest parses valid JSON" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "id": "test-plugin",
        \\  "version": "1.0.0",
        \\  "entry": "/bin/test-plugin",
        \\  "description": "Test plugin",
        \\  "capabilities": {
        \\    "lsp_requests": ["refract.test-plugin.custom"],
        \\    "mcp_tools": ["test_tool"]
        \\  },
        \\  "timeouts": {
        \\    "initialize_ms": 3000
        \\  },
        \\  "sandbox": {
        \\    "allow_network": true,
        \\    "allow_fs_write": ["/tmp"]
        \\  }
        \\}
    ;

    var manifest = try plugin_host.parseManifest(alloc, json);
    defer manifest.deinit(alloc);

    try std.testing.expectEqualSlices(u8, manifest.id, "test-plugin");
    try std.testing.expectEqualSlices(u8, manifest.version, "1.0.0");
    try std.testing.expectEqual(@as(u32, 3000), manifest.initialize_ms);
    try std.testing.expectEqual(true, manifest.allow_network);
    try std.testing.expectEqual(@as(usize, 1), manifest.mcp_tools.len);
}

test "P49 T49.10 parseManifest rejects malformed JSON" {
    const alloc = std.testing.allocator;
    const json = "{invalid json";

    try std.testing.expectError(
        error.Unexpected,
        plugin_host.parseManifest(alloc, json),
    );
}

test "P49 T49.11 parseManifest handles missing optional fields" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "id": "simple-plugin",
        \\  "version": "0.1.0",
        \\  "entry": "/bin/plugin",
        \\  "capabilities": {}
        \\}
    ;

    var manifest = try plugin_host.parseManifest(alloc, json);
    defer manifest.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), manifest.lsp_requests.len);
    try std.testing.expectEqual(@as(usize, 0), manifest.lsp_notifications.len);
    try std.testing.expectEqual(@as(usize, 0), manifest.mcp_tools.len);
    try std.testing.expectEqual(false, manifest.allow_network);
    try std.testing.expectEqual(@as(u32, 5000), manifest.initialize_ms);
}

test "P49 T49.12 validateManifest with mcp_tools succeeds" {
    const alloc = std.testing.allocator;
    var mcp_tools = try alloc.alloc([]const u8, 1);
    defer alloc.free(mcp_tools);
    mcp_tools[0] = "refract.test-plugin.analyze";

    try plugin_host.validateManifest(.{
        .id = "test-plugin",
        .version = "1.0.0",
        .entry = "/bin/plugin",
        .lsp_requests = &.{},
        .lsp_notifications = &.{},
        .mcp_tools = &.{},
        .initialize_ms = 5000,
        .request_ms = 2000,
        .shutdown_ms = 1000,
        .allow_network = false,
        .allow_fs_write = &.{},
    });
}
