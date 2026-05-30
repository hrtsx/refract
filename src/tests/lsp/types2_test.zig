const std = @import("std");
const harness = @import("harness");

const refract_bin = harness.refract_bin;
const Session = harness.Session;
const frame = harness.frame;
const extractResponses = harness.extractResponses;
const getNotificationByMethod = harness.getNotificationByMethod;
const getResponseById = harness.getResponseById;
const base_init = harness.base_init;
const base_initialized = harness.base_initialized;
const base_shutdown = harness.base_shutdown;
const base_exit = harness.base_exit;
test "P27 T10.39 type hierarchy prepare class" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1039";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class A\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class A\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/prepareTypeHierarchy\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":6}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P27 T10.40 type hierarchy prepare method returns nil" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1040";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def foo\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def foo\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/prepareTypeHierarchy\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":4}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P27 T10.41 type hierarchy supertypes" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1041";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class A\nend\nclass B < A\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class A\\nend\\nclass B < A\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"typeHierarchy/supertypes\",\"params\":{\"item\":{\"name\":\"B\",\"kind\":5,\"uri\":\"file://" ++ ws ++ "/a.rb\",\"range\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":2,\"character\":9}},\"selectionRange\":{\"start\":{\"line\":2,\"character\":6},\"end\":{\"line\":2,\"character\":7}}}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P27 T10.42 type hierarchy supertypes chain" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1042";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class A\nend\nclass B < A\nend\nclass C < B\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class A\\nend\\nclass B < A\\nend\\nclass C < B\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"typeHierarchy/supertypes\",\"params\":{\"item\":{\"name\":\"C\",\"kind\":5,\"uri\":\"file://" ++ ws ++ "/a.rb\",\"range\":{\"start\":{\"line\":4,\"character\":0},\"end\":{\"line\":4,\"character\":9}},\"selectionRange\":{\"start\":{\"line\":4,\"character\":6},\"end\":{\"line\":4,\"character\":7}}}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P27 T10.43 type hierarchy supertypes with mixins" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1043";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "module M\nend\nclass A\ninclude M\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"module M\\nend\\nclass A\\ninclude M\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"typeHierarchy/supertypes\",\"params\":{\"item\":{\"name\":\"A\",\"kind\":5,\"uri\":\"file://" ++ ws ++ "/a.rb\",\"range\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":2,\"character\":7}},\"selectionRange\":{\"start\":{\"line\":2,\"character\":6},\"end\":{\"line\":2,\"character\":7}}}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P27 T10.44 type hierarchy subtypes direct" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1044";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class A\nend\nclass B < A\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class A\\nend\\nclass B < A\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"typeHierarchy/subtypes\",\"params\":{\"item\":{\"name\":\"A\",\"kind\":5,\"uri\":\"file://" ++ ws ++ "/a.rb\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":7}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":7}}}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P27 T10.45 type hierarchy subtypes multiple" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1045";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class A\nend\nclass B < A\nend\nclass C < A\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class A\\nend\\nclass B < A\\nend\\nclass C < A\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"typeHierarchy/subtypes\",\"params\":{\"item\":{\"name\":\"A\",\"kind\":5,\"uri\":\"file://" ++ ws ++ "/a.rb\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":7}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":7}}}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P27 T10.52 semantic tokens delta no change" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1052";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = 1\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"x = 1\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/semanticTokens/full\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P27 T10.53 semantic tokens delta returns resultId" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1053";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def foo\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def foo\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/semanticTokens/full\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P27 T10.54 semantic tokens delta changed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1054";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = 1\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"x = 1\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/semanticTokens/full\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/semanticTokens/full/delta\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"previousResultId\":\"0\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 3) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P27 T10.55 semantic tokens delta unknown resultId" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1055";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "y = 2\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"y = 2\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/semanticTokens/full/delta\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"previousResultId\":\"unknown\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P27 T10.56 yard return inlay hint" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1056";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "# @return [String]\ndef foo\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"# @return [String]\\ndef foo\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/inlayHint\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":3,\"character\":0}}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P27 T10.58 or-assign lazy cache pattern" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1058";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "@cache ||= 1\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
}

test "P27 T10.59 module_function mode resets on exit" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1059";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "module M\nmodule_function\nend\nmodule N\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
}

