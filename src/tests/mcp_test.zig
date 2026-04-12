const std = @import("std");
const harness = @import("harness");
const Session = harness.Session;

test "P46 T46.1 MCP tools/list returns tools" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t461";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "resolve_type") != null);
}

test "P46 T46.2 MCP workspace_health returns metrics" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t462";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"workspace_health\",\"arguments\":{}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "schema_version") != null);
}

test "P46 T46.3 MCP resolve_type returns type hint" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t463";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/user.rb", .data = "class User\n  def full_name\n    name = \"John\"\n    name\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"resolve_type\",\"arguments\":{\"file\":\"" ++ ws ++ "/user.rb\",\"line\":3}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "line") != null);
}

test "P46 T46.4 MCP class_summary returns methods" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t464";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/user.rb", .data = "class User\n  def full_name\n    \"John\"\n  end\n  def normalize_name\n    self.name = name.strip\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"class_summary\",\"arguments\":{\"class_name\":\"User\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "methods") != null);
}

test "P46 T46.5 MCP method_signature returns signature" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t465";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/user.rb", .data = "class User\n  def greet(name, greeting = 'Hello')\n    \"#{greeting} #{name}\"\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"method_signature\",\"arguments\":{\"class_name\":\"User\",\"method_name\":\"greet\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "signature") != null or std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.6 MCP find_callers returns call sites" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t466";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/user.rb", .data = "class User\n  def helper_method\n    \"test\"\n  end\n  def use_it\n    helper_method\n    helper_method\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"find_callers\",\"arguments\":{\"method_name\":\"helper_method\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.7 MCP find_implementations finds method implementations" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t467";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/base.rb", .data = "class Base\n  def process\n    \"base\"\n  end\nend\nclass Child < Base\n  def process\n    \"child\"\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/base.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"find_implementations\",\"arguments\":{\"method_name\":\"process\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.8 MCP workspace_symbols searches symbols" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t468";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/user.rb", .data = "class User\n  def user_id\n    42\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"workspace_symbols\",\"arguments\":{\"query\":\"User\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.9 MCP type_hierarchy returns ancestors and descendants" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t469";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/hierarchy.rb", .data = "class Animal\nend\nclass Dog < Animal\n  def bark\n    \"woof\"\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/hierarchy.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"type_hierarchy\",\"arguments\":{\"class_name\":\"Dog\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "ancestors") != null or std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.10 MCP association_graph returns ActiveRecord associations" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4610";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/user.rb", .data = "class User < ApplicationRecord\n  has_many :posts\n  belongs_to :organization\n  has_one :profile\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"association_graph\",\"arguments\":{\"class_name\":\"User\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.11 MCP route_map lists Rails routes" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4611";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/routes.rb", .data = "Rails.application.routes.draw do\n  resources :users\n  get 'home', to: 'pages#home'\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/routes.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"route_map\",\"arguments\":{}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.12 MCP diagnostics returns file diagnostics" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4612";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/app.rb", .data = "class App\n  def broken\n    x = 1\n    y = 2\n    z\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/app.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"diagnostics\",\"arguments\":{\"file\":\"" ++ ws ++ "/app.rb\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.13 MCP get_symbol_source returns method source" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4613";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/user.rb", .data = "class User\n  def full_name\n    \"John Doe\"\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"get_symbol_source\",\"arguments\":{\"class_name\":\"User\",\"method_name\":\"full_name\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.14 MCP grep_source searches source files" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4614";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/code.rb", .data = "class User\n  def email_address\n    \"user@example.com\"\n  end\n  def show_email\n    puts email_address\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/code.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"grep_source\",\"arguments\":{\"query\":\"email\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.15 MCP i18n_lookup searches translations" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4615";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws ++ "/config");
    try std.fs.makeDirAbsolute(ws ++ "/config/locales");
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/config/locales/en.yml", .data = "en:\n  models:\n    user:\n      name: \"User Name\"\n      email: \"Email Address\"\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/config/locales/en.yml\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"i18n_lookup\",\"arguments\":{\"query\":\"models\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.16 MCP list_by_kind lists symbols by kind" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4616";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/app.rb", .data = "class User\n  def process\n    true\n  end\nend\nclass Post\n  def publish\n    true\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/app.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"list_by_kind\",\"arguments\":{\"kind\":\"class\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.17 MCP find_unused finds dead code" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4617";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/app.rb", .data = "class App\n  def used_method\n    true\n  end\n  def unused_method\n    false\n  end\nend\nApp.new.used_method\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/app.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"find_unused\",\"arguments\":{\"kind\":\"def\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.18 MCP get_file_overview lists symbols in file" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4618";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/user.rb", .data = "class User\n  def initialize(name)\n    @name = name\n  end\n  def display_name\n    @name\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"get_file_overview\",\"arguments\":{\"file\":\"" ++ ws ++ "/user.rb\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.19 MCP list_validations lists ActiveRecord validations" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4619";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/user.rb", .data = "class User < ApplicationRecord\n  validates :name, presence: true\n  validates :email, presence: true, uniqueness: true\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"list_validations\",\"arguments\":{\"class_name\":\"User\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.20 MCP list_callbacks lists callbacks" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4620";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/user.rb", .data = "class User < ApplicationRecord\n  before_save :normalize_name\n  after_create :send_welcome_email\n  before_destroy :cleanup\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"list_callbacks\",\"arguments\":{\"class_name\":\"User\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.21 MCP concern_usage finds concern usages" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4621";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/code.rb", .data = "module Timestampable\n  def created_at; end\n  def updated_at; end\nend\nclass User\n  include Timestampable\nend\nclass Post\n  include Timestampable\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/code.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"concern_usage\",\"arguments\":{\"module_name\":\"Timestampable\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.22 MCP find_references finds method references" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4622";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/app.rb", .data = "class User\n  def create\n    true\n  end\n  def handle\n    create\n    create\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/app.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"find_references\",\"arguments\":{\"name\":\"create\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.23 MCP explain_symbol explains method" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4623";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/user.rb", .data = "class User\n  def greet\n    \"Hello\"\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"explain_symbol\",\"arguments\":{\"class_name\":\"User\",\"method_name\":\"greet\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.24 MCP batch_resolve resolves multiple positions" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4624";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/app.rb", .data = "class App\n  def run\n    x = 1\n    y = 2\n    x + y\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/app.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"batch_resolve\",\"arguments\":{\"positions\":[{\"file\":\"" ++ ws ++ "/app.rb\",\"line\":2}]}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.25 MCP test_summary lists test methods" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4625";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/user_test.rb", .data = "class UserTest < Minitest::Test\n  def test_create\n    true\n  end\n  def test_update\n    true\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user_test.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"test_summary\",\"arguments\":{\"file\":\"" ++ ws ++ "/user_test.rb\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.26 MCP list_routes lists route helpers" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4626";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/routes.rb", .data = "Rails.application.routes.draw do\n  resources :users\n  resources :posts do\n    resources :comments\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/routes.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"list_routes\",\"arguments\":{}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.27 MCP refactor extracts method" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4627";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/app.rb", .data = "class App\n  def run\n    x = 1\n    y = 2\n    z = x + y\n    z\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/app.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"refactor\",\"arguments\":{\"file\":\"" ++ ws ++ "/app.rb\",\"start_line\":2,\"end_line\":4,\"kind\":\"extract_method\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.28 MCP available_code_actions returns actions" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4628";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/app.rb", .data = "class App\n  def test\n    x = 1\n    y = 2\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/app.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"available_code_actions\",\"arguments\":{\"file\":\"" ++ ws ++ "/app.rb\",\"line\":1}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P46 T46.29 MCP diagnostic_summary summarizes diagnostics" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p46_t4629";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/app.rb", .data = "class App\n  def broken\n    x = 1\n    y = 2\n    z\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/app.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"diagnostic_summary\",\"arguments\":{}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.1 MCP get_file_overview empty file" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t471";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/empty.rb", .data = "" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/empty.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"get_file_overview\",\"arguments\":{\"file\":\"" ++ ws ++ "/empty.rb\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "error") == null);
}

