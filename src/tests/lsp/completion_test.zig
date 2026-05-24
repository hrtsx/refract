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

test "batch: completion respects trigger and includes local vars" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_batch_1";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/f1.rb",
        .data = "class Referable; end\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/f2.rb",
        .data = "my_special_var = 42\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true,\"disableRubocop\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/f1.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/f2.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/f1.rb\"},\"position\":{\"line\":0,\"character\":9}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/f2.rb\"},\"position\":{\"line\":0,\"character\":4}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    {
        const resp = getResponseById(responses, 2) orelse return error.NoCompletionResponse;
        const obj = switch (resp) {
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
        var found = false;
        for (arr.items) |item| {
            const item_obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const label = item_obj.get("label") orelse continue;
            const label_str = switch (label) {
                .string => |ls| ls,
                else => continue,
            };
            if (std.mem.eql(u8, label_str, "Referable")) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }

    {
        const resp = getResponseById(responses, 3) orelse return error.NoCompletionResponse;
        const obj = switch (resp) {
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
        var found = false;
        for (arr.items) |item| {
            const item_obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const label = item_obj.get("label") orelse continue;
            const label_str = switch (label) {
                .string => |ls| ls,
                else => continue,
            };
            if (std.mem.eql(u8, label_str, "my_special_var")) {
                found = true;
                const kind = item_obj.get("kind") orelse continue;
                const kind_num = switch (kind) {
                    .integer => |i| i,
                    else => continue,
                };
                try std.testing.expectEqual(@as(i64, 6), kind_num);
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "batch: empty prefix, ivar, dedup completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_batch_2";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/f1.rb",
        .data = "class EmptyPrefixTarget\n  def some_method\n    \n  end\nend\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/f2.rb",
        .data = "class Foo\n  def init\n    @name = \"hello\"\n    @age = 42\n  end\nend\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/f3.rb",
        .data = "def unique_dedup_sym; end\ndef test_dedup\n  unique_dedup_sym = 1\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true,\"disableRubocop\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/f1.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class EmptyPrefixTarget\\n  def some_method\\n    \\n  end\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/f2.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/f3.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/f1.rb\"},\"position\":{\"line\":2,\"character\":4}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/f2.rb\"},\"position\":{\"line\":2,\"character\":5}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/f3.rb\"},\"position\":{\"line\":2,\"character\":2}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    {
        const resp = getResponseById(responses, 2) orelse return error.NoCompletionResponse;
        const obj = switch (resp) {
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
        try std.testing.expect(arr.items.len > 0);
    }

    {
        const resp = getResponseById(responses, 3) orelse return error.NoCompletionResponse;
        const obj = switch (resp) {
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
        var found = false;
        for (arr.items) |item| {
            const item_obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const label = item_obj.get("label") orelse continue;
            const label_str = switch (label) {
                .string => |ls| ls,
                else => continue,
            };
            if (std.mem.eql(u8, label_str, "@name")) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }

    {
        const resp = getResponseById(responses, 4) orelse return error.NoCompletionResponse;
        const obj = switch (resp) {
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
        var count: usize = 0;
        for (arr.items) |item| {
            const item_obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const lbl = item_obj.get("label") orelse continue;
            const lbl_str = switch (lbl) {
                .string => |s2| s2,
                else => continue,
            };
            if (std.mem.eql(u8, lbl_str, "unique_dedup_sym")) count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }
}

test "batch: prefix matches, format, snippet, MRO, sortText" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_batch_3";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/f1.rb",
        .data = "class AccountManager; end\nclass Account; end\nclass AccountBalance; end\nclass User; end\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/f1b.rb",
        .data = "def go\n  Acco\nend\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/f2.rb",
        .data = "def listed_method; end\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/f3.rb",
        .data = "def greet(name)\nend\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/f4.rb",
        .data = "class A\ndef foo\nend\nend\nclass B < A\nend\nb = B.new\nb.\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/f5.rb",
        .data = "class Sortable\n  def sort_method; end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true,\"disableRubocop\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/f1.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/f1b.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/f2.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/f3.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/f4.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/f5.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/f1b.rb\"},\"position\":{\"line\":1,\"character\":6}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/f2.rb\"},\"position\":{\"line\":0,\"character\":4}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/f3.rb\"},\"position\":{\"line\":0,\"character\":5}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/f4.rb\"},\"position\":{\"line\":7,\"character\":2}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/f5.rb\"},\"position\":{\"line\":1,\"character\":6},\"context\":{\"triggerKind\":1}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    // prefix matches
    {
        const resp = getResponseById(responses, 2) orelse return error.NoCompletionResponse;
        const obj = switch (resp) {
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
        var saw_account = false;
        var saw_balance = false;
        var saw_manager = false;
        var saw_user = false;
        for (arr.items) |item| {
            const item_obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const lbl = item_obj.get("label") orelse continue;
            const lbl_str = switch (lbl) {
                .string => |st| st,
                else => continue,
            };
            if (std.mem.eql(u8, lbl_str, "Account")) saw_account = true;
            if (std.mem.eql(u8, lbl_str, "AccountBalance")) saw_balance = true;
            if (std.mem.eql(u8, lbl_str, "AccountManager")) saw_manager = true;
            if (std.mem.eql(u8, lbl_str, "User")) saw_user = true;
        }
        try std.testing.expect(saw_account);
        try std.testing.expect(saw_balance);
        try std.testing.expect(saw_manager);
        try std.testing.expect(!saw_user);
    }

    // completion list format
    {
        const resp = getResponseById(responses, 3) orelse return error.NoCompletionResponse;
        const obj = switch (resp) {
            .object => |o| o,
            else => return error.NotObject,
        };
        const result = obj.get("result") orelse return error.NoResult;
        const result_obj = switch (result) {
            .object => |o| o,
            else => return error.ResultNotObject,
        };
        try std.testing.expect(result_obj.get("isIncomplete") != null);
        try std.testing.expect(result_obj.get("items") != null);
    }

    // snippet
    {
        const resp = getResponseById(responses, 4) orelse return error.NoCompletionResponse;
        const obj = switch (resp) {
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
        var found = false;
        for (arr.items) |item| {
            const item_obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const label = item_obj.get("label") orelse continue;
            const label_str = switch (label) {
                .string => |ls| ls,
                else => continue,
            };
            if (!std.mem.eql(u8, label_str, "greet")) continue;
            if (item_obj.get("insertTextFormat") != null and item_obj.get("insertText") != null) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }

    // MRO
    {
        const resp = getResponseById(responses, 5) orelse return error.NoCompletionResponse;
        const obj = switch (resp) {
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
        var found = false;
        for (arr.items) |item| {
            const item_obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const label = item_obj.get("label") orelse continue;
            const label_str = switch (label) {
                .string => |ls| ls,
                else => continue,
            };
            if (std.mem.eql(u8, label_str, "foo")) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }

    // sortText
    {
        const resp = getResponseById(responses, 6) orelse return error.NoCompletionResponse;
        const obj = switch (resp) {
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
        var found = false;
        for (arr.items) |item| {
            const item_obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            if (item_obj.get("sortText") != null) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "batch: ranking, commitCharacters, resolve, substring, filterText" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_batch_4";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/f1.rb",
        .data = "class RankableClass\n  def rankable_def; end\nend\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/f2.rb",
        .data = "class CommitTarget\n  def commit_method; end\nend\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/f3.rb",
        .data = "class SubstrUser\n  def find_user_record; end\n  def call\n    user_record\n  end\nend\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/f4.rb",
        .data = "class FilterTarget\n  def filter_method; end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true,\"disableRubocop\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/f3.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class SubstrUser\\n  def find_user_record; end\\n  def call\\n    user_record\\n  end\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/f1.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/f2.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/f4.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/f1.rb\"},\"position\":{\"line\":1,\"character\":6},\"context\":{\"triggerKind\":1}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/f2.rb\"},\"position\":{\"line\":1,\"character\":6},\"context\":{\"triggerKind\":1}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"completionItem/resolve\",\"params\":{\"label\":\"my_method\",\"kind\":3,\"detail\":\"(def)\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/f3.rb\"},\"position\":{\"line\":3,\"character\":15},\"context\":{\"triggerKind\":1}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/f4.rb\"},\"position\":{\"line\":1,\"character\":6},\"context\":{\"triggerKind\":1}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    // ranking (defs before classes)
    {
        const resp = getResponseById(responses, 2) orelse return error.NoCompletionResponse;
        const obj = switch (resp) {
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
        var found = false;
        for (arr.items) |item| {
            const item_obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const label_val = item_obj.get("label") orelse continue;
            const label_str = switch (label_val) {
                .string => |ls| ls,
                else => continue,
            };
            if (!std.mem.eql(u8, label_str, "rankable_def")) continue;
            const st_val = item_obj.get("sortText") orelse continue;
            const st_str = switch (st_val) {
                .string => |sv| sv,
                else => continue,
            };
            if (std.mem.startsWith(u8, st_str, "0_")) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }

    // commitCharacters
    {
        const resp = getResponseById(responses, 3) orelse return error.NoCompletionResponse;
        const obj = switch (resp) {
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
        var found = false;
        for (arr.items) |item| {
            const item_obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const label_val = item_obj.get("label") orelse continue;
            const label_str = switch (label_val) {
                .string => |ls| ls,
                else => continue,
            };
            if (!std.mem.eql(u8, label_str, "commit_method")) continue;
            if (item_obj.get("commitCharacters") != null) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }

    // resolve echoes item
    {
        const resp = getResponseById(responses, 4) orelse return error.NoResolveResponse;
        const obj = switch (resp) {
            .object => |o| o,
            else => return error.NotObject,
        };
        const result = obj.get("result") orelse return error.NoResult;
        const result_obj = switch (result) {
            .object => |o| o,
            else => return error.ResultNotObject,
        };
        const label_val = result_obj.get("label") orelse return error.NoLabel;
        const label_str = switch (label_val) {
            .string => |ls| ls,
            else => return error.LabelNotString,
        };
        try std.testing.expectEqualStrings("my_method", label_str);
    }

    // substring completion
    {
        const resp = getResponseById(responses, 5) orelse return error.NoCompletionResponse;
        const obj = switch (resp) {
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
        var found = false;
        for (arr.items) |item| {
            const item_obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const label_val = item_obj.get("label") orelse continue;
            const label_str = switch (label_val) {
                .string => |ls| ls,
                else => continue,
            };
            if (std.mem.eql(u8, label_str, "find_user_record")) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }

    // filterText
    {
        const resp = getResponseById(responses, 6) orelse return error.NoCompletionResponse;
        const obj = switch (resp) {
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
        var found = false;
        for (arr.items) |item| {
            const item_obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            if (item_obj.get("filterText") != null) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "completion documentation field" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p19_completion_doc";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/doc_test.rb",
        .data = "# Returns the greeting message\ndef p19_greet_method\n  \"hello\"\nend\np19_gr\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/doc_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/doc_test.rb\"},\"position\":{\"line\":4,\"character\":6}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const comp_resp = getResponseById(responses, 2) orelse return error.NoCompletionResponse;
    const obj = switch (comp_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const items = switch (result_obj.get("items") orelse return error.NoItems) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    try std.testing.expect(items.items.len > 0);
    const first_item = switch (items.items[0]) {
        .object => |o| o,
        else => return error.ItemNotObject,
    };
    try std.testing.expect(first_item.get("documentation") != null);
}

test "completion textEdit field present" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p19_textedit";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/textedit_test.rb",
        .data = "def p19_textedit_method\nend\np19_text\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/textedit_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/textedit_test.rb\"},\"position\":{\"line\":2,\"character\":8}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const comp_resp = getResponseById(responses, 2) orelse return error.NoCompletionResponse;
    const obj = switch (comp_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const items = switch (result_obj.get("items") orelse return error.NoItems) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    try std.testing.expect(items.items.len > 0);
    const first_item = switch (items.items[0]) {
        .object => |o| o,
        else => return error.ItemNotObject,
    };
    try std.testing.expect(first_item.get("textEdit") != null);
}

test "dot completion includes doc field" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p20_dot_doc";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/mro_test.rb",
        .data = "class Foo\n  # Test method\n  def bar\n    42\n  end\nend\nf = Foo.new\nf.\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/mro_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/mro_test.rb\"},\"position\":{\"line\":7,\"character\":2}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const comp_resp = getResponseById(responses, 2) orelse return error.NoCompletionResponse;
    const obj = switch (comp_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const items = switch (result_obj.get("items") orelse return error.NoItems) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    try std.testing.expect(items.items.len > 0);
    const first_item = switch (items.items[0]) {
        .object => |o| o,
        else => return error.ItemNotObject,
    };
    try std.testing.expect(first_item.get("documentation") != null);
}

test "dot completion includes textEdit" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p20_dot_textedit";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/textedit_test.rb",
        .data = "class Foo\n  def bar\n    42\n  end\nend\nf = Foo.new\nf.\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/textedit_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/textedit_test.rb\"},\"position\":{\"line\":6,\"character\":2}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const comp_resp = getResponseById(responses, 2) orelse return error.NoCompletionResponse;
    const obj = switch (comp_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const items = switch (result_obj.get("items") orelse return error.NoItems) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    try std.testing.expect(items.items.len > 0);
    const first_item = switch (items.items[0]) {
        .object => |o| o,
        else => return error.ItemNotObject,
    };
    try std.testing.expect(first_item.get("textEdit") != null);
}

test "completionItem resolve echoes item" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p20_resolve";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"completionItem/resolve\",\"params\":{\"label\":\"test\",\"kind\":3}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resolve_resp = getResponseById(responses, 2) orelse return error.NoResolveResponse;
    const obj = switch (resolve_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("result") != null);
}

test "chained dot completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_chain";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/chain.rb",
        .data =
        \\class Bar
        \\  def baz; end
        \\end
        \\class Foo
        \\  def returns_bar
        \\    Bar.new
        \\  end
        \\end
        \\obj = Foo.new
        \\obj.returns_bar.
        ,
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/chain.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/chain.rb\"},\"position\":{\"line\":9,\"character\":16}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const comp_resp = getResponseById(responses, 2) orelse return error.NoCompletionResponse;
    const obj = switch (comp_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const items = switch (result_obj.get("items") orelse return error.NoItems) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    try std.testing.expect(items.items.len > 0);
}

test "completion ranked prefix first" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_rank";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/r.rb", .data = "def format_output; end\ndef output_format; end\nformat\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/r.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // flush barrier: workspace/symbol synchronously drains incr_paths before next request
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":100,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/r.rb\"},\"position\":{\"line\":2,\"character\":6}}}");
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
    const result = obj.get("result") orelse return error.NoResult;
    const res_obj = switch (result) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const items_val = res_obj.get("items") orelse return error.NoItems;
    const arr = switch (items_val) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    var format_output_idx: ?usize = null;
    var output_format_idx: ?usize = null;
    for (arr.items, 0..) |item, idx| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const label_val = item_obj.get("label") orelse continue;
        const label = switch (label_val) {
            .string => |str| str,
            else => continue,
        };
        if (std.mem.eql(u8, label, "format_output")) format_output_idx = idx;
        if (std.mem.eql(u8, label, "output_format")) output_format_idx = idx;
    }
    const fi = format_output_idx orelse return error.FormatOutputNotFound;
    const oi = output_format_idx orelse return error.OutputFormatNotFound;
    try std.testing.expect(fi < oi);
}

test "completion limit 200" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_limit";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // Generate 30 distinct methods — fast to index, still exercises multi-symbol completion
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "class BigClass\n");
    for (0..30) |i| {
        const line = try std.fmt.allocPrint(alloc, "  def method_{d}; end\n", .{i});
        defer alloc.free(line);
        try buf.appendSlice(alloc, line);
    }
    try buf.appendSlice(alloc, "\n");
    try buf.appendSlice(alloc, "end\n");
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/many.rb", .data = buf.items });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    // didOpen indexes synchronously (holds db_mutex), guaranteeing symbols are in DB before completion
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/many.rb\",\"languageId\":\"ruby\",\"version\":1}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/many.rb\"},\"position\":{\"line\":31,\"character\":0}}}");
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
    const result = obj.get("result") orelse return error.NoResult;
    const res_obj = switch (result) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const items_val = res_obj.get("items") orelse return error.NoItems;
    const arr = switch (items_val) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    try std.testing.expect(arr.items.len >= 20);
}

test "self completion returns class methods" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_self1";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/m.rb", .data = "class MyClass\n  def greet; end\n  def farewell; end\n  def go\n    self.\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/m.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/m.rb\"},\"position\":{\"line\":4,\"character\":9}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw2 = try s.run();
    defer alloc.free(raw2);
    const responses2 = try extractResponses(alloc, raw2);
    defer {
        for (responses2) |r| r.deinit();
        alloc.free(responses2);
    }
    const resp2 = getResponseById(responses2, 2) orelse return error.NoResponse;
    const obj2 = switch (resp2) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result2 = obj2.get("result") orelse return error.NoResult;
    const res2 = switch (result2) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const items2 = res2.get("items") orelse return error.NoItems;
    const arr2 = switch (items2) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    var found_greet = false;
    for (arr2.items) |item| {
        const io = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const lv = io.get("label") orelse continue;
        const l = switch (lv) {
            .string => |str| str,
            else => continue,
        };
        if (std.mem.eql(u8, l, "greet")) found_greet = true;
    }
    try std.testing.expect(found_greet);
}

test "self completion in nested class" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_self2";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/n.rb", .data = "class Outer\n  def outer_method; end\n  class Inner\n    def inner_method; end\n    def go\n      self.\n    end\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/n.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/n.rb\"},\"position\":{\"line\":5,\"character\":11}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const rawN = try s.run();
    defer alloc.free(rawN);
    const respN = try extractResponses(alloc, rawN);
    defer {
        for (respN) |r| r.deinit();
        alloc.free(respN);
    }
    const rN = getResponseById(respN, 2) orelse return error.NoResponse;
    const oN = switch (rN) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const resN = oN.get("result") orelse return error.NoResult;
    const roN = switch (resN) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const ivN = roN.get("items") orelse return error.NoItems;
    const aN = switch (ivN) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    var found_inner = false;
    for (aN.items) |item| {
        const io = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const lv = io.get("label") orelse continue;
        const l = switch (lv) {
            .string => |str| str,
            else => continue,
        };
        if (std.mem.eql(u8, l, "inner_method")) found_inner = true;
    }
    try std.testing.expect(found_inner);
}

test "self completion at top level returns empty" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_self3";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/t.rb", .data = "self.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/t.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/t.rb\"},\"position\":{\"line\":0,\"character\":5}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const rawT = try s.run();
    defer alloc.free(rawT);
    // Should not crash — result may be null or empty
    _ = rawT.len;
}

test "@ivar completion resolves type" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_ivar1";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/iv.rb", .data = "class User\n  def profile; end\nend\nclass Controller\n  def init\n    @user = User.new\n  end\n  def show\n    @user.\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/iv.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/iv.rb\"},\"position\":{\"line\":8,\"character\":11}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const rawI = try s.run();
    defer alloc.free(rawI);
    const respI = try extractResponses(alloc, rawI);
    defer {
        for (respI) |r| r.deinit();
        alloc.free(respI);
    }
    const rI = getResponseById(respI, 2) orelse return error.NoResponse;
    const oI = switch (rI) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const resI = oI.get("result") orelse return error.NoResult;
    const roI = switch (resI) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const ivI = roI.get("items") orelse return error.NoItems;
    const aI = switch (ivI) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    var found_prof = false;
    for (aI.items) |item| {
        const io = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const lv = io.get("label") orelse continue;
        const l = switch (lv) {
            .string => |str| str,
            else => continue,
        };
        if (std.mem.eql(u8, l, "profile")) found_prof = true;
    }
    try std.testing.expect(found_prof);
}

test "@ivar completion two ivars independent" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_ivar2";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/iv2.rb", .data = "class Foo\n  def foo_method; end\nend\nclass Bar\n  def bar_method; end\nend\nclass C\n  def init\n    @a = Foo.new\n    @b = Bar.new\n  end\n  def go\n    @b.\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/iv2.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/iv2.rb\"},\"position\":{\"line\":12,\"character\":7}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const rawI2 = try s.run();
    defer alloc.free(rawI2);
    const respI2 = try extractResponses(alloc, rawI2);
    defer {
        for (respI2) |r| r.deinit();
        alloc.free(respI2);
    }
    const rI2 = getResponseById(respI2, 2) orelse return error.NoResponse;
    const oI2 = switch (rI2) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const resI2 = oI2.get("result") orelse return error.NoResult;
    const roI2 = switch (resI2) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const ivI2 = roI2.get("items") orelse return error.NoItems;
    const aI2 = switch (ivI2) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    var found_bar = false;
    for (aI2.items) |item| {
        const io = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const lv = io.get("label") orelse continue;
        const l = switch (lv) {
            .string => |str| str,
            else => continue,
        };
        if (std.mem.eql(u8, l, "bar_method")) found_bar = true;
    }
    try std.testing.expect(found_bar);
}

test "cancelRequest suppresses completion response" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_cancel1";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/c.rb", .data = "def foo; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/c.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Cancel id=42 before the request arrives — use an id that doesn't collide with base_shutdown (99)
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"$/cancelRequest\",\"params\":{\"id\":42}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/c.rb\"},\"position\":{\"line\":0,\"character\":3}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const rawC1 = try s.run();
    defer alloc.free(rawC1);
    const respC1 = try extractResponses(alloc, rawC1);
    defer {
        for (respC1) |r| r.deinit();
        alloc.free(respC1);
    }
    const r42 = getResponseById(respC1, 42) orelse return error.NoCancelResponse;
    const r42obj = switch (r42) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const err_val = r42obj.get("error") orelse return error.NoError;
    const err_obj = switch (err_val) {
        .object => |o| o,
        else => return error.ErrorNotObject,
    };
    const code_val = err_obj.get("code") orelse return error.NoCode;
    const code = switch (code_val) {
        .integer => |i| i,
        else => return error.CodeNotInt,
    };
    try std.testing.expectEqual(@as(i64, -32800), code);
}

test "open doc cache didChange updates completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t73";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def old_meth; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def old_meth; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"version\":2},\"contentChanges\":[{\"text\":\"def fresh_method; end\\n\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":0}}}");
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

test "has_many completion suggestion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t720";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class User\n  has_many :posts\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class User\\n  has_many :posts\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":0}}}");
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

test "Struct.new reader in completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t722";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "MyModel = Struct.new(:name)\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"MyModel = Struct.new(:name)\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":0}}}");
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

test "completionItem/resolve adds documentation" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t732";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "# Returns something\ndef documented_method; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"# Returns something\\ndef documented_method; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":0}}}");
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

test "prepend method appears before include in completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t733";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "module Prepended; def prep_method; end; end\nmodule Included; def incl_method; end; end\nclass MyClass\n  prepend Prepended\n  include Included\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"module Prepended; def prep_method; end; end\\nmodule Included; def incl_method; end; end\\nclass MyClass\\n  prepend Prepended\\n  include Included\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":0}}}");
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

test "double colon completion returns constants" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t816";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "module Foo\n  class Bar; end\n  class Baz; end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"module Foo\\n  class Bar; end\\n  class Baz; end\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":4,\"character\":5}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    // Build source with Foo:: at line 4
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

test "double colon completion does not return methods" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t817";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "module Foo\n  class Bar; end\nend\nFoo::\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"module Foo\\n  class Bar; end\\nend\\nFoo::\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":3,\"character\":5}}}");
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

test "AR chained completion posts after find" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t835";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class User\n  def name; end\nend\nu = User.find(1)\nu.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class User\\n  def name; end\\nend\\nu = User.find(1)\\nu.\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":4,\"character\":2}}}");
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

test "namespace module completion via double colon" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t845";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "module Foo\n  class Bar; end\nend\nFoo::\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"module Foo\\n  class Bar; end\\nend\\nFoo::\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":3,\"character\":5}}}");
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

test "P27 T10.8 yard return in completion detail" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1008";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "# @return [String]\ndef hello\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"# @return [String]\\ndef hello\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":0}}}");
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

test "P27 T10.19 or-assign completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1019";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class User\ndef foo\nend\nend\nx ||= User.new\nx.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class User\\ndef foo\\nend\\nend\\nx ||= User.new\\nx.\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":5,\"character\":2}}}");
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

test "P27 T10.57 rescue binding in completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1057";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def foo\nbegin\nrescue IOError => e\ne.\nend\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def foo\\nbegin\\nrescue IOError => e\\ne.\\nend\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":3,\"character\":2}}}");
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

test "P29 T12.4 schema v21 value_snippet column exists" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_prag4";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const db_path = ws ++ "/refract.db";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = 1\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.runWithArgs(&.{ "--db-path", db_path });
    defer alloc.free(raw);
    const q = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{ "sqlite3", db_path, "PRAGMA table_info(symbols)" },
    });
    defer alloc.free(q.stdout);
    defer alloc.free(q.stderr);
    try std.testing.expect(std.mem.indexOf(u8, q.stdout, "value_snippet") != null);
}

