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
const insertComposedOfSymbols = rails_dsl.insertComposedOfSymbols;
const insertDelegatedTypeSymbols = rails_dsl.insertDelegatedTypeSymbols;
const insertEnumSymbols = rails_dsl.insertEnumSymbols;
const insertNestedAttributesSymbols = rails_dsl.insertNestedAttributesSymbols;
const insertRailsDslSymbols = rails_dsl.insertRailsDslSymbols;
const insertRichTextSymbols = rails_dsl.insertRichTextSymbols;
const insertSecurePasswordSymbols = rails_dsl.insertSecurePasswordSymbols;
const insertSecureTokenSymbols = rails_dsl.insertSecureTokenSymbols;
const insertStoreAccessorSymbols = rails_dsl.insertStoreAccessorSymbols;

const v_defs = @import("visitor_defs.zig");
const v_calls = @import("visitor_calls.zig");
const v_vars = @import("visitor_vars.zig");
const v_patterns = @import("visitor_patterns.zig");

pub fn buildQualifiedName(parser: *prism.Parser, node: *const prism.Node, alloc: std.mem.Allocator) ![]u8 {
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

pub fn insertRescueFromHandler(ctx: *VisitCtx, cn: *const prism.CallNode) !void {
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

pub fn isAttrMethod(name: []const u8) bool {
    return std.mem.eql(u8, name, "attr_reader") or
        std.mem.eql(u8, name, "attr_writer") or
        std.mem.eql(u8, name, "attr_accessor") or
        std.mem.eql(u8, name, "mattr_accessor") or
        std.mem.eql(u8, name, "mattr_reader") or
        std.mem.eql(u8, name, "mattr_writer") or
        std.mem.eql(u8, name, "cattr_accessor") or
        std.mem.eql(u8, name, "cattr_reader") or
        std.mem.eql(u8, name, "cattr_writer") or
        std.mem.eql(u8, name, "thread_mattr_accessor") or
        std.mem.eql(u8, name, "thread_mattr_reader") or
        std.mem.eql(u8, name, "thread_mattr_writer") or
        std.mem.eql(u8, name, "thread_cattr_accessor") or
        std.mem.eql(u8, name, "thread_cattr_reader") or
        std.mem.eql(u8, name, "thread_cattr_writer") or
        std.mem.eql(u8, name, "class_attribute");
}

pub fn visitor(node: ?*const prism.Node, data: ?*anyopaque) callconv(.c) bool {
    const ctx: *VisitCtx = @ptrCast(@alignCast(data.?));
    const n = node.?;
    switch (n.*.type) {
        prism.NODE_CLASS => return v_defs.handleClass(ctx, n),
        prism.NODE_MODULE => return v_defs.handleModule(ctx, n),
        prism.NODE_DEF => return v_defs.handleDef(ctx, n),
        prism.NODE_CONSTANT_WRITE => return v_vars.handleConstantWrite(ctx, n),
        prism.NODE_CONSTANT_OR_WRITE, prism.NODE_CONSTANT_AND_WRITE => return v_vars.handleConstantOrAndWrite(ctx, n),
        prism.NODE_CONSTANT => {
            const rn: *const prism.ConstReadNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, rn.base.location.start);
            const name = resolveConstant(ctx.parser, rn.name);
            var ns_buf: [512]u8 = undefined;
            const ref_ns = namespaceFromStack(ctx, &ns_buf);
            insertRef(ctx.db, ctx.file_id, name, lc.line, lc.col, null, null, ref_ns) catch {
                ctx.error_count += 1;
            };
            addSemToken(ctx, lc.line, lc.col, @intCast(name.len), 5);
        },
        prism.NODE_CALL => return v_calls.handleCall(ctx, n),
        prism.NODE_ALIAS_METHOD => return v_defs.handleAliasMethod(ctx, n),
        prism.NODE_SINGLETON_CLASS => return v_defs.handleSingletonClass(ctx, n),
        prism.NODE_LOCAL_VAR_READ => {
            const lv: *const prism.LocalVarReadNode = @ptrCast(@alignCast(n));
            const lc = locationLineCol(ctx.parser, lv.base.location.start);
            const name = resolveConstant(ctx.parser, lv.name);
            insertRef(ctx.db, ctx.file_id, name, lc.line, lc.col, ctx.scope_id, null, null) catch {
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
                var ns_buf: [512]u8 = undefined;
                const ref_ns = namespaceFromStack(ctx, &ns_buf);
                insertRef(ctx.db, ctx.file_id, ref_name, lc.line, lc.col, null, null, ref_ns) catch {
                    ctx.error_count += 1;
                };
            }
        },
        prism.NODE_CONSTANT_PATH_WRITE => return v_vars.handleConstantPathWrite(ctx, n),
        prism.NODE_INSTANCE_VAR_WRITE => return v_vars.handleInstanceVarWrite(ctx, n),
        prism.NODE_INSTANCE_VAR_OR_WRITE, prism.NODE_INSTANCE_VAR_AND_WRITE => return v_vars.handleInstanceVarOrAndWrite(ctx, n),
        prism.NODE_CLASS_VAR_WRITE => return v_vars.handleClassVarWrite(ctx, n),
        prism.NODE_CLASS_VAR_OR_WRITE, prism.NODE_CLASS_VAR_AND_WRITE => return v_vars.handleClassVarOrAndWrite(ctx, n),
        prism.NODE_LOCAL_VAR_WRITE => return v_vars.handleLocalVarWrite(ctx, n),
        prism.NODE_MULTI_WRITE => return v_vars.handleMultiWrite(ctx, n),
        prism.NODE_FOR => return v_patterns.handleFor(ctx, n),
        prism.NODE_RESCUE => return v_patterns.handleRescue(ctx, n),
        prism.NODE_RESCUE_MODIFIER => return v_patterns.handleRescueModifier(ctx, n),
        prism.NODE_LOCAL_VAR_OR_WRITE => return v_vars.handleLocalVarOrWrite(ctx, n),
        prism.NODE_LOCAL_VAR_AND_WRITE => return v_vars.handleLocalVarAndWrite(ctx, n),
        prism.NODE_LOCAL_VAR_OP_WRITE => return v_vars.handleLocalVarOpWrite(ctx, n),
        prism.NODE_CASE_MATCH => return v_patterns.handleCaseMatch(ctx, n),
        prism.NODE_CAPTURE_PATTERN => return v_patterns.handleCapturePattern(ctx, n),
        prism.NODE_ARRAY_PATTERN => return v_patterns.handleArrayPattern(ctx, n),
        prism.NODE_HASH_PATTERN => return v_patterns.handleHashPattern(ctx, n),
        // Control flow: visit children so body vars get indexed (Phase 29)
        prism.NODE_UNLESS => return v_patterns.handleUnless(ctx, n),
        prism.NODE_WHILE, prism.NODE_UNTIL => return v_patterns.handleWhileUntil(ctx, n),
        prism.NODE_ENSURE, prism.NODE_YIELD, prism.NODE_SUPER, prism.NODE_FORWARDING_SUPER, prism.NODE_CALL_AND_WRITE, prism.NODE_CALL_OR_WRITE => return v_patterns.handleEnsureEtc(ctx, n),
        // Global variable write: index with scope_id=null (Phase 29)
        prism.NODE_GLOBAL_VAR_WRITE => return v_vars.handleGlobalVarWrite(ctx, n),
        prism.NODE_GLOBAL_VAR_OR_WRITE, prism.NODE_GLOBAL_VAR_AND_WRITE => return v_vars.handleGlobalVarOrAndWrite(ctx, n),
        prism.NODE_IF => return v_patterns.handleIf(ctx, n),
        else => {},
    }
    return true;
}

pub fn extractParams(ctx: *VisitCtx, symbol_id: i64, params_node: *const prism.ParametersNode) !void {
    var position: u32 = 0;

    for (0..params_node.requireds.size) |i| {
        const n = params_node.requireds.nodes[i];
        if (n.*.type == prism.NODE_REQUIRED_PARAM) {
            const rp: *const prism.RequiredParamNode = @ptrCast(@alignCast(n));
            const name = resolveConstant(ctx.parser, rp.name);
            const lc = locationLineCol(ctx.parser, rp.base.location.start);
            try insertParam(ctx.db, symbol_id, position, name, "required", null, 0);
            insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, null, 90, symbol_id) catch {
                ctx.error_count += 1;
            };
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
            insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, null, 90, symbol_id) catch {
                ctx.error_count += 1;
            };
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
                insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, "Array", 90, symbol_id) catch {
                    ctx.error_count += 1;
                };
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
            insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, null, 90, symbol_id) catch {
                ctx.error_count += 1;
            };
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
            insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, kw_type, 90, symbol_id) catch {
                ctx.error_count += 1;
            };
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
                insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, "Hash", 90, symbol_id) catch {
                    ctx.error_count += 1;
                };
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
                insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, null, 90, symbol_id) catch {
                    ctx.error_count += 1;
                };
                addSemToken(ctx, lc.line, lc.col, @intCast(name.len), 3);
            } else {
                try insertParam(ctx.db, symbol_id, position, "&", "block", null, 0);
            }
        }
    }
}

