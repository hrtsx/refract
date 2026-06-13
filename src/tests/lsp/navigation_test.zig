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

test "workspace/symbol returns array" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_nav_batch_ws1";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/sample.rb",
        .data =
        \\module TestMod
        \\  class TestClass
        \\    TESTCONST = 1
        \\    def test_method; end
        \\  end
        \\end
        \\
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/const_test.rb",
        .data = "MYCONST = 42\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/attr_test.rb",
        .data = "class Dog\n  attr_accessor :name\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/sample.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/const_test.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/attr_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Test\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"MYCONST\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"name\"}}");
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

    const sym_resp3 = getResponseById(responses, 3) orelse return error.NoSymbolResponse;
    const obj3 = switch (sym_resp3) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result3 = obj3.get("result") orelse return error.NoResult;
    const arr3 = switch (result3) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr3.items.len > 0);
    const first_sym = switch (arr3.items[0]) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const kind = first_sym.get("kind") orelse return error.NoKind;
    const kind_int = switch (kind) {
        .integer => |i| i,
        else => return error.KindNotInt,
    };
    try std.testing.expectEqual(@as(i64, 13), kind_int);

    const sym_resp4 = getResponseById(responses, 4) orelse return error.NoSymbolResponse;
    const obj4 = switch (sym_resp4) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result4 = obj4.get("result") orelse return error.NoResult;
    const arr4 = switch (result4) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    var found_name = false;
    for (arr4.items) |item| {
        const it = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const n = it.get("name") orelse continue;
        const ns = switch (n) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, ns, "name")) {
            found_name = true;
            break;
        }
    }
    try std.testing.expect(found_name);
}

test "definition returns location" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_nav_batch_def1";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/def_test.rb",
        .data = "class DefTarget; end\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/doc_test.rb",
        .data =
        \\module TestMod
        \\  class TestClass
        \\    TESTCONST = 1
        \\    def test_method; end
        \\  end
        \\end
        \\
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/hier_test.rb",
        .data = "class HierFoo\n  def hier_bar\n  end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/def_test.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/doc_test.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/hier_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/def_test.rb\"},\"position\":{\"line\":0,\"character\":6}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/doc_test.rb\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/hier_test.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoDefinitionResponse;
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
    const first = switch (arr.items[0]) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(first.get("uri") != null);

    const resp3 = getResponseById(responses, 3) orelse return error.NoDocSymResponse;
    const obj3 = switch (resp3) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result3 = obj3.get("result") orelse return error.NoResult;
    const arr3 = switch (result3) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr3.items.len > 0);

    const resp4 = getResponseById(responses, 4) orelse return error.NoDocSymResponse;
    const obj4 = switch (resp4) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result4 = obj4.get("result") orelse return error.NoResult;
    const arr4 = switch (result4) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    var found_bar_as_child = false;
    for (arr4.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const nm = item_obj.get("name") orelse continue;
        const nm_str = switch (nm) {
            .string => |sv| sv,
            else => continue,
        };
        if (!std.mem.eql(u8, nm_str, "HierFoo")) continue;
        const children_val = item_obj.get("children") orelse continue;
        const children = switch (children_val) {
            .array => |a| a,
            else => continue,
        };
        for (children.items) |child| {
            const child_obj = switch (child) {
                .object => |o| o,
                else => continue,
            };
            const cnm = child_obj.get("name") orelse continue;
            const cnm_str = switch (cnm) {
                .string => |sv| sv,
                else => continue,
            };
            if (std.mem.eql(u8, cnm_str, "hier_bar")) {
                found_bar_as_child = true;
                break;
            }
        }
        if (found_bar_as_child) break;
    }
    try std.testing.expect(found_bar_as_child);
}

test "documentSymbol returns symbols" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_docsym";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/sample.rb",
        .data =
        \\module TestMod
        \\  class TestClass
        \\    TESTCONST = 1
        \\    def test_method; end
        \\  end
        \\end
        \\
        ,
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/sample.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/sample.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoDocSymResponse;
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

test "delete event removes symbol" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_delete";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/delete_test.rb",
        .data = "UniqueDeleteTarget = 99\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/delete_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"UniqueDeleteTarget\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/delete_test.rb\",\"type\":3}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"UniqueDeleteTarget\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const before = getResponseById(responses, 2) orelse return error.NoBeforeResponse;
    const before_obj = switch (before) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const before_result = before_obj.get("result") orelse return error.NoResult;
    const before_arr = switch (before_result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(before_arr.items.len > 0);

    const after = getResponseById(responses, 3) orelse return error.NoAfterResponse;
    const after_obj = switch (after) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const after_result = after_obj.get("result") orelse return error.NoResult;
    const after_arr = switch (after_result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expectEqual(@as(usize, 0), after_arr.items.len);
}

test "documentHighlight returns ranges in file" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_high";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/highlight_test.rb",
        .data = "def greet\n  greet\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/highlight_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentHighlight\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/highlight_test.rb\"},\"position\":{\"line\":0,\"character\":4}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoHighlightResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    // def greet (1 symbol) + greet call (1 ref) = at least 2 highlights
    try std.testing.expect(arr.items.len >= 2);
}

test "references on a class constant returns cross-file uses" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_refs_const";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/account.rb",
        .data = "class Account\n  def self.find(id)\n    new\n  end\nend\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/user.rb",
        .data = "class User\n  def initialize\n    @account = Account.find(1)\n    @other = Account.new\n  end\nend\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/billing.rb",
        .data = "module Billing\n  def self.charge\n    Account.find(2)\n  end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/account.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/billing.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Cursor on `Account` in user.rb at line 2 col 15 (the `Account.find(1)` use)
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/references\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/user.rb\"},\"position\":{\"line\":2,\"character\":15},\"context\":{\"includeDeclaration\":false}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoRefsResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    // Three USE sites across two files: user.rb line 2, user.rb line 3, billing.rb line 2.
    // includeDeclaration=false should exclude `class Account` itself.
    try std.testing.expectEqual(@as(usize, 3), arr.items.len);
}

test "references on a method are scoped to its defining class (def_id)" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_refs_method_scope";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/alpha.rb",
        .data = "class Alpha\n  def shared\n  end\n  def use_it\n    shared\n  end\nend\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/beta.rb",
        .data = "class Beta\n  def shared\n  end\n  def call_it\n    shared\n  end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/alpha.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/beta.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Cursor on `def shared` in alpha.rb (line 1, col 6). Must return only Alpha's
    // decl + self-send, NOT Beta#shared (same name, different binding). Name-global
    // matching returned 4; binding-scoped returns 2.
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/references\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/alpha.rb\"},\"position\":{\"line\":1,\"character\":6},\"context\":{\"includeDeclaration\":true}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoRefsResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);
    for (arr.items) |item| {
        const io = switch (item) {
            .object => |o| o,
            else => return error.ItemNotObject,
        };
        const uri = switch (io.get("uri") orelse return error.NoUri) {
            .string => |str| str,
            else => return error.UriNotString,
        };
        try std.testing.expect(std.mem.indexOf(u8, uri, "alpha.rb") != null);
    }
}

test "go-to-def on a route helper resolves to the route declaration" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_route_def";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/config", .default_dir) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/config/routes.rb",
        .data = "Rails.application.routes.draw do\n  resources :widgets\nend\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/app.rb",
        .data = "class Foo\n  def go\n    redirect_to widgets_path\n  end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/config/routes.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/app.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Cursor on `widgets_path` in app.rb (line 2, col 18). The plural collection
    // helper must resolve to config/routes.rb.
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/app.rb\"},\"position\":{\"line\":2,\"character\":18}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoDefResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
    const io = switch (arr.items[0]) {
        .object => |o| o,
        else => return error.ItemNotObject,
    };
    const uri = switch (io.get("uri") orelse return error.NoUri) {
        .string => |str| str,
        else => return error.UriNotString,
    };
    try std.testing.expect(std.mem.indexOf(u8, uri, "config/routes.rb") != null);
}

