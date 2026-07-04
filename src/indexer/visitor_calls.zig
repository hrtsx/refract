const std = @import("std");
const db_mod = @import("../db.zig");
const prism = @import("../prism.zig");

const visit_ctx = @import("visit_ctx.zig");
const VisitCtx = visit_ctx.VisitCtx;
const SemToken = visit_ctx.SemToken;
const addSemToken = visit_ctx.addSemToken;

const prism_util = @import("prism_util.zig");
const resolveConstant = prism_util.resolveConstant;
const locationLineCol = prism_util.locationLineCol;

const symbol_insert = @import("symbol_insert.zig");
const insertSymbol = symbol_insert.insertSymbol;
const insertSymbolWithReturn = symbol_insert.insertSymbolWithReturn;
const insertSymbolGetId = symbol_insert.insertSymbolGetId;
const insertParam = symbol_insert.insertParam;
const insertLocalVar = symbol_insert.insertLocalVar;
const insertLocalVarClassId = symbol_insert.insertLocalVarClassId;
const insertMixin = symbol_insert.insertMixin;
const insertRef = symbol_insert.insertRef;
const insertCallRef = symbol_insert.insertCallRef;
const namespaceFromStack = symbol_insert.namespaceFromStack;

const type_hints = @import("type_hints.zig");
const updateSymbolReturnType = type_hints.updateSymbolReturnType;
const extractTypeAnnotation = type_hints.extractTypeAnnotation;
const extractNewCallType = type_hints.extractNewCallType;
const inferReceiverType = type_hints.inferReceiverType;
const lookupMethodReturn = type_hints.lookupMethodReturn;
const detectTypeGuard = type_hints.detectTypeGuard;
const detectNilGuard = type_hints.detectNilGuard;
const extractSorbetSig = type_hints.extractSorbetSig;
const findLastSorbetSig = type_hints.findLastSorbetSig;
const findCallArgs = type_hints.findCallArgs;
const parseSorbetParams = type_hints.parseSorbetParams;

const type_inference = @import("type_inference.zig");
const inferLiteralType = type_inference.inferLiteralType;
const parseYardParam = type_inference.parseYardParam;
const parseYardParamDesc = type_inference.parseYardParamDesc;
const parseYardReturn = type_inference.parseYardReturn;
const extractDocComment = type_inference.extractDocComment;

const stdlib_types = @import("stdlib_types.zig");
const lookupStdlibReturn = stdlib_types.lookupStdlibReturn;

const rbs_parser = @import("rbs_parser.zig");
const isRbsIdent = rbs_parser.isRbsIdent;

const rails_dsl = @import("rails_dsl.zig");
const stripArrayBrackets = rails_dsl.stripArrayBrackets;
const inferBlockReturnType = rails_dsl.inferBlockReturnType;
const isIterationMethod = rails_dsl.isIterationMethod;
const isRailsDsl = rails_dsl.isRailsDsl;
const schemaColumnType = rails_dsl.schemaColumnType;
const tableNameToModel = rails_dsl.tableNameToModel;
const insertAttachedSymbols = rails_dsl.insertAttachedSymbols;
const insertAttrSymbols = rails_dsl.insertAttrSymbols;
const insertAttributeSymbol = rails_dsl.insertAttributeSymbol;
const insertBlockParams = rails_dsl.insertBlockParams;
const capturePendingBlockYield = rails_dsl.capturePendingBlockYield;
const insertComposedOfSymbols = rails_dsl.insertComposedOfSymbols;
const insertDelegatedTypeSymbols = rails_dsl.insertDelegatedTypeSymbols;
const insertEnumSymbols = rails_dsl.insertEnumSymbols;
const insertNestedAttributesSymbols = rails_dsl.insertNestedAttributesSymbols;
const insertRailsDslSymbols = rails_dsl.insertRailsDslSymbols;
const insertRichTextSymbols = rails_dsl.insertRichTextSymbols;
const insertSecurePasswordSymbols = rails_dsl.insertSecurePasswordSymbols;
const insertSecureTokenSymbols = rails_dsl.insertSecureTokenSymbols;
const insertStoreAccessorSymbols = rails_dsl.insertStoreAccessorSymbols;

