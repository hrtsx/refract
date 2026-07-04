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

test "hover returns markdown" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_hover";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/hover_test.rb",
        .data = "class HoverTarget; end\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/hover_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/hover_test.rb\"},\"position\":{\"line\":0,\"character\":6}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoHoverResponse;
    const obj = switch (resp) {
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
    const kind = contents_obj.get("kind") orelse return error.NoKind;
    const kind_str = switch (kind) {
        .string => |ks| ks,
        else => return error.KindNotString,
    };
    try std.testing.expectEqualStrings("markdown", kind_str);
}

test "hover shows return type for def" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_rettype";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/return_type_test.rb",
        .data = "def greet\n  \"hello\"\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/return_type_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/return_type_test.rb\"},\"position\":{\"line\":0,\"character\":4}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoHoverResponse;
    const obj = switch (resp) {
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
        .string => |vs| vs,
        else => return error.ValueNotString,
    };
    try std.testing.expect(std.mem.indexOf(u8, value_str, "String") != null);
}

test "hover shows local var type" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_hovlv";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/hover_lv.rb",
        .data = "x = Dog.new\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/hover_lv.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/hover_lv.rb\"},\"position\":{\"line\":0,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoHoverResponse;
    const obj = switch (resp) {
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
        else => return error.NotObject,
    };
    const value = contents_obj.get("value") orelse return error.NoValue;
    const value_str = switch (value) {
        .string => |sv| sv,
        else => return error.NotString,
    };
    try std.testing.expect(std.mem.indexOf(u8, value_str, "Dog") != null);
}

test "hover on non-assignment line returns local var type" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_hovnonas";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/hover_nonassign.rb",
        .data = "x = Dog.new\nputs x\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/hover_nonassign.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/hover_nonassign.rb\"},\"position\":{\"line\":1,\"character\":5}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoHoverResponse;
    const obj = switch (resp) {
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
        .string => |vs| vs,
        else => return error.ValueNotString,
    };
    try std.testing.expect(std.mem.indexOf(u8, value_str, "Dog") != null);
}

test "hover shows doc comment" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_doc";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/doc_hover_test.rb",
        .data = "# Say hello\ndef greet\n  \"hello\"\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/doc_hover_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/doc_hover_test.rb\"},\"position\":{\"line\":1,\"character\":4}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoHoverResponse;
    const obj = switch (resp) {
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
        else => return error.ValueNotString,
    };
    try std.testing.expect(std.mem.indexOf(u8, value_str, "Say hello") != null);
}

test "def self.method shows 'def self' in hover" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_cdef";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/classdef_hover_test.rb",
        .data = "class Foo\n  def self.build\n    new\n  end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/classdef_hover_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/classdef_hover_test.rb\"},\"position\":{\"line\":1,\"character\":12}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoHoverResponse;
    const obj = switch (resp) {
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
        .string => |vs| vs,
        else => return error.ValueNotString,
    };
    try std.testing.expect(std.mem.indexOf(u8, value_str, "def self") != null);
}

test "hover on qualified name" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_qhover";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/qhover.rb",
        .data = "class Foo::Bar\nend\nFoo::Bar\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/qhover.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/qhover.rb\"},\"position\":{\"line\":2,\"character\":5}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const hover_resp = getResponseById(responses, 2) orelse return error.NoHoverResponse;
    const obj = switch (hover_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    try std.testing.expect(result != .null);
}

test "didChange reindexes hover shows new type" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t740";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def foo\n  x = 1\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def foo\\n  x = 1\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"version\":2},\"contentChanges\":[{\"text\":\"def foo\\n  x = \\\"hello\\\"\\nend\\n\"}]}}");
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
    const r = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P27 T10.62 yard param hover shows type" {
    var h = try harness.probe(std.testing.allocator, .{
        .source = "# @param count [Integer]\ndef run(count)\ncount\nend\n",
        .method = "textDocument/hover",
        .line = 2,
        .character = 0,
        .open = .overlay,
    });
    defer h.deinit();
    const r = h.response(2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P28 T11.29 hover union type two branches" {
    var h = try harness.probe(std.testing.allocator, .{
        .source = "if true\nx = User.new\nelse\nx = Post.new\nend\nx\n",
        .method = "textDocument/hover",
        .line = 5,
        .character = 0,
        .open = .overlay,
    });
    defer h.deinit();
    const r = h.response(2) orelse return error.NoResponse;
    const r_obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    _ = r_obj.get("result") orelse return error.NoResult;
}

