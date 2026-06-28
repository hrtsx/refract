const std = @import("std");
const prism = @import("../prism.zig");
const index = @import("index.zig");
const type_hints = @import("type_hints.zig");

const VisitCtx = index.VisitCtx;
const insertLocalVar = index.insertLocalVar;
const insertSymbol = index.insertSymbol;
const insertSymbolWithReturn = index.insertSymbolWithReturn;
const isScopeLabelDsl = index.isScopeLabelDsl;
const locationLineCol = index.locationLineCol;
const namespaceFromStack = index.namespaceFromStack;
const resolveConstant = index.resolveConstant;

pub fn insertAttrSymbols(ctx: *VisitCtx, cn: *const prism.CallNode, mname: []const u8) !void {
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
            std.mem.eql(u8, mname, "cattr_writer") or std.mem.eql(u8, mname, "cattr_accessor") or
            std.mem.endsWith(u8, mname, "_writer") or std.mem.endsWith(u8, mname, "_accessor"))
        {
            const writer_name = try std.fmt.allocPrint(ctx.alloc, "{s}=", .{attr_name});
            defer ctx.alloc.free(writer_name);
            try insertSymbol(ctx, "def", writer_name, lc.line, lc.col, null);
        }
    }
}

// `alias_attribute :new_name, :old_name` — AR synthesizes a reader/writer pair for
// the new name. Emit both as completable `def` symbols on the enclosing class so
// `obj.new_name`/`obj.new_name=` complete. (No static def exists otherwise.)
pub fn insertAliasAttribute(ctx: *VisitCtx, cn: *const prism.CallNode) void {
    if (cn.arguments == null) return;
    const args = cn.arguments[0].arguments;
    if (args.size == 0) return;
    const a0 = args.nodes[0];
    if (a0.*.type != prism.NODE_SYMBOL) return;
    const s0: *const prism.SymbolNode = @ptrCast(@alignCast(a0));
    if (s0.unescaped.source == null) return;
    const new_name = s0.unescaped.source[0..s0.unescaped.length];
    const lc = locationLineCol(ctx.parser, a0.*.location.start);
    var ns_buf: [256]u8 = undefined;
    const parent = if (ctx.namespace_stack_len > 0) namespaceFromStack(ctx, &ns_buf) else null;
    insertSymbolWithReturn(ctx, "def", new_name, lc.line, lc.col, null, "alias_attribute", parent, null) catch {
        ctx.error_count += 1;
    };
    var wbuf: [192]u8 = undefined;
    const writer = std.fmt.bufPrint(&wbuf, "{s}=", .{new_name}) catch return;
    insertSymbolWithReturn(ctx, "def", writer, lc.line, lc.col, null, "alias_attribute", parent, null) catch {
        ctx.error_count += 1;
    };
}

pub fn isRailsDsl(mname: []const u8) bool {
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
                "has_one_attached",
        "has_many_attached",       "has_rich_text",             "encrypts",               "normalizes",
        "attribute",               "has_secure_password",       "has_secure_token",       "delegated_type",
        "connects_to",             "composed_of",               "store_accessor",         "accepts_nested_attributes_for",
        // ActiveJob / ActionMailer class-level DSLs
        "queue_as",                "retry_on",                  "discard_on",             "default",
    };
    for (dsl) |d| if (std.mem.eql(u8, mname, d)) return true;
    return false;
}

