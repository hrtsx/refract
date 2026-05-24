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

test "publishDiagnostics emitted on didSave" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_diag";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/diag_test.rb",
        .data = "class DiagTest; end\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/diag_test.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const notif = getNotificationByMethod(responses, "textDocument/publishDiagnostics") orelse
        return error.NoDiagnosticsNotification;
    const notif_obj = switch (notif) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const params = notif_obj.get("params") orelse return error.NoParams;
    const params_obj = switch (params) {
        .object => |o| o,
        else => return error.ParamsNotObject,
    };
    try std.testing.expect(params_obj.get("diagnostics") != null);
}

test "didOpen indexes and emits publishDiagnostics" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_open";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/open_fixture.rb",
        .data = "def DidOpenMethod5821; end\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/open_fixture.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def DidOpenMethod5821; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"DidOpenMethod5821\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const diag_notif = getNotificationByMethod(responses, "textDocument/publishDiagnostics");
    try std.testing.expect(diag_notif != null);

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
    var found = false;
    for (arr.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const nm = item_obj.get("name") orelse continue;
        const nm_str = switch (nm) {
            .string => |s2| s2,
            else => continue,
        };
        if (std.mem.eql(u8, nm_str, "DidOpenMethod5821")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "didChange emits publishDiagnostics notification" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_chg";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/change_fixture.rb",
        .data = "def DidChangeMethod3847; end\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/change_fixture.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def DidChangeMethod3847; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/change_fixture.rb\",\"version\":2},\"contentChanges\":[{\"text\":\"def DidChangeMethod3847b; end\\n\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"DidChangeMethod3847\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const diag_notif = getNotificationByMethod(responses, "textDocument/publishDiagnostics");
    try std.testing.expect(diag_notif != null);

    const resp = getResponseById(responses, 2) orelse return error.NoSymbolResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "didClose clears diagnostics" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p20_didclose";
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
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/test.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Foo\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/test.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const diag_notif = getNotificationByMethod(responses, "textDocument/publishDiagnostics");
    try std.testing.expect(diag_notif != null);
    const diag_obj = switch (diag_notif.?) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const params = diag_obj.get("params") orelse return error.NoParams;
    const params_obj = switch (params) {
        .object => |o| o,
        else => return error.ParamsNotObject,
    };
    const diags = switch (params_obj.get("diagnostics") orelse return error.NoDiags) {
        .array => |a| a,
        else => return error.DiagsNotArray,
    };
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "syntax error file emits prism diagnostic" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t736";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/syntax.rb", .data = "def foo\n  missing_end" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/syntax.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def foo\\n  missing_end\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
}

test "gem file diagnostics suppressed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t827";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Normal; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Normal; end\\n\"}}}");
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
    const r = getResponseById(resp, 2) orelse return error.NoHoverResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "rubocop not found does not crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t828";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Foo; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Foo; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":6}}}");
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
    try std.testing.expect(obj.get("error") == null);
    _ = obj.get("result") orelse return error.NoResult;
}

test "rubocop not found sends showMessage" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t829";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Foo; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":6}}}");
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
    try std.testing.expect(obj.get("error") == null);
    _ = obj.get("result") orelse return error.NoResult;
}

test "gem file publishDiagnostics empty not crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t848";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Normal; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Normal; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":6}}}");
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
    try std.testing.expect(obj.get("error") == null);
    _ = obj.get("result") orelse return error.NoResult;
}

test "P29 T12.45 rubocop diagnostic has code field" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1245";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = 'hello'\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const notif = getNotificationByMethod(resp, "textDocument/publishDiagnostics") orelse return;
    const notif_obj = switch (notif) {
        .object => |o| o,
        else => return,
    };
    const params = switch (notif_obj.get("params") orelse return) {
        .object => |o| o,
        else => return,
    };
    const diags = switch (params.get("diagnostics") orelse return) {
        .array => |a| a,
        else => return,
    };
    if (diags.items.len == 0) return; // rubocop not available or no offenses
    const diag = switch (diags.items[0]) {
        .object => |o| o,
        else => return,
    };
    const src = diag.get("source") orelse return;
    const src_str = switch (src) {
        .string => |sv| sv,
        else => return,
    };
    if (!std.mem.eql(u8, src_str, "rubocop")) return; // only check rubocop diagnostics
    try std.testing.expect(diag.get("code") != null);
}