const dispatch = @import("visitor_dispatch.zig");
const visitor = dispatch.visitor;
const buildQualifiedName = dispatch.buildQualifiedName;
const insertRescueFromHandler = dispatch.insertRescueFromHandler;
const isAttrMethod = dispatch.isAttrMethod;
const extractParams = dispatch.extractParams;
const insertSymbolToProcRef = dispatch.insertSymbolToProcRef;
const indexPatternTarget = dispatch.indexPatternTarget;

pub fn handleCall(ctx: *VisitCtx, n: *const prism.Node) bool {
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
    if (cn.receiver == null and std.mem.eql(u8, mname, "alias_attribute")) {
        rails_dsl.insertAliasAttribute(ctx, cn);
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
    // described_class typing fires for both `describe X` and `RSpec.describe X` (the
    // latter has a receiver, so the receiverless DSL path above does not cover it).
    if (std.mem.eql(u8, mname, "describe") or std.mem.eql(u8, mname, "context")) {
        rails_dsl.insertDescribedClass(ctx, cn);
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
                        insertRef(ctx.db, ctx.file_id, src2[0..sym2.unescaped.length], lc2.line, lc2.col, null, "alias", null) catch {
                            ctx.error_count += 1;
                        };
                    }
                } else if (second.*.type == prism.NODE_STRING) {
                    const sn2: *const prism.StringNode = @ptrCast(@alignCast(second));
                    if (sn2.unescaped.source) |src2| {
                        const lc2 = locationLineCol(ctx.parser, second.*.location.start);
                        insertRef(ctx.db, ctx.file_id, src2[0..sn2.unescaped.length], lc2.line, lc2.col, null, "alias", null) catch {
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
    // Rails delegate synthesis (PR6).
    //   delegate :foo, :bar, to: :other                  → defs foo, bar
    //   delegate :foo, to: :other, prefix: true          → def other_foo
    //   delegate :foo, to: :other, prefix: :alt          → def alt_foo
    //   delegate :foo, to: :other, allow_nil: true       → noted (no symbol-shape change)
    if (cn.receiver == null and std.mem.eql(u8, mname, "delegate")) {
        if (cn.arguments) |args_node| {
            const del_args = args_node.*.arguments;

            // First pass: extract `to:` target + `prefix:` value out of
            // the trailing keyword hash, if any.
            var to_sym: ?[]const u8 = null;
            var prefix_true = false;
            var prefix_sym: ?[]const u8 = null;
            for (0..del_args.size) |di| {
                const arg = del_args.nodes[di];
                if (arg.*.type != prism.NODE_KEYWORD_HASH) continue;
                const kh: *const prism.KeywordHashNode = @ptrCast(@alignCast(arg));
                for (0..kh.elements.size) |kj| {
                    const elem = kh.elements.nodes[kj];
                    if (elem.*.type != prism.NODE_ASSOC) continue;
                    const assoc: *const prism.AssocNode = @ptrCast(@alignCast(elem));
                    if (assoc.key.*.type != prism.NODE_SYMBOL) continue;
                    const ksym: *const prism.SymbolNode = @ptrCast(@alignCast(assoc.key));
                    if (ksym.unescaped.source == null) continue;
                    const kname = ksym.unescaped.source[0..ksym.unescaped.length];
                    if (std.mem.eql(u8, kname, "to")) {
                        if (assoc.value.*.type == prism.NODE_SYMBOL) {
                            const vsym: *const prism.SymbolNode = @ptrCast(@alignCast(assoc.value));
                            if (vsym.unescaped.source) |src| to_sym = src[0..vsym.unescaped.length];
                        }
                    } else if (std.mem.eql(u8, kname, "prefix")) {
                        if (assoc.value.*.type == prism.NODE_TRUE) {
                            prefix_true = true;
                        } else if (assoc.value.*.type == prism.NODE_SYMBOL) {
                            const psym: *const prism.SymbolNode = @ptrCast(@alignCast(assoc.value));
                            if (psym.unescaped.source) |src| prefix_sym = src[0..psym.unescaped.length];
                        }
                    }
                }
            }

            // Second pass: emit one def per delegated symbol, prefixed
            // when requested. Prefix from explicit symbol wins over
            // `prefix: true`+`to:` fallback.
            const effective_prefix: ?[]const u8 = if (prefix_sym) |ps| ps else if (prefix_true) to_sym else null;

            // Delegated methods are instance methods of the enclosing
            // class; carry its namespace as parent so receiver-typed
            // goto/hover (`user.profile_name`) can find them.
            var del_ns_buf: [256]u8 = undefined;
            const del_parent = if (ctx.namespace_stack_len > 0) namespaceFromStack(ctx, &del_ns_buf) else null;

            for (0..del_args.size) |di| {
                const arg = del_args.nodes[di];
                if (arg.*.type == prism.NODE_KEYWORD_HASH) continue;
                if (arg.*.type != prism.NODE_SYMBOL) continue;
                const sn: *const prism.SymbolNode = @ptrCast(@alignCast(arg));
                if (sn.unescaped.source == null) continue;
                const dname = sn.unescaped.source[0..sn.unescaped.length];
                const dlc = locationLineCol(ctx.parser, arg.*.location.start);

                if (effective_prefix) |ep| {
                    var nbuf: [192]u8 = undefined;
                    const prefixed = std.fmt.bufPrint(&nbuf, "{s}_{s}", .{ ep, dname }) catch {
                        insertSymbolWithReturn(ctx, "def", dname, dlc.line, dlc.col, null, "delegate", del_parent, null) catch {
                            ctx.error_count += 1;
                        };
                        continue;
                    };
                    insertSymbolWithReturn(ctx, "def", prefixed, dlc.line, dlc.col, null, "delegate", del_parent, null) catch {
                        ctx.error_count += 1;
                    };
                } else {
                    insertSymbolWithReturn(ctx, "def", dname, dlc.line, dlc.col, null, "delegate", del_parent, null) catch {
                        ctx.error_count += 1;
                    };
                }
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
            var fwd_ns_buf: [256]u8 = undefined;
            const fwd_parent = if (ctx.namespace_stack_len > 0) namespaceFromStack(ctx, &fwd_ns_buf) else null;
            var fj: usize = 1; // skip first arg (the delegate target, e.g. :@engine)
            while (fj < fwd_args.size) : (fj += 1) {
                const arg = fwd_args.nodes[fj];
                if (arg.*.type != prism.NODE_SYMBOL) continue;
                const sn: *const prism.SymbolNode = @ptrCast(@alignCast(arg));
                if (sn.unescaped.source == null) continue;
                const dname = sn.unescaped.source[0..sn.unescaped.length];
                const dlc = locationLineCol(ctx.parser, arg.*.location.start);
                insertSymbolWithReturn(ctx, "def", dname, dlc.line, dlc.col, null, "def_delegator", fwd_parent, null) catch {
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
                } else if (!db_hit and cn.block.?.*.type == prism.NODE_BLOCK) {
                    // Receiver local has no type yet — the post-index pass may type it (`xs = fetch`).
                    // Stage the block param for deterministic resolution over the finished table.
                    const bnp: *const prism.BlockNode = @ptrCast(@alignCast(cn.block.?));
                    capturePendingBlockYield(ctx, bnp, "local", rv_name, mname);
                }
            } else if (recv.*.type == prism.NODE_INSTANCE_VAR_READ) {
                const rv: *const prism.InstanceVarReadNode = @ptrCast(@alignCast(recv));
                const rv_name = resolveConstant(ctx.parser, rv.name);
                var ivar_hit = false;
                if (ctx.db.prepare("SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1")) |lv| {
                    defer lv.finalize();
                    lv.bind_int(1, ctx.file_id);
                    lv.bind_text(2, rv_name);
                    if (lv.step() catch false) {
                        const ivar_type = lv.column_text(0);
                        if (ivar_type.len > 0 and cn.block.?.*.type == prism.NODE_BLOCK) {
                            ivar_hit = true;
                            const block_node: *const prism.BlockNode = @ptrCast(@alignCast(cn.block.?));
                            insertBlockParams(ctx, block_node, ivar_type, mname, accum_t) catch {
                                ctx.error_count += 1;
                            };
                        }
                    }
                } else |_| {}
                if (!ivar_hit and cn.block.?.*.type == prism.NODE_BLOCK) {
                    const bnp: *const prism.BlockNode = @ptrCast(@alignCast(cn.block.?));
                    capturePendingBlockYield(ctx, bnp, "ivar", rv_name, mname);
                }
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
    // `respond_to do |format|` — no explicit receiver (implicit self). Type the block
    // param to a synthetic `ActionController::Responder` so `format.json`/`.html`/… complete.
    // Confidence 60 (< the 70 diagnostic gate); the surface is defined in bundled RBS.
    if (cn.block != null and cn.receiver == null and std.mem.eql(u8, mname, "respond_to")) {
        if (cn.block.?.*.type == prism.NODE_BLOCK) {
            const block_node: *const prism.BlockNode = @ptrCast(@alignCast(cn.block.?));
            insertBlockParams(ctx, block_node, "ActionController::MimeResponds::Collector", "respond_to", null) catch {
                ctx.error_count += 1;
            };
        }
    }
    // Symbol to_proc: &:method_name at call site
    if (cn.block != null and cn.block.?.*.type == prism.NODE_SYMBOL) {
        const sym_block: *const prism.SymbolNode = @ptrCast(@alignCast(cn.block.?));
        if (sym_block.unescaped.source) |sym_src| {
            const method_name_sym = sym_src[0..sym_block.unescaped.length];
            insertSymbolToProcRef(ctx, cn.receiver, method_name_sym);
        }
    }
    // method-reference proc: &method(:foo) at call site. Resolves
    // `foo` against the receiver type the same way `&:foo` does.
    if (cn.block != null and cn.block.?.*.type == prism.NODE_CALL) {
        const block_call: *const prism.CallNode = @ptrCast(@alignCast(cn.block.?));
        const block_method_name = resolveConstant(ctx.parser, block_call.name);
        if (std.mem.eql(u8, block_method_name, "method") and block_call.arguments != null) {
            const inner_args = block_call.arguments[0].arguments;
            if (inner_args.size == 1 and inner_args.nodes[0].*.type == prism.NODE_SYMBOL) {
                const sym_arg: *const prism.SymbolNode = @ptrCast(@alignCast(inner_args.nodes[0]));
                if (sym_arg.unescaped.source) |sym_src2| {
                    const method_name_via = sym_src2[0..sym_arg.unescaped.length];
                    insertSymbolToProcRef(ctx, cn.receiver, method_name_via);
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
    // ActiveSupport::Concern `included do...end` or `extended do...end` — traverse block body with current namespace
    if (cn.receiver == null and (std.mem.eql(u8, mname, "included") or std.mem.eql(u8, mname, "extended"))) {
        if (cn.block != null and cn.block.?.*.type == prism.NODE_BLOCK) {
            const inc_blk: *const prism.BlockNode = @ptrCast(@alignCast(cn.block.?));
            if (inc_blk.body != null) {
                prism.visit_child_nodes(inc_blk.body.?, visitor, @ptrCast(ctx));
            }
        }
    }
    // ActiveSupport::Concern `concerning :AuthMethods do...end` — synthesize namespace
    if (cn.receiver == null and std.mem.eql(u8, mname, "concerning")) {
        if (cn.arguments != null) {
            const concern_args = cn.arguments[0].arguments;
            if (concern_args.size > 0 and concern_args.nodes[0].*.type == prism.NODE_SYMBOL) {
                const concern_sym: *const prism.SymbolNode = @ptrCast(@alignCast(concern_args.nodes[0]));
                if (concern_sym.unescaped.source) |sym_src| {
                    const concern_name = sym_src[0..concern_sym.unescaped.length];
                    if (cn.block != null and cn.block.?.*.type == prism.NODE_BLOCK) {
                        const concern_blk: *const prism.BlockNode = @ptrCast(@alignCast(cn.block.?));
                        if (ctx.namespace_stack_len < 64) {
                            ctx.namespace_stack[ctx.namespace_stack_len] = concern_name;
                            ctx.namespace_stack_len += 1;
                            if (concern_blk.body != null) {
                                prism.visit_child_nodes(concern_blk.body.?, visitor, @ptrCast(ctx));
                            }
                            ctx.namespace_stack_len -= 1;
                        }
                    }
                }
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
                    // AR generates `column?` (predicate) and `column=` (writer) for every
                    // column — emit both so `account.confirmed?`/`user.email=` complete.
                    var pq_buf: [128]u8 = undefined;
                    if (std.fmt.bufPrint(&pq_buf, "{s}?", .{cname})) |pq| {
                        insertSymbolWithReturn(ctx, "def", pq, lc_col.line, lc_col.col, "TrueClass | FalseClass", "column", model_name, null) catch {};
                    } else |_| {}
                    var wr_buf: [128]u8 = undefined;
                    if (std.fmt.bufPrint(&wr_buf, "{s}=", .{cname})) |wr| {
                        insertSymbolWithReturn(ctx, "def", wr, lc_col.line, lc_col.col, ruby_type, "column", model_name, null) catch {};
                    } else |_| {}
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
            } else if (std.mem.eql(u8, mname, "timestamps")) {
                // `t.timestamps` generates the created_at/updated_at datetime columns — the most
                // common column pair, invisible if not synthesized (schemaColumnType has no entry
                // for `timestamps`). Emit both readers so `model.created_at` completes.
                const lc_ts = locationLineCol(ctx.parser, cn.message_loc.start);
                inline for (.{ "created_at", "updated_at" }) |ts| {
                    insertSymbolWithReturn(ctx, "def", ts, lc_ts.line, lc_ts.col, "Time", "column", model_name, null) catch {};
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
            } else if (rcv.*.type == prism.NODE_CONSTANT_PATH) {
                // `Mod::Class.method` — record the fully-qualified receiver so
                // ref resolution binds the call to the right namespace's def.
                const q = buildQualifiedName(ctx.parser, rcv, ctx.alloc) catch break :blk null;
                defer ctx.alloc.free(q);
                if (q.len > 0 and q.len < rcv_buf.len) {
                    @memcpy(rcv_buf[0..q.len], q);
                    break :blk rcv_buf[0..q.len];
                }
                break :blk null;
            } else if (rcv.*.type == prism.NODE_CALL) {
                // Chained receiver like `Service.new.call` — infer the
                // constructed/return type of the inner call as the receiver.
                if (extractNewCallType(ctx.parser, rcv)) |t| {
                    if (t.len > 0 and t.len < rcv_buf.len) {
                        @memcpy(rcv_buf[0..t.len], t);
                        break :blk rcv_buf[0..t.len];
                    }
                }
                break :blk null;
            }
        }
        break :blk null;
    };
    insertCallRef(ctx.db, ctx.file_id, mname, lc.line, lc.col, ctx.scope_id, call_arg_count, call_recv_type, cn.receiver == null) catch {
        ctx.error_count += 1;
    };
    // Capture positional argument types (constructor/literal/AR-query exprs) keyed by
    // callee, so the backfill pass can type that method's params from its call sites.
    if (cn.arguments != null) {
        const cargs = cn.arguments[0].arguments;
        var ai: usize = 0;
        while (ai < cargs.size and ai < 8) : (ai += 1) {
            if (extractNewCallType(ctx.parser, cargs.nodes[ai])) |at| {
                if (at.len > 0) symbol_insert.insertCallArgType(ctx.db, mname, @intCast(ai), at) catch {};
            }
        }
    }
    return true;
}
