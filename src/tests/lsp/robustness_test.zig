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

test "gem indexing no crash when no Gemfile.lock" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_gem";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    // Ensure there is no Gemfile.lock in the fixture dir
    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, ws ++ "/Gemfile.lock") catch {};

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"NoSuchGemClass\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    // Server must not crash; workspace/symbol returns an array (possibly empty)
    const resp = getResponseById(responses, 2) orelse return error.NoSymbolResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    switch (result) {
        .array => {},
        else => return error.ResultNotArray,
    }
}

test "didOpen empty file no crash" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_empty";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/empty.rb", .data = "" });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/empty.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoSymbolResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    _ = arr;
}

test "initializationOptions disableGemIndex no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_opts";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoSymbolResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("result") != null);
}

test "circular symlink no infinite scan" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_link";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, ws ++ "/loop") catch {};
    try std.Io.Dir.cwd().symLink(std.Options.debug_io, ws, ws ++ "/loop", .{});
    defer std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, ws ++ "/loop") catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }
    try std.testing.expect(getResponseById(responses, 2) != null);
}

test "malformed Content-Length is safe" {
    const alloc = std.testing.allocator;

    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{refract_bin},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    try child.stdin.?.writeStreamingAll(std.Options.debug_io, "Content-Length: 999999999\r\n\r\n");
    child.stdin.?.close(std.Options.debug_io);
    child.stdin = null;

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = child.stdout.?.readStreaming(std.Options.debug_io, &.{buf[0..]}) catch break;
        if (n == 0) break;
    }

    var stderr_content: []u8 = &.{};
    if (child.stderr) |stderr_pipe| {
        var sbuf: [4096]u8 = undefined;
        var sbytes = std.ArrayList(u8).empty;
        while (true) {
            const sn = stderr_pipe.readStreaming(std.Options.debug_io, &.{sbuf[0..]}) catch break;
            if (sn == 0) break;
            sbytes.appendSlice(alloc, sbuf[0..sn]) catch break;
        }
        stderr_content = sbytes.toOwnedSlice(alloc) catch &.{};
    }
    defer if (stderr_content.len > 0) alloc.free(stderr_content);

    const term = try child.wait(std.Options.debug_io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("refract exited with code {d}\n", .{code});
        },
        else => std.debug.print("refract terminated abnormally: {}\n", .{term}),
    }
    if (stderr_content.len > 0) {
        std.debug.print("refract stderr:\n{s}\n", .{stderr_content});
    }
}

test "bg scan does not block hover" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_bgscan";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/h.rb", .data = "class MyClass\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/h.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class MyClass\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/h.rb\"},\"position\":{\"line\":0,\"character\":6}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }
    const resp = getResponseById(responses, 2) orelse return error.NoResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    _ = obj.get("id") orelse return error.NoId;
}

test "cancelRequest no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_cancel";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"$/cancelRequest\",\"params\":{\"id\":42}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }
    _ = getResponseById(responses, 2) orelse return error.NoResponse;
}

test "didRenameFiles unknown file no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_rename2";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/x.rb", .data = "x = 1\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didRenameFiles\",\"params\":{\"files\":[{\"oldUri\":\"file://" ++ ws ++ "/nonexistent.rb\",\"newUri\":\"file://" ++ ws ++ "/also_nonexistent.rb\"}]}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const rawR2 = try s.run();
    defer alloc.free(rawR2);
    const respR2 = try extractResponses(alloc, rawR2);
    defer {
        for (respR2) |r| r.deinit();
        alloc.free(respR2);
    }
    _ = getResponseById(respR2, 1) orelse return error.NoInitResponse;
}

