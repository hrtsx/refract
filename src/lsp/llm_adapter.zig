const std = @import("std");

pub const Provider = enum {
    none,
    anthropic,
    openai,
    ollama,

    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .none => "none",
            .anthropic => "anthropic",
            .openai => "openai",
            .ollama => "ollama",
        };
    }

    pub fn fromString(s: []const u8) Provider {
        if (std.ascii.eqlIgnoreCase(s, "anthropic")) return .anthropic;
        if (std.ascii.eqlIgnoreCase(s, "openai")) return .openai;
        if (std.ascii.eqlIgnoreCase(s, "ollama")) return .ollama;
        return .none;
    }
};

pub const Config = struct {
    enabled: bool = false,
    provider: Provider = .none,
    model: []u8,
    endpoint: []u8,
    auth_env_var: []u8, // env var name holding the API key (BYOK strictly)
    max_tokens: u32 = 256,
    timeout_ms: u32 = 200, // ghost-text budget per plan A4

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        alloc.free(self.model);
        alloc.free(self.endpoint);
        alloc.free(self.auth_env_var);
    }
};

/// Parse `${workspace}/.refract/llm.toml` (minimal subset: top-level `key = "value"`,
/// `key = true|false`, `key = <int>`). Lines starting with `#` ignored.
/// Defaults: provider=none, enabled=false, max_tokens=256, timeout_ms=200.
pub fn parse(alloc: std.mem.Allocator, toml_bytes: []const u8) !Config {
    var cfg = Config{
        .enabled = false,
        .provider = .none,
        .model = try alloc.dupe(u8, ""),
        .endpoint = try alloc.dupe(u8, ""),
        .auth_env_var = try alloc.dupe(u8, ""),
    };
    errdefer cfg.deinit(alloc);

    var it = std.mem.splitScalar(u8, toml_bytes, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        const raw = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        const val = std.mem.trim(u8, raw, "\"'");

        if (std.mem.eql(u8, key, "enabled")) {
            cfg.enabled = std.ascii.eqlIgnoreCase(val, "true");
        } else if (std.mem.eql(u8, key, "provider")) {
            cfg.provider = Provider.fromString(val);
        } else if (std.mem.eql(u8, key, "model")) {
            alloc.free(cfg.model);
            cfg.model = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "endpoint")) {
            alloc.free(cfg.endpoint);
            cfg.endpoint = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "auth_env_var")) {
            alloc.free(cfg.auth_env_var);
            cfg.auth_env_var = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "max_tokens")) {
            cfg.max_tokens = std.fmt.parseInt(u32, val, 10) catch cfg.max_tokens;
        } else if (std.mem.eql(u8, key, "timeout_ms")) {
            cfg.timeout_ms = std.fmt.parseInt(u32, val, 10) catch cfg.timeout_ms;
        }
    }
    return cfg;
}

/// Read llm.toml from `${workspace}/.refract/llm.toml`. Returns default config
/// (disabled, provider=none) when file absent or unreadable.
pub fn loadFromWorkspace(alloc: std.mem.Allocator, workspace_root: []const u8) !Config {
    const path = try std.fs.path.join(alloc, &.{ workspace_root, ".refract", "llm.toml" });
    defer alloc.free(path);
    var f = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch {
        return Config{
            .enabled = false,
            .provider = .none,
            .model = try alloc.dupe(u8, ""),
            .endpoint = try alloc.dupe(u8, ""),
            .auth_env_var = try alloc.dupe(u8, ""),
        };
    };
    defer f.close(std.Options.debug_io);
    var buf: [4096]u8 = undefined;
    var fr = f.readerStreaming(std.Options.debug_io, &buf);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = fr.interface.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        try bytes.appendSlice(alloc, chunk[0..n]);
        if (bytes.items.len > 64 * 1024) break;
    }
    return try parse(alloc, bytes.items);
}

/// Resolve API key from the configured env var. Empty string when unset/disabled.
/// Caller must NOT log this value.
pub fn resolveApiKey(cfg: Config) []const u8 {
    if (!cfg.enabled or cfg.provider == .none) return "";
    if (cfg.auth_env_var.len == 0) return "";
    var name_buf: [128]u8 = undefined;
    if (cfg.auth_env_var.len + 1 > name_buf.len) return "";
    @memcpy(name_buf[0..cfg.auth_env_var.len], cfg.auth_env_var);
    name_buf[cfg.auth_env_var.len] = 0;
    const ptr = std.c.getenv(@as([*:0]const u8, @ptrCast(&name_buf))) orelse return "";
    return std.mem.span(ptr);
}