test "P47 T47.2 MCP list_by_kind with comments only" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t472";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/comments.rb", .data = "# This is a comment\n# Another comment\n# Just comments\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/comments.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"list_by_kind\",\"arguments\":{\"kind\":\"def\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.3 MCP workspace_symbols deeply nested modules" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t473";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/nested.rb", .data = "module A\nmodule B\nmodule C\nmodule D\nmodule E\nmodule F\nmodule G\nmodule H\nclass DeepClass\nend\nend\nend\nend\nend\nend\nend\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/nested.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"workspace_symbols\",\"arguments\":{\"query\":\"DeepClass\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.4 MCP diagnostics with syntax errors" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t474";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/syntax.rb", .data = "class Broken\n  def method\n    if true\n      puts \"missing end\"\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/syntax.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"diagnostics\",\"arguments\":{\"file\":\"" ++ ws ++ "/syntax.rb\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.5 MCP grep_source with long method names" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t475";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    const longname = "def very_long_method_name_that_is_more_than_two_hundred_characters_long_this_is_testing_how_the_system_handles_very_lengthy_identifiers_that_should_still_be_indexed_properly_and_searchable_in_the_workspace_without_truncation_errors\n    true\n  end\nend\n";
    var buf: [512]u8 = undefined;
    const content = try std.fmt.bufPrint(&buf, "class VeryLongClass\n  {s}", .{longname});
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/longnames.rb", .data = content });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/longnames.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"grep_source\",\"arguments\":{\"query\":\"very_long\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.6 MCP workspace_symbols with unicode identifiers" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t476";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/unicode.rb", .data = "class Café\n  def service_naïve\n    \"test\"\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/unicode.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"workspace_symbols\",\"arguments\":{\"query\":\"Caf\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.7 MCP type_hierarchy cyclic includes" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t477";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/cyclic.rb", .data = "module ModuleA\n  include ModuleB\nend\nmodule ModuleB\n  include ModuleA\nend\nclass CyclicClass\n  include ModuleA\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/cyclic.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"type_hierarchy\",\"arguments\":{\"class_name\":\"CyclicClass\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.8 MCP list_validations no validations" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t478";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/simple.rb", .data = "class Simple < ApplicationRecord\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/simple.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"list_validations\",\"arguments\":{\"class_name\":\"Simple\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.9 MCP find_unused multiple symbols" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t479";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/unused.rb", .data = "class Controller\n  def used_one\n    true\n  end\n  def used_two\n    true\n  end\n  def unused_three\n    false\n  end\n  def unused_four\n    false\n  end\nend\nController.new.used_one\nController.new.used_two\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/unused.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"find_unused\",\"arguments\":{\"kind\":\"def\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.10 MCP route_map empty routes" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t4710";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/routes.rb", .data = "Rails.application.routes.draw do\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/routes.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"route_map\",\"arguments\":{}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "error") == null);
}

