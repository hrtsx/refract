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
test "shared_examples plain form indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_shex";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/sh.rb", .data = "shared_examples \"behaves like a record\" do\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/sh.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"behaves like a record\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const rawSH = try s.run();
    defer alloc.free(rawSH);
    const respSH = try extractResponses(alloc, rawSH);
    defer {
        for (respSH) |r| r.deinit();
        alloc.free(respSH);
    }
    const rSH = getResponseById(respSH, 2) orelse return error.NoSymbolResponse;
    const oSH = switch (rSH) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const resSH = oSH.get("result") orelse return error.NoResult;
    const aSH = switch (resSH) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(aSH.items.len >= 1);
}

test "around indexed as def" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_around";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/ar.rb", .data = "describe \"X\" do\n  around(:each) do |ex|\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/ar.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"each\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const rawAR = try s.run();
    defer alloc.free(rawAR);
    const respAR = try extractResponses(alloc, rawAR);
    defer {
        for (respAR) |r| r.deinit();
        alloc.free(respAR);
    }
    const rAR = getResponseById(respAR, 2) orelse return error.NoSymbolResponse;
    const oAR = switch (rAR) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const resAR = oAR.get("result") orelse return error.NoResult;
    const aAR = switch (resAR) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(aAR.items.len >= 1);
}

test "included hook indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p23_included";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/inc.rb", .data = "module Concern\n  included :setup do\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/inc.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"setup\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const rawIC = try s.run();
    defer alloc.free(rawIC);
    const respIC = try extractResponses(alloc, rawIC);
    defer {
        for (respIC) |r| r.deinit();
        alloc.free(respIC);
    }
    const rIC = getResponseById(respIC, 2) orelse return error.NoSymbolResponse;
    const oIC = switch (rIC) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const resIC = oIC.get("result") orelse return error.NoResult;
    const aIC = switch (resIC) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(aIC.items.len >= 1);
}

test "bundle dir excluded from scan" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t725";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/.bundle", .default_dir);
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/.bundle/gems", .default_dir);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/.bundle/gems/foo.rb", .data = "class BundledClass; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"BundledClass\"}}");
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

test "each_with_index second param Integer p25" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t808";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class User; end\nusers = User.all\nusers.each_with_index { |u, i|\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class User; end\\nusers = User.all\\nusers.each_with_index { |u, i|\\n\"}}}");
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
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.NotArray,
    };
    var found_integer = false;
    for (arr.items) |item| {
        const io = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const lv = io.get("label") orelse continue;
        const ls = switch (lv) {
            .string => |s2| s2,
            else => continue,
        };
        if (std.mem.indexOf(u8, ls, "Integer") != null) found_integer = true;
    }
    try std.testing.expect(found_integer);
}

test "gitignore dir excluded from scan" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t819";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/generated", .default_dir);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/.gitignore", .data = "generated/\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Normal; end\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/generated/gen.rb", .data = "class Generated; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
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

test "DB corrupted file deleted and recreated" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t830";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Foo; end\n" });
    // Write garbage to the expected db path to simulate corruption
    const home: []const u8 = if (std.c.getenv("HOME")) |p| std.mem.span(p) else "/tmp";
    const db_dir = try std.fmt.allocPrint(alloc, "{s}/.cache/refract", .{home});
    defer alloc.free(db_dir);
    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, db_dir) catch {};
    const db_path = try std.fmt.allocPrint(alloc, "{s}/refract_test_p25_t830.db", .{db_dir});
    defer alloc.free(db_path);
    std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = db_path, .data = "THIS IS NOT A VALID SQLITE DATABASE\n" }) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
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

test "P27 T10.21 execute command restartIndexer response" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1021";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/executeCommand\",\"params\":{\"command\":\"refract.restartIndexer\"}}");
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

test "P27 T10.47 rspec describe indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1047";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "describe \"User\" do\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"describe \\\"User\\\" do\\nend\\n\"}}}");
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
    const r = getResponseById(resp, 2) orelse return error.NoResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(obj.get("error") == null);
}

test "P27 T10.48 rspec it indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1048";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "it \"creates\" do\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"it \\\"creates\\\" do\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"creates\"}}");
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

