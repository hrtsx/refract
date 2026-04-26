const std = @import("std");
const llm_adapter = @import("../lsp/llm_adapter.zig");

test "disabled by default: without llm_config, resolveApiKey returns empty" {
    const alloc = std.testing.allocator;
    var cfg = llm_adapter.Config{
        .enabled = false,
        .provider = .none,
        .model = try alloc.dupe(u8, ""),
        .endpoint = try alloc.dupe(u8, ""),
        .auth_env_var = try alloc.dupe(u8, ""),
    };
    defer cfg.deinit(alloc);

    const key = llm_adapter.resolveApiKey(cfg);
    try std.testing.expect(key.len == 0);
}

test "provider=none: enabled config with provider .none returns empty key" {
    const alloc = std.testing.allocator;
    var cfg = llm_adapter.Config{
        .enabled = true,
        .provider = .none,
        .model = try alloc.dupe(u8, "gpt-4"),
        .endpoint = try alloc.dupe(u8, "https://api.openai.com"),
        .auth_env_var = try alloc.dupe(u8, "OPENAI_API_KEY"),
    };
    defer cfg.deinit(alloc);

    const key = llm_adapter.resolveApiKey(cfg);
    try std.testing.expect(key.len == 0);
}

test "missing api key: anthropic enabled but env var unset returns empty" {
    const alloc = std.testing.allocator;
    var cfg = llm_adapter.Config{
        .enabled = true,
        .provider = .anthropic,
        .model = try alloc.dupe(u8, "claude-3-haiku"),
        .endpoint = try alloc.dupe(u8, "https://api.anthropic.com"),
        .auth_env_var = try alloc.dupe(u8, "NONEXISTENT_KEY_VAR_12345"),
    };
    defer cfg.deinit(alloc);

    const key = llm_adapter.resolveApiKey(cfg);
    try std.testing.expect(key.len == 0);
}

test "parse: timeout_ms override is honored" {
    const alloc = std.testing.allocator;
    const toml =
        \\enabled = true
        \\provider = "anthropic"
        \\model = "claude-3-haiku"
        \\endpoint = "https://api.anthropic.com"
        \\auth_env_var = "X"
        \\timeout_ms = 75
    ;
    var cfg = try llm_adapter.parse(alloc, toml);
    defer cfg.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 75), cfg.timeout_ms);
    try std.testing.expectEqual(true, cfg.enabled);
}

test "fetchCompletion returns null on disabled config" {
    const alloc = std.testing.allocator;
    var cfg = llm_adapter.Config{
        .enabled = false,
        .provider = .none,
        .model = try alloc.dupe(u8, ""),
        .endpoint = try alloc.dupe(u8, ""),
        .auth_env_var = try alloc.dupe(u8, ""),
    };
    defer cfg.deinit(alloc);
    const r = try llm_adapter.fetchCompletion(alloc, cfg, "", "x");
    try std.testing.expect(r == null);
}