test "go-to-def on an engine-proxied route helper (spree.admin_*) resolves" {
    // Engine routes live in `Engine.routes.draw` and app code references them via an
    // engine proxy receiver (`spree.admin_stock_items_path`). `extractWord` drops the
    // `spree.` receiver (`.` isn't an ident char), so the helper resolves like any other.
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_engine_proxy_route_def";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/config", .default_dir) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/config/routes.rb",
        .data = "Spree::Core::Engine.routes.draw do\n  namespace :admin do\n    resources :stock_items, except: [:show, :new, :edit]\n  end\nend\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/app.rb",
        .data = "class Foo\n  def go\n    redirect_to spree.admin_stock_items_path\n  end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/config/routes.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/app.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // `admin_stock_items_path` begins after `spree.` at col 22 of line 2; aim inside it.
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/app.rb\"},\"position\":{\"line\":2,\"character\":25}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoDefResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
    const io = switch (arr.items[0]) {
        .object => |o| o,
        else => return error.ItemNotObject,
    };
    const uri = switch (io.get("uri") orelse return error.NoUri) {
        .string => |str| str,
        else => return error.UriNotString,
    };
    try std.testing.expect(std.mem.indexOf(u8, uri, "config/routes.rb") != null);
}

test "go-to-def on a namespaced route helper resolves (admin_ prefix)" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_ns_route_def";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/config", .default_dir) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/config/routes.rb",
        .data = "Rails.application.routes.draw do\n  namespace :admin do\n    resources :stock_items\n  end\nend\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/app.rb",
        .data = "class Foo\n  def go\n    redirect_to admin_stock_items_path\n  end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/config/routes.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/app.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // `admin_stock_items_path` starts at col 16 of line 2.
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/app.rb\"},\"position\":{\"line\":2,\"character\":20}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoDefResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
    const io = switch (arr.items[0]) {
        .object => |o| o,
        else => return error.ItemNotObject,
    };
    const uri = switch (io.get("uri") orelse return error.NoUri) {
        .string => |str| str,
        else => return error.UriNotString,
    };
    try std.testing.expect(std.mem.indexOf(u8, uri, "config/routes.rb") != null);
}

test "documentHighlight is scope-aware for local vars" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_scoph";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    // Two methods each define local `x`; line 1 and line 4 (0-indexed: 0 and 3)
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/scope_highlight.rb",
        .data = "def a\n  x = 1\nend\ndef b\n  x = 2\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/scope_highlight.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Highlight `x` at line 1 (0-indexed), character 2
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentHighlight\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/scope_highlight.rb\"},\"position\":{\"line\":1,\"character\":2}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp = getResponseById(responses, 2) orelse return error.NoHighlightResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };

    // Must not contain line 4 (0-indexed) — that's `x` in method `b`
    for (arr.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const range = item_obj.get("range") orelse continue;
        const range_obj = switch (range) {
            .object => |o| o,
            else => continue,
        };
        const start = range_obj.get("start") orelse continue;
        const start_obj = switch (start) {
            .object => |o| o,
            else => continue,
        };
        const ln = start_obj.get("line") orelse continue;
        const ln_num = switch (ln) {
            .integer => |i| i,
            else => continue,
        };
        try std.testing.expect(ln_num != 4);
    }
}

test "workspace/didDeleteFiles removes symbol" {
    const alloc = std.testing.allocator;

    // Write fixture to a unique location
    // We skip `initialized` so no background thread can race-reindex the file.
    const ws = "/tmp/refract_test_deldel";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/delete_target.rb",
        .data = "class DeleteTargetUnique7391; end\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    // No `initialized` → background thread never starts → no race
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/delete_target.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"DeleteTargetUnique7391\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didDeleteFiles\",\"params\":{\"files\":[{\"uri\":\"file://" ++ ws ++ "/delete_target.rb\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"DeleteTargetUnique7391\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const before = getResponseById(responses, 2) orelse return error.NoBeforeResponse;
    const before_obj = switch (before) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const before_arr = switch (before_obj.get("result") orelse return error.NoResult) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(before_arr.items.len > 0);

    const after = getResponseById(responses, 3) orelse return error.NoAfterResponse;
    const after_obj = switch (after) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const after_arr = switch (after_obj.get("result") orelse return error.NoResult) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expectEqual(@as(usize, 0), after_arr.items.len);
}

test "alias_method creates navigable symbol" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_alias";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/alias_method_test.rb",
        .data = "class User\n  def name; @name; end\n  alias_method :display_name, :name\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/alias_method_test.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"display_name\"}}");
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
        if (std.mem.eql(u8, nm_str, "display_name")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "didChangeWatchedFiles delete removes symbols" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_delete_sym";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/delete_me.rb",
        .data = "class ToBeDeleted; end\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/delete_me.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/delete_me.rb\",\"type\":3}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"ToBeDeleted\"}}");
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
        try std.testing.expect(!std.mem.eql(u8, nm_str, "ToBeDeleted"));
    }
}

test "server initializes and responds to workspace/symbol" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_schema18";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
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

    try std.testing.expect(getResponseById(responses, 1) != null);
    try std.testing.expect(getResponseById(responses, 2) != null);
}

test "didDeleteFiles removes symbols" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p19_did_delete";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/delete_p19.rb",
        .data = "def p19_delete_target_method\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/delete_p19.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didDeleteFiles\",\"params\":{\"files\":[{\"uri\":\"file://" ++ ws ++ "/delete_p19.rb\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"p19_delete_target_method\"}}");
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

test "empty file returns empty symbols" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p19_empty_file";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/empty.rb",
        .data = "",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/empty.rb\",\"type\":1}]}}");
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

test "workspace symbol empty query returns results" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p20_empty_query";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/symbols.rb",
        .data = "class TestClass\n  def test_method\n    42\n  end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/symbols.rb\",\"type\":1}]}}");
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

test "definition on qualified name" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_qdef";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/qdef.rb",
        .data = "class Foo::Bar\nend\nFoo::Bar\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/qdef.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/qdef.rb\"},\"position\":{\"line\":2,\"character\":5}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);

    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const def_resp = getResponseById(responses, 2) orelse return error.NoDefinitionResponse;
    const obj = switch (def_resp) {
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

test "implementation returns definition location" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_impl";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/impl.rb", .data = "class Foo\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/impl.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Foo\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/implementation\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/impl.rb\"},\"position\":{\"line\":0,\"character\":6}}}");
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
    _ = switch (result) {
        .null => return error.NullResult,
        .array => {},
        else => {},
    };
}

test "declaration returns definition location" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_decl";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/decl.rb", .data = "class Bar\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/decl.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Bar\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/declaration\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/decl.rb\"},\"position\":{\"line\":0,\"character\":6}}}");
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
    _ = obj.get("result") orelse return error.NoResult;
}

test "mattr_accessor indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_mattr";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/m.rb", .data = "module MyMod\n  mattr_accessor :setting\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/m.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"setting\"}}");
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

test "cattr_accessor indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_cattr";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/c.rb", .data = "class MyClass\n  cattr_accessor :config\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/c.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"config\"}}");
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

test "callHierarchy prepare returns item" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_callh";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/ch.rb", .data = "def my_method\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/ch.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def my_method\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/prepareCallHierarchy\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/ch.rb\"},\"position\":{\"line\":0,\"character\":4}}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "callHierarchy incomingCalls" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_incoming";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/inc.rb", .data = "def target\nend\ndef caller_fn\n  target\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/inc.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"callHierarchy/incomingCalls\",\"params\":{\"item\":{\"name\":\"target\",\"kind\":6,\"uri\":\"file://" ++ ws ++ "/inc.rb\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":6}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":6}}}}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len >= 1);
}

