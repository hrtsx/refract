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

test "--version prints version" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_ver";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ refract_bin, "--version" },
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var buf: [64]u8 = undefined;
    const n = child.stdout.?.readStreaming(std.Options.debug_io, &.{buf[0..]}) catch 0;

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
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "refract "));
}

test "--stdio flag is accepted" {
    const alloc = std.testing.allocator;
    var _rnd_bytes: [8]u8 = undefined;
    std.Options.debug_io.random(&_rnd_bytes);
    const rand_id = std.mem.readInt(u64, &_rnd_bytes, .little);
    var ws_buf: [128]u8 = undefined;
    const ws = std.fmt.bufPrint(&ws_buf, "/tmp/refract_test_stdio_{x}", .{rand_id}) catch "/tmp/refract_test_stdio_fb";
    var db_buf: [128]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_buf, "/tmp/refract_stdio_{x}.db", .{rand_id}) catch "/tmp/refract_stdio_fb.db";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, db_path) catch {};

    const init_json = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"rootUri\":\"file://{s}\",\"capabilities\":{{}},\"initializationOptions\":{{\"disableGemIndex\":true}}}}}}", .{ws});
    defer alloc.free(init_json);
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ refract_bin, "--stdio", "--db-path", db_path },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var timeout_done = std.atomic.Value(bool).init(false);
    const thr = std.Thread.spawn(.{}, struct {
        fn run(child_ptr: *std.process.Child, done: *std.atomic.Value(bool)) void {
            var elapsed: u32 = 0;
            while (elapsed < 8_000) : (elapsed += 100) {
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

    const init_frame = try frame(alloc, init_json);
    defer alloc.free(init_frame);
    const shutdown_frame = try frame(alloc, base_shutdown);
    defer alloc.free(shutdown_frame);
    const exit_frame = try frame(alloc, base_exit);
    defer alloc.free(exit_frame);
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
    const responses = try extractResponses(alloc, output.items);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }
    try std.testing.expect(getResponseById(responses, 1) != null);
}

test "log_level filters info messages" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_loglevel";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/log_test.rb",
        .data = "class LogTest; end\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/log_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"LogTest\"}}");
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
        if (!std.mem.eql(u8, ms, "window/logMessage")) continue;
        const params_val = robj.get("params") orelse continue;
        const params_obj = switch (params_val) {
            .object => |o| o,
            else => continue,
        };
        const type_val = params_obj.get("type") orelse continue;
        const type_int = switch (type_val) {
            .integer => |i| i,
            else => continue,
        };
        try std.testing.expect(type_int <= 2);
    }
}

test "max_file_size respected" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_maxsize";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/big_test.rb",
        .data = "class BigTest; def big_method; end; end\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true,\"maxFileSizeBytes\":1}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/big_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"BigTest\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const sym_resp = getResponseById(responses, 2) orelse return error.NoSymbolResponse;
    const obj = switch (sym_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    switch (result) {
        .array => |arr| try std.testing.expect(arr.items.len == 0),
        else => return error.ResultNotArray,
    }
}

test "--log-level 1 filters info" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p19_loglevel1";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.runWithArgs(&.{ "--log-level", "1" });
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    for (responses) |r| {
        const obj = switch (r.value) {
            .object => |o| o,
            else => continue,
        };
        const method_val = obj.get("method") orelse continue;
        const method = switch (method_val) {
            .string => |ms| ms,
            else => continue,
        };
        if (!std.mem.eql(u8, method, "window/logMessage")) continue;
        const params_val = obj.get("params") orelse continue;
        const params = switch (params_val) {
            .object => |po| po,
            else => continue,
        };
        const type_val = params.get("type") orelse continue;
        const msg_type = switch (type_val) {
            .integer => |ti| ti,
            else => continue,
        };
        try std.testing.expect(msg_type <= 1);
    }
}

test "--log-level 4 session completes" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p19_loglevel4";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.runWithArgs(&.{ "--log-level", "4" });
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const init_resp = getResponseById(responses, 1) orelse return error.NoInitializeResponse;
    const obj = switch (init_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("result") != null);
}