/// One-shot HTTP completion request with a hard wall-clock deadline of
/// `cfg.timeout_ms` (200 ms default per Lane A4). Spawns the actual fetch
/// on a worker thread and returns null if it doesn't complete in time —
/// the worker is detached and tears itself down independently. Returned
/// bytes are caller-owned.
///
/// Reliability gates: null on disabled / `.none` provider / missing key /
/// missing endpoint / missing model / HTTP ≥ 300 / parse failure /
/// timeout. The handler emits an empty inline-completion list on null,
/// so timeouts never block typing.
pub fn fetchCompletion(
    alloc: std.mem.Allocator,
    cfg: Config,
    api_key: []const u8,
    prompt: []const u8,
) !?[]u8 {
    if (!cfg.enabled or cfg.provider == .none) return null;
    if (cfg.provider != .ollama and api_key.len == 0) return null;
    if (cfg.endpoint.len == 0) return null;
    if (cfg.model.len == 0) return null;

    // Build context that outlives both caller and worker. Refcount = 2
    // (caller + worker); whoever decrements last frees the box.
    const ctx = try alloc.create(FetchCtx);
    ctx.* = .{
        .alloc = alloc,
        .cfg = cfg,
        .api_key = try alloc.dupe(u8, api_key),
        .prompt = try alloc.dupe(u8, prompt),
        .ref_count = std.atomic.Value(u8).init(2),
        .result = null,
        .done = .unset,
    };
    errdefer {
        // alloc.create succeeded but spawn failed below — manually undo the dupes.
        alloc.free(ctx.api_key);
        alloc.free(ctx.prompt);
        alloc.destroy(ctx);
    }

    const t = std.Thread.spawn(.{}, fetchWorker, .{ctx}) catch return null;

    const io = std.Options.debug_io;
    const dur_ms: i64 = @intCast(cfg.timeout_ms);
    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(dur_ms),
        .clock = .awake,
    } };

    if (ctx.done.waitTimeout(io, timeout)) |_| {
        // Worker finished within budget: take the result, then release.
        t.join();
        const r = ctx.result;
        ctx.result = null; // transfer ownership to caller
        releaseFetch(ctx);
        return r;
    } else |err| switch (err) {
        error.Timeout => {
            t.detach();
            releaseFetch(ctx); // worker holds the second ref; will free on its own.
            return null;
        },
        else => {
            t.join();
            releaseFetch(ctx);
            return null;
        },
    }
}

const FetchCtx = struct {
    alloc: std.mem.Allocator,
    cfg: Config,
    api_key: []u8,
    prompt: []u8,
    ref_count: std.atomic.Value(u8),
    result: ?[]u8,
    done: std.Io.Event,
};

fn fetchWorker(ctx: *FetchCtx) void {
    ctx.result = doHttpFetch(ctx.alloc, ctx.cfg, ctx.api_key, ctx.prompt) catch null;
    ctx.done.set(std.Options.debug_io);
    releaseFetch(ctx);
}

/// Decrement the FetchCtx ref. Last to release frees both the box and
/// any pending result + duped api_key/prompt.
fn releaseFetch(ctx: *FetchCtx) void {
    if (ctx.ref_count.fetchSub(1, .acq_rel) == 1) {
        if (ctx.result) |r| ctx.alloc.free(r);
        ctx.alloc.free(ctx.api_key);
        ctx.alloc.free(ctx.prompt);
        ctx.alloc.destroy(ctx);
    }
}