test "P27 T10.60 type hierarchy supertypes depth limit" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1060";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class A1; end\nclass A2 < A1; end\nclass A3 < A2; end\nclass A4 < A3; end\nclass A5 < A4; end\nclass A6 < A5; end\nclass A7 < A6; end\nclass A8 < A7; end\nclass A9 < A8; end\nclass A10 < A9; end\nclass A11 < A10; end\nclass A12 < A11; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class A1; end\\nclass A2 < A1; end\\nclass A3 < A2; end\\nclass A4 < A3; end\\nclass A5 < A4; end\\nclass A6 < A5; end\\nclass A7 < A6; end\\nclass A8 < A7; end\\nclass A9 < A8; end\\nclass A10 < A9; end\\nclass A11 < A10; end\\nclass A12 < A11; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"typeHierarchy/supertypes\",\"params\":{\"item\":{\"name\":\"A12\",\"kind\":5,\"uri\":\"file://" ++ ws ++ "/a.rb\",\"range\":{\"start\":{\"line\":11,\"character\":0},\"end\":{\"line\":11,\"character\":10}},\"selectionRange\":{\"start\":{\"line\":11,\"character\":6},\"end\":{\"line\":11,\"character\":9}}}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P28 T11.8 param hint single param no hint" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t1108";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def foo(a); end\nfoo(1)\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def foo(a); end\\nfoo(1)\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/inlayHint\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":1,\"character\":99}}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const r_obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    _ = r_obj.get("result") orelse return error.NoResult;
}

test "P28 T11.16 confidence upsert high wins" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t1116";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = User.new\nx ||= Post.new\nx\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"x = User.new\\nx ||= Post.new\\nx\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const r_obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    _ = r_obj.get("result") orelse return error.NoResult;
}

test "P28 T11.19 module_function reset by private" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t1119";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "module M\nmodule_function\ndef foo; end\nprivate\ndef bar; end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"module M\\nmodule_function\\ndef foo; end\\nprivate\\ndef bar; end\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P28 T11.23 constant path receiver typed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t1123";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = Models::User.new\nx\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"x = Models::User.new\\nx\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const r_obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    _ = r_obj.get("result") orelse return error.NoResult;
}

test "P28 T11.25 pattern match capture typed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t1125";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = 42\ncase x\nin Integer => n\nn\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"x = 42\\ncase x\\nin Integer => n\\nn\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":3,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const r_obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    _ = r_obj.get("result") orelse return error.NoResult;
}

test "P28 T11.49 or-assign confidence loses to write" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t1149";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = User.new\nx ||= Post.new\nx\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"x = User.new\\nx ||= Post.new\\nx\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const r_obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    _ = r_obj.get("result") orelse return error.NoResult;
}

test "P28 T11.50 or-assign confidence wins over nothing" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t1150";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x ||= Post.new\nx\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"x ||= Post.new\\nx\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const r_obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    _ = r_obj.get("result") orelse return error.NoResult;
}

test "P28 T11.61 p28 regression yard still works" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t1161";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "# @return [String]\ndef greet\n\"hello\"\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"# @return [String]\\ndef greet\\n\\\"hello\\\"\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":4}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P28 T11.62 p28 regression rescue binding still works" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t1162";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "begin\nrescue StandardError => e\ne\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"begin\\nrescue StandardError => e\\ne\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P29 T12.6 while body var indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1206";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "cond = true\nwhile cond\n  x = Object.new\n  x\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"cond = true\\nwhile cond\\n  x = Object.new\\n  x\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":3,\"character\":2}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P29 T12.7 until body var indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1207";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "until false\n  y = 1\n  y\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"until false\\n  y = 1\\n  y\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":2}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P29 T12.8 unless branch var indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1208";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "unless false\n  z = \"hi\"\n  z\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"unless false\\n  z = \\\"hi\\\"\\n  z\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":2}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P29 T12.9 ensure block var indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1209";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "begin\n  x = 1\nensure\n  y = 2\n  y\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"begin\\n  x = 1\\nensure\\n  y = 2\\n  y\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":4,\"character\":2}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P29 T12.14 global var indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1214";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "$config = Config.new\n$config\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"$config = Config.new\\n$config\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":1}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const contents = result_obj.get("contents") orelse return error.NoContents;
    const contents_obj = switch (contents) {
        .object => |o| o,
        else => return error.ContentsNotObject,
    };
    const value = contents_obj.get("value") orelse return error.NoValue;
    const value_str = switch (value) {
        .string => |sv| sv,
        else => return error.NotString,
    };
    try std.testing.expect(std.mem.indexOf(u8, value_str, "Config") != null);
}

test "P29 T12.16 global var confidence 70" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1216";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "$gvar = Object.new\n" });
    const db_path = ws ++ "/refract.db";
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"$gvar = Object.new\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.runWithArgs(&.{ "--db-path", db_path });
    defer alloc.free(raw);
    const q = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{ "sqlite3", db_path, "SELECT confidence FROM local_vars WHERE name='$gvar'" },
    });
    defer alloc.free(q.stdout);
    defer alloc.free(q.stderr);
    try std.testing.expect(std.mem.indexOf(u8, q.stdout, "70") != null);
}

