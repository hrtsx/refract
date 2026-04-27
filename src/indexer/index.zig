const std = @import("std");
const db_mod = @import("../db.zig");
const prism = @import("../prism.zig");
const i18n_mod = @import("i18n.zig");
const routes_mod = @import("routes.zig");
const erb_mapping = @import("../lsp/erb_mapping.zig");

pub const LogSink = *const fn (ctx: ?*anyopaque, level: u8, msg: []const u8) void;
pub var log_sink: ?LogSink = null;
pub var log_sink_ctx: ?*anyopaque = null;

fn emitLog(level: u8, msg: []const u8) void {
    if (log_sink) |sink| {
        sink(log_sink_ctx, level, msg);
    } else {
        std.debug.print("{s}", .{msg});
        std.debug.print("{s}", .{"\n"});
    }
}

const SemToken = struct {
    line: u32,
    col: u32,
    len: u32,
    token_type: u32,
    mods: u32,
};

const VisitCtx = struct {
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

threadlocal var hash_type_buf: [128]u8 = undefined;
threadlocal var generic_return_buf: [256]u8 = undefined;
threadlocal var ar_plural_buf: [128]u8 = undefined;

fn resolveConstant(parser: *prism.Parser, id: prism.ConstantId) []const u8 {
    const ct = prism.constantPoolIdToConstant(&parser.constant_pool, id);
    return ct[0].start[0..ct[0].length];
}

fn buildQualifiedName(parser: *prism.Parser, node: *const prism.Node, alloc: std.mem.Allocator) ![]u8 {
    switch (node.*.type) {
        prism.NODE_CONSTANT => {
            const cn: *const prism.ConstReadNode = @ptrCast(@alignCast(node));
            return alloc.dupe(u8, resolveConstant(parser, cn.name));
        },
        prism.NODE_CONSTANT_PATH => {
            const cp: *const prism.ConstantPathNode = @ptrCast(@alignCast(node));
            if (cp.name == 0) return alloc.dupe(u8, "");
            const tail = resolveConstant(parser, cp.name);
            if (cp.parent) |parent| {
                const prefix = try buildQualifiedName(parser, parent, alloc);
                defer alloc.free(prefix);
                if (prefix.len == 0) return alloc.dupe(u8, tail);
                return std.fmt.allocPrint(alloc, "{s}::{s}", .{ prefix, tail });
            }
            return alloc.dupe(u8, tail);
        },
        else => return alloc.dupe(u8, ""),
    }
}

fn locationLineCol(parser: *prism.Parser, offset: u32) struct { line: i32, col: u32 } {
    const lc = prism.lineOffsetListLineColumn(&parser.line_offsets, offset, parser.start_line);
    return .{ .line = lc.line, .col = lc.column };
}

fn addSemToken(ctx: *VisitCtx, line: i32, col: u32, len: u32, token_type: u32) void {
    if (line < 1) return;
    ctx.sem_tokens.append(ctx.alloc, .{
        .line = @intCast(line),
        .col = col,
        .len = len,
        .token_type = token_type,
        .mods = 0,
    }) catch {}; // OOM — token omitted; affects syntax highlighting only, not index correctness
}

fn inferLiteralType(node: *const prism.Node) ?[]const u8 {
    return switch (node.*.type) {
        prism.NODE_INTEGER => "Integer",
        prism.NODE_FLOAT => "Float",
        prism.NODE_STRING, prism.NODE_INTERPOLATED_STR => "String",
        prism.NODE_SYMBOL => "Symbol",
        prism.NODE_TRUE => "TrueClass",
        prism.NODE_FALSE => "FalseClass",
        prism.NODE_NIL => "NilClass",
        prism.NODE_ARRAY => "Array",
        prism.NODE_HASH => blk: {
            const hn: *const prism.HashNode = @ptrCast(@alignCast(node));
            if (hn.elements.size > 0) {
                const first_elem = hn.elements.nodes[0];
                if (first_elem.*.type == prism.NODE_ASSOC) {
                    const assoc: *const prism.AssocNode = @ptrCast(@alignCast(first_elem));
                    if (assoc.key) |key| {
                        if (assoc.value) |value| {
                            if (inferLiteralType(key)) |key_type| {
                                if (inferLiteralType(value)) |val_type| {
                                    // Copy slices to avoid aliasing when key_type/val_type
                                    // point into hash_type_buf from a recursive call.
                                    var kt_buf: [64]u8 = undefined;
                                    var vt_buf: [64]u8 = undefined;
                                    const kt_len = @min(key_type.len, kt_buf.len);
                                    const vt_len = @min(val_type.len, vt_buf.len);
                                    @memcpy(kt_buf[0..kt_len], key_type[0..kt_len]);
                                    @memcpy(vt_buf[0..vt_len], val_type[0..vt_len]);
                                    const len = std.fmt.bufPrint(&hash_type_buf, "Hash[{s}, {s}]", .{ kt_buf[0..kt_len], vt_buf[0..vt_len] }) catch break :blk "Hash";
                                    break :blk len;
                                }
                            }
                        }
                    }
                }
            }
            break :blk "Hash";
        },
        prism.NODE_RANGE => "Range",
        else => null,
    };
}

fn normalizeRbsReturn(rt: []const u8) []const u8 {
    // RBS uses `bool` as a sugar for `TrueClass | FalseClass`. Keep that mapping
    // consistent with parseUnionTypes' handling of `boolean` and with the
    // hardcoded lookupStdlibReturn.
    if (std.mem.eql(u8, rt, "bool")) return "TrueClass | FalseClass";
    if (std.mem.eql(u8, rt, "boolish")) return "TrueClass | FalseClass";
    if (std.mem.eql(u8, rt, "nil")) return "NilClass";
    return rt;
}

fn parseUnionTypes(inner: []const u8, buf: *[512]u8) ?[]const u8 {
    var result_len: usize = 0;
    var it = std.mem.splitSequence(u8, inner, ", ");
    var first = true;
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " ");
        if (t.len == 0) continue;
        const normalized: []const u8 = if (std.mem.eql(u8, t, "nil")) "NilClass" else if (std.mem.eql(u8, t, "boolean")) "TrueClass | FalseClass" else t;
        if (!first) {
            if (result_len + 3 > buf.len) break;
            buf[result_len..][0..3].* = " | ".*;
            result_len += 3;
        }
        if (result_len + normalized.len > buf.len) break;
        @memcpy(buf[result_len..][0..normalized.len], normalized);
        result_len += normalized.len;
        first = false;
    }
    if (result_len == 0) return null;
    return buf[0..result_len];
}

fn parseYardReturn(doc: []const u8, buf: *[512]u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, doc, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        const tag = "@return [";
        const idx = std.mem.indexOf(u8, t, tag) orelse continue;
        const rest = t[idx + tag.len ..];
        const end = std.mem.indexOfScalar(u8, rest, ']') orelse continue;
        const inner = rest[0..end];
        if (std.mem.startsWith(u8, inner, "Array<") and inner[inner.len - 1] == '>') {
            return inner[6 .. inner.len - 1];
        }
        if (std.mem.startsWith(u8, inner, "Hash{") and inner.len > 5 and inner[inner.len - 1] == '}') {
            return inner;
        }
        if (std.mem.startsWith(u8, inner, "Set[") or std.mem.startsWith(u8, inner, "Set<")) {
            return inner;
        }
        if (std.mem.indexOf(u8, inner, ",") != null) {
            return parseUnionTypes(inner, buf);
        }
        return inner;
    }
    return null;
}

fn parseYardParam(doc: []const u8, name: []const u8, buf: *[512]u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, doc, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, t, "@param ")) continue;
        const rest = t[7..];
        if (!std.mem.startsWith(u8, rest, name)) continue;
        const after = rest[name.len..];
        if (after.len == 0 or after[0] != ' ') continue;
        const bracket = std.mem.indexOf(u8, after, "[") orelse continue;
        const inner_start = after[bracket + 1 ..];
        const end = std.mem.indexOfScalar(u8, inner_start, ']') orelse continue;
        const inner = inner_start[0..end];
        if (std.mem.indexOf(u8, inner, ",") != null) {
            return parseUnionTypes(inner, buf);
        }
        return inner;
    }
    return null;
}

/// Returns the description text that follows `[Type]` on a YARD @param line.
/// e.g. `@param name [String] the user's name` → `"the user's name"`
fn parseYardParamDesc(doc: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, doc, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, t, "@param ")) continue;
        const rest = t[7..];
        if (!std.mem.startsWith(u8, rest, name)) continue;
        const after = rest[name.len..];
        if (after.len == 0 or after[0] != ' ') continue;
        const bracket = std.mem.indexOf(u8, after, "[") orelse continue;
        const inner_start = after[bracket + 1 ..];
        const close = std.mem.indexOfScalar(u8, inner_start, ']') orelse continue;
        const desc = std.mem.trim(u8, inner_start[close + 1 ..], " \t");
        if (desc.len == 0) return null;
        return desc;
    }
    return null;
}

fn extractDocComment(source: []const u8, node_start: u32, alloc: std.mem.Allocator) ?[]u8 {
    if (node_start == 0) return null;
    const end: usize = @min(@as(usize, node_start), source.len);

    // Find start of the def/class/module line
    var def_line_start: usize = end;
    while (def_line_start > 0 and source[def_line_start - 1] != '\n') {
        def_line_start -= 1;
    }

    // Collect comment lines going backward (up to 64)
    var lines: [64][]const u8 = undefined;
    var line_count: usize = 0;
    var pos: usize = def_line_start;

    while (pos > 0 and line_count < 64) {
        const prev_line_end = pos - 1; // '\n' at pos-1
        var prev_line_start = prev_line_end;
        while (prev_line_start > 0 and source[prev_line_start - 1] != '\n') {
            prev_line_start -= 1;
        }
        const line_slice = source[prev_line_start..prev_line_end];
        const trimmed = std.mem.trimStart(u8, line_slice, " \t");
        if (!std.mem.startsWith(u8, trimmed, "#")) break;
        const stripped: []const u8 = if (std.mem.startsWith(u8, trimmed, "# ")) trimmed[2..] else trimmed[1..];
        lines[line_count] = stripped;
        line_count += 1;
        pos = prev_line_start;
    }

    if (line_count == 0) return null;

    // Reverse (collected bottom-to-top)
    var i: usize = 0;
    var j: usize = line_count - 1;
    while (i < j) {
        const tmp = lines[i];
        lines[i] = lines[j];
        lines[j] = tmp;
        i += 1;
        j -= 1;
    }

    // Join with '\n'
    var result = std.ArrayList(u8).empty;
    for (lines[0..line_count], 0..) |line, idx| {
        if (idx > 0) result.append(alloc, '\n') catch {
            result.deinit(alloc);
            return null;
        };
        result.appendSlice(alloc, line) catch {
            result.deinit(alloc);
            return null;
        };
    }
    const raw = result.toOwnedSlice(alloc) catch return null;
    return appendYardTags(raw, alloc);
}

fn appendYardTags(raw: []u8, alloc: std.mem.Allocator) ?[]u8 {
    // Collect @deprecated prefix and extra tag sections.
    // Two-pass: first pass handles single-line tags; @example blocks are multi-line.
    var deprecated_msg: ?[]const u8 = null;
    var extras = std.ArrayList(u8).empty;

    // State machine for multi-line @example blocks
    var in_example = false;
    var example_buf = std.ArrayList(u8).empty;

    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");

        // Detect start of a new YARD tag (ends an open @example block)
        const is_yard_tag = t.len > 0 and t[0] == '@';

        if (in_example) {
            if (is_yard_tag) {
                // Close the current @example block before processing the new tag
                in_example = false;
                const ex = example_buf.toOwnedSlice(alloc) catch "";
                defer alloc.free(ex);
                if (ex.len > 0) {
                    extras.appendSlice(alloc, "\n\n**Example:**\n```ruby\n") catch {};
                    extras.appendSlice(alloc, ex) catch {};
                    extras.appendSlice(alloc, "\n```") catch {};
                }
                // Fall through to process the new tag below
            } else {
                // Accumulate example body line
                if (example_buf.items.len > 0) example_buf.append(alloc, '\n') catch {};
                example_buf.appendSlice(alloc, line) catch {};
                continue;
            }
        }

        if (std.mem.startsWith(u8, t, "@deprecated")) {
            deprecated_msg = std.mem.trim(u8, t["@deprecated".len..], " \t");
        } else if (std.mem.startsWith(u8, t, "@raise")) {
            const rest = std.mem.trim(u8, t["@raise".len..], " \t");
            extras.appendSlice(alloc, "\n\n**Raises:** ") catch {}; // OOM: doc formatting
            extras.appendSlice(alloc, rest) catch {}; // OOM: doc formatting
        } else if (std.mem.startsWith(u8, t, "@see")) {
            const rest = std.mem.trim(u8, t["@see".len..], " \t");
            extras.appendSlice(alloc, "\n\n**See also:** ") catch {}; // OOM: doc formatting
            extras.appendSlice(alloc, rest) catch {}; // OOM: doc formatting
        } else if (std.mem.startsWith(u8, t, "@overload")) {
            const rest = std.mem.trim(u8, t["@overload".len..], " \t");
            extras.appendSlice(alloc, "\n\n**Overload:** `") catch {}; // OOM: doc formatting
            extras.appendSlice(alloc, rest) catch {}; // OOM: doc formatting
            extras.appendSlice(alloc, "`") catch {}; // OOM: doc formatting
        } else if (std.mem.startsWith(u8, t, "@yieldparam")) {
            const rest = std.mem.trim(u8, t["@yieldparam".len..], " \t");
            extras.appendSlice(alloc, "\n\n**Yield param:** ") catch {}; // OOM: doc formatting
            extras.appendSlice(alloc, rest) catch {}; // OOM: doc formatting
        } else if (std.mem.startsWith(u8, t, "@yieldreturn")) {
            const rest = std.mem.trim(u8, t["@yieldreturn".len..], " \t");
            extras.appendSlice(alloc, "\n\n**Yield returns:** ") catch {}; // OOM: doc formatting
            extras.appendSlice(alloc, rest) catch {}; // OOM: doc formatting
        } else if (std.mem.startsWith(u8, t, "@note")) {
            const rest = std.mem.trim(u8, t["@note".len..], " \t");
            extras.appendSlice(alloc, "\n\n> ") catch {}; // OOM: doc formatting
            extras.appendSlice(alloc, rest) catch {}; // OOM: doc formatting
        } else if (std.mem.startsWith(u8, t, "@since")) {
            const rest = std.mem.trim(u8, t["@since".len..], " \t");
            extras.appendSlice(alloc, "\n\n_Since: ") catch {}; // OOM: doc formatting
            extras.appendSlice(alloc, rest) catch {}; // OOM: doc formatting
            extras.appendSlice(alloc, "_") catch {}; // OOM: doc formatting
        } else if (std.mem.startsWith(u8, t, "@example")) {
            // Begin accumulating a multi-line example block
            in_example = true;
            example_buf.clearRetainingCapacity();
            // The text after @example on the same line is the optional title (skip it)
        }
    }

    // Close any open @example block at EOF
    if (in_example) {
        const ex = example_buf.toOwnedSlice(alloc) catch "";
        defer alloc.free(ex);
        if (ex.len > 0) {
            extras.appendSlice(alloc, "\n\n**Example:**\n```ruby\n") catch {};
            extras.appendSlice(alloc, ex) catch {};
            extras.appendSlice(alloc, "\n```") catch {};
        }
    } else {
        example_buf.deinit(alloc);
    }

    const extras_slice = extras.toOwnedSlice(alloc) catch "";
    defer if (extras_slice.len > 0) alloc.free(extras_slice);
    if (deprecated_msg == null and extras_slice.len == 0) return raw;
    var out = std.ArrayList(u8).empty;
    if (deprecated_msg) |msg| {
        out.appendSlice(alloc, "**Deprecated:**") catch {
            out.deinit(alloc);
            alloc.free(raw);
            return null;
        };
        if (msg.len > 0) {
            out.append(alloc, ' ') catch {};
            out.appendSlice(alloc, msg) catch {};
        } // OOM: doc formatting
        out.appendSlice(alloc, "\n\n") catch {}; // OOM: doc formatting
    }
    out.appendSlice(alloc, raw) catch {
        out.deinit(alloc);
        alloc.free(raw);
        return null;
    };
    out.appendSlice(alloc, extras_slice) catch {}; // OOM: doc formatting
    alloc.free(raw);
    return out.toOwnedSlice(alloc) catch null;
}

fn insertRescueFromHandler(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
    if (cn.arguments == null) return;
    const args = cn.arguments[0].arguments;
    for (0..args.size) |i| {
        const arg = args.nodes[i];
        if (arg.*.type != prism.NODE_KEYWORD_HASH) continue;
        const kh: *const prism.KeywordHashNode = @ptrCast(@alignCast(arg));
        for (0..kh.elements.size) |j| {
            const elem = kh.elements.nodes[j];
            if (elem.*.type != prism.NODE_ASSOC) continue;
            const assoc: *const prism.AssocNode = @ptrCast(@alignCast(elem));
            if (assoc.key.*.type != prism.NODE_SYMBOL) continue;
            const ksym: *const prism.SymbolNode = @ptrCast(@alignCast(assoc.key));
            if (ksym.unescaped.source == null) continue;
            const kname = ksym.unescaped.source[0..ksym.unescaped.length];
            if (!std.mem.eql(u8, kname, "with")) continue;
            if (assoc.value.*.type != prism.NODE_SYMBOL) continue;
            const vsym: *const prism.SymbolNode = @ptrCast(@alignCast(assoc.value));
            if (vsym.unescaped.source == null) continue;
            const handler = vsym.unescaped.source[0..vsym.unescaped.length];
            const lc = locationLineCol(ctx.parser, assoc.value.*.location.start);
            try insertSymbol(ctx, "def", handler, lc.line, lc.col, null);
        }
    }
}

fn isAttrMethod(name: []const u8) bool {
    return std.mem.eql(u8, name, "attr_reader") or
        std.mem.eql(u8, name, "attr_writer") or
        std.mem.eql(u8, name, "attr_accessor") or
        std.mem.eql(u8, name, "mattr_accessor") or
        std.mem.eql(u8, name, "mattr_reader") or
        std.mem.eql(u8, name, "mattr_writer") or
        std.mem.eql(u8, name, "cattr_accessor") or
        std.mem.eql(u8, name, "cattr_reader") or
        std.mem.eql(u8, name, "cattr_writer");
}

fn insertAttrSymbols(ctx: *VisitCtx, cn: *const prism.CallNode, mname: []const u8) !void {
    if (cn.arguments == null) return;
    const args_list = cn.arguments[0].arguments;
    for (0..args_list.size) |i| {
        const arg = args_list.nodes[i];
        if (arg.*.type != prism.NODE_SYMBOL) continue;
        const sym: *const prism.SymbolNode = @ptrCast(@alignCast(arg));
        const src = sym.unescaped.source;
        if (src == null) continue;
        const attr_name = src[0..sym.unescaped.length];
        const lc = locationLineCol(ctx.parser, sym.base.location.start);
        try insertSymbol(ctx, "def", attr_name, lc.line, lc.col, null);
        if (std.mem.eql(u8, mname, "attr_writer") or std.mem.eql(u8, mname, "attr_accessor") or
            std.mem.eql(u8, mname, "mattr_writer") or std.mem.eql(u8, mname, "mattr_accessor") or
            std.mem.eql(u8, mname, "cattr_writer") or std.mem.eql(u8, mname, "cattr_accessor"))
        {
            const writer_name = try std.fmt.allocPrint(ctx.alloc, "{s}=", .{attr_name});
            defer ctx.alloc.free(writer_name);
            try insertSymbol(ctx, "def", writer_name, lc.line, lc.col, null);
        }
    }
}

fn isRailsDsl(mname: []const u8) bool {
    const dsl = [_][]const u8{
        "scope",                   "belongs_to",                "has_many",               "has_one",
        "has_and_belongs_to_many", "validates",                 "validates_presence_of",  "validates_uniqueness_of",
        "before_action",           "after_action",              "around_action",          "before_create",
        "after_create",            "before_save",               "after_save",             "before_destroy",
        "after_destroy",           "delegate",                  "rescue_from",            "helper_method",
        "around_create",           "around_save",               "around_destroy",         "validates_format_of",
        "validates_length_of",     "validates_numericality_of", "enum",                   "serialize",
        "store",                   "after_initialize",          "before_validation",      "after_commit",
        "prepend_before_action",   "validate",                  "after_update",           "before_update",
        "around_update",           "after_find",                "validates_inclusion_of", "validates_exclusion_of",
        "validates_with",          "before_commit",             "after_rollback",         "after_touch",
        "after_validation",        "default_scope",
        // RSpec
                    "describe",               "context",
        "it",                      "let",                       "let!",                   "subject",
        "before",                  "after",                     "shared_examples_for",    "shared_context",
        "shared_examples",         "around",
        // Sinatra
                           "get",                    "post",
        "put",                     "delete",                    "patch",                  "options",
        "route",
        // Rake
                          "task",                      "namespace",              "file",
        "directory",
        // ActiveSupport class-level accessors
                      "mattr_accessor",            "mattr_reader",           "mattr_writer",
        "cattr_accessor",          "cattr_reader",              "cattr_writer",
        // FactoryBot
                  "factory",
        "trait",                   "sequence",                  "association",
        // ActiveSupport module hooks
                   "included",
        "extended",                "prepended",
        // Hanami
                        "expose",                 "halt",
        "handle_exception",        "formats",                   "accepts",                "mount",
        // Grape
        "desc",                    "params",                    "requires",               "optional",
        "group",                   "resource",                  "resources",              "route_param",
        "helpers",                 "version",                   "default_format",         "default_error_status",
        "content_type",            "formatter",
        // Roda (dropped "plugin" — collides with Puma's plugin loader where it's DSL, not a method def)
                        "freeze",                 "hash_branch",
        "hash_routes",
        // Sequel associations
                    "one_to_many",               "many_to_one",            "many_to_many",
        "one_to_one",              "one_through_one",           "many_through_many",
        // Sequel validations
             "validates_presence",
        "validates_unique",        "validates_format",          "validates_type",
        // Rails 5.2 – 8.0 DSL extensions
                  "has_one_attached",        "has_many_attached",
        "has_rich_text",           "encrypts",                  "normalizes",            "attribute",
        "has_secure_password",     "has_secure_token",          "delegated_type",        "connects_to",
        "composed_of",             "store_accessor",            "accepts_nested_attributes_for",
        // ActiveJob / ActionMailer class-level DSLs
                                                                                          "queue_as",
        "retry_on",                "discard_on",                "default",
    };
    for (dsl) |d| if (std.mem.eql(u8, mname, d)) return true;
    return false;
}

fn isBuiltinMethod(name: []const u8) bool {
    const builtins = [_][]const u8{
        // Module DSL — always available in class/module body
        "include",                      "extend",                     "prepend",               "using",
        "private",                      "public",                     "protected",             "module_function",
        "attr_reader",                  "attr_writer",                "attr_accessor",         "define_method",
        "define_singleton_method",      "alias_method",               "remove_method",         "undef_method",
        "private_constant",             "public_constant",            "autoload",              "const_set",
        "const_get",                    "const_defined?",             "method_defined?",       "instance_method",
        "instance_methods",             "class_variable_get",         "class_variable_set",    "class_eval",
        "module_eval",                  "class_exec",                 "module_exec",           "refine",
        "ruby2_keywords",
        // Kernel — available everywhere
                      "puts",                       "print",                 "p",
        "pp",                           "raise",                      "fail",                  "require",
        "require_relative",             "load",                       "autoload?",             "lambda",
        "proc",                         "loop",                       "catch",                 "throw",
        "sleep",                        "exit",                       "exit!",                 "abort",
        "at_exit",                      "format",                     "sprintf",               "printf",
        "gets",                         "readline",                   "readlines",             "open",
        "binding",                      "block_given?",               "caller",                "caller_locations",
        "rand",                         "srand",                      "system",                "spawn",
        "exec",                         "fork",                       "trap",                  "warn",
        "Array",                        "String",                     "Integer",               "Float",
        "Hash",                         "Complex",                    "Rational",              "URI",
        // BasicObject / Object — universally present
        "send",                         "__send__",                   "public_send",           "tap",
        "then",                         "yield_self",                 "itself",                "object_id",
        "equal?",                       "eql?",                       "==",                    "!=",
        "hash",                         "inspect",                    "to_s",                  "to_str",
        "class",                        "nil?",                       "is_a?",                 "kind_of?",
        "instance_of?",                 "respond_to?",                "respond_to_missing?",   "method",
        "methods",                      "public_methods",             "private_methods",       "protected_methods",
        "singleton_methods",            "singleton_class",            "instance_variable_get", "instance_variable_set",
        "instance_variables",           "instance_variable_defined?", "freeze",                "frozen?",
        "dup",                          "clone",                      "display",
        // Common Rails controller/view helpers not in isRailsDsl
                      "params",
        "session",                      "cookies",                    "request",               "response",
        "flash",                        "render",                     "redirect_to",           "head",
        "url_for",                      "polymorphic_url",            "polymorphic_path",      "respond_to",
        "respond_with",                 "send_data",                  "send_file",             "current_user",
        "logger",                       "cache",                      "fresh_when",            "stale?",
        "expires_in",                   "expires_now",                "reset_session",         "authenticate_or_request_with_http_basic",
        "authenticate_with_http_basic", "skip_before_action",         "skip_after_action",     "skip_around_action",
        "skip_callback",                "set_callback",               "run_callbacks",
        // ActionView helpers (Rails 6+)
                                       "link_to",                    "link_to_if",            "link_to_unless",
        "button_to",                    "form_with",                  "form_for",              "form_tag",
        "fields_for",                   "fields",                     "label",                 "text_field",
        "text_area",                    "select",                     "select_tag",            "check_box",
        "radio_button",                 "hidden_field",               "submit_tag",            "image_tag",
        "image_url",                    "asset_path",                 "asset_url",             "video_tag",
        "audio_tag",                    "favicon_link_tag",           "javascript_tag",        "javascript_include_tag",
        "stylesheet_link_tag",          "csrf_meta_tags",             "csp_meta_tag",          "auto_discovery_link_tag",
        "content_tag",                  "tag",                        "concat",                "safe_join",
        "raw",                          "html_safe",                  "j",                     "sanitize",
        "strip_tags",                   "simple_format",              "truncate",              "highlight",
        "excerpt",                      "word_wrap",                  "pluralize",             "cycle",
        "number_to_currency",           "number_to_human",            "number_to_human_size",  "number_to_percentage",
        "number_to_phone",              "number_with_delimiter",      "number_with_precision", "time_ago_in_words",
        "distance_of_time_in_words",    "time_tag",                   "datetime_select",       "date_select",
        "select_date",                  "select_time",                "select_datetime",       "current_page?",
        "controller_name",              "action_name",                "view_context",          "yield",
        "content_for",                  "content_for?",               "provide",               "capture",
        "render_partial",
        // Hotwire / Turbo (Rails 7+)
                            "turbo_frame_tag",             "turbo_stream_from",     "turbo_stream",
        "turbo_refreshes_with",         "turbo_method_tag",           "turbo_confirm_tag",     "morph",
        // ActionMailer / ActionMailbox / ActiveJob (call sites; class-level DSLs in isRailsDsl)
                              "mail",                       "deliver_later",         "deliver_now",
        "deliver_later!",               "deliver_now!",               "perform_later",         "perform_now",
        "set",                          "wait",                       "wait_until",            "queue",
        "headers",                      "attachments",                "default_url_options",
        // RSpec matchers/helpers
                "expect",
        "expect_any_instance_of",       "allow",                      "allow_any_instance_of", "double",
        "instance_double",              "class_double",               "object_double",         "spy",
        "eq",                           "eql",                        "be",                    "be_a",
        "be_an",                        "be_kind_of",                 "be_instance_of",        "be_within",
        "match",                        "match_array",                "contain_exactly",       "start_with",
        "end_with",                     "raise_error",                "change",                "have_attributes",
        "satisfy",                      "receive",                    "receive_messages",      "have_received",
        "pending",                      "skip",                       "fixture_file_upload",   "raise_exception",
    };
    for (builtins) |b| if (std.mem.eql(u8, name, b)) return true;
    return false;
}

fn isIterationMethod(name: []const u8) bool {
    const methods = [_][]const u8{
        "each",             "map",             "flat_map",   "select",       "reject",      "find",
        "each_with_object", "each_with_index", "collect",    "detect",       "filter",      "filter_map",
        "inject",           "reduce",          "times",      "upto",         "downto",      "step",
        "each_slice",       "each_cons",       "min_by",     "max_by",       "sort_by",     "group_by",
        "tally",            "then",            "yield_self", "zip",          "take_while",  "drop_while",
        "partition",        "count",           "sum",        "find_all",     "lazy",        "cycle",
        "each_entry",       "chunk_while",     "slice_when", "slice_before", "slice_after", "tap",
        "chunk",
    };
    for (methods) |m| if (std.mem.eql(u8, name, m)) return true;
    return false;
}

fn stripArrayBrackets(t: ?[]const u8) ?[]const u8 {
    const s = t orelse return null;
    if (s.len >= 3 and s[0] == '[' and s[s.len - 1] == ']') return s[1 .. s.len - 1];
    return t;
}

fn blockElemType(mname: []const u8, receiver_type: ?[]const u8) ?[]const u8 {
    if (std.mem.eql(u8, mname, "times") or
        std.mem.eql(u8, mname, "upto") or
        std.mem.eql(u8, mname, "downto") or
        std.mem.eql(u8, mname, "step")) return "Integer";
    if (std.mem.eql(u8, mname, "then") or
        std.mem.eql(u8, mname, "yield_self") or
        std.mem.eql(u8, mname, "tap")) return receiver_type;
    if (std.mem.eql(u8, mname, "each_slice") or
        std.mem.eql(u8, mname, "each_cons")) return receiver_type;
    const elem_methods = [_][]const u8{
        "each",       "map",        "collect",         "select",
        "reject",     "filter",     "flat_map",        "filter_map",
        "take_while", "drop_while", "sort_by",         "min_by",
        "max_by",     "group_by",   "partition",       "count",
        "sum",        "zip",        "each_with_index", "each_with_object",
        "find",       "detect",     "inject",          "reduce",
        "tally",      "chunk",
    };
    for (elem_methods) |m| {
        if (std.mem.eql(u8, mname, m)) return stripArrayBrackets(receiver_type);
    }
    return stripArrayBrackets(receiver_type);
}

fn inferBlockReturnType(method_name: []const u8, receiver_type: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, method_name, "map") or std.mem.eql(u8, method_name, "collect") or
        std.mem.eql(u8, method_name, "filter_map"))
    {
        return receiver_type;
    }
    if (std.mem.eql(u8, method_name, "select") or std.mem.eql(u8, method_name, "reject") or
        std.mem.eql(u8, method_name, "filter") or std.mem.eql(u8, method_name, "sort_by") or
        std.mem.eql(u8, method_name, "min_by") or std.mem.eql(u8, method_name, "max_by") or
        std.mem.eql(u8, method_name, "take_while") or std.mem.eql(u8, method_name, "drop_while"))
    {
        return receiver_type;
    }
    if (std.mem.eql(u8, method_name, "each") or std.mem.eql(u8, method_name, "each_with_index") or
        std.mem.eql(u8, method_name, "each_with_object") or std.mem.eql(u8, method_name, "each_slice") or
        std.mem.eql(u8, method_name, "each_cons"))
    {
        return receiver_type;
    }
    if (std.mem.eql(u8, method_name, "find") or std.mem.eql(u8, method_name, "detect")) {
        return stripArrayBrackets(receiver_type);
    }
    if (std.mem.eql(u8, method_name, "flat_map") or std.mem.eql(u8, method_name, "partition")) {
        return receiver_type;
    }
    if (std.mem.eql(u8, method_name, "inject") or std.mem.eql(u8, method_name, "reduce")) {
        return stripArrayBrackets(receiver_type);
    }
    if (std.mem.eql(u8, method_name, "group_by") or std.mem.eql(u8, method_name, "tally")) {
        return "Hash";
    }
    if (std.mem.eql(u8, method_name, "count") or std.mem.eql(u8, method_name, "sum") or
        std.mem.eql(u8, method_name, "zip"))
    {
        return receiver_type;
    }
    return null;
}

fn insertBlockParams(ctx: *VisitCtx, block: *const prism.BlockNode, receiver_type: []const u8, method_name: []const u8, accum_type: ?[]const u8) !void {
    if (block.parameters == null) return;
    const param_generic: *const prism.Node = @ptrCast(@alignCast(block.parameters));
    if (param_generic.*.type != prism.NODE_BLOCK_PARAMETERS) return;
    const params_node: *const prism.BlockParametersNode = @ptrCast(@alignCast(block.parameters));
    if (params_node.parameters == null) return;
    const params_list: *const prism.ParametersNode = @ptrCast(@alignCast(params_node.parameters));
    if (params_list.requireds.size > 0) {
        const elem_type = blockElemType(method_name, receiver_type) orelse receiver_type;
        const p: *const prism.RequiredParamNode = @ptrCast(@alignCast(params_list.requireds.nodes[0]));
        const pname = resolveConstant(ctx.parser, p.name);
        const lc = locationLineCol(ctx.parser, p.base.location.start);
        if (std.mem.eql(u8, method_name, "inject") or std.mem.eql(u8, method_name, "reduce")) {
            insertLocalVar(ctx.db, ctx.file_id, pname, lc.line, lc.col, elem_type, 60, ctx.scope_id) catch {
                ctx.error_count += 1;
            };
            if (params_list.requireds.size > 1) {
                const p2: *const prism.RequiredParamNode = @ptrCast(@alignCast(params_list.requireds.nodes[1]));
                const pname2 = resolveConstant(ctx.parser, p2.name);
                const lc2 = locationLineCol(ctx.parser, p2.base.location.start);
                insertLocalVar(ctx.db, ctx.file_id, pname2, lc2.line, lc2.col, elem_type, 60, ctx.scope_id) catch {
                    ctx.error_count += 1;
                };
            }
        } else if (std.mem.eql(u8, method_name, "each_with_object") and params_list.requireds.size > 1) {
            insertLocalVar(ctx.db, ctx.file_id, pname, lc.line, lc.col, elem_type, 60, ctx.scope_id) catch {
                ctx.error_count += 1;
            };
            const p2: *const prism.RequiredParamNode = @ptrCast(@alignCast(params_list.requireds.nodes[1]));
            const pname2 = resolveConstant(ctx.parser, p2.name);
            const lc2 = locationLineCol(ctx.parser, p2.base.location.start);
            insertLocalVar(ctx.db, ctx.file_id, pname2, lc2.line, lc2.col, accum_type orelse "Object", 60, ctx.scope_id) catch {
                ctx.error_count += 1;
            };
        } else {
            insertLocalVar(ctx.db, ctx.file_id, pname, lc.line, lc.col, elem_type, 60, ctx.scope_id) catch {
                ctx.error_count += 1;
            };
            if (std.mem.eql(u8, method_name, "each_with_index") and params_list.requireds.size > 1) {
                const p2: *const prism.RequiredParamNode = @ptrCast(@alignCast(params_list.requireds.nodes[1]));
                const pname2 = resolveConstant(ctx.parser, p2.name);
                const lc2 = locationLineCol(ctx.parser, p2.base.location.start);
                insertLocalVar(ctx.db, ctx.file_id, pname2, lc2.line, lc2.col, "Integer", 60, ctx.scope_id) catch {
                    ctx.error_count += 1;
                };
            }
        }
    }
}