/// Pure HTTP path — blocking. Caller controls timeout via `fetchCompletion`.
fn doHttpFetch(
    alloc: std.mem.Allocator,
    cfg: Config,
    api_key: []const u8,
    prompt: []const u8,
) !?[]u8 {
    if (!cfg.enabled or cfg.provider == .none) return null;
    if (cfg.provider != .ollama and api_key.len == 0) return null;
    if (cfg.endpoint.len == 0) return null;
    if (cfg.model.len == 0) return null;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const url = try providerUrl(aalloc, cfg);
    const body = try providerBody(aalloc, cfg, prompt);

    var extra = std.ArrayList(std.http.Header).empty;
    var req_headers: std.http.Client.Request.Headers = .{
        .content_type = .{ .override = "application/json" },
    };
    switch (cfg.provider) {
        .anthropic => {
            try extra.append(aalloc, .{ .name = "x-api-key", .value = api_key });
            try extra.append(aalloc, .{ .name = "anthropic-version", .value = "2023-06-01" });
        },
        .openai => {
            const bearer = try std.fmt.allocPrint(aalloc, "Bearer {s}", .{api_key});
            req_headers.authorization = .{ .override = bearer };
        },
        .ollama => {},
        .none => unreachable,
    }

    const io = std.Options.debug_io;
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    // Load system CA roots so HTTPS handshakes succeed against real providers
    // (Anthropic / OpenAI). Skipped for plaintext endpoints (Ollama at
    // http://localhost:11434).
    if (std.mem.startsWith(u8, cfg.endpoint, "https://")) {
        const now_ts = std.Io.Timestamp.now(io, .real);
        client.ca_bundle.rescan(alloc, io, now_ts) catch return null;
    }

    var resp = std.Io.Writer.Allocating.init(alloc);
    defer resp.deinit();

    const fr = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &resp.writer,
        .headers = req_headers,
        .extra_headers = extra.items,
    }) catch return null;

    if (@intFromEnum(fr.status) >= 300) return null;
    return try extractCompletion(alloc, cfg.provider, resp.written());
}

fn providerUrl(alloc: std.mem.Allocator, cfg: Config) ![]u8 {
    const base = std.mem.trimEnd(u8, cfg.endpoint, "/");
    const path = switch (cfg.provider) {
        .anthropic => "/v1/messages",
        .openai => "/v1/chat/completions",
        .ollama => "/api/generate",
        .none => unreachable,
    };
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ base, path });
}

fn providerBody(alloc: std.mem.Allocator, cfg: Config, prompt: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    switch (cfg.provider) {
        .anthropic, .openai => {
            try out.appendSlice(alloc, "{\"model\":");
            try appendJsonString(alloc, &out, cfg.model);
            try out.appendSlice(alloc, ",\"max_tokens\":");
            const tokstr = try std.fmt.allocPrint(alloc, "{d}", .{cfg.max_tokens});
            defer alloc.free(tokstr);
            try out.appendSlice(alloc, tokstr);
            try out.appendSlice(alloc, ",\"messages\":[{\"role\":\"user\",\"content\":");
            try appendJsonString(alloc, &out, prompt);
            try out.appendSlice(alloc, "}]}");
        },
        .ollama => {
            try out.appendSlice(alloc, "{\"model\":");
            try appendJsonString(alloc, &out, cfg.model);
            try out.appendSlice(alloc, ",\"prompt\":");
            try appendJsonString(alloc, &out, prompt);
            try out.appendSlice(alloc, ",\"stream\":false,\"options\":{\"num_predict\":");
            const tokstr = try std.fmt.allocPrint(alloc, "{d}", .{cfg.max_tokens});
            defer alloc.free(tokstr);
            try out.appendSlice(alloc, tokstr);
            try out.appendSlice(alloc, "}}");
        },
        .none => unreachable,
    }
    return try out.toOwnedSlice(alloc);
}

fn appendJsonString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |b| {
        switch (b) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (b < 0x20) {
                    var hex_buf: [6]u8 = undefined;
                    const esc = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{b}) catch continue;
                    try out.appendSlice(alloc, esc);
                } else {
                    try out.append(alloc, b);
                }
            },
        }
    }
    try out.append(alloc, '"');
}

fn extractCompletion(alloc: std.mem.Allocator, provider: Provider, body: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const text: ?[]const u8 = switch (provider) {
        .anthropic => blk: {
            const arr_v = parsed.value.object.get("content") orelse break :blk null;
            if (arr_v != .array) break :blk null;
            if (arr_v.array.items.len == 0) break :blk null;
            const first = arr_v.array.items[0];
            if (first != .object) break :blk null;
            const t = first.object.get("text") orelse break :blk null;
            if (t != .string) break :blk null;
            break :blk t.string;
        },
        .openai => blk: {
            const choices = parsed.value.object.get("choices") orelse break :blk null;
            if (choices != .array) break :blk null;
            if (choices.array.items.len == 0) break :blk null;
            const first = choices.array.items[0];
            if (first != .object) break :blk null;
            const message = first.object.get("message") orelse break :blk null;
            if (message != .object) break :blk null;
            const content = message.object.get("content") orelse break :blk null;
            if (content != .string) break :blk null;
            break :blk content.string;
        },
        .ollama => blk: {
            const r = parsed.value.object.get("response") orelse break :blk null;
            if (r != .string) break :blk null;
            break :blk r.string;
        },
        .none => null,
    };
    if (text) |t| return try alloc.dupe(u8, t);
    return null;
}