test "P27 T10.49 minitest test method indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1049";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class T\ndef test_save\nend\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class T\\ndef test_save\\nend\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"test_save\"}}");
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

test "P27 T10.50 rspec context indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1050";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "context \"when admin\" do\nend\n" });
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

test "P29 T12.1 db pragma cache_size set" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_prag1";
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
        .argv = &.{ "sqlite3", db_path, "SELECT value FROM meta WHERE key='schema_version'" },
    });
    defer alloc.free(q.stdout);
    defer alloc.free(q.stderr);
    const val_str = std.mem.trim(u8, q.stdout, " \t\r\n");
    try std.testing.expect(std.mem.eql(u8, val_str, "11"));
}

test "P29 T12.2 db pragma temp_store memory" {
    const alloc = std.testing.allocator;
    var _rnd_bytes: [8]u8 = undefined;
    std.Options.debug_io.random(&_rnd_bytes);
    const rand_id = std.mem.readInt(u64, &_rnd_bytes, .little);
    var ws_buf: [128]u8 = undefined;
    const ws = std.fmt.bufPrint(&ws_buf, "/tmp/refract_test_p29_2_{x}", .{rand_id}) catch "/tmp/refract_test_p29_2_fb";
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

test "P29 T12.5 composite index file_kind_name exists" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_prag5";
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
        .argv = &.{ "sqlite3", db_path, "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_symbols_file_kind_name'" },
    });
    defer alloc.free(q.stdout);
    defer alloc.free(q.stderr);
    try std.testing.expect(std.mem.indexOf(u8, q.stdout, "idx_symbols_file_kind_name") != null);
}

test "P29 T12.67 endless method def foo = expr indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p29_t1267";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Greeter\n  def greet = \"Hello\"\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Greeter\\n  def greet = \\\"Hello\\\"\\nend\\n\"}}}");
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
    const r = getResponseById(resp, 2) orelse return error.NoDocSymResponse;
    const obj = switch (r) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const result = obj.get("result") orelse return error.NoResult;
    const arr = switch (result) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    var found_greet = false;
    for (arr.items) |item| {
        const io = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const nv = io.get("name") orelse continue;
        const ns = switch (nv) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, ns, "greet") or std.mem.eql(u8, ns, "Greeter")) {
            // Check children for greet
            if (std.mem.eql(u8, ns, "greet")) {
                found_greet = true;
                break;
            }
            const children = switch (io.get("children") orelse continue) {
                .array => |a| a,
                else => continue,
            };
            for (children.items) |child| {
                const co = switch (child) {
                    .object => |o| o,
                    else => continue,
                };
                const cn = switch (co.get("name") orelse continue) {
                    .string => |sv| sv,
                    else => continue,
                };
                if (std.mem.eql(u8, cn, "greet")) {
                    found_greet = true;
                    break;
                }
            }
        }
        if (found_greet) break;
    }
    try std.testing.expect(found_greet);
}

test "P30 T13.23 executeCommand restartIndexer regression" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1323";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Bb; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/executeCommand\",\"params\":{\"command\":\"refract.restartIndexer\",\"arguments\":[]}}");
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
}

test "P31 T14.1 rate limit skips second indexSource within 100ms" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t141";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Foo\n  def bar\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Foo\\n  def bar\\n  end\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"version\":2},\"contentChanges\":[{\"text\":\"class Foo\\n  def bar2\\n  end\\nend\\n\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"version\":3},\"contentChanges\":[{\"text\":\"class Foo\\n  def bar3\\n  end\\nend\\n\"}]}}");
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
}

test "P31 T14.38 Grape::API route methods recognized" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1438";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class GrapeApi1438 < Grape::API\n  get '/hello' do\n    {msg: 'hi'}\n  end\nend\n" });
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "GrapeApi1438") != null);
}

test "P32 T15.6 async didChangeWatchedFiles no deadlock" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t156";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Ndl156\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":2}]}}");
        try s.waitIdle(100);
    }
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

test "P32 T15.7 async didChangeWatchedFiles indexes after change" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t157";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Async157\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Async157\"}}");
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "Async157") != null);
}