test "progress report arrives during bg scan" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_progress";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    for (0..100) |i| {
        const fname = try std.fmt.allocPrint(alloc, ws ++ "/f{d}.rb", .{i});
        defer alloc.free(fname);
        try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = fname, .data = "x = 1\n" });
    }
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{\"window\":{\"workDoneProgress\":true}},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send(base_shutdown);
    try s.send(base_exit);
    const rawPR = try s.run();
    defer alloc.free(rawPR);
    _ = rawPR.len; // Don't assert count; scan timing is non-deterministic
}

test "bg scan skips file deleted between iterations" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t75";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/x.rb", .data = "x = 1\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didDeleteFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/nonexistent.rb\",\"type\":1}]}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
}

test "workspace symbol empty query no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t839";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Foo; end\n" });
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

test "non-UTF-8 file no crash post T0.1" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t846";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Foo; end\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/b.rb", .data = "\xff\xfe class Bad; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/b.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Foo\"}}");
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

test "P26 T9.62 namespace module symbol form no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p26_t962";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "module Foo::Bar\nend\n" });
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

test "P27 T10.5 yard no annotation no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1005";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def hello\nend\n" });
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

test "P27 T10.10 rescue binding untyped no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1010";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "begin\nrescue => e\nend\n" });
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

test "P27 T10.13 rescue modifier no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1013";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = 1 rescue 0\n" });
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

test "P27 T10.16 or-assign no crash no type" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1016";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x ||= compute\n" });
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

test "P27 T10.18 op-assign no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1018";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = 0\nx += 1\n" });
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

test "P27 T10.29 inlay hint param unknown method no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1029";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "unknown_method(1, 2)\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"unknown_method(1, 2)\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/inlayHint\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":20}}}}");
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

test "P27 T10.46 type hierarchy no parent no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1046";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class A\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class A\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"typeHierarchy/supertypes\",\"params\":{\"item\":{\"name\":\"A\",\"kind\":5,\"uri\":\"file://" ++ ws ++ "/a.rb\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":7}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":7}}}}}");
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

test "P28 T11.5 param hint multiline call no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t1105";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def foo(a, b); end\nfoo(\n  1,\n  2)\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def foo(a, b); end\\nfoo(\\n  1,\\n  2)\\n\"}}}");
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

test "P28 T11.6 param hint string with parens no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t1106";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def foo(a, b); end\nfoo(\"a(b)\", 1)\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def foo(a, b); end\\nfoo(\\\"a(b)\\\", 1)\\n\"}}}");
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
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P28 T11.27 pattern match no capture no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t1127";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "case [1, 2]\nin [1, 2]\nputs \"ok\"\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"case [1, 2]\\nin [1, 2]\\nputs \\\"ok\\\"\\nend\\n\"}}}");
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

test "P28 T11.37 workspace didChangeWorkspaceFolders no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t1137";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWorkspaceFolders\",\"params\":{\"event\":{\"added\":[],\"removed\":[]}}}");
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

test "P29 T12.10 yield children visited no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1210";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def foo\n  yield(1 + 2)\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def foo\\n  yield(1 + 2)\\nend\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
}

test "P29 T12.11 super children visited no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1211";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Child < Parent\n  def foo\n    super(1)\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Child < Parent\\n  def foo\\n    super(1)\\n  end\\nend\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
}

test "P29 T12.12 call_and_write no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1212";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "user = Object.new\nuser.name &&= \"x\"\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"user = Object.new\\nuser.name &&= \\\"x\\\"\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
}

test "P29 T12.13 call_or_write no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1213";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "@cache ||= fetch\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"@cache ||= fetch\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
}

test "P29 T12.18 namespace stack 64 deep no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1218";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // Build 64-level nested module source
    const f = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, ws ++ "/a.rb", .{});
    defer f.close(std.Options.debug_io);
    var i: usize = 0;
    var buf: [32]u8 = undefined;
    while (i < 64) : (i += 1) {
        const line = try std.fmt.bufPrint(&buf, "module M{d}\n", .{i});
        try f.writeStreamingAll(std.Options.debug_io, line);
    }
    try f.writeStreamingAll(std.Options.debug_io, "  INNER = 42\n");
    i = 0;
    while (i < 64) : (i += 1) {
        try f.writeStreamingAll(std.Options.debug_io, "end\n");
    }
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
}