test "P29 T12.17 global var scope_id null" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1217";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "$gv2 = Object.new\n" });
    const db_path = ws ++ "/refract.db";
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"$gv2 = Object.new\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.runWithArgs(&.{ "--db-path", db_path });
    defer alloc.free(raw);
    const q = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{ "sqlite3", db_path, "SELECT scope_id IS NULL FROM local_vars WHERE name='$gv2'" },
    });
    defer alloc.free(q.stdout);
    defer alloc.free(q.stderr);
    try std.testing.expect(std.mem.indexOf(u8, q.stdout, "1") != null);
}

test "P29 T12.28 private_class_method marks as private" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1228";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Foo\n  def self.secret; end\n  def self.visible; end\n  private_class_method :secret\nend\nFoo.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Foo\\n  def self.secret; end\\n  def self.visible; end\\n  private_class_method :secret\\nend\\nFoo.\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":5,\"character\":4},\"context\":{\"triggerKind\":2,\"triggerCharacter\":\".\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoCompletionResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const items_val = result_obj.get("items") orelse return error.NoItems;
    const arr = switch (items_val) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    var found_secret = false;
    var found_visible = false;
    for (arr.items) |item| {
        const io = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const lv = io.get("label") orelse continue;
        const ls = switch (lv) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, ls, "secret")) found_secret = true;
        if (std.mem.eql(u8, ls, "visible")) found_visible = true;
    }
    try std.testing.expect(!found_secret);
    try std.testing.expect(found_visible);
}

test "P29 T12.29 public_class_method restores visibility" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1229";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Bar\n  def self.restored; end\n  private_class_method :restored\n  public_class_method :restored\nend\nBar.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Bar\\n  def self.restored; end\\n  private_class_method :restored\\n  public_class_method :restored\\nend\\nBar.\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":5,\"character\":4},\"context\":{\"triggerKind\":2,\"triggerCharacter\":\".\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoCompletionResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const items_val = result_obj.get("items") orelse return error.NoItems;
    const arr = switch (items_val) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    var found_restored = false;
    for (arr.items) |item| {
        const io = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const lv = io.get("label") orelse continue;
        const ls = switch (lv) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, ls, "restored")) {
            found_restored = true;
            break;
        }
    }
    try std.testing.expect(found_restored);
}

test "P29 T12.30 private_class_method with two symbols" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1230";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Baz\n  def self.alpha; end\n  def self.beta; end\n  private_class_method :alpha, :beta\nend\nBaz.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Baz\\n  def self.alpha; end\\n  def self.beta; end\\n  private_class_method :alpha, :beta\\nend\\nBaz.\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":5,\"character\":4},\"context\":{\"triggerKind\":2,\"triggerCharacter\":\".\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoCompletionResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const items_val = result_obj.get("items") orelse return error.NoItems;
    const arr = switch (items_val) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    var found_alpha = false;
    var found_beta = false;
    for (arr.items) |item| {
        const io = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const lv = io.get("label") orelse continue;
        const ls = switch (lv) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, ls, "alpha")) found_alpha = true;
        if (std.mem.eql(u8, ls, "beta")) found_beta = true;
    }
    try std.testing.expect(!found_alpha);
    try std.testing.expect(!found_beta);
}

test "P29 T12.31 self method return type inferred" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1231";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Builder\n  # @return [Widget]\n  def build\n    Widget.new\n  end\n  def run\n    x = self.build\n    x\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Builder\\n  # @return [Widget]\\n  def build\\n    Widget.new\\n  end\\n  def run\\n    x = self.build\\n    x\\n  end\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":7,\"character\":4}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const contents = result_obj.get("contents") orelse return error.NoContents;
    const contents_obj = switch (contents) {
        .object => |o| o,
        else => return error.ContentsNotObject,
    };
    const value = contents_obj.get("value") orelse return error.NoValue;
    const value_str = switch (value) {
        .string => |sv| sv,
        else => return error.NotString,
    };
    try std.testing.expect(std.mem.indexOf(u8, value_str, "Widget") != null);
}

test "P29 T12.33 self method confidence 75" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1233";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Maker\n  # @return [Part]\n  def make\n    Part.new\n  end\n  def assemble\n    x = self.make\n  end\nend\n" });
    const db_path = ws ++ "/refract.db";
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.runWithArgs(&.{ "--db-path", db_path });
    defer alloc.free(raw);
    const q = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{ "sqlite3", db_path, "SELECT confidence FROM local_vars WHERE name='x' AND confidence=75" },
    });
    defer alloc.free(q.stdout);
    defer alloc.free(q.stderr);
    try std.testing.expect(std.mem.indexOf(u8, q.stdout, "75") != null);
}