pub fn isBuiltinMethod(name: []const u8) bool {
    const builtins = [_][]const u8{
        // Module DSL — always available in class/module body
        "include",                      "extend",                     "prepend",                   "using",
        "private",                      "public",                     "protected",                 "module_function",
        "attr_reader",                  "attr_writer",                "attr_accessor",             "define_method",
        "define_singleton_method",      "alias_method",               "remove_method",             "undef_method",
        "private_constant",             "public_constant",            "autoload",                  "const_set",
        "const_get",                    "const_defined?",             "method_defined?",           "instance_method",
        "instance_methods",             "class_variable_get",         "class_variable_set",        "class_eval",
        "module_eval",                  "class_exec",                 "module_exec",               "refine",
        "ruby2_keywords",
        // Kernel — available everywhere
                      "puts",                       "print",                     "p",
        "pp",                           "raise",                      "fail",                      "require",
        "require_relative",             "load",                       "autoload?",                 "lambda",
        "proc",                         "loop",                       "catch",                     "throw",
        "sleep",                        "exit",                       "exit!",                     "abort",
        "at_exit",                      "format",                     "sprintf",                   "printf",
        "gets",                         "readline",                   "readlines",                 "open",
        "binding",                      "block_given?",               "caller",                    "caller_locations",
        "rand",                         "srand",                      "system",                    "spawn",
        "exec",                         "fork",                       "trap",                      "warn",
        "Array",                        "String",                     "Integer",                   "Float",
        "Hash",                         "Complex",                    "Rational",                  "URI",
        // BasicObject / Object — universally present
        "send",                         "__send__",                   "public_send",               "tap",
        "then",                         "yield_self",                 "itself",                    "object_id",
        "equal?",                       "eql?",                       "==",                        "!=",
        "hash",                         "inspect",                    "to_s",                      "to_str",
        "class",                        "nil?",                       "is_a?",                     "kind_of?",
        "instance_of?",                 "respond_to?",                "respond_to_missing?",       "method",
        "methods",                      "public_methods",             "private_methods",           "protected_methods",
        "singleton_methods",            "singleton_class",            "instance_variable_get",     "instance_variable_set",
        "instance_variables",           "instance_variable_defined?", "freeze",                    "frozen?",
        "dup",                          "clone",                      "display",
        // Common Rails controller/view helpers not in isRailsDsl
                          "params",
        "session",                      "cookies",                    "request",                   "response",
        "flash",                        "render",                     "redirect_to",               "head",
        "url_for",                      "polymorphic_url",            "polymorphic_path",          "respond_to",
        "respond_with",                 "send_data",                  "send_file",                 "current_user",
        "logger",                       "cache",                      "fresh_when",                "stale?",
        "expires_in",                   "expires_now",                "reset_session",             "authenticate_or_request_with_http_basic",
        "authenticate_with_http_basic", "skip_before_action",         "skip_after_action",         "skip_around_action",
        "skip_callback",                "set_callback",               "run_callbacks",
        // ActionView helpers (Rails 6+)
                    "link_to",
        "link_to_if",                   "link_to_unless",             "button_to",                 "form_with",
        "form_for",                     "form_tag",                   "fields_for",                "fields",
        "label",                        "text_field",                 "text_area",                 "select",
        "select_tag",                   "check_box",                  "radio_button",              "hidden_field",
        "submit_tag",                   "image_tag",                  "image_url",                 "asset_path",
        "asset_url",                    "video_tag",                  "audio_tag",                 "favicon_link_tag",
        "javascript_tag",               "javascript_include_tag",     "stylesheet_link_tag",       "csrf_meta_tags",
        "csp_meta_tag",                 "auto_discovery_link_tag",    "content_tag",               "tag",
        "concat",                       "safe_join",                  "raw",                       "html_safe",
        "j",                            "sanitize",                   "strip_tags",                "simple_format",
        "truncate",                     "highlight",                  "excerpt",                   "word_wrap",
        "pluralize",                    "cycle",                      "number_to_currency",        "number_to_human",
        "number_to_human_size",         "number_to_percentage",       "number_to_phone",           "number_with_delimiter",
        "number_with_precision",        "time_ago_in_words",          "distance_of_time_in_words", "time_tag",
        "datetime_select",              "date_select",                "select_date",               "select_time",
        "select_datetime",              "current_page?",              "controller_name",           "action_name",
        "view_context",                 "yield",                      "content_for",               "content_for?",
        "provide",                      "capture",                    "render_partial",
        // Hotwire / Turbo (Rails 7+)
                   "turbo_frame_tag",
        "turbo_stream_from",            "turbo_stream",               "turbo_refreshes_with",      "turbo_method_tag",
        "turbo_confirm_tag",            "morph",
        // ActionMailer / ActionMailbox / ActiveJob (call sites; class-level DSLs in isRailsDsl)
                             "mail",                      "deliver_later",
        "deliver_now",                  "deliver_later!",             "deliver_now!",              "perform_later",
        "perform_now",                  "set",                        "wait",                      "wait_until",
        "queue",                        "headers",                    "attachments",               "default_url_options",
        // RSpec matchers/helpers
        "expect",                       "expect_any_instance_of",     "allow",                     "allow_any_instance_of",
        "double",                       "instance_double",            "class_double",              "object_double",
        "spy",                          "eq",                         "eql",                       "be",
        "be_a",                         "be_an",                      "be_kind_of",                "be_instance_of",
        "be_within",                    "match",                      "match_array",               "contain_exactly",
        "start_with",                   "end_with",                   "raise_error",               "change",
        "have_attributes",              "satisfy",                    "receive",                   "receive_messages",
        "have_received",                "pending",                    "skip",                      "fixture_file_upload",
        "raise_exception",
    };
    for (builtins) |b| if (std.mem.eql(u8, name, b)) return true;
    return false;
}