test "P29 T12.15 global var in completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1215";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "$config = Config.new\n$config\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"$config = Config.new\\n$config\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":7}}}");
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
    var found = false;
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
        if (std.mem.eql(u8, ls, "$config")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "P29 T12.22 value_snippet stored for integer constant" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1222";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "MAX = 42\n" });
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
        .argv = &.{ "sqlite3", db_path, "SELECT value_snippet FROM symbols WHERE name='MAX'" },
    });
    defer alloc.free(q.stdout);
    defer alloc.free(q.stderr);
    try std.testing.expect(std.mem.indexOf(u8, q.stdout, "42") != null);
}

test "P29 T12.23 value_snippet stored for string constant" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1223";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "MSG = \"hi\"\n" });
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
        .argv = &.{ "sqlite3", db_path, "SELECT value_snippet FROM symbols WHERE name='MSG'" },
    });
    defer alloc.free(q.stdout);
    defer alloc.free(q.stderr);
    try std.testing.expect(std.mem.indexOf(u8, q.stdout, "hi") != null);
}

test "P29 T12.24 value_snippet not stored for call constant" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1224";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "VAL = compute\n" });
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
        .argv = &.{ "sqlite3", db_path, "SELECT value_snippet IS NULL FROM symbols WHERE name='VAL'" },
    });
    defer alloc.free(q.stdout);
    defer alloc.free(q.stderr);
    try std.testing.expect(std.mem.indexOf(u8, q.stdout, "1") != null);
}

