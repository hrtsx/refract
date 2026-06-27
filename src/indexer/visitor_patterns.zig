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

const dispatch = @import("visitor_dispatch.zig");
const visitor = dispatch.visitor;
const buildQualifiedName = dispatch.buildQualifiedName;
const insertRescueFromHandler = dispatch.insertRescueFromHandler;
const isAttrMethod = dispatch.isAttrMethod;
const extractParams = dispatch.extractParams;
const insertSymbolToProcRef = dispatch.insertSymbolToProcRef;
const indexPatternTarget = dispatch.indexPatternTarget;

pub fn handleFor(ctx: *VisitCtx, n: *const prism.Node) bool {
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
}

pub fn handleRescue(ctx: *VisitCtx, n: *const prism.Node) bool {
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
}

pub fn handleRescueModifier(ctx: *VisitCtx, n: *const prism.Node) bool {
    prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
    return false;
}

pub fn handleCaseMatch(ctx: *VisitCtx, n: *const prism.Node) bool {
    prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
    return false;
}

pub fn handleCapturePattern(ctx: *VisitCtx, n: *const prism.Node) bool {
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
}

pub fn handleArrayPattern(ctx: *VisitCtx, n: *const prism.Node) bool {
    const ap: *const prism.ArrayPatternNode = @ptrCast(@alignCast(n));
    if (ap.requireds.size > 0) {
        for (0..ap.requireds.size) |i| {
            indexPatternTarget(ctx, ap.requireds.nodes[i], "Object");
        }
    }
    if (ap.rest) |rest_pat| {
        indexPatternTarget(ctx, rest_pat, "[Object]");
    }
    prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
    return false;
}

pub fn handleHashPattern(ctx: *VisitCtx, n: *const prism.Node) bool {
    const hp: *const prism.HashPatternNode = @ptrCast(@alignCast(n));
    if (hp.elements.size > 0) {
        for (0..hp.elements.size) |i| {
            const elem = hp.elements.nodes[i];
            if (elem.*.type != prism.NODE_ASSOC) continue;
            const assoc: *const prism.AssocNode = @ptrCast(@alignCast(elem));
            const vt = assoc.value.*.type;
            if (vt == prism.NODE_CAPTURE_PATTERN or vt == prism.NODE_LOCAL_VARIABLE_TARGET) {
                // `{k: Type => name}` or `{k: name}` — the value is the binding.
                indexPatternTarget(ctx, assoc.value, "Object");
            } else if (vt == prism.NODE_IMPLICIT) {
                // Shorthand `{name:}` — the key symbol IS the bound local.
                if (assoc.key.*.type == prism.NODE_SYMBOL) {
                    const ksym: *const prism.SymbolNode = @ptrCast(@alignCast(assoc.key));
                    if (ksym.unescaped.source) |src| {
                        const kname = src[0..ksym.unescaped.length];
                        const hash_lc = locationLineCol(ctx.parser, assoc.key.*.location.start);
                        insertLocalVar(ctx.db, ctx.file_id, kname, hash_lc.line, hash_lc.col, "Object", 85, ctx.scope_id) catch {
                            ctx.error_count += 1;
                        };
                    }
                }
            }
            // Nested array/hash patterns are handled by visit_child_nodes below.
        }
    }
    prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
    return false;
}

pub fn handleUnless(ctx: *VisitCtx, n: *const prism.Node) bool {
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
}

pub fn handleWhileUntil(ctx: *VisitCtx, n: *const prism.Node) bool {
    prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
    return false;
}

pub fn handleEnsureEtc(ctx: *VisitCtx, n: *const prism.Node) bool {
    prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
    return false;
}

pub fn handleIf(ctx: *VisitCtx, n: *const prism.Node) bool {
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
}