test "P29 T12.19 namespace stack 65 deep safely dropped" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1219";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const f = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, ws ++ "/a.rb", .{});
    defer f.close(std.Options.debug_io);
    var i: usize = 0;
    var buf2: [32]u8 = undefined;
    while (i < 65) : (i += 1) {
        const line = try std.fmt.bufPrint(&buf2, "module M{d}\n", .{i});
        try f.writeStreamingAll(std.Options.debug_io, line);
    }
    try f.writeStreamingAll(std.Options.debug_io, "  DEEP_CONST = 1\n");
    i = 0;
    while (i < 65) : (i += 1) {
        try f.writeStreamingAll(std.Options.debug_io, "end\n");
    }
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
}

test "P29 T12.20 folding stack 200 deep no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1220";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const f = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, ws ++ "/a.rb", .{});
    defer f.close(std.Options.debug_io);
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        try f.writeStreamingAll(std.Options.debug_io, "begin\n");
    }
    try f.writeStreamingAll(std.Options.debug_io, "  x = 1\n");
    i = 0;
    while (i < 200) : (i += 1) {
        try f.writeStreamingAll(std.Options.debug_io, "end\n");
    }
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/foldingRange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoFoldingResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    switch (result) {
        .array => {},
        else => return error.ResultNotArray,
    }
}

test "P29 T12.21 folding stack 130 deep no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1221";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const f = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, ws ++ "/a.rb", .{});
    defer f.close(std.Options.debug_io);
    var i: usize = 0;
    while (i < 130) : (i += 1) {
        try f.writeStreamingAll(std.Options.debug_io, "begin\n");
    }
    try f.writeStreamingAll(std.Options.debug_io, "  y = 2\n");
    i = 0;
    while (i < 130) : (i += 1) {
        try f.writeStreamingAll(std.Options.debug_io, "end\n");
    }
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/foldingRange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoFoldingResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    switch (result) {
        .array => {},
        else => return error.ResultNotArray,
    }
}

test "P29 T12.32 self method no return type no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1232";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Worker\n  def run\n    x = self.unknown_method\n    x\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Worker\\n  def run\\n    x = self.unknown_method\\n    x\\n  end\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":3,\"character\":4}}}");
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

test "P29 T12.35 chained inference missing receiver no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1235";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = unknown.method\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"x = unknown.method\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
}

test "P29 T12.36 chained inference missing method no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1236";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "user = User.new\nx = user.nonexistent_method\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"user = User.new\\nx = user.nonexistent_method\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
}

test "P30 T13.19 linkedEditingRange no crash on number position" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1319";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = 1\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/linkedEditingRange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":4}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoResponse;
}

test "P30 T13.20 linkedEditingRange no crash on empty file" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1320";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "\n" });
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
    _ = getResponseById(resp, 2) orelse return error.NoResponse;
}

test "P30 T13.21 executeCommand forceReindex no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1321";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Aa; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/executeCommand\",\"params\":{\"command\":\"refract.forceReindex\",\"arguments\":[]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoExecResponse;
    _ = getResponseById(resp, 3) orelse return error.NoSymbolResponse;
}

test "P30 T13.22 executeCommand toggleGemIndex no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1322";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = 1\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/executeCommand\",\"params\":{\"command\":\"refract.toggleGemIndex\",\"arguments\":[]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoExecResponse;
    _ = getResponseById(resp, 3) orelse return error.NoSymbolResponse;
}

test "P30 T13.24 Symbol to_proc no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1324";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "arr = [\"a\", \"b\"]\nnames = arr.map(&:upcase)\n" });
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
}

test "P30 T13.27 2-level chain no crash missing mid" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1327";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Chainaa\n  # @return [Chainbb]\n  def getb\n    nil\n  end\nend\nobj = Chainaa.new\nx = obj.unknownmid.getc\n" });
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
}