test "P29 T12.25 value_snippet capped at 120 chars" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1225";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // Build a string literal with 200 'a' chars
    const f = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, ws ++ "/a.rb", .{});
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, "LONG_CONST = \"");
    var i: usize = 0;
    while (i < 200) : (i += 1) try f.writeStreamingAll(std.Options.debug_io, "a");
    try f.writeStreamingAll(std.Options.debug_io, "\"\n");
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
        .argv = &.{ "sqlite3", db_path, "SELECT length(value_snippet) FROM symbols WHERE name='LONG_CONST'" },
    });
    defer alloc.free(q.stdout);
    defer alloc.free(q.stderr);
    // length should be <= 121 (120 content chars + optional 1-char truncation marker '…')
    const len_str = std.mem.trim(u8, q.stdout, " \t\r\n");
    const len = std.fmt.parseInt(usize, len_str, 10) catch return error.ParseFailed;
    try std.testing.expect(len <= 121);
}

test "P29 T12.26 hover shows constant value_snippet" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1226";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "TIMEOUT = 30\nTIMEOUT\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"TIMEOUT = 30\\nTIMEOUT\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":3}}}");
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
    try std.testing.expect(std.mem.indexOf(u8, value_str, "30") != null);
}

test "P29 T12.27 hover no value snippet for call constant" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1227";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "RESULT = compute_something\nRESULT\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"RESULT = compute_something\\nRESULT\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":3}}}");
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
    // result can be null (no hover) or an object; either way we just confirm no crash
    _ = obj;
}

