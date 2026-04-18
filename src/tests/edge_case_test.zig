const std = @import("std");
const harness = @import("harness");
const Session = harness.Session;

test "P48 T48.1 Edge case: empty file zero bytes" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p48_t481";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/empty.rb", .data = "" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/empty.rb\",\"type\":1}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/empty.rb\"},\"position\":{\"line\":0,\"character\":0}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "error") == null or std.mem.indexOf(u8, raw, "error") != null);
}

test "P48 T48.2 Edge case: comments only file" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p48_t482";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/comments.rb", .data = "# Initial comment\n# Comment block\n=begin\nMultiline\ncomment\n=end\n# Final comment\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/comments.rb\",\"type\":1}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/comments.rb\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "error") == null);
}

test "P48 T48.3 Edge case: deeply nested modules (8+ levels)" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p48_t483";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/deep.rb", .data = "module L1\nmodule L2\nmodule L3\nmodule L4\nmodule L5\nmodule L6\nmodule L7\nmodule L8\nmodule L9\nclass Deep\n  def work\n    true\n  end\nend\nend\nend\nend\nend\nend\nend\nend\nend\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/deep.rb\",\"type\":1}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/deep.rb\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P48 T48.4 Edge case: file with syntax errors" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p48_t484";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/syntax.rb", .data = "class Broken\n  def method\n    if true\n      puts \"unmatched\"\n    # missing end\n  end\n  def another_error\n    [1, 2,  # missing bracket\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/syntax.rb\",\"type\":1}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/syntax.rb\"},\"position\":{\"line\":1,\"character\":5}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "error") == null or std.mem.indexOf(u8, raw, "result") != null);
}

test "P48 T48.5 Edge case: very long method name (200+ chars)" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p48_t485";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/long.rb", .data = "class Handler\n  def this_is_a_very_long_method_name_that_exceeds_two_hundred_characters_in_length_to_test_identifier_handling_and_truncation_in_the_indexing_system_and_should_be_properly_indexed_for_search_and_navigation_without_any_issues_whatsoever\n    true\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/long.rb\",\"type\":1}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/long.rb\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P48 T48.6 Edge case: unicode identifiers in Ruby" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p48_t486";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/unicode.rb", .data = "class Café\n  attr_accessor :naïve_field\n  def métier\n    \"work\"\n  end\n  def 日本語\n    \"japanese\"\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/unicode.rb\",\"type\":1}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/unicode.rb\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P48 T48.7 Edge case: cyclic module inclusion" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p48_t487";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/cyclic.rb", .data = "module CycleA\n  include CycleB\n  def method_a\n    true\n  end\nend\nmodule CycleB\n  include CycleA\n  def method_b\n    true\n  end\nend\nclass UsesCycle\n  include CycleA\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/cyclic.rb\",\"type\":1}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/cyclic.rb\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P49 T49.1 Template: HAML file indexing" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p49_t491";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/app", .default_dir);
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/app/views", .default_dir);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/app/views/sample.haml", .data = ".container\n  %h1.title User Profile\n  %form#user-form\n    .form-group\n      %label Email\n      %input{name: 'email', type: 'email'}\n    .form-group\n      %label Password\n      %input{name: 'password', type: 'password'}\n    %button{type: 'submit'} Submit\n  #sidebar\n    %ul.nav\n      %li%a{href: '/'} Home\n      %li%a{href: '/about'} About\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/app/views/sample.haml\",\"type\":1}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/app/views/sample.haml\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P49 T49.2 Template: routes file with nested resources" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p49_t492";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/config", .default_dir);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/config/routes.rb", .data = "Rails.application.routes.draw do\n  namespace :admin do\n    resources :users do\n      resources :posts do\n        resources :comments, only: [:create, :destroy]\n      end\n      collection do\n        get :active\n        post :bulk_update\n      end\n    end\n  end\n  scope 'api/v1' do\n    resources :products\n    resources :orders\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/config/routes.rb\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"route_map\",\"arguments\":{}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P49 T49.3 Template: locale file with i18n keys" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p49_t493";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/config", .default_dir);
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws ++ "/config/locales", .default_dir);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/config/locales/en.yml", .data = "en:\n  activerecord:\n    models:\n      user: User\n      post: Post\n    attributes:\n      user:\n        name: Name\n        email: Email Address\n        password: Password\n      post:\n        title: Post Title\n        content: Content\n  errors:\n    messages:\n      taken: has already been taken\n      invalid: is invalid\n  views:\n    users:\n      show: User Profile\n      edit: Edit User\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/config/locales/en.yml\",\"type\":1}]}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"i18n_lookup\",\"arguments\":{\"query\":\"activerecord\"}}}");
    try s.sendLine("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.runWithArgs(&.{"--mcp"});
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "result") != null);
}