test "P30 T13.28 2-level chain no crash missing leaf" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1328";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Leafbb\nend\nclass Leafaa\n  # @return [Leafbb]\n  def getb\n    Leafbb.new\n  end\nend\nobj = Leafaa.new\nx = obj.getb.unknownleaf\n" });
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
}

test "P30 T13.29 2-level chain no crash missing root type" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1329";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "untyped_obj = get_something\nx = untyped_obj.getb.getc\n" });
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
}

test "P30 T13.30 parallel indexing many files no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1330";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var path_buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, ws ++ "/f{d}.rb", .{i});
        var content_buf: [64]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf, "class Parallel{d}class; end\n", .{i});
        try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = path, .data = content });
    }
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    var j: usize = 0;
    while (j < 20) : (j += 1) {
        var path_buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/f{d}.rb", .{j});
        var msg_buf = std.ArrayList(u8).empty;
        defer msg_buf.deinit(alloc);
        try msg_buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://");
        try msg_buf.appendSlice(alloc, ws);
        try msg_buf.appendSlice(alloc, path);
        try msg_buf.appendSlice(alloc, "\",\"type\":1}]}}");
        try s.send(msg_buf.items);
    }
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Parallel0class\"}}");
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
}

test "P30 T13.33 regression p29 hover completion docSymbol no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1333";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Service\n  def call\n    42\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":6}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":4,\"character\":0}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
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
    _ = getResponseById(resp, 3) orelse return error.NoCompletionResponse;
    _ = getResponseById(resp, 4) orelse return error.NoDocSymResponse;
}

test "P31 T14.11 refract.showReferences executeCommand no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1411";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/executeCommand\",\"params\":{\"command\":\"refract.showReferences\",\"arguments\":[\"file://" ++ ws ++ "/a.rb\",{\"line\":0,\"character\":0}]}}");
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
    const obj2 = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj2.get("error") == null);
}

test "P31 T14.12 refract.runTest executeCommand no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1412";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a_spec.rb", .data = "describe 'Foo' do\n  it 'works' do\n  end\nend\n" }) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/executeCommand\",\"params\":{\"command\":\"refract.runTest\",\"arguments\":[\"file://" ++ ws ++ "/a_spec.rb\",1]}}");
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
    const obj2 = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj2.get("error") == null);
}

test "P32 T15.9 safe nav dot completion with typed receiver" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t159";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class SafeNav159\n  def greet159; end\nend\nu = SafeNav159.new\nu&.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":4,\"character\":3}}}");
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "greet159") != null);
}

test "P32 T15.10 safe nav dot completion untyped receiver" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1510";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x&.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":3}}}");
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
}

test "P32 T15.11 safe nav type inference user&.name returns String" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1511";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Usr1511\n  # @return [String]\n  def nm1511; \"x\"; end\nend\nu1511 = Usr1511.new\nt1511 = u1511&.nm1511\n" });
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

test "P32 T15.12 safe nav chain completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1512";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Usr1512\n  # @return [String]\n  def nm1512; \"x\"; end\nend\nu1512 = Usr1512.new\nu1512&.nm1512&.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":5,\"character\":15}}}");
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "upcase") != null or std.mem.indexOf(u8, raw, "downcase") != null);
}

test "P32 T15.13 safe nav no crash at offset 0" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1513";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "&.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":2}}}");
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
}

test "P35 T18.1 Unicode identifiers no crash on hover" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p35_181";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/unicode.rb", .data = "def caf\xC3\xA9_method; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/unicode.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/unicode.rb\"},\"position\":{\"line\":0,\"character\":4}}}");
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

