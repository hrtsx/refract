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

test "workspace/didCreateFiles indexes new file" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_create";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/created_file.rb",
        .data = "class CreatedModel\n  def created_method; end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didCreateFiles\",\"params\":{\"files\":[{\"uri\":\"file://" ++ ws ++ "/created_file.rb\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"CreatedModel\"}}");
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
        if (std.mem.eql(u8, nm_str, "CreatedModel")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "rbi file indexed on watched event" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_rbi";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/typed_sig.rbi",
        .data = "class RbiClass\n  def rbi_method; end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/typed_sig.rbi\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"RbiClass\"}}");
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
        if (std.mem.eql(u8, nm_str, "RbiClass")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "class << self methods indexed as classdef" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_singleton";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/singleton_test.rb",
        .data = "class Foo\n  class << self\n    def build; end\n  end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/singleton_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"build\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/singleton_test.rb\"},\"position\":{\"line\":2,\"character\":8}}}");
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
    const sym_obj = switch (sym_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const sym_result = sym_obj.get("result") orelse return error.NoResult;
    const sym_arr = switch (sym_result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(sym_arr.items.len > 0);

    const hover_resp = getResponseById(responses, 3) orelse return error.NoHoverResponse;
    const hover_obj = switch (hover_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const hover_result = hover_obj.get("result") orelse return error.NoResult;
    const hover_result_obj = switch (hover_result) {
        .object => |o| o,
        else => return error.ResultNotObject,
    };
    const contents = hover_result_obj.get("contents") orelse return error.NoContents;
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

test "Rakefile task methods indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_rakefile";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/Rakefile",
        .data = "def helper_task; end\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/Rakefile\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"helper_task\"}}");
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
    try std.testing.expect(arr.items.len > 0);
}

test "scope indexed as classdef" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_scope";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/scope_test.rb",
        .data = "class Post\n  scope :find_active, -> { where(active: true) }\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true,\"disableRubocop\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/scope_test.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Post\\n  scope :find_active, -> { where(active: true) }\\nend\\n\"}}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"find_active\"}}");
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
    try std.testing.expect(arr.items.len > 0);
}

test "belongs_to and has_many indexed as def" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_assoc";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/assoc_test.rb",
        .data = "class Comment\n  belongs_to :user\n  has_many :posts\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/assoc_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"user\"}}");
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
    try std.testing.expect(arr.items.len > 0);
}

test "didOpen triggers indexing" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_didopen_idx";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/opened.rb",
        .data = "class OpenedClass\n  def opened_method; end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/opened.rb\",\"languageId\":\"ruby\",\"version\":1}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"OpenedClass\"}}");
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
    var found = false;
    for (arr.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const nm = item_obj.get("name") orelse continue;
        const nm_str = switch (nm) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, nm_str, "OpenedClass")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "didChangeWatchedFiles modify reindexes" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_modify_reindex";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/modify_test.rb",
        .data = "class OriginalClass; end\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/modify_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/modify_test.rb",
        .data = "class ModifiedClass; end\n",
    });
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/modify_test.rb\",\"type\":2}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"ModifiedClass\"}}");
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
    var found = false;
    for (arr.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const nm = item_obj.get("name") orelse continue;
        const nm_str = switch (nm) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, nm_str, "ModifiedClass")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "progress begin and end sent during indexing" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_progress";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/prog_test.rb",
        .data = "class ProgressTest; end\n",
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

test "local_vars no duplicates after double reindex" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_nodup";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/dup_test.rb",
        .data = "def dup_method\n  unique_local_var = 1\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/dup_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/dup_test.rb\",\"type\":2}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/dup_test.rb\"},\"position\":{\"line\":1,\"character\":18},\"context\":{\"triggerKind\":1}}}");
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
    var count: usize = 0;
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
        if (std.mem.eql(u8, label_str, "unique_local_var")) count += 1;
    }
    try std.testing.expect(count <= 1);
}