fn inferAssocReturnType(alloc: std.mem.Allocator, mname: []const u8, assoc_name: []const u8, class_name_override: ?[]const u8) ?[]u8 {
    const is_plural = std.mem.eql(u8, mname, "has_many") or
        std.mem.eql(u8, mname, "has_and_belongs_to_many") or
        std.mem.eql(u8, mname, "one_to_many") or
        std.mem.eql(u8, mname, "many_to_many") or
        std.mem.eql(u8, mname, "many_through_many");
    const is_singular = std.mem.eql(u8, mname, "belongs_to") or
        std.mem.eql(u8, mname, "has_one") or
        std.mem.eql(u8, mname, "many_to_one") or
        std.mem.eql(u8, mname, "one_to_one") or
        std.mem.eql(u8, mname, "one_through_one");
    if (!is_plural and !is_singular) return null;
    // class_name: option overrides convention-based inference
    if (class_name_override) |cn_override| {
        if (is_plural) return std.fmt.allocPrint(alloc, "[{s}]", .{cn_override}) catch null;
        return alloc.dupe(u8, cn_override) catch null;
    }
    var singular: []const u8 = assoc_name;
    if (std.mem.endsWith(u8, assoc_name, "ies") and assoc_name.len > 3) {
        const base = assoc_name[0 .. assoc_name.len - 3];
        const class_name = std.fmt.allocPrint(alloc, "{c}{s}y", .{ std.ascii.toUpper(base[0]), base[1..] }) catch return null;
        defer alloc.free(class_name);
        if (is_plural) return std.fmt.allocPrint(alloc, "[{s}]", .{class_name}) catch null;
        return alloc.dupe(u8, class_name) catch null;
    }
    if (std.mem.endsWith(u8, assoc_name, "s") and assoc_name.len > 1) {
        singular = assoc_name[0 .. assoc_name.len - 1];
    }
    var class_name_buf: [256]u8 = undefined;
    if (singular.len > 256) return null;
    @memcpy(class_name_buf[0..singular.len], singular);
    class_name_buf[0] = std.ascii.toUpper(class_name_buf[0]);
    const class_name = class_name_buf[0..singular.len];
    if (is_plural) return std.fmt.allocPrint(alloc, "[{s}]", .{class_name}) catch null;
    return alloc.dupe(u8, class_name) catch null;
}

/// Map a Rails schema column method to its Ruby return type.
fn schemaColumnType(mname: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, mname, "string") or
        std.mem.eql(u8, mname, "text") or
        std.mem.eql(u8, mname, "uuid") or
        std.mem.eql(u8, mname, "binary") or
        std.mem.eql(u8, mname, "citext")) return "String";
    if (std.mem.eql(u8, mname, "integer") or
        std.mem.eql(u8, mname, "bigint") or
        std.mem.eql(u8, mname, "smallint") or
        std.mem.eql(u8, mname, "tinyint")) return "Integer";
    if (std.mem.eql(u8, mname, "float") or
        std.mem.eql(u8, mname, "decimal") or
        std.mem.eql(u8, mname, "numeric") or
        std.mem.eql(u8, mname, "real")) return "Float";
    if (std.mem.eql(u8, mname, "boolean")) return "TrueClass | FalseClass";
    if (std.mem.eql(u8, mname, "date")) return "Date";
    if (std.mem.eql(u8, mname, "datetime") or
        std.mem.eql(u8, mname, "timestamp") or
        std.mem.eql(u8, mname, "timestamptz") or
        std.mem.eql(u8, mname, "time")) return "Time";
    if (std.mem.eql(u8, mname, "json") or
        std.mem.eql(u8, mname, "jsonb") or
        std.mem.eql(u8, mname, "hstore")) return "Hash";
    if (std.mem.eql(u8, mname, "references") or
        std.mem.eql(u8, mname, "belongs_to")) return "Integer"; // _id column
    return null;
}

/// Convert a snake_case table name to a CamelCase model name.
/// Writes into `buf`, returns a slice into buf or null if the name is too long.
fn tableNameToModel(table: []const u8, buf: []u8) ?[]u8 {
    // Singularize: strip trailing 's' or 'ies'
    var singular: []const u8 = table;
    if (std.mem.endsWith(u8, table, "ies") and table.len > 3) {
        // categories → category
        const base = table[0 .. table.len - 3];
        if (base.len + 1 > buf.len) return null;
        @memcpy(buf[0..base.len], base);
        buf[base.len] = 'y';
        singular = buf[0 .. base.len + 1];
        // Now camelCase below using temp singular
        return snakeToCamel(singular, buf);
    }
    if (std.mem.endsWith(u8, table, "s") and table.len > 1) {
        singular = table[0 .. table.len - 1];
    }
    return snakeToCamel(singular, buf);
}

fn snakeToCamel(snake: []const u8, buf: []u8) ?[]u8 {
    if (snake.len == 0 or snake.len > buf.len) return null;
    var out: usize = 0;
    var cap_next = true;
    for (snake) |c| {
        if (c == '_') {
            cap_next = true;
            continue;
        }
        if (out >= buf.len) return null;
        buf[out] = if (cap_next) std.ascii.toUpper(c) else c;
        out += 1;
        cap_next = false;
    }
    return buf[0..out];
}

fn insertRailsDslSymbols(ctx: *VisitCtx, cn: *const prism.CallNode, mname: []const u8) !void {
    // default_scope takes a block/lambda, not a named symbol arg — handle before arg checks
    if (std.mem.eql(u8, mname, "default_scope")) {
        const lc = locationLineCol(ctx.parser, cn.base.location.start);
        var ns_buf_ds: [256]u8 = undefined;
        const parent_ds = if (ctx.namespace_stack_len > 0) namespaceFromStack(ctx, &ns_buf_ds) else null;
        try insertSymbolWithReturn(ctx, "scope", "default_scope", lc.line, lc.col, null, mname, parent_ds, null);
        return;
    }
    if (cn.arguments == null) return;
    const args_list = cn.arguments[0].arguments;
    if (args_list.size == 0) return;
    const first_arg = args_list.nodes[0];
    const lc = locationLineCol(ctx.parser, first_arg.*.location.start);
    var sym_name: []const u8 = undefined;
    if (first_arg.*.type == prism.NODE_SYMBOL) {
        const sym: *const prism.SymbolNode = @ptrCast(@alignCast(first_arg));
        if (sym.unescaped.source == null) return;
        sym_name = sym.unescaped.source[0..sym.unescaped.length];
    } else if (first_arg.*.type == prism.NODE_STRING) {
        const sn: *const prism.StringNode = @ptrCast(@alignCast(first_arg));
        if (sn.unescaped.source == null) return;
        sym_name = sn.unescaped.source[0..sn.unescaped.length];
    } else return;
    const kind: []const u8 =
        if (std.mem.eql(u8, mname, "scope")) "scope" else if (std.mem.eql(u8, mname, "belongs_to") or
        std.mem.eql(u8, mname, "has_many") or
        std.mem.eql(u8, mname, "has_one") or
        std.mem.eql(u8, mname, "has_and_belongs_to_many") or
        std.mem.eql(u8, mname, "delegated_type") or
        std.mem.eql(u8, mname, "one_to_many") or
        std.mem.eql(u8, mname, "many_to_one") or
        std.mem.eql(u8, mname, "many_to_many") or
        std.mem.eql(u8, mname, "one_to_one") or
        std.mem.eql(u8, mname, "one_through_one") or
        std.mem.eql(u8, mname, "many_through_many")) "association" else if (std.mem.eql(u8, mname, "encrypts") or
        std.mem.eql(u8, mname, "normalizes")) "validation" else if (std.mem.eql(u8, mname, "connects_to") or
        std.mem.eql(u8, mname, "queue_as") or
        std.mem.eql(u8, mname, "retry_on") or
        std.mem.eql(u8, mname, "discard_on") or
        std.mem.eql(u8, mname, "default")) "callback" else if (std.mem.eql(u8, mname, "shared_examples_for") or
        std.mem.eql(u8, mname, "shared_context") or
        std.mem.eql(u8, mname, "shared_examples")) "module" else if (std.mem.eql(u8, mname, "describe") or
        std.mem.eql(u8, mname, "context") or
        std.mem.eql(u8, mname, "it") or
        std.mem.eql(u8, mname, "specify")) "test" else if (std.mem.eql(u8, mname, "let") or
        std.mem.eql(u8, mname, "let!") or
        std.mem.eql(u8, mname, "subject") or
        std.mem.eql(u8, mname, "association")) "variable" else if (std.mem.eql(u8, mname, "factory") or
        std.mem.eql(u8, mname, "trait")) "class" else if (std.mem.startsWith(u8, mname, "validates")) "validation" else if (std.mem.eql(u8, mname, "before_action") or
        std.mem.eql(u8, mname, "after_action") or
        std.mem.eql(u8, mname, "around_action") or
        std.mem.eql(u8, mname, "before_create") or
        std.mem.eql(u8, mname, "after_create") or
        std.mem.eql(u8, mname, "before_save") or
        std.mem.eql(u8, mname, "after_save") or
        std.mem.eql(u8, mname, "before_destroy") or
        std.mem.eql(u8, mname, "after_destroy") or
        std.mem.eql(u8, mname, "before_update") or
        std.mem.eql(u8, mname, "after_update") or
        std.mem.eql(u8, mname, "around_create") or
        std.mem.eql(u8, mname, "around_save") or
        std.mem.eql(u8, mname, "around_destroy") or
        std.mem.eql(u8, mname, "around_update") or
        std.mem.eql(u8, mname, "before_validation") or
        std.mem.eql(u8, mname, "after_initialize") or
        std.mem.eql(u8, mname, "after_find") or
        std.mem.eql(u8, mname, "after_commit") or
        std.mem.eql(u8, mname, "before_commit") or
        std.mem.eql(u8, mname, "after_rollback") or
        std.mem.eql(u8, mname, "after_touch") or
        std.mem.eql(u8, mname, "after_validation") or
        std.mem.eql(u8, mname, "validate")) "callback" else "def";
    var ns_buf: [256]u8 = undefined;
    const parent = if (ctx.namespace_stack_len > 0) namespaceFromStack(ctx, &ns_buf) else null;
    // Capture the full DSL call source as value_snippet (e.g. "has_many :posts, dependent: :destroy")
    var call_snip_buf: [123]u8 = undefined;
    var call_snip: ?[]const u8 = null;
    const call_start = cn.base.location.start;
    const call_full_len = cn.base.location.length;
    const call_vlen = @min(call_full_len, 120);
    if (@as(usize, call_start) + call_vlen <= ctx.source.len) {
        @memcpy(call_snip_buf[0..call_vlen], ctx.source[@as(usize, call_start) .. @as(usize, call_start) + call_vlen]);
        const call_snip_end = if (call_full_len > 120) blk: {
            @memcpy(call_snip_buf[call_vlen .. call_vlen + 3], "\u{2026}");
            break :blk call_vlen + 3;
        } else call_vlen;
        call_snip = call_snip_buf[0..call_snip_end];
    }
    // Scan keyword hash options for class_name:, through:, polymorphic:
    var class_name_opt: ?[]const u8 = null;
    var through_join: ?[]const u8 = null;
    var is_polymorphic = false;
    if (args_list.size > 1) {
        for (1..args_list.size) |oi| {
            const opt_arg = args_list.nodes[oi];
            if (opt_arg.*.type != prism.NODE_KEYWORD_HASH) continue;
            const kh_opt: *const prism.KeywordHashNode = @ptrCast(@alignCast(opt_arg));
            for (0..kh_opt.elements.size) |ej| {
                const kh_elem = kh_opt.elements.nodes[ej];
                if (kh_elem.*.type != prism.NODE_ASSOC) continue;
                const kh_assoc: *const prism.AssocNode = @ptrCast(@alignCast(kh_elem));
                if (kh_assoc.key.*.type != prism.NODE_SYMBOL) continue;
                const kh_ksym: *const prism.SymbolNode = @ptrCast(@alignCast(kh_assoc.key));
                if (kh_ksym.unescaped.source == null) continue;
                const kname = kh_ksym.unescaped.source[0..kh_ksym.unescaped.length];
                if (std.mem.eql(u8, kname, "class_name")) {
                    if (kh_assoc.value.*.type == prism.NODE_STRING) {
                        const cn_sv: *const prism.StringNode = @ptrCast(@alignCast(kh_assoc.value));
                        if (cn_sv.unescaped.source != null)
                            class_name_opt = cn_sv.unescaped.source[0..cn_sv.unescaped.length];
                    }
                } else if (std.mem.eql(u8, kname, "through")) {
                    if (kh_assoc.value.*.type == prism.NODE_SYMBOL) {
                        const tj_sym: *const prism.SymbolNode = @ptrCast(@alignCast(kh_assoc.value));
                        if (tj_sym.unescaped.source != null)
                            through_join = tj_sym.unescaped.source[0..tj_sym.unescaped.length];
                    } else if (kh_assoc.value.*.type == prism.NODE_STRING) {
                        const tj_sv: *const prism.StringNode = @ptrCast(@alignCast(kh_assoc.value));
                        if (tj_sv.unescaped.source != null)
                            through_join = tj_sv.unescaped.source[0..tj_sv.unescaped.length];
                    }
                } else if (std.mem.eql(u8, kname, "polymorphic")) {
                    if (kh_assoc.value.*.type == prism.NODE_TRUE) is_polymorphic = true;
                }
            }
        }
    }
    // When through: is present, store a structured value_snippet so MCP tools can detect it.
    // Polymorphic associations override with a "polymorphic" marker.
    var through_vs_buf: [128]u8 = undefined;
    const effective_snip: ?[]const u8 = if (is_polymorphic)
        "polymorphic"
    else if (through_join) |tj|
        std.fmt.bufPrint(&through_vs_buf, "through:{s}", .{tj}) catch call_snip
    else
        call_snip;
    // Polymorphic belongs_to has no static return type — the concrete type lives in *_type column.
    const assoc_return_type = if (is_polymorphic) null else inferAssocReturnType(ctx.alloc, mname, sym_name, class_name_opt);
    defer if (assoc_return_type) |rt| ctx.alloc.free(rt);
    if (assoc_return_type) |rt| {
        try insertSymbolWithReturn(ctx, kind, sym_name, lc.line, lc.col, rt, mname, parent, effective_snip);
    } else if (std.mem.eql(u8, mname, "scope") and ctx.namespace_stack_len > 0) {
        var scope_buf: [270]u8 = undefined;
        const class_name = parent orelse "";
        const scope_rt = if (class_name.len > 0) std.fmt.bufPrint(&scope_buf, "[{s}]", .{class_name}) catch null else null;
        if (scope_rt) |srt| {
            try insertSymbolWithReturn(ctx, kind, sym_name, lc.line, lc.col, srt, mname, parent, effective_snip);
        } else {
            try insertSymbolWithReturn(ctx, kind, sym_name, lc.line, lc.col, null, mname, parent, effective_snip);
        }
    } else {
        try insertSymbolWithReturn(ctx, kind, sym_name, lc.line, lc.col, null, mname, parent, effective_snip);
    }
}

fn insertEnumValues(ctx: *VisitCtx, vn: *const prism.Node) !void {
    if (vn.*.type == prism.NODE_ARRAY) {
        const arr: *const prism.ArrayNode = @ptrCast(@alignCast(vn));
        for (0..arr.elements.size) |i| {
            const elem = arr.elements.nodes[i];
            if (elem.*.type != prism.NODE_SYMBOL) continue;
            const vsym: *const prism.SymbolNode = @ptrCast(@alignCast(elem));
            if (vsym.unescaped.source == null) continue;
            const vname = vsym.unescaped.source[0..vsym.unescaped.length];
            const vlc = locationLineCol(ctx.parser, elem.*.location.start);
            try insertSymbol(ctx, "def", vname, vlc.line, vlc.col, null);
            try insertEnumValueMethods(ctx, vname, vlc.line, vlc.col);
        }
    } else if (vn.*.type == prism.NODE_HASH) {
        const hn: *const prism.HashNode = @ptrCast(@alignCast(vn));
        for (0..hn.elements.size) |i| {
            const elem = hn.elements.nodes[i];
            if (elem.*.type != prism.NODE_ASSOC) continue;
            const assoc: *const prism.AssocNode = @ptrCast(@alignCast(elem));
            if (assoc.key.*.type != prism.NODE_SYMBOL) continue;
            const ksym: *const prism.SymbolNode = @ptrCast(@alignCast(assoc.key));
            if (ksym.unescaped.source == null) continue;
            const vname = ksym.unescaped.source[0..ksym.unescaped.length];
            const vlc = locationLineCol(ctx.parser, assoc.key.*.location.start);
            try insertSymbol(ctx, "def", vname, vlc.line, vlc.col, null);
            try insertEnumValueMethods(ctx, vname, vlc.line, vlc.col);
        }
    } else if (vn.*.type == prism.NODE_KEYWORD_HASH) {
        const kh: *const prism.KeywordHashNode = @ptrCast(@alignCast(vn));
        for (0..kh.elements.size) |i| {
            const elem = kh.elements.nodes[i];
            if (elem.*.type != prism.NODE_ASSOC) continue;
            const assoc: *const prism.AssocNode = @ptrCast(@alignCast(elem));
            if (assoc.key.*.type != prism.NODE_SYMBOL) continue;
            const ksym: *const prism.SymbolNode = @ptrCast(@alignCast(assoc.key));
            if (ksym.unescaped.source == null) continue;
            const vname = ksym.unescaped.source[0..ksym.unescaped.length];
            const vlc = locationLineCol(ctx.parser, assoc.key.*.location.start);
            try insertSymbol(ctx, "def", vname, vlc.line, vlc.col, null);
            try insertEnumValueMethods(ctx, vname, vlc.line, vlc.col);
        }
    }
}

// Inserts the Rails-generated predicate, bang, and scope methods for one enum value.
// e.g. for value "active": active? active! and scope active
fn insertEnumValueMethods(ctx: *VisitCtx, vname: []const u8, line: i64, col: i64) !void {
    if (vname.len == 0 or vname.len > 120) return;
    const l: i32 = @intCast(@min(line, std.math.maxInt(i32)));
    const c: u32 = @intCast(@min(@max(col, 0), std.math.maxInt(u32)));
    var pred_buf: [128]u8 = undefined;
    const pred = std.fmt.bufPrint(&pred_buf, "{s}?", .{vname}) catch return;
    try insertSymbol(ctx, "def", pred, l, c, null);
    var bang_buf: [128]u8 = undefined;
    const bang = std.fmt.bufPrint(&bang_buf, "{s}!", .{vname}) catch return;
    try insertSymbol(ctx, "def", bang, l, c, null);
    // Rails also generates a class-level scope method with the same name
    try insertSymbol(ctx, "scope", vname, l, c, null);
}

fn insertEnumSymbols(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
    if (cn.arguments == null) return;
    const args = cn.arguments[0].arguments;
    if (args.size == 0) return;

    var values_node: ?*const prism.Node = null;

    // Style: enum :status, [:draft, :published]  (positional, Ruby 3.2+)
    if (args.nodes[0].*.type == prism.NODE_SYMBOL) {
        const sym: *const prism.SymbolNode = @ptrCast(@alignCast(args.nodes[0]));
        if (sym.unescaped.source) |src| {
            const lc = locationLineCol(ctx.parser, args.nodes[0].*.location.start);
            try insertSymbol(ctx, "def", src[0..sym.unescaped.length], lc.line, lc.col, null);
        }
        if (args.size >= 2) values_node = args.nodes[1];
    }
    // Style: enum status: [:draft, :published]  (keyword hash, Rails 4+)
    // Each key in the hash is a separate enum attribute; process them all.
    else if (args.nodes[0].*.type == prism.NODE_KEYWORD_HASH) {
        const kh: *const prism.KeywordHashNode = @ptrCast(@alignCast(args.nodes[0]));
        for (0..kh.elements.size) |ki| {
            const elem = kh.elements.nodes[ki];
            if (elem.*.type != prism.NODE_ASSOC) continue;
            const assoc: *const prism.AssocNode = @ptrCast(@alignCast(elem));
            if (assoc.key.*.type != prism.NODE_SYMBOL) continue;
            const ksym: *const prism.SymbolNode = @ptrCast(@alignCast(assoc.key));
            if (ksym.unescaped.source == null) continue;
            const lc = locationLineCol(ctx.parser, assoc.key.*.location.start);
            try insertSymbol(ctx, "def", ksym.unescaped.source[0..ksym.unescaped.length], lc.line, lc.col, null);
            // Index values from this key's array/hash
            insertEnumValues(ctx, assoc.value) catch {
                ctx.error_count += 1;
            };
        }
        return; // values already handled per-key above
    }

    const vn = values_node orelse return;
    try insertEnumValues(ctx, vn);
}

// Rails 5.2 – 8.0 DSL synthesis helpers.
// Each extracts a first symbol/string arg and emits a small fixed family of
// accessor methods, mirroring what Rails generates at runtime.

fn extractFirstSymbolName(cn: *const prism.CallNode) ?[]const u8 {
    if (cn.arguments == null) return null;
    const args = cn.arguments[0].arguments;
    if (args.size == 0) return null;
    const first = args.nodes[0];
    if (first.*.type == prism.NODE_SYMBOL) {
        const sym: *const prism.SymbolNode = @ptrCast(@alignCast(first));
        if (sym.unescaped.source == null) return null;
        return sym.unescaped.source[0..sym.unescaped.length];
    } else if (first.*.type == prism.NODE_STRING) {
        const sn: *const prism.StringNode = @ptrCast(@alignCast(first));
        if (sn.unescaped.source == null) return null;
        return sn.unescaped.source[0..sn.unescaped.length];
    }
    return null;
}

fn insertAttachedSymbols(ctx: *VisitCtx, cn: *const prism.CallNode, mname: []const u8) !void {
    const sym_name = extractFirstSymbolName(cn) orelse return;
    if (sym_name.len == 0 or sym_name.len > 100) return;
    const lc = locationLineCol(ctx.parser, cn.arguments[0].arguments.nodes[0].*.location.start);
    const is_many = std.mem.eql(u8, mname, "has_many_attached");
    const reader_type: []const u8 = if (is_many) "ActiveStorage::Attached::Many" else "ActiveStorage::Attached::One";
    const att_type: []const u8 = if (is_many) "ActiveStorage::Attachment::Many" else "ActiveStorage::Attachment";
    const blob_type: []const u8 = if (is_many) "ActiveStorage::Blob::Many" else "ActiveStorage::Blob";
    const att_suffix: []const u8 = if (is_many) "_attachments" else "_attachment";
    const blob_suffix: []const u8 = if (is_many) "_blobs" else "_blob";
    var ns_buf: [256]u8 = undefined;
    const parent = if (ctx.namespace_stack_len > 0) namespaceFromStack(ctx, &ns_buf) else null;

    try insertSymbolWithReturn(ctx, "def", sym_name, lc.line, lc.col, reader_type, mname, parent, null);
    var w_buf: [128]u8 = undefined;
    const w = std.fmt.bufPrint(&w_buf, "{s}=", .{sym_name}) catch return;
    try insertSymbolWithReturn(ctx, "def", w, lc.line, lc.col, null, mname, parent, null);
    var a_buf: [128]u8 = undefined;
    const a = std.fmt.bufPrint(&a_buf, "{s}{s}", .{ sym_name, att_suffix }) catch return;
    try insertSymbolWithReturn(ctx, "def", a, lc.line, lc.col, att_type, mname, parent, null);
    var b_buf: [128]u8 = undefined;
    const b = std.fmt.bufPrint(&b_buf, "{s}{s}", .{ sym_name, blob_suffix }) catch return;
    try insertSymbolWithReturn(ctx, "def", b, lc.line, lc.col, blob_type, mname, parent, null);
}

fn insertRichTextSymbols(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
    const sym_name = extractFirstSymbolName(cn) orelse return;
    if (sym_name.len == 0 or sym_name.len > 100) return;
    const lc = locationLineCol(ctx.parser, cn.arguments[0].arguments.nodes[0].*.location.start);
    var ns_buf: [256]u8 = undefined;
    const parent = if (ctx.namespace_stack_len > 0) namespaceFromStack(ctx, &ns_buf) else null;

    try insertSymbolWithReturn(ctx, "def", sym_name, lc.line, lc.col, "ActionText::RichText", "has_rich_text", parent, null);
    var w_buf: [128]u8 = undefined;
    const w = std.fmt.bufPrint(&w_buf, "{s}=", .{sym_name}) catch return;
    try insertSymbolWithReturn(ctx, "def", w, lc.line, lc.col, null, "has_rich_text", parent, null);
    var p_buf: [128]u8 = undefined;
    const p = std.fmt.bufPrint(&p_buf, "{s}?", .{sym_name}) catch return;
    try insertSymbolWithReturn(ctx, "def", p, lc.line, lc.col, "TrueClass | FalseClass", "has_rich_text", parent, null);
}

fn insertSecurePasswordSymbols(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
    var prefix: []const u8 = "password";
    var line: i32 = 0;
    var col: u32 = 0;
    if (cn.arguments != null) {
        const args = cn.arguments[0].arguments;
        if (args.size > 0 and args.nodes[0].*.type == prism.NODE_SYMBOL) {
            const sym: *const prism.SymbolNode = @ptrCast(@alignCast(args.nodes[0]));
            if (sym.unescaped.source) |src| {
                if (sym.unescaped.length > 0 and sym.unescaped.length <= 80) prefix = src[0..sym.unescaped.length];
            }
            const lc = locationLineCol(ctx.parser, args.nodes[0].*.location.start);
            line = lc.line;
            col = lc.col;
        } else {
            const lc = locationLineCol(ctx.parser, cn.base.location.start);
            line = lc.line;
            col = lc.col;
        }
    } else {
        const lc = locationLineCol(ctx.parser, cn.base.location.start);
        line = lc.line;
        col = lc.col;
    }
    var ns_buf: [256]u8 = undefined;
    const parent = if (ctx.namespace_stack_len > 0) namespaceFromStack(ctx, &ns_buf) else null;

    var b1: [128]u8 = undefined;
    const setter = std.fmt.bufPrint(&b1, "{s}=", .{prefix}) catch return;
    try insertSymbolWithReturn(ctx, "def", setter, line, col, "String", "has_secure_password", parent, null);
    var b2: [128]u8 = undefined;
    const conf = std.fmt.bufPrint(&b2, "{s}_confirmation=", .{prefix}) catch return;
    try insertSymbolWithReturn(ctx, "def", conf, line, col, "String", "has_secure_password", parent, null);
    var b3: [128]u8 = undefined;
    const digest = std.fmt.bufPrint(&b3, "{s}_digest", .{prefix}) catch return;
    try insertSymbolWithReturn(ctx, "def", digest, line, col, "String", "has_secure_password", parent, null);
    if (std.mem.eql(u8, prefix, "password")) {
        try insertSymbolWithReturn(ctx, "def", "authenticate", line, col, null, "has_secure_password", parent, null);
    } else {
        var b4: [128]u8 = undefined;
        const auth = std.fmt.bufPrint(&b4, "authenticate_{s}", .{prefix}) catch return;
        try insertSymbolWithReturn(ctx, "def", auth, line, col, null, "has_secure_password", parent, null);
    }
}

fn insertSecureTokenSymbols(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
    var name: []const u8 = "token";
    var line: i32 = 0;
    var col: u32 = 0;
    if (cn.arguments != null) {
        const args = cn.arguments[0].arguments;
        if (args.size > 0 and args.nodes[0].*.type == prism.NODE_SYMBOL) {
            const sym: *const prism.SymbolNode = @ptrCast(@alignCast(args.nodes[0]));
            if (sym.unescaped.source) |src| {
                if (sym.unescaped.length > 0 and sym.unescaped.length <= 80) name = src[0..sym.unescaped.length];
            }
            const lc = locationLineCol(ctx.parser, args.nodes[0].*.location.start);
            line = lc.line;
            col = lc.col;
        } else {
            const lc = locationLineCol(ctx.parser, cn.base.location.start);
            line = lc.line;
            col = lc.col;
        }
    } else {
        const lc = locationLineCol(ctx.parser, cn.base.location.start);
        line = lc.line;
        col = lc.col;
    }
    var ns_buf: [256]u8 = undefined;
    const parent = if (ctx.namespace_stack_len > 0) namespaceFromStack(ctx, &ns_buf) else null;

    try insertSymbolWithReturn(ctx, "def", name, line, col, "String", "has_secure_token", parent, null);
    var bw: [128]u8 = undefined;
    const w = std.fmt.bufPrint(&bw, "{s}=", .{name}) catch return;
    try insertSymbolWithReturn(ctx, "def", w, line, col, "String", "has_secure_token", parent, null);
    var br: [128]u8 = undefined;
    const r = std.fmt.bufPrint(&br, "regenerate_{s}", .{name}) catch return;
    try insertSymbolWithReturn(ctx, "def", r, line, col, "String", "has_secure_token", parent, null);
}

fn insertAttributeSymbol(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
    const name = extractFirstSymbolName(cn) orelse return;
    if (name.len == 0 or name.len > 100) return;
    const args = cn.arguments[0].arguments;
    const lc = locationLineCol(ctx.parser, args.nodes[0].*.location.start);
    var ns_buf: [256]u8 = undefined;
    const parent = if (ctx.namespace_stack_len > 0) namespaceFromStack(ctx, &ns_buf) else null;

    var rt: ?[]const u8 = null;
    if (args.size >= 2 and args.nodes[1].*.type == prism.NODE_SYMBOL) {
        const t_sym: *const prism.SymbolNode = @ptrCast(@alignCast(args.nodes[1]));
        if (t_sym.unescaped.source) |src| {
            const tname = src[0..t_sym.unescaped.length];
            rt = schemaColumnType(tname);
        }
    }

    try insertSymbolWithReturn(ctx, "def", name, lc.line, lc.col, rt, "attribute", parent, null);
    var bw: [128]u8 = undefined;
    const w = std.fmt.bufPrint(&bw, "{s}=", .{name}) catch return;
    try insertSymbolWithReturn(ctx, "def", w, lc.line, lc.col, rt, "attribute", parent, null);
    var bp: [128]u8 = undefined;
    const p = std.fmt.bufPrint(&bp, "{s}?", .{name}) catch return;
    try insertSymbolWithReturn(ctx, "def", p, lc.line, lc.col, "TrueClass | FalseClass", "attribute", parent, null);
}

fn insertStoreAccessorSymbols(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
    if (cn.arguments == null) return;
    const args = cn.arguments[0].arguments;
    if (args.size < 2) return;
    var ns_buf: [256]u8 = undefined;
    const parent = if (ctx.namespace_stack_len > 0) namespaceFromStack(ctx, &ns_buf) else null;

    var i: usize = 1;
    while (i < args.size) : (i += 1) {
        const arg = args.nodes[i];
        if (arg.*.type != prism.NODE_SYMBOL) continue;
        const sym: *const prism.SymbolNode = @ptrCast(@alignCast(arg));
        if (sym.unescaped.source == null) continue;
        const name = sym.unescaped.source[0..sym.unescaped.length];
        if (name.len == 0 or name.len > 100) continue;
        const lc = locationLineCol(ctx.parser, arg.*.location.start);
        try insertSymbolWithReturn(ctx, "def", name, lc.line, lc.col, "Object", "store_accessor", parent, null);
        var bw: [128]u8 = undefined;
        const w = std.fmt.bufPrint(&bw, "{s}=", .{name}) catch continue;
        try insertSymbolWithReturn(ctx, "def", w, lc.line, lc.col, null, "store_accessor", parent, null);
    }
}

fn insertComposedOfSymbols(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
    const name = extractFirstSymbolName(cn) orelse return;
    if (name.len == 0 or name.len > 100) return;
    const args = cn.arguments[0].arguments;
    const lc = locationLineCol(ctx.parser, args.nodes[0].*.location.start);
    var ns_buf: [256]u8 = undefined;
    const parent = if (ctx.namespace_stack_len > 0) namespaceFromStack(ctx, &ns_buf) else null;

    var class_buf: [128]u8 = undefined;
    var class_name: ?[]const u8 = null;
    var idx: usize = 1;
    while (idx < args.size) : (idx += 1) {
        const a = args.nodes[idx];
        if (a.*.type != prism.NODE_KEYWORD_HASH) continue;
        const kh: *const prism.KeywordHashNode = @ptrCast(@alignCast(a));
        for (0..kh.elements.size) |ej| {
            const e = kh.elements.nodes[ej];
            if (e.*.type != prism.NODE_ASSOC) continue;
            const ass: *const prism.AssocNode = @ptrCast(@alignCast(e));
            if (ass.key.*.type != prism.NODE_SYMBOL) continue;
            const ks: *const prism.SymbolNode = @ptrCast(@alignCast(ass.key));
            if (ks.unescaped.source == null) continue;
            const kn = ks.unescaped.source[0..ks.unescaped.length];
            if (std.mem.eql(u8, kn, "class_name") and ass.value.*.type == prism.NODE_STRING) {
                const sv: *const prism.StringNode = @ptrCast(@alignCast(ass.value));
                if (sv.unescaped.source) |src| class_name = src[0..sv.unescaped.length];
            }
        }
    }
    if (class_name == null) class_name = snakeToCamel(name, &class_buf);

    try insertSymbolWithReturn(ctx, "def", name, lc.line, lc.col, class_name, "composed_of", parent, null);
    var bw: [128]u8 = undefined;
    const w = std.fmt.bufPrint(&bw, "{s}=", .{name}) catch return;
    try insertSymbolWithReturn(ctx, "def", w, lc.line, lc.col, class_name, "composed_of", parent, null);
}

fn insertDelegatedTypeSymbols(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
    const name = extractFirstSymbolName(cn) orelse return;
    if (name.len == 0 or name.len > 100) return;
    const args = cn.arguments[0].arguments;
    const lc = locationLineCol(ctx.parser, args.nodes[0].*.location.start);
    var ns_buf: [256]u8 = undefined;
    const parent = if (ctx.namespace_stack_len > 0) namespaceFromStack(ctx, &ns_buf) else null;

    try insertSymbolWithReturn(ctx, "association", name, lc.line, lc.col, null, "delegated_type", parent, null);
    var bt: [128]u8 = undefined;
    const t = std.fmt.bufPrint(&bt, "{s}_type", .{name}) catch return;
    try insertSymbolWithReturn(ctx, "def", t, lc.line, lc.col, "String", "delegated_type", parent, null);
    var bi: [128]u8 = undefined;
    const i_ = std.fmt.bufPrint(&bi, "{s}_id", .{name}) catch return;
    try insertSymbolWithReturn(ctx, "def", i_, lc.line, lc.col, "Integer", "delegated_type", parent, null);
    var bc: [128]u8 = undefined;
    const c_ = std.fmt.bufPrint(&bc, "{s}_class", .{name}) catch return;
    try insertSymbolWithReturn(ctx, "def", c_, lc.line, lc.col, "Class", "delegated_type", parent, null);
}

fn insertNestedAttributesSymbols(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
    if (cn.arguments == null) return;
    const args = cn.arguments[0].arguments;
    var ns_buf: [256]u8 = undefined;
    const parent = if (ctx.namespace_stack_len > 0) namespaceFromStack(ctx, &ns_buf) else null;

    var i: usize = 0;
    while (i < args.size) : (i += 1) {
        const arg = args.nodes[i];
        if (arg.*.type != prism.NODE_SYMBOL) continue;
        const sym: *const prism.SymbolNode = @ptrCast(@alignCast(arg));
        if (sym.unescaped.source == null) continue;
        const name = sym.unescaped.source[0..sym.unescaped.length];
        if (name.len == 0 or name.len > 100) continue;
        const lc = locationLineCol(ctx.parser, arg.*.location.start);
        var bw: [160]u8 = undefined;
        const w = std.fmt.bufPrint(&bw, "{s}_attributes=", .{name}) catch continue;
        try insertSymbolWithReturn(ctx, "def", w, lc.line, lc.col, null, "accepts_nested_attributes_for", parent, null);
    }
}