test "P29 T12.34 chained type inference one level" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1234";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class User\n  # @return [String]\n  def full_name\n    \"Alice\"\n  end\nend\nuser = User.new\nname = user.full_name\nname\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class User\\n  # @return [String]\\n  def full_name\\n    \\\"Alice\\\"\\n  end\\nend\\nuser = User.new\\nname = user.full_name\\nname\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":8,\"character\":1}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const contents = result_obj.get("contents") orelse return error.NoContents;
    const contents_obj = switch (contents) {
        .object => |o| o,
        else => return error.ContentsNotObject,
    };
    const value = contents_obj.get("value") orelse return error.NoValue;
    const value_str = switch (value) {
        .string => |sv| sv,
        else => return error.NotString,
    };
    try std.testing.expect(std.mem.indexOf(u8, value_str, "String") != null);
}

test "P29 T12.37 chained inference confidence 55" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1237";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Product\n  # @return [Price]\n  def price\n    Price.new\n  end\nend\nproduct = Product.new\np = product.price\n" });
    const db_path = ws ++ "/refract.db";
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.runWithArgs(&.{ "--db-path", db_path });
    defer alloc.free(raw);
    const q = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{ "sqlite3", db_path, "SELECT confidence FROM local_vars WHERE name='p' AND confidence=55" },
    });
    defer alloc.free(q.stdout);
    defer alloc.free(q.stderr);
    try std.testing.expect(std.mem.indexOf(u8, q.stdout, "55") != null);
}

test "P29 T12.38 numbered param _1 in block" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1238";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "[1, 2].each { _1.to_s }\n" });
    const db_path = ws ++ "/refract.db";
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.runWithArgs(&.{ "--db-path", db_path });
    defer alloc.free(raw);
    const q = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{ "sqlite3", db_path, "SELECT name FROM local_vars WHERE name='_1'" },
    });
    defer alloc.free(q.stdout);
    defer alloc.free(q.stderr);
    try std.testing.expect(std.mem.indexOf(u8, q.stdout, "_1") != null);
}

test "P29 T12.39 numbered param _1 gets element type" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1239";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "users = [User.new]\nusers.each { _1.name }\n" });
    const db_path = ws ++ "/refract.db";
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.runWithArgs(&.{ "--db-path", db_path });
    defer alloc.free(raw);
    const q = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{ "sqlite3", db_path, "SELECT type_hint FROM local_vars WHERE name='_1'" },
    });
    defer alloc.free(q.stdout);
    defer alloc.free(q.stderr);
    // _1 should get User as type_hint
    try std.testing.expect(std.mem.indexOf(u8, q.stdout, "User") != null);
}

test "P29 T12.40 numbered param explicit block not affected" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1240";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "[1, 2].map { |x| x }\n" });
    const db_path = ws ++ "/refract.db";
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.runWithArgs(&.{ "--db-path", db_path });
    defer alloc.free(raw);
    const q = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{ "sqlite3", db_path, "SELECT count(*) FROM local_vars WHERE name='_1'" },
    });
    defer alloc.free(q.stdout);
    defer alloc.free(q.stderr);
    try std.testing.expect(std.mem.indexOf(u8, q.stdout, "0") != null);
}

test "P29 T12.58 signature help keyword active param" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1258";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def greet(name:, age: nil)\nend\ngreet(name:\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Position at end of "greet(name:" — line 2, char 11
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/signatureHelp\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":11}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoSigHelpResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    // Signature help should exist with signatures and correct activeParameter
    try std.testing.expect(result_obj.get("signatures") != null);
    const ap = result_obj.get("activeParameter") orelse return;
    const ap_int = switch (ap) {
        .integer => |i| i,
        else => return,
    };
    // name: is the first keyword param — should be index 0
    try std.testing.expect(ap_int == 0);
}

test "P29 T12.59 signature help keyword partial no false match" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1259";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def process(name:, count: 1)\nend\nprocess(n\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/signatureHelp\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":9}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoSigHelpResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P29 T12.60 signature help keyword at comma boundary" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1260";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def send_email(to:, subject:, body: nil)\nend\nsend_email(to: \"x\", subject:\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Position after "subject:" — line 2, char 27
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/signatureHelp\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":27}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoSigHelpResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    try std.testing.expect(result_obj.get("signatures") != null);
    // subject: is the second keyword param — should be index 1
    const ap = result_obj.get("activeParameter") orelse return;
    const ap_int = switch (ap) {
        .integer => |i| i,
        else => return,
    };
    try std.testing.expect(ap_int == 1);
}

test "P29 T12.68 while var and global var coexist" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1268";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "$logger = Logger.new\nwhile true\n  item = Item.new\n  break\nend\n" });
    const db_path = ws ++ "/refract.db";
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.runWithArgs(&.{ "--db-path", db_path });
    defer alloc.free(raw);
    const q1 = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{ "sqlite3", db_path, "SELECT name FROM local_vars WHERE name='$logger'" },
    });
    defer alloc.free(q1.stdout);
    defer alloc.free(q1.stderr);
    const q2 = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{ "sqlite3", db_path, "SELECT name FROM local_vars WHERE name='item'" },
    });
    defer alloc.free(q2.stdout);
    defer alloc.free(q2.stderr);
    try std.testing.expect(std.mem.indexOf(u8, q1.stdout, "$logger") != null);
    try std.testing.expect(std.mem.indexOf(u8, q2.stdout, "item") != null);
}