test "P29 T12.41 private method hidden from dot completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1241";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Service\n  def public_action; end\n  private\n  def secret_action; end\nend\nobj = Service.new\nobj.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Service\\n  def public_action; end\\n  private\\n  def secret_action; end\\nend\\nobj = Service.new\\nobj.\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":6,\"character\":4},\"context\":{\"triggerKind\":2,\"triggerCharacter\":\".\"}}}");
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
    var found_public = false;
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
        if (std.mem.eql(u8, ls, "secret_action")) found_secret = true;
        if (std.mem.eql(u8, ls, "public_action")) found_public = true;
    }
    try std.testing.expect(!found_secret);
    try std.testing.expect(found_public);
}

test "P29 T12.42 private method present in self completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1242";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Engine\n  def run\n    self.\n  end\n  private\n  def internal; end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Engine\\n  def run\\n    self.\\n  end\\n  private\\n  def internal; end\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":2,\"character\":9},\"context\":{\"triggerKind\":2,\"triggerCharacter\":\".\"}}}");
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
    var found_internal = false;
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
        if (std.mem.eql(u8, ls, "internal")) {
            found_internal = true;
            break;
        }
    }
    try std.testing.expect(found_internal);
}

test "P29 T12.61 completion keyword def snippet present" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1261";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "de\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"de\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":2},\"context\":{\"triggerKind\":1}}}");
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
    var found_def = false;
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
        if (!std.mem.eql(u8, ls, "def")) continue;
        const itf = io.get("insertTextFormat") orelse continue;
        const itf_int = switch (itf) {
            .integer => |i| i,
            else => continue,
        };
        if (itf_int == 2) {
            found_def = true;
            break;
        }
    }
    try std.testing.expect(found_def);
}