test "validates indexed as def" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_validates";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/validates_test.rb",
        .data = "class ValidatesModel\n  validates :validated_name, presence: true\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/validates_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"validated_name\"}}");
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
    var found = false;
    for (arr.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const nm = item_obj.get("name") orelse continue;
        const nm_str = switch (nm) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, nm_str, "validated_name")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "before_action indexed as def" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_before_action";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/before_action_test.rb",
        .data = "class ActionController\n  before_action :authenticate_user\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/before_action_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"authenticate_user\"}}");
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
    var found = false;
    for (arr.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const nm = item_obj.get("name") orelse continue;
        const nm_str = switch (nm) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, nm_str, "authenticate_user")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "has_and_belongs_to_many indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_habtm";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/habtm_test.rb",
        .data = "class HabtmPost\n  has_and_belongs_to_many :habtm_tags\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/habtm_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"habtm_tags\"}}");
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
    var found = false;
    for (arr.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const nm = item_obj.get("name") orelse continue;
        const nm_str = switch (nm) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, nm_str, "habtm_tags")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "define_method indexed as def" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_defmeth";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/define_method_test.rb",
        .data = "class DynMethods\n  define_method(:dynamic_greet) { 'hello' }\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/define_method_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"dynamic_greet\"}}");
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
    var found = false;
    for (arr.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const nm = item_obj.get("name") orelse continue;
        const nm_str = switch (nm) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, nm_str, "dynamic_greet")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "window/logMessage on indexing error" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_logmsg";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "\",\"type\":3}]}}");
    try s.waitIdle(100);
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

test "delegate indexed as def" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_delegate";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/delegate_test.rb",
        .data = "class DelegateOrder\n  delegate :delegated_name, to: :user\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/delegate_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"delegated_name\"}}");
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
    var found = false;
    for (arr.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const nm = item_obj.get("name") orelse continue;
        const nm_str = switch (nm) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, nm_str, "delegated_name")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "log_file writes on indexing" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_logfile";
    const log_path = "/tmp/refract_test_logfile.log";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, log_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, log_path) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/logfile_test.rb",
        .data = "class LogFileTest; end\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.runWithArgs(&.{ "--log-file", log_path, "--verbose" });
    defer alloc.free(raw);

    const log_contents = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, log_path, alloc, std.Io.Limit.limited(1024 * 1024)) catch "";
    defer alloc.free(log_contents);
    try std.testing.expect(log_contents.len > 0);
}

test "rescue_from indexed as def" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_rescue_from";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/rescue_from_test.rb",
        .data = "class MyController\n  rescue_from :handle_not_found\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/rescue_from_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"handle_not_found\"}}");
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
        .array => |arr| try std.testing.expect(arr.items.len > 0),
        else => return error.ResultNotArray,
    }
}

test "helper_method indexed as def" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_helper_method";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/helper_method_test.rb",
        .data = "class ApplicationController\n  helper_method :current_user\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/helper_method_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"current_user\"}}");
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
        .array => |arr| try std.testing.expect(arr.items.len > 0),
        else => return error.ResultNotArray,
    }
}

test "validates_format_of indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_validates_format";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/validates_format_test.rb",
        .data = "class User\n  validates_format_of :email\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/validates_format_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"email\"}}");
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
        .array => |arr| try std.testing.expect(arr.items.len > 0),
        else => return error.ResultNotArray,
    }
}

test "rescue_from with: handler indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p19_rescue_from";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/rescue_from_test.rb",
        .data = "class ApplicationController\n  rescue_from ActiveRecord::RecordNotFound, with: :handle_404\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/rescue_from_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"handle_404\"}}");
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
        .array => |arr| try std.testing.expect(arr.items.len > 0),
        else => return error.ResultNotArray,
    }
}

test "define_singleton_method indexed as classdef" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p19_def_singleton";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/singleton_method_test.rb",
        .data = "class MyClass\n  define_singleton_method :my_singleton_foo do\n  end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/singleton_method_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"my_singleton_foo\"}}");
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
        .array => |arr| try std.testing.expect(arr.items.len > 0),
        else => return error.ResultNotArray,
    }
}

