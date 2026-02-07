const std = @import("std");
const db_mod = @import("../db.zig");
const prism = @import("../prism.zig");
const i18n_mod = @import("i18n.zig");
const routes_mod = @import("routes.zig");
const erb_mapping = @import("../lsp/erb_mapping.zig");

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
                                    const len = std.fmt.bufPrint(&hash_type_buf, "Hash[{s}, {s}]", .{ key_type, val_type }) catch break :blk "Hash";
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

fn parseUnionTypes(inner: []const u8, buf: *[512]u8) ?[]const u8 {
    var result_len: usize = 0;
    var it = std.mem.splitSequence(u8, inner, ", ");
    var first = true;
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " ");
        if (t.len == 0) continue;
        const normalized: []const u8 = if (std.mem.eql(u8, t, "nil")) "NilClass"
            else if (std.mem.eql(u8, t, "boolean")) "TrueClass | FalseClass"
            else t;
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
        const trimmed = std.mem.trimLeft(u8, line_slice, " \t");
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
    var result = std.ArrayList(u8){};
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
    // Collect @deprecated prefix and extra tag sections
    var deprecated_msg: ?[]const u8 = null;
    var extras = std.ArrayList(u8){};
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, t, "@deprecated")) {
            deprecated_msg = std.mem.trim(u8, t["@deprecated".len..], " \t");
        } else if (std.mem.startsWith(u8, t, "@raise")) {
            const rest = std.mem.trim(u8, t["@raise".len..], " \t");
            extras.appendSlice(alloc, "\n\n**Raises:** ") catch {};
            extras.appendSlice(alloc, rest) catch {};
        } else if (std.mem.startsWith(u8, t, "@see")) {
            const rest = std.mem.trim(u8, t["@see".len..], " \t");
            extras.appendSlice(alloc, "\n\n**See also:** ") catch {};
            extras.appendSlice(alloc, rest) catch {};
        } else if (std.mem.startsWith(u8, t, "@overload")) {
            const rest = std.mem.trim(u8, t["@overload".len..], " \t");
            extras.appendSlice(alloc, "\n\n**Overload:** `") catch {};
            extras.appendSlice(alloc, rest) catch {};
            extras.appendSlice(alloc, "`") catch {};
        }
    }
    const extras_slice = extras.toOwnedSlice(alloc) catch "";
    defer if (extras_slice.len > 0) alloc.free(extras_slice);
    if (deprecated_msg == null and extras_slice.len == 0) return raw;
    var out = std.ArrayList(u8){};
    if (deprecated_msg) |msg| {
        out.appendSlice(alloc, "**Deprecated:**") catch { out.deinit(alloc); alloc.free(raw); return null; };
        if (msg.len > 0) { out.append(alloc, ' ') catch {}; out.appendSlice(alloc, msg) catch {}; }
        out.appendSlice(alloc, "\n\n") catch {};
    }
    out.appendSlice(alloc, raw) catch { out.deinit(alloc); alloc.free(raw); return null; };
    out.appendSlice(alloc, extras_slice) catch {};
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
            std.mem.eql(u8, mname, "cattr_writer") or std.mem.eql(u8, mname, "cattr_accessor")) {
            const writer_name = try std.fmt.allocPrint(ctx.alloc, "{s}=", .{attr_name});
            defer ctx.alloc.free(writer_name);
            try insertSymbol(ctx, "def", writer_name, lc.line, lc.col, null);
        }
    }
}

fn isRailsDsl(mname: []const u8) bool {
    const dsl = [_][]const u8{
        "scope",                   "belongs_to",   "has_many",              "has_one",
        "has_and_belongs_to_many", "validates",    "validates_presence_of", "validates_uniqueness_of",
        "before_action",           "after_action", "around_action",         "before_create",
        "after_create",            "before_save",  "after_save",            "before_destroy",
        "after_destroy",           "delegate",
        "rescue_from",             "helper_method",
        "around_create",           "around_save",  "around_destroy",
        "validates_format_of",     "validates_length_of", "validates_numericality_of",
        "enum",                    "serialize",    "store",                 "after_initialize",
        "before_validation",       "after_commit", "prepend_before_action",
        "validate",                "after_update", "before_update",         "around_update",
        "after_find",              "validates_inclusion_of", "validates_exclusion_of", "validates_with",
        // RSpec
        "describe", "context", "it", "let", "let!", "subject",
        "before", "after", "shared_examples_for", "shared_context",
        "shared_examples", "around",
        // Sinatra
        "get", "post", "put", "delete", "patch", "head", "options", "route",
        // Rake
        "task", "namespace", "file", "directory",
        // ActiveSupport class-level accessors
        "mattr_accessor", "mattr_reader", "mattr_writer",
        "cattr_accessor", "cattr_reader", "cattr_writer",
        // FactoryBot
        "factory", "trait", "sequence", "association",
        // ActiveSupport module hooks
        "included", "extended", "prepended",
        // Hanami
        "expose", "halt", "handle_exception", "formats", "accepts", "mount",
        // Grape
        "desc", "params", "requires", "optional", "group", "resource", "resources", "route_param",
        "helpers", "version", "default_format", "default_error_status", "content_type", "formatter",
        // Roda
        "plugin", "freeze", "hash_branch", "hash_routes",
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
        "each", "map", "flat_map", "select", "reject", "find",
        "each_with_object", "each_with_index", "collect", "detect",
        "filter", "filter_map", "inject", "reduce", "times", "upto",
        "downto", "step", "each_slice", "each_cons", "min_by", "max_by",
        "sort_by", "group_by", "tally", "then", "yield_self", "zip",
        "take_while", "drop_while", "partition", "count", "sum",
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
        "each",           "map",            "collect",        "select",
        "reject",         "filter",         "flat_map",       "filter_map",
        "take_while",     "drop_while",     "sort_by",        "min_by",
        "max_by",         "group_by",       "partition",      "count",
        "sum",            "zip",            "each_with_index", "each_with_object",
        "find",           "detect",         "inject",         "reduce",
        "tally",          "chunk",
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
            insertLocalVar(ctx.db, ctx.file_id, pname, lc.line, lc.col, elem_type, 60, ctx.scope_id) catch {};
            if (params_list.requireds.size > 1) {
                const p2: *const prism.RequiredParamNode = @ptrCast(@alignCast(params_list.requireds.nodes[1]));
                const pname2 = resolveConstant(ctx.parser, p2.name);
                const lc2 = locationLineCol(ctx.parser, p2.base.location.start);
                insertLocalVar(ctx.db, ctx.file_id, pname2, lc2.line, lc2.col, elem_type, 60, ctx.scope_id) catch {};
            }
        } else if (std.mem.eql(u8, method_name, "each_with_object") and params_list.requireds.size > 1) {
            insertLocalVar(ctx.db, ctx.file_id, pname, lc.line, lc.col, elem_type, 60, ctx.scope_id) catch {};
            const p2: *const prism.RequiredParamNode = @ptrCast(@alignCast(params_list.requireds.nodes[1]));
            const pname2 = resolveConstant(ctx.parser, p2.name);
            const lc2 = locationLineCol(ctx.parser, p2.base.location.start);
            insertLocalVar(ctx.db, ctx.file_id, pname2, lc2.line, lc2.col, accum_type orelse "Object", 60, ctx.scope_id) catch {};
        } else {
            insertLocalVar(ctx.db, ctx.file_id, pname, lc.line, lc.col, elem_type, 60, ctx.scope_id) catch {};
            if (std.mem.eql(u8, method_name, "each_with_index") and params_list.requireds.size > 1) {
                const p2: *const prism.RequiredParamNode = @ptrCast(@alignCast(params_list.requireds.nodes[1]));
                const pname2 = resolveConstant(ctx.parser, p2.name);
                const lc2 = locationLineCol(ctx.parser, p2.base.location.start);
                insertLocalVar(ctx.db, ctx.file_id, pname2, lc2.line, lc2.col, "Integer", 60, ctx.scope_id) catch {};
            }
        }
    }
}