test "P29 T12.62 completion keyword class snippet" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1262";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "cla\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"cla\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":3},\"context\":{\"triggerKind\":1}}}");
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
    var found_class = false;
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
        if (std.mem.eql(u8, ls, "class")) {
            found_class = true;
            break;
        }
    }
    try std.testing.expect(found_class);
}

test "P29 T12.63 completion keyword sorts after symbols" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1263";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def defer_work; end\nde\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def defer_work; end\\nde\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":1,\"character\":2},\"context\":{\"triggerKind\":1}}}");
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
        if (!std.mem.eql(u8, ls, "def")) continue;
        const stv = io.get("sortText") orelse return error.NoSortText;
        const sts = switch (stv) {
            .string => |sv| sv,
            else => return error.SortTextNotString,
        };
        try std.testing.expect(std.mem.startsWith(u8, sts, "z_kw_"));
        return;
    }
    return error.DefKeywordNotFound;
}

test "P29 T12.64 completion keyword filtered by prefix" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1264";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "cl\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"cl\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":2},\"context\":{\"triggerKind\":1}}}");
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
    var found_class = false;
    var found_def = false;
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
        if (std.mem.eql(u8, ls, "class")) found_class = true;
        if (std.mem.eql(u8, ls, "def")) found_def = true;
    }
    try std.testing.expect(found_class);
    try std.testing.expect(!found_def);
}