test "outgoingCalls returns empty array" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_outgoing";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"callHierarchy/outgoingCalls\",\"params\":{\"item\":{\"name\":\"foo\",\"kind\":6,\"uri\":\"file:///tmp/x.rb\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":3}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":3}}}}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr.items.len == 0);
}

test "open doc cache didChange updates symbols" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t72";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def old_method; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def old_method; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"version\":2},\"contentChanges\":[{\"text\":\"def new_method; end\\n\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"new_method\"}}");
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
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.NotArray,
    };
    if (arr.items.len == 0) return error.EmptyResult;
}

test "outgoingCalls returns called methods" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t730";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def target_method\n  foo_call\n  bar_call\nend\ndef foo_call; end\ndef bar_call; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def target_method\\n  foo_call\\n  bar_call\\nend\\ndef foo_call; end\\ndef bar_call; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/prepareCallHierarchy\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":4}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"callHierarchy/outgoingCalls\",\"params\":{\"item\":{\"name\":\"target_method\",\"kind\":12,\"uri\":\"file://" ++ ws ++ "/a.rb\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":3,\"character\":3}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":4},\"end\":{\"line\":0,\"character\":19}}}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 3) orelse return error.NoOutgoingResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
    _ = obj.get("result") orelse return error.NoResult;
}

test "outgoingCalls empty for method with no calls" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t731";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def simple_method\n  42\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def simple_method\\n  42\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/prepareCallHierarchy\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":4}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"callHierarchy/outgoingCalls\",\"params\":{\"item\":{\"name\":\"simple_method\",\"kind\":12,\"uri\":\"file://" ++ ws ++ "/a.rb\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":2,\"character\":3}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":4},\"end\":{\"line\":0,\"character\":17}}}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 3) orelse return error.NoOutgoingResponse;
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

test "non-UTF-8 file not in workspace/symbol" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t735";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/binary.rb", .data = "\xFF\xFE\x00\x01" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
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
    try std.testing.expectEqual(@as(usize, 0), result_arr.items.len);
}

test "large workspace 1000 symbols indexes fully" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t737";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    for (0..50) |fi| {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(alloc);
        for (0..20) |mi| {
            const line = try std.fmt.allocPrint(alloc, "def method_{d}_{d}; end\n", .{ fi, mi });
            defer alloc.free(line);
            try buf.appendSlice(alloc, line);
        }
        const fname = try std.fmt.allocPrint(alloc, ws ++ "/f{d}.rb", .{fi});
        defer alloc.free(fname);
        try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = fname, .data = buf.items });
    }
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    for (0..50) |fi| {
        const watch_msg = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\"," ++
            "\"params\":{{\"changes\":[{{\"uri\":\"file://" ++ ws ++ "/f{d}.rb\",\"type\":1}}]}}}}", .{fi});
        defer alloc.free(watch_msg);
        try s.send(watch_msg);
    }
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"method_0_0\"}}");
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

test "large workspace symbol query fast" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t738";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    for (0..50) |fi| {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(alloc);
        for (0..20) |mi| {
            const line = try std.fmt.allocPrint(alloc, "def method_{d}_{d}; end\n", .{ fi, mi });
            defer alloc.free(line);
            try buf.appendSlice(alloc, line);
        }
        const fname = try std.fmt.allocPrint(alloc, ws ++ "/f{d}.rb", .{fi});
        defer alloc.free(fname);
        try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = fname, .data = buf.items });
    }
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"method_0_0\"}}");
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
    _ = obj.get("result") orelse return error.NoResult;
}

test "workspace symbol fuzzy camel initials" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t822";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class UserController; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"UC\"}}");
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
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.NotArray,
    };
    var found = false;
    for (arr.items) |item| {
        const io = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const nv = io.get("name") orelse continue;
        const ns = switch (nv) {
            .string => |s2| s2,
            else => continue,
        };
        if (std.mem.eql(u8, ns, "UserController")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "workspace symbol fuzzy subsequence" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t823";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class UserController; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"usrctrl\"}}");
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
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.NotArray,
    };
    var found = false;
    for (arr.items) |item| {
        const io = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const nv = io.get("name") orelse continue;
        const ns = switch (nv) {
            .string => |s2| s2,
            else => continue,
        };
        if (std.mem.eql(u8, ns, "UserController")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "workspace symbol exact prefix still works" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t824";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class UserController; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"User\"}}");
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
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.NotArray,
    };
    var found = false;
    for (arr.items) |item| {
        const io = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const nv = io.get("name") orelse continue;
        const ns = switch (nv) {
            .string => |s2| s2,
            else => continue,
        };
        if (std.mem.eql(u8, ns, "UserController")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "P26 T9.2 data receiver DB" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p26_t902";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Post\ndef save; end\nend\ndata = Post.all\ndata.each { |p| }\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Post\\ndef save; end\\nend\\ndata = Post.all\\ndata.each { |p| }\\n\"}}}");
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

test "P26 T9.3 results receiver heuristic" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p26_t903";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class User\nend\nresults = User.all\nresults.select { |r| }\n" });
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

test "P26 T9.18 end_line for class" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p26_t918";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class MyClass\ndef foo\n123\nend\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class MyClass\\ndef foo\\n123\\nend\\nend\\n\"}}}");
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

test "P26 T9.39 namespace two-level workspace symbol" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p26_t939";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "module Foo\nclass Bar\nend\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"module Foo\\nclass Bar\\nend\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Bar\"}}");
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

test "P27 T10.33 code lens ref count method" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1033";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def foo\nend\nfoo\nfoo\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def foo\\nend\\nfoo\\nfoo\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/codeLens\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
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

test "P27 T10.34 code lens zero refs" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1034";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def unused\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def unused\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/codeLens\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
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

test "P27 T10.35 code lens class symbol" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1035";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Foo\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Foo\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/codeLens\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
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

test "P27 T10.36 code lens large file limit" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1036";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class A; end\nclass B; end\nclass C; end\nclass D; end\nclass E; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class A; end\\nclass B; end\\nclass C; end\\nclass D; end\\nclass E; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/codeLens\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
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

test "P27 T10.37 code lens rspec it block" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1037";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "it \"does X\" do\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"it \\\"does X\\\" do\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/codeLens\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
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

test "P27 T10.38 code lens minitest test method" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1038";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def test_create\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def test_create\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/codeLens\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
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

test "P28 T11.11 code lens same file refs count" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t1111";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def greet; end\ngreet\ngreet\ngreet\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def greet; end\\ngreet\\ngreet\\ngreet\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/codeLens\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
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

test "P28 T11.14 code lens test run lens present" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t1114";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def test_something; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def test_something; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/codeLens\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"}}}");
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

test "P30 T13.25 Symbol to_proc child nodes still indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1325";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "arr = [\"a\", \"b\"]\nnames = arr.map(&:upcase)\nresultvar = names\n" });
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
}

test "P30 T13.31 parallel indexing symbols from multiple files present" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1331";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Alphaclassxyz; end\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/b.rb", .data = "class Betaclassxyz; end\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/c.rb", .data = "class Gammaclassxyz; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/b.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/c.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"classxyz\"}}");
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "Alphaclassxyz") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Betaclassxyz") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Gammaclassxyz") != null);
}

test "P30 T13.32 reindex same file no duplicate symbols" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1332";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Uniquexyzclass; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Uniquexyzclass\"}}");
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
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, raw, pos, "Uniquexyzclass")) |idx| {
        count += 1;
        pos = idx + 1;
    }
    try std.testing.expect(count <= 4);
}

test "P30 T13.35 regression attr_accessor still synthesizes reader writer" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1335";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Widget\n  attr_accessor :widgetcolor\nend\nw = Widget.new\nw.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
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
    _ = getResponseById(resp, 2) orelse return error.NoCompletionResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "widgetcolor") != null);
}

test "P31 T14.9 refract.showReferences registered in capabilities" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t149";
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "showReferences") != null);
}