fn inferAssocReturnType(alloc: std.mem.Allocator, mname: []const u8, assoc_name: []const u8) ?[]u8 {
    const is_plural = std.mem.eql(u8, mname, "has_many") or
                      std.mem.eql(u8, mname, "has_and_belongs_to_many");
    const is_singular = std.mem.eql(u8, mname, "belongs_to") or
                        std.mem.eql(u8, mname, "has_one");
    if (!is_plural and !is_singular) return null;
    var singular: []const u8 = assoc_name;
    if (std.mem.endsWith(u8, assoc_name, "ies") and assoc_name.len > 3) {
        const base = assoc_name[0 .. assoc_name.len - 3];
        const class_name = std.fmt.allocPrint(alloc, "{c}{s}y",
            .{ std.ascii.toUpper(base[0]), base[1..] }) catch return null;
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

fn insertRailsDslSymbols(ctx: *VisitCtx, cn: *const prism.CallNode, mname: []const u8) !void {
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
        if (std.mem.eql(u8, mname, "scope")) "def"
        else if (std.mem.eql(u8, mname, "shared_examples_for") or
                 std.mem.eql(u8, mname, "shared_context") or
                 std.mem.eql(u8, mname, "shared_examples")) "module"
        else if (std.mem.eql(u8, mname, "describe") or
                 std.mem.eql(u8, mname, "context") or
                 std.mem.eql(u8, mname, "it") or
                 std.mem.eql(u8, mname, "specify")) "test"
        else if (std.mem.eql(u8, mname, "let") or
                 std.mem.eql(u8, mname, "let!") or
                 std.mem.eql(u8, mname, "subject") or
                 std.mem.eql(u8, mname, "association")) "variable"
        else if (std.mem.eql(u8, mname, "factory") or
                 std.mem.eql(u8, mname, "trait")) "class"
        else "def";
    const assoc_return_type = inferAssocReturnType(ctx.alloc, mname, sym_name);
    defer if (assoc_return_type) |rt| ctx.alloc.free(rt);
    if (assoc_return_type) |rt| {
        try insertSymbolWithReturn(ctx, kind, sym_name, lc.line, lc.col, rt);
    } else if (std.mem.eql(u8, mname, "scope") and ctx.namespace_stack_len > 0) {
        var scope_buf: [270]u8 = undefined;
        var ns_buf: [256]u8 = undefined;
        const class_name = namespaceFromStack(ctx, &ns_buf);
        const scope_rt = if (class_name.len > 0) std.fmt.bufPrint(&scope_buf, "[{s}]", .{class_name}) catch null else null;
        if (scope_rt) |srt| {
            try insertSymbolWithReturn(ctx, kind, sym_name, lc.line, lc.col, srt);
        } else {
            try insertSymbol(ctx, kind, sym_name, lc.line, lc.col, null);
        }
    } else {
        try insertSymbol(ctx, kind, sym_name, lc.line, lc.col, null);
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
            const vlc = locationLineCol(ctx.parser, elem.*.location.start);
            try insertSymbol(ctx, "def", vsym.unescaped.source[0..vsym.unescaped.length], vlc.line, vlc.col, null);
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
            const vlc = locationLineCol(ctx.parser, assoc.key.*.location.start);
            try insertSymbol(ctx, "def", ksym.unescaped.source[0..ksym.unescaped.length], vlc.line, vlc.col, null);
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
            const vlc = locationLineCol(ctx.parser, assoc.key.*.location.start);
            try insertSymbol(ctx, "def", ksym.unescaped.source[0..ksym.unescaped.length], vlc.line, vlc.col, null);
        }
    }
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
            insertEnumValues(ctx, assoc.value) catch {};
        }
        return; // values already handled per-key above
    }

    const vn = values_node orelse return;
    try insertEnumValues(ctx, vn);
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
        @memcpy(prev[0..b.len + 1], curr[0..b.len + 1]);
    }
    return prev[b.len];
}