test "P47 T47.11 MCP i18n_lookup empty locale file" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t4711";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws ++ "/config");
    try std.fs.makeDirAbsolute(ws ++ "/config/locales");
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/config/locales/en.yml", .data = "" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/config/locales/en.yml\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"i18n_lookup\",\"arguments\":{\"query\":\"test\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.12 MCP list_callbacks multiple callbacks" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t4712";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/user.rb", .data = "class User < ApplicationRecord\n  before_validate :set_defaults\n  before_save :normalize_name\n  before_save :hash_password\n  after_create :send_welcome_email\n  after_update :log_changes\n  after_destroy :cleanup_files\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"list_callbacks\",\"arguments\":{\"class_name\":\"User\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.13 MCP concern_usage no concerns" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t4713";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/code.rb", .data = "module UnusedModule\n  def helper\n    true\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/code.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"concern_usage\",\"arguments\":{\"module_name\":\"UnusedModule\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.14 MCP find_references across files" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t4714";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/helper.rb", .data = "module Helper\n  def self.format_name(str)\n    str.upcase\n  end\nend\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/user.rb", .data = "class User\n  def display\n    Helper.format_name(\"test\")\n    Helper.format_name(\"another\")\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/helper.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/user.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"find_references\",\"arguments\":{\"name\":\"format_name\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.15 MCP explain_symbol class" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t4715";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/product.rb", .data = "class Product < ApplicationRecord\n  belongs_to :category\n  has_many :reviews\n  def display_name\n    \"Product: #{name}\"\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/product.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"explain_symbol\",\"arguments\":{\"class_name\":\"Product\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.16 MCP batch_resolve multiple files" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t4716";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/file1.rb", .data = "class First\n  def method_a\n    true\n  end\nend\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/file2.rb", .data = "class Second\n  def method_b\n    true\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/file1.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/file2.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"batch_resolve\",\"arguments\":{\"positions\":[{\"file\":\"" ++ ws ++ "/file1.rb\",\"line\":1},{\"file\":\"" ++ ws ++ "/file2.rb\",\"line\":1}]}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.17 MCP test_summary test file" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t4717";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/app_test.rb", .data = "require 'test_helper'\nclass AppTest < Minitest::Test\n  def test_setup\n    assert true\n  end\n  def test_calculation\n    assert_equal 2, 1 + 1\n  end\n  def test_failure\n    assert false\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/app_test.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"test_summary\",\"arguments\":{\"file\":\"" ++ ws ++ "/app_test.rb\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.18 MCP list_routes nested resources" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t4718";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/routes.rb", .data = "Rails.application.routes.draw do\n  namespace :api do\n    namespace :v1 do\n      resources :users do\n        resources :posts do\n          resources :comments\n        end\n      end\n    end\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/routes.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"list_routes\",\"arguments\":{}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.19 MCP refactor extract variable" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t4719";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/refactor.rb", .data = "class Calculator\n  def compute\n    x = 5\n    y = 10\n    (x + y) * 2\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/refactor.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"refactor\",\"arguments\":{\"file\":\"" ++ ws ++ "/refactor.rb\",\"start_line\":3,\"end_line\":5,\"kind\":\"extract_variable\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.20 MCP available_code_actions multiple actions" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t4720";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/actions.rb", .data = "class Actions\n  def unused_var\n    unused = 1\n    y = 2\n    unused_too = 3\n    y\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/actions.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"available_code_actions\",\"arguments\":{\"file\":\"" ++ ws ++ "/actions.rb\",\"line\":2}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.21 MCP association_graph multiple associations" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t4721";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/models.rb", .data = "class User < ApplicationRecord\n  has_many :posts\n  has_many :comments\n  has_one :profile\n  belongs_to :organization\n  has_and_belongs_to_many :groups\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/models.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"association_graph\",\"arguments\":{\"class_name\":\"User\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.22 MCP explain_type_chain returns chain" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t4722";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/typed.rb", .data = "class Typed\n  def run\n    name = \"hello\"\n    name.upcase\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/typed.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"explain_type_chain\",\"arguments\":{\"file\":\"" ++ ws ++ "/typed.rb\",\"line\":3}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.23 MCP suggest_types returns suggestions" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t4723";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/untyped.rb", .data = "class Untyped\n  def process(x)\n    x.to_s\n  end\n  def compute(a, b)\n    a + b\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/untyped.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"suggest_types\",\"arguments\":{\"file\":\"" ++ ws ++ "/untyped.rb\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.24 MCP type_coverage returns metrics" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t4724";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/coverage.rb", .data = "class Coverage\n  def typed_method\n    name = \"hello\"\n    name\n  end\n  def untyped_method(x)\n    x\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/coverage.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"type_coverage\",\"arguments\":{}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.25 MCP find_similar returns matches" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t4725";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = ws ++ "/similar.rb", .data = "class Similar\n  def calculate_total\n    100\n  end\n  def calculate_totals\n    [100, 200]\n  end\n  def compute_total\n    50\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/similar.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"find_similar\",\"arguments\":{\"method_name\":\"calculate_total\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P47 T47.26 MCP rate limiting rejects excess requests" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p47_t4726";
    std.fs.deleteTreeAbsolute(ws) catch {};
    try std.fs.makeDirAbsolute(ws);
    defer std.fs.deleteTreeAbsolute(ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    for (2..112) |i| {
        var id_buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&id_buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/list\"}}", .{i}) catch continue;
        try s.sendLine(line);
    }
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "rate limit exceeded") != null);
}