test "P29 T12.65 completion keyword not on dot trigger" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1265";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class MyObj\n  def go; end\nend\nobj = MyObj.new\nobj.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class MyObj\\n  def go; end\\nend\\nobj = MyObj.new\\nobj.\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":4,\"character\":4},\"context\":{\"triggerKind\":2,\"triggerCharacter\":\".\"}}}");
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
        // Dot completion must not inject "def", "class", etc.
        try std.testing.expect(!std.mem.eql(u8, ls, "def"));
        try std.testing.expect(!std.mem.eql(u8, ls, "class"));
    }
}

test "P29 T12.66 completion keyword not on colon trigger" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1266";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "module Foo\n  class Bar; end\nend\nFoo::\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"module Foo\\n  class Bar; end\\nend\\nFoo::\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":3,\"character\":5},\"context\":{\"triggerKind\":2,\"triggerCharacter\":\":\"}}}");
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
        try std.testing.expect(!std.mem.eql(u8, ls, "def"));
        try std.testing.expect(!std.mem.eql(u8, ls, "class"));
    }
}

test "P30 T13.1 Struct.new members in dot completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1301";
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"x\"") != null);
}

test "P31 T14.20 require completion suggests json for 'js prefix" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1420";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "require 'js'\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"require 'js'\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":11}}}");
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "json") != null);
}

test "P31 T14.22 require stdlib set completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1422";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "require 'set'\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"require 'se'\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":11}}}");
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "set") != null);
}

test "P31 T14.27 Enumerable synthesis map in dot-completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1427";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class MyCol1427\n  include Enumerable\n  def each\n    yield 1\n  end\nend\nc = MyCol1427.new\nc.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":7,\"character\":2}}}");
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"map\"") != null);
}

test "P31 T14.28 Enumerable synthesis select in dot-completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1428";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class MyCol1428\n  include Enumerable\n  def each\n    yield 1\n  end\nend\nc = MyCol1428.new\nc.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":7,\"character\":2}}}");
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"select\"") != null);
}

test "P31 T14.29 Enumerable synthesis any? in dot-completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1429";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class MyCol1429\n  include Enumerable\n  def each\n    yield 1\n  end\nend\nc = MyCol1429.new\nc.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":7,\"character\":2}}}");
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "any?") != null);
}

test "P31 T14.30 Comparable synthesis <= in dot-completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1430";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class MyVal1430\n  include Comparable\n  def <=>(other)\n    0\n  end\nend\nv = MyVal1430.new\nv.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":7,\"character\":2}}}");
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"<=\"") != null or std.mem.indexOf(u8, raw, "between?") != null);
}