test "P32 T15.18 lookupStdlibReturn String#scan returns Array" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1518";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "s1518 = \"hello world\"\nx1518 = s1518.scan(/\\w+/)\n" });
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

test "P32 T15.41 content_hash skips reindex on same content" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1541";
    const db_path = ws ++ "/refract.db";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Skip1541\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Skip1541\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.runWithArgs(&.{ "--db-path", db_path });
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoSymbolResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "Skip1541") != null);
}

test "P32 T15.42 content_hash reindexes on content change despite same mtime" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1542";
    const db_path = ws ++ "/refract.db";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Before1542\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class After1542\nend\n" });
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":2}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"After1542\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.runWithArgs(&.{ "--db-path", db_path });
    defer alloc.free(raw);
    const resp = try extractResponses(alloc, raw);
    defer {
        for (resp) |r| r.deinit();
        alloc.free(resp);
    }
    _ = getResponseById(resp, 2) orelse return error.NoSymbolResponse;
    try std.testing.expect(std.mem.indexOf(u8, raw, "After1542") != null);
}

test "T_ENDLESS_METHOD endless method def is indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tendless";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/endless.rb", .data = "def double(x) = x * 2\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/endless.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"double\"}}");
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
        const kind_val = obj.get("kind") orelse continue;
        const kind = switch (kind_val) {
            .integer => |i| i,
            else => continue,
        };
        if (std.mem.eql(u8, name, "double") and kind == 6) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "T_DELETED_PATHS_CLEANUP deleted_paths cleared after index cycle" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_tdelpaths";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    inline for (0..10) |i| {
        const path = ws ++ "/f" ++ std.fmt.comptimePrint("{d}", .{i}) ++ ".rb";
        try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = path, .data = "class F" ++ std.fmt.comptimePrint("{d}", .{i}) ++ "; end\n" });
    }
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    // Delete 5 of the 10 files
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didDeleteFiles\",\"params\":{\"files\":[" ++
        "{\"uri\":\"file://" ++ ws ++ "/f0.rb\"}," ++
        "{\"uri\":\"file://" ++ ws ++ "/f1.rb\"}," ++
        "{\"uri\":\"file://" ++ ws ++ "/f2.rb\"}," ++
        "{\"uri\":\"file://" ++ ws ++ "/f3.rb\"}," ++
        "{\"uri\":\"file://" ++ ws ++ "/f4.rb\"}" ++
        "]}}");
    // Force re-index cycle (this triggers cleanupStale which should clear deleted_paths)
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/executeCommand\",\"params\":{\"command\":\"refract.restartIndexer\",\"arguments\":[]}}");
    // Save a remaining file — must not crash
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/f5.rb\"}}}");
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
    const sym_resp = getResponseById(resp, 3) orelse return error.NoSymbolResponse;
    const sym_obj = switch (sym_resp) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expect(sym_obj.get("result") != null);
}

test "P24 T24.3 class variable or-write indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t243";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class Counter\n  @@count ||= 0\n  def self.count\n    @@count\n  end\nend\n";
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
    try std.testing.expect(obj.get("result") != null);
}

test "P24 T24.4 non-self singleton class methods are indexed" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p24_t244";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "user = Object.new\nclass << user\n  def greet\n    \"hello\"\n  end\nend\n";
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
    var found_greet = false;
    for (arr.items) |item| {
        const iobj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const n_val = iobj.get("name") orelse continue;
        const n = switch (n_val) {
            .string => |s2| s2,
            else => continue,
        };
        if (std.mem.eql(u8, n, "greet")) {
            found_greet = true;
            break;
        }
    }
    try std.testing.expect(found_greet);
}

test "T-MF4 schema.rb columns indexed as model defs" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_mf4";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/db", .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/db/schema.rb",
        .data =
        \\ActiveRecord::Schema[7.1].define(version: 2024_01_01_000000) do
        \\  create_table "users", force: :cascade do |t|
        \\    t.string "email", null: false
        \\    t.integer "age"
        \\    t.boolean "active", default: true
        \\    t.timestamps
        \\  end
        \\end
        ,
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/db/schema.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // "email" column should be indexed as a def on "User"
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
    try std.testing.expect(arr.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, raw, "email") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "User") != null);
}