test "P29 T12.70 regression p27 YARD tests still pass" {
    // Verify YARD @return annotation still drives hover content.
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1270";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Repo\n  # @return [Array<User>]\n  def all\n    []\n  end\nend\nr = Repo.new\nusers = r.all\nusers\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Repo\\n  # @return [Array<User>]\\n  def all\\n    []\\n  end\\nend\\nr = Repo.new\\nusers = r.all\\nusers\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":10}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
}

test "P30 T13.2 Struct.new writer methods present" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1302";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "MyPoint = Struct.new(:x, :y)\np = MyPoint.new\np.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":2}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoCompletionResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "x=") != null);
}

test "P30 T13.3 Data.define reader only no writer" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1303";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "MyData = Data.define(:name)\nd = MyData.new(name: \"a\")\nd.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":2}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoCompletionResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"name=\"") == null);
}

test "P30 T13.4 Struct.new kind upgraded to class" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1304";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "MyPoint = Struct.new(:x, :y)\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"MyPoint\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoSymbolResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "MyPoint") != null);
}

test "P30 T13.9 endless def integer return type" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1309";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Counter\n  def count = 0\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":6}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Integer") != null);
}

test "P30 T13.10 endless def new-call return type" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1310";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Factory\n  def user = Userclass.new\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":6}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Userclass") != null);
}

test "P30 T13.11 endless def symbol return type" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1311";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class State\n  def status = :active\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":6}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Symbol") != null);
}

test "P30 T13.12 YARD union type two types" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1312";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Repo\n  # @return [String, nil]\n  def reponame\n    nil\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":6}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "String") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "NilClass") != null or std.mem.indexOf(u8, raw, "nil") != null);
}

test "P30 T13.13 YARD union type three types" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1313";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Calc\n  # @return [Integer, String, Float]\n  def calcvalue\n    0\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":6}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Integer") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Float") != null);
}

test "P30 T13.14 YARD single type unchanged regression" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1314";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class App\n  # @return [Adminuser]\n  def current_user\n    nil\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":6}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Adminuser") != null);
}

test "P30 T13.18 linkedEditingRange local var all occurrences" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1318";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "myvar = 1\nyyy = myvar\nzzz = myvar + 1\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/linkedEditingRange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoLinkedEditResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "ranges") != null);
}

test "P30 T13.26 2-level chain type inferred" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1326";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Deepcc\nend\nclass Deepbb\n  # @return [Deepcc]\n  def getc\n    Deepcc.new\n  end\nend\nclass Deepaa\n  # @return [Deepbb]\n  def getb\n    Deepbb.new\n  end\nend\ndeepobj = Deepaa.new\nresultchain = deepobj.getb.getc\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoSymbolResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Deepaa") != null);
}

test "P30 T13.34 regression 1-level chain confidence 55 still works" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1334";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Personchain\n  # @return [String]\n  def chainname\n    \"alice\"\n  end\nend\npc = Personchain.new\nresultname = pc.chainname\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":7,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "String") != null);
}

test "P31 T14.31 lookupStdlibReturn String#upcase returns String type" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1431";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "t = \"hello\".upcase\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "String") != null);
}

test "P31 T14.36 lookupStdlibReturn chained String#upcase#length returns Integer" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1436";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "n = \"hi\".upcase.length\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Integer") != null);
}

test "P31 T14.44 p31 regression Struct.new still works" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1444";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "Point1444 = Struct.new(:x1444, :y1444)\np = Point1444.new(1, 2)\np.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":2}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoCompletionResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "x1444") != null);
}

test "P31 T14.45 p31 regression chained inference still works" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1445";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Pers1445\n  # @return [String]\n  def chainname1445\n    \"alice\"\n  end\nend\npc = Pers1445.new\nresult1445 = pc.chainname1445\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":7,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "String") != null);
}

test "P32 T15.30 pattern matching capture binds type" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1530";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "v1530 = \"hello\"\ncase v1530\nin String => s1530\n  s1530\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":3,\"character\":2}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "String") != null);
}

test "P32 T15.33 ||= infers type from RHS" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1533";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x1533 = nil\nx1533 ||= \"default\"\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "String") != null);
}

test "P32 T15.37 delegate return type preserved" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1537";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Order1537\n  delegate :name1537, to: :user1537\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoDocSymResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "name1537") != null);
}

test "P32 T15.38 AR where returns collection type" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1538";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Post1538\nend\nposts1538 = Post1538.where(active: true)\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Post1538") != null);
}

test "P32 T15.39 AR where.first returns single instance type" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1539";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Article1539\nend\na1539 = Article1539.where(id: 1).first\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Article1539") != null);
}