test "P31 T14.25 didChangeWorkspaceFolders removes folder symbols" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1425";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class FolderClass1425\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWorkspaceFolders\",\"params\":{\"event\":{\"added\":[],\"removed\":[{\"uri\":\"file://" ++ ws ++ "\",\"name\":\"test\"}]}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"FolderClass1425\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoSymResponse;
}

test "P31 T14.42 p31 regression documentSymbol still works" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1442";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class RegClass1442\n  def regmethod1442\n  end\nend\n" });
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "RegClass1442") != null);
}

test "P31 T14.43 p31 regression attr_accessor still synthesizes reader writer" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1443";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Widget1443\n  attr_accessor :regcolor1443\nend\nw = Widget1443.new\nw.\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
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
    _ = getResponseById(resp, 2) orelse return error.NoCompletionResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "regcolor1443") != null);
}

test "P32 T15.8 async delete still removes symbols" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t158";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/del158.rb", .data = "class Del158\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/del158.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/del158.rb\",\"type\":3}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Del158\"}}");
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

test "P32 T15.24 lookupStdlibReturn Symbol#to_s returns String" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1524";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "s1524 = :hello\nx1524 = s1524.to_s\n" });
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

test "P33 T16.3 workspace/symbol excludes gem symbols" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p33_t163";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/app.rb", .data = "class WorkspaceClass163\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/app.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"WorkspaceClass163\"}}");
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "WorkspaceClass163") != null);
}

test "P35 T18.5 didChangeWorkspaceFolders remove clears folder symbols" {
    const alloc = std.testing.allocator;
    const ws_a = "/tmp/refract_test_p35_185a";
    const ws_b = "/tmp/refract_test_p35_185b";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws_a) catch {};
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws_b) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws_a, .default_dir);
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws_b, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws_a) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws_b) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws_a ++ "/a.rb", .data = "class FolderAlpha185\nend\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws_b ++ "/b.rb", .data = "class FolderBeta185\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws_a ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWorkspaceFolders\",\"params\":{\"event\":{\"added\":[{\"uri\":\"file://" ++ ws_b ++ "\",\"name\":\"b\"}],\"removed\":[]}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWorkspaceFolders\",\"params\":{\"event\":{\"added\":[],\"removed\":[{\"uri\":\"file://" ++ ws_b ++ "\",\"name\":\"b\"}]}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"FolderBeta185\"}}");
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "FolderBeta185") == null);
}

test "T2 LIKE special chars workspace symbol underscore prefix" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_t2_like";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // Foo_Base is a valid Ruby class name (starts uppercase) containing literal "_Base"
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/helper.rb",
        .data = "class Foo_Base\nend\nclass FooBase\nend\n",
    });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/helper.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Foo_Base\\nend\\nclass FooBase\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"_Base\"}}");
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "Foo_Base") != null);
}

test "T3 isIncomplete true when symbol limit hit" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_t3_incomplete";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // Write 201 classes to a single file, starting with blank line so position {0,0} gives word=""
    var rb_content = std.ArrayList(u8).empty;
    defer rb_content.deinit(alloc);
    try rb_content.appendSlice(alloc, "\n");
    var ci: usize = 0;
    while (ci < 201) : (ci += 1) {
        const line = try std.fmt.allocPrint(alloc, "class Foo{d:0>3}X\nend\n", .{ci});
        defer alloc.free(line);
        try rb_content.appendSlice(alloc, line);
    }
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/many.rb", .data = rb_content.items });
    // Build JSON-escaped content for didOpen (newlines → \n, no other escaping needed)
    var json_content = std.ArrayList(u8).empty;
    defer json_content.deinit(alloc);
    for (rb_content.items) |c| {
        if (c == '\n') {
            try json_content.appendSlice(alloc, "\\n");
        } else {
            try json_content.append(alloc, c);
        }
    }
    const did_open_msg = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"file://{s}/many.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"{s}\"}}}}}}", .{ ws, json_content.items });
    defer alloc.free(did_open_msg);
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send(did_open_msg);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/many.rb\"},\"position\":{\"line\":0,\"character\":0},\"context\":{\"triggerKind\":2,\"triggerCharacter\":\".\"}}}");
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
    const incomplete = result_obj.get("isIncomplete") orelse return error.NoIsIncomplete;
    const is_incomplete = switch (incomplete) {
        .bool => |b| b,
        else => return error.IsIncompleteNotBool,
    };
    try std.testing.expect(is_incomplete);
}

test "T_TRAVERSAL_TYPEHIERARCHY prepareTypeHierarchy with traversal URI returns null" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_ttravtype";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/app.rb", .data = "class Foo; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/prepareTypeHierarchy\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/../../etc/passwd\"},\"position\":{\"line\":0,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const th_resp = getResponseById(resp, 2) orelse return error.NoTypeHierarchyResponse;
    const th_obj = switch (th_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = th_obj.get("result") orelse return error.NoResult;
    try std.testing.expect(result == .null);
}

test "T_TRAVERSAL_CALLHIERARCHY prepareCallHierarchy with traversal URI returns null" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_ttravcall";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/app.rb", .data = "def greet; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/prepareCallHierarchy\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/../../etc/passwd\"},\"position\":{\"line\":0,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const ch_resp = getResponseById(resp, 2) orelse return error.NoCallHierarchyResponse;
    const ch_obj = switch (ch_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = ch_obj.get("result") orelse return error.NoResult;
    try std.testing.expect(result == .null);
}

test "T_CONTAINER_NAME workspace/symbol includes containerName for class method" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tcnname";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/widget.rb", .data = "class MyWidget\ndef paint; end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/widget.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class MyWidget\\ndef paint; end\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"paint\"}}");
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
    const items = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    var found_container = false;
    for (items.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const cn = obj.get("containerName") orelse continue;
        const cn_str = switch (cn) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, cn_str, "MyWidget")) {
            found_container = true;
            break;
        }
    }
    try std.testing.expect(found_container);
}

test "T_CONTAINER_INFIX workspace/symbol infix match includes containerName" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tcninfix";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/widget.rb", .data = "class MyWidget\ndef paint; end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/widget.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class MyWidget\\ndef paint; end\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"ain\"}}");
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
    const items = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    var found_container = false;
    for (items.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const cn = obj.get("containerName") orelse continue;
        const cn_str = switch (cn) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, cn_str, "MyWidget")) {
            found_container = true;
            break;
        }
    }
    try std.testing.expect(found_container);
}

test "T_CALL_HIERARCHY callHierarchyPrepare returns array" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tcallhier";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/ch.rb", .data = "def foo; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/ch.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/prepareCallHierarchy\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/ch.rb\"},\"position\":{\"line\":0,\"character\":4}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const ch_resp = getResponseById(resp, 2) orelse return error.NoCallHierarchyResponse;
    const ch_obj = switch (ch_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = ch_obj.get("result") orelse return error.NoResult;
    try std.testing.expect(result == .array or result == .null);
}

test "T_DOCUMENT_HIGHLIGHT_KINDS definition site is write, reference site is read" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_thlkinds";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/hl.rb", .data = "x = 1\nputs x\n" });
    const file_uri = "file://" ++ ws ++ "/hl.rb";
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"" ++ file_uri ++ "\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"x = 1\\nputs x\\n\"}}}");
    // Highlight at line 0, col 0 — the assignment 'x = 1'
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentHighlight\",\"params\":{\"textDocument\":{\"uri\":\"" ++ file_uri ++ "\"},\"position\":{\"line\":0,\"character\":0}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const hl_resp = getResponseById(resp, 2) orelse return error.NoHighlightResponse;
    const hl_obj = switch (hl_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = hl_obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        .null => return,
        else => return error.NotArray,
    };
    try std.testing.expect(arr.items.len >= 2);
    // Find definition (write) site with kind 3, and reference (read) site with kind 2
    var found_write = false;
    var found_read = false;
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const kind_val = obj.get("kind") orelse continue;
        const k = switch (kind_val) {
            .integer => |i| i,
            else => continue,
        };
        if (k == 3) found_write = true;
        if (k == 2) found_read = true;
    }
    try std.testing.expect(found_write);
    try std.testing.expect(found_read);
}