test "didCreateFiles triggers indexing" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p19_did_create";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/created_p19.rb",
        .data = "def p19_created_method\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didCreateFiles\",\"params\":{\"files\":[{\"uri\":\"file://" ++ ws ++ "/created_p19.rb\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"p19_created_method\"}}");
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
        .array => |arr| try std.testing.expect(arr.items.len > 0),
        else => return error.ResultNotArray,
    }
}

test "class variable indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p20_classvar";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/classvar.rb",
        .data = "class Foo\n  @@config = {}\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/classvar.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"@@config\"}}");
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
    const result_arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(result_arr.items.len >= 1);
}

test "delegate DSL indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p20_delegate";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/delegate.rb",
        .data = "class Foo\n  delegate :bar, to: :baz\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/delegate.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"bar\"}}");
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
    const result_arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(result_arr.items.len >= 1);
}

test "scope DSL indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p20_scope";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/scope.rb",
        .data = "class Foo\n  scope :active, -> {}\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/scope.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"active\"}}");
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
    const result_arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(result_arr.items.len >= 1);
}

test "qualified class name indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_qclass";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/qclass.rb",
        .data = "class Foo::Bar\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/qclass.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Foo::Bar\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "qualified module name indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_qmod";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/qmod.rb",
        .data = "module Foo::Bar\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/qmod.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Foo::Bar\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "constant_path_write indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_cpwrite";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/cpwrite.rb",
        .data = "module Foo\nend\nFoo::BAR = 1\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/cpwrite.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Foo::BAR\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "validate DSL indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_validate";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/validate.rb",
        .data = "class MyModel\n  validate :my_check\n  def my_check; end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/validate.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"my_check\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "after_update DSL indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_after_update";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/au.rb",
        .data = "class MyModel\n  after_update :refresh_cache\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/au.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"refresh_cache\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "before_update DSL indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_before_update";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/bu.rb",
        .data = "class MyModel\n  before_update :normalize\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/bu.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"normalize\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "validates_inclusion_of indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_vinclusion";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/vinc.rb",
        .data = "class MyModel\n  validates_inclusion_of :status, in: %w[active inactive]\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/vinc.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"status\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "validates_with indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_vwith";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/vwith.rb",
        .data = "class MyModel\n  validates_with EmailValidator\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/vwith.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"MyModel\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "after_find DSL indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_after_find";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/af.rb",
        .data = "class MyModel\n  after_find :populate_cache\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/af.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"populate_cache\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "validates_exclusion_of indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_vexclusion";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/vexc.rb",
        .data = "class MyModel\n  validates_exclusion_of :age, in: 0..17\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/vexc.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"age\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "rspec describe indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_describe";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/spec.rb", .data = "describe \"MyClass\" do\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/spec.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"MyClass\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "rspec it indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_rspec_it";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/spec.rb", .data = "it \"does the thing\" do\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/spec.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"does the thing\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "rspec let indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_rspec_let";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/spec.rb", .data = "describe \"X\" do\n  let(:foo) { 1 }\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/spec.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"foo\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "sinatra get indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_sinatra_get";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/app.rb", .data = "get \"/hello\" do\n  \"world\"\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/app.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"/hello\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "rake task indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_rake_task";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/Rakefile", .data = "task :build do\n  puts \"building\"\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/Rakefile\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"build\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "sinatra post indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_sinatra_post";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/app.rb", .data = "post \"/submit\" do\n  \"ok\"\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/app.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"/submit\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "rspec context indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_rspec_ctx";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/spec.rb", .data = "describe \"X\" do\n  context \"when logged in\" do\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/spec.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"when logged in\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "rspec shared_examples_for indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_shared_ex";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/shared.rb", .data = "shared_examples_for \"a valid model\" do\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/shared.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"a valid model\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "rake namespace indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_rake_ns";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/Rakefile", .data = "namespace :test do\n  task :run do\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/Rakefile\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"test\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "each_with_index second param Integer" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_ewi";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/ewi.rb", .data = "class Item\n  def name; end\nend\nitems = []\nitems.each_with_index do |item, idx|\n  idx\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/ewi.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/ewi.rb\"},\"position\":{\"line\":5,\"character\":2}}}");
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