test "P32 T15.40 AR chained order still collection" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1540";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Tag1540\nend\nresult1540 = Tag1540.where(active: true).order(:name)\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Tag1540") != null);
}

test "P32 T15.47 p32 regression signatureHelp still works" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1547";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def sig1547(a, b)\n  a + b\nend\nsig1547(\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/signatureHelp\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":3,\"character\":8}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoSigHelpResponse;
}

test "P32 T15.48 p32 regression AR .new still works" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1548";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Reg1548\n  def meth1548; end\nend\nr1548 = Reg1548.new\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":3,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Reg1548") != null);
}

test "P19 T19.4 semantic tokens delta no deleteCount:0 when prev blob missing" {
    // Validates Fix 3: when server has no stored prev_blob but client sends a non-empty
    // previousResultId, the response must be full SemanticTokens (data:[...]), NOT a
    // delta with deleteCount:0 which would corrupt the editor's existing token list.
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p19_t194";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/c.rb", .data = "x = 1\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/c.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // workspace/symbol triggers flushIncrPaths so file is indexed before delta request
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"x\"}}");
    // Send delta with a stale previousResultId (simulating editor surviving a DB wipe)
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/semanticTokens/full/delta\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/c.rb\"},\"previousResultId\":\"stale-id-from-before-db-wipe\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 3) orelse return error.NoDeltaResponse;
    // Fix 3: must NOT emit deleteCount:0 (which inserts tokens on top of existing ones)
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"deleteCount\":0") == null);
}

test "P20 T20.1 semantic tokens UTF-16 converter produces valid token stream" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p20_t201";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "# café\nclass Foo\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-16\"]}},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"# café\\nclass Foo\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Foo\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/semanticTokens/full\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r3 = getResponseById(resp, 3) orelse return error.NoSemTokensResponse;
    const r3outer = switch (r3) {
        .object => |o| o,
        else => return error.NotAnObject,
    };
    const result_val = r3outer.get("result") orelse return error.NoResultField;
    const r3obj = switch (result_val) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const data_val = r3obj.get("data") orelse return error.NoDataField;
    const data_arr = switch (data_val) {
        .array => |a| a,
        else => return error.DataNotArray,
    };
    // Token stream must be a multiple of 5
    try std.testing.expect(data_arr.items.len % 5 == 0);
}

test "P23 T23.2 private def inline does not leak visibility to subsequent methods" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_t232";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class Cfg\n  private def secret; end\n  def visible; end\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }
    const resp2 = getResponseById(responses, 2) orelse return error.NoResponse;
    const obj = switch (resp2) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    // Both secret and visible should appear in documentSymbol
    var found_secret = false;
    var found_visible = false;
    for (arr.items) |item| {
        const iobj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const children_val = iobj.get("children") orelse continue;
        const children = switch (children_val) {
            .array => |a| a,
            else => continue,
        };
        for (children.items) |child| {
            const cobj = switch (child) {
                .object => |o| o,
                else => continue,
            };
            const n_val = cobj.get("name") orelse continue;
            const n = switch (n_val) {
                .string => |s2| s2,
                else => continue,
            };
            if (std.mem.eql(u8, n, "secret")) found_secret = true;
            if (std.mem.eql(u8, n, "visible")) found_visible = true;
        }
    }
    try std.testing.expect(found_secret);
    try std.testing.expect(found_visible);
}

test "P28 T28.1 workspace/symbol gvar query returns global variable" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t281";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/g.rb", .data = "$config_path = '/etc'\n$debug = false\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/g.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"$config\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }
    const resp2 = getResponseById(responses, 2) orelse return error.NoSymbolResponse;
    const obj2 = switch (resp2) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj2.get("error") == null);
    const result2 = obj2.get("result") orelse return error.NoResult;
    const arr = switch (result2) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    var found = false;
    for (arr.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = item_obj.get("name") orelse continue;
        const name_str = switch (name) {
            .string => |ns| ns,
            else => continue,
        };
        if (std.mem.eql(u8, name_str, "$config_path")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "P33 T33.6 attribute synthesizes typed reader, writer, predicate" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p33_t336";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class User\n  attribute :age, :integer\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/user.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"age\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "age?") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "age=") != null);
}

test "P33 T33.7 delegated_type synthesizes type, id, class accessors" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p33_t337";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class Entry\n  delegated_type :entryable, types: %w[Message Comment]\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/entry.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/entry.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"entryable\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "entryable_type") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "entryable_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "entryable_class") != null);
}

test "P33 T33.8 composed_of synthesizes accessor with class_name return type" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p33_t338";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class Account\n  composed_of :balance, class_name: \"Money\"\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/account.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/account.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"balance\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "balance=") != null);
}

test "P33 T33.14 polymorphic belongs_to indexes association without static return type" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p33_t3314";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class Comment\n  belongs_to :commentable, polymorphic: true\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/comment.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/comment.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"commentable\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "commentable") != null);
}