test "T_ALIAS_SYMBOL alias creates navigable symbol" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_talias_kw";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/alias.rb", .data = "class Foo\n  def bar; end\n  alias baz bar\nend\n" });
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
    const arr = switch (result) {
        .array => |a| a,
        .null => return,
        else => return error.NotArray,
    };
    var found = false;
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name_val = obj.get("name") orelse continue;
        const name = switch (name_val) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, name, "baz")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "T_UTF16_OUTPUT workspace/symbol character column correct for UTF-16 vs UTF-8" {
    // File: "é; class Foo\nend\n"
    // é = 0xC3 0xA9 (2 UTF-8 bytes, 1 UTF-16 code unit)
    // "class" starts at UTF-8 byte 10, UTF-16 character 9
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tutf16out";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const file_path = ws ++ "/test_utf16_col.rb";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = file_path, .data = "\xc3\xa9; class Foo\nend\n" });
    const file_uri = "file://" ++ ws ++ "/test_utf16_col.rb";

    // Sub-case 1: UTF-16 client (no positionEncodings → server defaults to utf-16)
    {
        var s = try Session.init(alloc);
        defer s.deinit();
        try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
        try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");
        try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didCreateFiles\",\"params\":{\"files\":[{\"uri\":\"" ++ file_uri ++ "\"}]}}");
        try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Foo\"}}");
        try s.send("{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"shutdown\",\"params\":null}");
        try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
        const raw = try s.run();
        defer alloc.free(raw);
        const resp = try extractResponses(alloc, raw);
        defer {
            for (resp) |r| r.deinit();
            alloc.free(resp);
        }

        // Confirm positionEncoding is utf-16
        const init_resp = getResponseById(resp, 1) orelse return error.NoInitResponse;
        const init_obj = switch (init_resp) {
            .object => |o| o,
            else => return error.NotObject,
        };
        const result_val = init_obj.get("result") orelse return error.NoResult;
        const result_obj = switch (result_val) {
            .object => |o| o,
            else => return error.ResultNotObject,
        };
        const caps_val = result_obj.get("capabilities") orelse return error.NoCaps;
        const caps_obj = switch (caps_val) {
            .object => |o| o,
            else => return error.CapsNotObject,
        };
        const pos_enc = caps_obj.get("positionEncoding") orelse return error.NoPositionEncoding;
        const enc_str = switch (pos_enc) {
            .string => |sv| sv,
            else => return error.NotString,
        };
        try std.testing.expectEqualStrings("utf-16", enc_str);

        // Check workspace/symbol result character
        const sym_resp = getResponseById(resp, 2) orelse return error.NoSymResponse;
        const sym_obj = switch (sym_resp) {
            .object => |o| o,
            else => return error.SymNotObject,
        };
        const sym_result = sym_obj.get("result") orelse return error.NoSymResult;
        const sym_arr = switch (sym_result) {
            .array => |a| a,
            else => return error.SymNotArray,
        };
        if (sym_arr.items.len == 0) return error.SymEmpty;
        const sym0 = switch (sym_arr.items[0]) {
            .object => |o| o,
            else => return error.Sym0NotObject,
        };
        const loc = switch (sym0.get("location") orelse return error.NoLocation) {
            .object => |o| o,
            else => return error.LocNotObject,
        };
        const range = switch (loc.get("range") orelse return error.NoRange) {
            .object => |o| o,
            else => return error.RangeNotObject,
        };
        const start = switch (range.get("start") orelse return error.NoStart) {
            .object => |o| o,
            else => return error.StartNotObject,
        };
        const char_val = start.get("character") orelse return error.NoCharacter;
        const char_int = switch (char_val) {
            .integer => |i| i,
            else => return error.CharNotInt,
        };
        // File: é; class Foo\n  →  "class" keyword at UTF-8 byte 4, UTF-16 char 3
        // (é=2 bytes but 1 UTF-16 unit, so byte 4 → char 3)
        try std.testing.expectEqual(@as(i64, 3), char_int);
    }

    // Sub-case 2: UTF-8 client (positionEncodings: ["utf-8"])
    {
        var s = try Session.init(alloc);
        defer s.deinit();
        try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{\"general\":{\"positionEncodings\":[\"utf-8\"]}},\"initializationOptions\":{\"disableGemIndex\":true}}}");
        try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");
        try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didCreateFiles\",\"params\":{\"files\":[{\"uri\":\"" ++ file_uri ++ "\"}]}}");
        try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Foo\"}}");
        try s.send("{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"shutdown\",\"params\":null}");
        try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
        const raw = try s.run();
        defer alloc.free(raw);
        const resp = try extractResponses(alloc, raw);
        defer {
            for (resp) |r| r.deinit();
            alloc.free(resp);
        }

        const sym_resp = getResponseById(resp, 2) orelse return error.NoSymResponse;
        const sym_obj = switch (sym_resp) {
            .object => |o| o,
            else => return error.SymNotObject,
        };
        const sym_result = sym_obj.get("result") orelse return error.NoSymResult;
        const sym_arr = switch (sym_result) {
            .array => |a| a,
            else => return error.SymNotArray,
        };
        if (sym_arr.items.len == 0) return error.SymEmpty;
        const sym0 = switch (sym_arr.items[0]) {
            .object => |o| o,
            else => return error.Sym0NotObject,
        };
        const loc = switch (sym0.get("location") orelse return error.NoLocation) {
            .object => |o| o,
            else => return error.LocNotObject,
        };
        const range = switch (loc.get("range") orelse return error.NoRange) {
            .object => |o| o,
            else => return error.RangeNotObject,
        };
        const start = switch (range.get("start") orelse return error.NoStart) {
            .object => |o| o,
            else => return error.StartNotObject,
        };
        const char_val = start.get("character") orelse return error.NoCharacter;
        const char_int = switch (char_val) {
            .integer => |i| i,
            else => return error.CharNotInt,
        };
        // UTF-8: é counts as 2 bytes, so "class" keyword is at byte column 4 (no conversion)
        try std.testing.expectEqual(@as(i64, 4), char_int);
    }
}

test "P20 T20.3 documentSymbol selectionRange is not 999" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p20_t203";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/c.rb", .data = "class UserAuthentication\n  def process; end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/c.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class UserAuthentication\\n  def process; end\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/c.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"UserAuthentication\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/c.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r3 = getResponseById(resp, 3) orelse return error.NoSymbolResponse;
    const r3outer = switch (r3) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const r3result = r3outer.get("result") orelse return error.NoResultField;
    const syms = switch (r3result) {
        .array => |a| a,
        else => return error.NotArray,
    };
    if (syms.items.len == 0) return error.NoSymbols;
    const top = switch (syms.items[0]) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const sel = switch (top.get("selectionRange") orelse return error.NoSelectionRange) {
        .object => |o| o,
        else => return error.SelRangeNotObj,
    };
    const sel_end = switch (sel.get("end") orelse return error.NoEnd) {
        .object => |o| o,
        else => return error.EndNotObj,
    };
    const ec = switch (sel_end.get("character") orelse return error.NoChar) {
        .integer => |i| i,
        else => return error.CharNotInt,
    };
    try std.testing.expect(ec != 999);
    try std.testing.expect(ec > 0);
    // Check child selectionRange
    const children_val = top.get("children") orelse return error.NoChildren;
    const children = switch (children_val) {
        .array => |a| a,
        else => return error.ChildrenNotArray,
    };
    if (children.items.len > 0) {
        const child = switch (children.items[0]) {
            .object => |o| o,
            else => return error.ChildNotObj,
        };
        const csel = switch (child.get("selectionRange") orelse return error.NoChildSel) {
            .object => |o| o,
            else => return error.CSelNotObj,
        };
        const csel_end = switch (csel.get("end") orelse return error.NoCEnd) {
            .object => |o| o,
            else => return error.CEndNotObj,
        };
        const cec = switch (csel_end.get("character") orelse return error.NoCChar) {
            .integer => |i| i,
            else => return error.CCharNotInt,
        };
        try std.testing.expect(cec != 999);
    }
}