/// Shared body for `&:symbol` and `&method(:symbol)` at call sites: resolve
/// the method against the receiver's inferred type (local-var or literal
/// receiver), and insert a `refs.kind=call` row when the method exists on
/// that type. No-op when receiver is null or untyped.
pub fn insertSymbolToProcRef(ctx: *VisitCtx, receiver: ?*const prism.Node, method_name: []const u8) void {
    const recv = receiver orelse return;
    if (recv.*.type == prism.NODE_LOCAL_VAR_READ) {
        const rv: *const prism.LocalVarReadNode = @ptrCast(@alignCast(recv));
        const rv_name = resolveConstant(ctx.parser, rv.name);
        if (ctx.db.prepare("SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1")) |lv_stmt| {
            defer lv_stmt.finalize();
            lv_stmt.bind_int(1, ctx.file_id);
            lv_stmt.bind_text(2, rv_name);
            if (lv_stmt.step() catch false) {
                const t = lv_stmt.column_text(0);
                if (t.len > 0) {
                    if (stripArrayBrackets(t)) |elem| {
                        if (lookupMethodReturn(ctx.db, elem, method_name)) |_| {
                            insertRef(ctx.db, ctx.file_id, method_name, 0, 0, null, "call", null) catch {
                                ctx.error_count += 1;
                            };
                        }
                    }
                }
            }
        } else |_| {}
    } else if (inferLiteralType(recv)) |lit_type| {
        if (lookupMethodReturn(ctx.db, lit_type, method_name)) |_| {
            insertRef(ctx.db, ctx.file_id, method_name, 0, 0, null, "call", null) catch {
                ctx.error_count += 1;
            };
        }
    }
}