test "--disable-rubocop no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p19_disable_rubocop";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/test.rb",
        .data = "def hello\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/test.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def hello\\nend\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.runWithArgs(&.{"--disable-rubocop"});
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const init_resp = getResponseById(responses, 1) orelse return error.NoInitializeResponse;
    const obj = switch (init_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("result") != null);
}

test "--db-path override" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p19_dbpath";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    const custom_db = ws ++ "/custom.db";
    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, custom_db) catch {};

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.runWithArgs(&.{ "--db-path", custom_db });
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const init_resp = getResponseById(responses, 1) orelse return error.NoInitializeResponse;
    const obj = switch (init_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("result") != null);
    std.Io.Dir.cwd().access(std.Options.debug_io, custom_db, .{}) catch return error.CustomDbNotCreated;
}

test "didChangeConfiguration no error" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p20_config";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeConfiguration\",\"params\":{\"settings\":{}}}");
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
        const obj = switch (r.value) {
            .object => |o| o,
            else => continue,
        };
        if (obj.get("error")) |_| {
            return error.ErrorFound;
        }
    }
}

test "maxFileSizeMb configurable via initOptions" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t726";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = 1\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"maxFileSizeMb\":1,\"disableGemIndex\":true}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 1) orelse return error.NoInitResponse;
}

test "rubocopTimeoutSecs 1 kills rubocop fast" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t727";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = 1\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"rubocopTimeoutSecs\":1,\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"x = 1\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/formatting\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"options\":{\"tabSize\":2,\"insertSpaces\":true}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoFormattingResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "excludeDirs config excludes directory" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t728";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/generated", .default_dir);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/generated/foo.rb", .data = "class Generated; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"excludeDirs\":[\"generated\"],\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Generated\"}}");
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
    try std.testing.expectEqual(@as(usize, 0), result_arr.items.len);
}

test "P27 T10.3 yard param type overrides inference" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1003";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "# @param count [Integer]\ndef run(count)\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"# @param count [Integer]\\ndef run(count)\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":7}}}");
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

test "P29 T12.3 db pragma busy_timeout set" {
    const alloc = std.testing.allocator;
    var _rnd_bytes: [8]u8 = undefined;
    std.Options.debug_io.random(&_rnd_bytes);
    const rand_id = std.mem.readInt(u64, &_rnd_bytes, .little);
    var ws_buf: [128]u8 = undefined;
    const ws = std.fmt.bufPrint(&ws_buf, "/tmp/refract_test_p29_3_{x}", .{rand_id}) catch "/tmp/refract_test_p29_3_fb";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var rb_buf: [160]u8 = undefined;
    const rb_path = std.fmt.bufPrint(&rb_buf, "{s}/a.rb", .{ws}) catch return;
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = rb_path, .data = "x = 1\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    const init_msg = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"rootUri\":\"file://{s}\",\"capabilities\":{{}},\"initializationOptions\":{{\"disableGemIndex\":true}}}}}}", .{ws});
    defer alloc.free(init_msg);
    try s.send(init_msg);
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
    try std.testing.expect(getResponseById(resp, 1) != null);
}

test "P30 T13.15 didChangeConfiguration disables rubocop no error" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1315";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = 1\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeConfiguration\",\"params\":{\"settings\":{\"refract\":{\"disableRubocop\":true}}}}");
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
    _ = getResponseById(resp, 2) orelse return error.NoResponse;
}

test "P30 T13.16 didChangeConfiguration sets log level no error" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1316";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = 1\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeConfiguration\",\"params\":{\"settings\":{\"refract\":{\"logLevel\":3}}}}");
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
    _ = getResponseById(resp, 2) orelse return error.NoResponse;
}

test "P30 T13.17 didChangeConfiguration disableGemIndex no error" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1317";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = 1\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeConfiguration\",\"params\":{\"settings\":{\"refract\":{\"disableGemIndex\":true}}}}");
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
    _ = getResponseById(resp, 2) orelse return error.NoResponse;
}

test "P32 T15.27 @type annotation overrides inference" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1527";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "# @type [Integer]\nx1527 = \"string value\"\n" });
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

test "P32 T15.34 ||= doesnt override higher-confidence type" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1534";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x1534 = 42\nx1534 ||= \"hi\"\n" });
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

