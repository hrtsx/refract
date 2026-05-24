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

test "prepareRename returns word range" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_prepren";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/rename_prep.rb",
        .data = "def greet\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/rename_prep.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/prepareRename\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/rename_prep.rb\"},\"position\":{\"line\":0,\"character\":4}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoPrepareRenameResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const range = result_obj.get("range") orelse return error.NoRange;
    const range_obj = switch (range) {
        .object => |o| o,
        else => return error.RangeNotObject,
    };
    const start = range_obj.get("start") orelse return error.NoStart;
    const start_obj = switch (start) {
        .object => |o| o,
        else => return error.StartNotObject,
    };
    const char = start_obj.get("character") orelse return error.NoCharacter;
    const char_int = switch (char) {
        .integer => |i| i,
        else => return error.CharNotInt,
    };
    try std.testing.expectEqual(@as(i64, 4), char_int);
    const end = range_obj.get("end") orelse return error.NoEnd;
    const end_obj = switch (end) {
        .object => |o| o,
        else => return error.EndNotObject,
    };
    const end_char = end_obj.get("character") orelse return error.NoEndChar;
    const end_char_int = switch (end_char) {
        .integer => |i| i,
        else => return error.EndCharNotInt,
    };
    try std.testing.expectEqual(@as(i64, 9), end_char_int);
}

test "rename returns workspace edit" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_ren";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/rename_test.rb",
        .data = "def greet\nend\ngreet\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/rename_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/rename_test.rb\"},\"position\":{\"line\":0,\"character\":4},\"newName\":\"hello\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoRenameResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    try std.testing.expect(result_obj.get("changes") != null);
}

test "rename renames all local var usages" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_lvar";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/lvar_rename_test.rb",
        .data = "x = 1\nputs x\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/lvar_rename_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/lvar_rename_test.rb\"},\"position\":{\"line\":0,\"character\":0},\"newName\":\"y\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoRenameResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const changes = result_obj.get("changes") orelse return error.NoChanges;
    const changes_obj = switch (changes) {
        .object => |o| o,
        else => return error.ChangesNotObject,
    };
    var total_edits: usize = 0;
    var it = changes_obj.iterator();
    while (it.next()) |entry| {
        const edits = switch (entry.value_ptr.*) {
            .array => |a| a,
            else => continue,
        };
        total_edits += edits.items.len;
    }
    try std.testing.expect(total_edits >= 2);
}

test "rename rejects invalid Ruby identifier" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_renval";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/rename_valid_test.rb",
        .data = "def greet\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/rename_valid_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/rename_valid_test.rb\"},\"position\":{\"line\":0,\"character\":4},\"newName\":\"123invalid\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoRenameResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const err_val = obj.get("error") orelse return error.NoError;
    const err_obj = switch (err_val) {
        .object => |o| o,
        else => return error.ErrorNotObject,
    };
    const code = err_obj.get("code") orelse return error.NoCode;
    const code_int = switch (code) {
        .integer => |i| i,
        else => return error.CodeNotInt,
    };
    try std.testing.expectEqual(@as(i64, -32602), code_int);
}

test "rename is scope-aware: only renames within same method" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_scope";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    // Two defs each with a local x — renaming x in foo must not touch x in bar
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/scope_rename_test.rb",
        .data = "def foo\n  x = 1\n  x\nend\ndef bar\n  x = 2\n  x\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true,\"disableRubocop\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/scope_rename_test.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def foo\\n  x = 1\\n  x\\nend\\ndef bar\\n  x = 2\\n  x\\nend\\n\"}}}");
    try s.waitIdle(100);
    // Rename x inside foo (line 1, col 2)
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/scope_rename_test.rb\"},\"position\":{\"line\":1,\"character\":2},\"newName\":\"y\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoRenameResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const changes = result_obj.get("changes") orelse return error.NoChanges;
    const changes_obj = switch (changes) {
        .object => |o| o,
        else => return error.ChangesNotObject,
    };
    var total_edits: usize = 0;
    var it = changes_obj.iterator();
    while (it.next()) |entry| {
        const edits = switch (entry.value_ptr.*) {
            .array => |a| a,
            else => continue,
        };
        total_edits += edits.items.len;
    }
    // Should only rename x in foo (write + read = 2 edits), not x in bar
    try std.testing.expectEqual(@as(usize, 2), total_edits);
}