test "P28 T11.30 hover single type no pipe" {
    var h = try harness.probe(std.testing.allocator, .{
        .source = "x = User.new\nx\n",
        .method = "textDocument/hover",
        .line = 1,
        .character = 0,
        .open = .overlay,
    });
    defer h.deinit();
    const r = h.response(2) orelse return error.NoResponse;
    const r_obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    _ = r_obj.get("result") orelse return error.NoResult;
}

test "P31 T14.40 p31 regression hover still works" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1440";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class RegClass1440\n  def regmethod\n    42\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":6}}}");
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

test "P32 T15.28 @type annotation hover shows annotated type" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1528";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "# @type [Float]\ny1528 = 42\n" });
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "Float") != null);
}

test "P32 T15.44 p32 regression hover still works" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1544";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Smoke1544\n  def hello1544; end\nend\ns1544 = Smoke1544.new\n" });
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "Smoke1544") != null);
}

test "T_UTF8_IDENT non-ASCII identifier hover does not crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tutf8";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/utf8.rb", .data = "def caf\xc3\xa9; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/utf8.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/utf8.rb\"},\"position\":{\"line\":0,\"character\":7}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const hover_resp = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    const hover_obj = switch (hover_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(hover_obj.get("result") != null);
}

test "P20 T20.4 hover response includes range field" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p20_t204";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/d.rb", .data = "class Util\n  def self.parse(x); x; end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/d.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Util\\n  def self.parse(x); x; end\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/d.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"parse\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/d.rb\"},\"position\":{\"line\":1,\"character\":13}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r3 = getResponseById(resp, 3) orelse return error.NoHoverResponse;
    const r3outer = switch (r3) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const r3result = r3outer.get("result") orelse .null;
    switch (r3result) {
        .null => {},
        .object => |obj| {
            const range_val = obj.get("range") orelse return error.NoRangeInHover;
            const range_obj = switch (range_val) {
                .object => |o| o,
                else => return error.RangeNotObj,
            };
            const start_val = range_obj.get("start") orelse return error.NoStart;
            const start_obj = switch (start_val) {
                .object => |o| o,
                else => return error.StartNotObj,
            };
            const start_line = switch (start_obj.get("line") orelse return error.NoLine) {
                .integer => |i| i,
                else => return error.LineNotInt,
            };
            try std.testing.expect(start_line == 1);
        },
        else => return error.UnexpectedHoverType,
    }
}

test "P22 T22.6 hover on class shows superclass" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_t226";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class Animal; end\nclass Dog < Animal\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/dog.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/dog.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/dog.rb\"},\"position\":{\"line\":1,\"character\":7}}}");
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
    const value = switch (contents_obj.get("value") orelse return error.NoValue) {
        .string => |s2| s2,
        else => return error.ValueNotString,
    };
    try std.testing.expect(std.mem.indexOf(u8, value, "Animal") != null);
}

test "P22 T22.7 hover on class shows included module" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_t227";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "module Walkable; end\nclass Dog\n  include Walkable\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/dog.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/dog.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/dog.rb\"},\"position\":{\"line\":1,\"character\":7}}}");
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
    const value = switch (contents_obj.get("value") orelse return error.NoValue) {
        .string => |s2| s2,
        else => return error.ValueNotString,
    };
    try std.testing.expect(std.mem.indexOf(u8, value, "Walkable") != null);
}

test "P24 T24.1 ivar or-write indexed for hover and workspace symbol" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t241";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class Cache\n  def fetch\n    @result ||= expensive\n    @result\n  end\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":3,\"character\":5}}}");
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
    // @result should be found (hover returns a result, not null)
    try std.testing.expect(obj.get("result") != null);
}

test "P24 T24.5 hover on whitespace returns empty result not crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t245";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class Foo\n  \n  def bar; end\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Hover on line 1 (blank line with only spaces)
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":0}}}");
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
    // Must not have an error field; result may be null (empty hover)
    try std.testing.expect(obj.get("error") == null);
}

test "hover on Time shows class methods section" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_time_hover";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/time_ref.rb",
        .data = "t = Time.now\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/time_ref.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Hover cursor at position of "T" in "Time"
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/time_ref.rb\"},\"position\":{\"line\":0,\"character\":5}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoHoverResponse;
    const obj = switch (resp) {
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
        .string => |s2| s2,
        else => return error.ValueNotString,
    };
    try std.testing.expect(std.mem.indexOf(u8, value_str, "Class methods:") != null);
    try std.testing.expect(std.mem.indexOf(u8, value_str, "now") != null);
}