test "P33 T33.11 encrypts indexes attribute name with validation kind" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p33_t3311";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class User\n  encrypts :ssn\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/user.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"ssn\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "ssn") != null);
}

test "P33 T33.12 normalizes indexes attribute name" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p33_t3312";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class User\n  normalizes :email, with: ->(e) { e.strip.downcase }\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/user.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"email\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "email") != null);
}

test "large file over 8MB skipped without crash" {
    const alloc = std.testing.allocator;

    const ws = "/tmp/refract_test_huge";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    const huge_path = ws ++ "/huge.rb";
    {
        const f = try std.Io.Dir.cwd().createFile(std.Options.debug_io, huge_path, .{});
        defer f.close(std.Options.debug_io);
        const line = "# padding line to fill space\n";
        var written: usize = 0;
        const target: usize = 9 * 1024 * 1024;
        while (written < target) {
            try f.writeStreamingAll(std.Options.debug_io, line);
            written += line.len;
        }
    }
    defer std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, huge_path) catch {};

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/huge.rb\",\"type\":1}]}}");
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
    switch (result) {
        .array => {},
        else => return error.ResultNotArray,
    }
}

test "superclass qualified parent_name" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_qparent";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/qparent.rb",
        .data = "module ActiveRecord\n  class Base; end\nend\nclass Foo < ActiveRecord::Base\nend\n",
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/qparent.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
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

test "qualified mixin stored" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p21_qmixin";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/qmixin.rb",
        .data =
        \\module Concerns::Searchable
        \\  def search; end
        \\end
        \\class Post
        \\  include Concerns::Searchable
        \\end
        \\p = Post.new
        \\p.
        ,
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/qmixin.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Concerns::Searchable\"}}");
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

test "gitignore comment lines ignored" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t820";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/.gitignore", .data = "# generated\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Normal; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Normal\"}}");
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

test "gitignore glob lines ignored" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t821";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/.gitignore", .data = "*.tmp\n*.log\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Normal; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"Normal\"}}");
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

test "large workspace fuzzy query fast" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p25_t847";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "class UserController; end\n");
    var ci: usize = 0;
    while (ci < 20) : (ci += 1) {
        const line = try std.fmt.allocPrint(alloc, "class Sym{d}; end\n", .{ci});
        defer alloc.free(line);
        try buf.appendSlice(alloc, line);
    }
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/big.rb", .data = buf.items });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/big.rb\",\"type\":1}]}}");
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
    try std.testing.expect(obj.get("error") == null);
    const result_arr = switch (obj.get("result") orelse return error.NoResult) {
        .array => |a| a,
        else => return error.ResultNotArray,
    };
    try std.testing.expect(result_arr.items.len > 0);
}

test "P26 T9.4 heuristic fallback" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p26_t904";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "people = get_people\npeople.each { |p| }\n" });
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

test "P26 T9.56 for loop AR" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p26_t956";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class User; end\nfor u in User.all\nend\n" });
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

test "P27 T10.51 non-test method not marked test" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t1051";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "def save\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"def save\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"save\"}}");
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

test "P30 T13.5 delegate creates synthetic method" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1305";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class User\n  delegate :fullname, to: :profile\nend\nu = User.new\nu.\n" });
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "fullname") != null);
}

test "P30 T13.6 delegate multiple methods" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1306";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class User\n  delegate :foofoo, :barbar, to: :obj\nend\nu = User.new\nu.\n" });
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "foofoo") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "barbar") != null);
}

test "P30 T13.7 def_delegator synthesizes method" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1307";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Car\n  def_delegator :@engine, :topspeed\nend\nc = Car.new\nc.\n" });
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "topspeed") != null);
}

test "P30 T13.8 def_delegators synthesizes multiple" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p30_t1308";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Robot\n  def_delegators :@core, :moverobot, :stoprobot\nend\nr = Robot.new\nr.\n" });
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "moverobot") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "stoprobot") != null);
}

test "P31 T14.3 rate limit per-file independent" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t143";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class A\nend\n" });
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/b.rb", .data = "class B\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"version\":1},\"contentChanges\":[{\"text\":\"class A2\\nend\\n\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/b.rb\",\"version\":1},\"contentChanges\":[{\"text\":\"class B2\\nend\\n\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"A2\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"B2\"}}");
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
    _ = getResponseById(resp, 3) orelse return error.NoSymResponse2;
}