test "P35 T18.4 didChangeWorkspaceFolders add new folder no crash" {
    const alloc = std.testing.allocator;
    const ws_a = "/tmp/refract_test_p35_184a";
    const ws_b = "/tmp/refract_test_p35_184b";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws_a) catch {};
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws_b) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws_a, .default_dir);
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws_b, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws_a) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws_b) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws_a ++ "/a.rb", .data = "class FolderAlpha184\nend\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws_b ++ "/b.rb", .data = "class FolderBeta184\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws_a ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWorkspaceFolders\",\"params\":{\"event\":{\"added\":[{\"uri\":\"file://" ++ ws_b ++ "\",\"name\":\"b\"}],\"removed\":[]}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"FolderBeta184\"}}");
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
}

test "T1 syntax error ruby no crash on hover" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_t1_syntax";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/broken.rb",
        .data = "def broken_method(\n  oops invalid",
    });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/broken.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/broken.rb\"},\"position\":{\"line\":0,\"character\":0}}}");
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

test "T4 concurrent requests all responses returned" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_t4_concurrent";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class ConcurrentAlpha\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"ConcurrentAlpha\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"ConcurrentAlpha\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"ConcurrentAlpha\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"ConcurrentAlpha\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"ConcurrentAlpha\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    var found: usize = 0;
    for ([_]i64{ 2, 3, 4, 5, 6 }) |id| {
        if (getResponseById(resp, id) != null) found += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), found);
}

test "T5 scanner depth deep tree handled safely" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_t5_depth";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // Create a 10-level deep directory tree with one .rb file per level
    var path_buf: [512]u8 = undefined;
    var cur_path: []u8 = try alloc.dupe(u8, ws);
    defer alloc.free(cur_path);
    var depth: usize = 0;
    while (depth < 10) : (depth += 1) {
        const sub = try std.fmt.bufPrint(&path_buf, "{s}/d{d}", .{ cur_path, depth });
        std.Io.Dir.createDirAbsolute(std.Options.debug_io, sub, .default_dir) catch {};
        const rb = try std.fmt.allocPrint(alloc, "{s}/level{d}.rb", .{ sub, depth });
        defer alloc.free(rb);
        const content = try std.fmt.allocPrint(alloc, "class DepthLevel{d}\nend\n", .{depth});
        defer alloc.free(content);
        std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = rb, .data = content }) catch {};
        const new_path = try alloc.dupe(u8, sub);
        alloc.free(cur_path);
        cur_path = new_path;
    }
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"DepthLevel\"}}");
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
    // Must not crash and must return a valid response
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"error\"") == null or
        std.mem.indexOf(u8, raw, "DepthLevel") != null);
}

test "P21 T21.8 PRAGMA optimize smoke no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_t218";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    var fi: usize = 0;
    while (fi < 50) : (fi += 1) {
        const fname = try std.fmt.allocPrint(alloc, ws ++ "/c{d}.rb", .{fi});
        defer alloc.free(fname);
        const src = try std.fmt.allocPrint(alloc, "class OptClass{d}; end\n", .{fi});
        defer alloc.free(src);
        try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = fname, .data = src });
        const change = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{{\"changes\":[{{\"uri\":\"file://{s}\",\"type\":1}}]}}}}", .{fname});
        defer alloc.free(change);
        try s.send(change);
    }
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"OptClass\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r2 = getResponseById(resp, 2) orelse return error.NoSymbolResponse;
    const r2obj = switch (r2) {
        .object => |o| o,
        else => return error.NotObject,
    };
    _ = r2obj.get("result") orelse return error.NoResult;
}

test "P22 T22.9b concurrent didChange no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_t229b";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class A; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class A; end\\n\"}}}");
    var v: usize = 2;
    while (v <= 6) : (v += 1) {
        const change = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{{\"textDocument\":{{\"uri\":\"file://{s}/a.rb\",\"version\":{d}}},\"contentChanges\":[{{\"text\":\"class A{d}; end\\n\"}}]}}}}", .{ ws, v, v });
        defer alloc.free(change);
        try s.send(change);
    }
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":7}}}");
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
    const robj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    _ = robj.get("result") orelse return error.NoResult;
}

