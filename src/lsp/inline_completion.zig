const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const types = @import("types.zig");
const llm_adapter = @import("llm_adapter.zig");

const extractTextDocumentUri = S.extractTextDocumentUri;
const extractPosition = S.extractPosition;
const uriToPath = S.uriToPath;
const writeEscapedJson = S.writeEscapedJson;

/// LSP 3.18 textDocument/inlineCompletion handler.
///
/// Returns ghost text for the cursor position. Default off — only fires when
/// `${workspace}/.refract/llm.toml` has `enabled = true` and a provider with
/// auth_env_var resolving to a non-empty key. Latency budget: timeout_ms (200
/// ms by default) per Lane A reliability gate.
///
/// HTTP wiring is intentionally minimal — provider-agnostic adapter design
/// is in `lsp/llm_adapter.zig`. The actual completion fetch calls
/// `llm_adapter.fetchCompletion` for real HTTP (gated by config, timeout-bounded,
/// fire-and-forget on timeout). Returns empty list on network failure or disabled state.
pub fn handleInlineCompletion(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    if (self.isCancelled(msg.id)) return self.cancelledResponse(msg.id);

    const cfg_ptr = if (self.llm_config) |*c| c else return emptyInlineList(self, msg);
    if (!cfg_ptr.enabled or cfg_ptr.provider == .none) return emptyInlineList(self, msg);

    const api_key = llm_adapter.resolveApiKey(cfg_ptr.*);
    if (api_key.len == 0) return emptyInlineList(self, msg);

    const uri = extractTextDocumentUri(msg.params) orelse return emptyInlineList(self, msg);
    const pos = extractPosition(msg.params) orelse return emptyInlineList(self, msg);

    const path = uriToPath(self.alloc, uri) catch return emptyInlineList(self, msg);
    defer self.alloc.free(path);
    if (!self.pathInBounds(path)) return emptyInlineList(self, msg);
    const source = self.readSourceForUri(uri, path) catch return emptyInlineList(self, msg);
    defer self.alloc.free(source);

    const ctx = buildInlineContext(self.alloc, source, pos.line, pos.character) catch return emptyInlineList(self, msg);
    defer self.alloc.free(ctx);

    const completion_text = requestCompletion(self.alloc, cfg_ptr.*, api_key, ctx) catch null;
    defer if (completion_text) |t| self.alloc.free(t);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"items\":[");
    if (completion_text) |t| if (t.len > 0) {
        try w.writeAll("{\"insertText\":");
        try writeEscapedJson(w, t);
        try w.writeAll("}");
    };
    try w.writeAll("]}");
    const raw = try aw.toOwnedSlice();
    return types.ResponseMessage{ .id = msg.id, .raw_result = raw, .result = null, .@"error" = null };
}

fn emptyInlineList(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    const raw = try self.alloc.dupe(u8, "{\"items\":[]}");
    return types.ResponseMessage{ .id = msg.id, .raw_result = raw, .result = null, .@"error" = null };
}

/// Slice a 200-line window around `cursor_line` and append a position marker.
/// Caller frees.
fn buildInlineContext(alloc: std.mem.Allocator, source: []const u8, cursor_line: u32, cursor_col: u32) ![]u8 {
    const window: u32 = 100;
    const start_line: u32 = if (cursor_line > window) cursor_line - window else 0;
    const end_line: u32 = cursor_line + window;
    var current_line: u32 = 0;
    var slice_start: usize = 0;
    var slice_end: usize = source.len;
    for (source, 0..) |ch, i| {
        if (current_line == start_line and slice_start == 0) slice_start = i;
        if (ch == '\n') {
            current_line += 1;
            if (current_line > end_line) {
                slice_end = i;
                break;
            }
        }
    }
    const window_src = source[slice_start..slice_end];
    return std.fmt.allocPrint(alloc, "<<<refract-cursor line={d} col={d}>>>\n{s}\n<<<refract-cursor-end>>>\n", .{ cursor_line, cursor_col, window_src });
}

/// Provider-agnostic completion request. Delegates to `llm_adapter.fetchCompletion`
/// which dispatches to Anthropic / OpenAI / Ollama based on `cfg.provider`.
/// Network failures and disabled state both surface as `null` (handler emits
/// an empty list either way — safe default).
fn requestCompletion(
    alloc: std.mem.Allocator,
    cfg: llm_adapter.Config,
    api_key: []const u8,
    context: []const u8,
) !?[]u8 {
    return llm_adapter.fetchCompletion(alloc, cfg, api_key, context);
}

test "buildInlineContext slices around cursor and embeds marker" {
    const alloc = std.testing.allocator;
    const src = "line0\nline1\nline2\nline3\nline4\n";
    const ctx = try buildInlineContext(alloc, src, 2, 3);
    defer alloc.free(ctx);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "line=2 col=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "line2") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "<<<refract-cursor-end>>>") != null);
}

test "buildInlineContext clamps to file bounds for out-of-range cursor" {
    const alloc = std.testing.allocator;
    const src = "line0\nline1\nline2\n";
    const ctx = try buildInlineContext(alloc, src, 100, 500);
    defer alloc.free(ctx);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "line=100 col=500") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "<<<refract-cursor-end>>>") != null);
}