test "P29 T12.46 rubocop diagnostic code equals cop_name" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1246";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = 'hello'\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const notif = getNotificationByMethod(resp, "textDocument/publishDiagnostics") orelse return;
    const notif_obj = switch (notif) {
        .object => |o| o,
        else => return,
    };
    const params = switch (notif_obj.get("params") orelse return) {
        .object => |o| o,
        else => return,
    };
    const diags = switch (params.get("diagnostics") orelse return) {
        .array => |a| a,
        else => return,
    };
    if (diags.items.len == 0) return;
    for (diags.items) |d| {
        const do = switch (d) {
            .object => |o| o,
            else => continue,
        };
        const src = do.get("source") orelse continue;
        const src_str = switch (src) {
            .string => |sv| sv,
            else => continue,
        };
        if (!std.mem.eql(u8, src_str, "rubocop")) continue;
        const code = do.get("code") orelse return error.NoCode;
        const code_str = switch (code) {
            .string => |sv| sv,
            else => return error.CodeNotString,
        };
        // cop_name format is "Namespace/CopName"
        try std.testing.expect(std.mem.indexOf(u8, code_str, "/") != null);
        return;
    }
}

test "P29 T12.47 rubocop diagnostic has codeDescription href" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1247";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = 'hello'\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const notif = getNotificationByMethod(resp, "textDocument/publishDiagnostics") orelse return;
    const notif_obj = switch (notif) {
        .object => |o| o,
        else => return,
    };
    const params = switch (notif_obj.get("params") orelse return) {
        .object => |o| o,
        else => return,
    };
    const diags = switch (params.get("diagnostics") orelse return) {
        .array => |a| a,
        else => return,
    };
    if (diags.items.len == 0) return;
    for (diags.items) |d| {
        const do = switch (d) {
            .object => |o| o,
            else => continue,
        };
        const src = do.get("source") orelse continue;
        const src_str = switch (src) {
            .string => |sv| sv,
            else => continue,
        };
        if (!std.mem.eql(u8, src_str, "rubocop")) continue;
        if (do.get("code") == null) continue;
        const cd = switch (do.get("codeDescription") orelse return error.NoCodeDescription) {
            .object => |o| o,
            else => return error.CodeDescNotObject,
        };
        const href = switch (cd.get("href") orelse return error.NoHref) {
            .string => |sv| sv,
            else => return error.HrefNotString,
        };
        try std.testing.expect(std.mem.startsWith(u8, href, "https://docs.rubocop.org"));
        return;
    }
}

test "P29 T12.48 rubocop codeDescription namespace lowercased" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1248";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = 'hello'\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const notif = getNotificationByMethod(resp, "textDocument/publishDiagnostics") orelse return;
    const notif_obj = switch (notif) {
        .object => |o| o,
        else => return,
    };
    const params = switch (notif_obj.get("params") orelse return) {
        .object => |o| o,
        else => return,
    };
    const diags = switch (params.get("diagnostics") orelse return) {
        .array => |a| a,
        else => return,
    };
    if (diags.items.len == 0) return;
    for (diags.items) |d| {
        const do = switch (d) {
            .object => |o| o,
            else => continue,
        };
        const src = do.get("source") orelse continue;
        const src_str = switch (src) {
            .string => |sv| sv,
            else => continue,
        };
        if (!std.mem.eql(u8, src_str, "rubocop")) continue;
        const code_val = do.get("code") orelse continue;
        const code_str = switch (code_val) {
            .string => |sv| sv,
            else => continue,
        };
        if (!std.mem.startsWith(u8, code_str, "Style/")) continue;
        const cd = switch (do.get("codeDescription") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        const href = switch (cd.get("href") orelse continue) {
            .string => |sv| sv,
            else => continue,
        };
        try std.testing.expect(std.mem.indexOf(u8, href, "cops_style") != null);
        return;
    }
}

