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

test "initialize returns capabilities" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_init";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 1) orelse return error.NoInitializeResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    try std.testing.expect(result_obj.get("capabilities") != null);
    try std.testing.expect(result_obj.get("serverInfo") != null);
}

test "cancelRequest produces no response" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_cancel";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send(
        \\{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":999}}
    );
    try s.send(
        \\{"jsonrpc":"2.0","id":2,"method":"workspace/symbol","params":{"query":""}}
    );
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    // Verify no response has id=999 (cancelRequest must not produce a response)
    for (responses) |r| {
        const obj = switch (r.value) {
            .object => |o| o,
            else => continue,
        };
        const id_val = obj.get("id") orelse continue;
        const rid = switch (id_val) {
            .integer => |i| i,
            else => continue,
        };
        try std.testing.expect(rid != 999);
    }
}

test "shutdown exits cleanly" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_shut";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const shutdown_resp = getResponseById(responses, 99) orelse return error.NoShutdownResponse;
    const obj = switch (shutdown_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "unknown method returns error" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_err";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"unknownMethod\",\"params\":{}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoErrorResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const err = obj.get("error") orelse return error.NoError;
    const err_obj = switch (err) {
        .object => |o| o,
        else => return error.ErrorNotObject,
    };
    const code = err_obj.get("code") orelse return error.NoCode;
    const code_int = switch (code) {
        .integer => |i| i,
        else => return error.CodeNotInt,
    };
    try std.testing.expectEqual(@as(i64, -32601), code_int);
}

test "didClose is a no-op" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_close";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file:///tmp/nonexistent_DidCloseMethod9134.rb\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"DidCloseMethod9134\"}}");
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
    try std.testing.expect(obj.get("error") == null);
    const result = obj.get("result") orelse return error.NoResult;
    switch (result) {
        .array => {},
        else => return error.ResultNotArray,
    }
}

test "didOpen does not crash on missing file" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_didopen_miss";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/nonexistent_file.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"\"}}}");
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

    try std.testing.expect(getResponseById(responses, 1) != null);
    try std.testing.expect(getResponseById(responses, 2) != null);
}

test "progress absent without client cap" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_noprogress";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/noprog_test.rb",
        .data = "class NoProg; end\n",
    });

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

    for (responses) |r| {
        const robj = switch (r.value) {
            .object => |o| o,
            else => continue,
        };
        const m = robj.get("method") orelse continue;
        const ms = switch (m) {
            .string => |sv| sv,
            else => continue,
        };
        try std.testing.expect(!std.mem.eql(u8, ms, "$/progress"));
    }
}

test "progress sent when cap advertised" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_yesprogress";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/yesprog_test.rb",
        .data = "class YesProg; end\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{\"window\":{\"workDoneProgress\":true}},\"initializationOptions\":{\"disableGemIndex\":true}}}");
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

    var found_progress = false;
    for (responses) |r| {
        const robj = switch (r.value) {
            .object => |o| o,
            else => continue,
        };
        const m = robj.get("method") orelse continue;
        const ms = switch (m) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, ms, "$/progress")) {
            found_progress = true;
            break;
        }
    }
    try std.testing.expect(found_progress);
}

test "@ trigger in server capabilities" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p19_at_trigger";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 1) orelse return error.NoInitializeResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const caps = switch (result_obj.get("capabilities") orelse return error.NoCaps) {
        .object => |o| o,
        else => return error.CapsNotObject,
    };
    const completion_provider = switch (caps.get("completionProvider") orelse return error.NoCompletionProvider) {
        .object => |o| o,
        else => return error.CompletionProviderNotObject,
    };
    const trigger_chars = switch (completion_provider.get("triggerCharacters") orelse return error.NoTriggerChars) {
        .array => |a| a,
        else => return error.TriggerCharsNotArray,
    };
    var found_at = false;
    for (trigger_chars.items) |tc| {
        const s2 = switch (tc) {
            .string => |str| str,
            else => continue,
        };
        if (std.mem.eql(u8, s2, "@")) {
            found_at = true;
            break;
        }
    }
    try std.testing.expect(found_at);
}