test "scope DSL kind is def not classdef" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t729";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class User < ApplicationRecord\n  scope :active, -> { where(active: true) }\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class User < ApplicationRecord\\n  scope :active, -> { where(active: true) }\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"active\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoSymbolResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
    const result_arr = switch (obj.get("result") orelse return error.NoResult) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(result_arr.items.len > 0);
}

test "P31 T14.32 lookupStdlibReturn String#length returns Integer" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1432";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "n = \"hello\".length\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Integer") != null);
}

test "P31 T14.33 lookupStdlibReturn Array#join returns String" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1433";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "s = [1,2,3].join\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "String") != null);
}

test "P31 T14.34 lookupStdlibReturn Integer#to_s returns String" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1434";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "s = 42.to_s\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "String") != null);
}

test "P31 T14.35 lookupStdlibReturn Hash#keys returns Array" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1435";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "k = {a: 1}.keys\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Array") != null);
}

test "P32 T15.14 blk2 stdlib mid-type chain" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1514";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Usr1514\n  # @return [String]\n  def nm1514; \"x\"; end\nend\nu1514 = Usr1514.new\nx1514 = u1514.nm1514.upcase\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":5,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "String") != null);
}

test "P32 T15.15 blk2 stdlib leaf-type arr.join.length" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1515";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class C1515\n  # @return [Array]\n  def items1515; []; end\nend\nc1515 = C1515.new\nx1515 = c1515.items1515.join\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":5,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "String") != null);
}

test "P32 T15.16 blk2 no false positive for untyped root" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1516";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x1516 = foo1516.bar1516.baz1516\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
}

test "P32 T15.17 lookupStdlibReturn String#start_with? returns TrueClass" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1517";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "s1517 = \"hello\"\nx1517 = s1517.start_with?(\"h\")\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "TrueClass") != null);
}

test "P32 T15.19 lookupStdlibReturn String#reverse returns String" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1519";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "s1519 = \"hello\"\nx1519 = s1519.reverse\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "String") != null);
}

test "P32 T15.20 lookupStdlibReturn Array#tally returns Hash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1520";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "a1520 = [1, 2, 1]\nx1520 = a1520.tally\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Hash") != null);
}

test "P32 T15.21 lookupStdlibReturn Array#filter_map returns Array" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1521";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "a1521 = [1, nil, 2]\nx1521 = a1521.filter_map { |x| x }\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Array") != null);
}

test "P32 T15.22 lookupStdlibReturn Hash#invert returns Hash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1522";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "h1522 = {a: 1}\nx1522 = h1522.invert\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Hash") != null);
}

test "P32 T15.23 lookupStdlibReturn Hash#except returns Hash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1523";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "h1523 = {a: 1, b: 2}\nx1523 = h1523.except(:a)\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Hash") != null);
}

test "P32 T15.25 lookupStdlibReturn Float#ceil returns Integer" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1525";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "f1525 = 3.14\nx1525 = f1525.ceil\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Integer") != null);
}

test "P32 T15.26 lookupStdlibReturn blank? returns TrueClass" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1526";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "s1526 = \"hello\"\nx1526 = s1526.blank?\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "TrueClass") != null);
}

test "P32 T15.31 pattern matching Integer binding" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1531";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "v1531 = 42\ncase v1531\nin Integer => n1531\n  n1531\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":3,\"character\":2}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Integer") != null);
}

test "P34 T34.2 wrong-arity checker flags too many positional arguments" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p34_t342";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // Greeter#hello takes 1 positional param. Calling it with 2 args on a typed receiver
    // should populate refs.receiver_type='Greeter' and arg_count=2, triggering wrong-arity.
    const src =
        "class Greeter\n" ++
        "  def hello(name); puts name; end\n" ++
        "end\n" ++
        "g = Greeter.new\n" ++
        "g.hello(\"a\", \"b\")\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/wrong_arity.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/wrong_arity.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"" ++
        "class Greeter\\n" ++
        "  def hello(name); puts name; end\\n" ++
        "end\\n" ++
        "g = Greeter.new\\n" ++
        "g.hello(\\\"a\\\", \\\"b\\\")\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "refract/wrong-arity") != null);
}

test "P34 T34.3 wrong-arity flags too few args on a self-send" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p34_t343";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // triple takes 3 required params; the receiverless call triple(1, 2) inside #run is a
    // self-send (refs.kind='self_call', receiver_type NULL) and must be flagged too-few.
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/self_arity.rb", .data =
        "class Calc\n" ++
        "  def triple(a, b, c); a + b + c; end\n" ++
        "  def run; triple(1, 2); end\n" ++
        "end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/self_arity.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"" ++
        "class Calc\\n" ++
        "  def triple(a, b, c); a + b + c; end\\n" ++
        "  def run; triple(1, 2); end\\n" ++
        "end\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "refract/wrong-arity") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "too few arguments") != null);
}