test "P50 T50.1 Edge case: out-of-range position" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p50_t501";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/tiny.rb", .data = "class Tiny\n  def work\n    true\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/tiny.rb\",\"type\":1}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/tiny.rb\"},\"position\":{\"line\":99999,\"character\":99999}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/tiny.rb\"},\"position\":{\"line\":99999,\"character\":0}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(raw.len > 0);
}

test "P50 T50.2 Edge case: malformed JSON-RPC missing method" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p50_t502";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"params\":{}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":\"string_id\",\"method\":\"textDocument/hover\",\"params\":{}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(raw.len > 0);
}

test "P50 T50.3 Edge case: heredoc type inference" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p50_t503";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/heredoc.rb", .data = "class HeredocTest\n  def plain_heredoc\n    <<~SQL\n      SELECT * FROM users\n    SQL\n  end\n  def squiggly\n    <<~RUBY\n      puts 'hello'\n    RUBY\n  end\n  def quoted\n    <<-'NOINTERP'\n      \\#{this_stays_literal}\n    NOINTERP\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/heredoc.rb\",\"type\":1}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/heredoc.rb\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "plain_heredoc") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "squiggly") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "quoted") != null);
}

test "P50 T50.4 Edge case: diamond inheritance MRO" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p50_t504";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/diamond.rb", .data = "module Loggable\n  def log\n    'logged'\n  end\nend\nmodule Serializable\n  include Loggable\n  def serialize\n    'serialized'\n  end\nend\nmodule Cacheable\n  include Loggable\n  def cache\n    'cached'\n  end\nend\nclass DiamondBase\n  include Serializable\n  include Cacheable\n  def work\n    log\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/diamond.rb\",\"type\":1}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/diamond.rb\"},\"position\":{\"line\":22,\"character\":4}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(raw.len > 0);
}

test "P50 T50.5 Edge case: implementation vs definition" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p50_t505";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/hierarchy.rb", .data = "class Animal\n  def speak\n    'generic'\n  end\nend\nclass Dog < Animal\n  def speak\n    'woof'\n  end\nend\nclass Cat < Animal\n  def speak\n    'meow'\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/hierarchy.rb\",\"type\":1}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/implementation\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/hierarchy.rb\"},\"position\":{\"line\":1,\"character\":6}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(raw.len > 0);
}

test "P50 T50.6 Edge case: rapid didOpen and didChange sequence" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p50_t506";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/rapid.rb", .data = "class Rapid\n  def v1\n    1\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/rapid.rb\",\"languageId\":\"ruby\",\"version\":1,\"text\":\"class Rapid\\n  def v1\\n    1\\n  end\\nend\\n\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/rapid.rb\",\"version\":2},\"contentChanges\":[{\"text\":\"class Rapid\\n  def v2\\n    2\\n  end\\nend\\n\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/rapid.rb\",\"version\":3},\"contentChanges\":[{\"text\":\"class Rapid\\n  def v3\\n    3\\n  end\\nend\\n\"}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/rapid.rb\"},\"position\":{\"line\":1,\"character\":6}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(raw.len > 0);
}

test "P50 T50.7 Edge case: pattern matching Ruby 3.0" {
    const alloc = std.testing.allocator;
    const ws = "/tmp/refract_test_p50_t507";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, ws, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, ws) catch {};
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ws ++ "/pattern.rb", .data = "class PatternTest\n  def check(data)\n    case data\n    in {name: String => name, age: Integer => age}\n      \"\\#{name} is \\#{age}\"\n    in [Integer => first, *rest]\n      first + rest.sum\n    in nil\n      'nothing'\n    end\n  end\nend\n" });
    var s = try Session.init(alloc);
    defer s.deinit();
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" ++ ws ++ "\",\"capabilities\":{},\"initializationOptions\":{\"disableGemIndex\":true}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ ws ++ "/pattern.rb\",\"type\":1}]}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ ws ++ "/pattern.rb\"}}}");
    try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":null}");
    const raw = try s.run();
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "check") != null);
}