fn updateSymbolReturnType(db: db_mod.Db, symbol_id: i64, return_type: []const u8) !void {
    const stmt = try db.prepare("UPDATE symbols SET return_type = ? WHERE id = ?");
    defer stmt.finalize();
    stmt.bind_text(1, return_type);
    stmt.bind_int(2, symbol_id);
    _ = try stmt.step();
}

fn extractTypeAnnotation(source: []const u8, offset: usize) ?[]const u8 {
    if (offset == 0) return null;
    var pos = offset;
    while (pos > 0 and source[pos - 1] != '\n') pos -= 1;
    if (pos == 0) return null;
    pos -= 1;
    const line_end = pos;
    while (pos > 0 and source[pos - 1] != '\n') pos -= 1;
    const prev_line = std.mem.trim(u8, source[pos..line_end], " \t\r");
    const prefix = "# @type ";
    if (!std.mem.startsWith(u8, prev_line, prefix)) return null;
    const rest = prev_line[prefix.len..];
    if (rest.len > 0 and rest[0] == '[') {
        const end = std.mem.indexOf(u8, rest, "]") orelse return null;
        return rest[1..end];
    }
    if (rest.len > 1 and rest[0] == ':') {
        return std.mem.trim(u8, rest[1..], " ");
    }
    return null;
}

fn extractNewCallType(parser: *prism.Parser, node: ?*const prism.Node) ?[]const u8 {
    const n = node orelse return null;
    if (n.*.type == prism.NODE_CASE) {
        const cn: *const prism.CaseNode = @ptrCast(@alignCast(n));
        if (cn.conditions.size > 0) {
            const when_generic = cn.conditions.nodes[0];
            if (when_generic.*.type == prism.NODE_WHEN) {
                const wn: *const prism.WhenNode = @ptrCast(@alignCast(when_generic));
                if (wn.statements != null) {
                    const stmts: *const prism.StatementsNode = @ptrCast(@alignCast(wn.statements));
                    if (stmts.body.size > 0) {
                        return extractNewCallType(parser, stmts.body.nodes[stmts.body.size - 1]);
                    }
                }
            }
        }
        return null;
    }
    if (n.*.type != prism.NODE_CALL) return null;
    const call: *const prism.CallNode = @ptrCast(@alignCast(n));
    const mname = resolveConstant(parser, call.name);
    const recv = call.receiver orelse return null;
    // Stdlib return type for literal receivers (e.g. "hello".upcase → String)
    if (inferLiteralType(recv)) |lrt| {
        if (lookupStdlibReturn(lrt, mname)) |rt| return rt;
    }
    // Stdlib return type for chained calls (e.g. "hi".upcase.length → Integer)
    if (recv.*.type == prism.NODE_CALL) {
        if (extractNewCallType(parser, recv)) |inner_type| {
            if (lookupStdlibReturn(inner_type, mname)) |rt| return rt;
        }
    }
    if (!std.mem.eql(u8, mname, "new")) {
        if (recv.*.type != prism.NODE_CONSTANT) return null;
        const rc: *const prism.ConstReadNode = @ptrCast(@alignCast(recv));
        const class_name = resolveConstant(parser, rc.name);
        const ar_singular = [_][]const u8{ "find", "first", "last", "create", "create!", "build", "find_by", "find_by!", "take" };
        for (ar_singular) |m| {
            if (std.mem.eql(u8, mname, m)) return class_name;
        }
        const ar_plural = [_][]const u8{ "where", "all", "order", "limit", "includes", "joins", "preload", "eager_load", "select", "group", "having", "left_joins", "left_outer_joins", "distinct" };
        for (ar_plural) |m| {
            if (std.mem.eql(u8, mname, m)) {
                return std.fmt.bufPrint(&ar_plural_buf, "[{s}]", .{class_name}) catch null;
            }
        }
        return null;
    }
    if (recv.*.type == prism.NODE_CONSTANT) {
        const rc: *const prism.ConstReadNode = @ptrCast(@alignCast(recv));
        return resolveConstant(parser, rc.name);
    } else if (recv.*.type == prism.NODE_CONSTANT_PATH) {
        const cp: *const prism.ConstantPathNode = @ptrCast(@alignCast(recv));
        if (cp.name != 0) return resolveConstant(parser, cp.name);
    }
    return null;
}

fn inferReceiverType(ctx: *VisitCtx, recv: *const prism.Node) ?[]const u8 {
    return inferReceiverTypeDepth(ctx, recv, 0);
}

fn inferReceiverTypeDepth(ctx: *VisitCtx, recv: *const prism.Node, depth: u8) ?[]const u8 {
    if (depth > 2) return null;
    if (recv.*.type == prism.NODE_LOCAL_VAR_READ) {
        const rv: *const prism.LocalVarReadNode = @ptrCast(@alignCast(recv));
        const rv_name = resolveConstant(ctx.parser, rv.name);
        if (ctx.db.prepare("SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1")) |lv| {
            defer lv.finalize();
            lv.bind_int(1, ctx.file_id);
            lv.bind_text(2, rv_name);
            if (lv.step() catch false) {
                const t = lv.column_text(0);
                if (t.len > 0) return t;
            }
        } else |_| {}
    } else if (recv.*.type == prism.NODE_INSTANCE_VAR_READ) {
        const rv: *const prism.InstanceVarReadNode = @ptrCast(@alignCast(recv));
        const rv_name = resolveConstant(ctx.parser, rv.name);
        if (ctx.db.prepare("SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1")) |lv| {
            defer lv.finalize();
            lv.bind_int(1, ctx.file_id);
            lv.bind_text(2, rv_name);
            if (lv.step() catch false) {
                const t = lv.column_text(0);
                if (t.len > 0) return t;
            }
        } else |_| {}
    } else if (recv.*.type == prism.NODE_SELF) {
        var ns_buf: [256]u8 = undefined;
        const ns = namespaceFromStack(ctx, &ns_buf);
        if (ns.len > 0) return ns;
    } else if (recv.*.type == prism.NODE_CALL) {
        const inner_call: *const prism.CallNode = @ptrCast(@alignCast(recv));
        const inner_method = resolveConstant(ctx.parser, inner_call.name);
        if (inner_call.receiver) |inner_recv| {
            if (inferReceiverTypeDepth(ctx, inner_recv, depth + 1)) |inner_type| {
                return lookupMethodReturn(ctx.db, inner_type, inner_method);
            }
        }
    }
    return null;
}

fn lookupMethodReturn(db: db_mod.Db, parent_name: []const u8, method_name: []const u8) ?[]const u8 {
    const stmt = db.prepare(
        \\SELECT return_type FROM symbols
        \\WHERE name = ? AND parent_name = ? AND kind IN ('def','classdef','scope')
        \\AND return_type IS NOT NULL LIMIT 1
    ) catch return null;
    defer stmt.finalize();
    stmt.bind_text(1, method_name);
    stmt.bind_text(2, parent_name);
    if (stmt.step() catch false) {
        const rt = stmt.column_text(0);
        if (rt.len > 0) return rt;
    }
    return null;
}

fn detectTypeGuard(parser: *prism.Parser, cond: *const prism.Node) ?struct { name: []const u8, narrowed_type: []const u8 } {
    // Truthy guard: `if x` → x is not nil/false (narrow to non-nil)
    if (cond.*.type == prism.NODE_LOCAL_VAR_READ) {
        const var_read: *const prism.LocalVarReadNode = @ptrCast(@alignCast(cond));
        return .{ .name = resolveConstant(parser, var_read.name), .narrowed_type = "Object" };
    }

    if (cond.*.type != prism.NODE_CALL) return null;
    const call: *const prism.CallNode = @ptrCast(@alignCast(cond));
    const method_name = resolveConstant(parser, call.name);

    const is_type_guard = std.mem.eql(u8, method_name, "is_a?") or
        std.mem.eql(u8, method_name, "kind_of?") or
        std.mem.eql(u8, method_name, "instance_of?");
    if (!is_type_guard) return null;

    // Receiver must be a simple local variable
    if (call.receiver == null) return null;
    const recv = call.receiver.?;
    if (recv.*.type != prism.NODE_LOCAL_VAR_READ) return null;
    const var_read: *const prism.LocalVarReadNode = @ptrCast(@alignCast(recv));
    const var_name = resolveConstant(parser, var_read.name);

    // First argument must be a constant (the class name)
    if (call.arguments == null) return null;
    const args = call.arguments[0].arguments;
    if (args.size == 0) return null;
    const first_arg = args.nodes[0];

    if (first_arg.*.type != prism.NODE_CONSTANT) return null;
    const const_node: *const prism.ConstReadNode = @ptrCast(@alignCast(first_arg));
    const class_name = resolveConstant(parser, const_node.name);

    return .{ .name = var_name, .narrowed_type = class_name };
}

fn detectNilGuard(parser: *prism.Parser, cond: *const prism.Node) ?[]const u8 {
    if (cond.*.type != prism.NODE_CALL) return null;
    const call: *const prism.CallNode = @ptrCast(@alignCast(cond));
    const method_name = resolveConstant(parser, call.name);
    if (!std.mem.eql(u8, method_name, "nil?")) return null;
    if (call.receiver == null) return null;
    const recv = call.receiver.?;
    if (recv.*.type != prism.NODE_LOCAL_VAR_READ) return null;
    const var_read: *const prism.LocalVarReadNode = @ptrCast(@alignCast(recv));
    return resolveConstant(parser, var_read.name);
}