test "P35 T18.2 excludeDirs option skips excluded directory" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p35_182";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/lib", .default_dir);
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/vendor", .default_dir);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/lib/alpha.rb", .data = "class LibAlpha182\nend\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/vendor/beta.rb", .data = "class VendorBeta182\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true,\"excludeDirs\":[\"vendor\"]}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/lib/alpha.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"LibAlpha182\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"VendorBeta182\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoLibAlphaResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "LibAlpha182") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "VendorBeta182") == null);
}

test "P35 T18.3 maxFileSizeBytes 1 skips all files" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p35_183";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class SizeCheck183\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true,\"maxFileSizeBytes\":1}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"SizeCheck183\"}}");
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "SizeCheck183") == null);
}

test "T_VERSION stale didChange does not revert content" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tversion";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/v.rb", .data = "def current_sym_xqz; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/v.rb\",\"languageId\":\"ruby\",\"version\":2,\"text\":\"def current_sym_xqz; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/v.rb\",\"version\":1},\"contentChanges\":[{\"text\":\"def stale_sym_xqz; end\\n\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/v.rb\",\"version\":3},\"contentChanges\":[{\"text\":\"def current_sym_xqz; end\\n\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"stale_sym_xqz\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const sym_resp = getResponseById(resp, 3) orelse return error.NoSymbolResponse;
    const sym_obj = switch (sym_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = sym_obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.NotArray,
    };
    try std.testing.expectEqual(@as(usize, 0), arr.items.len);
}

test "T_LARGE_FILE file above max_file_size not indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tlargefile";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    const large_path = ws ++ "/large_unique_xyz123.rb";
    {
        const f = try std.Io.Dir.cwd().createFile(std.Options.debug_io, large_path, .{});
        defer f.close(std.Options.debug_io);
        const chunk = "# this is a comment line to pad the file\n";
        const target = 9 * 1024 * 1024;
        var written: usize = 0;
        while (written < target) {
            const n = @min(chunk.len, target - written);
            try f.writeStreamingAll(std.Options.debug_io, chunk[0..n]);
            written += n;
        }
        // Write the unique symbol at the very end
        try f.writeStreamingAll(std.Options.debug_io, "def refract_unique_sym_xyz123_large_file_method; end\n");
    }

    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ large_path ++ "\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"refract_unique_sym_xyz123_large_file_method\"}}");
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
    const result = sym_obj.get("result") orelse return error.NoResult;
    switch (result) {
        .array => |arr| try std.testing.expectEqual(@as(usize, 0), arr.items.len),
        .null => {},
        else => return error.UnexpectedResult,
    }
}

test "T_EXCLUDEDIRS_SAVE file in excludeDir not re-indexed on save" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_texclsave";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/generated", .default_dir);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/generated/auto.rb", .data = "class AutoExcludedGen; end\n" });
    const file_uri = "file://" ++ ws ++ "/generated/auto.rb";
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true,\"excludeDirs\":[\"generated\"]}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\",\"params\":{\"textDocument\":{\"uri\":\"" ++ file_uri ++ "\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"AutoExcludedGen\"}}");
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
    const sym_result = sym_obj.get("result") orelse return error.NoResult;
    switch (sym_result) {
        .array => |a| try std.testing.expectEqual(@as(usize, 0), a.items.len),
        .null => {},
        else => return error.UnexpectedResult,
    }
}

test "P21 T21.7 gitignore negation respected" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_t217";
    const db = "/tmp/refract_test_p21_t217.db";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, db) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, db) catch {};
    std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/vendor", .default_dir) catch {};
    std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/vendor/keep", .default_dir) catch {};
    std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/vendor/skip", .default_dir) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/.gitignore", .data = "vendor\n!keep\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/vendor/keep/g.rb", .data = "class GoodOne; end\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/vendor/skip/b.rb", .data = "class BadOne; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/vendor/keep/g.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"GoodOne\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"BadOne\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.runWithArgs(&.{ "--db-path", db });
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r3 = getResponseById(resp, 3) orelse return error.NoBadOneResponse;
    const r3obj = switch (r3) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const r3result = r3obj.get("result") orelse return error.NoResult;
    const bad_arr = switch (r3result) {
        .array => |a| a,
        else => return error.NotArray,
    };
    try std.testing.expect(bad_arr.items.len == 0);
}