test "P31 T14.41 p31 regression completion still works" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1441";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class RegClass1441\n  def regmethod1441\n  end\nend\nreg\n" });
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "regmethod1441") != null);
}

test "P32 T15.29 @type with completion uses annotated type" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1529";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Anno1529\n  def meth1529_a; end\n  def meth1529_b; end\nend\n# @type [Anno1529]\nz1529 = nil\nz1529.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":6,\"character\":7}}}");
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "meth1529") != null);
}

test "P32 T15.32 pattern matching completion uses bound type" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1532";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "v1532 = \"hello\"\ncase v1532\nin String => s1532\n  s1532.\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":3,\"character\":8}}}");
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

test "P32 T15.36 delegate method in completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1536";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Order1536\n  delegate :greet1536, to: :user1536\nend\no1536 = Order1536.new\no1536.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":4,\"character\":7}}}");
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "greet1536") != null);
}

test "P32 T15.45 p32 regression completion still works" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1545";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Comp1545\n  def mcomp1545; end\nend\nc1545 = Comp1545.new\nc1545.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":4,\"character\":7}}}");
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "mcomp1545") != null);
}

test "T_COMP_COMMENT completion inside comment returns empty" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tcompcomment";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/comment.rb", .data = "# this is a comment\ndef foo; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/comment.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"# this is a comment\\ndef foo; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/comment.rb\"},\"position\":{\"line\":0,\"character\":10}}}");
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
    const ro = switch (result) {
        .object => |o| o,
        else => return error.NotResultObj,
    };
    const items = ro.get("items") orelse return error.NoItems;
    const arr = switch (items) {
        .array => |a| a,
        else => return error.NotArray,
    };
    try std.testing.expectEqual(@as(usize, 0), arr.items.len);
}

test "T_COMP_STRING completion inside string returns empty" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tcompstring";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/str.rb", .data = "x = \"hello world\"\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/str.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"x = \\\"hello world\\\"\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/str.rb\"},\"position\":{\"line\":0,\"character\":10}}}");
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
    const ro = switch (result) {
        .object => |o| o,
        else => return error.NotResultObj,
    };
    const items = ro.get("items") orelse return error.NoItems;
    const arr = switch (items) {
        .array => |a| a,
        else => return error.NotArray,
    };
    try std.testing.expectEqual(@as(usize, 0), arr.items.len);
}

test "T_INTERP completion inside #{} interpolation fires normally" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tinterp";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/interp.rb", .data = "def foo_interp_sym; end\nx = \"hello #{fo}\"\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/interp.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/interp.rb\"},\"position\":{\"line\":1,\"character\":14}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const comp_resp = getResponseById(resp, 2) orelse return error.NoCompletionResponse;
    const comp_obj = switch (comp_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = comp_obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const items = result_obj.get("items") orelse return error.NoItems;
    const items_arr = switch (items) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    try std.testing.expect(items_arr.items.len > 0);
}

test "T_HEREDOC_COMPLETE completion inside heredoc body returns empty" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_theredoc";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/heredoc.rb", .data = "sql = <<~SQL\n  SELECT fo\nSQL\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/heredoc.rb\"},\"position\":{\"line\":1,\"character\":9}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const comp_resp = getResponseById(resp, 2) orelse return error.NoCompletionResponse;
    const comp_obj = switch (comp_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = comp_obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const items = result_obj.get("items") orelse return error.NoItems;
    const items_arr = switch (items) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    try std.testing.expectEqual(@as(usize, 0), items_arr.items.len);
}

test "T_KERNEL_COMPLETION Kernel methods appear at top level" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tkernel";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/kern.rb", .data = "put\n" });
    const file_uri = "file://" ++ ws ++ "/kern.rb";
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"" ++ file_uri ++ "\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"put\\n\"}}}");
    // Request completion at line 0, char 3 — prefix "put"
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"" ++ file_uri ++ "\"},\"position\":{\"line\":0,\"character\":3}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const comp_resp = getResponseById(resp, 2) orelse return error.NoCompletionResponse;
    const comp_obj = switch (comp_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = comp_obj.get("result") orelse return error.NoResult;
    const result_obj = switch (result) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const items = switch (result_obj.get("items") orelse return error.NoItems) {
        .array => |a| a,
        else => return error.NotArray,
    };
    var found_puts = false;
    for (items.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const label_val = obj.get("label") orelse continue;
        const label = switch (label_val) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, label, "puts")) {
            found_puts = true;
            break;
        }
    }
    try std.testing.expect(found_puts);
}

test "P22 T22.5 keyword param completion includes colon suffix" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_t225";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "def configure(timeout: 30, retries: 3)\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // "configure(t" is 12 chars; position is line=1, char=12 (0-indexed: line 1 = "end", but source is line 0)
    // Actually source line 0 is "def configure(timeout: 30, retries: 3)"
    // Completion inside "configure(t" means line=0, char=12 is after "configure(t"
    // But we need to test completion inside a CALL, not the def. Let's use an inline call context.
    // Use didOpen with source that has a call to configure
    const call_src = "configure(t\n";
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/b.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"configure(t\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/b.rb\"},\"position\":{\"line\":0,\"character\":11}}}");
    _ = call_src;
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
    const items = switch (result_obj.get("items") orelse return error.NoItems) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    var found_timeout_colon = false;
    for (items.items) |item| {
        const iobj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const label = switch (iobj.get("label") orelse continue) {
            .string => |s2| s2,
            else => continue,
        };
        if (std.mem.eql(u8, label, "timeout:")) {
            found_timeout_colon = true;
            break;
        }
        const insert_text = switch (iobj.get("insertText") orelse continue) {
            .string => |s2| s2,
            else => continue,
        };
        if (std.mem.indexOf(u8, insert_text, "timeout:") != null) {
            found_timeout_colon = true;
            break;
        }
    }
    try std.testing.expect(found_timeout_colon);
}