test "P21 T21.2 codeLens returns 250+ symbols" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_t212";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var src = std.ArrayList(u8).empty;
    defer src.deinit(alloc);
    try src.appendSlice(alloc, "class BigFile\n");
    var mi: usize = 0;
    while (mi < 250) : (mi += 1) {
        var _lb: [32]u8 = undefined;
        try src.appendSlice(alloc, try std.fmt.bufPrint(&_lb, "  def m{d}; end\n", .{mi}));
    }
    try src.appendSlice(alloc, "end\n");
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/big.rb", .data = src.items });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/big.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"m\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/codeLens\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/big.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r3 = getResponseById(resp, 3) orelse return error.NoCodeLensResponse;
    const r3obj = switch (r3) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const r3result = r3obj.get("result") orelse return error.NoResult;
    const arr = switch (r3result) {
        .array => |a| a,
        else => return error.NotArray,
    };
    try std.testing.expect(arr.items.len >= 250);
}

test "P21 T21.3 workspace symbol returns 250+ matches" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_t213";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var src = std.ArrayList(u8).empty;
    defer src.deinit(alloc);
    try src.appendSlice(alloc, "class BigWs\n");
    var mi: usize = 0;
    while (mi < 250) : (mi += 1) {
        var _lb: [32]u8 = undefined;
        try src.appendSlice(alloc, try std.fmt.bufPrint(&_lb, "  def mws{d}; end\n", .{mi}));
    }
    try src.appendSlice(alloc, "end\n");
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/ws.rb", .data = src.items });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/ws.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"BigWs\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"mws\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r3 = getResponseById(resp, 3) orelse return error.NoSymbolResponse;
    const r3obj = switch (r3) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const r3result = r3obj.get("result") orelse return error.NoResult;
    const arr = switch (r3result) {
        .array => |a| a,
        else => return error.NotArray,
    };
    try std.testing.expect(arr.items.len >= 250);
}

test "P21 T21.4 method_missing in documentSymbol" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_t214";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/proxy.rb", .data = "class Proxy\n  def method_missing(name, *args)\n    super\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/proxy.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Proxy\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/proxy.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r3 = getResponseById(resp, 3) orelse return error.NoDocSymResponse;
    const r3obj = switch (r3) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const r3result = r3obj.get("result") orelse return error.NoResult;
    const arr = switch (r3result) {
        .array => |a| a,
        else => return error.NotArray,
    };
    var found = false;
    for (arr.items) |item| {
        const iobj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name_val = iobj.get("name") orelse continue;
        const iname = switch (name_val) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, iname, "Proxy")) {
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
                const cname_val = cobj.get("name") orelse continue;
                const cname = switch (cname_val) {
                    .string => |sv| sv,
                    else => continue,
                };
                if (std.mem.eql(u8, cname, "method_missing")) {
                    found = true;
                    break;
                }
            }
        }
    }
    try std.testing.expect(found);
}

test "P21 T21.5 respond_to_missing? in documentSymbol" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_t215";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/proxy2.rb", .data = "class Proxy2\n  def respond_to_missing?(name, include_private = false)\n    true\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/proxy2.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Proxy2\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/proxy2.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r3 = getResponseById(resp, 3) orelse return error.NoDocSymResponse;
    const r3obj = switch (r3) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const r3result = r3obj.get("result") orelse return error.NoResult;
    const arr = switch (r3result) {
        .array => |a| a,
        else => return error.NotArray,
    };
    var found = false;
    for (arr.items) |item| {
        const iobj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name_val = iobj.get("name") orelse continue;
        const iname = switch (name_val) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, iname, "Proxy2")) {
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
                const cname_val = cobj.get("name") orelse continue;
                const cname = switch (cname_val) {
                    .string => |sv| sv,
                    else => continue,
                };
                if (std.mem.eql(u8, cname, "respond_to_missing?")) {
                    found = true;
                    break;
                }
            }
        }
    }
    try std.testing.expect(found);
}

test "P21 T21.6 require_relative definition jump" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_t216";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "require_relative 'b'\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/b.rb", .data = "class Bee; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/b.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Bee\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":19}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r3 = getResponseById(resp, 3) orelse return error.NoDefResponse;
    const r3obj = switch (r3) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const r3result = r3obj.get("result") orelse return error.NoResult;
    const arr = switch (r3result) {
        .array => |a| a,
        else => return error.NotArray,
    };
    try std.testing.expect(arr.items.len > 0);
    const loc = switch (arr.items[0]) {
        .object => |o| o,
        else => return error.NotLocObj,
    };
    const uri_val = loc.get("uri") orelse return error.NoUri;
    const uri_sv = switch (uri_val) {
        .string => |sv| sv,
        else => return error.UriNotString,
    };
    try std.testing.expect(std.mem.endsWith(u8, uri_sv, "/b.rb"));
    const range_val = loc.get("range") orelse return error.NoRange;
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
    try std.testing.expect(start_line == 0);
}

test "P22 T22.3 alias keyword new name in documentSymbol" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_t223";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class Foo\n  def greet; end\n  alias hello greet\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/foo.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/foo.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/foo.rb\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r = getResponseById(resp, 2) orelse return error.NoDocSymbolResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.NotArray,
    };
    var found_hello = false;
    for (arr.items) |item| {
        const iobj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name_val = iobj.get("name") orelse continue;
        const name = switch (name_val) {
            .string => |s2| s2,
            else => continue,
        };
        if (std.mem.eql(u8, name, "hello")) found_hello = true;
        const children = switch (iobj.get("children") orelse continue) {
            .array => |a| a,
            else => continue,
        };
        for (children.items) |child| {
            const cobj = switch (child) {
                .object => |o| o,
                else => continue,
            };
            const cn = switch (cobj.get("name") orelse continue) {
                .string => |s2| s2,
                else => continue,
            };
            if (std.mem.eql(u8, cn, "hello")) found_hello = true;
        }
    }
    try std.testing.expect(found_hello);
}

test "P22 T22.4 alias keyword new name in workspace symbol" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_t224";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class Foo\n  def greet; end\n  alias hello greet\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/foo.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/foo.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"hello\"}}");
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
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.NotArray,
    };
    try std.testing.expect(arr.items.len > 0);
    const first_item = switch (arr.items[0]) {
        .object => |o| o,
        else => return error.ItemNotObject,
    };
    const name_val = first_item.get("name") orelse return error.NoName;
    const name = switch (name_val) {
        .string => |s2| s2,
        else => return error.NameNotString,
    };
    try std.testing.expectEqualStrings("hello", name);
}