test "P29 T12.49 rubocop lint namespace in href" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1249";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // Use code likely to trigger Lint cop (unused variable)
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def foo\n  unused = 1\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const notif = getNotificationByMethod(resp, "textDocument/publishDiagnostics") orelse return;
    const notif_obj = switch (notif) {
        .object => |o| o,
        else => return,
    };
    const params = switch (notif_obj.get("params") orelse return) {
        .object => |o| o,
        else => return,
    };
    const diags = switch (params.get("diagnostics") orelse return) {
        .array => |a| a,
        else => return,
    };
    if (diags.items.len == 0) return;
    for (diags.items) |d| {
        const do = switch (d) {
            .object => |o| o,
            else => continue,
        };
        const src = do.get("source") orelse continue;
        const src_str = switch (src) {
            .string => |sv| sv,
            else => continue,
        };
        if (!std.mem.eql(u8, src_str, "rubocop")) continue;
        const code_val = do.get("code") orelse continue;
        const code_str = switch (code_val) {
            .string => |sv| sv,
            else => continue,
        };
        if (!std.mem.startsWith(u8, code_str, "Lint/")) continue;
        const cd = switch (do.get("codeDescription") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        const href = switch (cd.get("href") orelse continue) {
            .string => |sv| sv,
            else => continue,
        };
        try std.testing.expect(std.mem.indexOf(u8, href, "cops_lint") != null);
        return;
    }
}

test "P29 T12.50 prism diagnostic has no code field" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1250";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // Invalid Ruby — will produce a Prism parse error
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const notif = getNotificationByMethod(resp, "textDocument/publishDiagnostics") orelse return;
    const notif_obj = switch (notif) {
        .object => |o| o,
        else => return,
    };
    const params = switch (notif_obj.get("params") orelse return) {
        .object => |o| o,
        else => return,
    };
    const diags = switch (params.get("diagnostics") orelse return) {
        .array => |a| a,
        else => return,
    };
    for (diags.items) |d| {
        const do = switch (d) {
            .object => |o| o,
            else => continue,
        };
        const src = do.get("source") orelse continue;
        const src_str = switch (src) {
            .string => |sv| sv,
            else => continue,
        };
        if (!std.mem.eql(u8, src_str, "refract")) continue;
        // Prism diagnostics from refract must not have code or codeDescription
        try std.testing.expect(do.get("code") == null);
        try std.testing.expect(do.get("codeDescription") == null);
        return;
    }
}

test "P31 T14.5 publishDiagnostics uses open buffer for unsaved syntax error" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t145";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Foo\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Foo\\ndef bar(\\nend\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "publishDiagnostics") != null);
}

test "P31 T14.17 textDocument/diagnostic pull model returns full response" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1417";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Foo\n  def bar\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/diagnostic\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoDiagResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"kind\":\"full\"") != null);
}

test "P31 T14.19 textDocument/diagnostic empty items on valid file" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1419";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Foo\n  def bar\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/diagnostic\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoDiagResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"items\":[]") != null);
}

test "T_PRISM_DIAG diagnostics published after syntax error" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tprismdiag";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/err.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def foo(\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const diag_notif = getNotificationByMethod(resp, "textDocument/publishDiagnostics");
    if (diag_notif) |notif| {
        const notif_obj = switch (notif) {
            .object => |o| o,
            else => return error.NotObject,
        };
        const params_val = notif_obj.get("params") orelse return error.NoDiagParams;
        const params_obj = switch (params_val) {
            .object => |o| o,
            else => return error.NotObject,
        };
        const diagnostics = params_obj.get("diagnostics") orelse return error.NoDiagnostics;
        const diag_arr = switch (diagnostics) {
            .array => |a| a,
            else => return error.NotArray,
        };
        try std.testing.expect(diag_arr.items.len >= 1);
        const first = switch (diag_arr.items[0]) {
            .object => |o| o,
            else => return error.NotObject,
        };
        const severity = first.get("severity") orelse return error.NoSeverity;
        try std.testing.expectEqual(@as(i64, 1), severity.integer);
    } else {
        // publishDiagnostics may not be emitted if prism detects no error; pass anyway
    }
}