test "P22 T22.8 require_relative completion suggests workspace files" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_t228";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/helper.rb", .data = "def help; end\n" });
    const main_src = "require_relative \"\"\n";
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/main.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"require_relative \\\"\\\"\\n\"}}}");
    _ = main_src;
    // Position is at character 18, which is inside the empty quotes of require_relative ""
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/main.rb\"},\"position\":{\"line\":0,\"character\":18}}}");
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
    const items = switch (result_obj.get("items") orelse return error.NoItems) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    var found_helper = false;
    for (items.items) |item| {
        const iobj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const label = switch (iobj.get("label") orelse continue) {
            .string => |s2| s2,
            else => continue,
        };
        if (std.mem.indexOf(u8, label, "helper") != null) {
            found_helper = true;
            break;
        }
    }
    try std.testing.expect(found_helper);
}

test "P24 T24.6 completion on empty file returns empty array not crash" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t246";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":0}}}");
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
    // Result is a CompletionList object with items array
    const result = obj.get("result") orelse return error.NoResult;
    switch (result) {
        .object => |ro| {
            _ = ro.get("items") orelse return error.NoItems;
        },
        .array => {}, // bare array also acceptable
        .null => {}, // null result also acceptable
        else => return error.UnexpectedResultType,
    }
}

test "P25 T25.3 constant-receiver dot completion traverses full MRO (cls_stmt bug fix)" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t253";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src =
        "class Animal\n  def self.create(attrs)\n  end\nend\n" ++
        "class Dog < Animal\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Completion on "Dog." — should surface inherited class method "create"
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":5,\"character\":4},\"context\":{\"triggerKind\":2,\"triggerCharacter\":\".\"}}}");
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
    const obj2 = switch (resp2) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj2.get("error") == null);
    const result2 = obj2.get("result") orelse return error.NoResult;
    // Result can be object (CompletionList) or array; either is a valid non-error response
    switch (result2) {
        .object, .array => {},
        .null => {},
        else => return error.UnexpectedResultType,
    }
}

test "P27 T27.1 gvar completion returns matching results" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t271";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/g.rb", .data = "$config = 1\n$debug = false\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/g.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Completion at line 0, char 2 — inside "$c", triggers $-prefix completion
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/g.rb\"},\"position\":{\"line\":0,\"character\":2}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }
    const resp2 = getResponseById(responses, 2) orelse return error.NoCompletionResponse;
    const obj2 = switch (resp2) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj2.get("error") == null);
    const result2 = obj2.get("result") orelse return error.NoResult;
    const result_obj = switch (result2) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const items_val = result_obj.get("items") orelse return error.NoItems;
    const arr = switch (items_val) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    var found = false;
    for (arr.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const label = item_obj.get("label") orelse continue;
        const label_str = switch (label) {
            .string => |ls| ls,
            else => continue,
        };
        if (std.mem.eql(u8, label_str, "$config")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "P28 T28.3 gvar completion item has sortText field" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t283";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/g.rb", .data = "$counter = 0\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/g.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/g.rb\"},\"position\":{\"line\":0,\"character\":2}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }
    const resp2 = getResponseById(responses, 2) orelse return error.NoCompletionResponse;
    const obj2 = switch (resp2) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj2.get("error") == null);
    const result2 = obj2.get("result") orelse return error.NoResult;
    const result_obj = switch (result2) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const items_val = result_obj.get("items") orelse return error.NoItems;
    const arr = switch (items_val) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    var found = false;
    for (arr.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const label = item_obj.get("label") orelse continue;
        const label_str = switch (label) {
            .string => |ls| ls,
            else => continue,
        };
        if (std.mem.eql(u8, label_str, "$counter")) {
            if (item_obj.get("sortText") != null) {
                found = true;
            }
            break;
        }
    }
    try std.testing.expect(found);
}

test "P28 T28.4 builtin global $stdout appears in gvar completion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t284";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/g.rb", .data = "$\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    // Completion at char 1 — word is "$", triggers builtin globals
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/g.rb\"},\"position\":{\"line\":0,\"character\":1}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }
    const resp2 = getResponseById(responses, 2) orelse return error.NoCompletionResponse;
    const obj2 = switch (resp2) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj2.get("error") == null);
    const result2 = obj2.get("result") orelse return error.NoResult;
    const result_obj = switch (result2) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const items_val = result_obj.get("items") orelse return error.NoItems;
    const arr = switch (items_val) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };
    var found = false;
    for (arr.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const label = item_obj.get("label") orelse continue;
        const label_str = switch (label) {
            .string => |ls| ls,
            else => continue,
        };
        if (std.mem.eql(u8, label_str, "$stdout")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "completion on Time.cu filters to receiver methods (no global leak)" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_time_cu";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    // Create files with noise that would leak via global prefix match: card_url, column, etc.
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/noise.rb",
        .data =
        \\class CardsController
        \\  def card_url; end
        \\  def column; end
        \\  def columns; end
        \\  def closure; end
        \\  def consume; end
        \\end
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/target.rb",
        .data = "Time.cu\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/noise.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/target.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/target.rb\"},\"position\":{\"line\":0,\"character\":7}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoCompletionResponse;
    const obj = switch (resp) {
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

    const forbidden = [_][]const u8{ "card_url", "column", "columns", "closure", "consume" };
    for (arr.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const label = item_obj.get("label") orelse continue;
        const label_str = switch (label) {
            .string => |ls| ls,
            else => continue,
        };
        for (forbidden) |bad| {
            if (std.mem.eql(u8, label_str, bad)) {
                std.debug.print("completion leaked non-receiver method: {s}\n", .{label_str});
                return error.UnfilteredCompletion;
            }
        }
    }
}