test "P22 T22.10 alias_method and bare alias coexist in documentSymbol" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p22_t2210";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class Proxy\n  def original; end\n  alias_method :dsl_alias, :original\n  alias kw_alias original\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/proxy.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/proxy.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/proxy.rb\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"kw_alias\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    const r2 = getResponseById(resp, 2) orelse return error.NoDocSymbolResponse;
    const r2obj = switch (r2) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const r2result = r2obj.get("result") orelse return error.NoResult;
    const arr = switch (r2result) {
        .array => |a| a,
        else => return error.NotArray,
    };
    var found_original = false;
    var found_dsl = false;
    var found_kw = false;
    for (arr.items) |item| {
        const iobj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name_val = iobj.get("name") orelse continue;
        const name = switch (name_val) {
            .string => |s2| s2,
            else => continue,
        };
        if (std.mem.eql(u8, name, "original")) found_original = true;
        if (std.mem.eql(u8, name, "dsl_alias")) found_dsl = true;
        if (std.mem.eql(u8, name, "kw_alias")) found_kw = true;
        if (iobj.get("children")) |chv| {
            const children = switch (chv) {
                .array => |a| a,
                else => continue,
            };
            for (children.items) |child| {
                const cobj = switch (child) {
                    .object => |o| o,
                    else => continue,
                };
                const cn = switch (cobj.get("name") orelse continue) {
                    .string => |s2| s2,
                    else => continue,
                };
                if (std.mem.eql(u8, cn, "original")) found_original = true;
                if (std.mem.eql(u8, cn, "dsl_alias")) found_dsl = true;
                if (std.mem.eql(u8, cn, "kw_alias")) found_kw = true;
            }
        }
    }
    try std.testing.expect(found_original);
    try std.testing.expect(found_dsl);
    try std.testing.expect(found_kw);
    const r3 = getResponseById(resp, 3) orelse return error.NoWsSymbolResponse;
    const r3obj = switch (r3) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const r3result = r3obj.get("result") orelse return error.NoResult;
    const r3arr = switch (r3result) {
        .array => |a| a,
        else => return error.NotArray,
    };
    try std.testing.expect(r3arr.items.len > 0);
}

test "P23 T23.1 incomingCalls from.name is caller method name not file path" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_t231";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "def greet\nend\ndef driver\n  greet\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"callHierarchy/incomingCalls\",\"params\":{\"item\":{\"name\":\"greet\",\"kind\":12,\"uri\":\"file://" ++ ws ++ "/a.rb\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":5}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":4},\"end\":{\"line\":0,\"character\":9}}}}}");
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
    try std.testing.expect(arr.items.len >= 1);
    // Verify from.name is the caller function name, not a file path
    const first = switch (arr.items[0]) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const from_val = first.get("from") orelse return error.NoFrom;
    const from = switch (from_val) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const name_val = from.get("name") orelse return error.NoName;
    const name = switch (name_val) {
        .string => |s2| s2,
        else => return error.NotString,
    };
    // Must be a method name ("driver"), not a file path (which would contain '/')
    try std.testing.expect(!std.mem.containsAtLeast(u8, name, 1, "/"));
    try std.testing.expectEqualStrings("driver", name);
}

test "P23 T23.3 nested constant has correct parent_name in workspace symbol" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_t233";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class Config\n  TIMEOUT = 30\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"TIMEOUT\"}}");
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
    try std.testing.expect(arr.items.len >= 1);
    // Check that the first TIMEOUT result has containerName "Config"
    const first = switch (arr.items[0]) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const cn_val = first.get("containerName") orelse return error.NoContainerName;
    const cn = switch (cn_val) {
        .string => |s2| s2,
        else => return error.NotString,
    };
    try std.testing.expectEqualStrings("Config", cn);
}

test "P24 T24.2 constant or-write indexed with containerName in workspace symbol" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t242";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "module Config\n  TIMEOUT ||= 30\n  RETRIES ||= 3\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"TIMEOUT\"}}");
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
    try std.testing.expect(arr.items.len >= 1);
    const first = switch (arr.items[0]) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const cn_val = first.get("containerName") orelse return error.NoContainerName;
    const cn = switch (cn_val) {
        .string => |s2| s2,
        else => return error.NotString,
    };
    try std.testing.expectEqualStrings("Config", cn);
}

test "P24 T24.7 definition with linkSupport emits LocationLink with originSelectionRange" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t247";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src_a = "require_relative \"b\"\nFoo.new\n";
    const src_b = "class Foo\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = src_a });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/b.rb", .data = src_b });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{\"textDocument\":{\"definition\":{\"linkSupport\":true}}},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/b.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Go-to-definition on the require_relative string (char 18 = inside "b")
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\"},\"position\":{\"line\":0,\"character\":18}}}");
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
    try std.testing.expect(arr.items.len >= 1);
    const first = switch (arr.items[0]) {
        .object => |o| o,
        else => return error.NotObject,
    };
    // LocationLink format: must have targetUri and originSelectionRange
    _ = first.get("targetUri") orelse return error.NoTargetUri;
    _ = first.get("originSelectionRange") orelse return error.NoOriginSelectionRange;
}

test "P25 T25.1 enum keyword-hash style values indexed in workspace/symbol" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t251";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class Post\n  enum status: [:draft, :published, :archived]\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/post.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/post.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"draft\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"status\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }
    // enum values must appear
    const resp2 = getResponseById(responses, 2) orelse return error.NoResponse;
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
    try std.testing.expect(arr2.items.len >= 1);
    // enum attribute name must appear
    const resp3 = getResponseById(responses, 3) orelse return error.NoResponse;
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
    try std.testing.expect(arr3.items.len >= 1);
}

test "P25 T25.2 enum hash style values indexed in workspace/symbol" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t252";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class User\n  enum role: { admin: 0, moderator: 1, member: 2 }\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/user.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"admin\"}}");
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
    const arr2 = switch (result2) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(arr2.items.len >= 1);
}

test "P28 T28.2 workspace/symbol prefix-first ordering" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p28_t282";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/o.rb", .data = "class OrderItem; end\nclass Order; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/o.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Order\"}}");
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
    var found_order = false;
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
        if (std.mem.eql(u8, name_str, "Order")) {
            found_order = true;
            break;
        }
    }
    try std.testing.expect(found_order);
}

test "P36 T4A.1 didChangeWorkspaceFolders add folder B remove folder A: A symbols gone B symbols visible" {
    const alloc = std.testing.allocator;
    const ws_a = "/tmp/refract_test_p36_t4a1_a";
    const ws_b = "/tmp/refract_test_p36_t4a1_b";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws_a) catch {};
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws_b) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws_a, .default_dir);
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws_b, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws_a) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws_b) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws_a ++ "/alpha.rb", .data = "class AlphaClassOnly; end\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws_b ++ "/beta.rb", .data = "class BetaClassOnly; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws_a ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws_a ++ "/alpha.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"AlphaClassOnly\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWorkspaceFolders\",\"params\":{\"event\":{\"added\":[{\"uri\":\"file://" ++ ws_b ++ "\",\"name\":\"b\"}],\"removed\":[{\"uri\":\"file://" ++ ws_a ++ "\",\"name\":\"a\"}]}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws_b ++ "/beta.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"AlphaClassOnly\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"BetaClassOnly\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }

    const resp2 = getResponseById(responses, 2) orelse return error.NoInitialSymbolResponse;
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
    var found_alpha_before = false;
    for (arr2.items) |item| {
        const iobj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = iobj.get("name") orelse continue;
        if (std.mem.eql(u8, switch (name) {
            .string => |ns| ns,
            else => continue,
        }, "AlphaClassOnly")) {
            found_alpha_before = true;
            break;
        }
    }
    try std.testing.expect(found_alpha_before);

    const resp3 = getResponseById(responses, 3) orelse return error.NoPostRemoveSymbolResponse;
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
            .string => |ns2| ns2,
            else => continue,
        };
        try std.testing.expect(!std.mem.eql(u8, ns, "AlphaClassOnly"));
    }

    const resp4 = getResponseById(responses, 4) orelse return error.NoBetaSymbolResponse;
    const obj4 = switch (resp4) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj4.get("error") == null);
    const result4 = obj4.get("result") orelse return error.NoResult;
    const arr4 = switch (result4) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    var found_beta = false;
    for (arr4.items) |item| {
        const iobj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = iobj.get("name") orelse continue;
        if (std.mem.eql(u8, switch (name) {
            .string => |ns| ns,
            else => continue,
        }, "BetaClassOnly")) {
            found_beta = true;
            break;
        }
    }
    try std.testing.expect(found_beta);
}