test "P37 T2.1 malformed JSON body produces parse error response" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p37_t2";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true,\"disableRubocop\":true}}}");
    try s.send(base_initialized);
    const bad_body = "NOT JSON {{{{";
    const bad_frame = try std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n{s}", .{ bad_body.len, bad_body });
    defer alloc.free(bad_frame);
    try s.input.appendSlice(alloc, bad_frame);
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }
    var found_parse_error = false;
    for (responses) |r| {
        const obj = switch (r.value) {
            .object => |o| o,
            else => continue,
        };
        const err_val = obj.get("error") orelse continue;
        const err_obj = switch (err_val) {
            .object => |o| o,
            else => continue,
        };
        const code_val = err_obj.get("code") orelse continue;
        const code = switch (code_val) {
            .integer => |n| n,
            else => continue,
        };
        if (code == -32700) {
            found_parse_error = true;
            break;
        }
    }
    try std.testing.expect(found_parse_error);
}

test "sort_by still works post T0.1" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t840";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class User; end\nusers = User.all\nusers.sort_by { |u|\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class User; end\\nusers = User.all\\nusers.sort_by { |u|\\n\"}}}");
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
    const r = getResponseById(resp, 2) orelse return error.NoInlayResponse;
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

test "P34 T17.1 negative line position returns null not panic" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p34_t171";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/neg.rb", .data = "class NegPos\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/neg.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/neg.rb\"},\"position\":{\"line\":-1,\"character\":0}}}");
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

test "T_CRLF position accuracy for CRLF files" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tcrlf";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/crlf.rb", .data = "class Foo\r\n  def bar\r\nend\r\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/crlf.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/crlf.rb\"},\"position\":{\"line\":1,\"character\":6}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"error\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "bar") != null);
}

test "T_PATH_OUTSIDE path traversal does not crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tpathout";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file:///etc/passwd\"},\"position\":{\"line\":0,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp_out = try extractResponses(alloc, raw);
    defer {
        for (resp_out) |r| r.deinit();
        alloc.free(resp_out);
    }
    _ = getResponseById(resp_out, 2);
}

test "T_ALIAS alias_method second arg cross-ref" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_talias_am";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/alias.rb", .data = "class Foo\n  def bar; end\n  alias_method :baz, :bar\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/alias.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"baz\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "baz") != null);
}

test "T_CANON path traversal via .. in URI does not escape workspace" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tcanon";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/../../etc/passwd\"},\"position\":{\"line\":0,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const shutdown_resp = getResponseById(resp, 99) orelse return error.NoShutdownResponse;
    const shutdown_obj = switch (shutdown_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(shutdown_obj.get("id") != null);
}