test "extractCompletion parses anthropic content[].text" {
    const alloc = std.testing.allocator;
    const body = "{\"content\":[{\"type\":\"text\",\"text\":\"hello world\"}]}";
    const got = (try extractCompletion(alloc, .anthropic, body)) orelse return error.NoText;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("hello world", got);
}

test "extractCompletion parses openai choices[].message.content" {
    const alloc = std.testing.allocator;
    const body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"def x; end\"}}]}";
    const got = (try extractCompletion(alloc, .openai, body)) orelse return error.NoText;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("def x; end", got);
}

test "extractCompletion parses ollama response" {
    const alloc = std.testing.allocator;
    const body = "{\"response\":\"snippet\",\"done\":true}";
    const got = (try extractCompletion(alloc, .ollama, body)) orelse return error.NoText;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("snippet", got);
}

test "providerBody anthropic round-trips model + prompt" {
    const alloc = std.testing.allocator;
    var cfg = try parse(alloc,
        \\enabled = true
        \\provider = "anthropic"
        \\model = "claude-test"
        \\endpoint = "https://api.anthropic.com"
        \\auth_env_var = "X"
        \\max_tokens = 64
    );
    defer cfg.deinit(alloc);
    const body = try providerBody(alloc, cfg, "ghost\ncompletion");
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "claude-test") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":64") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ghost\\ncompletion") != null);
}

test "providerUrl builds /v1/messages for anthropic with trailing slash trimmed" {
    const alloc = std.testing.allocator;
    var cfg = try parse(alloc,
        \\enabled = true
        \\provider = "anthropic"
        \\endpoint = "https://api.anthropic.com/"
    );
    defer cfg.deinit(alloc);
    const url = try providerUrl(alloc, cfg);
    defer alloc.free(url);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url);
}

test "fetchCompletion early-out when disabled" {
    const alloc = std.testing.allocator;
    var cfg = try parse(alloc, "");
    defer cfg.deinit(alloc);
    const got = try fetchCompletion(alloc, cfg, "key", "prompt");
    try std.testing.expect(got == null);
}

test "parse defaults applied when file empty" {
    const alloc = std.testing.allocator;
    var cfg = try parse(alloc, "");
    defer cfg.deinit(alloc);
    try std.testing.expectEqual(false, cfg.enabled);
    try std.testing.expectEqual(Provider.none, cfg.provider);
    try std.testing.expectEqual(@as(u32, 256), cfg.max_tokens);
    try std.testing.expectEqual(@as(u32, 200), cfg.timeout_ms);
}

test "parse reads provider, model, endpoint, auth_env_var" {
    const alloc = std.testing.allocator;
    const toml =
        \\enabled = true
        \\provider = "anthropic"
        \\model = "claude-opus-4-7"
        \\endpoint = "https://api.anthropic.com"
        \\auth_env_var = "ANTHROPIC_API_KEY"
        \\max_tokens = 512
        \\timeout_ms = 150
    ;
    var cfg = try parse(alloc, toml);
    defer cfg.deinit(alloc);
    try std.testing.expectEqual(true, cfg.enabled);
    try std.testing.expectEqual(Provider.anthropic, cfg.provider);
    try std.testing.expectEqualStrings("claude-opus-4-7", cfg.model);
    try std.testing.expectEqualStrings("https://api.anthropic.com", cfg.endpoint);
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", cfg.auth_env_var);
    try std.testing.expectEqual(@as(u32, 512), cfg.max_tokens);
    try std.testing.expectEqual(@as(u32, 150), cfg.timeout_ms);
}

test "parse ignores comments and section headers" {
    const alloc = std.testing.allocator;
    const toml =
        \\# top comment
        \\[adapter]
        \\enabled = true
        \\provider = "ollama"
    ;
    var cfg = try parse(alloc, toml);
    defer cfg.deinit(alloc);
    try std.testing.expectEqual(Provider.ollama, cfg.provider);
}

test "resolveApiKey returns empty when disabled" {
    const alloc = std.testing.allocator;
    const toml =
        \\enabled = false
        \\provider = "anthropic"
        \\auth_env_var = "PATH"
    ;
    var cfg = try parse(alloc, toml);
    defer cfg.deinit(alloc);
    try std.testing.expectEqualStrings("", resolveApiKey(cfg));
}