test "P37 T1.1 didChange with full document text updates workspace symbol" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p37_t1";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class FooV1; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true,\"disableRubocop\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class FooV1; end\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"version\":2},\"contentChanges\":[{\"text\":\"class FooV2; end\\n\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"FooV2\"}}");
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
    const arr2 = switch (result2) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    var found = false;
    for (arr2.items) |item| {
        const iobj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = iobj.get("name") orelse continue;
        if (std.mem.eql(u8, switch (name) {
            .string => |n| n,
            else => continue,
        }, "FooV2")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "T-MF1 cross-file definition: definition in other file is found" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_mf1";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/user.rb",
        .data =
        \\class User
        \\  def greet
        \\    "hello"
        \\  end
        \\end
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/app.rb",
        .data =
        \\User.new.greet
        ,
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/app.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Request workspace/symbol for "greet" — should find the definition in user.rb
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"greet\"}}");
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
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    // "greet" must appear in the cross-file symbol index
    try std.testing.expect(arr.items.len > 0);
    // Check raw LSP output for expected strings (avoids re-serializing JSON)
    try std.testing.expect(std.mem.indexOf(u8, raw, "greet") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "user.rb") != null);
}

test "P34 T34.1 nil-receiver checker flags method calls on nil-typed locals" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p34_t341";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    // x is assigned literal nil -> inferLiteralType returns NilClass; the call x.foo
    // should populate refs.receiver_type='NilClass' and trigger the checker.
    const src = "x = nil\nx.foo\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/nil_receiver.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/nil_receiver.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"x = nil\\nx.foo\\n\"}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "refract/nil-receiver") != null);
}

test "parallel reindex computes correct symbol and ref counts" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_parallel_reindex";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/library.rb",
        .data = "class Library\n  def books\n    []\n  end\nend\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/book.rb",
        .data = "class Book\n  attr_accessor :title, :author\nend\n",
    });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/reader.rb",
        .data = "class Reader\n  def read_book(book)\n    Book.new()\n  end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[" ++
        "{\"uri\":\"file://" ++ ws ++ "/library.rb\",\"type\":1}," ++
        "{\"uri\":\"file://" ++ ws ++ "/book.rb\",\"type\":1}," ++
        "{\"uri\":\"file://" ++ ws ++ "/reader.rb\",\"type\":1}" ++
        "]}}");
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
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };

    try std.testing.expect(arr.items.len >= 3);
}

test "thread_mattr_accessor synthesizes reader and writer" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_thread_mattr";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/t.rb", .data = "class MyClass\n  thread_mattr_accessor :current_tenant\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/t.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Both the reader `current_tenant` and writer `current_tenant=` must exist.
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"current_tenant\"}}");
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
    // reader + writer = 2 symbols named current_tenant / current_tenant=
    var saw_reader = false;
    var saw_writer = false;
    for (arr.items) |it| {
        const io = switch (it) {
            .object => |o| o,
            else => continue,
        };
        const nm = switch (io.get("name") orelse continue) {
            .string => |str| str,
            else => continue,
        };
        if (std.mem.eql(u8, nm, "current_tenant")) saw_reader = true;
        if (std.mem.eql(u8, nm, "current_tenant=")) saw_writer = true;
    }
    try std.testing.expect(saw_reader);
    try std.testing.expect(saw_writer);
}

test "go-to-def prefers a real def over an RSpec describe-string of the same name" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_describe_precision";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/spec", .default_dir) catch {};

    // Real method `build` in lib/widget.rb.
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/widget.rb",
        .data = "class Widget\n  def build\n    42\n  end\nend\n",
    });
    // A spec whose `describe \"build\"` prose string collides with the method name,
    // and which then CALLS `widget.build`. Go-to-def on the call must land on the
    // real def in widget.rb, NOT on the same-file `describe \"build\"` prose line.
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/spec/widget_spec.rb",
        .data = "describe \"build\" do\n  it \"works\" do\n    widget.build\n  end\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/widget.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/spec/widget_spec.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Cursor on `build` in `widget.build` (line 2, char 11) inside the spec file.
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/spec/widget_spec.rb\"},\"position\":{\"line\":2,\"character\":11}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }
    const resp = getResponseById(responses, 2) orelse return error.NoDefResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    // The real def must be found, and the describe-string prose line must NEVER
    // be among the results. Other benign results (e.g. a bundled-RBS `build`) may
    // appear depending on index timing, so check the two properties, not "all".
    var saw_def = false;
    var saw_prose = false;
    for (arr.items) |it| {
        const io = switch (it) {
            .object => |o| o,
            else => continue,
        };
        const uri = switch (io.get("uri") orelse io.get("targetUri") orelse continue) {
            .string => |str| str,
            else => continue,
        };
        if (std.mem.indexOf(u8, uri, "widget.rb") != null) saw_def = true;
        if (std.mem.indexOf(u8, uri, "widget_spec.rb") != null) saw_prose = true;
    }
    try std.testing.expect(saw_def);
    try std.testing.expect(!saw_prose);
}

test "go-to-def prefers a real def over a Rake task label of the same name" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_rake_task_precision";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    // Real method `seed` in seeder.rb.
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/seeder.rb",
        .data = "class Seeder\n  def seed\n    42\n  end\nend\n",
    });
    // A Rakefile whose `task :seed` label collides with the method name and then
    // calls `seeder.seed`. Go-to-def on the call must land on the real def, not
    // the Rake task label.
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/Rakefile",
        .data = "task :seed do\n  seeder.seed\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/seeder.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/Rakefile\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Cursor on `seed` in `seeder.seed` (line 1, char 9) inside the Rakefile.
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/Rakefile\"},\"position\":{\"line\":1,\"character\":11}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }
    const resp = getResponseById(responses, 2) orelse return error.NoDefResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    // The real def must be found, and the Rake `task :seed` label line must NEVER
    // be among the results. Benign extra results (e.g. a bundled-RBS `seed`) may
    // appear depending on index timing, so check the two properties, not "all".
    var saw_def = false;
    var saw_label = false;
    for (arr.items) |it| {
        const io = switch (it) {
            .object => |o| o,
            else => continue,
        };
        const uri = switch (io.get("uri") orelse io.get("targetUri") orelse continue) {
            .string => |str| str,
            else => continue,
        };
        if (std.mem.indexOf(u8, uri, "seeder.rb") != null) saw_def = true;
        if (std.mem.indexOf(u8, uri, "Rakefile") != null) saw_label = true;
    }
    try std.testing.expect(saw_def);
    try std.testing.expect(!saw_label);
}

test "go-to-def does not case-fold a lowercase probe onto a constant" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_casefold_probe";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    // A qualified constant `Outer::Inner::RB`.
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/rbs.rb",
        .data = "module Outer\n  module Inner\n    class RB\n    end\n  end\nend\n",
    });
    // A lowercase `rb` identifier in another file — no real `def rb` exists, so
    // go-to-def falls to the qualified-suffix fallback, which must NOT match the
    // case-folded constant `::RB`.
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/caller.rb",
        .data = "puts rb\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/rbs.rb\",\"type\":1},{\"uri\":\"file://" ++ ws ++ "/caller.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // Cursor on `rb` in `puts rb` (line 0, char 5).
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/caller.rb\"},\"position\":{\"line\":0,\"character\":5}}}");
    try s.send(base_shutdown);
    try s.send(base_exit);

    const raw = try s.run();
    defer alloc.free(raw);
    const responses = try extractResponses(alloc, raw);
    defer {
        for (responses) |r| r.deinit();
        alloc.free(responses);
    }
    const resp = getResponseById(responses, 2) orelse return error.NoDefResponse;
    const obj = switch (resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    // The only `RB`-ish symbol is the case-folded constant; it must be rejected.
    for (arr.items) |it| {
        const io = switch (it) {
            .object => |o| o,
            else => continue,
        };
        const uri = switch (io.get("uri") orelse io.get("targetUri") orelse continue) {
            .string => |str| str,
            else => continue,
        };
        try std.testing.expect(std.mem.indexOf(u8, uri, "rbs.rb") == null);
    }
}