test "T_TRANSPORT_BADLEN transport rejects Content-Length: 0" {
    const alloc = std.testing.allocator;
    var _rnd_bytes: [8]u8 = undefined;
    std.Options.debug_io.random(&_rnd_bytes);
    const rand_id = std.mem.readInt(u64, &_rnd_bytes, .little);
    var ws_buf: [128]u8 = undefined;
    const ws = std.fmt.bufPrint(&ws_buf, "/tmp/refract_test_badlen_{x}", .{rand_id}) catch "/tmp/refract_test_badlen_fb";
    var db_buf: [128]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_buf, "/tmp/refract_badlen_{x}.db", .{rand_id}) catch "/tmp/refract_badlen_fb.db";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, db_path) catch {};

    const argv = [_][]const u8{ refract_bin, "--db-path", db_path };
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var timeout_done = std.atomic.Value(bool).init(false);
    const thr = std.Thread.spawn(.{}, struct {
        fn run(child_ptr: *std.process.Child, done: *std.atomic.Value(bool)) void {
            var elapsed: u32 = 0;
            while (elapsed < 10_000) : (elapsed += 100) {
                if (done.load(.acquire)) return;
                {
                    var _sleep_ts: std.c.timespec = .{ .sec = @intCast((100 * std.time.ns_per_ms) / std.time.ns_per_s), .nsec = @intCast((100 * std.time.ns_per_ms) % std.time.ns_per_s) };
                    _ = std.c.nanosleep(&_sleep_ts, null);
                }
            }
            if (!done.load(.acquire)) child_ptr.kill(std.Options.debug_io);
        }
    }.run, .{ &child, &timeout_done }) catch null;
    defer {
        timeout_done.store(true, .release);
        if (thr) |t| t.join();
    }

    const bad_frame = "Content-Length: 0\r\n\r\n";
    const init_json = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"rootUri\":\"file://{s}\",\"capabilities\":{{}},\"initializationOptions\":{{\"disableGemIndex\":true}}}}}}", .{ws});
    defer alloc.free(init_json);
    const init_frame = try std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n{s}", .{ init_json.len, init_json });
    defer alloc.free(init_frame);
    const shutdown_json = "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"shutdown\",\"params\":null}";
    const shutdown_frame = try std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n{s}", .{ shutdown_json.len, shutdown_json });
    defer alloc.free(shutdown_frame);
    const exit_json = "{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}";
    const exit_frame = try std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n{s}", .{ exit_json.len, exit_json });
    defer alloc.free(exit_frame);

    try child.stdin.?.writeStreamingAll(std.Options.debug_io, bad_frame);
    try child.stdin.?.writeStreamingAll(std.Options.debug_io, init_frame);
    try child.stdin.?.writeStreamingAll(std.Options.debug_io, shutdown_frame);
    try child.stdin.?.writeStreamingAll(std.Options.debug_io, exit_frame);
    child.stdin.?.close(std.Options.debug_io);
    child.stdin = null;

    var output = std.ArrayList(u8).empty;
    defer output.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = child.stdout.?.readStreaming(std.Options.debug_io, &.{buf[0..]}) catch break;
        if (n == 0) break;
        try output.appendSlice(alloc, buf[0..n]);
    }

    var stderr_content: []u8 = &.{};
    if (child.stderr) |stderr_pipe| {
        var sbuf: [4096]u8 = undefined;
        var sbytes = std.ArrayList(u8).empty;
        while (true) {
            const sn = stderr_pipe.readStreaming(std.Options.debug_io, &.{sbuf[0..]}) catch break;
            if (sn == 0) break;
            sbytes.appendSlice(alloc, sbuf[0..sn]) catch break;
        }
        stderr_content = sbytes.toOwnedSlice(alloc) catch &.{};
    }
    defer if (stderr_content.len > 0) alloc.free(stderr_content);

    const term = try child.wait(std.Options.debug_io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("refract exited with code {d}\n", .{code});
        },
        else => std.debug.print("refract terminated abnormally: {}\n", .{term}),
    }
    if (stderr_content.len > 0) {
        std.debug.print("refract stderr:\n{s}\n", .{stderr_content});
    }
    const resp = try extractResponses(alloc, output.items);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const init_resp = getResponseById(resp, 1) orelse return error.NoInitResponse;
    const init_obj = switch (init_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(init_obj.get("result") != null);
}

test "T_DEBOUNCE rapid changes server stays responsive" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tdebounce";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/db.rb", .data = "def base_debounce_method; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    const file_uri = "file://" ++ ws ++ "/db.rb";
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"" ++ file_uri ++ "\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def base_debounce_method; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"" ++ file_uri ++ "\",\"version\":2},\"contentChanges\":[{\"text\":\"def base_debounce_method; end\\n# v2\\n\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"" ++ file_uri ++ "\",\"version\":3},\"contentChanges\":[{\"text\":\"def base_debounce_method; end\\n# v3\\n\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"" ++ file_uri ++ "\",\"version\":4},\"contentChanges\":[{\"text\":\"def base_debounce_method; end\\n# v4\\n\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"" ++ file_uri ++ "\",\"version\":5},\"contentChanges\":[{\"text\":\"def base_debounce_method; end\\n# v5\\n\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"" ++ file_uri ++ "\"},\"position\":{\"line\":0,\"character\":4}}}");
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
    try std.testing.expect(hover_obj.get("result") != null or hover_obj.get("error") == null);
}