fn editDistance(a: []const u8, b: []const u8) u32 {
    if (a.len > 64 or b.len > 64) return 99;
    if (a.len == 0) return @intCast(b.len);
    if (b.len == 0) return @intCast(a.len);
    var prev: [65]u32 = undefined;
    var curr: [65]u32 = undefined;
    for (0..b.len + 1) |j| prev[j] = @intCast(j);
    for (a, 0..) |ca, i| {
        curr[0] = @intCast(i + 1);
        for (b, 0..) |cb, j| {
            const cost: u32 = if (ca == cb) 0 else 1;
            curr[j + 1] = @min(@min(curr[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
    }
    return prev[b.len];
}

fn extractSorbetSig(source: []const u8, def_start: u32) ?[]const u8 {
    const scan_start = if (def_start > 300) def_start - 300 else 0;
    const scan_slice = source[scan_start..def_start];
    if (std.mem.lastIndexOf(u8, scan_slice, "returns(")) |ret_pos| {
        if (std.mem.lastIndexOf(u8, scan_slice[0..ret_pos], "sig")) |_| {
            const after_returns = scan_slice[ret_pos + 8 ..];
            if (std.mem.indexOf(u8, after_returns, ")")) |end| {
                const type_str = std.mem.trim(u8, after_returns[0..end], " \t\n");
                if (type_str.len > 0 and type_str.len < 64) {
                    return type_str;
                }
            }
        }
    }
    return null;
}

fn visitor(node: ?*const prism.Node, data: ?*anyopaque) callconv(.c) bool {
    const ctx: *VisitCtx = @ptrCast(@alignCast(data.?));
    const n = node.?;
    switch (n.*.type) {
        prism.NODE_CLASS => {
            const cn: *const prism.ClassNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, cn.base.location.start);
            const end_offset = cn.base.location.start + cn.base.location.length;
            const end_lc = locationLineCol(ctx.parser, end_offset);
            const name_owned = buildQualifiedName(ctx.parser, cn.constant_path, ctx.alloc) catch null;
            defer if (name_owned) |nm| ctx.alloc.free(nm);
            const short_name: []const u8 = resolveConstant(ctx.parser, cn.name);
            const base_name: []const u8 = name_owned orelse short_name;
            var ns_parent: ?[]u8 = null;
            defer if (ns_parent) |np| ctx.alloc.free(np);
            var fq_name: ?[]u8 = null;
            defer if (fq_name) |fq| ctx.alloc.free(fq);
            if (ctx.namespace_stack_len > 0) {
                var parts = std.ArrayList(u8).empty;
                defer parts.deinit(ctx.alloc);
                for (ctx.namespace_stack[0..ctx.namespace_stack_len]) |ns_part| {
                    if (parts.items.len > 0) parts.appendSlice(ctx.alloc, "::") catch {}; // OOM: namespace building
                    parts.appendSlice(ctx.alloc, ns_part) catch {}; // OOM: namespace building
                }
                ns_parent = parts.toOwnedSlice(ctx.alloc) catch null;
                if (ns_parent) |np| {
                    fq_name = std.fmt.allocPrint(ctx.alloc, "{s}::{s}", .{ np, base_name }) catch null;
                }
            } else if (std.mem.lastIndexOf(u8, base_name, "::")) |pos| {
                ns_parent = ctx.alloc.dupe(u8, base_name[0..pos]) catch null;
            }
            const insert_name: []const u8 = fq_name orelse base_name;
            const doc = extractDocComment(ctx.source, cn.base.location.start, ctx.alloc);
            defer if (doc) |d| ctx.alloc.free(d);
            const class_pn: ?[]const u8 = if (ns_parent) |np| if (np.len > 0) np else null else null;
            const class_sym_id = insertSymbolGetId(ctx, "class", insert_name, lc.line, lc.col, doc, @intCast(end_lc.line), "public", class_pn) catch 0;
            if (cn.superclass) |sc| {
                if (ns_parent == null) {
                    const pn_owned = buildQualifiedName(ctx.parser, sc, ctx.alloc) catch null;
                    defer if (pn_owned) |p| ctx.alloc.free(p);
                    const pn: []const u8 = pn_owned orelse "";
                    if (pn.len > 0 and class_sym_id > 0) {
                        if (ctx.db.prepare("UPDATE symbols SET parent_name=? WHERE id=?")) |u| {
                            defer u.finalize();
                            u.bind_text(1, pn);
                            u.bind_int(2, class_sym_id);
                            _ = u.step() catch false;
                        } else |_| {}
                    }
                }
            }
            addSemToken(ctx, lc.line, lc.col, @intCast(short_name.len), 0);
            const prev_class = ctx.current_class_id;
            const prev_vis = ctx.current_visibility;
            const prev_mf = ctx.module_function_mode;
            ctx.current_class_id = if (class_sym_id > 0) class_sym_id else null;
            ctx.current_visibility = "public";
            ctx.module_function_mode = false;
            const ns_pushed_class = ctx.namespace_stack_len < 64;
            if (ns_pushed_class) {
                ctx.namespace_stack[ctx.namespace_stack_len] = short_name;
                ctx.namespace_stack_len += 1;
            }
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            if (ns_pushed_class and ctx.namespace_stack_len > 0) ctx.namespace_stack_len -= 1;
            ctx.current_class_id = prev_class;
            ctx.current_visibility = prev_vis;
            ctx.module_function_mode = prev_mf;
            return false;
        },
        prism.NODE_MODULE => {
            const mn: *const prism.ModuleNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, mn.base.location.start);
            const end_offset = mn.base.location.start + mn.base.location.length;
            const end_lc = locationLineCol(ctx.parser, end_offset);
            const name_owned = buildQualifiedName(ctx.parser, mn.constant_path, ctx.alloc) catch null;
            defer if (name_owned) |nm| ctx.alloc.free(nm);
            const short_name: []const u8 = resolveConstant(ctx.parser, mn.name);
            const base_name: []const u8 = name_owned orelse short_name;
            var ns_parent: ?[]u8 = null;
            defer if (ns_parent) |np| ctx.alloc.free(np);
            var fq_name: ?[]u8 = null;
            defer if (fq_name) |fq| ctx.alloc.free(fq);
            if (ctx.namespace_stack_len > 0) {
                var parts = std.ArrayList(u8).empty;
                defer parts.deinit(ctx.alloc);
                for (ctx.namespace_stack[0..ctx.namespace_stack_len]) |ns_part| {
                    if (parts.items.len > 0) parts.appendSlice(ctx.alloc, "::") catch {}; // OOM: namespace building
                    parts.appendSlice(ctx.alloc, ns_part) catch {}; // OOM: namespace building
                }
                ns_parent = parts.toOwnedSlice(ctx.alloc) catch null;
                if (ns_parent) |np| {
                    fq_name = std.fmt.allocPrint(ctx.alloc, "{s}::{s}", .{ np, base_name }) catch null;
                }
            } else if (std.mem.lastIndexOf(u8, base_name, "::")) |pos| {
                ns_parent = ctx.alloc.dupe(u8, base_name[0..pos]) catch null;
            }
            const insert_name: []const u8 = fq_name orelse base_name;
            const doc = extractDocComment(ctx.source, mn.base.location.start, ctx.alloc);
            defer if (doc) |d| ctx.alloc.free(d);
            const mod_pn: ?[]const u8 = if (ns_parent) |np| if (np.len > 0) np else null else null;
            const mod_sym_id = insertSymbolGetId(ctx, "module", insert_name, lc.line, lc.col, doc, @intCast(end_lc.line), "public", mod_pn) catch 0;
            addSemToken(ctx, lc.line, lc.col, @intCast(short_name.len), 1);
            const prev_class = ctx.current_class_id;
            const prev_vis = ctx.current_visibility;
            const prev_mf = ctx.module_function_mode;
            ctx.current_class_id = if (mod_sym_id > 0) mod_sym_id else null;
            ctx.current_visibility = "public";
            ctx.module_function_mode = false;
            const ns_pushed_mod = ctx.namespace_stack_len < 64;
            if (ns_pushed_mod) {
                ctx.namespace_stack[ctx.namespace_stack_len] = short_name;
                ctx.namespace_stack_len += 1;
            }
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            if (ns_pushed_mod and ctx.namespace_stack_len > 0) ctx.namespace_stack_len -= 1;
            ctx.current_class_id = prev_class;
            ctx.current_visibility = prev_vis;
            ctx.module_function_mode = prev_mf;
            return false;
        },
        prism.NODE_DEF => {
            const dn: *const prism.DefNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, dn.name_loc.start);
            const end_offset = dn.base.location.start + dn.base.location.length;
            const end_lc = locationLineCol(ctx.parser, end_offset);
            const name = resolveConstant(ctx.parser, dn.name);
            const doc = extractDocComment(ctx.source, dn.base.location.start, ctx.alloc);
            defer if (doc) |d| ctx.alloc.free(d);
            const is_singleton = dn.receiver != null or ctx.in_singleton;
            const is_test_method = !is_singleton and std.mem.startsWith(u8, name, "test_");
            const kind: []const u8 = if (is_singleton) "classdef" else if (is_test_method) "test" else if (ctx.module_function_mode) "classdef" else "def";
            const vis = if (is_singleton) "public" else if (ctx.module_function_mode) "public" else ctx.current_visibility;
            var def_pn_buf: [512]u8 = undefined;
            const def_pn_str = namespaceFromStack(ctx, &def_pn_buf);
            const def_pn: ?[]const u8 = if (def_pn_str.len > 0) def_pn_str else null;
            const sym_id = insertSymbolGetId(ctx, kind, name, lc.line, lc.col, doc, @intCast(end_lc.line), vis, def_pn) catch 0;
            // module_function: also insert private instance-side def
            if (ctx.module_function_mode and !is_singleton) {
                _ = insertSymbolGetId(ctx, "def", name, lc.line, lc.col, doc, @intCast(end_lc.line), "private", def_pn) catch 0;
            }
            addSemToken(ctx, lc.line, lc.col, @intCast(name.len), 2);
            if (sym_id > 0 and dn.parameters != null) {
                extractParams(ctx, sym_id, dn.parameters.?) catch {
                    ctx.error_count += 1;
                };
                // YARD @param annotations
                if (doc) |d| {
                    const params_node: *const prism.ParametersNode = @ptrCast(@alignCast(dn.parameters.?));
                    var position: u32 = 0;
                    for (0..params_node.requireds.size) |i| {
                        const pn = params_node.requireds.nodes[i];
                        if (pn.*.type == prism.NODE_REQUIRED_PARAM) {
                            const rp: *const prism.RequiredParamNode = @ptrCast(@alignCast(pn));
                            const pname = resolveConstant(ctx.parser, rp.name);
                            var yard_pbuf: [512]u8 = undefined;
                            const yard_type = parseYardParam(d, pname, &yard_pbuf);
                            const yard_desc = parseYardParamDesc(d, pname);
                            if (yard_type != null or yard_desc != null) {
                                if (ctx.db.prepare("UPDATE params SET type_hint=COALESCE(?,type_hint), description=COALESCE(?,description) WHERE symbol_id=? AND position=?")) |u| {
                                    defer u.finalize();
                                    if (yard_type) |yt| u.bind_text(1, yt) else u.bind_null(1);
                                    if (yard_desc) |yd| u.bind_text(2, yd) else u.bind_null(2);
                                    u.bind_int(3, sym_id);
                                    u.bind_int(4, @intCast(position));
                                    _ = u.step() catch {
                                        ctx.error_count += 1;
                                    };
                                } else |_| {}
                            }
                        }
                        position += 1;
                    }
                    for (0..params_node.optionals.size) |i| {
                        const pn = params_node.optionals.nodes[i];
                        if (pn.*.type == prism.NODE_OPTIONAL_PARAM) {
                            const op: *const prism.OptionalParamNode = @ptrCast(@alignCast(pn));
                            const pname = resolveConstant(ctx.parser, op.name);
                            var yard_pbuf2: [512]u8 = undefined;
                            const yard_type2 = parseYardParam(d, pname, &yard_pbuf2);
                            const yard_desc2 = parseYardParamDesc(d, pname);
                            if (yard_type2 != null or yard_desc2 != null) {
                                if (ctx.db.prepare("UPDATE params SET type_hint=COALESCE(?,type_hint), description=COALESCE(?,description) WHERE symbol_id=? AND position=?")) |u| {
                                    defer u.finalize();
                                    if (yard_type2) |yt| u.bind_text(1, yt) else u.bind_null(1);
                                    if (yard_desc2) |yd| u.bind_text(2, yd) else u.bind_null(2);
                                    u.bind_int(3, sym_id);
                                    u.bind_int(4, @intCast(position));
                                    _ = u.step() catch {
                                        ctx.error_count += 1;
                                    };
                                } else |_| {}
                            }
                        }
                        position += 1;
                    }
                }
            }
            // YARD annotations override inferred return type
            if (sym_id > 0) {
                if (doc) |d| {
                    var yard_rbuf: [512]u8 = undefined;
                    if (parseYardReturn(d, &yard_rbuf)) |yard_ret| {
                        if (ctx.db.prepare("UPDATE symbols SET return_type=? WHERE id=?")) |u| {
                            defer u.finalize();
                            u.bind_text(1, yard_ret);
                            u.bind_int(2, sym_id);
                            _ = u.step() catch {
                                ctx.error_count += 1;
                            };
                        } else |_| {}
                    }
                }
            }
            if (sym_id > 0 and dn.body != null) {
                const body = dn.body.?;
                if (body.*.type == prism.NODE_STATEMENTS) {
                    const stmts: *const prism.StatementsNode = @ptrCast(@alignCast(body));
                    if (stmts.body.size > 0) {
                        const last_node = stmts.body.nodes[stmts.body.size - 1];
                        if (inferLiteralType(last_node)) |rt| {
                            updateSymbolReturnType(ctx.db, sym_id, rt) catch {
                                ctx.error_count += 1;
                            };
                        } else if (extractNewCallType(ctx.parser, last_node)) |rt| {
                            updateSymbolReturnType(ctx.db, sym_id, rt) catch {
                                ctx.error_count += 1;
                            };
                        } else if (last_node.*.type == prism.NODE_CALL) blk: {
                            const db_call: *const prism.CallNode = @ptrCast(@alignCast(last_node));
                            const db_mname = resolveConstant(ctx.parser, db_call.name);
                            if (db_call.receiver) |recv| {
                                if (inferReceiverType(ctx, recv)) |recv_type| {
                                    if (lookupMethodReturn(ctx.db, recv_type, db_mname)) |rt| {
                                        updateSymbolReturnType(ctx.db, sym_id, rt) catch {
                                            ctx.error_count += 1;
                                        };
                                        break :blk;
                                    }
                                }
                            }
                        } else if (last_node.*.type == prism.NODE_RETURN) {
                            const rn: *const prism.ReturnNode = @ptrCast(@alignCast(last_node));
                            if (rn.arguments != null) {
                                const rargs = rn.arguments[0].arguments;
                                if (rargs.size > 0) {
                                    if (extractNewCallType(ctx.parser, rargs.nodes[0])) |rt| {
                                        updateSymbolReturnType(ctx.db, sym_id, rt) catch {
                                            ctx.error_count += 1;
                                        };
                                    }
                                }
                            }
                        }
                    }
                } else {
                    // Endless method: def foo = expr — body is the expression directly
                    if (inferLiteralType(body)) |rt| {
                        updateSymbolReturnType(ctx.db, sym_id, rt) catch {
                            ctx.error_count += 1;
                        };
                    } else if (extractNewCallType(ctx.parser, body)) |rt| {
                        updateSymbolReturnType(ctx.db, sym_id, rt) catch {
                            ctx.error_count += 1;
                        };
                    } else if (body.*.type == prism.NODE_CALL) {
                        const bc: *const prism.CallNode = @ptrCast(@alignCast(body));
                        const bm = resolveConstant(ctx.parser, bc.name);
                        if (bc.receiver) |recv| {
                            if (inferReceiverType(ctx, recv)) |recv_type| {
                                if (lookupMethodReturn(ctx.db, recv_type, bm)) |rt| {
                                    updateSymbolReturnType(ctx.db, sym_id, rt) catch {
                                        ctx.error_count += 1;
                                    };
                                }
                            }
                        }
                    }
                }
            }
            // Sorbet sig { params(...).returns(Type) } — authoritative, overrides body inference
            if (sym_id > 0 and dn.base.location.start > 0) {
                const def_start = dn.base.location.start;
                const scan_start = if (def_start > 2000) def_start - 2000 else 0;
                const scan_slice = ctx.source[scan_start..def_start];
                if (findLastSorbetSig(scan_slice)) |sig_body| {
                    if (findCallArgs(sig_body, "returns")) |rt_raw| {
                        const rt = std.mem.trim(u8, rt_raw, " \t\n\r");
                        var rt_buf: [128]u8 = undefined;
                        var final_rt: []const u8 = rt;
                        if (std.mem.startsWith(u8, rt, "T.nilable(") and std.mem.endsWith(u8, rt, ")")) {
                            const inner = std.mem.trim(u8, rt[10 .. rt.len - 1], " \t");
                            if (std.fmt.bufPrint(&rt_buf, "{s} | nil", .{inner})) |b| {
                                final_rt = b;
                            } else |_| {}
                        }
                        if (final_rt.len > 0 and final_rt.len < 128) {
                            updateSymbolReturnType(ctx.db, sym_id, final_rt) catch {
                                ctx.error_count += 1;
                            };
                        }
                    }
                    if (findCallArgs(sig_body, "params")) |params_body| {
                        parseSorbetParams(ctx.db, sym_id, params_body);
                    }
                }
            }
            const prev_scope = ctx.scope_id;
            ctx.scope_id = if (sym_id > 0) sym_id else null;
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            ctx.scope_id = prev_scope;
            return false;
        },
        prism.NODE_CONSTANT_WRITE => {
            const cn: *const prism.ConstWriteNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, cn.base.location.start);
            const name = resolveConstant(ctx.parser, cn.name);
            var cw_pn_buf: [512]u8 = undefined;
            const cw_pn_str = namespaceFromStack(ctx, &cw_pn_buf);
            const cw_pn: ?[]const u8 = if (cw_pn_str.len > 0) cw_pn_str else null;
            const sym_id = insertSymbolGetId(ctx, "constant", name, lc.line, lc.col, null, null, "public", cw_pn) catch 0;
            addSemToken(ctx, lc.line, lc.col, @intCast(name.len), 5);
            // Store value_snippet for literal and compound constants
            if (sym_id > 0) {
                const val = cn.value;
                const is_literal = switch (val.*.type) {
                    prism.NODE_INTEGER, prism.NODE_FLOAT, prism.NODE_STRING, prism.NODE_SYMBOL, prism.NODE_TRUE, prism.NODE_FALSE, prism.NODE_NIL, prism.NODE_ARRAY, prism.NODE_HASH, prism.NODE_RANGE => true,
                    else => false,
                };
                if (is_literal) {
                    const vstart = val.*.location.start;
                    const full_len = val.*.location.length;
                    const vlen = @min(full_len, 120);
                    if (@as(usize, vstart) + vlen <= ctx.source.len) {
                        var snip_buf: [123]u8 = undefined;
                        @memcpy(snip_buf[0..vlen], ctx.source[@as(usize, vstart) .. @as(usize, vstart) + vlen]);
                        const snip_end = if (full_len > 120) blk: {
                            @memcpy(snip_buf[vlen .. vlen + 3], "\u{2026}");
                            break :blk vlen + 3;
                        } else vlen;
                        const snippet = snip_buf[0..snip_end];
                        if (ctx.db.prepare("UPDATE symbols SET value_snippet=? WHERE id=?")) |upd| {
                            defer upd.finalize();
                            upd.bind_text(1, snippet);
                            upd.bind_int(2, sym_id);
                            _ = upd.step() catch {
                                ctx.error_count += 1;
                            };
                        } else |_| {}
                    }
                }
            }
            if (cn.value.*.type == prism.NODE_CALL) {
                const call: *const prism.CallNode = @ptrCast(@alignCast(cn.value));
                const mname = resolveConstant(ctx.parser, call.name);
                const is_struct_new = (call.receiver != null and
                    call.receiver.?.*.type == prism.NODE_CONSTANT and
                    std.mem.eql(u8, mname, "new"));
                const is_data_define = (call.receiver != null and
                    call.receiver.?.*.type == prism.NODE_CONSTANT and
                    std.mem.eql(u8, mname, "define"));
                var receiver_name: []const u8 = "";
                if (is_struct_new or is_data_define) {
                    const recv_const: *const prism.ConstReadNode = @ptrCast(@alignCast(call.receiver.?));
                    receiver_name = resolveConstant(ctx.parser, recv_const.name);
                }
                if ((is_struct_new and std.mem.eql(u8, receiver_name, "Struct")) or
                    (is_data_define and std.mem.eql(u8, receiver_name, "Data")))
                {
                    // Upgrade kind to 'class' so dot-completion query finds members
                    if (sym_id > 0) {
                        if (ctx.db.prepare("UPDATE symbols SET kind='class' WHERE id=?")) |upd| {
                            defer upd.finalize();
                            upd.bind_int(1, sym_id);
                            _ = upd.step() catch {
                                ctx.error_count += 1;
                            };
                        } else |_| {}
                    }
                    if (call.arguments != null) {
                        const args = call.arguments[0].arguments;
                        for (0..args.size) |ai| {
                            const arg = args.nodes[ai];
                            if (arg.*.type == prism.NODE_SYMBOL) {
                                const sym: *const prism.SymbolNode = @ptrCast(@alignCast(arg));
                                if (sym.unescaped.source) |src| {
                                    const sym_name = src[0..sym.unescaped.length];
                                    const alc = locationLineCol(ctx.parser, arg.*.location.start);
                                    insertSymbol(ctx, "def", sym_name, alc.line, alc.col, null) catch {
                                        ctx.error_count += 1;
                                    };
                                    if (is_struct_new) {
                                        const writer_name = ctx.alloc.alloc(u8, sym_name.len + 1) catch continue;
                                        defer ctx.alloc.free(writer_name);
                                        @memcpy(writer_name[0..sym_name.len], sym_name);
                                        writer_name[sym_name.len] = '=';
                                        insertSymbol(ctx, "def", writer_name, alc.line, alc.col, null) catch {
                                            ctx.error_count += 1;
                                        };
                                    }
                                }
                            }
                        }
                    }
                }
            }
        },
        prism.NODE_CONSTANT_OR_WRITE, prism.NODE_CONSTANT_AND_WRITE => {
            const cow: *const prism.ConstantOrWriteNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, cow.name_loc.start);
            const name = resolveConstant(ctx.parser, cow.name);
            var cw_pn_buf: [512]u8 = undefined;
            const cw_pn_str = namespaceFromStack(ctx, &cw_pn_buf);
            const cw_pn: ?[]const u8 = if (cw_pn_str.len > 0) cw_pn_str else null;
            _ = insertSymbolGetId(ctx, "constant", name, lc.line, lc.col, null, null, "public", cw_pn) catch 0;
            addSemToken(ctx, lc.line, lc.col, @intCast(name.len), 5);
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        prism.NODE_CONSTANT => {
            const rn: *const prism.ConstReadNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, rn.base.location.start);
            const name = resolveConstant(ctx.parser, rn.name);
            insertRef(ctx.db, ctx.file_id, name, lc.line, lc.col, null) catch {
                ctx.error_count += 1;
            };
            addSemToken(ctx, lc.line, lc.col, @intCast(name.len), 5);
        },
        prism.NODE_CALL => {
            const cn: *const prism.CallNode = @ptrCast(@alignCast(n));
            const mname = resolveConstant(ctx.parser, cn.name);
            if (cn.receiver == null and std.mem.eql(u8, mname, "rescue_from")) {
                insertRescueFromHandler(ctx, cn) catch {
                    ctx.error_count += 1;
                };
            }
            if (cn.receiver == null and isAttrMethod(mname)) {
                insertAttrSymbols(ctx, cn, mname) catch {
                    ctx.error_count += 1;
                };
            }
            if (cn.receiver == null and std.mem.eql(u8, mname, "enum")) {
                insertEnumSymbols(ctx, cn) catch {
                    ctx.error_count += 1;
                };
            } else if (cn.receiver == null and (std.mem.eql(u8, mname, "has_one_attached") or std.mem.eql(u8, mname, "has_many_attached"))) {
                insertAttachedSymbols(ctx, cn, mname) catch {
                    ctx.error_count += 1;
                };
            } else if (cn.receiver == null and std.mem.eql(u8, mname, "has_rich_text")) {
                insertRichTextSymbols(ctx, cn) catch {
                    ctx.error_count += 1;
                };
            } else if (cn.receiver == null and std.mem.eql(u8, mname, "has_secure_password")) {
                insertSecurePasswordSymbols(ctx, cn) catch {
                    ctx.error_count += 1;
                };
            } else if (cn.receiver == null and std.mem.eql(u8, mname, "has_secure_token")) {
                insertSecureTokenSymbols(ctx, cn) catch {
                    ctx.error_count += 1;
                };
            } else if (cn.receiver == null and std.mem.eql(u8, mname, "attribute")) {
                insertAttributeSymbol(ctx, cn) catch {
                    ctx.error_count += 1;
                };
            } else if (cn.receiver == null and std.mem.eql(u8, mname, "store_accessor")) {
                insertStoreAccessorSymbols(ctx, cn) catch {
                    ctx.error_count += 1;
                };
            } else if (cn.receiver == null and std.mem.eql(u8, mname, "delegated_type")) {
                insertDelegatedTypeSymbols(ctx, cn) catch {
                    ctx.error_count += 1;
                };
            } else if (cn.receiver == null and std.mem.eql(u8, mname, "composed_of")) {
                insertComposedOfSymbols(ctx, cn) catch {
                    ctx.error_count += 1;
                };
            } else if (cn.receiver == null and std.mem.eql(u8, mname, "accepts_nested_attributes_for")) {
                insertNestedAttributesSymbols(ctx, cn) catch {
                    ctx.error_count += 1;
                };
            } else if (cn.receiver == null and isRailsDsl(mname)) {
                insertRailsDslSymbols(ctx, cn, mname) catch {
                    ctx.error_count += 1;
                };
            }
            if (cn.receiver == null and std.mem.eql(u8, mname, "alias_method")) {
                if (cn.arguments != null) {
                    const args = cn.arguments[0].arguments;
                    if (args.size >= 1) {
                        const first = args.nodes[0];
                        if (first.*.type == prism.NODE_SYMBOL) {
                            const sym: *const prism.SymbolNode = @ptrCast(@alignCast(first));
                            if (sym.unescaped.source) |src| {
                                const lc = locationLineCol(ctx.parser, first.*.location.start);
                                insertSymbol(ctx, "def", src[0..sym.unescaped.length], lc.line, lc.col, null) catch {
                                    ctx.error_count += 1;
                                };
                            }
                        }
                    }
                    if (args.size >= 2) {
                        const second = args.nodes[1];
                        if (second.*.type == prism.NODE_SYMBOL) {
                            const sym2: *const prism.SymbolNode = @ptrCast(@alignCast(second));
                            if (sym2.unescaped.source) |src2| {
                                const lc2 = locationLineCol(ctx.parser, second.*.location.start);
                                insertRef(ctx.db, ctx.file_id, src2[0..sym2.unescaped.length], lc2.line, lc2.col, null) catch {
                                    ctx.error_count += 1;
                                };
                            }
                        } else if (second.*.type == prism.NODE_STRING) {
                            const sn2: *const prism.StringNode = @ptrCast(@alignCast(second));
                            if (sn2.unescaped.source) |src2| {
                                const lc2 = locationLineCol(ctx.parser, second.*.location.start);
                                insertRef(ctx.db, ctx.file_id, src2[0..sn2.unescaped.length], lc2.line, lc2.col, null) catch {
                                    ctx.error_count += 1;
                                };
                            }
                        }
                    }
                }
            }
            if (cn.receiver == null and std.mem.eql(u8, mname, "define_method")) {
                if (cn.arguments != null) {
                    const args = cn.arguments[0].arguments;
                    if (args.size > 0 and args.nodes[0].*.type == prism.NODE_SYMBOL) {
                        const sym: *const prism.SymbolNode = @ptrCast(@alignCast(args.nodes[0]));
                        if (sym.unescaped.source) |src| {
                            const lc = locationLineCol(ctx.parser, args.nodes[0].*.location.start);
                            insertSymbol(ctx, "def", src[0..sym.unescaped.length], lc.line, lc.col, null) catch {
                                ctx.error_count += 1;
                            };
                        }
                    } else if (args.size > 0 and args.nodes[0].*.type == prism.NODE_STRING) {
                        const sn: *const prism.StringNode = @ptrCast(@alignCast(args.nodes[0]));
                        if (sn.unescaped.source) |src| {
                            const lc = locationLineCol(ctx.parser, args.nodes[0].*.location.start);
                            insertSymbol(ctx, "def", src[0..sn.unescaped.length], lc.line, lc.col, null) catch {
                                ctx.error_count += 1;
                            };
                        }
                    }
                }
            }
            if (cn.receiver == null and std.mem.eql(u8, mname, "define_singleton_method")) {
                if (cn.arguments != null) {
                    const args = cn.arguments[0].arguments;
                    if (args.size > 0 and args.nodes[0].*.type == prism.NODE_SYMBOL) {
                        const sym: *const prism.SymbolNode = @ptrCast(@alignCast(args.nodes[0]));
                        if (sym.unescaped.source) |src| {
                            const lc = locationLineCol(ctx.parser, args.nodes[0].*.location.start);
                            insertSymbol(ctx, "classdef", src[0..sym.unescaped.length], lc.line, lc.col, null) catch {
                                ctx.error_count += 1;
                            };
                        }
                    } else if (args.size > 0 and args.nodes[0].*.type == prism.NODE_STRING) {
                        const sn: *const prism.StringNode = @ptrCast(@alignCast(args.nodes[0]));
                        if (sn.unescaped.source) |src| {
                            const lc = locationLineCol(ctx.parser, args.nodes[0].*.location.start);
                            insertSymbol(ctx, "classdef", src[0..sn.unescaped.length], lc.line, lc.col, null) catch {
                                ctx.error_count += 1;
                            };
                        }
                    }
                }
            }
            if (cn.receiver == null and std.mem.eql(u8, mname, "module_function")) {
                if (cn.arguments != null) {
                    const args = cn.arguments[0].arguments;
                    for (0..args.size) |ai| {
                        const arg = args.nodes[ai];
                        if (arg.*.type == prism.NODE_SYMBOL) {
                            const sym: *const prism.SymbolNode = @ptrCast(@alignCast(arg));
                            if (sym.unescaped.source) |src| {
                                const lc = locationLineCol(ctx.parser, arg.*.location.start);
                                insertSymbol(ctx, "classdef", src[0..sym.unescaped.length], lc.line, lc.col, null) catch {
                                    ctx.error_count += 1;
                                };
                                // Also mark the existing instance def as private
                                if (ctx.db.prepare("UPDATE symbols SET visibility='private' WHERE file_id=? AND name=? AND kind='def'")) |u| {
                                    defer u.finalize();
                                    u.bind_int(1, ctx.file_id);
                                    u.bind_text(2, src[0..sym.unescaped.length]);
                                    _ = u.step() catch {
                                        ctx.error_count += 1;
                                    };
                                } else |_| {}
                            }
                        }
                    }
                } else {
                    // bare module_function — enable mode for subsequent defs
                    ctx.module_function_mode = true;
                }
            }
            // ActiveSupport::Concern: class_methods do ... end — promote inner defs to classdef
            if (cn.receiver == null and std.mem.eql(u8, mname, "class_methods") and cn.block != null) {
                const prev_mf = ctx.module_function_mode;
                const prev_vis = ctx.current_visibility;
                ctx.module_function_mode = true;
                ctx.current_visibility = "public";
                prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
                ctx.module_function_mode = prev_mf;
                ctx.current_visibility = prev_vis;
                return false;
            }
            // private_class_method / public_class_method visibility (Phase 29)
            if (cn.receiver == null and
                (std.mem.eql(u8, mname, "private_class_method") or
                    std.mem.eql(u8, mname, "public_class_method")))
            {
                const new_vis: []const u8 = if (mname[1] == 'r') "private" else "public";
                if (cn.arguments != null) {
                    const pcm_args = cn.arguments[0].arguments;
                    for (0..pcm_args.size) |pcm_i| {
                        const pcm_arg = pcm_args.nodes[pcm_i];
                        if (pcm_arg.*.type != prism.NODE_SYMBOL) continue;
                        const pcm_sym: *const prism.SymbolNode = @ptrCast(@alignCast(pcm_arg));
                        if (pcm_sym.unescaped.source) |src| {
                            const method_name = src[0..pcm_sym.unescaped.length];
                            if (ctx.db.prepare("UPDATE symbols SET visibility=? WHERE file_id=? AND name=? AND kind IN ('def','classdef')")) |upd| {
                                defer upd.finalize();
                                upd.bind_text(1, new_vis);
                                upd.bind_int(2, ctx.file_id);
                                upd.bind_text(3, method_name);
                                _ = upd.step() catch {
                                    ctx.error_count += 1;
                                };
                            } else |_| {}
                        }
                    }
                }
            }
            // Track include/prepend/extend for mixin resolution
            if (cn.receiver == null and ctx.current_class_id != null and
                (std.mem.eql(u8, mname, "include") or std.mem.eql(u8, mname, "prepend") or std.mem.eql(u8, mname, "extend")))
            {
                if (cn.arguments != null) {
                    const args_list = cn.arguments[0].arguments;
                    for (0..args_list.size) |ai| {
                        const arg = args_list.nodes[ai];
                        if (arg.*.type == prism.NODE_CONSTANT) {
                            const mod_node: *const prism.ConstReadNode = @ptrCast(@alignCast(arg));
                            const mod_name = resolveConstant(ctx.parser, mod_node.name);
                            insertMixin(ctx.db, ctx.current_class_id.?, mod_name, mname) catch {
                                ctx.error_count += 1;
                            };
                        } else if (arg.*.type == prism.NODE_CONSTANT_PATH) {
                            const mod_owned = buildQualifiedName(ctx.parser, arg, ctx.alloc) catch null;
                            defer if (mod_owned) |m| ctx.alloc.free(m);
                            const mod_name: []const u8 = mod_owned orelse blk: {
                                const cp: *const prism.ConstantPathNode = @ptrCast(@alignCast(arg));
                                break :blk if (cp.name != 0) resolveConstant(ctx.parser, cp.name) else "";
                            };
                            if (mod_name.len > 0) insertMixin(ctx.db, ctx.current_class_id.?, mod_name, mname) catch {
                                ctx.error_count += 1;
                            };
                        }
                    }
                }
            }
            // Visibility setter detection: private/protected/public (no receiver)
            if (cn.receiver == null) {
                const is_priv = std.mem.eql(u8, mname, "private");
                const is_prot = std.mem.eql(u8, mname, "protected");
                const is_pub = std.mem.eql(u8, mname, "public");
                if (is_priv or is_prot or is_pub) {
                    const new_vis: []const u8 = if (is_priv) "private" else if (is_prot) "protected" else "public";
                    // Inline form: `private def foo` — argument is a single def node
                    const is_inline = blk: {
                        if (cn.arguments) |args| {
                            if (args.*.arguments.size == 1 and
                                args.*.arguments.nodes[0].*.type == prism.NODE_DEF)
                                break :blk true;
                        }
                        break :blk false;
                    };
                    if (is_inline) {
                        // Scoped: only the one def gets this visibility; restore afterwards
                        const prev_vis = ctx.current_visibility;
                        const prev_mf = ctx.module_function_mode;
                        ctx.current_visibility = new_vis;
                        ctx.module_function_mode = false;
                        prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
                        ctx.current_visibility = prev_vis;
                        ctx.module_function_mode = prev_mf;
                        return false;
                    } else {
                        ctx.current_visibility = new_vis;
                        ctx.module_function_mode = false;
                    }
                }
            }
            // Rails delegate synthesis
            if (cn.receiver == null and std.mem.eql(u8, mname, "delegate")) {
                if (cn.arguments) |args_node| {
                    const del_args = args_node.*.arguments;
                    for (0..del_args.size) |di| {
                        const arg = del_args.nodes[di];
                        if (arg.*.type == prism.NODE_KEYWORD_HASH) continue;
                        if (arg.*.type != prism.NODE_SYMBOL) continue;
                        const sn: *const prism.SymbolNode = @ptrCast(@alignCast(arg));
                        if (sn.unescaped.source == null) continue;
                        const dname = sn.unescaped.source[0..sn.unescaped.length];
                        const dlc = locationLineCol(ctx.parser, arg.*.location.start);
                        insertSymbol(ctx, "def", dname, dlc.line, dlc.col, null) catch {
                            ctx.error_count += 1;
                        };
                    }
                }
            }
            // Forwardable def_delegator / def_delegators synthesis
            if (cn.receiver == null and
                (std.mem.eql(u8, mname, "def_delegator") or
                    std.mem.eql(u8, mname, "def_delegators")))
            {
                if (cn.arguments) |args_node| {
                    const fwd_args = args_node.*.arguments;
                    var fj: usize = 1; // skip first arg (the delegate target, e.g. :@engine)
                    while (fj < fwd_args.size) : (fj += 1) {
                        const arg = fwd_args.nodes[fj];
                        if (arg.*.type != prism.NODE_SYMBOL) continue;
                        const sn: *const prism.SymbolNode = @ptrCast(@alignCast(arg));
                        if (sn.unescaped.source == null) continue;
                        const dname = sn.unescaped.source[0..sn.unescaped.length];
                        const dlc = locationLineCol(ctx.parser, arg.*.location.start);
                        insertSymbol(ctx, "def", dname, dlc.line, dlc.col, null) catch {
                            ctx.error_count += 1;
                        };
                    }
                }
            }
            // Block param inference for iteration methods
            const accum_t: ?[]const u8 = if (std.mem.eql(u8, mname, "each_with_object") and cn.arguments != null) blk_acc: {
                const ewo_args = cn.arguments[0].arguments;
                if (ewo_args.size > 0) break :blk_acc inferLiteralType(ewo_args.nodes[0]);
                break :blk_acc null;
            } else null;
            if (cn.block != null and isIterationMethod(mname)) {
                if (cn.receiver) |recv| {
                    if (recv.*.type == prism.NODE_LOCAL_VAR_READ) {
                        const rv: *const prism.LocalVarReadNode = @ptrCast(@alignCast(recv));
                        const rv_name = resolveConstant(ctx.parser, rv.name);
                        var db_hit = false;
                        if (ctx.db.prepare("SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1")) |lv_stmt| {
                            defer lv_stmt.finalize();
                            lv_stmt.bind_int(1, ctx.file_id);
                            lv_stmt.bind_text(2, rv_name);
                            if (lv_stmt.step() catch false) {
                                const t = lv_stmt.column_text(0);
                                if (t.len > 0) {
                                    db_hit = true;
                                    const elem = stripArrayBrackets(t);
                                    if (elem) |e| {
                                        if (cn.block.?.*.type == prism.NODE_BLOCK) {
                                            const block_node: *const prism.BlockNode = @ptrCast(@alignCast(cn.block.?));
                                            insertBlockParams(ctx, block_node, e, mname, accum_t) catch {
                                                ctx.error_count += 1;
                                            };
                                        }
                                    }
                                }
                            }
                        } else |_| {}
                        if (!db_hit and rv_name.len > 3 and rv_name[rv_name.len - 1] == 's') {
                            const base = rv_name[0 .. rv_name.len - 1];
                            const buf = ctx.alloc.alloc(u8, base.len) catch null;
                            if (buf) |b| {
                                defer ctx.alloc.free(b);
                                @memcpy(b, base);
                                b[0] = std.ascii.toUpper(b[0]);
                                const block_generic = cn.block.?;
                                if (block_generic.*.type == prism.NODE_BLOCK) {
                                    const block_node: *const prism.BlockNode = @ptrCast(@alignCast(block_generic));
                                    insertBlockParams(ctx, block_node, b, mname, accum_t) catch {
                                        ctx.error_count += 1;
                                    };
                                }
                            }
                        }
                    } else if (recv.*.type == prism.NODE_INSTANCE_VAR_READ) {
                        const rv: *const prism.InstanceVarReadNode = @ptrCast(@alignCast(recv));
                        const rv_name = resolveConstant(ctx.parser, rv.name);
                        if (ctx.db.prepare("SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1")) |lv| {
                            defer lv.finalize();
                            lv.bind_int(1, ctx.file_id);
                            lv.bind_text(2, rv_name);
                            if (lv.step() catch false) {
                                const ivar_type = lv.column_text(0);
                                if (ivar_type.len > 0 and cn.block.?.*.type == prism.NODE_BLOCK) {
                                    const block_node: *const prism.BlockNode = @ptrCast(@alignCast(cn.block.?));
                                    insertBlockParams(ctx, block_node, ivar_type, mname, accum_t) catch {
                                        ctx.error_count += 1;
                                    };
                                }
                            }
                        } else |_| {}
                    } else if (recv.*.type == prism.NODE_CALL) {
                        const outer_call: *const prism.CallNode = @ptrCast(@alignCast(recv));
                        if (outer_call.receiver) |outer_recv| {
                            if (outer_recv.*.type == prism.NODE_CONSTANT) {
                                const rc: *const prism.ConstReadNode = @ptrCast(@alignCast(outer_recv));
                                const class_name = resolveConstant(ctx.parser, rc.name);
                                if (cn.block.?.*.type == prism.NODE_BLOCK) {
                                    const block_node: *const prism.BlockNode = @ptrCast(@alignCast(cn.block.?));
                                    insertBlockParams(ctx, block_node, class_name, mname, accum_t) catch {
                                        ctx.error_count += 1;
                                    };
                                }
                            }
                        }
                    } else if (inferLiteralType(recv)) |lit_type| {
                        if (cn.block.?.*.type == prism.NODE_BLOCK) {
                            const block_node: *const prism.BlockNode = @ptrCast(@alignCast(cn.block.?));
                            insertBlockParams(ctx, block_node, lit_type, mname, accum_t) catch {
                                ctx.error_count += 1;
                            };
                        }
                    }
                }
            }
            // Numbered parameter binding: _1, _2, _3 for blocks without explicit params (Phase 29)
            if (cn.block != null and cn.block.?.*.type == prism.NODE_BLOCK) {
                const nb: *const prism.BlockNode = @ptrCast(@alignCast(cn.block.?));
                const has_numbered = nb.parameters != null and nb.parameters.?.*.type == prism.NODE_NUMBERED_PARAMETERS;
                if (nb.parameters == null or has_numbered) {
                    var elem_type_np_buf: [256]u8 = undefined;
                    var elem_type_np: []const u8 = "";
                    if (cn.receiver) |recv_np| {
                        if (recv_np.*.type == prism.NODE_LOCAL_VAR_READ) {
                            const rv_np: *const prism.LocalVarReadNode = @ptrCast(@alignCast(recv_np));
                            const rv_name_np = resolveConstant(ctx.parser, rv_np.name);
                            if (ctx.db.prepare("SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1")) |np_stmt| {
                                defer np_stmt.finalize();
                                np_stmt.bind_int(1, ctx.file_id);
                                np_stmt.bind_text(2, rv_name_np);
                                if (np_stmt.step() catch false) {
                                    const th = np_stmt.column_text(0);
                                    if (stripArrayBrackets(th)) |e| {
                                        const copy_len = @min(e.len, elem_type_np_buf.len);
                                        @memcpy(elem_type_np_buf[0..copy_len], e[0..copy_len]);
                                        elem_type_np = elem_type_np_buf[0..copy_len];
                                    }
                                }
                            } else |_| {}
                        } else if (inferLiteralType(recv_np)) |lit| {
                            elem_type_np = lit;
                        }
                    }
                    if (elem_type_np.len > 0) {
                        const nb_lc = locationLineCol(ctx.parser, nb.base.location.start);
                        var ni: u8 = 1;
                        while (ni <= 3) : (ni += 1) {
                            var nbuf: [4]u8 = undefined;
                            const nname = std.fmt.bufPrint(&nbuf, "_{d}", .{ni}) catch break;
                            const np_type: ?[]const u8 = if (ni == 1) elem_type_np else null;
                            insertLocalVar(ctx.db, ctx.file_id, nname, nb_lc.line, nb_lc.col, np_type, 50, ctx.scope_id) catch {
                                ctx.error_count += 1;
                            };
                        }
                    }
                }
            }
            // ActiveSupport::Concern `included do...end` — traverse block body with current namespace
            if (cn.receiver == null and std.mem.eql(u8, mname, "included")) {
                if (cn.block != null and cn.block.?.*.type == prism.NODE_BLOCK) {
                    const inc_blk: *const prism.BlockNode = @ptrCast(@alignCast(cn.block.?));
                    if (inc_blk.body != null) {
                        prism.visit_child_nodes(inc_blk.body.?, visitor, @ptrCast(ctx));
                    }
                }
            }
            // schema.rb / migrations: `create_table "users" do |t| ... end`
            if ((std.mem.eql(u8, mname, "create_table") or std.mem.eql(u8, mname, "change_table")) and
                cn.block != null and cn.block.?.*.type == prism.NODE_BLOCK)
            {
                const tbl_blk: *const prism.BlockNode = @ptrCast(@alignCast(cn.block.?));
                if (tbl_blk.body != null) {
                    var table_raw: ?[]const u8 = null;
                    if (cn.arguments != null) {
                        const args_list_t = cn.arguments[0].arguments;
                        if (args_list_t.size > 0) {
                            const first_arg = args_list_t.nodes[0];
                            if (first_arg.*.type == prism.NODE_STRING) {
                                const sn_t: *const prism.StringNode = @ptrCast(@alignCast(first_arg));
                                if (sn_t.unescaped.source != null)
                                    table_raw = sn_t.unescaped.source[0..sn_t.unescaped.length];
                            } else if (first_arg.*.type == prism.NODE_SYMBOL) {
                                const sym_t: *const prism.SymbolNode = @ptrCast(@alignCast(first_arg));
                                if (sym_t.unescaped.source != null)
                                    table_raw = sym_t.unescaped.source[0..sym_t.unescaped.length];
                            }
                        }
                    }
                    if (table_raw) |traw| {
                        const model_name = tableNameToModel(traw, &ctx.schema_table_buf);
                        if (model_name != null) {
                            ctx.schema_table = model_name;
                            prism.visit_child_nodes(tbl_blk.body.?, visitor, @ptrCast(ctx));
                            ctx.schema_table = null;
                        }
                    }
                }
            }
            // schema.rb column: `t.string :email` inside a create_table block
            if (ctx.schema_table) |model_name| {
                if (cn.receiver != null and cn.receiver.?.*.type == prism.NODE_LOCAL_VAR_READ) {
                    if (schemaColumnType(mname)) |ruby_type| {
                        var col_name: ?[]const u8 = null;
                        if (cn.arguments != null) {
                            const col_args_list = cn.arguments[0].arguments;
                            if (col_args_list.size > 0) {
                                const col_arg = col_args_list.nodes[0];
                                if (col_arg.*.type == prism.NODE_SYMBOL) {
                                    const csym: *const prism.SymbolNode = @ptrCast(@alignCast(col_arg));
                                    if (csym.unescaped.source != null)
                                        col_name = csym.unescaped.source[0..csym.unescaped.length];
                                } else if (col_arg.*.type == prism.NODE_STRING) {
                                    const csv: *const prism.StringNode = @ptrCast(@alignCast(col_arg));
                                    if (csv.unescaped.source != null)
                                        col_name = csv.unescaped.source[0..csv.unescaped.length];
                                }
                            }
                        }
                        if (col_name) |cname| {
                            const lc_col = locationLineCol(ctx.parser, cn.message_loc.start);
                            insertSymbolWithReturn(ctx, "def", cname, lc_col.line, lc_col.col, ruby_type, "column", model_name, null) catch {
                                ctx.error_count += 1;
                            };
                            // For references/belongs_to, also insert the _id column
                            if (std.mem.eql(u8, mname, "references") or std.mem.eql(u8, mname, "belongs_to")) {
                                var id_buf: [128]u8 = undefined;
                                const id_name = std.fmt.bufPrint(&id_buf, "{s}_id", .{cname}) catch null;
                                if (id_name) |iname| {
                                    insertSymbolWithReturn(ctx, "def", iname, lc_col.line, lc_col.col, "Integer", "column", model_name, null) catch {
                                        ctx.error_count += 1;
                                    };
                                }
                            }
                        }
                    }
                }
            }
            const lc = locationLineCol(ctx.parser, cn.message_loc.start);
            // Compute arg_count and receiver_type at the call site for the type checker.
            const call_arg_count: i64 = if (cn.arguments != null) @intCast(cn.arguments[0].arguments.size) else 0;
            var rcv_buf: [128]u8 = undefined;
            const call_recv_type: ?[]const u8 = blk: {
                if (cn.receiver) |rcv| {
                    if (rcv.*.type == prism.NODE_LOCAL_VAR_READ) {
                        const lvr: *const prism.LocalVarReadNode = @ptrCast(@alignCast(rcv));
                        const rname = resolveConstant(ctx.parser, lvr.name);
                        // Pull the most-recent typed binding. Accept confidence >= 70 (RBS/sigs/narrowing)
                        // OR exactly 'NilClass' regardless of confidence — `x = nil` is unambiguous.
                        const lookup = ctx.db.prepare(
                            "SELECT type_hint, confidence FROM local_vars WHERE file_id=? AND name=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1",
                        ) catch break :blk null;
                        defer lookup.finalize();
                        lookup.bind_int(1, ctx.file_id);
                        lookup.bind_text(2, rname);
                        if (lookup.step() catch false) {
                            const txt = lookup.column_text(0);
                            // Accept any non-empty type_hint. The downstream checker queries
                            // gate by exact-symbol-match (arity) and explicit-NilClass (nil-receiver),
                            // so low-confidence types simply yield no diagnostic.
                            if (txt.len > 0 and txt.len < rcv_buf.len) {
                                @memcpy(rcv_buf[0..txt.len], txt);
                                break :blk rcv_buf[0..txt.len];
                            }
                        }
                        break :blk null;
                    } else if (rcv.*.type == prism.NODE_CONSTANT) {
                        const cr: *const prism.ConstReadNode = @ptrCast(@alignCast(rcv));
                        const cname = resolveConstant(ctx.parser, cr.name);
                        if (cname.len > 0 and cname.len < rcv_buf.len) {
                            @memcpy(rcv_buf[0..cname.len], cname);
                            break :blk rcv_buf[0..cname.len];
                        }
                        break :blk null;
                    }
                }
                break :blk null;
            };
            insertCallRef(ctx.db, ctx.file_id, mname, lc.line, lc.col, ctx.scope_id, call_arg_count, call_recv_type) catch {
                ctx.error_count += 1;
            };
        },
        prism.NODE_ALIAS_METHOD => {
            const an: *const prism.AliasMethodNode = @ptrCast(@alignCast(n));
            if (an.new_name.*.type == prism.NODE_SYMBOL) {
                const nsym: *const prism.SymbolNode = @ptrCast(@alignCast(an.new_name));
                if (nsym.unescaped.source) |src| {
                    const lc = locationLineCol(ctx.parser, an.new_name.*.location.start);
                    insertSymbol(ctx, "def", src[0..nsym.unescaped.length], lc.line, lc.col, null) catch {
                        ctx.error_count += 1;
                    };
                }
            }
            if (an.old_name.*.type == prism.NODE_SYMBOL) {
                const osym: *const prism.SymbolNode = @ptrCast(@alignCast(an.old_name));
                if (osym.unescaped.source) |src| {
                    const lc = locationLineCol(ctx.parser, an.old_name.*.location.start);
                    insertRef(ctx.db, ctx.file_id, src[0..osym.unescaped.length], lc.line, lc.col, null) catch {
                        ctx.error_count += 1;
                    };
                }
            }
        },
        prism.NODE_SINGLETON_CLASS => {
            const sn: *const prism.SingletonClassNode = @ptrCast(@alignCast(n));
            const prev = ctx.in_singleton;
            if (sn.expression.*.type == prism.NODE_SELF) ctx.in_singleton = true;
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            ctx.in_singleton = prev;
            return false;
        },
        prism.NODE_LOCAL_VAR_READ => {
            const lv: *const prism.LocalVarReadNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, lv.base.location.start);
            const name = resolveConstant(ctx.parser, lv.name);
            insertRef(ctx.db, ctx.file_id, name, lc.line, lc.col, ctx.scope_id) catch {
                ctx.error_count += 1;
            };
        },
        prism.NODE_CONSTANT_PATH => {
            const pn: *const prism.ConstantPathNode = @ptrCast(@alignCast(n));
            const full_owned = buildQualifiedName(ctx.parser, n, ctx.alloc) catch null;
            defer if (full_owned) |f| ctx.alloc.free(f);
            const ref_name: []const u8 = full_owned orelse blk: {
                if (pn.name != 0) break :blk resolveConstant(ctx.parser, pn.name);
                break :blk "";
            };
            if (ref_name.len > 0) {
                const lc = locationLineCol(ctx.parser, pn.base.location.start);
                insertRef(ctx.db, ctx.file_id, ref_name, lc.line, lc.col, null) catch {
                    ctx.error_count += 1;
                };
            }
        },
        prism.NODE_CONSTANT_PATH_WRITE => {
            const cpw: *const prism.ConstantPathWriteNode = @ptrCast(@alignCast(n));
            const full_owned = buildQualifiedName(ctx.parser, @as(*const prism.Node, @ptrCast(@alignCast(cpw.target))), ctx.alloc) catch null;
            defer if (full_owned) |f| ctx.alloc.free(f);
            const full_name: []const u8 = full_owned orelse "";
            if (full_name.len > 0) {
                const lc = locationLineCol(ctx.parser, cpw.target.*.base.location.start);
                // Extract parent from qualified name: "Foo::BAR" → parent "Foo", store full "Foo::BAR" as name
                const sep = std.mem.lastIndexOf(u8, full_name, "::");
                const qual_parent: ?[]const u8 = if (sep) |s| full_name[0..s] else null;
                _ = insertSymbolGetId(ctx, "constant", full_name, lc.line, lc.col, null, null, "public", qual_parent) catch 0;
            }
        },
        prism.NODE_INSTANCE_VAR_WRITE => {
            const iv: *const prism.InstanceVarWriteNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, iv.name_loc.start);
            const name = resolveConstant(ctx.parser, iv.name);

            var type_hint: ?[]const u8 = if (iv.value) |val| inferLiteralType(val) else null;

            if (type_hint == null) {
                if (iv.value) |val| {
                    if (val.*.type == prism.NODE_CALL) {
                        const call: *const prism.CallNode = @ptrCast(@alignCast(val));
                        const mname = resolveConstant(ctx.parser, call.name);
                        if (std.mem.eql(u8, mname, "new") and call.receiver != null) {
                            if (call.receiver.?.*.type == prism.NODE_CONSTANT) {
                                const rc: *const prism.ConstReadNode = @ptrCast(@alignCast(call.receiver.?));
                                type_hint = resolveConstant(ctx.parser, rc.name);
                            }
                        }
                    }
                }
            }

            // TypeProf-lite: @ivar = some_method → look up return_type from symbols
            var iv_inserted = false;
            if (type_hint == null) {
                if (iv.value) |val| {
                    if (val.*.type == prism.NODE_CALL) {
                        const call: *const prism.CallNode = @ptrCast(@alignCast(val));
                        const mname = resolveConstant(ctx.parser, call.name);
                        if (!std.mem.eql(u8, mname, "new")) {
                            if (ctx.db.prepare("SELECT return_type FROM symbols WHERE name = ? AND kind = 'def' " ++
                                "AND return_type IS NOT NULL LIMIT 1")) |rs|
                            {
                                defer rs.finalize();
                                rs.bind_text(1, mname);
                                if (rs.step() catch false) {
                                    const rt = rs.column_text(0);
                                    if (rt.len > 0) {
                                        insertLocalVarClassId(ctx.db, ctx.file_id, name, lc.line, lc.col, rt, 0, ctx.current_class_id) catch {
                                            ctx.error_count += 1;
                                        };
                                        iv_inserted = true;
                                    }
                                }
                            } else |_| {}
                        }
                    }
                }
            }
            if (!iv_inserted) insertLocalVarClassId(ctx.db, ctx.file_id, name, lc.line, lc.col, type_hint, 0, ctx.current_class_id) catch {
                ctx.error_count += 1;
            };
        },
        prism.NODE_INSTANCE_VAR_OR_WRITE, prism.NODE_INSTANCE_VAR_AND_WRITE => {
            const iv: *const prism.InstanceVarOrWriteNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, iv.name_loc.start);
            const name = resolveConstant(ctx.parser, iv.name);
            const rtype = if (iv.value != null)
                inferLiteralType(iv.value.?) orelse extractNewCallType(ctx.parser, iv.value.?)
            else
                null;
            insertLocalVarClassId(ctx.db, ctx.file_id, name, lc.line, lc.col, rtype, 0, ctx.current_class_id) catch {
                ctx.error_count += 1;
            };
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        prism.NODE_CLASS_VAR_WRITE => {
            const cvw: *const prism.ClassVarWriteNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, cvw.name_loc.start);
            const name = resolveConstant(ctx.parser, cvw.name);
            insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, null, 0, null) catch {
                ctx.error_count += 1;
            };
        },
        prism.NODE_CLASS_VAR_OR_WRITE, prism.NODE_CLASS_VAR_AND_WRITE => {
            const cvw: *const prism.ClassVarOrWriteNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, cvw.name_loc.start);
            const name = resolveConstant(ctx.parser, cvw.name);
            insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, null, 0, null) catch {
                ctx.error_count += 1;
            };
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        prism.NODE_LOCAL_VAR_WRITE => {
            const lv: *const prism.LocalVarWriteNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, lv.name_loc.start);
            const name = resolveConstant(ctx.parser, lv.name);
            addSemToken(ctx, lc.line, lc.col, @intCast(name.len), 4);

            // @type annotation takes highest priority
            var type_hint: ?[]const u8 = extractTypeAnnotation(ctx.source, lv.name_loc.start);
            var ar_alloc_type: ?[]u8 = null;
            defer if (ar_alloc_type) |t| ctx.alloc.free(t);

            // Array literal with typed first element: [User.new] → [User] for block param inference
            // Must run before inferLiteralType to avoid "Array" overriding "[User]"
            if (type_hint == null) {
                if (lv.value) |val| {
                    if (val.*.type == prism.NODE_ARRAY) {
                        const arr: *const prism.ArrayNode = @ptrCast(@alignCast(val));
                        if (arr.elements.size > 0) {
                            if (extractNewCallType(ctx.parser, arr.elements.nodes[0])) |elem| {
                                ar_alloc_type = std.fmt.allocPrint(ctx.alloc, "[{s}]", .{elem}) catch null;
                                if (ar_alloc_type) |at| type_hint = at;
                            }
                        }
                    }
                }
            }

            if (type_hint == null) {
                type_hint = if (lv.value) |val| inferLiteralType(val) else null;
            }

            if (type_hint == null) {
                if (lv.value) |val| {
                    type_hint = extractNewCallType(ctx.parser, val);
                }
            }

            if (type_hint == null) {
                if (lv.value) |val| {
                    if (val.*.type == prism.NODE_IF) {
                        const if_node: *const prism.IfNode = @ptrCast(@alignCast(val));
                        // Extract then branch: first statement in statements list
                        const then_t: ?[]const u8 = blk: {
                            if (if_node.statements == null) break :blk null;
                            const stmts: *const prism.StatementsNode = @ptrCast(@alignCast(if_node.statements));
                            if (stmts.body.size == 0) break :blk null;
                            break :blk extractNewCallType(ctx.parser, stmts.body.nodes[0]);
                        };
                        // Extract else branch: subsequent is either ElseNode or IfNode
                        const else_t: ?[]const u8 = blk: {
                            if (if_node.subsequent == null) break :blk null;
                            const subseq: *const prism.Node = @ptrCast(@alignCast(if_node.subsequent));
                            if (subseq.*.type == prism.NODE_ELSE) {
                                const else_node: *const prism.ElseNode = @ptrCast(@alignCast(subseq));
                                if (else_node.statements == null) break :blk null;
                                const stmts: *const prism.StatementsNode = @ptrCast(@alignCast(else_node.statements));
                                if (stmts.body.size == 0) break :blk null;
                                break :blk extractNewCallType(ctx.parser, stmts.body.nodes[0]);
                            }
                            break :blk null;
                        };
                        if (then_t != null and else_t != null and std.mem.eql(u8, then_t.?, else_t.?)) {
                            type_hint = then_t;
                        } else if (then_t != null) {
                            type_hint = then_t;
                        }
                    }
                }
            }

            if (type_hint == null) {
                if (lv.value) |val| {
                    if (val.*.type == prism.NODE_CASE) {
                        type_hint = extractNewCallType(ctx.parser, val);
                    }
                }
            }

            // ActiveRecord class method inference: User.find(1) → User, User.where(...) → [User]
            if (type_hint == null) {
                if (lv.value) |val| {
                    if (val.*.type == prism.NODE_CALL) {
                        const call: *const prism.CallNode = @ptrCast(@alignCast(val));
                        const mname = resolveConstant(ctx.parser, call.name);
                        if (call.receiver != null and call.receiver.?.*.type == prism.NODE_CONSTANT) {
                            const rc: *const prism.ConstReadNode = @ptrCast(@alignCast(call.receiver.?));
                            const class_name = resolveConstant(ctx.parser, rc.name);
                            const ar_singular = [_][]const u8{
                                "find",     "first",    "last",  "create", "create!", "build",
                                "find_by",  "find_by!", "take",  "new",    "[]",      "with_pk",
                                "with_pk!", "now",      "today", "parse",  "open",    "read",
                            };
                            const ar_plural = [_][]const u8{
                                "where",            "all",        "order",   "limit",  "includes", "joins",
                                "preload",          "eager_load", "select",  "group",  "having",   "left_joins",
                                "left_outer_joins", "distinct",   "exclude", "filter", "dataset",  "grep",
                                "eager",            "graph",
                            };
                            for (ar_singular) |m| {
                                if (std.mem.eql(u8, mname, m)) {
                                    type_hint = class_name;
                                    break;
                                }
                            }
                            if (type_hint == null) {
                                for (ar_plural) |m| {
                                    if (std.mem.eql(u8, mname, m)) {
                                        ar_alloc_type = std.fmt.allocPrint(ctx.alloc, "[{s}]", .{class_name}) catch null;
                                        if (ar_alloc_type) |at| type_hint = at;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // AR 2-level class chain: ClassName.ar_plural.ar_singular → ClassName, .ar_plural → [ClassName]
            if (type_hint == null) {
                if (lv.value) |val| {
                    if (val.*.type == prism.NODE_CALL) {
                        const outer_ar: *const prism.CallNode = @ptrCast(@alignCast(val));
                        const outer_ar_mname = resolveConstant(ctx.parser, outer_ar.name);
                        if (outer_ar.receiver) |mid_ar| {
                            if (mid_ar.*.type == prism.NODE_CALL) {
                                const inner_ar: *const prism.CallNode = @ptrCast(@alignCast(mid_ar));
                                const inner_ar_mname = resolveConstant(ctx.parser, inner_ar.name);
                                const ar_plural_set = [_][]const u8{ "where", "all", "order", "limit", "includes", "joins", "preload", "eager_load", "select", "group", "having", "left_joins", "left_outer_joins", "distinct", "scoped", "unscoped", "exclude", "filter", "dataset", "grep", "eager", "graph" };
                                const inner_is_pl = for (ar_plural_set) |m| {
                                    if (std.mem.eql(u8, inner_ar_mname, m)) break true;
                                } else false;
                                if (inner_is_pl) {
                                    if (inner_ar.receiver) |class_ar| {
                                        if (class_ar.*.type == prism.NODE_CONSTANT) {
                                            const rc3: *const prism.ConstReadNode = @ptrCast(@alignCast(class_ar));
                                            const cname3 = resolveConstant(ctx.parser, rc3.name);
                                            const ar_sing_set = [_][]const u8{ "first", "last", "find", "find_by", "find_by!", "take", "create", "create!", "build" };
                                            const outer_is_sing = for (ar_sing_set) |m| {
                                                if (std.mem.eql(u8, outer_ar_mname, m)) break true;
                                            } else false;
                                            if (outer_is_sing) {
                                                type_hint = cname3;
                                            } else {
                                                const outer_is_pl = for (ar_plural_set) |m| {
                                                    if (std.mem.eql(u8, outer_ar_mname, m)) break true;
                                                } else false;
                                                if (outer_is_pl) {
                                                    ar_alloc_type = std.fmt.allocPrint(ctx.alloc, "[{s}]", .{cname3}) catch null;
                                                    if (ar_alloc_type) |at| type_hint = at;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            var inserted = false;

            // Sorbet T.let(expr, Type) / T.cast(expr, Type) / T.must(expr) — authoritative
            if (!inserted) {
                if (lv.value) |val_tl| {
                    if (val_tl.*.type == prism.NODE_CALL) {
                        const tcall: *const prism.CallNode = @ptrCast(@alignCast(val_tl));
                        if (tcall.receiver != null and tcall.receiver.?.*.type == prism.NODE_CONSTANT) {
                            const trc: *const prism.ConstReadNode = @ptrCast(@alignCast(tcall.receiver.?));
                            const tcls = resolveConstant(ctx.parser, trc.name);
                            if (std.mem.eql(u8, tcls, "T")) {
                                const tmname = resolveConstant(ctx.parser, tcall.name);
                                if ((std.mem.eql(u8, tmname, "let") or std.mem.eql(u8, tmname, "cast")) and tcall.arguments != null) {
                                    const targs = tcall.arguments[0].arguments;
                                    if (targs.size >= 2) {
                                        const type_arg = targs.nodes[1];
                                        const t_start = type_arg.*.location.start;
                                        const t_end = type_arg.*.location.start + type_arg.*.location.length;
                                        if (t_end > t_start and t_end <= ctx.source.len) {
                                            const t_src = std.mem.trim(u8, ctx.source[t_start..t_end], " \t");
                                            if (t_src.len > 0 and t_src.len < 128) {
                                                var tbuf: [160]u8 = undefined;
                                                var final_t: []const u8 = t_src;
                                                if (std.mem.startsWith(u8, t_src, "T.nilable(") and std.mem.endsWith(u8, t_src, ")")) {
                                                    const inner = std.mem.trim(u8, t_src[10 .. t_src.len - 1], " \t");
                                                    if (std.fmt.bufPrint(&tbuf, "{s} | nil", .{inner})) |b| {
                                                        final_t = b;
                                                    } else |_| {}
                                                }
                                                insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, final_t, 95, ctx.scope_id) catch {
                                                    ctx.error_count += 1;
                                                };
                                                inserted = true;
                                            }
                                        }
                                    }
                                } else if (std.mem.eql(u8, tmname, "must") and tcall.arguments != null) {
                                    const targs = tcall.arguments[0].arguments;
                                    if (targs.size >= 1) {
                                        const inner_arg = targs.nodes[0];
                                        if (inner_arg.*.type == prism.NODE_LOCAL_VAR_READ) {
                                            const lvr: *const prism.LocalVarReadNode = @ptrCast(@alignCast(inner_arg));
                                            const inner_name = resolveConstant(ctx.parser, lvr.name);
                                            if (ctx.db.prepare("SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1")) |ms| {
                                                defer ms.finalize();
                                                ms.bind_int(1, ctx.file_id);
                                                ms.bind_text(2, inner_name);
                                                if (ms.step() catch false) {
                                                    const raw = ms.column_text(0);
                                                    const stripped = if (std.mem.endsWith(u8, raw, " | nil")) raw[0 .. raw.len - 6] else raw;
                                                    if (stripped.len > 0) {
                                                        insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, stripped, 95, ctx.scope_id) catch {
                                                            ctx.error_count += 1;
                                                        };
                                                        inserted = true;
                                                    }
                                                }
                                            } else |_| {}
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // self.method: look up return_type in current class (Phase 29, confidence=75)
            if (!inserted and type_hint == null) {
                if (lv.value) |val| {
                    if (val.*.type == prism.NODE_CALL) {
                        const cn2: *const prism.CallNode = @ptrCast(@alignCast(val));
                        if (cn2.receiver) |recv2| {
                            if (recv2.*.type == prism.NODE_SELF) {
                                if (ctx.current_class_id) |cid| {
                                    const called = resolveConstant(ctx.parser, cn2.name);
                                    if (ctx.db.prepare("SELECT s.return_type FROM symbols s " ++
                                        "WHERE s.name=? AND s.kind IN ('def','classdef') " ++
                                        "AND s.file_id=(SELECT file_id FROM symbols WHERE id=?) " ++
                                        "AND s.return_type IS NOT NULL LIMIT 1")) |ss|
                                    {
                                        defer ss.finalize();
                                        ss.bind_text(1, called);
                                        ss.bind_int(2, cid);
                                        if (ss.step() catch false) {
                                            const rt = ss.column_text(0);
                                            if (rt.len > 0) {
                                                insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, rt, 75, ctx.scope_id) catch {
                                                    ctx.error_count += 1;
                                                };
                                                inserted = true;
                                            }
                                        }
                                    } else |_| {}
                                }
                            }
                        }
                    }
                }
            }

            // 1-level chain: user.profile where user: User (Phase 29, confidence=55)
            if (!inserted and type_hint == null) {
                if (lv.value) |val| {
                    if (val.*.type == prism.NODE_CALL) {
                        const cn3: *const prism.CallNode = @ptrCast(@alignCast(val));
                        if (cn3.receiver) |recv3| {
                            if (recv3.*.type == prism.NODE_LOCAL_VAR_READ) {
                                const lvr: *const prism.LocalVarReadNode = @ptrCast(@alignCast(recv3));
                                const recv_name = resolveConstant(ctx.parser, lvr.name);
                                const called = resolveConstant(ctx.parser, cn3.name);
                                if (ctx.db.prepare("SELECT type_hint FROM local_vars " ++
                                    "WHERE name=? AND type_hint IS NOT NULL " ++
                                    "ORDER BY CASE WHEN file_id=? THEN 0 ELSE 1 END, confidence DESC, line DESC LIMIT 1")) |rs2|
                                {
                                    defer rs2.finalize();
                                    rs2.bind_text(1, recv_name);
                                    rs2.bind_int(2, ctx.file_id);
                                    if (rs2.step() catch false) {
                                        const recv_type = rs2.column_text(0);
                                        if (recv_type.len > 0) {
                                            if (ctx.db.prepare("SELECT return_type FROM symbols " ++
                                                "WHERE name=? AND kind='def' AND file_id IN " ++
                                                "(SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?) " ++
                                                "AND return_type IS NOT NULL LIMIT 1")) |cs|
                                            {
                                                defer cs.finalize();
                                                cs.bind_text(1, called);
                                                cs.bind_text(2, recv_type);
                                                if (cs.step() catch false) {
                                                    const rt = cs.column_text(0);
                                                    if (rt.len > 0) {
                                                        insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, rt, 55, ctx.scope_id) catch {
                                                            ctx.error_count += 1;
                                                        };
                                                        inserted = true;
                                                    }
                                                }
                                            } else |_| {}
                                            if (!inserted) {
                                                if (lookupStdlibReturn(recv_type, called)) |stdlib_rt| {
                                                    insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, stdlib_rt, 55, ctx.scope_id) catch {
                                                        ctx.error_count += 1;
                                                    };
                                                    inserted = true;
                                                }
                                            }
                                        }
                                    }
                                } else |_| {}
                            }
                        }
                    }
                }
            }

            // N-level chain: a.b.c.d.e (up to 5 levels, confidence decreases with depth)
            if (!inserted and type_hint == null) blk2: {
                const val2 = lv.value orelse break :blk2;
                if (val2.*.type != prism.NODE_CALL) break :blk2;

                // Walk the receiver chain to collect method names (innermost first)
                var chain_methods: [6][]const u8 = undefined;
                var chain_len: u8 = 0;
                var cur_node: *const prism.Node = val2;
                while (chain_len < 6) {
                    if (cur_node.*.type != prism.NODE_CALL) break;
                    const cn_walk: *const prism.CallNode = @ptrCast(@alignCast(cur_node));
                    chain_methods[chain_len] = resolveConstant(ctx.parser, cn_walk.name);
                    chain_len += 1;
                    cur_node = cn_walk.receiver orelse break;
                }
                if (chain_len < 2) break :blk2;
                // cur_node should be the root (local var or self)
                var root_type_storage: [128]u8 = undefined;
                var current_type: []const u8 = undefined;
                if (cur_node.*.type == prism.NODE_LOCAL_VAR_READ) {
                    const lvr2: *const prism.LocalVarReadNode = @ptrCast(@alignCast(cur_node));
                    const root_name = resolveConstant(ctx.parser, lvr2.name);
                    const r1 = ctx.db.prepare("SELECT type_hint FROM local_vars WHERE name=? " ++
                        "AND type_hint IS NOT NULL ORDER BY confidence DESC LIMIT 1") catch break :blk2;
                    defer r1.finalize();
                    r1.bind_text(1, root_name);
                    if (!(r1.step() catch false)) break :blk2;
                    const rt_raw = r1.column_text(0);
                    const rt_len = @min(rt_raw.len, root_type_storage.len);
                    @memcpy(root_type_storage[0..rt_len], rt_raw[0..rt_len]);
                    current_type = root_type_storage[0..rt_len];
                } else if (cur_node.*.type == prism.NODE_CONSTANT) {
                    const rc2: *const prism.ConstReadNode = @ptrCast(@alignCast(cur_node));
                    const cname2 = resolveConstant(ctx.parser, rc2.name);
                    const cn2_len = @min(cname2.len, root_type_storage.len);
                    @memcpy(root_type_storage[0..cn2_len], cname2[0..cn2_len]);
                    current_type = root_type_storage[0..cn2_len];
                } else break :blk2;

                // Resolve types through the chain (reverse order: root → leaf)
                var step_buf: [128]u8 = undefined;
                var step_idx: u8 = chain_len;
                while (step_idx > 1) {
                    step_idx -= 1;
                    const method_name = chain_methods[step_idx];
                    // Constructor-like methods return the class itself
                    if (std.mem.eql(u8, method_name, "new") or std.mem.eql(u8, method_name, "[]") or
                        std.mem.eql(u8, method_name, "now") or std.mem.eql(u8, method_name, "today") or
                        std.mem.eql(u8, method_name, "parse"))
                        continue;
                    // Strip generic brackets for class lookup
                    const base_type = if (std.mem.indexOfScalar(u8, current_type, '[')) |bracket|
                        current_type[0..bracket]
                    else
                        current_type;
                    var found = false;
                    if (ctx.db.prepare("SELECT return_type FROM symbols WHERE name=? AND kind='def' " ++
                        "AND file_id IN (SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?) " ++
                        "AND return_type IS NOT NULL LIMIT 1")) |rs|
                    {
                        defer rs.finalize();
                        rs.bind_text(1, method_name);
                        rs.bind_text(2, base_type);
                        if (rs.step() catch false) {
                            const raw = rs.column_text(0);
                            if (raw.len > 0) {
                                const ft_len = @min(raw.len, step_buf.len);
                                @memcpy(step_buf[0..ft_len], raw[0..ft_len]);
                                const cpy_len = @min(ft_len, root_type_storage.len);
                                @memcpy(root_type_storage[0..cpy_len], step_buf[0..cpy_len]);
                                current_type = root_type_storage[0..cpy_len];
                                found = true;
                            }
                        }
                    } else |_| {}
                    if (!found) {
                        if (lookupStdlibReturn(base_type, method_name)) |stdlib_rt| {
                            const ft_len = @min(stdlib_rt.len, step_buf.len);
                            @memcpy(step_buf[0..ft_len], stdlib_rt[0..ft_len]);
                            const cpy_len = @min(ft_len, root_type_storage.len);
                            @memcpy(root_type_storage[0..cpy_len], step_buf[0..cpy_len]);
                            current_type = root_type_storage[0..cpy_len];
                            found = true;
                        }
                    }
                    if (!found) {
                        const is_ar_plural = for ([_][]const u8{ "where", "all", "order", "limit", "includes", "joins", "scoped", "preload", "eager_load", "distinct", "group", "having", "reorder", "rewhere" }) |m| {
                            if (std.mem.eql(u8, method_name, m)) break true;
                        } else false;
                        if (is_ar_plural) {
                            // Copy base_type to step_buf to avoid aliasing with root_type_storage
                            const bt_len = @min(base_type.len, step_buf.len);
                            @memcpy(step_buf[0..bt_len], base_type[0..bt_len]);
                            current_type = std.fmt.bufPrint(&root_type_storage, "[{s}]", .{step_buf[0..bt_len]}) catch break :blk2;
                            found = true;
                        }
                    }
                    if (!found) break :blk2;
                }
                // Resolve the final (outermost) method
                const leaf_method = chain_methods[0];
                const leaf_base = if (std.mem.indexOfScalar(u8, current_type, '[')) |bracket|
                    current_type[0..bracket]
                else
                    current_type;
                var leaf_type_buf: [128]u8 = undefined;
                var leaf_type: ?[]const u8 = null;
                if (ctx.db.prepare("SELECT return_type FROM symbols WHERE name=? AND kind='def' " ++
                    "AND file_id IN (SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?) " ++
                    "AND return_type IS NOT NULL LIMIT 1")) |rs|
                {
                    defer rs.finalize();
                    rs.bind_text(1, leaf_method);
                    rs.bind_text(2, leaf_base);
                    if (rs.step() catch false) {
                        const raw = rs.column_text(0);
                        if (raw.len > 0) {
                            const lt_len = @min(raw.len, leaf_type_buf.len);
                            @memcpy(leaf_type_buf[0..lt_len], raw[0..lt_len]);
                            leaf_type = leaf_type_buf[0..lt_len];
                        }
                    }
                } else |_| {}
                if (leaf_type == null) {
                    if (lookupStdlibReturn(leaf_base, leaf_method)) |stdlib_lt| {
                        const lt_len = @min(stdlib_lt.len, leaf_type_buf.len);
                        @memcpy(leaf_type_buf[0..lt_len], stdlib_lt[0..lt_len]);
                        leaf_type = leaf_type_buf[0..lt_len];
                    }
                }
                if (leaf_type) |lt| {
                    const confidence: u8 = switch (chain_len) {
                        2 => 38,
                        3 => 30,
                        4 => 25,
                        else => 20,
                    };
                    insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, lt, confidence, ctx.scope_id) catch {
                        ctx.error_count += 1;
                    };
                    inserted = true;
                }
            }

            // Block return type: names = users.map { |u| u.name } → [String]
            if (!inserted and type_hint == null) blk_ret: {
                const val_br = lv.value orelse break :blk_ret;
                if (val_br.*.type != prism.NODE_CALL) break :blk_ret;
                const cn_br: *const prism.CallNode = @ptrCast(@alignCast(val_br));
                const mname_br = resolveConstant(ctx.parser, cn_br.name);
                if (!isIterationMethod(mname_br)) break :blk_ret;
                if (cn_br.block == null) break :blk_ret;
                const recv_br = cn_br.receiver orelse break :blk_ret;
                var recv_type_buf: [128]u8 = undefined;
                var recv_type: ?[]const u8 = null;
                if (recv_br.*.type == prism.NODE_LOCAL_VAR_READ) {
                    const lvr_br: *const prism.LocalVarReadNode = @ptrCast(@alignCast(recv_br));
                    const rn = resolveConstant(ctx.parser, lvr_br.name);
                    if (ctx.db.prepare("SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1")) |rst| {
                        defer rst.finalize();
                        rst.bind_int(1, ctx.file_id);
                        rst.bind_text(2, rn);
                        if (rst.step() catch false) {
                            const raw_rt = rst.column_text(0);
                            const rt_len = @min(raw_rt.len, recv_type_buf.len);
                            @memcpy(recv_type_buf[0..rt_len], raw_rt[0..rt_len]);
                            recv_type = recv_type_buf[0..rt_len];
                        }
                    } else |_| {}
                } else if (recv_br.*.type == prism.NODE_CONSTANT) {
                    const rc_br: *const prism.ConstReadNode = @ptrCast(@alignCast(recv_br));
                    recv_type = resolveConstant(ctx.parser, rc_br.name);
                }
                if (recv_type) |rt| {
                    const result_type = inferBlockReturnType(mname_br, rt);
                    if (result_type) |brt| {
                        insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, brt, 50, ctx.scope_id) catch {
                            ctx.error_count += 1;
                        };
                        inserted = true;
                    }
                }
            }

            // TypeProf-lite: x = some_method → look up return_type from symbols
            if (type_hint == null) {
                if (lv.value) |val| {
                    if (val.*.type == prism.NODE_CALL) {
                        const call: *const prism.CallNode = @ptrCast(@alignCast(val));
                        const mname = resolveConstant(ctx.parser, call.name);
                        if (!std.mem.eql(u8, mname, "new")) {
                            if (ctx.db.prepare("SELECT return_type FROM symbols WHERE name = ? AND kind = 'def' " ++
                                "AND return_type IS NOT NULL LIMIT 1")) |rs|
                            {
                                defer rs.finalize();
                                rs.bind_text(1, mname);
                                if (rs.step() catch false) {
                                    const rt = rs.column_text(0);
                                    if (rt.len > 0) {
                                        insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, rt, 0, ctx.scope_id) catch {
                                            ctx.error_count += 1;
                                        };
                                        inserted = true;
                                    }
                                }
                            } else |_| {}
                        }
                    }
                }
            }

            if (!inserted) insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, type_hint, 0, ctx.scope_id) catch {
                ctx.error_count += 1;
            };
            if (lv.value) |val| {
                if (val.*.type == prism.NODE_LAMBDA) {
                    const lam: *const prism.LambdaNode = @ptrCast(@alignCast(val));
                    var lambda_ret: ?[]const u8 = null;
                    if (lam.body != null) {
                        const body_node: *const prism.Node = @ptrCast(@alignCast(lam.body.?));
                        if (body_node.*.type == prism.NODE_STATEMENTS) {
                            const stmts: *const prism.StatementsNode = @ptrCast(@alignCast(body_node));
                            if (stmts.body.size > 0) {
                                const last = stmts.body.nodes[stmts.body.size - 1];
                                lambda_ret = extractNewCallType(ctx.parser, last) orelse inferLiteralType(last);
                            }
                        }
                    }
                    const sym_id = insertSymbolGetId(ctx, "def", name, lc.line, lc.col, lambda_ret, null, "public", null) catch 0;
                    if (sym_id > 0 and lam.parameters != null) {
                        const param_node: *const prism.Node = @ptrCast(@alignCast(lam.parameters.?));
                        if (param_node.*.type == prism.NODE_BLOCK_PARAMETERS) {
                            const bp: *const prism.BlockParametersNode = @ptrCast(@alignCast(lam.parameters.?));
                            if (bp.parameters != null) {
                                extractParams(ctx, sym_id, bp.parameters.?) catch {
                                    ctx.error_count += 1;
                                };
                            }
                        }
                    }
                }
            }
        },
        prism.NODE_MULTI_WRITE => {
            const mw: *const prism.MultiWriteNode = @ptrCast(@alignCast(n));
            if (mw.value != null and mw.value.?.*.type == prism.NODE_ARRAY) {
                const arr: *const prism.ArrayNode = @ptrCast(@alignCast(mw.value.?));
                const pair_count = @min(mw.lefts.size, arr.elements.size);
                for (0..pair_count) |i| {
                    const left = mw.lefts.nodes[i];
                    if (left.*.type != prism.NODE_LOCAL_VAR_TARGET) continue;
                    const lt: *const prism.LocalVarTargetNode = @ptrCast(@alignCast(left));
                    const lname = resolveConstant(ctx.parser, lt.name);
                    if (std.mem.eql(u8, lname, "_")) continue;
                    const llc = locationLineCol(ctx.parser, left.*.location.start);
                    const rtype = extractNewCallType(ctx.parser, arr.elements.nodes[i]);
                    insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, rtype, 0, ctx.scope_id) catch {
                        ctx.error_count += 1;
                    };
                }
            } else if (mw.lefts.size == 1 and mw.value != null) {
                const left = mw.lefts.nodes[0];
                if (left.*.type == prism.NODE_LOCAL_VAR_TARGET) {
                    const lt: *const prism.LocalVarTargetNode = @ptrCast(@alignCast(left));
                    const lname = resolveConstant(ctx.parser, lt.name);
                    const llc = locationLineCol(ctx.parser, left.*.location.start);
                    const rtype = extractNewCallType(ctx.parser, mw.value.?);
                    insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, rtype, 0, ctx.scope_id) catch {
                        ctx.error_count += 1;
                    };
                }
            }
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        prism.NODE_FOR => {
            const fn_node: *const prism.ForNode = @ptrCast(@alignCast(n));
            if (fn_node.index.*.type == prism.NODE_LOCAL_VAR_TARGET) {
                const lt: *const prism.LocalVarTargetNode = @ptrCast(@alignCast(fn_node.index));
                const lname = resolveConstant(ctx.parser, lt.name);
                const llc = locationLineCol(ctx.parser, fn_node.index.*.location.start);
                const coll_type = extractNewCallType(ctx.parser, fn_node.collection);
                const elem_type = stripArrayBrackets(coll_type);
                insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, elem_type, 50, ctx.scope_id) catch {
                    ctx.error_count += 1;
                };
            }
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        prism.NODE_RESCUE => {
            const rn: *const prism.RescueNode = @ptrCast(@alignCast(n));
            if (rn.reference != null and rn.reference.?.*.type == prism.NODE_LOCAL_VAR_TARGET) {
                const lt: *const prism.LocalVarTargetNode = @ptrCast(@alignCast(rn.reference.?));
                const lname = resolveConstant(ctx.parser, lt.name);
                const llc = locationLineCol(ctx.parser, rn.reference.?.*.location.start);
                var exc_type: ?[]const u8 = null;
                if (rn.exceptions.size > 0) {
                    const exc = rn.exceptions.nodes[0];
                    if (exc.*.type == prism.NODE_CONSTANT) {
                        const cn: *const prism.ConstReadNode = @ptrCast(@alignCast(exc));
                        exc_type = resolveConstant(ctx.parser, cn.name);
                    }
                }
                insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, exc_type, 80, ctx.scope_id) catch {
                    ctx.error_count += 1;
                };
            }
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        prism.NODE_RESCUE_MODIFIER => {
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        prism.NODE_LOCAL_VAR_OR_WRITE => {
            const lw: *const prism.LocalVarOrWriteNode = @ptrCast(@alignCast(n));
            const lname = resolveConstant(ctx.parser, lw.name);
            const llc = locationLineCol(ctx.parser, lw.name_loc.start);
            const rtype = if (lw.value) |val| inferLiteralType(val) orelse extractNewCallType(ctx.parser, val) else null;
            insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, rtype, 20, ctx.scope_id) catch {
                ctx.error_count += 1;
            };
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        prism.NODE_LOCAL_VAR_AND_WRITE => {
            const lw: *const prism.LocalVarAndWriteNode = @ptrCast(@alignCast(n));
            const lname = resolveConstant(ctx.parser, lw.name);
            const llc = locationLineCol(ctx.parser, lw.name_loc.start);
            const rtype = if (lw.value) |val| inferLiteralType(val) orelse extractNewCallType(ctx.parser, val) else null;
            insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, rtype, 15, ctx.scope_id) catch {
                ctx.error_count += 1;
            };
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        prism.NODE_LOCAL_VAR_OP_WRITE => {
            const lw: *const prism.LocalVarOpWriteNode = @ptrCast(@alignCast(n));
            const lname = resolveConstant(ctx.parser, lw.name);
            const llc = locationLineCol(ctx.parser, lw.name_loc.start);
            insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, null, 20, ctx.scope_id) catch {
                ctx.error_count += 1;
            };
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        prism.NODE_CASE_MATCH => {
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        prism.NODE_CAPTURE_PATTERN => {
            const cp: *const prism.CapturePatternNode = @ptrCast(@alignCast(n));
            const lt: *const prism.LocalVarTargetNode = @ptrCast(@alignCast(cp.target));
            const lname = resolveConstant(ctx.parser, lt.name);
            const llc = locationLineCol(ctx.parser, n.*.location.start);
            var pat_type: ?[]const u8 = null;
            if (cp.value.*.type == prism.NODE_CONSTANT) {
                const cn2: *const prism.ConstReadNode = @ptrCast(@alignCast(cp.value));
                pat_type = resolveConstant(ctx.parser, cn2.name);
            } else if (cp.value.*.type == prism.NODE_CONSTANT_PATH) {
                const cpv: *const prism.ConstantPathNode = @ptrCast(@alignCast(cp.value));
                if (cpv.name != 0) pat_type = resolveConstant(ctx.parser, cpv.name);
            }
            insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, pat_type, 85, ctx.scope_id) catch {
                ctx.error_count += 1;
            };
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        // Control flow: visit children so body vars get indexed (Phase 29)
        prism.NODE_UNLESS => {
            const unless_node: *const prism.UnlessNode = @ptrCast(@alignCast(n));
            if (unless_node.predicate) |cond| {
                if (detectNilGuard(ctx.parser, cond)) |var_name| {
                    const guard_lc = locationLineCol(ctx.parser, cond.*.location.start);
                    insertLocalVar(ctx.db, ctx.file_id, var_name, guard_lc.line, guard_lc.col, "Object", 80, ctx.scope_id) catch {
                        ctx.error_count += 1;
                    };
                }
            }
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        prism.NODE_WHILE, prism.NODE_UNTIL => {
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        prism.NODE_ENSURE, prism.NODE_YIELD, prism.NODE_SUPER, prism.NODE_FORWARDING_SUPER, prism.NODE_CALL_AND_WRITE, prism.NODE_CALL_OR_WRITE => {
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        // Global variable write: index with scope_id=null (Phase 29)
        prism.NODE_GLOBAL_VAR_WRITE => {
            const gv: *const prism.GlobalVarWriteNode = @ptrCast(@alignCast(n));
            const gname = resolveConstant(ctx.parser, gv.name);
            const glc = locationLineCol(ctx.parser, n.*.location.start);
            const gval_type: ?[]const u8 = if (gv.value != null) blk: {
                break :blk inferLiteralType(gv.value.?) orelse extractNewCallType(ctx.parser, gv.value.?);
            } else null;
            insertLocalVar(ctx.db, ctx.file_id, gname, glc.line, glc.col, gval_type, 70, null) catch {
                ctx.error_count += 1;
            };
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        prism.NODE_GLOBAL_VAR_OR_WRITE, prism.NODE_GLOBAL_VAR_AND_WRITE => {
            const gv: *const prism.GlobalVarOrWriteNode = @ptrCast(@alignCast(n));
            const gname = resolveConstant(ctx.parser, gv.name);
            const glc = locationLineCol(ctx.parser, gv.name_loc.start);
            insertLocalVar(ctx.db, ctx.file_id, gname, glc.line, glc.col, null, 70, null) catch {
                ctx.error_count += 1;
            };
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        prism.NODE_IF => {
            const if_node: *const prism.IfNode = @ptrCast(@alignCast(n));
            if (if_node.predicate) |cond| {
                if (detectTypeGuard(ctx.parser, cond)) |guard| {
                    const guard_lc = locationLineCol(ctx.parser, cond.*.location.start);
                    insertLocalVar(ctx.db, ctx.file_id, guard.name, guard_lc.line, guard_lc.col, guard.narrowed_type, 85, ctx.scope_id) catch {
                        ctx.error_count += 1;
                    };
                }
            }
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        else => {},
    }
    return true;
}

fn extractParams(ctx: *VisitCtx, symbol_id: i64, params_node: *const prism.ParametersNode) !void {
    var position: u32 = 0;

    for (0..params_node.requireds.size) |i| {
        const n = params_node.requireds.nodes[i];
        if (n.*.type == prism.NODE_REQUIRED_PARAM) {
            const rp: *const prism.RequiredParamNode = @ptrCast(@alignCast(n));
            const name = resolveConstant(ctx.parser, rp.name);
            const lc = locationLineCol(ctx.parser, rp.base.location.start);
            try insertParam(ctx.db, symbol_id, position, name, "required", null, 0);
            addSemToken(ctx, lc.line, lc.col, @intCast(name.len), 3);
        }
        position += 1;
    }

    for (0..params_node.optionals.size) |i| {
        const n = params_node.optionals.nodes[i];
        if (n.*.type == prism.NODE_OPTIONAL_PARAM) {
            const op: *const prism.OptionalParamNode = @ptrCast(@alignCast(n));
            const name = resolveConstant(ctx.parser, op.name);
            const lc = locationLineCol(ctx.parser, op.base.location.start);
            try insertParam(ctx.db, symbol_id, position, name, "optional", null, 0);
            addSemToken(ctx, lc.line, lc.col, @intCast(name.len), 3);
        }
        position += 1;
    }

    if (params_node.rest != null) {
        const rn = params_node.rest.?;
        if (rn.*.type == prism.NODE_REST_PARAM) {
            const rp: *const prism.RestParamNode = @ptrCast(@alignCast(rn));
            if (rp.name != 0) {
                const name = resolveConstant(ctx.parser, rp.name);
                const lc = locationLineCol(ctx.parser, rp.base.location.start);
                try insertParam(ctx.db, symbol_id, position, name, "rest", "Array", 0);
                addSemToken(ctx, lc.line, lc.col, @intCast(name.len), 3);
            } else {
                try insertParam(ctx.db, symbol_id, position, "*", "rest", "Array", 0);
            }
        }
        position += 1;
    }

    for (0..params_node.keywords.size) |i| {
        const n = params_node.keywords.nodes[i];
        if (n.*.type == prism.NODE_REQUIRED_KW_PARAM) {
            const rk: *const prism.RequiredKwParamNode = @ptrCast(@alignCast(n));
            const name = resolveConstant(ctx.parser, rk.name);
            const lc = locationLineCol(ctx.parser, rk.base.location.start);
            try insertParam(ctx.db, symbol_id, position, name, "keyword", null, 0);
            addSemToken(ctx, lc.line, lc.col, @intCast(name.len), 3);
        } else if (n.*.type == prism.NODE_OPTIONAL_KW_PARAM) {
            const ok: *const prism.OptionalKwParamNode = @ptrCast(@alignCast(n));
            const name = resolveConstant(ctx.parser, ok.name);
            const lc = locationLineCol(ctx.parser, ok.base.location.start);
            const kw_type: ?[]const u8 = if (ok.value != null) switch (ok.value.?.*.type) {
                prism.NODE_INTEGER => "Integer",
                prism.NODE_FLOAT => "Float",
                prism.NODE_STRING, prism.NODE_INTERPOLATED_STR => "String",
                prism.NODE_SYMBOL => "Symbol",
                prism.NODE_TRUE, prism.NODE_FALSE => "Boolean",
                prism.NODE_ARRAY => "Array",
                prism.NODE_HASH => "Hash",
                else => null,
            } else null;
            try insertParam(ctx.db, symbol_id, position, name, "keyword", kw_type, 0);
            addSemToken(ctx, lc.line, lc.col, @intCast(name.len), 3);
        }
        position += 1;
    }

    if (params_node.keyword_rest != null) {
        const krn = params_node.keyword_rest.?;
        if (krn.*.type == prism.NODE_KEYWORD_REST_PARAM) {
            const kr: *const prism.KeywordRestParamNode = @ptrCast(@alignCast(krn));
            if (kr.name != 0) {
                const name = resolveConstant(ctx.parser, kr.name);
                const lc = locationLineCol(ctx.parser, kr.base.location.start);
                try insertParam(ctx.db, symbol_id, position, name, "keyword_rest", "Hash", 0);
                addSemToken(ctx, lc.line, lc.col, @intCast(name.len), 3);
            } else {
                try insertParam(ctx.db, symbol_id, position, "**", "keyword_rest", "Hash", 0);
            }
        }
        position += 1;
    }

    if (params_node.block != null) {
        const bn = params_node.block.?;
        if (bn.*.type == prism.NODE_BLOCK_PARAM) {
            const bp: *const prism.BlockParamNode = @ptrCast(@alignCast(bn));
            if (bp.name != 0) {
                const name = resolveConstant(ctx.parser, bp.name);
                const lc = locationLineCol(ctx.parser, bp.base.location.start);
                try insertParam(ctx.db, symbol_id, position, name, "block", null, 0);
                addSemToken(ctx, lc.line, lc.col, @intCast(name.len), 3);
            } else {
                try insertParam(ctx.db, symbol_id, position, "&", "block", null, 0);
            }
        }
    }
}

fn insertRef(db: db_mod.Db, file_id: i64, name: []const u8, line: i32, col: u32, scope_id: ?i64) !void {
    const stmt = try db.prepare(
        \\INSERT OR IGNORE INTO refs (file_id, name, line, col, scope_id) VALUES (?, ?, ?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_text(2, name);
    stmt.bind_int(3, line);
    stmt.bind_int(4, @intCast(col));
    if (scope_id) |sid| stmt.bind_int(5, sid) else stmt.bind_null(5);
    _ = try stmt.step();
}

// Variant for ref insertions where call-site context is known (positional arg count and,
// when resolvable, receiver static type). The type checker reads these columns.
fn insertCallRef(
    db: db_mod.Db,
    file_id: i64,
    name: []const u8,
    line: i32,
    col: u32,
    scope_id: ?i64,
    arg_count: i64,
    receiver_type: ?[]const u8,
) !void {
    const stmt = try db.prepare(
        \\INSERT OR IGNORE INTO refs (file_id, name, line, col, scope_id, arg_count, receiver_type)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_text(2, name);
    stmt.bind_int(3, line);
    stmt.bind_int(4, @intCast(col));
    if (scope_id) |sid| stmt.bind_int(5, sid) else stmt.bind_null(5);
    stmt.bind_int(6, arg_count);
    if (receiver_type) |rt| stmt.bind_text(7, rt) else stmt.bind_null(7);
    _ = try stmt.step();
}

fn insertSymbol(ctx: *VisitCtx, kind: []const u8, name: []const u8, line: i32, col: u32, _: ?[]const u8) !void {
    const stmt = try ctx.db.prepare(
        \\INSERT OR IGNORE INTO symbols (file_id, name, kind, line, col)
        \\VALUES (?, ?, ?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, ctx.file_id);
    stmt.bind_text(2, name);
    stmt.bind_text(3, kind);
    stmt.bind_int(4, line);
    stmt.bind_int(5, @intCast(col));
    _ = try stmt.step();
}

fn insertSymbolWithReturn(ctx: *VisitCtx, kind: []const u8, name: []const u8, line: i32, col: u32, return_type: ?[]const u8, doc: ?[]const u8, parent_name: ?[]const u8, value_snippet: ?[]const u8) !void {
    const stmt = try ctx.db.prepare(
        \\INSERT OR IGNORE INTO symbols (file_id, name, kind, line, col, return_type, doc, parent_name, value_snippet)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, ctx.file_id);
    stmt.bind_text(2, name);
    stmt.bind_text(3, kind);
    stmt.bind_int(4, line);
    stmt.bind_int(5, @intCast(col));
    if (return_type) |rt| stmt.bind_text(6, rt) else stmt.bind_null(6);
    if (doc) |d| stmt.bind_text(7, d) else stmt.bind_null(7);
    if (parent_name) |pn| stmt.bind_text(8, pn) else stmt.bind_null(8);
    if (value_snippet) |vs| stmt.bind_text(9, vs) else stmt.bind_null(9);
    _ = try stmt.step();
}

fn insertSymbolGetId(ctx: *VisitCtx, kind: []const u8, name: []const u8, line: i32, col: u32, doc: ?[]const u8, end_line: ?i64, visibility: []const u8, parent_name: ?[]const u8) !i64 {
    const stmt = try ctx.db.prepare(
        \\INSERT INTO symbols (file_id, name, kind, line, col, doc, end_line, visibility, parent_name)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        \\RETURNING id
    );
    defer stmt.finalize();
    stmt.bind_int(1, ctx.file_id);
    stmt.bind_text(2, name);
    stmt.bind_text(3, kind);
    stmt.bind_int(4, line);
    stmt.bind_int(5, @intCast(col));
    if (doc) |d| stmt.bind_text(6, d) else stmt.bind_null(6);
    if (end_line) |el| stmt.bind_int(7, el) else stmt.bind_null(7);
    stmt.bind_text(8, visibility);
    if (parent_name) |pn| stmt.bind_text(9, pn) else stmt.bind_null(9);
    if (try stmt.step()) return stmt.column_int(0);
    return ctx.db.last_insert_rowid();
}

fn namespaceFromStack(ctx: *const VisitCtx, buf: []u8) []const u8 {
    var pos: usize = 0;
    for (ctx.namespace_stack[0..ctx.namespace_stack_len], 0..) |ns, i| {
        if (i > 0) {
            if (pos + 2 > buf.len) return buf[0..pos];
            buf[pos] = ':';
            buf[pos + 1] = ':';
            pos += 2;
        }
        if (pos + ns.len > buf.len) return buf[0..pos];
        @memcpy(buf[pos..][0..ns.len], ns);
        pos += ns.len;
    }
    return buf[0..pos];
}

fn insertParam(db: db_mod.Db, symbol_id: i64, position: u32, name: []const u8, kind: []const u8, type_hint: ?[]const u8, confidence: u8) !void {
    const stmt = try db.prepare(
        \\INSERT INTO params (symbol_id, position, name, kind, type_hint, confidence)
        \\VALUES (?, ?, ?, ?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, symbol_id);
    stmt.bind_int(2, @intCast(position));
    stmt.bind_text(3, name);
    stmt.bind_text(4, kind);
    if (type_hint) |th| stmt.bind_text(5, th) else stmt.bind_null(5);
    stmt.bind_int(6, @intCast(confidence));
    _ = try stmt.step();
}

fn insertLocalVar(db: db_mod.Db, file_id: i64, name: []const u8, line: i32, col: u32, type_hint: ?[]const u8, confidence: u8, scope_id: ?i64) !void {
    const stmt = try db.prepare(
        \\INSERT INTO local_vars (file_id, name, line, col, type_hint, confidence, scope_id)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(file_id, name, line, col) DO UPDATE SET
        \\  type_hint = CASE WHEN excluded.confidence > local_vars.confidence THEN excluded.type_hint ELSE local_vars.type_hint END,
        \\  confidence = MAX(excluded.confidence, local_vars.confidence)
    );
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_text(2, name);
    stmt.bind_int(3, line);
    stmt.bind_int(4, @intCast(col));
    if (type_hint) |th| stmt.bind_text(5, th) else stmt.bind_null(5);
    stmt.bind_int(6, @intCast(confidence));
    if (scope_id) |sid| stmt.bind_int(7, sid) else stmt.bind_null(7);
    _ = try stmt.step();
}

fn insertLocalVarClassId(db: db_mod.Db, file_id: i64, name: []const u8, line: i32, col: u32, type_hint: ?[]const u8, confidence: u8, class_id: ?i64) !void {
    const stmt = try db.prepare(
        \\INSERT INTO local_vars (file_id, name, line, col, type_hint, confidence, class_id)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(file_id, name, line, col) DO UPDATE SET
        \\  type_hint = CASE WHEN excluded.confidence > local_vars.confidence THEN excluded.type_hint ELSE local_vars.type_hint END,
        \\  confidence = MAX(excluded.confidence, local_vars.confidence),
        \\  class_id = CASE WHEN excluded.class_id IS NOT NULL THEN excluded.class_id ELSE local_vars.class_id END
    );
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_text(2, name);
    stmt.bind_int(3, line);
    stmt.bind_int(4, @intCast(col));
    if (type_hint) |th| stmt.bind_text(5, th) else stmt.bind_null(5);
    stmt.bind_int(6, @intCast(confidence));
    if (class_id) |cid| stmt.bind_int(7, cid) else stmt.bind_null(7);
    _ = try stmt.step();
}

fn insertMixin(db: db_mod.Db, class_id: i64, module_name: []const u8, kind: []const u8) !void {
    const stmt = try db.prepare(
        \\INSERT INTO mixins (class_id, module_name, kind) VALUES (?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, class_id);
    stmt.bind_text(2, module_name);
    stmt.bind_text(3, kind);
    _ = try stmt.step();
}

fn findLastSorbetSig(slice: []const u8) ?[]const u8 {
    const brace_pos = std.mem.lastIndexOf(u8, slice, "sig {");
    const do_pos = std.mem.lastIndexOf(u8, slice, "sig do");
    var pick: usize = 0;
    var is_brace = true;
    if (brace_pos == null and do_pos == null) return null;
    if (brace_pos == null) {
        pick = do_pos.?;
        is_brace = false;
    } else if (do_pos == null) {
        pick = brace_pos.?;
    } else {
        if (brace_pos.? >= do_pos.?) {
            pick = brace_pos.?;
        } else {
            pick = do_pos.?;
            is_brace = false;
        }
    }
    if (pick > 0) {
        const prev = slice[pick - 1];
        const is_ident = (prev >= 'a' and prev <= 'z') or (prev >= 'A' and prev <= 'Z') or (prev >= '0' and prev <= '9') or prev == '_';
        if (is_ident) return null;
    }
    if (is_brace) {
        const lbrace = pick + 4;
        if (lbrace >= slice.len or slice[lbrace] != '{') return null;
        var depth: i32 = 0;
        var i: usize = lbrace;
        while (i < slice.len) : (i += 1) {
            switch (slice[i]) {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) return slice[lbrace + 1 .. i];
                },
                else => {},
            }
        }
    } else {
        const after_do = pick + 6;
        if (after_do >= slice.len) return null;
        if (std.mem.indexOf(u8, slice[after_do..], "end")) |end_rel| {
            return slice[after_do .. after_do + end_rel];
        }
    }
    return null;
}

fn findCallArgs(slice: []const u8, name: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, slice, search_from, name)) |pos| {
        const end = pos + name.len;
        if (end >= slice.len or slice[end] != '(') {
            search_from = pos + 1;
            continue;
        }
        if (pos > 0) {
            const prev = slice[pos - 1];
            const is_word = (prev >= 'a' and prev <= 'z') or (prev >= 'A' and prev <= 'Z') or (prev >= '0' and prev <= '9') or prev == '_';
            if (is_word) {
                search_from = pos + 1;
                continue;
            }
        }
        var depth: i32 = 0;
        var i = end;
        while (i < slice.len) : (i += 1) {
            switch (slice[i]) {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) return slice[end + 1 .. i];
                },
                else => {},
            }
        }
        search_from = pos + 1;
    }
    return null;
}

fn updateSorbetParamType(db: db_mod.Db, symbol_id: i64, param_name: []const u8, type_hint: []const u8) void {
    const u = db.prepare("UPDATE params SET type_hint=?, confidence=90 WHERE symbol_id=? AND name=?") catch return;
    defer u.finalize();
    u.bind_text(1, type_hint);
    u.bind_int(2, symbol_id);
    u.bind_text(3, param_name);
    _ = u.step() catch {};
}

fn parseSorbetParams(db: db_mod.Db, symbol_id: i64, body: []const u8) void {
    var start: usize = 0;
    var depth: i32 = 0;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        const at_end = i == body.len;
        if (!at_end) {
            switch (body[i]) {
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -= 1,
                else => {},
            }
        }
        if (at_end or (body[i] == ',' and depth == 0)) {
            const part = std.mem.trim(u8, body[start..i], " \t\n\r");
            if (part.len > 0) {
                if (std.mem.indexOfScalar(u8, part, ':')) |c| {
                    const pname = std.mem.trim(u8, part[0..c], " \t");
                    const ptype = std.mem.trim(u8, part[c + 1 ..], " \t\n\r");
                    if (pname.len > 0 and ptype.len > 0 and isRbsIdent(pname)) {
                        updateSorbetParamType(db, symbol_id, pname, ptype);
                    }
                }
            }
            start = i + 1;
        }
    }
}

fn resolveRbsSymbolId(db: db_mod.Db, file_id: i64, name: []const u8, kind: []const u8, line: i32) ?i64 {
    const stmt = db.prepare("SELECT id FROM symbols WHERE file_id=? AND name=? AND kind=? AND line=? LIMIT 1") catch return null;
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_text(2, name);
    stmt.bind_text(3, kind);
    stmt.bind_int(4, line);
    if (stmt.step() catch false) return stmt.column_int(0);
    return null;
}

fn isRbsIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (!((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_')) return false;
    }
    return true;
}

fn findTopLevelArrow(s: []const u8) ?usize {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            '-' => {
                if (depth == 0 and s[i + 1] == '>') return i;
            },
            else => {},
        }
    }
    return null;
}

fn findMatchingParen(s: []const u8, lpar: usize) ?usize {
    var depth: i32 = 0;
    var i: usize = lpar;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn insertOneRbsParam(db: db_mod.Db, symbol_id: i64, position: u32, part_in: []const u8) void {
    var rest = std.mem.trim(u8, part_in, " \t");
    if (rest.len == 0) return;
    var kind: []const u8 = "positional";
    if (std.mem.startsWith(u8, rest, "**")) {
        kind = "keyword_rest";
        rest = std.mem.trim(u8, rest[2..], " \t");
    } else if (rest[0] == '*') {
        kind = "rest";
        rest = std.mem.trim(u8, rest[1..], " \t");
    } else if (rest[0] == '&') {
        kind = "block";
        rest = std.mem.trim(u8, rest[1..], " \t");
    } else if (rest[0] == '?') {
        kind = "optional";
        rest = std.mem.trim(u8, rest[1..], " \t");
    }

    var name_part: []const u8 = "";
    var type_part: []const u8 = rest;
    var depth: i32 = 0;
    var j: usize = 0;
    while (j < rest.len) : (j += 1) {
        const c = rest[j];
        switch (c) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            ':' => {
                if (depth == 0) {
                    if (j + 1 < rest.len and rest[j + 1] == ':') {
                        j += 1;
                        continue;
                    }
                    if (j > 0 and rest[j - 1] == ':') continue;
                    const maybe_name = std.mem.trim(u8, rest[0..j], " \t");
                    if (isRbsIdent(maybe_name)) {
                        name_part = maybe_name;
                        type_part = std.mem.trim(u8, rest[j + 1 ..], " \t");
                        if (std.mem.eql(u8, kind, "positional") or std.mem.eql(u8, kind, "optional")) {
                            kind = if (std.mem.eql(u8, kind, "optional")) "keyword" else "keyword";
                        }
                    }
                    break;
                }
            },
            else => {},
        }
    }

    // Positional form `Type name`: last whitespace-separated token is the name if it's a lowercase ident.
    if (name_part.len == 0 and type_part.len > 0) {
        if (std.mem.lastIndexOfAny(u8, type_part, " \t")) |ws| {
            const trailing = std.mem.trim(u8, type_part[ws + 1 ..], " \t");
            if (isRbsIdent(trailing) and trailing.len > 0 and trailing[0] >= 'a' and trailing[0] <= 'z') {
                name_part = trailing;
                type_part = std.mem.trim(u8, type_part[0..ws], " \t");
            }
        }
    }

    var name_buf: [32]u8 = undefined;
    const name_final: []const u8 = if (name_part.len > 0)
        name_part
    else
        std.fmt.bufPrint(&name_buf, "arg{d}", .{position}) catch "arg";
    const type_hint: ?[]const u8 = if (type_part.len > 0) type_part else null;
    insertParam(db, symbol_id, position, name_final, kind, type_hint, 90) catch {};
}

fn parseRbsParamList(db: db_mod.Db, symbol_id: i64, param_list: []const u8) void {
    var position: u32 = 0;
    var start: usize = 0;
    var depth: i32 = 0;
    var i: usize = 0;
    while (i <= param_list.len) : (i += 1) {
        const at_end = i == param_list.len;
        if (!at_end) {
            switch (param_list[i]) {
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -= 1,
                else => {},
            }
        }
        if (at_end or (param_list[i] == ',' and depth == 0)) {
            const part = param_list[start..i];
            if (std.mem.trim(u8, part, " \t").len > 0) {
                insertOneRbsParam(db, symbol_id, position, part);
                position += 1;
            }
            start = i + 1;
        }
    }
}

fn setRbsDoc(db: db_mod.Db, sym_id: i64, doc: []const u8) void {
    if (doc.len == 0) return;
    const upd = db.prepare("UPDATE symbols SET doc = ? WHERE id = ? AND (doc IS NULL OR doc = '')") catch return;
    defer upd.finalize();
    upd.bind_text(1, doc);
    upd.bind_int(2, sym_id);
    _ = upd.step() catch {};
}

fn insertRbsSymbol(db: db_mod.Db, file_id: i64, kind: []const u8, name: []const u8, line: i32, col: u32, parent_name: ?[]const u8) !void {
    const stmt = try db.prepare(
        \\INSERT OR IGNORE INTO symbols (file_id, name, kind, line, col, parent_name)
        \\VALUES (?, ?, ?, ?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_text(2, name);
    stmt.bind_text(3, kind);
    stmt.bind_int(4, line);
    stmt.bind_int(5, @intCast(col));
    if (parent_name) |pn| stmt.bind_text(6, pn) else stmt.bind_null(6);
    _ = try stmt.step();
}

fn insertRbsSymbolWithReturn(db: db_mod.Db, file_id: i64, kind: []const u8, name: []const u8, line: i32, col: u32, return_type: []const u8, parent_name: ?[]const u8) !void {
    const check = try db.prepare(
        \\SELECT id, return_type FROM symbols
        \\WHERE file_id = ? AND name = ? AND kind = ?
    );
    defer check.finalize();
    check.bind_int(1, file_id);
    check.bind_text(2, name);
    check.bind_text(3, kind);

    if (try check.step()) {
        const existing_rt = check.column_text(1);
        if (std.mem.eql(u8, existing_rt, return_type)) return;
        var dedup_it = std.mem.splitSequence(u8, existing_rt, " | ");
        var already_present = false;
        while (dedup_it.next()) |part| {
            if (std.mem.eql(u8, part, return_type)) {
                already_present = true;
                break;
            }
        }
        if (already_present) return;
        const id = check.column_int(0);
        var buf: [512]u8 = undefined;
        const aggregated = std.fmt.bufPrint(&buf, "{s} | {s}", .{ existing_rt, return_type }) catch return;
        const upd = try db.prepare("UPDATE symbols SET return_type = ? WHERE id = ?");
        defer upd.finalize();
        upd.bind_text(1, aggregated);
        upd.bind_int(2, id);
        _ = try upd.step();
        return;
    }

    const stmt = try db.prepare(
        \\INSERT OR IGNORE INTO symbols (file_id, name, kind, line, col, return_type, parent_name)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_text(2, name);
    stmt.bind_text(3, kind);
    stmt.bind_int(4, line);
    stmt.bind_int(5, @intCast(col));
    stmt.bind_text(6, return_type);
    if (parent_name) |pn| stmt.bind_text(7, pn) else stmt.bind_null(7);
    _ = try stmt.step();
}

fn indexRbs(db: db_mod.Db, file_id: i64, source: []const u8) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_num: i32 = 1;
    var ns_stack: [32][]const u8 = undefined;
    var ns_indent: [32]usize = undefined;
    var ns_depth: u8 = 0;
    var ns_buf: [512]u8 = undefined;
    var doc_buf: [2048]u8 = undefined;
    var doc_len: usize = 0;

    while (lines.next()) |raw_line| : (line_num += 1) {
        const indent = raw_line.len - std.mem.trimStart(u8, raw_line, " \t").len;
        const line = std.mem.trim(u8, raw_line, " \t");

        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#")) {
            var content = line[1..];
            if (content.len > 0 and content[0] == ' ') content = content[1..];
            if (doc_len + content.len + 1 < doc_buf.len) {
                if (doc_len > 0) {
                    doc_buf[doc_len] = '\n';
                    doc_len += 1;
                }
                @memcpy(doc_buf[doc_len..][0..content.len], content);
                doc_len += content.len;
            }
            continue;
        }

        if (std.mem.eql(u8, line, "end")) {
            if (ns_depth > 0 and indent == ns_indent[ns_depth - 1]) ns_depth -= 1;
            doc_len = 0;
            continue;
        }

        if (std.mem.startsWith(u8, line, "class ") or std.mem.startsWith(u8, line, "module ")) {
            const kw_len: usize = if (line[0] == 'c') 6 else 7;
            const name_end = std.mem.indexOfScalar(u8, line[kw_len..], ' ') orelse line.len - kw_len;
            const name = line[kw_len .. kw_len + name_end];
            if (name.len == 0) continue;
            const kind: []const u8 = if (line[0] == 'c') "class" else "module";
            if (ns_depth < 32) {
                ns_stack[ns_depth] = name;
                ns_indent[ns_depth] = indent;
                ns_depth += 1;
            }
            insertRbsSymbol(db, file_id, kind, name, line_num, 0, null) catch |e| {
                std.debug.print("{s}", .{"refract: RBS insert: "});
                std.debug.print("{s}", .{@errorName(e)});
                std.debug.print("{s}", .{"\n"});
            };
            if (doc_len > 0) {
                if (resolveRbsSymbolId(db, file_id, name, kind, line_num)) |sid| {
                    setRbsDoc(db, sid, doc_buf[0..doc_len]);
                }
                doc_len = 0;
            }
            continue;
        }

        // Compute current parent name from namespace stack
        const current_parent: ?[]const u8 = if (ns_depth > 0) blk: {
            var pos: usize = 0;
            for (ns_stack[0..ns_depth], 0..) |ns, ni| {
                if (ni > 0) {
                    if (pos + 2 <= ns_buf.len) {
                        ns_buf[pos] = ':';
                        ns_buf[pos + 1] = ':';
                        pos += 2;
                    }
                }
                if (pos + ns.len <= ns_buf.len) {
                    @memcpy(ns_buf[pos..][0..ns.len], ns);
                    pos += ns.len;
                }
            }
            break :blk ns_buf[0..pos];
        } else null;

        if (std.mem.startsWith(u8, line, "def ")) {
            const rest = line[4..];
            const colon_pos = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
            const name = std.mem.trim(u8, rest[0..colon_pos], " ");
            if (name.len == 0) continue;
            const sig_part = rest[colon_pos + 1 ..];

            // RBS self.method → classdef kind, strip "self." prefix
            const is_class_method = std.mem.startsWith(u8, name, "self.");
            const def_kind: []const u8 = if (is_class_method) "classdef" else "def";
            const def_name = if (is_class_method) name[5..] else name;

            const arrow_opt = findTopLevelArrow(sig_part);
            if (arrow_opt == null) {
                insertRbsSymbol(db, file_id, def_kind, def_name, line_num, 0, current_parent) catch |e| {
                    std.debug.print("{s}", .{"refract: RBS insert: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
                };
                continue;
            }
            const arrow_pos = arrow_opt.?;
            const raw_rt = std.mem.trim(u8, sig_part[arrow_pos + 2 ..], " ");
            const rt = normalizeRbsReturn(raw_rt);
            if (rt.len > 0 and !std.mem.eql(u8, rt, "void")) {
                insertRbsSymbolWithReturn(db, file_id, def_kind, def_name, line_num, 0, rt, current_parent) catch |e| {
                    std.debug.print("{s}", .{"refract: RBS insert: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
                };
            } else {
                insertRbsSymbol(db, file_id, def_kind, def_name, line_num, 0, current_parent) catch |e| {
                    std.debug.print("{s}", .{"refract: RBS insert: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
                };
            }

            const before_arrow = sig_part[0..arrow_pos];
            if (std.mem.indexOfScalar(u8, before_arrow, '(')) |lpar| {
                if (findMatchingParen(before_arrow, lpar)) |rpar| {
                    const param_list = before_arrow[lpar + 1 .. rpar];
                    if (resolveRbsSymbolId(db, file_id, name, "def", line_num)) |sid| {
                        parseRbsParamList(db, sid, param_list);
                    }
                }
            }
            if (doc_len > 0) {
                if (resolveRbsSymbolId(db, file_id, def_name, def_kind, line_num)) |sid| {
                    setRbsDoc(db, sid, doc_buf[0..doc_len]);
                }
                doc_len = 0;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "interface ")) {
            const rest = line["interface ".len..];
            const end = std.mem.indexOfAny(u8, rest, " \t\r\n{") orelse rest.len;
            const name = std.mem.trim(u8, rest[0..end], " \t");
            if (name.len > 0)
                insertRbsSymbol(db, file_id, "module", name, line_num, 0, current_parent) catch |e| {
                    std.debug.print("{s}", .{"refract: RBS insert: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
                };
            continue;
        }

        if (std.mem.startsWith(u8, line, "type ")) {
            const rest = line["type ".len..];
            const end = std.mem.indexOfAny(u8, rest, " \t\r\n=") orelse rest.len;
            const name = std.mem.trim(u8, rest[0..end], " \t");
            if (name.len > 0)
                insertRbsSymbol(db, file_id, "constant", name, line_num, 0, current_parent) catch |e| {
                    std.debug.print("{s}", .{"refract: RBS insert: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
                };
            continue;
        }

        if (std.mem.startsWith(u8, line, "attr_reader ") or
            std.mem.startsWith(u8, line, "attr_writer ") or
            std.mem.startsWith(u8, line, "attr_accessor "))
        {
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const rest = line[sp + 1 ..];
            const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
            const attr_name = std.mem.trim(u8, rest[0..colon], " ");
            if (attr_name.len == 0) continue;
            const raw_attr_rt = std.mem.trim(u8, rest[colon + 1 ..], " ");
            const rt = normalizeRbsReturn(raw_attr_rt);
            if (!std.mem.startsWith(u8, line, "attr_writer ")) {
                insertRbsSymbolWithReturn(db, file_id, "def", attr_name, line_num, 0, rt, current_parent) catch |e| {
                    std.debug.print("{s}", .{"refract: RBS insert: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
                };
            }
            if (std.mem.startsWith(u8, line, "attr_writer ") or
                std.mem.startsWith(u8, line, "attr_accessor "))
            {
                var writer_buf: [256]u8 = undefined;
                const writer_name = std.fmt.bufPrint(&writer_buf, "{s}=", .{attr_name}) catch continue;
                insertRbsSymbol(db, file_id, "def", writer_name, line_num, 0, current_parent) catch |e| {
                    std.debug.print("{s}", .{"refract: RBS insert: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
                };
            }
            continue;
        }
    }
}

fn storeSemTokens(db: db_mod.Db, file_id: i64, tokens: []const SemToken, alloc: std.mem.Allocator) !void {
    if (tokens.len == 0) {
        const del = try db.prepare("DELETE FROM sem_tokens WHERE file_id = ?");
        defer del.finalize();
        del.bind_int(1, file_id);
        _ = try del.step();
        return;
    }

    // Sort by (line, col)
    const sorted = try alloc.dupe(SemToken, tokens);
    defer alloc.free(sorted);
    std.sort.block(SemToken, sorted, {}, struct {
        fn lt(_: void, a: SemToken, b: SemToken) bool {
            if (a.line != b.line) return a.line < b.line;
            return a.col < b.col;
        }
    }.lt);

    // Delta-encode into u32 array
    const blob = try alloc.alloc(u32, sorted.len * 5);
    defer alloc.free(blob);

    var prev_line: u32 = 0;
    var prev_col: u32 = 0;
    for (sorted, 0..) |tok, i| {
        const lsp_line = tok.line - 1; // convert to 0-based
        const delta_line = lsp_line - prev_line;
        const delta_col = if (delta_line == 0) tok.col - prev_col else tok.col;
        blob[i * 5 + 0] = delta_line;
        blob[i * 5 + 1] = delta_col;
        blob[i * 5 + 2] = tok.len;
        blob[i * 5 + 3] = tok.token_type;
        blob[i * 5 + 4] = tok.mods;
        prev_line = lsp_line;
        prev_col = tok.col;
    }

    // Pack as LE bytes
    const bytes = try alloc.alloc(u8, blob.len * 4);
    defer alloc.free(bytes);
    for (blob, 0..) |v, i| {
        std.mem.writeInt(u32, bytes[i * 4 ..][0..4], v, .little);
    }

    const stmt = try db.prepare(
        \\INSERT INTO sem_tokens (file_id, prev_blob, blob)
        \\VALUES (?, (SELECT blob FROM sem_tokens WHERE file_id=?), ?)
        \\ON CONFLICT(file_id) DO UPDATE SET
        \\  prev_blob=excluded.prev_blob, blob=excluded.blob
    );
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_int(2, file_id);
    stmt.bind_blob(3, bytes);
    _ = try stmt.step();
}

pub const DiagEntry = struct {
    line: i32,
    col: u32,
    message: []u8,
    severity: u8 = 1,
    source: []const u8 = "refract",
    end_col: u32 = 0,
    code: []const u8 = "",
};

pub fn lookupStdlibReturn(class_name: []const u8, method_name: []const u8) ?[]const u8 {
    // Array-of-T unwrapping: [User].first → User, [User].count → Integer, etc.
    if (class_name.len > 2 and class_name[0] == '[' and class_name[class_name.len - 1] == ']') {
        const inner = class_name[1 .. class_name.len - 1];
        if (std.mem.eql(u8, method_name, "first") or std.mem.eql(u8, method_name, "last") or
            std.mem.eql(u8, method_name, "find") or std.mem.eql(u8, method_name, "take") or
            std.mem.eql(u8, method_name, "sample")) return inner;
        if (std.mem.eql(u8, method_name, "count") or std.mem.eql(u8, method_name, "size") or
            std.mem.eql(u8, method_name, "length")) return "Integer";
        if (std.mem.eql(u8, method_name, "empty?") or std.mem.eql(u8, method_name, "any?") or
            std.mem.eql(u8, method_name, "all?") or std.mem.eql(u8, method_name, "none?")) return "TrueClass";
        if (std.mem.eql(u8, method_name, "where") or std.mem.eql(u8, method_name, "order") or
            std.mem.eql(u8, method_name, "limit") or std.mem.eql(u8, method_name, "includes") or
            std.mem.eql(u8, method_name, "joins") or std.mem.eql(u8, method_name, "select") or
            std.mem.eql(u8, method_name, "preload") or std.mem.eql(u8, method_name, "eager_load") or
            std.mem.eql(u8, method_name, "distinct") or std.mem.eql(u8, method_name, "group") or
            std.mem.eql(u8, method_name, "having") or std.mem.eql(u8, method_name, "reorder") or
            std.mem.eql(u8, method_name, "rewhere") or std.mem.eql(u8, method_name, "unscoped") or
            std.mem.eql(u8, method_name, "scoped")) return class_name;
        if (std.mem.eql(u8, method_name, "map") or std.mem.eql(u8, method_name, "collect") or
            std.mem.eql(u8, method_name, "flat_map") or std.mem.eql(u8, method_name, "reject") or
            std.mem.eql(u8, method_name, "filter")) return "Array";
        if (std.mem.eql(u8, method_name, "to_a") or std.mem.eql(u8, method_name, "all")) return "Array";
        return null;
    }
    if (std.mem.startsWith(u8, class_name, "Array[") and class_name[class_name.len - 1] == ']') {
        const inner_type = class_name[6 .. class_name.len - 1];
        if (std.mem.eql(u8, method_name, "first") or std.mem.eql(u8, method_name, "last") or
            std.mem.eql(u8, method_name, "sample") or std.mem.eql(u8, method_name, "min") or
            std.mem.eql(u8, method_name, "max")) return inner_type;
        if (std.mem.eql(u8, method_name, "flatten") or std.mem.eql(u8, method_name, "compact") or
            std.mem.eql(u8, method_name, "uniq") or std.mem.eql(u8, method_name, "sort") or
            std.mem.eql(u8, method_name, "reverse") or std.mem.eql(u8, method_name, "shuffle")) return class_name;
        if (std.mem.eql(u8, method_name, "count") or std.mem.eql(u8, method_name, "size") or
            std.mem.eql(u8, method_name, "length")) return "Integer";
        if (std.mem.eql(u8, method_name, "empty?") or std.mem.eql(u8, method_name, "any?") or
            std.mem.eql(u8, method_name, "all?") or std.mem.eql(u8, method_name, "none?") or
            std.mem.eql(u8, method_name, "include?")) return "TrueClass";
        if (std.mem.eql(u8, method_name, "join")) return "String";
        if (std.mem.eql(u8, method_name, "to_a")) return class_name;
        return null;
    }
    if (std.mem.eql(u8, class_name, "String")) {
        if (std.mem.eql(u8, method_name, "upcase") or
            std.mem.eql(u8, method_name, "downcase") or
            std.mem.eql(u8, method_name, "strip") or
            std.mem.eql(u8, method_name, "lstrip") or
            std.mem.eql(u8, method_name, "rstrip") or
            std.mem.eql(u8, method_name, "chomp") or
            std.mem.eql(u8, method_name, "chop") or
            std.mem.eql(u8, method_name, "gsub") or
            std.mem.eql(u8, method_name, "sub") or
            std.mem.eql(u8, method_name, "capitalize") or
            std.mem.eql(u8, method_name, "swapcase") or
            std.mem.eql(u8, method_name, "reverse") or
            std.mem.eql(u8, method_name, "squeeze") or
            std.mem.eql(u8, method_name, "delete") or
            std.mem.eql(u8, method_name, "encode") or
            std.mem.eql(u8, method_name, "tr") or
            std.mem.eql(u8, method_name, "center") or
            std.mem.eql(u8, method_name, "ljust") or
            std.mem.eql(u8, method_name, "rjust") or
            std.mem.eql(u8, method_name, "concat") or
            std.mem.eql(u8, method_name, "prepend") or
            std.mem.eql(u8, method_name, "slice") or
            std.mem.eql(u8, method_name, "freeze") or
            std.mem.eql(u8, method_name, "to_s")) return "String";
        if (std.mem.eql(u8, method_name, "to_i") or
            std.mem.eql(u8, method_name, "length") or
            std.mem.eql(u8, method_name, "size") or
            std.mem.eql(u8, method_name, "count") or
            std.mem.eql(u8, method_name, "bytesize") or
            std.mem.eql(u8, method_name, "hex") or
            std.mem.eql(u8, method_name, "oct")) return "Integer";
        if (std.mem.eql(u8, method_name, "to_f")) return "Float";
        if (std.mem.eql(u8, method_name, "to_sym")) return "Symbol";
        if (std.mem.eql(u8, method_name, "split") or
            std.mem.eql(u8, method_name, "chars") or
            std.mem.eql(u8, method_name, "bytes") or
            std.mem.eql(u8, method_name, "scan") or
            std.mem.eql(u8, method_name, "lines")) return "Array";
        if (std.mem.eql(u8, method_name, "empty?") or
            std.mem.eql(u8, method_name, "include?") or
            std.mem.eql(u8, method_name, "start_with?") or
            std.mem.eql(u8, method_name, "end_with?") or
            std.mem.eql(u8, method_name, "match?") or
            std.mem.eql(u8, method_name, "valid_encoding?")) return "TrueClass";
    }
    if (std.mem.eql(u8, class_name, "Integer") or
        std.mem.eql(u8, class_name, "Numeric"))
    {
        if (std.mem.eql(u8, method_name, "to_s") or
            std.mem.eql(u8, method_name, "inspect") or
            std.mem.eql(u8, method_name, "chr")) return "String";
        if (std.mem.eql(u8, method_name, "to_f")) return "Float";
        if (std.mem.eql(u8, method_name, "to_i") or
            std.mem.eql(u8, method_name, "abs") or
            std.mem.eql(u8, method_name, "ceil") or
            std.mem.eql(u8, method_name, "floor") or
            std.mem.eql(u8, method_name, "round") or
            std.mem.eql(u8, method_name, "truncate") or
            std.mem.eql(u8, method_name, "times") or
            std.mem.eql(u8, method_name, "gcd") or
            std.mem.eql(u8, method_name, "lcm") or
            std.mem.eql(u8, method_name, "next") or
            std.mem.eql(u8, method_name, "succ") or
            std.mem.eql(u8, method_name, "pred") or
            std.mem.eql(u8, method_name, "upto") or
            std.mem.eql(u8, method_name, "downto")) return "Integer";
        if (std.mem.eql(u8, method_name, "digits") or
            std.mem.eql(u8, method_name, "divmod")) return "Array";
        if (std.mem.eql(u8, method_name, "zero?") or
            std.mem.eql(u8, method_name, "odd?") or
            std.mem.eql(u8, method_name, "even?") or
            std.mem.eql(u8, method_name, "positive?") or
            std.mem.eql(u8, method_name, "negative?") or
            std.mem.eql(u8, method_name, "between?")) return "TrueClass";
    }
    if (std.mem.eql(u8, class_name, "Float")) {
        if (std.mem.eql(u8, method_name, "to_i") or
            std.mem.eql(u8, method_name, "ceil") or
            std.mem.eql(u8, method_name, "floor") or
            std.mem.eql(u8, method_name, "round") or
            std.mem.eql(u8, method_name, "truncate")) return "Integer";
        if (std.mem.eql(u8, method_name, "to_f") or
            std.mem.eql(u8, method_name, "abs")) return "Float";
        if (std.mem.eql(u8, method_name, "to_s") or
            std.mem.eql(u8, method_name, "inspect")) return "String";
        if (std.mem.eql(u8, method_name, "positive?") or
            std.mem.eql(u8, method_name, "negative?") or
            std.mem.eql(u8, method_name, "zero?") or
            std.mem.eql(u8, method_name, "finite?") or
            std.mem.eql(u8, method_name, "nan?") or
            std.mem.eql(u8, method_name, "infinite?")) return "TrueClass";
    }
    if (std.mem.eql(u8, class_name, "Array")) {
        if (std.mem.eql(u8, method_name, "length") or
            std.mem.eql(u8, method_name, "size") or
            std.mem.eql(u8, method_name, "count") or
            std.mem.eql(u8, method_name, "sum")) return "Integer";
        if (std.mem.eql(u8, method_name, "join")) return "String";
        if (std.mem.eql(u8, method_name, "empty?") or
            std.mem.eql(u8, method_name, "include?") or
            std.mem.eql(u8, method_name, "any?") or
            std.mem.eql(u8, method_name, "all?") or
            std.mem.eql(u8, method_name, "none?") or
            std.mem.eql(u8, method_name, "one?")) return "TrueClass";
        if (std.mem.eql(u8, method_name, "flatten") or
            std.mem.eql(u8, method_name, "compact") or
            std.mem.eql(u8, method_name, "uniq") or
            std.mem.eql(u8, method_name, "sort") or
            std.mem.eql(u8, method_name, "reverse") or
            std.mem.eql(u8, method_name, "map") or
            std.mem.eql(u8, method_name, "collect") or
            std.mem.eql(u8, method_name, "entries") or
            std.mem.eql(u8, method_name, "select") or
            std.mem.eql(u8, method_name, "filter") or
            std.mem.eql(u8, method_name, "reject") or
            std.mem.eql(u8, method_name, "push") or
            std.mem.eql(u8, method_name, "pop") or
            std.mem.eql(u8, method_name, "shift") or
            std.mem.eql(u8, method_name, "unshift") or
            std.mem.eql(u8, method_name, "append") or
            std.mem.eql(u8, method_name, "prepend") or
            std.mem.eql(u8, method_name, "shuffle") or
            std.mem.eql(u8, method_name, "rotate") or
            std.mem.eql(u8, method_name, "intersection") or
            std.mem.eql(u8, method_name, "union") or
            std.mem.eql(u8, method_name, "difference") or
            std.mem.eql(u8, method_name, "product") or
            std.mem.eql(u8, method_name, "combination") or
            std.mem.eql(u8, method_name, "permutation") or
            std.mem.eql(u8, method_name, "flat_map") or
            std.mem.eql(u8, method_name, "filter_map") or
            std.mem.eql(u8, method_name, "each_slice") or
            std.mem.eql(u8, method_name, "each_cons")) return "Array";
        if (std.mem.eql(u8, method_name, "tally") or
            std.mem.eql(u8, method_name, "to_h")) return "Hash";
    }
    if (std.mem.eql(u8, class_name, "Hash") or std.mem.startsWith(u8, class_name, "Hash[")) {
        if (std.mem.eql(u8, method_name, "keys")) {
            if (extractHashGenerics(class_name)) |g| {
                return std.fmt.bufPrint(&generic_return_buf, "Array[{s}]", .{g.key}) catch "Array";
            }
            return "Array";
        }
        if (std.mem.eql(u8, method_name, "values")) {
            if (extractHashGenerics(class_name)) |g| {
                return std.fmt.bufPrint(&generic_return_buf, "Array[{s}]", .{g.value}) catch "Array";
            }
            return "Array";
        }
        if (std.mem.eql(u8, method_name, "fetch") or std.mem.eql(u8, method_name, "[]") or std.mem.eql(u8, method_name, "dig")) {
            if (extractHashGenerics(class_name)) |g| return g.value;
            return null;
        }
        if (std.mem.eql(u8, method_name, "to_a") or
            std.mem.eql(u8, method_name, "map") or
            std.mem.eql(u8, method_name, "flat_map")) return "Array";
        if (std.mem.eql(u8, method_name, "length") or
            std.mem.eql(u8, method_name, "size") or
            std.mem.eql(u8, method_name, "count")) return "Integer";
        if (std.mem.eql(u8, method_name, "empty?") or
            std.mem.eql(u8, method_name, "has_key?") or
            std.mem.eql(u8, method_name, "include?") or
            std.mem.eql(u8, method_name, "key?") or
            std.mem.eql(u8, method_name, "any?") or
            std.mem.eql(u8, method_name, "all?") or
            std.mem.eql(u8, method_name, "none?")) return "TrueClass";
        if (std.mem.eql(u8, method_name, "select") or
            std.mem.eql(u8, method_name, "filter") or
            std.mem.eql(u8, method_name, "reject") or
            std.mem.eql(u8, method_name, "merge") or
            std.mem.eql(u8, method_name, "merge!") or
            std.mem.eql(u8, method_name, "transform_values") or
            std.mem.eql(u8, method_name, "transform_keys") or
            std.mem.eql(u8, method_name, "invert") or
            std.mem.eql(u8, method_name, "compact") or
            std.mem.eql(u8, method_name, "slice") or
            std.mem.eql(u8, method_name, "except") or
            std.mem.eql(u8, method_name, "update") or
            std.mem.eql(u8, method_name, "each_with_object") or
            std.mem.eql(u8, method_name, "group_by") or
            std.mem.eql(u8, method_name, "each_key") or
            std.mem.eql(u8, method_name, "each_value") or
            std.mem.eql(u8, method_name, "each_pair")) return "Hash";
        if (std.mem.eql(u8, method_name, "to_s")) return "String";
    }
    if (std.mem.eql(u8, class_name, "Symbol")) {
        if (std.mem.eql(u8, method_name, "to_s") or
            std.mem.eql(u8, method_name, "id2name") or
            std.mem.eql(u8, method_name, "name") or
            std.mem.eql(u8, method_name, "inspect")) return "String";
        if (std.mem.eql(u8, method_name, "to_sym") or
            std.mem.eql(u8, method_name, "upcase") or
            std.mem.eql(u8, method_name, "downcase")) return "Symbol";
        if (std.mem.eql(u8, method_name, "to_proc")) return "Proc";
        if (std.mem.eql(u8, method_name, "length") or
            std.mem.eql(u8, method_name, "size")) return "Integer";
        if (std.mem.eql(u8, method_name, "match?") or
            std.mem.eql(u8, method_name, "empty?")) return "TrueClass";
        if (std.mem.eql(u8, method_name, "match")) return "MatchData";
    }
    if (std.mem.eql(u8, class_name, "Regexp")) {
        if (std.mem.eql(u8, method_name, "match")) return "MatchData";
        if (std.mem.eql(u8, method_name, "source") or
            std.mem.eql(u8, method_name, "inspect") or
            std.mem.eql(u8, method_name, "to_s")) return "String";
        if (std.mem.eql(u8, method_name, "match?") or
            std.mem.eql(u8, method_name, "casefold?")) return "TrueClass";
        if (std.mem.eql(u8, method_name, "names") or
            std.mem.eql(u8, method_name, "named_captures")) return "Array";
        if (std.mem.eql(u8, method_name, "options")) return "Integer";
    }
    if (std.mem.eql(u8, class_name, "MatchData")) {
        if (std.mem.eql(u8, method_name, "to_s") or
            std.mem.eql(u8, method_name, "string") or
            std.mem.eql(u8, method_name, "pre_match") or
            std.mem.eql(u8, method_name, "post_match") or
            std.mem.eql(u8, method_name, "inspect")) return "String";
        if (std.mem.eql(u8, method_name, "captures") or
            std.mem.eql(u8, method_name, "to_a") or
            std.mem.eql(u8, method_name, "names")) return "Array";
        if (std.mem.eql(u8, method_name, "named_captures")) return "Hash";
        if (std.mem.eql(u8, method_name, "length") or
            std.mem.eql(u8, method_name, "size")) return "Integer";
        if (std.mem.eql(u8, method_name, "regexp")) return "Regexp";
    }
    if (std.mem.eql(u8, class_name, "File") or std.mem.eql(u8, class_name, "IO")) {
        if (std.mem.eql(u8, method_name, "read") or
            std.mem.eql(u8, method_name, "gets") or
            std.mem.eql(u8, method_name, "readline") or
            std.mem.eql(u8, method_name, "chomp") or
            std.mem.eql(u8, method_name, "to_s") or
            std.mem.eql(u8, method_name, "path") or
            std.mem.eql(u8, method_name, "inspect")) return "String";
        if (std.mem.eql(u8, method_name, "readlines") or
            std.mem.eql(u8, method_name, "each_line")) return "Array";
        if (std.mem.eql(u8, method_name, "size") or
            std.mem.eql(u8, method_name, "pos") or
            std.mem.eql(u8, method_name, "lineno") or
            std.mem.eql(u8, method_name, "fileno")) return "Integer";
        if (std.mem.eql(u8, method_name, "exist?") or
            std.mem.eql(u8, method_name, "file?") or
            std.mem.eql(u8, method_name, "directory?") or
            std.mem.eql(u8, method_name, "readable?") or
            std.mem.eql(u8, method_name, "writable?") or
            std.mem.eql(u8, method_name, "eof?") or
            std.mem.eql(u8, method_name, "closed?")) return "TrueClass";
        if (std.mem.eql(u8, method_name, "stat")) return "File::Stat";
    }
    if (std.mem.eql(u8, class_name, "Time") or std.mem.eql(u8, class_name, "Date") or
        std.mem.eql(u8, class_name, "DateTime"))
    {
        if (std.mem.eql(u8, method_name, "now") or
            std.mem.eql(u8, method_name, "today") or
            std.mem.eql(u8, method_name, "current") or
            std.mem.eql(u8, method_name, "new") or
            std.mem.eql(u8, method_name, "parse") or
            std.mem.eql(u8, method_name, "utc") or
            std.mem.eql(u8, method_name, "at") or
            std.mem.eql(u8, method_name, "yesterday") or
            std.mem.eql(u8, method_name, "tomorrow") or
            std.mem.eql(u8, method_name, "beginning_of_day") or
            std.mem.eql(u8, method_name, "end_of_day") or
            std.mem.eql(u8, method_name, "beginning_of_month") or
            std.mem.eql(u8, method_name, "end_of_month") or
            std.mem.eql(u8, method_name, "beginning_of_year") or
            std.mem.eql(u8, method_name, "ago") or
            std.mem.eql(u8, method_name, "since") or
            std.mem.eql(u8, method_name, "in_time_zone") or
            std.mem.eql(u8, method_name, "change") or
            std.mem.eql(u8, method_name, "advance")) return class_name;
        if (std.mem.eql(u8, method_name, "to_s") or
            std.mem.eql(u8, method_name, "strftime") or
            std.mem.eql(u8, method_name, "iso8601") or
            std.mem.eql(u8, method_name, "httpdate") or
            std.mem.eql(u8, method_name, "rfc2822") or
            std.mem.eql(u8, method_name, "to_formatted_s") or
            std.mem.eql(u8, method_name, "inspect")) return "String";
        if (std.mem.eql(u8, method_name, "to_i") or
            std.mem.eql(u8, method_name, "to_r") or
            std.mem.eql(u8, method_name, "year") or
            std.mem.eql(u8, method_name, "month") or
            std.mem.eql(u8, method_name, "day") or
            std.mem.eql(u8, method_name, "hour") or
            std.mem.eql(u8, method_name, "min") or
            std.mem.eql(u8, method_name, "sec") or
            std.mem.eql(u8, method_name, "wday") or
            std.mem.eql(u8, method_name, "yday") or
            std.mem.eql(u8, method_name, "usec") or
            std.mem.eql(u8, method_name, "nsec")) return "Integer";
        if (std.mem.eql(u8, method_name, "to_f")) return "Float";
        if (std.mem.eql(u8, method_name, "to_date")) return "Date";
        if (std.mem.eql(u8, method_name, "to_time")) return "Time";
        if (std.mem.eql(u8, method_name, "to_datetime")) return "DateTime";
        if (std.mem.eql(u8, method_name, "zone")) return "String";
        if (std.mem.eql(u8, method_name, "dst?") or
            std.mem.eql(u8, method_name, "utc?") or
            std.mem.eql(u8, method_name, "future?") or
            std.mem.eql(u8, method_name, "past?") or
            std.mem.eql(u8, method_name, "today?") or
            std.mem.eql(u8, method_name, "saturday?") or
            std.mem.eql(u8, method_name, "sunday?") or
            std.mem.eql(u8, method_name, "on_weekday?") or
            std.mem.eql(u8, method_name, "on_weekend?")) return "TrueClass";
    }
    if (std.mem.eql(u8, class_name, "Enumerator")) {
        if (std.mem.eql(u8, method_name, "to_a") or
            std.mem.eql(u8, method_name, "entries")) return "Array";
        if (std.mem.eql(u8, method_name, "size") or
            std.mem.eql(u8, method_name, "count")) return "Integer";
        if (std.mem.eql(u8, method_name, "inspect") or
            std.mem.eql(u8, method_name, "to_s")) return "String";
    }
    if (std.mem.eql(u8, class_name, "Range")) {
        if (std.mem.eql(u8, method_name, "to_a") or
            std.mem.eql(u8, method_name, "entries")) return "Array";
        if (std.mem.eql(u8, method_name, "size") or
            std.mem.eql(u8, method_name, "count") or
            std.mem.eql(u8, method_name, "min") or
            std.mem.eql(u8, method_name, "max")) return "Integer";
        if (std.mem.eql(u8, method_name, "to_s") or
            std.mem.eql(u8, method_name, "inspect")) return "String";
        if (std.mem.eql(u8, method_name, "include?") or
            std.mem.eql(u8, method_name, "cover?") or
            std.mem.eql(u8, method_name, "any?") or
            std.mem.eql(u8, method_name, "none?") or
            std.mem.eql(u8, method_name, "exclude_end?")) return "TrueClass";
    }
    if (std.mem.eql(u8, class_name, "Pathname")) {
        if (std.mem.eql(u8, method_name, "to_s") or
            std.mem.eql(u8, method_name, "to_path") or
            std.mem.eql(u8, method_name, "basename") or
            std.mem.eql(u8, method_name, "dirname") or
            std.mem.eql(u8, method_name, "extname") or
            std.mem.eql(u8, method_name, "expand_path") or
            std.mem.eql(u8, method_name, "realpath") or
            std.mem.eql(u8, method_name, "read")) return "String";
        if (std.mem.eql(u8, method_name, "join") or
            std.mem.eql(u8, method_name, "parent") or
            std.mem.eql(u8, method_name, "cleanpath") or
            std.mem.eql(u8, method_name, "relative_path_from") or
            std.mem.eql(u8, method_name, "sub_ext")) return "Pathname";
        if (std.mem.eql(u8, method_name, "children") or
            std.mem.eql(u8, method_name, "entries") or
            std.mem.eql(u8, method_name, "glob") or
            std.mem.eql(u8, method_name, "readlines")) return "Array";
        if (std.mem.eql(u8, method_name, "exist?") or
            std.mem.eql(u8, method_name, "file?") or
            std.mem.eql(u8, method_name, "directory?") or
            std.mem.eql(u8, method_name, "empty?") or
            std.mem.eql(u8, method_name, "absolute?") or
            std.mem.eql(u8, method_name, "relative?")) return "TrueClass";
    }
    // Universal methods present on all objects
    if (std.mem.eql(u8, method_name, "class")) return "Class";
    if (std.mem.eql(u8, method_name, "frozen?") or
        std.mem.eql(u8, method_name, "nil?") or
        std.mem.eql(u8, method_name, "is_a?") or
        std.mem.eql(u8, method_name, "kind_of?") or
        std.mem.eql(u8, method_name, "instance_of?") or
        std.mem.eql(u8, method_name, "respond_to?") or
        std.mem.eql(u8, method_name, "equal?") or
        std.mem.eql(u8, method_name, "eql?") or
        std.mem.eql(u8, method_name, "tainted?")) return "TrueClass";
    if (std.mem.eql(u8, method_name, "to_s") or
        std.mem.eql(u8, method_name, "inspect")) return "String";
    if (std.mem.eql(u8, method_name, "hash") or
        std.mem.eql(u8, method_name, "object_id")) return "Integer";
    if (std.mem.eql(u8, method_name, "dup") or
        std.mem.eql(u8, method_name, "clone") or
        std.mem.eql(u8, method_name, "freeze") or
        std.mem.eql(u8, method_name, "itself") or
        std.mem.eql(u8, method_name, "tap")) return class_name;
    if (std.mem.eql(u8, method_name, "methods") or
        std.mem.eql(u8, method_name, "public_methods") or
        std.mem.eql(u8, method_name, "private_methods") or
        std.mem.eql(u8, method_name, "protected_methods") or
        std.mem.eql(u8, method_name, "instance_variables")) return "Array";
    // String methods missed earlier
    if (std.mem.eql(u8, class_name, "String")) {
        if (std.mem.eql(u8, method_name, "match")) return "MatchData";
        if (std.mem.eql(u8, method_name, "index") or
            std.mem.eql(u8, method_name, "rindex")) return "Integer";
        if (std.mem.eql(u8, method_name, "replace") or
            std.mem.eql(u8, method_name, "insert") or
            std.mem.eql(u8, method_name, "force_encoding") or
            std.mem.eql(u8, method_name, "scrub") or
            std.mem.eql(u8, method_name, "unicode_normalize") or
            std.mem.eql(u8, method_name, "b")) return "String";
        if (std.mem.eql(u8, method_name, "unpack")) return "Array";
        if (std.mem.eql(u8, method_name, "encoding")) return "Encoding";
    }
    // ActiveSupport methods — harmless on non-Rails codebases
    if (std.mem.eql(u8, method_name, "blank?") or
        std.mem.eql(u8, method_name, "present?") or
        std.mem.eql(u8, method_name, "in?")) return "TrueClass";
    if (std.mem.eql(u8, method_name, "with_indifferent_access") or
        std.mem.eql(u8, method_name, "deep_symbolize_keys") or
        std.mem.eql(u8, method_name, "deep_stringify_keys")) return "Hash";
    if (std.mem.eql(u8, method_name, "presence")) return class_name;
    if (std.mem.eql(u8, method_name, "try") or
        std.mem.eql(u8, method_name, "try!")) return null;
    return null;
}

fn extractHashGenerics(class_name: []const u8) ?struct { key: []const u8, value: []const u8 } {
    if (!std.mem.startsWith(u8, class_name, "Hash[")) return null;
    if (class_name[class_name.len - 1] != ']') return null;
    const inner = class_name[5 .. class_name.len - 1];
    var depth: u32 = 0;
    for (inner, 0..) |ch, i| {
        switch (ch) {
            '[' => depth += 1,
            ']' => depth -|= 1,
            ',' => if (depth == 0) return .{
                .key = std.mem.trim(u8, inner[0..i], " "),
                .value = std.mem.trim(u8, inner[i + 1 ..], " "),
            },
            else => {},
        }
    }
    return null;
}

// Find the innermost class/module symbol that textually contains the given line.
// Returns the symbol's id and fully qualified name, or null if the line is not inside any
// class/module body in this file.
fn findEnclosingClass(
    db: db_mod.Db,
    file_id: i64,
    line: i64,
    alloc: std.mem.Allocator,
) ?struct { id: i64, name: []u8 } {
    const stmt = db.prepare(
        \\SELECT id, name FROM symbols
        \\WHERE file_id = ? AND kind IN ('class','classdef','module','moduledef')
        \\  AND line <= ?
        \\  AND (end_line IS NULL OR end_line >= ?)
        \\ORDER BY line DESC
        \\LIMIT 1
    ) catch return null;
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_int(2, line);
    stmt.bind_int(3, line);
    if (!(stmt.step() catch false)) return null;
    const id = stmt.column_int(0);
    const name_text = stmt.column_text(1);
    const owned = alloc.dupe(u8, name_text) catch return null;
    return .{ .id = id, .name = owned };
}

const MethodResolution = enum {
    found, // method exists somewhere in the known ancestor chain
    not_found, // entire ancestor chain walked, fully known, no match
    unknown, // at least one ancestor is outside the index; cannot decide
};

// Walk the ancestor chain of `class_name` looking for a `def` whose name matches
// `method_name`. Returns:
//   .found       — exists on the class or any reachable ancestor
//   .not_found   — fully walked a known chain, method absent
//   .unknown     — an ancestor is not in the symbols table (external gem/stdlib)
//
// "Ancestor" here means: the class itself, its recorded parent_name (superclass when
// the class is top-level, namespace parent otherwise — a known limitation of the
// current schema), and every module in the `mixins` table attached to the class.
fn resolveMethodInAncestors(
    db: db_mod.Db,
    class_name: []const u8,
    method_name: []const u8,
    alloc: std.mem.Allocator,
) MethodResolution {
    var seen = std.StringHashMap(void).init(alloc);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        seen.deinit();
    }
    var queue = std.ArrayList([]u8).empty;
    defer {
        for (queue.items) |item| alloc.free(item);
        queue.deinit(alloc);
    }

    const first = alloc.dupe(u8, class_name) catch return .unknown;
    queue.append(alloc, first) catch {
        alloc.free(first);
        return .unknown;
    };

    var steps: u32 = 0;
    const max_steps: u32 = 32;

    while (queue.items.len > 0) {
        if (steps >= max_steps) return .unknown;
        steps += 1;

        const name = queue.orderedRemove(0);
        defer alloc.free(name);

        if (seen.contains(name)) continue;
        const key_copy = alloc.dupe(u8, name) catch return .unknown;
        seen.put(key_copy, {}) catch {
            alloc.free(key_copy);
            return .unknown;
        };

        // Look up the class/module symbol by name. If not present, the chain is
        // external — we cannot decide anything, bail out.
        const lookup = db.prepare(
            \\SELECT id, parent_name FROM symbols
            \\WHERE name = ? AND kind IN ('class','classdef','module','moduledef')
            \\LIMIT 1
        ) catch return .unknown;
        defer lookup.finalize();
        lookup.bind_text(1, name);
        if (!(lookup.step() catch false)) return .unknown;
        const class_id = lookup.column_int(0);
        const parent_name_slice = lookup.column_text(1);

        // Method defined directly under this class?
        const has_method = db.prepare(
            \\SELECT 1 FROM symbols
            \\WHERE kind = 'def' AND parent_name = ? AND name = ?
            \\LIMIT 1
        ) catch return .unknown;
        defer has_method.finalize();
        has_method.bind_text(1, name);
        has_method.bind_text(2, method_name);
        if (has_method.step() catch false) return .found;

        // Enqueue superclass (stored as parent_name for top-level classes).
        if (parent_name_slice.len > 0) {
            const dup = alloc.dupe(u8, parent_name_slice) catch return .unknown;
            queue.append(alloc, dup) catch {
                alloc.free(dup);
                return .unknown;
            };
        }

        // Enqueue mixins (include/prepend/extend) attached to this class.
        const mix_stmt = db.prepare(
            \\SELECT module_name FROM mixins WHERE class_id = ?
        ) catch return .unknown;
        defer mix_stmt.finalize();
        mix_stmt.bind_int(1, class_id);
        while (mix_stmt.step() catch false) {
            const mod_name = mix_stmt.column_text(0);
            if (mod_name.len == 0) continue;
            const dup = alloc.dupe(u8, mod_name) catch return .unknown;
            queue.append(alloc, dup) catch {
                alloc.free(dup);
                return .unknown;
            };
        }
    }

    return .not_found;
}

pub fn getDiags(path: []const u8, alloc: std.mem.Allocator) ![]DiagEntry {
    const source = std.Io.Dir.cwd().readFileAllocOptions(
        std.Options.debug_io,
        path,
        alloc,
        std.Io.Limit.limited(8 * 1024 * 1024),
        .@"1",
        0,
    ) catch return &.{};
    defer alloc.free(source);

    if (source.len == 0) return &.{};

    var erb_buf: ?[]u8 = null;
    defer if (erb_buf) |b| alloc.free(b);
    const prism_src: []const u8 = if (std.mem.endsWith(u8, path, ".erb")) blk: {
        erb_buf = try extractErbRuby(alloc, source);
        break :blk erb_buf.?;
    } else if (std.mem.endsWith(u8, path, ".haml")) blk: {
        erb_buf = try extractHamlRuby(alloc, source);
        break :blk erb_buf.?;
    } else if (std.mem.endsWith(u8, path, ".slim")) blk: {
        erb_buf = try extractSlimRuby(alloc, source);
        break :blk erb_buf.?;
    } else source;

    var arena = prism.Arena{ .current = null, .block_count = 0 };
    defer prism.arena_free(&arena);
    var parser: prism.Parser = undefined;
    prism.parser_init(&arena, &parser, prism_src.ptr, prism_src.len - 1, null);
    defer prism.parser_free(&parser);
    _ = prism.parse(&parser);

    var list = std.ArrayList(DiagEntry).empty;
    errdefer {
        for (list.items) |e| alloc.free(e.message);
        list.deinit(alloc);
    }

    var node = parser.error_list.head;
    while (node != null) {
        const diag: *const prism.Diagnostic = @ptrCast(@alignCast(node));
        const msg_slice = std.mem.span(diag.message);
        const lc = locationLineCol(&parser, diag.location.start);
        try list.append(alloc, .{
            .line = lc.line,
            .col = lc.col,
            .message = try alloc.dupe(u8, msg_slice),
        });
        node = diag.node.next;
    }

    return list.toOwnedSlice(alloc);
}

pub fn getDiagsFromSource(source: []const u8, path: []const u8, alloc: std.mem.Allocator) ![]DiagEntry {
    if (source.len == 0) return &.{};

    var erb_buf: ?[]u8 = null;
    defer if (erb_buf) |b| alloc.free(b);
    const prism_src: []const u8 = if (std.mem.endsWith(u8, path, ".erb")) blk: {
        erb_buf = try extractErbRuby(alloc, source);
        break :blk erb_buf.?;
    } else if (std.mem.endsWith(u8, path, ".haml")) blk: {
        erb_buf = try extractHamlRuby(alloc, source);
        break :blk erb_buf.?;
    } else if (std.mem.endsWith(u8, path, ".slim")) blk: {
        erb_buf = try extractSlimRuby(alloc, source);
        break :blk erb_buf.?;
    } else source;

    var arena = prism.Arena{ .current = null, .block_count = 0 };
    defer prism.arena_free(&arena);
    var parser: prism.Parser = undefined;
    prism.parser_init(&arena, &parser, prism_src.ptr, prism_src.len, null);
    defer prism.parser_free(&parser);
    _ = prism.parse(&parser);

    var list = std.ArrayList(DiagEntry).empty;
    errdefer {
        for (list.items) |e| alloc.free(e.message);
        list.deinit(alloc);
    }

    var node = parser.error_list.head;
    while (node != null) {
        const diag: *const prism.Diagnostic = @ptrCast(@alignCast(node));
        const msg_slice = std.mem.span(diag.message);
        const lc = locationLineCol(&parser, diag.location.start);
        try list.append(alloc, .{
            .line = lc.line,
            .col = lc.col,
            .message = try alloc.dupe(u8, msg_slice),
        });
        node = diag.node.next;
    }

    return list.toOwnedSlice(alloc);
}

fn extractErbRuby(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    var buf = try alloc.dupe(u8, source);
    var i: usize = 0;
    var in_ruby = false;
    var is_comment = false;

    while (i < source.len) {
        if (!in_ruby) {
            if (i + 1 < source.len and source[i] == '<' and source[i + 1] == '%') {
                if (i + 2 < source.len and source[i + 2] == '%') {
                    buf[i] = ' ';
                    buf[i + 1] = ' ';
                    buf[i + 2] = ' ';
                    i += 3;
                    continue;
                }
                buf[i] = ' ';
                buf[i + 1] = ' ';
                i += 2;
                if (i < source.len) switch (source[i]) {
                    '#' => {
                        is_comment = true;
                        buf[i] = ' ';
                        i += 1;
                    },
                    '=', '-' => {
                        buf[i] = ' ';
                        i += 1;
                    },
                    else => {},
                };
                in_ruby = true;
                continue;
            }
            if (source[i] != '\n') buf[i] = ' ';
            i += 1;
        } else {
            if (i + 1 < source.len and source[i] == '%' and source[i + 1] == '>') {
                buf[i] = ' ';
                buf[i + 1] = ' ';
                i += 2;
                if (i < source.len and source[i] == '-') {
                    buf[i] = ' ';
                    i += 1;
                }
                in_ruby = false;
                is_comment = false;
                continue;
            }
            if (is_comment and source[i] != '\n') buf[i] = ' ';
            i += 1;
        }
    }
    return buf;
}

fn extractHamlRuby(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    var map = try erb_mapping.buildHamlMap(alloc, source);
    defer map.deinit();

    var buf = try alloc.alloc(u8, source.len);
    @memset(buf, ' ');

    for (map.spans) |span| {
        if (span.ruby_end > buf.len or span.erb_end > source.len) continue;
        const ruby_len = span.ruby_end - span.ruby_start;
        if (span.ruby_start + ruby_len > buf.len or span.erb_start + ruby_len > source.len) continue;
        @memcpy(buf[span.ruby_start..][0..ruby_len], source[span.erb_start..][0..ruby_len]);
    }

    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == ' ' and source[i] == '\n') {
            buf[i] = '\n';
        }
    }

    return buf;
}

fn extractSlimRuby(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    var map = try erb_mapping.buildSlimMap(alloc, source);
    defer map.deinit();

    var buf = try alloc.alloc(u8, source.len);
    @memset(buf, ' ');

    for (map.spans) |span| {
        if (span.ruby_end > buf.len or span.erb_end > source.len) continue;
        const ruby_len = span.ruby_end - span.ruby_start;
        if (span.ruby_start + ruby_len > buf.len or span.erb_start + ruby_len > source.len) continue;
        @memcpy(buf[span.ruby_start..][0..ruby_len], source[span.erb_start..][0..ruby_len]);
    }

    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == ' ' and source[i] == '\n') {
            buf[i] = '\n';
        }
    }

    return buf;
}

pub fn runSemanticChecks(db: db_mod.Db, file_id: i64, alloc: std.mem.Allocator) !std.ArrayList(DiagEntry) {
    var diags = std.ArrayList(DiagEntry).empty;

    // Unused local variable detection: local_vars not referenced in refs within same file
    // Skip names starting with _ (convention for intentionally unused)
    const unused_stmt = db.prepare(
        \\SELECT lv.name, lv.line, lv.col FROM local_vars lv
        \\WHERE lv.file_id = ? AND lv.name NOT LIKE '\_%' ESCAPE '\'
        \\AND lv.name NOT LIKE '@%' AND lv.name NOT LIKE '$%'
        \\AND NOT EXISTS (
        \\  SELECT 1 FROM refs r WHERE r.file_id = lv.file_id AND r.name = lv.name
        \\)
    ) catch return diags;
    defer unused_stmt.finalize();
    unused_stmt.bind_int(1, file_id);

    while (unused_stmt.step() catch false) {
        const var_name = unused_stmt.column_text(0);
        const line = unused_stmt.column_int(1);
        const col = unused_stmt.column_int(2);

        const msg = std.fmt.allocPrint(alloc, "unused local variable '{s}'", .{var_name}) catch continue;
        diags.append(alloc, .{
            .line = @intCast(line),
            .col = @intCast(col),
            .message = msg,
            .severity = 2,
            .code = "refract/unused-variable",
        }) catch {
            alloc.free(msg);
        };
    }

    const param_stmt = db.prepare(
        \\SELECT p.name, s.line, s.col FROM params p
        \\JOIN symbols s ON p.symbol_id = s.id
        \\WHERE s.file_id = ? AND s.kind = 'def'
        \\AND p.name NOT LIKE '\_%' ESCAPE '\'
        \\AND NOT EXISTS (
        \\  SELECT 1 FROM refs r WHERE r.file_id = s.file_id AND r.name = p.name
        \\)
        \\AND NOT EXISTS (
        \\  SELECT 1 FROM local_vars lv WHERE lv.file_id = s.file_id AND lv.name = p.name
        \\)
    ) catch return diags;
    defer param_stmt.finalize();
    param_stmt.bind_int(1, file_id);

    while (param_stmt.step() catch false) {
        const pname = param_stmt.column_text(0);
        const pline = param_stmt.column_int(1);
        const pcol = param_stmt.column_int(2);
        const pmsg = std.fmt.allocPrint(alloc, "unused parameter '{s}'", .{pname}) catch continue;
        diags.append(alloc, .{
            .line = @intCast(pline),
            .col = @intCast(pcol),
            .message = pmsg,
            .severity = 4,
            .code = "refract/unused-parameter",
        }) catch {
            alloc.free(pmsg);
        };
    }

    const method_stmt = db.prepare(
        \\SELECT s.name, s.line, s.col FROM symbols s
        \\WHERE s.file_id = ? AND s.kind = 'def'
        \\AND s.visibility = 'public'
        \\AND s.name NOT LIKE '\_%' ESCAPE '\'
        \\AND s.name NOT IN (
        \\  'initialize','to_s','inspect','to_h','to_a','to_i','to_f','to_str',
        \\  'to_proc','to_ary','to_hash','to_int','to_io','to_path','to_regexp',
        \\  'method_missing','respond_to_missing?','inherited','included',
        \\  'extended','prepended','const_missing','hash','eql?','<=>','==',
        \\  'coerce','encode_with','init_with','marshal_dump','marshal_load'
        \\)
        \\AND s.name NOT LIKE 'test\_%' ESCAPE '\'
        \\AND s.name NOT IN ('setup','teardown','before','after')
        \\AND NOT EXISTS (SELECT 1 FROM refs r WHERE r.name = s.name)
    ) catch return diags;
    defer method_stmt.finalize();
    method_stmt.bind_int(1, file_id);

    while (method_stmt.step() catch false) {
        const mname = method_stmt.column_text(0);
        const mline = method_stmt.column_int(1);
        const mcol = method_stmt.column_int(2);
        const mmsg = std.fmt.allocPrint(alloc, "unused method '{s}'", .{mname}) catch continue;
        diags.append(alloc, .{
            .line = @intCast(mline),
            .col = @intCast(mcol),
            .message = mmsg,
            .severity = 4,
            .code = "refract/unused-method",
        }) catch {
            alloc.free(mmsg);
        };
    }

    const dup_stmt = db.prepare(
        \\SELECT s1.name, s1.line FROM symbols s1
        \\WHERE s1.file_id = ? AND s1.kind = 'def'
        \\AND EXISTS (
        \\  SELECT 1 FROM symbols s2
        \\  WHERE s2.file_id = s1.file_id AND s2.name = s1.name AND s2.kind = 'def'
        \\  AND s2.id != s1.id
        \\  AND COALESCE(s2.parent_name,'') = COALESCE(s1.parent_name,'')
        \\)
        \\ORDER BY s1.name, s1.line
    ) catch return diags;
    defer dup_stmt.finalize();
    dup_stmt.bind_int(1, file_id);

    while (dup_stmt.step() catch false) {
        const dname = dup_stmt.column_text(0);
        const dline = dup_stmt.column_int(1);
        const dmsg = std.fmt.allocPrint(alloc, "method '{s}' defined multiple times", .{dname}) catch continue;
        diags.append(alloc, .{
            .line = @intCast(dline),
            .col = 0,
            .message = dmsg,
            .severity = 2,
            .code = "refract/duplicate-method",
        }) catch {
            alloc.free(dmsg);
        };
    }

    // Undefined method with fuzzy "did you mean?" suggestions.
    //
    // Strategy, in order of cheapness:
    //   1. Filter refs already defined as workspace symbols or local vars (SQL).
    //   2. Skip Ruby/Rails/RSpec built-in method names via the static allowlists.
    //   3. For each surviving ref, locate its enclosing class/module and walk the
    //      ancestor chain (superclass + mixins). If any ancestor lives outside the
    //      index (e.g. ActiveRecord::Base), bail out silently — we cannot prove the
    //      method is undefined without knowing what those externals provide.
    //   4. Only flag when the entire ancestor chain is fully visible in the symbols
    //      table and the method is provably absent from every link.
    const ref_stmt = db.prepare(
        \\SELECT r.name, r.line, r.col FROM refs r
        \\WHERE r.file_id = ? AND r.name NOT LIKE '\_%' ESCAPE '\'
        \\AND NOT EXISTS (
        \\  SELECT 1 FROM symbols s WHERE s.name = r.name
        \\)
        \\AND NOT EXISTS (
        \\  SELECT 1 FROM local_vars lv WHERE lv.file_id = r.file_id AND lv.name = r.name
        \\)
    ) catch return diags;
    defer ref_stmt.finalize();
    ref_stmt.bind_int(1, file_id);

    while (ref_stmt.step() catch false) {
        const ref_name = ref_stmt.column_text(0);
        const line = ref_stmt.column_int(1);
        const col = ref_stmt.column_int(2);

        // Skip common Ruby built-ins and keywords
        if (ref_name.len == 0) continue;
        if (ref_name[0] >= 'A' and ref_name[0] <= 'Z') continue; // constants handled elsewhere
        if (isBuiltinMethod(ref_name)) continue;
        if (isRailsDsl(ref_name)) continue;
        if (isIterationMethod(ref_name)) continue;

        // Ancestry-aware check. Find the innermost class/module that contains this
        // ref's line and resolve the method against its full ancestor chain.
        if (findEnclosingClass(db, file_id, line, alloc)) |enc| {
            defer alloc.free(enc.name);
            const resolution = resolveMethodInAncestors(db, enc.name, ref_name, alloc);
            switch (resolution) {
                .found => continue, // method actually exists somewhere in the chain
                .unknown => continue, // external ancestor — cannot prove absent
                .not_found => {}, // fall through to fuzzy suggestion + diagnostic
            }
        } else {
            // Top-level ref with no enclosing class. Without receiver context we
            // cannot reliably distinguish a typo from a method in Kernel / loaded
            // scripts, so skip rather than noise.
            continue;
        }

        // Find similar symbol names for "did you mean?" suggestions
        const similar = db.prepare(
            \\SELECT DISTINCT name FROM symbols
            \\WHERE kind IN ('def','classdef') AND name LIKE ? ESCAPE '\'
            \\LIMIT 10
        ) catch continue;
        defer similar.finalize();
        var like_buf: [256]u8 = undefined;
        const like_pat = std.fmt.bufPrint(&like_buf, "%{s}%", .{ref_name}) catch continue;
        similar.bind_text(1, like_pat);

        var best_name: ?[]const u8 = null;
        // Tighter threshold: at most 2 edits, and never more than half the ref length
        const max_dist: u32 = @min(@as(u32, 2), @as(u32, @intCast(ref_name.len / 2 + 1)));
        var best_dist: u32 = max_dist + 1;
        while (similar.step() catch false) {
            const candidate = similar.column_text(0);
            // Reject operator-name candidates (==, <=>, <<, []=, etc.) — they are never sensible
            // suggestions for an identifier typo.
            if (candidate.len == 0) continue;
            const first = candidate[0];
            const is_ident_start = (first >= 'a' and first <= 'z') or first == '_';
            if (!is_ident_start) continue;
            const dist = editDistance(ref_name, candidate);
            if (dist > 0 and dist < best_dist) {
                best_dist = dist;
                best_name = candidate;
            }
        }

        if (best_name) |suggested| {
            const msg = std.fmt.allocPrint(alloc, "undefined method '{s}' \u{2014} did you mean '{s}'?", .{ ref_name, suggested }) catch continue;
            diags.append(alloc, .{
                .line = @intCast(line),
                .col = @intCast(col),
                .message = msg,
                .severity = 2,
                .code = "refract/undefined-method",
            }) catch {
                alloc.free(msg);
            };
        }
    }

    // Type-checker: method called on a NilClass-narrowed receiver.
    // The narrower at insertLocalVar marks a var as NilClass when a control-flow guard
    // proves nil; we emit a warning every time such a var is the receiver of a call.
    {
        const nil_stmt = db.prepare(
            \\SELECT r.name, r.line, r.col FROM refs r
            \\WHERE r.file_id = ? AND r.receiver_type = 'NilClass'
        ) catch return diags;
        defer nil_stmt.finalize();
        nil_stmt.bind_int(1, file_id);
        while (nil_stmt.step() catch false) {
            const rname = nil_stmt.column_text(0);
            const rline = nil_stmt.column_int(1);
            const rcol = nil_stmt.column_int(2);
            const msg = std.fmt.allocPrint(alloc, "method '{s}' called on a value proven to be nil", .{rname}) catch continue;
            diags.append(alloc, .{
                .line = @intCast(rline),
                .col = @intCast(rcol),
                .message = msg,
                .severity = 2,
                .code = "refract/nil-receiver",
            }) catch alloc.free(msg);
        }
    }

    // Type-checker: too many positional arguments for a known method.
    //
    // Triggers only when:
    //   - the call site has a known receiver_type (confidence >= 70 at insertion),
    //   - that receiver has exactly one matching def in our index,
    //   - that def has no rest / keyword_rest / block param (which would accept any extras),
    //   - the call's arg_count exceeds the positional+keyword count.
    //
    // We deliberately use COALESCE on parent_name so non-namespaced top-level methods
    // also match when receiver_type matches their owning class.
    {
        const arity_stmt = db.prepare(
            \\SELECT r.name, r.line, r.col, r.arg_count, r.receiver_type FROM refs r
            \\WHERE r.file_id = ?
            \\  AND r.arg_count > 0
            \\  AND r.receiver_type IS NOT NULL
            \\  AND r.receiver_type != 'NilClass'
        ) catch return diags;
        defer arity_stmt.finalize();
        arity_stmt.bind_int(1, file_id);

        while (arity_stmt.step() catch false) {
            const rname = arity_stmt.column_text(0);
            const rline = arity_stmt.column_int(1);
            const rcol = arity_stmt.column_int(2);
            const rargs = arity_stmt.column_int(3);
            const rtype = arity_stmt.column_text(4);
            if (rtype.len == 0) continue;

            // Find the matching method definition's id.
            const sym_stmt = db.prepare(
                \\SELECT id FROM symbols
                \\WHERE name = ? AND COALESCE(parent_name,'') = ? AND kind IN ('def','classdef')
                \\LIMIT 2
            ) catch continue;
            defer sym_stmt.finalize();
            sym_stmt.bind_text(1, rname);
            sym_stmt.bind_text(2, rtype);
            if (!(sym_stmt.step() catch false)) continue;
            const sym_id = sym_stmt.column_int(0);
            // If multiple defs match (e.g. monkey patches), bail to avoid false positives.
            if (sym_stmt.step() catch false) continue;

            // Sum non-variadic params and check for variadic kinds.
            const arity_param_stmt = db.prepare(
                \\SELECT
                \\  SUM(CASE WHEN kind IN ('rest','keyword_rest','block') THEN 1 ELSE 0 END) AS variadic,
                \\  SUM(CASE WHEN kind NOT IN ('rest','keyword_rest','block') OR kind IS NULL THEN 1 ELSE 0 END) AS fixed
                \\FROM params WHERE symbol_id = ?
            ) catch continue;
            defer arity_param_stmt.finalize();
            arity_param_stmt.bind_int(1, sym_id);
            if (!(arity_param_stmt.step() catch false)) continue;
            const variadic = arity_param_stmt.column_int(0);
            const fixed = arity_param_stmt.column_int(1);
            if (variadic > 0) continue; // accepts any number of extras
            if (fixed == 0) continue; // method has no params recorded — likely incomplete index

            if (rargs > fixed) {
                const msg = std.fmt.allocPrint(alloc, "too many arguments for '{s}': got {d}, expected at most {d}", .{ rname, rargs, fixed }) catch continue;
                diags.append(alloc, .{
                    .line = @intCast(rline),
                    .col = @intCast(rcol),
                    .message = msg,
                    .severity = 2,
                    .code = "refract/wrong-arity",
                }) catch alloc.free(msg);
            }
        }
    }

    return diags;
}

/// Optional progress callback for long-running reindex operations.
/// Called every PROGRESS_STRIDE files with (done, total, last_path).
/// Safe to call while the DB transaction is open — must not touch the DB.
pub const ProgressCallback = struct {
    ctx: *anyopaque,
    report: *const fn (ctx: *anyopaque, done: usize, total: usize, path: []const u8) void,
};

const PROGRESS_STRIDE = 25;

pub fn reindex(db: db_mod.Db, paths: []const []const u8, is_gem: bool, alloc: std.mem.Allocator, max_file_size: usize, progress: ?ProgressCallback) !void {
    // Chunked commit strategy: a single transaction over 10k+ files makes the
    // WAL grow to hundreds of MB and the final COMMIT becomes pathological.
    // Committing every CHUNK_SIZE files lets the WAL auto-checkpoint (PRAGMA
    // wal_autocheckpoint=100 pages) and keeps memory + write throughput steady.
    // Refs are keyed by name, not symbol_id, so cross-chunk lookups still work.
    const CHUNK_SIZE: usize = 500;

    var in_tx = false;
    defer if (in_tx) {
        db.rollback() catch {}; // rollback best-effort if we never reached the final commit
    };

    for (paths, 0..) |path, i| {
        if (i % CHUNK_SIZE == 0) {
            if (in_tx) {
                try db.commit();
                in_tx = false;
            }
            try db.begin();
            in_tx = true;
        }
        // Fire progress every PROGRESS_STRIDE files (and on the final file)
        if (progress) |cb| {
            if (i % PROGRESS_STRIDE == 0 or i + 1 == paths.len) {
                cb.report(cb.ctx, i + 1, paths.len, path);
            }
        }
        // Check mtime; fast-skip unchanged files
        const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch continue;
        const disk_mtime: i64 = stat.mtime.toMilliseconds();

        const check = try db.prepare("SELECT mtime, content_hash FROM files WHERE path = ?");
        defer check.finalize();
        check.bind_text(1, path);
        const has_existing = try check.step();
        var db_mtime: i64 = -1;
        var db_hash: i64 = 0;
        if (has_existing) {
            db_mtime = check.column_int(0);
            db_hash = check.column_int(1);
        }

        // Evict files that now exceed the configured limit, regardless of mtime.
        // This handles the case where maxFileSize was tightened via didChangeConfiguration
        // while the file on disk is unchanged.
        if (stat.size > max_file_size) {
            if (has_existing) {
                if (db.prepare("DELETE FROM files WHERE path = ?")) |del_stmt| {
                    defer del_stmt.finalize();
                    del_stmt.bind_text(1, path);
                    _ = del_stmt.step() catch {};
                } else |_| {}
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "refract: evicting {s} (exceeds maxFileSize)", .{path}) catch "refract: evicting file (too large)";
                emitLog(3, msg);
            }
            continue;
        }

        if (has_existing and db_mtime == disk_mtime and db_hash != 0) continue;

        const source = std.Io.Dir.cwd().readFileAllocOptions(
            std.Options.debug_io,
            path,
            alloc,
            std.Io.Limit.limited(max_file_size),
            .@"1",
            0,
        ) catch |err| {
            if (err == error.StreamTooLong) {
                var buf: [512]u8 = undefined;
                const msg = if (max_file_size == 8 * 1024 * 1024)
                    std.fmt.bufPrint(&buf, "refract: skipping {s} (>8MB)", .{path}) catch "refract: skipping file (too large)"
                else
                    std.fmt.bufPrint(&buf, "refract: skipping {s} (file too large)", .{path}) catch "refract: skipping file (too large)";
                emitLog(3, msg);
                if (has_existing) {
                    if (db.prepare("DELETE FROM files WHERE path = ?")) |del_stmt| {
                        defer del_stmt.finalize();
                        del_stmt.bind_text(1, path);
                        _ = del_stmt.step() catch {};
                    } else |_| {}
                }
            }
            continue;
        };
        defer alloc.free(source);

        if (source.len == 0) continue;

        // Compute content hash; skip if content is unchanged despite mtime change
        const content_hash: i64 = @bitCast(std.hash.Wyhash.hash(0, source[0 .. source.len - 1]));
        if (has_existing and db_hash == content_hash and content_hash != 0) continue;

        // Upsert file record with mtime, content_hash, and is_gem flag
        const upsert = try db.prepare(
            \\INSERT INTO files (path, mtime, content_hash, is_gem) VALUES (?, ?, ?, ?)
            \\ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime, content_hash=excluded.content_hash, is_gem=excluded.is_gem
            \\RETURNING id
        );
        defer upsert.finalize();
        upsert.bind_text(1, path);
        upsert.bind_int(2, disk_mtime);
        upsert.bind_int(3, content_hash);
        upsert.bind_int(4, if (is_gem) 1 else 0);
        const has_row = try upsert.step();
        const file_id: i64 = if (has_row) upsert.column_int(0) else db.last_insert_rowid();

        // Delete domain-specific tables (these have their own re-indexing below)
        if (db.prepare("DELETE FROM i18n_keys WHERE file_id = ?")) |s| {
            defer s.finalize();
            s.bind_int(1, file_id);
            _ = s.step() catch {}; // cleanup
        } else |_| {}
        if (db.prepare("DELETE FROM routes WHERE file_id = ?")) |s| {
            defer s.finalize();
            s.bind_int(1, file_id);
            _ = s.step() catch {}; // cleanup
        } else |_| {}
        if (db.prepare("DELETE FROM aliases WHERE file_id = ?")) |s| {
            defer s.finalize();
            s.bind_int(1, file_id);
            _ = s.step() catch {}; // cleanup
        } else |_| {}

        // Routes: index config/routes*.rb, routes/*.rb, and common Sinatra entry points
        const is_route_file = (std.mem.containsAtLeast(u8, path, 1, "config/routes") or
            std.mem.containsAtLeast(u8, path, 1, "routes/") or
            std.mem.endsWith(u8, path, "/app.rb") or
            std.mem.endsWith(u8, path, "/web.rb") or
            std.mem.endsWith(u8, path, "/server.rb"));
        if (is_route_file and std.mem.endsWith(u8, path, ".rb")) {
            routes_mod.indexRoutesWithPath(db, file_id, source[0 .. source.len - 1], alloc, path);
        }

        // RBS: parse type signatures directly, skip Prism
        if (std.mem.endsWith(u8, path, ".rbs")) {
            deleteSymbolData(db, file_id);
            try indexRbs(db, file_id, source[0 .. source.len - 1]);
            continue;
        }

        if (std.mem.endsWith(u8, path, ".yml") or std.mem.endsWith(u8, path, ".yaml")) {
            if (std.mem.containsAtLeast(u8, path, 1, "locales/")) {
                i18n_mod.indexLocaleFile(db, file_id, source[0 .. source.len - 1]);
            }
            // Skip non-locale YAML files — Prism can hang on large YAML parsed as Ruby
            continue;
        }

        const parse_source: []const u8 = if (std.mem.endsWith(u8, path, ".erb")) blk: {
            const extracted = try extractErbRuby(alloc, source[0 .. source.len - 1]);
            break :blk extracted;
        } else if (std.mem.endsWith(u8, path, ".haml")) blk: {
            const extracted = try extractHamlRuby(alloc, source[0 .. source.len - 1]);
            break :blk extracted;
        } else if (std.mem.endsWith(u8, path, ".slim")) blk: {
            const extracted = try extractSlimRuby(alloc, source[0 .. source.len - 1]);
            break :blk extracted;
        } else source[0 .. source.len - 1];
        defer if (std.mem.endsWith(u8, path, ".erb") or std.mem.endsWith(u8, path, ".haml") or std.mem.endsWith(u8, path, ".slim")) alloc.free(parse_source);

        // Parse AST first — if parse fails, preserve existing index
        var arena = prism.Arena{ .current = null, .block_count = 0 };
        defer prism.arena_free(&arena);
        var parser: prism.Parser = undefined;
        prism.parser_init(&arena, &parser, parse_source.ptr, parse_source.len, null);
        defer prism.parser_free(&parser);

        const root = prism.parse(&parser);
        if (root == null) continue;

        // Parse succeeded — now safe to delete old symbols/refs/local_vars
        deleteSymbolData(db, file_id);

        var ctx = VisitCtx{
            .db = db,
            .file_id = file_id,
            .parser = &parser,
            .alloc = alloc,
            .sem_tokens = std.ArrayList(SemToken).empty,
            .source = parse_source,
        };
        defer ctx.sem_tokens.deinit(alloc);

        prism.visit_node(root, visitor, &ctx);

        if (ctx.error_count > 0) {
            var ebuf: [256]u8 = undefined;
            const emsg = std.fmt.bufPrint(&ebuf, "refract: {d} index error(s) in {s} (DB full or schema mismatch?)", .{ ctx.error_count, path }) catch "refract: index errors occurred";
            emitLog(2, emsg);
        }

        storeSemTokens(db, file_id, ctx.sem_tokens.items, alloc) catch {}; // non-critical: highlighting only
    }

    if (in_tx) {
        try db.commit();
        in_tx = false;
    }
}

fn deleteSymbolData(db: db_mod.Db, file_id: i64) void {
    if (db.prepare("DELETE FROM symbols WHERE file_id = ?")) |s| {
        defer s.finalize();
        s.bind_int(1, file_id);
        _ = s.step() catch {};
    } else |_| {}
    if (db.prepare("DELETE FROM refs WHERE file_id = ?")) |s| {
        defer s.finalize();
        s.bind_int(1, file_id);
        _ = s.step() catch {};
    } else |_| {}
    if (db.prepare("DELETE FROM local_vars WHERE file_id = ?")) |s| {
        defer s.finalize();
        s.bind_int(1, file_id);
        _ = s.step() catch {};
    } else |_| {}
}

pub fn shouldSkip(db: db_mod.Db, path: []const u8, disk_mtime: i64) bool {
    const stmt = db.prepare("SELECT mtime, content_hash FROM files WHERE path = ?") catch return false;
    defer stmt.finalize();
    stmt.bind_text(1, path);
    const has_row = stmt.step() catch return false;
    if (!has_row) return false;
    const db_mtime = stmt.column_int(0);
    const db_hash = stmt.column_int(1);
    return db_mtime == disk_mtime and db_hash != 0;
}

pub fn commitParsed(real_db: db_mod.Db, mem_db: db_mod.Db, path: []const u8, is_gem: bool, alloc: std.mem.Allocator) !void {
    // Query the mem_db for parse results
    const fq = mem_db.prepare("SELECT id, mtime, content_hash FROM files WHERE path = ?") catch return;
    defer fq.finalize();
    fq.bind_text(1, path);
    if (!(fq.step() catch return)) return; // file was skipped (empty, too large, parse error)
    const mem_file_id = fq.column_int(0);
    const disk_mtime = fq.column_int(1);
    const content_hash = fq.column_int(2);

    // Skip if content unchanged in real_db
    const ck = real_db.prepare("SELECT content_hash FROM files WHERE path = ?") catch return;
    defer ck.finalize();
    ck.bind_text(1, path);
    if (ck.step() catch false) {
        if (ck.column_int(0) == content_hash and content_hash != 0) return;
    }

    try real_db.begin();
    var committed = false;
    defer if (!committed) {
        real_db.rollback() catch {};
    }; // rollback best-effort

    // Upsert file record in real_db
    const upsert = try real_db.prepare(
        \\INSERT INTO files (path, mtime, content_hash, is_gem) VALUES (?, ?, ?, ?)
        \\ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime, content_hash=excluded.content_hash, is_gem=excluded.is_gem
        \\RETURNING id
    );
    defer upsert.finalize();
    upsert.bind_text(1, path);
    upsert.bind_int(2, disk_mtime);
    upsert.bind_int(3, content_hash);
    upsert.bind_int(4, if (is_gem) 1 else 0);
    const has_file_row = try upsert.step();
    const real_file_id: i64 = if (has_file_row) upsert.column_int(0) else real_db.last_insert_rowid();

    // Delete old symbols (cascades to params and mixins via FK)
    const del_sym = try real_db.prepare("DELETE FROM symbols WHERE file_id = ?");
    defer del_sym.finalize();
    del_sym.bind_int(1, real_file_id);
    _ = try del_sym.step();

    const del_refs = try real_db.prepare("DELETE FROM refs WHERE file_id = ?");
    defer del_refs.finalize();
    del_refs.bind_int(1, real_file_id);
    _ = try del_refs.step();

    const del_lv = try real_db.prepare("DELETE FROM local_vars WHERE file_id = ?");
    defer del_lv.finalize();
    del_lv.bind_int(1, real_file_id);
    _ = try del_lv.step();

    // Copy symbols from mem_db, building provisional→real ID map
    var id_map = std.AutoHashMap(i64, i64).init(alloc);
    defer id_map.deinit();

    const sel_sym = try mem_db.prepare(
        \\SELECT id, name, kind, line, col, return_type, doc, end_line, visibility, parent_name, value_snippet
        \\FROM symbols WHERE file_id = ? ORDER BY id
    );
    defer sel_sym.finalize();
    sel_sym.bind_int(1, mem_file_id);

    const ins_sym = try real_db.prepare(
        \\INSERT INTO symbols (file_id, name, kind, line, col, return_type, doc, end_line, visibility, parent_name, value_snippet)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id
    );
    defer ins_sym.finalize();

    while (try sel_sym.step()) {
        const mem_sym_id = sel_sym.column_int(0);
        ins_sym.reset();
        ins_sym.bind_int(1, real_file_id);
        ins_sym.bind_text(2, sel_sym.column_text(1));
        ins_sym.bind_text(3, sel_sym.column_text(2));
        ins_sym.bind_int(4, sel_sym.column_int(3));
        ins_sym.bind_int(5, sel_sym.column_int(4));
        const rt = sel_sym.column_text(5);
        if (rt.len > 0) ins_sym.bind_text(6, rt) else ins_sym.bind_null(6);
        const doc = sel_sym.column_text(6);
        if (doc.len > 0) ins_sym.bind_text(7, doc) else ins_sym.bind_null(7);
        if (sel_sym.column_type(7) != 5) ins_sym.bind_int(8, sel_sym.column_int(7)) else ins_sym.bind_null(8);
        ins_sym.bind_text(9, sel_sym.column_text(8));
        const pn = sel_sym.column_text(9);
        if (pn.len > 0) ins_sym.bind_text(10, pn) else ins_sym.bind_null(10);
        const vs = sel_sym.column_text(10);
        if (vs.len > 0) ins_sym.bind_text(11, vs) else ins_sym.bind_null(11);
        const got_row = try ins_sym.step();
        const real_sym_id: i64 = if (got_row) ins_sym.column_int(0) else real_db.last_insert_rowid();
        ins_sym.reset();
        try id_map.put(mem_sym_id, real_sym_id);
    }

    // Copy params
    const sel_p = try mem_db.prepare(
        \\SELECT p.symbol_id, p.position, p.name, p.kind, p.type_hint, p.confidence
        \\FROM params p JOIN symbols s ON p.symbol_id = s.id WHERE s.file_id = ?
    );
    defer sel_p.finalize();
    sel_p.bind_int(1, mem_file_id);

    const ins_p = try real_db.prepare(
        \\INSERT OR IGNORE INTO params (symbol_id, position, name, kind, type_hint, confidence)
        \\VALUES (?, ?, ?, ?, ?, ?)
    );
    defer ins_p.finalize();

    while (try sel_p.step()) {
        const real_sym_id = id_map.get(sel_p.column_int(0)) orelse continue;
        ins_p.reset();
        ins_p.bind_int(1, real_sym_id);
        ins_p.bind_int(2, sel_p.column_int(1));
        ins_p.bind_text(3, sel_p.column_text(2));
        ins_p.bind_text(4, sel_p.column_text(3));
        const th = sel_p.column_text(4);
        if (th.len > 0) ins_p.bind_text(5, th) else ins_p.bind_null(5);
        ins_p.bind_int(6, sel_p.column_int(5));
        _ = try ins_p.step();
    }

    // Copy refs
    const sel_r = try mem_db.prepare(
        \\SELECT name, line, col, scope_id FROM refs WHERE file_id = ?
    );
    defer sel_r.finalize();
    sel_r.bind_int(1, mem_file_id);

    const ins_r = try real_db.prepare(
        \\INSERT OR IGNORE INTO refs (file_id, name, line, col, scope_id) VALUES (?, ?, ?, ?, ?)
    );
    defer ins_r.finalize();

    while (try sel_r.step()) {
        ins_r.reset();
        ins_r.bind_int(1, real_file_id);
        ins_r.bind_text(2, sel_r.column_text(0));
        ins_r.bind_int(3, sel_r.column_int(1));
        ins_r.bind_int(4, sel_r.column_int(2));
        if (sel_r.column_type(3) != 5) {
            const real_scope = id_map.get(sel_r.column_int(3)) orelse 0;
            if (real_scope != 0) ins_r.bind_int(5, real_scope) else ins_r.bind_null(5);
        } else ins_r.bind_null(5);
        _ = try ins_r.step();
    }

    // Copy local_vars
    const sel_lv = try mem_db.prepare(
        \\SELECT name, line, col, type_hint, confidence, scope_id, class_id FROM local_vars WHERE file_id = ?
    );
    defer sel_lv.finalize();
    sel_lv.bind_int(1, mem_file_id);

    const ins_lv = try real_db.prepare(
        \\INSERT OR IGNORE INTO local_vars (file_id, name, line, col, type_hint, confidence, scope_id, class_id)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer ins_lv.finalize();

    while (try sel_lv.step()) {
        ins_lv.reset();
        ins_lv.bind_int(1, real_file_id);
        ins_lv.bind_text(2, sel_lv.column_text(0));
        ins_lv.bind_int(3, sel_lv.column_int(1));
        ins_lv.bind_int(4, sel_lv.column_int(2));
        const th = sel_lv.column_text(3);
        if (th.len > 0) ins_lv.bind_text(5, th) else ins_lv.bind_null(5);
        ins_lv.bind_int(6, sel_lv.column_int(4));
        if (sel_lv.column_type(5) != 5) {
            const real_scope = id_map.get(sel_lv.column_int(5)) orelse 0;
            if (real_scope != 0) ins_lv.bind_int(7, real_scope) else ins_lv.bind_null(7);
        } else ins_lv.bind_null(7);
        if (sel_lv.column_type(6) != 5) {
            const real_class = id_map.get(sel_lv.column_int(6)) orelse 0;
            if (real_class != 0) ins_lv.bind_int(8, real_class) else ins_lv.bind_null(8);
        } else ins_lv.bind_null(8);
        _ = try ins_lv.step();
    }

    // Copy mixins (class_id references symbols, cascades on delete)
    const sel_mx = try mem_db.prepare(
        \\SELECT m.class_id, m.module_name, m.kind
        \\FROM mixins m JOIN symbols s ON m.class_id = s.id WHERE s.file_id = ?
    );
    defer sel_mx.finalize();
    sel_mx.bind_int(1, mem_file_id);

    const ins_mx = try real_db.prepare(
        \\INSERT INTO mixins (class_id, module_name, kind) VALUES (?, ?, ?)
    );
    defer ins_mx.finalize();

    while (try sel_mx.step()) {
        const real_class_id = id_map.get(sel_mx.column_int(0)) orelse continue;
        ins_mx.reset();
        ins_mx.bind_int(1, real_class_id);
        ins_mx.bind_text(2, sel_mx.column_text(1));
        ins_mx.bind_text(3, sel_mx.column_text(2));
        _ = try ins_mx.step();
    }

    // Copy sem_tokens
    const sel_st = try mem_db.prepare("SELECT blob, prev_blob FROM sem_tokens WHERE file_id = ?");
    defer sel_st.finalize();
    sel_st.bind_int(1, mem_file_id);

    if (try sel_st.step()) {
        const ins_st = try real_db.prepare(
            \\INSERT OR REPLACE INTO sem_tokens (file_id, blob, prev_blob) VALUES (?, ?, ?)
        );
        defer ins_st.finalize();
        ins_st.bind_int(1, real_file_id);
        ins_st.bind_blob(2, sel_st.column_blob(0));
        const pb = sel_st.column_blob(1);
        if (pb.len > 0) ins_st.bind_blob(3, pb) else ins_st.bind_null(3);
        _ = try ins_st.step();
    }

    try real_db.commit();
    committed = true;
}

pub fn indexSource(source: []const u8, path: []const u8, db: db_mod.Db, alloc: std.mem.Allocator) !void {
    var src = source;
    if (src.len >= 3 and src[0] == 0xEF and src[1] == 0xBB and src[2] == 0xBF) {
        src = src[3..];
    }
    if (!std.unicode.utf8ValidateSlice(src)) return;
    if (src.len == 0) return;

    // Upsert file record — zero mtime and content_hash so reindex always re-reads disk next time
    const upsert = try db.prepare(
        \\INSERT INTO files (path, mtime, content_hash, is_gem) VALUES (?, 0, 0, 0)
        \\ON CONFLICT(path) DO UPDATE SET mtime=0, content_hash=0
        \\RETURNING id
    );
    defer upsert.finalize();
    upsert.bind_text(1, path);
    const has_row = try upsert.step();
    const file_id: i64 = if (has_row) upsert.column_int(0) else db.last_insert_rowid();

    // Delete old symbols, refs, and local_vars for this file
    const del = try db.prepare("DELETE FROM symbols WHERE file_id = ?");
    defer del.finalize();
    del.bind_int(1, file_id);
    _ = try del.step();

    const del_refs = try db.prepare("DELETE FROM refs WHERE file_id = ?");
    defer del_refs.finalize();
    del_refs.bind_int(1, file_id);
    _ = try del_refs.step();

    const del_lvars = try db.prepare("DELETE FROM local_vars WHERE file_id = ?");
    defer del_lvars.finalize();
    del_lvars.bind_int(1, file_id);
    _ = try del_lvars.step();

    if (db.prepare("DELETE FROM i18n_keys WHERE file_id = ?")) |s| {
        defer s.finalize();
        s.bind_int(1, file_id);
        _ = s.step() catch {};
    } else |_| {}
    if (db.prepare("DELETE FROM routes WHERE file_id = ?")) |s| {
        defer s.finalize();
        s.bind_int(1, file_id);
        _ = s.step() catch {};
    } else |_| {}
    if (db.prepare("DELETE FROM aliases WHERE file_id = ?")) |s| {
        defer s.finalize();
        s.bind_int(1, file_id);
        _ = s.step() catch {};
    } else |_| {}

    var arena = prism.Arena{ .current = null, .block_count = 0 };
    defer prism.arena_free(&arena);
    var parser: prism.Parser = undefined;
    prism.parser_init(&arena, &parser, src.ptr, src.len, null);
    defer prism.parser_free(&parser);

    const root = prism.parse(&parser);
    if (root == null) return;

    var ctx = VisitCtx{
        .db = db,
        .file_id = file_id,
        .parser = &parser,
        .alloc = alloc,
        .sem_tokens = std.ArrayList(SemToken).empty,
        .source = src,
    };
    defer ctx.sem_tokens.deinit(alloc);

    prism.visit_node(root, visitor, &ctx);

    storeSemTokens(db, file_id, ctx.sem_tokens.items, alloc) catch {}; // non-critical: highlighting only
}

pub fn indexBundledRbs(db: db_mod.Db) !usize {
    const bundled_rbs = @import("bundled_rbs.zig");
    var count: usize = 0;
    for (bundled_rbs.files) |f| {
        if (f.content.len == 0) continue;
        const upsert = db.prepare(
            \\INSERT INTO files (path, mtime, content_hash, is_gem) VALUES (?, 0, 0, 1)
            \\ON CONFLICT(path) DO UPDATE SET mtime=0, content_hash=0, is_gem=1
            \\RETURNING id
        ) catch continue;
        defer upsert.finalize();
        upsert.bind_text(1, f.path);
        const has_row = upsert.step() catch continue;
        const file_id: i64 = if (has_row) upsert.column_int(0) else db.last_insert_rowid();

        deleteSymbolData(db, file_id);
        indexRbs(db, file_id, f.content) catch continue;
        count += 1;
    }
    return count;
}

pub fn ensureBundledRbs(db: db_mod.Db) void {
    const bundled_rbs = @import("bundled_rbs.zig");
    const expected: i64 = @intCast(bundled_rbs.files.len);
    const cnt_stmt = db.prepare("SELECT COUNT(*) FROM files WHERE path LIKE '<bundled>/%'") catch return;
    defer cnt_stmt.finalize();
    var current: i64 = 0;
    if (cnt_stmt.step() catch false) current = cnt_stmt.column_int(0);
    if (current >= expected) return;
    _ = indexBundledRbs(db) catch return;
}

pub fn cleanupStale(db: db_mod.Db, scanned: []const []const u8, root_path: []const u8, alloc: std.mem.Allocator, keep: ?*const std.StringHashMapUnmanaged(void)) !void {
    var disk_set = std.StringHashMap(void).init(alloc);
    defer disk_set.deinit();
    for (scanned) |p| try disk_set.put(p, {});

    // Only consider files under root_path so extra_roots are never wrongly deleted
    const like_pat = try std.fmt.allocPrint(alloc, "{s}/%", .{root_path});
    defer alloc.free(like_pat);
    const sel = try db.prepare("SELECT path FROM files WHERE is_gem=0 AND path LIKE ? ESCAPE '\\' AND path NOT LIKE '<bundled>/%'");
    defer sel.finalize();
    sel.bind_text(1, like_pat);
    var stale = std.ArrayList([]u8).empty;
    defer {
        for (stale.items) |p| alloc.free(p);
        stale.deinit(alloc);
    }
    while (try sel.step()) {
        const p = sel.column_text(0);
        if (disk_set.contains(p)) continue;
        if (keep) |k| if (k.contains(p)) continue;
        // Defensive: only stale if the file is actually gone from disk.
        // Guards against scan/FS-visibility races where a present file wasn't
        // in the initial scan set (e.g. macOS FSEvents lag).
        _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, p, .{}) catch {
            try stale.append(alloc, try alloc.dupe(u8, p));
            continue;
        };
    }

    if (stale.items.len == 0) return;

    try db.begin();
    var committed = false;
    defer if (!committed) {
        db.rollback() catch {}; // rollback best-effort
    };
    const del = try db.prepare("DELETE FROM files WHERE path = ?");
    defer del.finalize();
    for (stale.items) |p| {
        del.reset();
        del.bind_text(1, p);
        _ = try del.step();
    }
    try db.commit();
    committed = true;
}

test "cleanupStale preserves gem entries" {
    const alloc = std.testing.allocator;

    const db_path = "/tmp/refract_gem_cleanup_test.db";
    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, db_path) catch {};
    const db = try db_mod.Db.open(db_path);
    defer db.close();
    defer std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, db_path) catch {};
    try db.init_schema();

    try db.exec("INSERT INTO files (path, mtime, is_gem) VALUES ('/gems/activesupport/core.rb', 999, 1)");

    const project_paths = [_][]const u8{"/tmp/project_file.rb"};
    try cleanupStale(db, &project_paths, "/tmp", alloc, null);

    const check = try db.prepare("SELECT COUNT(*) FROM files WHERE path='/gems/activesupport/core.rb' AND is_gem=1");
    defer check.finalize();
    try std.testing.expect(try check.step());
    try std.testing.expectEqual(@as(i64, 1), check.column_int(0));
}