test "P27 T27.2 bundleExecTimeoutSecs accepted in initializationOptions" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t272";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class A; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true,\"bundleExecTimeoutSecs\":5}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"A\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }
    const resp1 = getResponseById(responses, 1) orelse return error.NoInitResponse;
    const obj1 = switch (resp1) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj1.get("error") == null);
    const resp2 = getResponseById(responses, 2) orelse return error.NoSymbolResponse;
    const obj2 = switch (resp2) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj2.get("error") == null);
}

test "P36 T4B.1 disableRubocop toggle via didChangeConfiguration does not crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p36_t4b1";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Foo; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true,\"disableRubocop\":false}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeConfiguration\",\"params\":{\"settings\":{\"refract\":{\"disableRubocop\":true}}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeConfiguration\",\"params\":{\"settings\":{\"refract\":{\"disableRubocop\":false}}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Foo\"}}");
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
}

test "P36 T4C.1 file exceeding maxFileSizeBytes is not indexed but diagnostics still run" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p36_t4c1";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const big_content = "# bigfile\nclass BigFileSentinel; end\n" ++ "x = 1\n" ** 300;
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/big.rb", .data = big_content });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/small.rb", .data = "class SmallOk; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true,\"maxFileSizeBytes\":100}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/big.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/small.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"BigFileSentinel\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"SmallOk\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp2 = getResponseById(responses, 2) orelse return error.NoBigSymbolResponse;
    const obj2 = switch (resp2) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj2.get("error") == null);
    const result2 = obj2.get("result") orelse return error.NoResult;
    const arr2 = switch (result2) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    for (arr2.items) |item| {
        const iobj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = iobj.get("name") orelse continue;
        const ns = switch (name) {
            .string => |ns2| ns2,
            else => continue,
        };
        try std.testing.expect(!std.mem.eql(u8, ns, "BigFileSentinel"));
    }

    const resp3 = getResponseById(responses, 3) orelse return error.NoSmallSymbolResponse;
    const obj3 = switch (resp3) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj3.get("error") == null);
    const result3 = obj3.get("result") orelse return error.NoResult;
    const arr3 = switch (result3) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    var found_small = false;
    for (arr3.items) |item| {
        const iobj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = iobj.get("name") orelse continue;
        if (std.mem.eql(u8, switch (name) {
            .string => |ns| ns,
            else => continue,
        }, "SmallOk")) {
            found_small = true;
            break;
        }
    }
    try std.testing.expect(found_small);
}

test "P36 T4D.1 rubocopTimeoutSecs hot-reload via didChangeConfiguration no crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p36_t4d1";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Baz; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeConfiguration\",\"params\":{\"settings\":{\"refract\":{\"rubocopTimeoutSecs\":1}}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeConfiguration\",\"params\":{\"settings\":{\"refract\":{\"maxWorkers\":2,\"maxFileSize\":4}}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Baz\"}}");
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
}

test "P37 T4.1 maxFileSizeMb hot-reload via didChangeConfiguration excludes large files" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p37_t4";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/small.rb", .data = "class SmallMbSentinel; end\n" });
    const big_content = "class BigMbSentinel; end\n" ++ "x = 1\n" ** 200;
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/big.rb", .data = big_content });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true,\"disableRubocop\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeConfiguration\",\"params\":{\"settings\":{\"refract\":{\"maxFileSizeMb\":1}}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"SmallMbSentinel\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeConfiguration\",\"params\":{\"settings\":{\"refract\":{\"maxFileSize\":10}}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/big.rb\",\"type\":2},{\"uri\":\"file://" ++ ws ++ "/big.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"BigMbSentinel\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }
    const resp2 = getResponseById(responses, 2) orelse return error.NoSmallSymbolResponse;
    const obj2 = switch (resp2) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj2.get("error") == null);
    const resp3 = getResponseById(responses, 3) orelse return error.NoBigSymbolResponse;
    const obj3 = switch (resp3) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj3.get("error") == null);
    const result3 = obj3.get("result") orelse return error.NoResult;
    const arr3 = switch (result3) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    for (arr3.items) |item| {
        const iobj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = iobj.get("name") orelse continue;
        const ns = switch (name) {
            .string => |n| n,
            else => continue,
        };
        try std.testing.expect(!std.mem.eql(u8, ns, "BigMbSentinel"));
    }
}