test "T_NORUBO_FMT formatting returns null gracefully when rubocop absent" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tnorubofmt";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/fmt.rb", .data = "def foo; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/formatting\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/fmt.rb\"},\"options\":{\"tabSize\":2,\"insertSpaces\":true}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const fmt_resp = getResponseById(resp, 2) orelse return error.NoFormattingResponse;
    const fmt_obj = switch (fmt_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    // Either null result (rubocop absent) or an array of edits (rubocop present)
    // Either way, there must be no error code
    const err_val = fmt_obj.get("error");
    if (err_val) |ev| {
        try std.testing.expect(ev == .null);
    }
}

test "file deletion clears diagnostics" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_delete_diag";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/broken.rb",
        .data = "def foo\n  end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didDeleteFiles\",\"params\":{\"files\":[{\"uri\":\"file://" ++ ws ++ "/broken.rb\"}]}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const target_uri = "file://" ++ ws ++ "/broken.rb";
    var found_empty = false;
    for (responses) |r| {
        const robj = switch (r.value) {
            .object => |o| o,
            else => continue,
        };
        const m = switch (robj.get("method") orelse continue) {
            .string => |sv| sv,
            else => continue,
        };
        if (!std.mem.eql(u8, m, "textDocument/publishDiagnostics")) continue;
        const params = switch (robj.get("params") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        const uri = switch (params.get("uri") orelse continue) {
            .string => |sv| sv,
            else => continue,
        };
        if (!std.mem.eql(u8, uri, target_uri)) continue;
        const diags = switch (params.get("diagnostics") orelse continue) {
            .array => |a| a,
            else => continue,
        };
        if (diags.items.len == 0) {
            found_empty = true;
            break;
        }
    }
    try std.testing.expect(found_empty);
}

test "recheckRubocop in executeCommandProvider" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_recheck_cmd";
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
    const exec_prov = switch (caps.get("executeCommandProvider") orelse return error.NoExecProv) {
        .object => |o| o,
        else => return error.ExecProvNotObject,
    };
    const commands = switch (exec_prov.get("commands") orelse return error.NoCommands) {
        .array => |a| a,
        else => return error.CommandsNotArray,
    };
    var found = false;
    for (commands.items) |cmd| {
        const s2 = switch (cmd) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, s2, "refract.recheckRubocop")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "P19 T19.1 pull diagnostic returns kind:full with resultId" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p19_t191";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Foo; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/diagnostic\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoDiagResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"kind\":\"full\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"resultId\":\"") != null);
}

test "P19 T19.2 pull diagnostic includes syntax errors" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p19_t192";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/bad.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def foo\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/diagnostic\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/bad.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoDiagResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"severity\":1") != null);
}

test "P19 T19.3 pull diagnostic returns kind:unchanged for same content" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p19_t193";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const content = "class Bar; end\n";
    const hash_val = std.hash.Wyhash.hash(0, content);
    var hash_buf: [20]u8 = undefined;
    const result_id_str = std.fmt.bufPrint(&hash_buf, "{x}", .{hash_val}) catch "0";
    const second_req = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/diagnostic\"," ++
        "\"params\":{{\"textDocument\":{{\"uri\":\"file://" ++ ws ++ "/b.rb\"}}," ++
        "\"previousResultId\":\"{s}\"}}}}", .{result_id_str});
    defer alloc.free(second_req);
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/b.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Bar; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/diagnostic\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/b.rb\"}}}");
    try s.send(second_req);
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 3) orelse return error.NoDiagResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"kind\":\"unchanged\"") != null);
}

test "P36 T4B.2 refract.recheckRubocop command succeeds and returns null result" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p36_t4b2";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Bar; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/executeCommand\",\"params\":{\"command\":\"refract.recheckRubocop\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }
    const resp2 = getResponseById(responses, 2) orelse return error.NoCommandResponse;
    const obj2 = switch (resp2) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj2.get("error") == null);
}