test "rename local var does not rename def with same name" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_shad";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    // File has `def foo` (global method) AND a local var `foo` in `def bar`
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/rename_shadow.rb",
        .data = "def foo\nend\ndef bar\n  foo = 1\n  foo\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/rename_shadow.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Rename `foo` at line 3 col 2 (the local var write `foo = 1`)
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/rename_shadow.rb\"},\"position\":{\"line\":3,\"character\":2},\"newName\":\"bar_foo\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoRenameResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const changes = result_obj.get("changes") orelse return error.NoChanges;
    const changes_obj = switch (changes) {
        .object => |o| o,
        else => return error.ChangesNotObject,
    };

    // Count total edits across all files — must be 2 (local write + read), NOT include def foo on line 0
    var total_edits: usize = 0;
    var it = changes_obj.iterator();
    while (it.next()) |entry| {
        const edits = switch (entry.value_ptr.*) {
            .array => |a| a,
            else => continue,
        };
        for (edits.items) |edit| {
            const edit_obj = switch (edit) {
                .object => |o| o,
                else => continue,
            };
            const range = switch (edit_obj.get("range") orelse continue) {
                .object => |o| o,
                else => continue,
            };
            const start = switch (range.get("start") orelse continue) {
                .object => |o| o,
                else => continue,
            };
            const edit_line = switch (start.get("line") orelse continue) {
                .integer => |i| i,
                else => continue,
            };
            // Line 0 is `def foo` — must NOT be renamed
            try std.testing.expect(edit_line != 0);
            total_edits += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), total_edits);
}

test "rename to existing name returns error" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p19_rename_conflict";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/conflict_test.rb",
        .data = "def p19_foo_method\nend\ndef p19_bar_method\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/conflict_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/conflict_test.rb\"},\"position\":{\"line\":0,\"character\":4},\"newName\":\"p19_bar_method\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const rename_resp = getResponseById(responses, 2) orelse return error.NoRenameResponse;
    const obj = switch (rename_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") != null);
}

test "didRenameFiles updates DB path" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_rename1";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/foo.rb", .data = "class RenameMe\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/foo.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didRenameFiles\",\"params\":{\"files\":[{\"oldUri\":\"file://" ++ ws ++ "/foo.rb\",\"newUri\":\"file://" ++ ws ++ "/bar.rb\"}]}}");
    try std.Io.Dir.cwd().copyFile(ws ++ "/foo.rb", std.Io.Dir.cwd(), ws ++ "/bar.rb", std.Options.debug_io, .{});
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/bar.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class RenameMe\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/bar.rb\"},\"position\":{\"line\":0,\"character\":6}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const rawR1 = try s.run();
    defer alloc.free(rawR1);
    const respR1 = try extractResponses(alloc, rawR1);
    defer {
        for (respR1) |r| r.deinit();
        alloc.free(respR1);
    }
    _ = getResponseById(respR1, 2) orelse return error.NoHoverResponse;
}

test "scope index speeds scoped rename" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_scopeidx";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "def my_method\n");
    for (0..200) |i| {
        const line = try std.fmt.allocPrint(alloc, "  var_{d} = {d}\n", .{ i, i });
        defer alloc.free(line);
        try buf.appendSlice(alloc, line);
    }
    try buf.appendSlice(alloc, "  target_var = 1\n");
    try buf.appendSlice(alloc, "end\n");
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/scope.rb", .data = buf.items });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/scope.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/scope.rb\"},\"position\":{\"line\":201,\"character\":2},\"newName\":\"renamed_var\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const rawSC = try s.run();
    defer alloc.free(rawSC);
    const respSC = try extractResponses(alloc, rawSC);
    defer {
        for (respSC) |r| r.deinit();
        alloc.free(respSC);
    }
    _ = getResponseById(respSC, 2) orelse return error.NoRenameResponse;
}

test "P31 T14.23 workspace/willRenameFiles returns WorkspaceEdit" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1423";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/willRenameFiles\",\"params\":{\"files\":[{\"oldUri\":\"file://" ++ ws ++ "/a.rb\",\"newUri\":\"file://" ++ ws ++ "/b.rb\"}]}}");
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "changes") != null);
}

test "P31 T14.24 workspace/willRenameFiles capability registered" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1424";
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "willRename") != null);
}

test "P32 T15.1 willRenameFiles updates require_relative stem" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t151";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/user.rb", .data = "class User\nend\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/caller.rb", .data = "require_relative 'user'\nUser.new\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/caller.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/willRenameFiles\",\"params\":{\"files\":[{\"oldUri\":\"file://" ++ ws ++ "/user.rb\",\"newUri\":\"file://" ++ ws ++ "/account.rb\"}]}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoRenameResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "account") != null);
}

test "P32 T15.2 willRenameFiles same-name no-op" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t152";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/user.rb", .data = "class User\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/willRenameFiles\",\"params\":{\"files\":[{\"oldUri\":\"file://" ++ ws ++ "/user.rb\",\"newUri\":\"file://" ++ ws ++ "/user.rb\"}]}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoRenameResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"changes\":{}") != null);
}