pub fn isIterationMethod(name: []const u8) bool {
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

// Sorbet's type-signature DSL — `sig { params(x: Integer).returns(String) }` etc.
// These read as receiverless method calls but are provided by the sorbet-runtime
// gem, so the undefined-method checker must not flag them.
pub fn isSorbetDsl(name: []const u8) bool {
    const methods = [_][]const u8{
        "sig",                    "params",            "returns",        "void",        "override",
        "overridable",            "abstract",          "implementation", "checked",     "on_failure",
        "type_parameters",        "type_member",       "type_template",  "bind",        "let",
        "cast",                   "must",              "unsafe",         "reveal_type", "absurd",
        "mixes_in_class_methods", "requires_ancestor", "nilable",        "any",         "all",
        "untyped",                "noreturn",          "attached_class", "self_type",   "class_of",
        "enums",                  "sealed",
    };
    for (methods) |m| if (std.mem.eql(u8, name, m)) return true;
    return false;
}

pub fn stripArrayBrackets(t: ?[]const u8) ?[]const u8 {
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

pub fn inferBlockReturnType(method_name: []const u8, receiver_type: []const u8) ?[]const u8 {
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
    if (std.mem.eql(u8, method_name, "tap")) {
        return receiver_type;
    }
    if (std.mem.eql(u8, method_name, "then") or std.mem.eql(u8, method_name, "yield_self")) {
        return "Block";
    }
    if (std.mem.eql(u8, method_name, "lazy")) {
        return receiver_type;
    }
    if (std.mem.eql(u8, method_name, "force")) {
        return receiver_type;
    }
    return null;
}

pub fn insertBlockParams(ctx: *VisitCtx, block: *const prism.BlockNode, receiver_type: []const u8, method_name: []const u8, accum_type: ?[]const u8) !void {
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
pub fn schemaColumnType(mname: []const u8) ?[]const u8 {
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
pub fn tableNameToModel(table: []const u8, buf: []u8) ?[]u8 {
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

// RSpec `describe SomeClass` / `RSpec.describe SomeClass` — record `described_class`
// as a local typed to the class under test, so `described_class.`/`described_class.new.`
// complete. Called for both the receiverless and `RSpec.`-qualified forms.
pub fn insertDescribedClass(ctx: *VisitCtx, cn: *const prism.CallNode) void {
    if (cn.arguments == null) return;
    const args = cn.arguments[0].arguments;
    if (args.size == 0) return;
    const a0 = args.nodes[0];
    if (a0.*.type != prism.NODE_CONSTANT and a0.*.type != prism.NODE_CONSTANT_PATH) return;
    if (type_hints.qualifyConstPath(ctx.parser, a0)) |cls| {
        if (cls.len > 0) {
            const lcl = locationLineCol(ctx.parser, cn.base.location.start);
            // described_class IS the class object, not an instance — `described_class.new`
            // / `.create` / scopes are class-method calls. Store with the `.class`
            // singleton marker so completion routes through the constant receiver path
            // and offers class methods, mirroring `x = Foo` (which holds the class object).
            // confidence 60 (< the 70 diagnostic gate): completion only, never an FP.
            var marker_buf: [256]u8 = undefined;
            const hint = std.fmt.bufPrint(&marker_buf, "{s}.class", .{cls}) catch cls;
            insertLocalVar(ctx.db, ctx.file_id, "described_class", lcl.line, lcl.col, hint, 60, ctx.scope_id) catch {};
        }
    }
}

pub fn insertRailsDslSymbols(ctx: *VisitCtx, cn: *const prism.CallNode, mname: []const u8) !void {
    // default_scope takes a block/lambda, not a named symbol arg — handle before arg checks
    if (std.mem.eql(u8, mname, "default_scope")) {
        const lc = locationLineCol(ctx.parser, cn.base.location.start);
        var ns_buf_ds: [256]u8 = undefined;
        const parent_ds = if (ctx.namespace_stack_len > 0) namespaceFromStack(ctx, &ns_buf_ds) else null;
        try insertSymbolWithReturn(ctx, "scope", "default_scope", lc.line, lc.col, null, mname, parent_ds, null);
        return;
    }
    // RSpec receiver typing (completion-only typed locals). `let(:x) { Bar.new }` /
    // `subject { Bar.new }` record a local `x`/`subject` typed from the block's last
    // expression; `describe SomeClass` records `described_class -> SomeClass`. These
    // make `x.`/`subject.`/`described_class.` complete on the right receiver.
    if (std.mem.eql(u8, mname, "let") or std.mem.eql(u8, mname, "let!") or std.mem.eql(u8, mname, "subject")) {
        var lv_name: ?[]const u8 = if (std.mem.eql(u8, mname, "subject")) "subject" else null;
        if (cn.arguments != null and cn.arguments[0].arguments.size > 0) {
            const a0 = cn.arguments[0].arguments.nodes[0];
            if (a0.*.type == prism.NODE_SYMBOL) {
                const s: *const prism.SymbolNode = @ptrCast(@alignCast(a0));
                if (s.unescaped.source != null) lv_name = s.unescaped.source[0..s.unescaped.length];
            }
        }
        if (lv_name) |nm| {
            if (cn.block != null and cn.block.?.*.type == prism.NODE_BLOCK) {
                const blk: *const prism.BlockNode = @ptrCast(@alignCast(cn.block));
                if (blk.body != null and blk.body.?.*.type == prism.NODE_STATEMENTS) {
                    const stmts: *const prism.StatementsNode = @ptrCast(@alignCast(blk.body));
                    if (stmts.body.size > 0) {
                        if (type_hints.extractNewCallType(ctx.parser, stmts.body.nodes[stmts.body.size - 1])) |rt| {
                            const lcl = locationLineCol(ctx.parser, cn.base.location.start);
                            insertLocalVar(ctx.db, ctx.file_id, nm, lcl.line, lcl.col, rt, 60, ctx.scope_id) catch {};
                        }
                    }
                }
            }
        }
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
        // Grouping/scoping labels (Rails routes, Rake tasks/namespaces, Grape API
        // scopes, custom settings DSLs): indexed for workspace/symbol + outline, but
        // kept OUT of method go-to-def — `namespace :web` / `task :seed` are labels,
        // not callable `recv.web` / `recv.seed`.
        if (isScopeLabelDsl(mname)) "namespace" else if (std.mem.eql(u8, mname, "scope")) "scope" else if (std.mem.eql(u8, mname, "belongs_to") or
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
    // Scan keyword hash options for class_name:, through:, source:, polymorphic:
    var class_name_opt: ?[]const u8 = null;
    var through_join: ?[]const u8 = null;
    var source_alias: ?[]const u8 = null;
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
                } else if (std.mem.eql(u8, kname, "source")) {
                    if (kh_assoc.value.*.type == prism.NODE_SYMBOL) {
                        const src_sym: *const prism.SymbolNode = @ptrCast(@alignCast(kh_assoc.value));
                        if (src_sym.unescaped.source != null)
                            source_alias = src_sym.unescaped.source[0..src_sym.unescaped.length];
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
    // When source: alias is present, use that for type inference instead of sym_name
    const assoc_lookup_name = source_alias orelse sym_name;
    // Polymorphic belongs_to has no static return type — the concrete type lives in *_type column.
    const assoc_return_type = if (is_polymorphic) null else inferAssocReturnType(ctx.alloc, mname, assoc_lookup_name, class_name_opt);
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

pub fn insertEnumSymbols(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
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

pub fn insertAttachedSymbols(ctx: *VisitCtx, cn: *const prism.CallNode, mname: []const u8) !void {
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

pub fn insertRichTextSymbols(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
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

pub fn insertSecurePasswordSymbols(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
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

pub fn insertSecureTokenSymbols(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
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

pub fn insertAttributeSymbol(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
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

pub fn insertStoreAccessorSymbols(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
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

pub fn insertComposedOfSymbols(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
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

pub fn insertDelegatedTypeSymbols(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
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

pub fn insertNestedAttributesSymbols(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
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