test "didChange no temp file" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p20_didchange";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/test.rb",
        .data = "class Foo\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/test.rb\",\"version\":2},\"contentChanges\":[{\"text\":\"class Bar\\nend\\n\"}]}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    // Snapshot existing refract- dirs before starting the server
    var existing = std.ArrayList([]u8).empty;
    defer {
        for (existing.items) |k| alloc.free(k);
        existing.deinit(alloc);
    }
    {
        var pre = std.Io.Dir.openDirAbsolute(std.Options.debug_io, "/tmp", .{ .iterate = true }) catch return;
        defer pre.close(std.Options.debug_io);
        var it2 = pre.iterate();
        while (try it2.next(std.Options.debug_io)) |entry| {
            if (std.mem.startsWith(u8, entry.name, "refract-"))
                try existing.append(alloc, try alloc.dupe(u8, entry.name));
        }
    }

    const raw = try s.run();
    defer alloc.free(raw);

    const responses_tmp = try extractResponses(alloc, raw);
    defer {
        for (responses_tmp) |r| r.deinit();
        alloc.free(responses_tmp);
    }

    // Check for any NEW refract- dirs created during this test
    var tmp_files = std.Io.Dir.openDirAbsolute(std.Options.debug_io, "/tmp", .{ .iterate = true }) catch return;
    defer tmp_files.close(std.Options.debug_io);
    var iter = tmp_files.iterate();
    while (try iter.next(std.Options.debug_io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "refract-")) continue;
        var was_existing = false;
        for (existing.items) |k| {
            if (std.mem.eql(u8, k, entry.name)) {
                was_existing = true;
                break;
            }
        }
        if (!was_existing) return error.TempFileFound;
    }
}

test "cancelRequest does not affect other ids" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_cancel2";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/c2.rb", .data = "def bar; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/c2.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"$/cancelRequest\",\"params\":{\"id\":1}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/c2.rb\"},\"position\":{\"line\":0,\"character\":3}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const rawC2 = try s.run();
    defer alloc.free(rawC2);
    const respC2 = try extractResponses(alloc, rawC2);
    defer {
        for (respC2) |r| r.deinit();
        alloc.free(respC2);
    }
    _ = getResponseById(respC2, 2) orelse return error.Id2Missing;
}

test "open doc cache stores didOpen text" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t71";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class A; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def cached_method; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"A\"}}");
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
    _ = obj.get("result") orelse return error.NoResult;
}

test "open doc cache didClose reverts to disk" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t74";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def disk_method; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def mem_method; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"disk_method\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"mem_method\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r2 = getResponseById(resp, 2) orelse return error.NoSymbolResponse2;
    const obj2 = switch (r2) {
        .object => |o| o,
        else => return error.NotObject2,
    };
    const result2 = obj2.get("result") orelse return error.NoResult2;
    const arr2 = switch (result2) {
        .array => |a| a,
        else => return error.NotArray2,
    };
    if (arr2.items.len == 0) return error.EmptyResult2;
}

test "progress workDoneProgress/create sent before begin" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t76";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    for (0..10) |i| {
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
    const raw = try s.run();
    defer alloc.free(raw);
}

test "P31 T14.10 refract.runTest registered in capabilities" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1410";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "runTest") != null);
}

test "P33 T16.1 request before initialize returns server_not_initialized" {
    const alloc = std.testing.allocator;
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Foo\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file:///tmp\",\"capabilities\":{}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const err_resp = getResponseById(resp, 1) orelse return error.NoErrorResponse;
    const obj = switch (err_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") != null);
    const err_obj = switch (obj.get("error").?) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const code = switch (err_obj.get("code") orelse return error.NoCode) {
        .integer => |i| i,
        else => return error.NotInteger,
    };
    try std.testing.expectEqual(@as(i64, -32002), code);
}

test "P33 T16.2 request after shutdown returns invalid_request" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p33_t162";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"shutdown\",\"params\":null}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"\"}}");
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const err_resp = getResponseById(resp, 2) orelse return error.NoErrorResponse;
    const obj = switch (err_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") != null);
    const err_obj = switch (obj.get("error").?) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const code = switch (err_obj.get("code") orelse return error.NoCode) {
        .integer => |i| i,
        else => return error.NotInteger,
    };
    try std.testing.expectEqual(@as(i64, -32600), code);
}

test "T_TRAVERSAL_DIDSAVE didSave with traversal URI does not crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_ttravdidsa";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/../../etc/passwd\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"root\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const sym_resp = getResponseById(resp, 2) orelse return error.NoSymbolResponse;
    const sym_obj = switch (sym_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(sym_obj.get("result") != null);
    try std.testing.expect(sym_obj.get("error") == null);
}