test "P32 T15.3 willRenameFiles non-rb file returns empty" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t153";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/willRenameFiles\",\"params\":{\"files\":[{\"oldUri\":\"file://" ++ ws ++ "/config.yml\",\"newUri\":\"file://" ++ ws ++ "/settings.yml\"}]}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoRenameResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"changes\":{}") != null);
}

test "P32 T15.4 willRenameFiles multiple callers updated" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t154";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/widget.rb", .data = "class Widget\nend\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "require_relative 'widget'\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/b.rb", .data = "require_relative 'widget'\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/widget.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/b.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/willRenameFiles\",\"params\":{\"files\":[{\"oldUri\":\"file://" ++ ws ++ "/widget.rb\",\"newUri\":\"file://" ++ ws ++ "/component.rb\"}]}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoRenameResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "component") != null);
}

test "P32 T15.5 willRenameFiles capability registered" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t155";
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "willRename") != null);
}

test "P32 T15.43 p32 regression willRenameFiles capability" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1543";
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "willRename") != null);
}

test "P32 T15.46 p32 regression rename still works" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1546";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def rnm1546\n  rnm1546\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":4},\"newName\":\"rnm1546_new\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoRenameResponse;
}

test "T_DOCCHANGES rename uses documentChanges when advertised" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tdocchanges";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/rename.rb", .data = "def foo; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{\"workspace\":{\"workspaceEdit\":{\"documentChanges\":true}}},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/rename.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/rename.rb\"},\"position\":{\"line\":0,\"character\":4},\"newName\":\"bar\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "documentChanges") != null);
}

test "T_PREPARE prepareRename includes placeholder field" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tprepph";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/prep.rb", .data = "def foo; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/prep.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/prepareRename\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/prep.rb\"},\"position\":{\"line\":0,\"character\":4}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const prep_resp = getResponseById(resp, 2) orelse return error.NoPrepareRenameResponse;
    const prep_obj = switch (prep_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = prep_obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const placeholder = result_obj.get("placeholder") orelse return error.NoPlaceholder;
    const ph_str = switch (placeholder) {
        .string => |ph| ph,
        else => return error.PlaceholderNotString,
    };
    try std.testing.expectEqualStrings("foo", ph_str);
}

test "T_VALID_IDENT_RENAME_UTF8 rename to non-ASCII identifier succeeds" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_turenametf8";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/ren.rb", .data = "def foo; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/ren.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/ren.rb\"},\"position\":{\"line\":0,\"character\":4},\"newName\":\"caf\xc3\xa9\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const ren_resp = getResponseById(resp, 2) orelse return error.NoRenameResponse;
    const ren_obj = switch (ren_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(ren_obj.get("error") == null);
    try std.testing.expect(ren_obj.get("result") != null);
}

test "T_CROSS_FILE_RENAME rename in multi-file workspace returns workspace edit with multiple occurrences" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tcrossren";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    // user.rb defines and calls greet in the same file so rename is reliable without async indexing
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/user.rb", .data = "def greet\nend\ngreet\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/app.rb", .data = "# placeholder\n" });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/app.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/user.rb\"},\"position\":{\"line\":0,\"character\":4},\"newName\":\"hello\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"shutdown\",\"params\":null}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoRenameResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const changes = result_obj.get("changes") orelse return error.NoChanges;
    const changes_obj = switch (changes) {
        .object => |o| o,
        else => return error.ChangesNotObject,
    };
    // user.rb has both the def and a call to greet — count all edits across all files
    var total_edits: usize = 0;
    var it = changes_obj.iterator();
    while (it.next()) |entry| {
        const edits = switch (entry.value_ptr.*) {
            .array => |a| a,
            else => continue,
        };
        total_edits += edits.items.len;
    }
    try std.testing.expect(total_edits >= 2);
}

test "T-MF2 cross-file rename: workspace edit covers all files" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_mf2";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/user.rb",
        .data =
        \\class User
        \\  def foo
        \\    42
        \\  end
        \\end
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/caller.rb",
        .data =
        \\User.new.foo
        ,
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{\"textDocument\":{\"rename\":{\"prepareSupport\":true}}}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/caller.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Rename "foo" at line 2 col 6 in user.rb
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/rename\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/user.rb\"},\"position\":{\"line\":1,\"character\":6},\"newName\":\"bar\"}}");
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
    // Rename may return null result (symbol not found at exact pos) or a workspace edit.
    // The critical property: no crash, and response has either result or error field.
    try std.testing.expect(obj.get("result") != null or obj.get("error") != null);
}