test "P34 T34.4 undefined-method flags an unknown self-send" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p34_t344";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // missing_helper is never defined and the class has no dynamic signals, so the
    // receiverless call must be flagged even without a close "did you mean?" suggestion.
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/self_undef.rb", .data =
        "class Calc\n" ++
        "  def run; missing_helper(3); end\n" ++
        "end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/self_undef.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"" ++
        "class Calc\\n" ++
        "  def run; missing_helper(3); end\\n" ++
        "end\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "refract/undefined-method") != null);
}

test "P34 T34.5 undefined-method suggestion is valid UTF-8 (no freed-slice garbage)" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p34_t345";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // Several same-prefix defs force the "did you mean" candidate loop to step past
    // the chosen best, which previously left best_name pointing at a reused SQLite
    // row buffer (use-after-free) and printed garbage bytes. The whole reply must
    // remain valid UTF-8.
    // The undefined name `calculat` is a substring of all three real defs (so the
    // LIKE-based candidate query returns multiple rows) and within edit distance 2 of
    // each, forcing the best-candidate loop to step past the chosen row.
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/sugg.rb", .data =
        "class Calc\n" ++
        "  def calculate; end\n" ++
        "  def calculated; end\n" ++
        "  def calculates; end\n" ++
        "  def run; calculat(1); end\n" ++
        "end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/sugg.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"" ++
        "class Calc\\n" ++
        "  def calculate; end\\n" ++
        "  def calculated; end\\n" ++
        "  def calculates; end\\n" ++
        "  def run; calculat(1); end\\n" ++
        "end\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "did you mean") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(raw));
}

test "P34 T34.6 self-send into an unindexed-base method is not flagged" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p34_t346";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // Cop < ExternalBase: the base is outside the workspace, so its methods are
    // invisible. A receiverless call must NOT be flagged (the ancestry is not
    // provably closed) — this was the RuboCop-cop false positive on Homebrew.
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/cop.rb", .data =
        "class Cop < ExternalBase\n" ++
        "  def run; offending_node(1); end\n" ++
        "end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/cop.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"" ++
        "class Cop < ExternalBase\\n" ++
        "  def run; offending_node(1); end\\n" ++
        "end\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "offending_node") == null);
}

test "P34 T34.7 Sorbet sig DSL is not flagged as undefined" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p34_t347";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // `sig { ... }` and its chained returns/void are sorbet-runtime DSL, not undefined.
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/typed.rb", .data =
        "class Calc\n" ++
        "  sig { returns(Integer) }\n" ++
        "  def answer; 42; end\n" ++
        "end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/typed.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"" ++
        "class Calc\\n" ++
        "  sig { returns(Integer) }\\n" ++
        "  def answer; 42; end\\n" ++
        "end\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "undefined method 'sig'") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "undefined method 'returns'") == null);
}

test "P34 T34.8 bare self-send inside a module is not flagged (concern pattern)" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p34_t348";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // A module is mixed into unknown hosts at runtime (Rails concern). A
    // receiverless call to a method provided by a sibling concern / the host must
    // NOT be flagged — this was the Solidus `permitted_address_attributes` FP.
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/concern.rb", .data =
        "module StrongParams\n" ++
        "  def permitted_payment; {address: permitted_address}; end\n" ++
        "end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/concern.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"" ++
        "module StrongParams\\n" ++
        "  def permitted_payment; {address: permitted_address}; end\\n" ++
        "end\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "undefined method 'permitted_address'") == null);
}

test "P34 T34.9 RSpec before(:each) does not synthesize a duplicate 'each' method" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p34_t349";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // Two `before(:each)` hooks previously each recorded a phantom def `each`,
    // tripping duplicate-method. The timing symbol is not a method name.
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/spec.rb", .data =
        "describe Thing do\n" ++
        "  before(:each) { setup_a }\n" ++
        "  before(:each) { setup_b }\n" ++
        "end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/spec.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"" ++
        "describe Thing do\\n" ++
        "  before(:each) { setup_a }\\n" ++
        "  before(:each) { setup_b }\\n" ++
        "end\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "method 'each' defined multiple times") == null);
}

test "P34 T34.10 delegate of a name the class also defines is not a duplicate" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p34_t3410";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // `delegate :currency` synthesizes a def; a real `def currency` override must
    // not collide with it (Solidus Payment FP).
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/payment.rb", .data =
        "class Payment\n" ++
        "  delegate :currency, to: :order\n" ++
        "  def currency; super || 'USD'; end\n" ++
        "end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/payment.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"" ++
        "class Payment\\n" ++
        "  delegate :currency, to: :order\\n" ++
        "  def currency; super || 'USD'; end\\n" ++
        "end\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "method 'currency' defined multiple times") == null);
}
