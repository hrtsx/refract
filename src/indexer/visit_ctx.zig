const std = @import("std");
const db_mod = @import("../db.zig");
const prism = @import("../prism.zig");

/// One semantic-highlighting token, delta-encoded at store time.
pub const SemToken = struct {
    line: u32,
    col: u32,
    len: u32,
    token_type: u32,
    mods: u32,
};

/// Mutable state threaded through the prism AST walk while indexing one file:
/// the open DB + file id, the parser/source, the current lexical scope, the
/// namespace stack, and migration-schema context. Owned by `indexSource`.
pub const VisitCtx = struct {
    db: db_mod.Db,
    file_id: i64,
    parser: *prism.Parser,
    alloc: std.mem.Allocator,
    sem_tokens: std.ArrayList(SemToken),
    source: []const u8,
    scope_id: ?i64 = null,
    current_class_id: ?i64 = null,
    in_singleton: bool = false,
    current_visibility: []const u8 = "public",
    namespace_stack: [64][]const u8 = undefined,
    namespace_stack_len: u8 = 0,
    module_function_mode: bool = false,
    error_count: u32 = 0,
    /// Non-null while visiting inside a `create_table`/`change_table` block.
    /// Holds the camelized model name (e.g. "User" for table "users").
    schema_table: ?[]const u8 = null,
    schema_table_buf: [256]u8 = undefined,
};

/// Record a semantic token (1-based line). OOM drops the token — highlighting
/// only, never index correctness.
pub fn addSemToken(ctx: *VisitCtx, line: i32, col: u32, len: u32, token_type: u32) void {
    if (line < 1) return;
    ctx.sem_tokens.append(ctx.alloc, .{
        .line = @intCast(line),
        .col = col,
        .len = len,
        .token_type = token_type,
        .mods = 0,
    }) catch {}; // OOM — token omitted; affects syntax highlighting only, not index correctness
}