fn extractSorbetSig(source: []const u8, def_start: u32) ?[]const u8 {
    const scan_start = if (def_start > 300) def_start - 300 else 0;
    const scan_slice = source[scan_start..def_start];
    if (std.mem.lastIndexOf(u8, scan_slice, "returns(")) |ret_pos| {
        if (std.mem.lastIndexOf(u8, scan_slice[0..ret_pos], "sig")) |_| {
            const after_returns = scan_slice[ret_pos + 8..];
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
                var parts = std.ArrayList(u8){};
                defer parts.deinit(ctx.alloc);
                for (ctx.namespace_stack[0..ctx.namespace_stack_len]) |ns_part| {
                    if (parts.items.len > 0) parts.appendSlice(ctx.alloc, "::") catch {};
                    parts.appendSlice(ctx.alloc, ns_part) catch {};
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
            if (ns_pushed_class) { ctx.namespace_stack[ctx.namespace_stack_len] = short_name; ctx.namespace_stack_len += 1; }
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
                var parts = std.ArrayList(u8){};
                defer parts.deinit(ctx.alloc);
                for (ctx.namespace_stack[0..ctx.namespace_stack_len]) |ns_part| {
                    if (parts.items.len > 0) parts.appendSlice(ctx.alloc, "::") catch {};
                    parts.appendSlice(ctx.alloc, ns_part) catch {};
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
            if (ns_pushed_mod) { ctx.namespace_stack[ctx.namespace_stack_len] = short_name; ctx.namespace_stack_len += 1; }
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
                extractParams(ctx, sym_id, dn.parameters.?) catch {};
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
                            if (parseYardParam(d, pname, &yard_pbuf)) |yard_type| {
                                if (ctx.db.prepare("UPDATE params SET type_hint=? WHERE symbol_id=? AND position=?")) |u| {
                                    defer u.finalize();
                                    u.bind_text(1, yard_type);
                                    u.bind_int(2, sym_id);
                                    u.bind_int(3, @intCast(position));
                                    _ = u.step() catch {};
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
                            if (parseYardParam(d, pname, &yard_pbuf2)) |yard_type| {
                                if (ctx.db.prepare("UPDATE params SET type_hint=? WHERE symbol_id=? AND position=?")) |u| {
                                    defer u.finalize();
                                    u.bind_text(1, yard_type);
                                    u.bind_int(2, sym_id);
                                    u.bind_int(3, @intCast(position));
                                    _ = u.step() catch {};
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
                            _ = u.step() catch {};
                        } else |_| {}
                    }
                }
            }
            // Sorbet sig { returns(Type) } detection via source scanning
            if (sym_id > 0 and dn.base.location.start > 0) {
                const def_start = dn.base.location.start;
                const scan_start = if (def_start > 300) def_start - 300 else 0;
                const scan_slice = ctx.source[scan_start..def_start];
                if (std.mem.lastIndexOf(u8, scan_slice, "returns(")) |ret_pos| {
                    if (std.mem.lastIndexOf(u8, scan_slice[0..ret_pos], "sig")) |_| {
                        const after_returns = scan_slice[ret_pos + 8 ..];
                        if (std.mem.indexOf(u8, after_returns, ")")) |end| {
                            const type_str = std.mem.trim(u8, after_returns[0..end], " \t\n");
                            if (type_str.len > 0 and type_str.len < 64) {
                                if (ctx.db.prepare("UPDATE symbols SET return_type=? WHERE id=? AND return_type IS NULL")) |u| {
                                    defer u.finalize();
                                    u.bind_text(1, type_str);
                                    u.bind_int(2, sym_id);
                                    _ = u.step() catch {};
                                } else |_| {}
                            }
                        }
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
                            updateSymbolReturnType(ctx.db, sym_id, rt) catch {};
                        } else if (extractNewCallType(ctx.parser, last_node)) |rt| {
                            updateSymbolReturnType(ctx.db, sym_id, rt) catch {};
                        } else if (last_node.*.type == prism.NODE_RETURN) {
                            const rn: *const prism.ReturnNode = @ptrCast(@alignCast(last_node));
                            if (rn.arguments != null) {
                                const rargs = rn.arguments.?[0].arguments;
                                if (rargs.size > 0) {
                                    if (extractNewCallType(ctx.parser, rargs.nodes[0])) |rt| {
                                        updateSymbolReturnType(ctx.db, sym_id, rt) catch {};
                                    }
                                }
                            }
                        }
                    }
                } else {
                    // Endless method: def foo = expr — body is the expression directly
                    if (inferLiteralType(body)) |rt| {
                        updateSymbolReturnType(ctx.db, sym_id, rt) catch {};
                    } else if (extractNewCallType(ctx.parser, body)) |rt| {
                        updateSymbolReturnType(ctx.db, sym_id, rt) catch {};
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
            // Store value_snippet for literal constants (Phase 29)
            if (sym_id > 0) {
                const val = cn.value;
                const is_literal = switch (val.*.type) {
                    prism.NODE_INTEGER, prism.NODE_FLOAT,
                    prism.NODE_STRING, prism.NODE_SYMBOL,
                    prism.NODE_TRUE, prism.NODE_FALSE, prism.NODE_NIL => true,
                    else => false,
                };
                if (is_literal) {
                    const vstart = val.*.location.start;
                    const vlen = @min(val.*.location.length, 120);
                    if (@as(usize, vstart) + vlen <= ctx.source.len) {
                        const snippet = ctx.source[@as(usize, vstart)..@as(usize, vstart) + vlen];
                        if (ctx.db.prepare("UPDATE symbols SET value_snippet=? WHERE id=?")) |upd| {
                            defer upd.finalize();
                            upd.bind_text(1, snippet);
                            upd.bind_int(2, sym_id);
                            _ = upd.step() catch {};
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
                    (is_data_define and std.mem.eql(u8, receiver_name, "Data"))) {
                    // Upgrade kind to 'class' so dot-completion query finds members
                    if (sym_id > 0) {
                        if (ctx.db.prepare("UPDATE symbols SET kind='class' WHERE id=?")) |upd| {
                            defer upd.finalize();
                            upd.bind_int(1, sym_id);
                            _ = upd.step() catch {};
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
                                    insertSymbol(ctx, "def", sym_name, alc.line, alc.col, null) catch {};
                                    if (is_struct_new) {
                                        const writer_name = ctx.alloc.alloc(u8, sym_name.len + 1) catch continue;
                                        defer ctx.alloc.free(writer_name);
                                        @memcpy(writer_name[0..sym_name.len], sym_name);
                                        writer_name[sym_name.len] = '=';
                                        insertSymbol(ctx, "def", writer_name, alc.line, alc.col, null) catch {};
                                    }
                                }
                            }
                        }
                    }
                }
            }
        },
        prism.NODE_CONSTANT_OR_WRITE,
        prism.NODE_CONSTANT_AND_WRITE => {
            const cow: *const prism.ConstantOrWriteNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, cow.name_loc.start);
            const name = resolveConstant(ctx.parser, cow.name);
            var cw_pn_buf: [512]u8 = undefined;
            const cw_pn_str = namespaceFromStack(ctx, &cw_pn_buf);
            const cw_pn: ?[]const u8 = if (cw_pn_str.len > 0) cw_pn_str else null;
            _ = insertSymbolGetId(ctx, "constant", name, lc.line, lc.col, null, null, "public", cw_pn) catch 0;
            addSemToken(ctx, lc.line, lc.col, @intCast(name.len), 5);
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
        },
        prism.NODE_CONSTANT => {
            const rn: *const prism.ConstReadNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, rn.base.location.start);
            const name = resolveConstant(ctx.parser, rn.name);
            insertRef(ctx.db, ctx.file_id, name, lc.line, lc.col, null) catch {};
            addSemToken(ctx, lc.line, lc.col, @intCast(name.len), 5);
        },
        prism.NODE_CALL => {
            const cn: *const prism.CallNode = @ptrCast(@alignCast(n));
            const mname = resolveConstant(ctx.parser, cn.name);
            if (cn.receiver == null and std.mem.eql(u8, mname, "rescue_from")) {
                insertRescueFromHandler(ctx, cn) catch {};
            }
            if (cn.receiver == null and isAttrMethod(mname)) {
                insertAttrSymbols(ctx, cn, mname) catch {};
            }
            if (cn.receiver == null and std.mem.eql(u8, mname, "enum")) {
                insertEnumSymbols(ctx, cn) catch {};
            } else if (cn.receiver == null and isRailsDsl(mname)) {
                insertRailsDslSymbols(ctx, cn, mname) catch {};
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
                                insertSymbol(ctx, "def", src[0..sym.unescaped.length], lc.line, lc.col, null) catch {};
                            }
                        }
                    }
                    if (args.size >= 2) {
                        const second = args.nodes[1];
                        if (second.*.type == prism.NODE_SYMBOL) {
                            const sym2: *const prism.SymbolNode = @ptrCast(@alignCast(second));
                            if (sym2.unescaped.source) |src2| {
                                const lc2 = locationLineCol(ctx.parser, second.*.location.start);
                                insertRef(ctx.db, ctx.file_id, src2[0..sym2.unescaped.length], lc2.line, lc2.col, null) catch {};
                            }
                        } else if (second.*.type == prism.NODE_STRING) {
                            const sn2: *const prism.StringNode = @ptrCast(@alignCast(second));
                            if (sn2.unescaped.source) |src2| {
                                const lc2 = locationLineCol(ctx.parser, second.*.location.start);
                                insertRef(ctx.db, ctx.file_id, src2[0..sn2.unescaped.length], lc2.line, lc2.col, null) catch {};
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
                            insertSymbol(ctx, "def", src[0..sym.unescaped.length], lc.line, lc.col, null) catch {};
                        }
                    } else if (args.size > 0 and args.nodes[0].*.type == prism.NODE_STRING) {
                        const sn: *const prism.StringNode = @ptrCast(@alignCast(args.nodes[0]));
                        if (sn.unescaped.source) |src| {
                            const lc = locationLineCol(ctx.parser, args.nodes[0].*.location.start);
                            insertSymbol(ctx, "def", src[0..sn.unescaped.length], lc.line, lc.col, null) catch {};
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
                            insertSymbol(ctx, "classdef", src[0..sym.unescaped.length], lc.line, lc.col, null) catch {};
                        }
                    } else if (args.size > 0 and args.nodes[0].*.type == prism.NODE_STRING) {
                        const sn: *const prism.StringNode = @ptrCast(@alignCast(args.nodes[0]));
                        if (sn.unescaped.source) |src| {
                            const lc = locationLineCol(ctx.parser, args.nodes[0].*.location.start);
                            insertSymbol(ctx, "classdef", src[0..sn.unescaped.length], lc.line, lc.col, null) catch {};
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
                                insertSymbol(ctx, "classdef", src[0..sym.unescaped.length], lc.line, lc.col, null) catch {};
                                // Also mark the existing instance def as private
                                if (ctx.db.prepare("UPDATE symbols SET visibility='private' WHERE file_id=? AND name=? AND kind='def'")) |u| {
                                    defer u.finalize();
                                    u.bind_int(1, ctx.file_id);
                                    u.bind_text(2, src[0..sym.unescaped.length]);
                                    _ = u.step() catch {};
                                } else |_| {}
                            }
                        }
                    }
                } else {
                    // bare module_function — enable mode for subsequent defs
                    ctx.module_function_mode = true;
                }
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
                            if (ctx.db.prepare(
                                "UPDATE symbols SET visibility=? WHERE file_id=? AND name=? AND kind IN ('def','classdef')"
                            )) |upd| {
                                defer upd.finalize();
                                upd.bind_text(1, new_vis);
                                upd.bind_int(2, ctx.file_id);
                                upd.bind_text(3, method_name);
                                _ = upd.step() catch {};
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
                            insertMixin(ctx.db, ctx.current_class_id.?, mod_name, mname) catch {};
                        } else if (arg.*.type == prism.NODE_CONSTANT_PATH) {
                            const mod_owned = buildQualifiedName(ctx.parser, arg, ctx.alloc) catch null;
                            defer if (mod_owned) |m| ctx.alloc.free(m);
                            const mod_name: []const u8 = mod_owned orelse blk: {
                                const cp: *const prism.ConstantPathNode = @ptrCast(@alignCast(arg));
                                break :blk if (cp.name != 0) resolveConstant(ctx.parser, cp.name) else "";
                            };
                            if (mod_name.len > 0) insertMixin(ctx.db, ctx.current_class_id.?, mod_name, mname) catch {};
                        }
                    }
                }
            }
            // Visibility setter detection: private/protected/public (no receiver)
            if (cn.receiver == null) {
                const is_priv = std.mem.eql(u8, mname, "private");
                const is_prot = std.mem.eql(u8, mname, "protected");
                const is_pub  = std.mem.eql(u8, mname, "public");
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
                        insertSymbol(ctx, "def", dname, dlc.line, dlc.col, null) catch {};
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
                        insertSymbol(ctx, "def", dname, dlc.line, dlc.col, null) catch {};
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
                        if (ctx.db.prepare(
                            "SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1"
                        )) |lv_stmt| {
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
                                            insertBlockParams(ctx, block_node, e, mname, accum_t) catch {};
                                        }
                                    }
                                }
                            }
                        } else |_| {}
                        if (!db_hit and rv_name.len > 3 and rv_name[rv_name.len - 1] == 's') {
                            const base = rv_name[0..rv_name.len - 1];
                            const buf = ctx.alloc.alloc(u8, base.len) catch null;
                            if (buf) |b| {
                                defer ctx.alloc.free(b);
                                @memcpy(b, base);
                                b[0] = std.ascii.toUpper(b[0]);
                                const block_generic = cn.block.?;
                                if (block_generic.*.type == prism.NODE_BLOCK) {
                                    const block_node: *const prism.BlockNode = @ptrCast(@alignCast(block_generic));
                                    insertBlockParams(ctx, block_node, b, mname, accum_t) catch {};
                                }
                            }
                        }
                    } else if (recv.*.type == prism.NODE_INSTANCE_VAR_READ) {
                        const rv: *const prism.InstanceVarReadNode = @ptrCast(@alignCast(recv));
                        const rv_name = resolveConstant(ctx.parser, rv.name);
                        if (ctx.db.prepare(
                            "SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1"
                        )) |lv| {
                            defer lv.finalize();
                            lv.bind_int(1, ctx.file_id);
                            lv.bind_text(2, rv_name);
                            if (lv.step() catch false) {
                                const ivar_type = lv.column_text(0);
                                if (ivar_type.len > 0 and cn.block.?.*.type == prism.NODE_BLOCK) {
                                    const block_node: *const prism.BlockNode = @ptrCast(@alignCast(cn.block.?));
                                    insertBlockParams(ctx, block_node, ivar_type, mname, accum_t) catch {};
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
                                    insertBlockParams(ctx, block_node, class_name, mname, accum_t) catch {};
                                }
                            }
                        }
                    } else if (inferLiteralType(recv)) |lit_type| {
                        if (cn.block.?.*.type == prism.NODE_BLOCK) {
                            const block_node: *const prism.BlockNode = @ptrCast(@alignCast(cn.block.?));
                            insertBlockParams(ctx, block_node, lit_type, mname, accum_t) catch {};
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
                            if (ctx.db.prepare(
                                "SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1"
                            )) |np_stmt| {
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
                            insertLocalVar(ctx.db, ctx.file_id, nname, nb_lc.line, nb_lc.col, np_type, 50, ctx.scope_id) catch {};
                        }
                    }
                }
            }
            const lc = locationLineCol(ctx.parser, cn.message_loc.start);
            insertRef(ctx.db, ctx.file_id, mname, lc.line, lc.col, null) catch {};
        },
        prism.NODE_ALIAS_METHOD => {
            const an: *const prism.AliasMethodNode = @ptrCast(@alignCast(n));
            if (an.new_name.*.type == prism.NODE_SYMBOL) {
                const nsym: *const prism.SymbolNode = @ptrCast(@alignCast(an.new_name));
                if (nsym.unescaped.source) |src| {
                    const lc = locationLineCol(ctx.parser, an.new_name.*.location.start);
                    insertSymbol(ctx, "def", src[0..nsym.unescaped.length], lc.line, lc.col, null) catch {};
                }
            }
            if (an.old_name.*.type == prism.NODE_SYMBOL) {
                const osym: *const prism.SymbolNode = @ptrCast(@alignCast(an.old_name));
                if (osym.unescaped.source) |src| {
                    const lc = locationLineCol(ctx.parser, an.old_name.*.location.start);
                    insertRef(ctx.db, ctx.file_id, src[0..osym.unescaped.length], lc.line, lc.col, null) catch {};
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
            insertRef(ctx.db, ctx.file_id, name, lc.line, lc.col, ctx.scope_id) catch {};
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
                insertRef(ctx.db, ctx.file_id, ref_name, lc.line, lc.col, null) catch {};
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
                                        insertLocalVarClassId(ctx.db, ctx.file_id, name, lc.line, lc.col, rt, 0, ctx.current_class_id) catch {};
                                        iv_inserted = true;
                                    }
                                }
                            } else |_| {}
                        }
                    }
                }
            }
            if (!iv_inserted) insertLocalVarClassId(ctx.db, ctx.file_id, name, lc.line, lc.col, type_hint, 0, ctx.current_class_id) catch {};
        },
        prism.NODE_INSTANCE_VAR_OR_WRITE,
        prism.NODE_INSTANCE_VAR_AND_WRITE => {
            const iv: *const prism.InstanceVarOrWriteNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, iv.name_loc.start);
            const name = resolveConstant(ctx.parser, iv.name);
            const rtype = if (iv.value != null)
                inferLiteralType(iv.value.?) orelse extractNewCallType(ctx.parser, iv.value.?)
            else null;
            insertLocalVarClassId(ctx.db, ctx.file_id, name, lc.line, lc.col, rtype, 0, ctx.current_class_id) catch {};
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
        },
        prism.NODE_CLASS_VAR_WRITE => {
            const cvw: *const prism.ClassVarWriteNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, cvw.name_loc.start);
            const name = resolveConstant(ctx.parser, cvw.name);
            insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, null, 0, null) catch {};
        },
        prism.NODE_CLASS_VAR_OR_WRITE,
        prism.NODE_CLASS_VAR_AND_WRITE => {
            const cvw: *const prism.ClassVarOrWriteNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, cvw.name_loc.start);
            const name = resolveConstant(ctx.parser, cvw.name);
            insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, null, 0, null) catch {};
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
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
                                "find", "first", "last", "create", "create!", "build",
                                "find_by", "find_by!", "take", "new",
                            };
                            const ar_plural = [_][]const u8{
                                "where", "all", "order", "limit", "includes", "joins",
                                "preload", "eager_load", "select", "group", "having",
                                "left_joins", "left_outer_joins", "distinct",
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
                                const ar_plural_set = [_][]const u8{ "where", "all", "order", "limit",
                                    "includes", "joins", "preload", "eager_load", "select", "group",
                                    "having", "left_joins", "left_outer_joins", "distinct", "scoped", "unscoped" };
                                const inner_is_pl = for (ar_plural_set) |m| {
                                    if (std.mem.eql(u8, inner_ar_mname, m)) break true;
                                } else false;
                                if (inner_is_pl) {
                                    if (inner_ar.receiver) |class_ar| {
                                        if (class_ar.*.type == prism.NODE_CONSTANT) {
                                            const rc3: *const prism.ConstReadNode = @ptrCast(@alignCast(class_ar));
                                            const cname3 = resolveConstant(ctx.parser, rc3.name);
                                            const ar_sing_set = [_][]const u8{ "first", "last", "find",
                                                "find_by", "find_by!", "take", "create", "create!", "build" };
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
            // self.method: look up return_type in current class (Phase 29, confidence=75)
            if (!inserted and type_hint == null) {
                if (lv.value) |val| {
                    if (val.*.type == prism.NODE_CALL) {
                        const cn2: *const prism.CallNode = @ptrCast(@alignCast(val));
                        if (cn2.receiver) |recv2| {
                            if (recv2.*.type == prism.NODE_SELF) {
                                if (ctx.current_class_id) |cid| {
                                    const called = resolveConstant(ctx.parser, cn2.name);
                                    if (ctx.db.prepare(
                                        "SELECT s.return_type FROM symbols s " ++
                                        "WHERE s.name=? AND s.kind IN ('def','classdef') " ++
                                        "AND s.file_id=(SELECT file_id FROM symbols WHERE id=?) " ++
                                        "AND s.return_type IS NOT NULL LIMIT 1"
                                    )) |ss| {
                                        defer ss.finalize();
                                        ss.bind_text(1, called);
                                        ss.bind_int(2, cid);
                                        if (ss.step() catch false) {
                                            const rt = ss.column_text(0);
                                            if (rt.len > 0) {
                                                insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, rt, 75, ctx.scope_id) catch {};
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
                                if (ctx.db.prepare(
                                    "SELECT type_hint FROM local_vars " ++
                                    "WHERE name=? AND type_hint IS NOT NULL " ++
                                    "ORDER BY CASE WHEN file_id=? THEN 0 ELSE 1 END, confidence DESC, line DESC LIMIT 1"
                                )) |rs2| {
                                    defer rs2.finalize();
                                    rs2.bind_text(1, recv_name);
                                    rs2.bind_int(2, ctx.file_id);
                                    if (rs2.step() catch false) {
                                        const recv_type = rs2.column_text(0);
                                        if (recv_type.len > 0) {
                                            if (ctx.db.prepare(
                                                "SELECT return_type FROM symbols " ++
                                                "WHERE name=? AND kind='def' AND file_id IN " ++
                                                "(SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?) " ++
                                                "AND return_type IS NOT NULL LIMIT 1"
                                            )) |cs| {
                                                defer cs.finalize();
                                                cs.bind_text(1, called);
                                                cs.bind_text(2, recv_type);
                                                if (cs.step() catch false) {
                                                    const rt = cs.column_text(0);
                                                    if (rt.len > 0) {
                                                        insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, rt, 55, ctx.scope_id) catch {};
                                                        inserted = true;
                                                    }
                                                }
                                            } else |_| {}
                                            if (!inserted) {
                                                if (lookupStdlibReturn(recv_type, called)) |stdlib_rt| {
                                                    insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, stdlib_rt, 55, ctx.scope_id) catch {};
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
                    const r1 = ctx.db.prepare(
                        "SELECT type_hint FROM local_vars WHERE name=? " ++
                        "AND type_hint IS NOT NULL ORDER BY confidence DESC LIMIT 1"
                    ) catch break :blk2;
                    defer r1.finalize();
                    r1.bind_text(1, root_name);
                    if (!(r1.step() catch false)) break :blk2;
                    const rt_raw = r1.column_text(0);
                    const rt_len = @min(rt_raw.len, root_type_storage.len);
                    @memcpy(root_type_storage[0..rt_len], rt_raw[0..rt_len]);
                    current_type = root_type_storage[0..rt_len];
                } else break :blk2;

                // Resolve types through the chain (reverse order: root → leaf)
                var step_buf: [128]u8 = undefined;
                var step_idx: u8 = chain_len;
                while (step_idx > 1) {
                    step_idx -= 1;
                    const method_name = chain_methods[step_idx];
                    // Strip generic brackets for class lookup
                    const base_type = if (std.mem.indexOfScalar(u8, current_type, '[')) |bracket|
                        current_type[0..bracket]
                    else
                        current_type;
                    var found = false;
                    if (ctx.db.prepare(
                        "SELECT return_type FROM symbols WHERE name=? AND kind='def' " ++
                        "AND file_id IN (SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?) " ++
                        "AND return_type IS NOT NULL LIMIT 1"
                    )) |rs| {
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
                            const ft_len = @min(stdlib_rt.len, root_type_storage.len);
                            @memcpy(root_type_storage[0..ft_len], stdlib_rt[0..ft_len]);
                            current_type = root_type_storage[0..ft_len];
                            found = true;
                        }
                    }
                    if (!found) {
                        const is_ar_plural = for ([_][]const u8{ "where", "all", "order", "limit",
                            "includes", "joins", "scoped", "preload", "eager_load", "distinct",
                            "group", "having", "reorder", "rewhere" }) |m|
                        {
                            if (std.mem.eql(u8, method_name, m)) break true;
                        } else false;
                        if (is_ar_plural) {
                            current_type = std.fmt.bufPrint(&root_type_storage, "[{s}]", .{base_type}) catch break :blk2;
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
                if (ctx.db.prepare(
                    "SELECT return_type FROM symbols WHERE name=? AND kind='def' " ++
                    "AND file_id IN (SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?) " ++
                    "AND return_type IS NOT NULL LIMIT 1"
                )) |rs| {
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
                    insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, lt, confidence, ctx.scope_id) catch {};
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
                        insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, brt, 50, ctx.scope_id) catch {};
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
                                        insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, rt, 0, ctx.scope_id) catch {};
                                        inserted = true;
                                    }
                                }
                            } else |_| {}
                        }
                    }
                }
            }

            if (!inserted) insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, type_hint, 0, ctx.scope_id) catch {};
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
                        const bp: *const prism.BlockParametersNode = @ptrCast(@alignCast(lam.parameters.?));
                        if (bp.parameters != null) {
                            extractParams(ctx, sym_id, bp.parameters.?) catch {};
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
                    insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, rtype, 0, ctx.scope_id) catch {};
                }
            } else if (mw.lefts.size == 1 and mw.value != null) {
                const left = mw.lefts.nodes[0];
                if (left.*.type == prism.NODE_LOCAL_VAR_TARGET) {
                    const lt: *const prism.LocalVarTargetNode = @ptrCast(@alignCast(left));
                    const lname = resolveConstant(ctx.parser, lt.name);
                    const llc = locationLineCol(ctx.parser, left.*.location.start);
                    const rtype = extractNewCallType(ctx.parser, mw.value.?);
                    insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, rtype, 0, ctx.scope_id) catch {};
                }
            }
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
        },
        prism.NODE_FOR => {
            const fn_node: *const prism.ForNode = @ptrCast(@alignCast(n));
            if (fn_node.index.*.type == prism.NODE_LOCAL_VAR_TARGET) {
                const lt: *const prism.LocalVarTargetNode = @ptrCast(@alignCast(fn_node.index));
                const lname = resolveConstant(ctx.parser, lt.name);
                const llc = locationLineCol(ctx.parser, fn_node.index.*.location.start);
                const coll_type = extractNewCallType(ctx.parser, fn_node.collection);
                const elem_type = stripArrayBrackets(coll_type);
                insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, elem_type, 50, ctx.scope_id) catch {};
            }
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
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
                insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, exc_type, 80, ctx.scope_id) catch {};
            }
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
        },
        prism.NODE_RESCUE_MODIFIER => {
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
        },
        prism.NODE_LOCAL_VAR_OR_WRITE => {
            const lw: *const prism.LocalVarOrWriteNode = @ptrCast(@alignCast(n));
            const lname = resolveConstant(ctx.parser, lw.name);
            const llc = locationLineCol(ctx.parser, lw.name_loc.start);
            const rtype = if (lw.value) |val| inferLiteralType(val) orelse extractNewCallType(ctx.parser, val) else null;
            insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, rtype, 20, ctx.scope_id) catch {};
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
        },
        prism.NODE_LOCAL_VAR_AND_WRITE => {
            const lw: *const prism.LocalVarAndWriteNode = @ptrCast(@alignCast(n));
            const lname = resolveConstant(ctx.parser, lw.name);
            const llc = locationLineCol(ctx.parser, lw.name_loc.start);
            const rtype = if (lw.value) |val| inferLiteralType(val) orelse extractNewCallType(ctx.parser, val) else null;
            insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, rtype, 15, ctx.scope_id) catch {};
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
        },
        prism.NODE_LOCAL_VAR_OP_WRITE => {
            const lw: *const prism.LocalVarOpWriteNode = @ptrCast(@alignCast(n));
            const lname = resolveConstant(ctx.parser, lw.name);
            const llc = locationLineCol(ctx.parser, lw.name_loc.start);
            insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, null, 20, ctx.scope_id) catch {};
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
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
            insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, pat_type, 85, ctx.scope_id) catch {};
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        // Control flow: visit children so body vars get indexed (Phase 29)
        prism.NODE_WHILE,
        prism.NODE_UNTIL,
        prism.NODE_UNLESS => {
            const unless_node: *const prism.IfNode = @ptrCast(@alignCast(n));
            if (unless_node.predicate) |cond| {
                // `unless x.nil?` → x is not nil in the body
                if (detectNilGuard(ctx.parser, cond)) |var_name| {
                    const guard_lc = locationLineCol(ctx.parser, cond.*.location.start);
                    insertLocalVar(ctx.db, ctx.file_id, var_name, guard_lc.line, guard_lc.col, "Object", 80, ctx.scope_id) catch {};
                }
            }
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        prism.NODE_ENSURE,
        prism.NODE_YIELD,
        prism.NODE_SUPER,
        prism.NODE_FORWARDING_SUPER,
        prism.NODE_CALL_AND_WRITE,
        prism.NODE_CALL_OR_WRITE => {
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        // Global variable write: index with scope_id=null (Phase 29)
        prism.NODE_GLOBAL_VAR_WRITE => {
            const gv: *const prism.GlobalVarWriteNode = @ptrCast(@alignCast(n));
            const gname = resolveConstant(ctx.parser, gv.name);
            const glc = locationLineCol(ctx.parser, n.*.location.start);
            const gval_type: ?[]const u8 = if (gv.value != null) blk: {
                break :blk inferLiteralType(gv.value.?)
                    orelse extractNewCallType(ctx.parser, gv.value.?);
            } else null;
            insertLocalVar(ctx.db, ctx.file_id, gname, glc.line, glc.col, gval_type, 70, null) catch {};
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
            return false;
        },
        prism.NODE_GLOBAL_VAR_OR_WRITE,
        prism.NODE_GLOBAL_VAR_AND_WRITE => {
            const gv: *const prism.GlobalVarOrWriteNode = @ptrCast(@alignCast(n));
            const gname = resolveConstant(ctx.parser, gv.name);
            const glc = locationLineCol(ctx.parser, gv.name_loc.start);
            insertLocalVar(ctx.db, ctx.file_id, gname, glc.line, glc.col, null, 70, null) catch {};
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
        },
        prism.NODE_IF => {
            const if_node: *const prism.IfNode = @ptrCast(@alignCast(n));
            if (if_node.predicate) |cond| {
                if (detectTypeGuard(ctx.parser, cond)) |guard| {
                    const guard_lc = locationLineCol(ctx.parser, cond.*.location.start);
                    insertLocalVar(ctx.db, ctx.file_id, guard.name, guard_lc.line, guard_lc.col, guard.narrowed_type, 85, ctx.scope_id) catch {};
                }
            }
            prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
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

fn insertSymbolWithReturn(ctx: *VisitCtx, kind: []const u8, name: []const u8, line: i32, col: u32, return_type: ?[]const u8) !void {
    const stmt = try ctx.db.prepare(
        \\INSERT OR IGNORE INTO symbols (file_id, name, kind, line, col, return_type)
        \\VALUES (?, ?, ?, ?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, ctx.file_id);
    stmt.bind_text(2, name);
    stmt.bind_text(3, kind);
    stmt.bind_int(4, line);
    stmt.bind_int(5, @intCast(col));
    if (return_type) |rt| stmt.bind_text(6, rt) else stmt.bind_null(6);
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

fn insertRbsSymbol(db: db_mod.Db, file_id: i64, kind: []const u8, name: []const u8, line: i32, col: u32) !void {
    const stmt = try db.prepare(
        \\INSERT OR IGNORE INTO symbols (file_id, name, kind, line, col)
        \\VALUES (?, ?, ?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_text(2, name);
    stmt.bind_text(3, kind);
    stmt.bind_int(4, line);
    stmt.bind_int(5, @intCast(col));
    _ = try stmt.step();
}

fn insertRbsSymbolWithReturn(db: db_mod.Db, file_id: i64, kind: []const u8, name: []const u8, line: i32, col: u32, return_type: []const u8) !void {
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
        \\INSERT OR IGNORE INTO symbols (file_id, name, kind, line, col, return_type)
        \\VALUES (?, ?, ?, ?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_text(2, name);
    stmt.bind_text(3, kind);
    stmt.bind_int(4, line);
    stmt.bind_int(5, @intCast(col));
    stmt.bind_text(6, return_type);
    _ = try stmt.step();
}

fn indexRbs(db: db_mod.Db, file_id: i64, source: []const u8) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_num: i32 = 1;

    while (lines.next()) |raw_line| : (line_num += 1) {
        const line = std.mem.trim(u8, raw_line, " \t");

        if (std.mem.startsWith(u8, line, "class ") or std.mem.startsWith(u8, line, "module ")) {
            const kw_len: usize = if (line[0] == 'c') 6 else 7;
            const name_end = std.mem.indexOfScalar(u8, line[kw_len..], ' ') orelse line.len - kw_len;
            const name = line[kw_len .. kw_len + name_end];
            if (name.len == 0) continue;
            const kind: []const u8 = if (line[0] == 'c') "class" else "module";
            insertRbsSymbol(db, file_id, kind, name, line_num, 0) catch {};
            continue;
        }

        if (std.mem.startsWith(u8, line, "def ")) {
            const rest = line[4..];
            const colon_pos = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
            const name = std.mem.trim(u8, rest[0..colon_pos], " ");
            const arrow_pos = std.mem.lastIndexOf(u8, rest, "->") orelse {
                insertRbsSymbol(db, file_id, "def", name, line_num, 0) catch {};
                continue;
            };
            const rt = std.mem.trim(u8, rest[arrow_pos + 2 ..], " ");
            if (rt.len > 0 and !std.mem.eql(u8, rt, "void")) {
                insertRbsSymbolWithReturn(db, file_id, "def", name, line_num, 0, rt) catch {};
            } else {
                insertRbsSymbol(db, file_id, "def", name, line_num, 0) catch {};
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "interface ")) {
            const rest = line["interface ".len..];
            const end = std.mem.indexOfAny(u8, rest, " \t\r\n{") orelse rest.len;
            const name = std.mem.trim(u8, rest[0..end], " \t");
            if (name.len > 0)
                insertRbsSymbol(db, file_id, "module", name, line_num, 0) catch {};
            continue;
        }

        if (std.mem.startsWith(u8, line, "type ")) {
            const rest = line["type ".len..];
            const end = std.mem.indexOfAny(u8, rest, " \t\r\n=") orelse rest.len;
            const name = std.mem.trim(u8, rest[0..end], " \t");
            if (name.len > 0)
                insertRbsSymbol(db, file_id, "constant", name, line_num, 0) catch {};
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
            const rt = std.mem.trim(u8, rest[colon + 1 ..], " ");
            if (!std.mem.startsWith(u8, line, "attr_writer ")) {
                insertRbsSymbolWithReturn(db, file_id, "def", attr_name, line_num, 0, rt) catch {};
            }
            if (std.mem.startsWith(u8, line, "attr_writer ") or
                std.mem.startsWith(u8, line, "attr_accessor "))
            {
                var writer_buf: [256]u8 = undefined;
                const writer_name = std.fmt.bufPrint(&writer_buf, "{s}=", .{attr_name}) catch continue;
                insertRbsSymbol(db, file_id, "def", writer_name, line_num, 0) catch {};
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
            std.mem.eql(u8, method_name, "inspect")) return "String";
        if (std.mem.eql(u8, method_name, "to_sym") or
            std.mem.eql(u8, method_name, "upcase") or
            std.mem.eql(u8, method_name, "downcase") or
            std.mem.eql(u8, method_name, "to_proc")) return "Symbol";
        if (std.mem.eql(u8, method_name, "length") or
            std.mem.eql(u8, method_name, "size")) return "Integer";
        if (std.mem.eql(u8, method_name, "match?") or
            std.mem.eql(u8, method_name, "empty?")) return "TrueClass";
    }
    // ActiveSupport methods — harmless on non-Rails codebases
    if (std.mem.eql(u8, method_name, "blank?") or
        std.mem.eql(u8, method_name, "present?") or
        std.mem.eql(u8, method_name, "in?")) return "TrueClass";
    if (std.mem.eql(u8, method_name, "with_indifferent_access") or
        std.mem.eql(u8, method_name, "deep_symbolize_keys") or
        std.mem.eql(u8, method_name, "deep_stringify_keys")) return "Hash";
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

pub fn getDiags(path: []const u8, alloc: std.mem.Allocator) ![]DiagEntry {
    const source = std.fs.cwd().readFileAllocOptions(
        alloc,
        path,
        8 * 1024 * 1024,
        null,
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

    var list = std.ArrayList(DiagEntry){};
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

    var list = std.ArrayList(DiagEntry){};
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
    var diags = std.ArrayList(DiagEntry){};

    // Unused local variable detection: local_vars not referenced in refs within same file
    // Skip names starting with _ (convention for intentionally unused)
    const unused_stmt = db.prepare(
        \\SELECT lv.name, lv.line, lv.col FROM local_vars lv
        \\WHERE lv.file_id = ? AND lv.name NOT LIKE '\_%' ESCAPE '\'
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

    // Undefined method with fuzzy "did you mean?" suggestions
    // Check refs that look like method calls against known symbols
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

    return diags;
}

pub fn reindex(db: db_mod.Db, paths: []const []const u8, is_gem: bool, alloc: std.mem.Allocator, max_file_size: usize) !void {
    try db.begin();
    var committed = false;
    defer if (!committed) {
        db.rollback() catch {};
    };

    for (paths) |path| {
        // Check mtime; fast-skip unchanged files
        const stat = std.fs.cwd().statFile(path) catch continue;
        const disk_mtime: i64 = @intCast(@divTrunc(stat.mtime, std.time.ns_per_ms));

        const check = try db.prepare("SELECT mtime, content_hash FROM files WHERE path = ?");
        defer check.finalize();
        check.bind_text(1, path);
        const has_existing = try check.step();
        var db_mtime: i64 = -1;
        var db_hash: i64 = 0;
        if (has_existing) {
            db_mtime = check.column_int(0);
            db_hash = check.column_int(1);
            if (db_mtime == disk_mtime and db_hash != 0) continue;
        }

        const source = std.fs.cwd().readFileAllocOptions(
            alloc,
            path,
            max_file_size,
            null,
            .@"1",
            0,
        ) catch |err| {
            if (err == error.StreamTooLong) {
                var buf: [512]u8 = undefined;
                const msg = if (max_file_size == 8 * 1024 * 1024)
                    std.fmt.bufPrint(&buf, "refract: skipping {s} (>8MB)\n", .{path}) catch "refract: skipping file (too large)\n"
                else
                    std.fmt.bufPrint(&buf, "refract: skipping {s} (file too large)\n", .{path}) catch "refract: skipping file (too large)\n";
                std.fs.File.stderr().writeAll(msg) catch {};
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

        // Routes: index config/routes*.rb files
        if (std.mem.containsAtLeast(u8, path, 1, "config/routes") and
            std.mem.endsWith(u8, path, ".rb"))
        {
            routes_mod.indexRoutes(db, file_id, source[0 .. source.len - 1], alloc) catch {};
        }

        // RBS: parse type signatures directly, skip Prism
        if (std.mem.endsWith(u8, path, ".rbs")) {
            deleteSymbolData(db, file_id);
            try indexRbs(db, file_id, source[0 .. source.len - 1]);
            continue;
        }

        if (std.mem.containsAtLeast(u8, path, 1, "locales/") and
            (std.mem.endsWith(u8, path, ".yml") or std.mem.endsWith(u8, path, ".yaml"))) {
            i18n_mod.indexLocaleFile(db, file_id, source[0 .. source.len - 1]);
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
            .sem_tokens = std.ArrayList(SemToken){},
            .source = parse_source,
        };
        defer ctx.sem_tokens.deinit(alloc);

        prism.visit_node(root, visitor, &ctx);

        if (ctx.error_count > 0) {
            var ebuf: [256]u8 = undefined;
            const emsg = std.fmt.bufPrint(&ebuf,
                "refract: {d} index error(s) in {s} (DB full or schema mismatch?)\n",
                .{ ctx.error_count, path }) catch "refract: index errors occurred\n";
            std.fs.File.stderr().writeAll(emsg) catch {};
        }

        storeSemTokens(db, file_id, ctx.sem_tokens.items, alloc) catch {};
    }

    try db.commit();
    committed = true;
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
    defer if (!committed) { real_db.rollback() catch {}; };

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
        const rt = sel_sym.column_text(5); if (rt.len > 0) ins_sym.bind_text(6, rt) else ins_sym.bind_null(6);
        const doc = sel_sym.column_text(6); if (doc.len > 0) ins_sym.bind_text(7, doc) else ins_sym.bind_null(7);
        if (sel_sym.column_type(7) != 5) ins_sym.bind_int(8, sel_sym.column_int(7)) else ins_sym.bind_null(8);
        ins_sym.bind_text(9, sel_sym.column_text(8));
        const pn = sel_sym.column_text(9); if (pn.len > 0) ins_sym.bind_text(10, pn) else ins_sym.bind_null(10);
        const vs = sel_sym.column_text(10); if (vs.len > 0) ins_sym.bind_text(11, vs) else ins_sym.bind_null(11);
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
        const th = sel_p.column_text(4); if (th.len > 0) ins_p.bind_text(5, th) else ins_p.bind_null(5);
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
        const th = sel_lv.column_text(3); if (th.len > 0) ins_lv.bind_text(5, th) else ins_lv.bind_null(5);
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
        .sem_tokens = std.ArrayList(SemToken){},
        .source = src,
    };
    defer ctx.sem_tokens.deinit(alloc);

    prism.visit_node(root, visitor, &ctx);

    storeSemTokens(db, file_id, ctx.sem_tokens.items, alloc) catch {};
}

pub fn cleanupStale(db: db_mod.Db, scanned: []const []const u8, root_path: []const u8, alloc: std.mem.Allocator) !void {
    var disk_set = std.StringHashMap(void).init(alloc);
    defer disk_set.deinit();
    for (scanned) |p| try disk_set.put(p, {});

    // Only consider files under root_path so extra_roots are never wrongly deleted
    const like_pat = try std.fmt.allocPrint(alloc, "{s}/%", .{root_path});
    defer alloc.free(like_pat);
    const sel = try db.prepare("SELECT path FROM files WHERE is_gem=0 AND path LIKE ? ESCAPE '\\'");
    defer sel.finalize();
    sel.bind_text(1, like_pat);
    var stale = std.ArrayList([]u8){};
    defer {
        for (stale.items) |p| alloc.free(p);
        stale.deinit(alloc);
    }
    while (try sel.step()) {
        const p = sel.column_text(0);
        if (!disk_set.contains(p)) try stale.append(alloc, try alloc.dupe(u8, p));
    }

    if (stale.items.len == 0) return;

    try db.begin();
    var committed = false;
    defer if (!committed) {
        db.rollback() catch {};
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
    std.fs.deleteFileAbsolute(db_path) catch {};
    const db = try db_mod.Db.open(db_path);
    defer db.close();
    defer std.fs.deleteFileAbsolute(db_path) catch {};
    try db.init_schema();

    try db.exec("INSERT INTO files (path, mtime, is_gem) VALUES ('/gems/activesupport/core.rb', 999, 1)");

    const project_paths = [_][]const u8{"/tmp/project_file.rb"};
    try cleanupStale(db, &project_paths, "/tmp", alloc);

    const check = try db.prepare("SELECT COUNT(*) FROM files WHERE path='/gems/activesupport/core.rb' AND is_gem=1");
    defer check.finalize();
    try std.testing.expect(try check.step());
    try std.testing.expectEqual(@as(i64, 1), check.column_int(0));
}