/// Index a pattern-match binding target. Handles `pattern => name`
/// (CapturePatternNode, type from the pattern's constant) and a bare
/// `name` binding (LocalVariableTargetNode, type from `default_type`).
pub fn indexPatternTarget(ctx: *VisitCtx, node: *const prism.Node, default_type: ?[]const u8) void {
    if (node.*.type == prism.NODE_CAPTURE_PATTERN) {
        const cap: *const prism.CapturePatternNode = @ptrCast(@alignCast(node));
        const target: *const prism.LocalVarTargetNode = @ptrCast(@alignCast(cap.target));
        const name = resolveConstant(ctx.parser, target.name);
        var pat_type: ?[]const u8 = default_type;
        if (cap.value.*.type == prism.NODE_CONSTANT) {
            const cn2: *const prism.ConstReadNode = @ptrCast(@alignCast(cap.value));
            pat_type = resolveConstant(ctx.parser, cn2.name);
        }
        const lc = locationLineCol(ctx.parser, node.*.location.start);
        insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, pat_type, 85, ctx.scope_id) catch {
            ctx.error_count += 1;
        };
    } else if (node.*.type == prism.NODE_LOCAL_VARIABLE_TARGET) {
        const target: *const prism.LocalVarTargetNode = @ptrCast(@alignCast(node));
        const name = resolveConstant(ctx.parser, target.name);
        const lc = locationLineCol(ctx.parser, node.*.location.start);
        insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, default_type, 85, ctx.scope_id) catch {
            ctx.error_count += 1;
        };
    } else if (node.*.type == prism.NODE_SPLAT) {
        // `*rest` binding in an array pattern — unwrap to the inner target.
        const sp: *const prism.SplatNode = @ptrCast(@alignCast(node));
        if (sp.expression) |inner| indexPatternTarget(ctx, inner, default_type);
    }
}