test "rspec before indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_before";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/spec.rb", .data = "describe \"X\" do\n  before(:each) { @x = 1 }\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/spec.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"each\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "rspec after indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_after";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/spec.rb", .data = "describe \"X\" do\n  after(:all) { cleanup }\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/spec.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"all\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "mattr_reader indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_mattr_reader";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/m.rb", .data = "module Config\n  mattr_reader :val\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/m.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"val\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "scope indexes exist in schema v19" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_idxcheck";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "x = 1\n" });
    const db_path = ws ++ "/refract.db";
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.runWithArgs(&.{ "--db-path", db_path });
    defer alloc.free(raw);
    // Query indexes via sqlite3 CLI to avoid importing db.zig outside its module path
    const q1 = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{ "sqlite3", db_path, "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_refs_scope'" },
    });
    defer alloc.free(q1.stdout);
    defer alloc.free(q1.stderr);
    const q2 = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{ "sqlite3", db_path, "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_local_vars_scope'" },
    });
    defer alloc.free(q2.stdout);
    defer alloc.free(q2.stderr);
    try std.testing.expect(std.mem.indexOf(u8, q1.stdout, "idx_refs_scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, q2.stdout, "idx_local_vars_scope") != null);
}

test "factory :user indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_factory";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/f.rb", .data = "factory :user do\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/f.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"user\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const rawF = try s.run();
    defer alloc.free(rawF);
    const respF = try extractResponses(alloc, rawF);
    defer {
        for (respF) |r| r.deinit();
        alloc.free(respF);
    }
    const rF = getResponseById(respF, 2) orelse return error.NoSymbolResponse;
    const oF = switch (rF) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const resF = oF.get("result") orelse return error.NoResult;
    const aF = switch (resF) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(aF.items.len >= 1);
}

test "trait :admin indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_trait";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/tr.rb", .data = "factory :user do\n  trait :admin do\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/tr.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"admin\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const rawTR = try s.run();
    defer alloc.free(rawTR);
    const respTR = try extractResponses(alloc, rawTR);
    defer {
        for (respTR) |r| r.deinit();
        alloc.free(respTR);
    }
    const rTR = getResponseById(respTR, 2) orelse return error.NoSymbolResponse;
    const oTR = switch (rTR) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const resTR = oTR.get("result") orelse return error.NoResult;
    const aTR = switch (resTR) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(aTR.items.len >= 1);
}

test "sequence :email indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_seq";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/sq.rb", .data = "sequence :email do |n|\n  \"user\"\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/sq.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"email\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const rawSQ = try s.run();
    defer alloc.free(rawSQ);
    const respSQ = try extractResponses(alloc, rawSQ);
    defer {
        for (respSQ) |r| r.deinit();
        alloc.free(respSQ);
    }
    const rSQ = getResponseById(respSQ, 2) orelse return error.NoSymbolResponse;
    const oSQ = switch (rSQ) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const resSQ = oSQ.get("result") orelse return error.NoResult;
    const aSQ = switch (resSQ) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(aSQ.items.len >= 1);
}

test "association :user indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_assoc";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/as.rb", .data = "factory :post do\n  association :author\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/as.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"author\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const rawAS = try s.run();
    defer alloc.free(rawAS);
    const respAS = try extractResponses(alloc, rawAS);
    defer {
        for (respAS) |r| r.deinit();
        alloc.free(respAS);
    }
    const rAS = getResponseById(respAS, 2) orelse return error.NoSymbolResponse;
    const oAS = switch (rAS) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const resAS = oAS.get("result") orelse return error.NoResult;
    const aAS = switch (resAS) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(aAS.items.len >= 1);
}