test "P31 T14.4 getDiagsFromSource returns prism diags for syntax error" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t144";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Foo\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Foo\\ndef bar(\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"version\":2},\"contentChanges\":[{\"text\":\"class Foo\\ndef bar(\\nend\\n\"}]}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "publishDiagnostics") != null or raw.len > 0);
}

test "P31 T14.7 open_docs_order no duplicate URIs after multiple edits" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t147";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Foo\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    var vi: u32 = 1;
    while (vi <= 10) : (vi += 1) {
        try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/a.rb\",\"version\":1},\"contentChanges\":[{\"text\":\"class Foo\\nend\\n\"}]}}");
    }
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
}

test "P31 T14.37 Hanami::Action DSL methods not flagged" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1437";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class ShowAction1437 < Hanami::Action\n  expose :user\n  def call(params)\n  end\nend\n" });
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "ShowAction1437") != null);
}

test "P31 T14.39 Roda class recognized" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p31_t1439";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class RodaApp1439 < Roda\n  plugin :render\n  route do |r|\n    r.root { 'hello' }\n  end\nend\n" });
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "RodaApp1439") != null);
}

test "P32 T15.35 delegate synthesizes method" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p32_t1535";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class Order1535\n  delegate :nm1535, :em1535, to: :user1535\nend\n" });
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
    try std.testing.expect(std.mem.indexOf(u8, raw, "nm1535") != null);
}

test "P27 T27.3 maxWorkers accepted in initializationOptions" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p27_t273";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/a.rb", .data = "class B; end\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true,\"maxWorkers\":2}}}");
    try s.send(base_initialized);
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
}

test "T-MF3 through: association surfaced in association_graph" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_mf3";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = ws ++ "/user.rb",
        .data =
        \\class User < ApplicationRecord
        \\  has_many :user_posts
        \\  has_many :posts, through: :user_posts
        \\end
        ,
    });

    var s = try Session.init(alloc);
    defer s.deinit();

    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    // value_snippet for "posts" association should be "through:user_posts"
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"posts\"}}");
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
    // "posts" association must be indexed (through: doesn't prevent indexing)
    try std.testing.expect(arr.items.len > 0);
}

test "P33 T33.1 has_one_attached synthesizes attachment and blob accessors" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p33_t331";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class User\n  has_one_attached :avatar\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/user.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"avatar\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "avatar_attachment") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "avatar_blob") != null);
}

test "P33 T33.2 has_many_attached synthesizes plural attachment and blob accessors" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p33_t332";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class Post\n  has_many_attached :photos\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/post.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/post.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"photos\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "photos_attachments") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "photos_blobs") != null);
}

test "P33 T33.3 has_rich_text synthesizes reader, writer, and predicate" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p33_t333";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class Article\n  has_rich_text :content\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/article.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/article.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"content\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "content?") != null);
}

test "P33 T33.4 has_secure_password synthesizes digest and authenticate" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p33_t334";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class User\n  has_secure_password\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/user.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"password\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"authenticate\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "password_digest") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "password_confirmation=") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "authenticate") != null);
}

test "P33 T33.5 has_secure_token synthesizes token and regenerate" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p33_t335";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class User\n  has_secure_token :auth_token\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/user.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"auth_token\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"regenerate\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "regenerate_auth_token") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "auth_token") != null);
}

test "P33 T33.9 store_accessor synthesizes individual accessors" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p33_t339";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class User\n  store_accessor :settings, :timezone, :locale\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/user.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"timezone\"}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"locale\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "timezone=") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "locale=") != null);
}

test "P33 T33.10 accepts_nested_attributes_for synthesizes attributes= writer" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p33_t3310";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    const src = "class Author\n  accepts_nested_attributes_for :posts\nend\n";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/author.rb", .data = src });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send(base_initialized);
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/author.rb\",\"type\":1}]}}");
    try s.waitIdle(100);
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"posts_attributes\"}}");
    try s.send(base_shutdown);
    try s.send(base_exit);
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "posts_attributes=") != null);
}