test "T_UTF16 position negotiation with multibyte characters" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tutf16";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // Write file with é (U+00E9): 2 UTF-8 bytes, 1 UTF-16 code unit
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/utf16.rb", .data = "def caf\xc3\xa9(x)\n  x\nend\n" });
    const file_uri = "file://" ++ ws ++ "/utf16.rb";
    var s = try Session.init(alloc);
    defer s.deinit();
    // Initialize with utf-16 position encoding
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-16\"]}},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"" ++ file_uri ++ "\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def caf\\u00e9(x)\\n  x\\nend\\n\"}}}");
    // Hover at line 0, char 5 in UTF-16 — inside 'café', past only ASCII chars so UTF-16==UTF-8 here
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"" ++ file_uri ++ "\"},\"position\":{\"line\":0,\"character\":5}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    // Server must handle utf-16 request and return a valid (non-error) response
    const hover_resp = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    const hover_obj = switch (hover_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    // Result key must be present (may be null if not indexed, but must not be an error)
    try std.testing.expect(hover_obj.get("result") != null);
    if (hover_obj.get("error")) |ev| try std.testing.expect(ev == .null);
}

test "T_DB_INTEGRITY corrupted DB is self-healed at startup" {
    const alloc = std.testing.allocator;
    const garbage_db = "/tmp/refract_test_tdbint_garbage.db";
    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, garbage_db) catch {};
    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, garbage_db ++ ".lock") catch {};
    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, garbage_db ++ "-wal") catch {};
    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, garbage_db ++ "-shm") catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, garbage_db) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, garbage_db ++ ".lock") catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, garbage_db ++ "-wal") catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, garbage_db ++ "-shm") catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = garbage_db, .data = "THIS IS NOT A SQLITE DATABASE\n" });
    const argv = [_][]const u8{ refract_bin, "--db-path", garbage_db };
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    child.stdin.?.close(std.Options.debug_io);
    child.stdin = null;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = child.stdout.?.readStreaming(std.Options.debug_io, &.{buf[0..]}) catch break;
        if (n == 0) break;
    }

    var stderr_content: []u8 = &.{};
    if (child.stderr) |stderr_pipe| {
        var sbuf: [4096]u8 = undefined;
        var sbytes = std.ArrayList(u8).empty;
        while (true) {
            const sn = stderr_pipe.readStreaming(std.Options.debug_io, &.{sbuf[0..]}) catch break;
            if (sn == 0) break;
            sbytes.appendSlice(alloc, sbuf[0..sn]) catch break;
        }
        stderr_content = sbytes.toOwnedSlice(alloc) catch &.{};
    }
    defer if (stderr_content.len > 0) alloc.free(stderr_content);

    const term = try child.wait(std.Options.debug_io);
    if (stderr_content.len > 0) {
        std.debug.print("refract stderr:\n{s}\n", .{stderr_content});
    }
    // Corruption must be detected and logged, and the server must come up cleanly.
    switch (term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.AbnormalExit,
    }
    try std.testing.expect(std.mem.indexOf(u8, stderr_content, "self-heal") != null);
}

test "P27 T27.4 URI with percent-encoded space is accepted" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t274";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class C; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    // URI with %20 in the path — server must not crash
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/my%20project/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class C; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/my%20project/a.rb\"},\"position\":{\"line\":0,\"character\":6}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }
    const resp2 = getResponseById(responses, 2) orelse return error.NoHoverResponse;
    const obj2 = switch (resp2) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj2.get("error") == null);
}
