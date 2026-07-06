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

pub fn handleConstantWrite(ctx: *VisitCtx, n: *const prism.Node) bool {
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
            // Members are accessor methods on the assigned constant
            // (e.g. `Point = Struct.new(:x)` → `Point#x`), so parent must
            // be the constant name for receiver-typed `point.x` lookup.
            const struct_parent = resolveConstant(ctx.parser, cn.name);
            if (call.arguments != null) {
                const args = call.arguments[0].arguments;
                for (0..args.size) |ai| {
                    const arg = args.nodes[ai];
                    if (arg.*.type == prism.NODE_SYMBOL) {
                        const sym: *const prism.SymbolNode = @ptrCast(@alignCast(arg));
                        if (sym.unescaped.source) |src| {
                            const sym_name = src[0..sym.unescaped.length];
                            const alc = locationLineCol(ctx.parser, arg.*.location.start);
                            insertSymbolWithReturn(ctx, "def", sym_name, alc.line, alc.col, null, null, struct_parent, null) catch {
                                ctx.error_count += 1;
                            };
                            if (is_struct_new) {
                                const writer_name = ctx.alloc.alloc(u8, sym_name.len + 1) catch continue;
                                defer ctx.alloc.free(writer_name);
                                @memcpy(writer_name[0..sym_name.len], sym_name);
                                writer_name[sym_name.len] = '=';
                                insertSymbolWithReturn(ctx, "def", writer_name, alc.line, alc.col, null, null, struct_parent, null) catch {
                                    ctx.error_count += 1;
                                };
                            }
                        }
                    }
                }
            }
        }
    }
    return true;
}

pub fn handleConstantOrAndWrite(ctx: *VisitCtx, n: *const prism.Node) bool {
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
}

pub fn handleConstantPathWrite(ctx: *VisitCtx, n: *const prism.Node) bool {
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
    return true;
}

pub fn handleInstanceVarWrite(ctx: *VisitCtx, n: *const prism.Node) bool {
    const iv: *const prism.InstanceVarWriteNode = @ptrCast(@alignCast(n));
    const lc = locationLineCol(ctx.parser, iv.name_loc.start);
    const name = resolveConstant(ctx.parser, iv.name);

    var type_hint: ?[]const u8 = if (iv.value) |val| inferLiteralType(val) else null;

    // `@x = Klass.new` / `Klass.find(..)` / `Spree::Model.find_by(..)` / factory builder:
    // type the ivar to the constructed/queried singular instance. This is the dominant
    // controller pattern (`@post = Post.find(params[:id])`); since all methods of a class
    // share class_id, typing the callback/action ivar at its assignment makes it complete
    // in every sibling method. Guard out plural/relation results (`[Klass]` from
    // `.where`/`.all`): persisting an ivar as a bare Array shadows the completion-time
    // naming heuristic and regresses relation-scope completion (measured). Confidence stays
    // 0 (FP-safe — diagnostics never read ivar type_hints).
    if (type_hint == null) {
        if (iv.value) |val| {
            if (extractNewCallType(ctx.parser, val)) |ext| {
                if (ext.len > 0 and ext[0] != '[') type_hint = ext;
            }
        }
    }

    // Deferred receiver-scoped typing: `@ivar = recv.method` (non-constructor). The method's
    // return type depends on recv's class, which may live in another not-yet-indexed file —
    // resolving it during the single parallel pass is both racy (partial table) and imprecise
    // (the old code grabbed ANY same-named def's return). Capture the (recv, method) shape; the
    // post-index flow-typing pass resolves it deterministically over the complete table.
    if (type_hint == null) {
        if (iv.value) |val| {
            if (val.*.type == prism.NODE_CALL) {
                const call: *const prism.CallNode = @ptrCast(@alignCast(val));
                const mname = resolveConstant(ctx.parser, call.name);
                if (!std.mem.eql(u8, mname, "new")) capturePendingRecvReturn(ctx, call, name, lc, mname);
            }
        }
    }
    insertLocalVarClassId(ctx.db, ctx.file_id, name, lc.line, lc.col, type_hint, 0, ctx.current_class_id) catch {
        ctx.error_count += 1;
    };
    return true;
}

// Record an `@ivar = recv.method` assignment for deterministic post-index resolution.
// Only receivers whose type the flow-typing pass can resolve are captured (self/implicit
// self, a constant class, or another instance variable); other receivers are left untyped
// (the completion-time naming heuristic still covers conventionally-named ivars).
fn capturePendingRecvReturn(ctx: *VisitCtx, call: *const prism.CallNode, ivar_name: []const u8, lc: anytype, method_name: []const u8) void {
    // recv_kind drives how the post-index pass resolves the method's class. `other`
    // (unrecognized receiver: a local var, a chain, …) falls back to an unscoped — but
    // still deterministic — return-type lookup, preserving the old coverage.
    var recv_kind: []const u8 = "other";
    var recv_name: []const u8 = "";
    if (call.receiver) |rcv| {
        switch (rcv.*.type) {
            prism.NODE_SELF => recv_kind = "self",
            prism.NODE_CONSTANT => {
                const rc: *const prism.ConstReadNode = @ptrCast(@alignCast(rcv));
                recv_kind = "const";
                recv_name = resolveConstant(ctx.parser, rc.name);
            },
            prism.NODE_CONSTANT_PATH => {
                if (type_hints.qualifyConstPath(ctx.parser, rcv)) |q| {
                    recv_kind = "const";
                    recv_name = q;
                }
            },
            prism.NODE_INSTANCE_VAR_READ => {
                const ir: *const prism.InstanceVarReadNode = @ptrCast(@alignCast(rcv));
                recv_kind = "ivar";
                recv_name = resolveConstant(ctx.parser, ir.name);
            },
            prism.NODE_LOCAL_VAR_READ => {
                // `x = y.method` where y is a local — resolved SCOPED (y's own type_hint,
                // file-scoped) by the flow pass. Kept out of the unscoped fallback (which would
                // type x to an arbitrary same-named return); untyped-when-unresolvable is better.
                const lr: *const prism.LocalVarReadNode = @ptrCast(@alignCast(rcv));
                recv_kind = "local";
                recv_name = resolveConstant(ctx.parser, lr.name);
            },
            else => {},
        }
    } else {
        recv_kind = "self"; // implicit self
    }
    if (ctx.db.prepare("INSERT INTO pending_recv_returns (file_id,class_id,ivar_name,line,col,recv_kind,recv_name,method_name) VALUES (?,?,?,?,?,?,?,?)")) |ps| {
        defer ps.finalize();
        ps.bind_int(1, ctx.file_id);
        if (ctx.current_class_id) |cid| ps.bind_int(2, cid) else ps.bind_null(2);
        ps.bind_text(3, ivar_name);
        ps.bind_int(4, lc.line);
        ps.bind_int(5, @intCast(lc.col));
        ps.bind_text(6, recv_kind);
        if (recv_name.len > 0) ps.bind_text(7, recv_name) else ps.bind_null(7);
        ps.bind_text(8, method_name);
        _ = ps.step() catch {};
    } else |_| {}
}

pub fn handleInstanceVarOrAndWrite(ctx: *VisitCtx, n: *const prism.Node) bool {
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
}

pub fn handleClassVarWrite(ctx: *VisitCtx, n: *const prism.Node) bool {
    const cvw: *const prism.ClassVarWriteNode = @ptrCast(@alignCast(n));
    const lc = locationLineCol(ctx.parser, cvw.name_loc.start);
    const name = resolveConstant(ctx.parser, cvw.name);
    insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, null, 0, null) catch {
        ctx.error_count += 1;
    };
    return true;
}

pub fn handleClassVarOrAndWrite(ctx: *VisitCtx, n: *const prism.Node) bool {
    const cvw: *const prism.ClassVarOrWriteNode = @ptrCast(@alignCast(n));
    const lc = locationLineCol(ctx.parser, cvw.name_loc.start);
    const name = resolveConstant(ctx.parser, cvw.name);
    insertLocalVar(ctx.db, ctx.file_id, name, lc.line, lc.col, null, 0, null) catch {
        ctx.error_count += 1;
    };
    prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
    return false;
}

pub fn handleLocalVarWrite(ctx: *VisitCtx, n: *const prism.Node) bool {
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

    // Bare constant alias: `x = Foo` / `x = Mod::Foo` binds the class OBJECT, so
    // `x.` should complete singleton/class methods, not instance methods. Tag the
    // hint with a `.class` marker the completion engine recognizes (and which no
    // symbol name matches, so diagnostics ignore it).
    if (type_hint == null) {
        if (lv.value) |val| {
            if (val.*.type == prism.NODE_CONSTANT or val.*.type == prism.NODE_CONSTANT_PATH) {
                if (type_hints.qualifyConstPath(ctx.parser, val)) |q| {
                    ar_alloc_type = std.fmt.allocPrint(ctx.alloc, "{s}.class", .{q}) catch null;
                    if (ar_alloc_type) |at| type_hint = at;
                }
            }
        }
    }

    if (type_hint == null) {
        if (lv.value) |val| {
            if (val.*.type == prism.NODE_IF) {
                const if_node: *const prism.IfNode = @ptrCast(@alignCast(val));
                // Extract then branch: first statement in statements list.
                // extractNewCallType may return a thread-local buffer (qualifyConstPath /
                // ar_plural_buf), so dupe it before computing else_t — the else lookup
                // can overwrite that buffer and clobber then_t.
                const then_raw: ?[]const u8 = blk: {
                    if (if_node.statements == null) break :blk null;
                    const stmts: *const prism.StatementsNode = @ptrCast(@alignCast(if_node.statements));
                    if (stmts.body.size == 0) break :blk null;
                    break :blk extractNewCallType(ctx.parser, stmts.body.nodes[0]);
                };
                var then_dup: ?[]u8 = null;
                if (then_raw) |t| then_dup = ctx.alloc.dupe(u8, t) catch null;
                defer if (then_dup) |t| ctx.alloc.free(t);
                const then_t: ?[]const u8 = if (then_dup) |t| t else null;
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
                if (then_t != null and else_t != null) {
                    if (std.mem.eql(u8, then_t.?, else_t.?)) {
                        ar_alloc_type = ctx.alloc.dupe(u8, then_t.?) catch null;
                    } else {
                        // Differing branch types → union; completion splits on " | ".
                        ar_alloc_type = std.fmt.allocPrint(ctx.alloc, "{s} | {s}", .{ then_t.?, else_t.? }) catch null;
                    }
                    if (ar_alloc_type) |at| type_hint = at;
                } else if (then_t) |t| {
                    ar_alloc_type = ctx.alloc.dupe(u8, t) catch null;
                    if (ar_alloc_type) |at| type_hint = at;
                } else if (else_t) |e| {
                    ar_alloc_type = ctx.alloc.dupe(u8, e) catch null;
                    if (ar_alloc_type) |at| type_hint = at;
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
        // AR singular finishers on a Relation: unwrap `[Type]` → `Type`.
        // Mirrors how `User.where(…).first` returns one `User`, not a
        // collection. Limited to the documented AR finder set so we
        // don't accidentally unwrap `[String].first` (which would be wrong
        // for `String#first` on a String literal).
        if (leaf_type == null and std.mem.startsWith(u8, current_type, "[") and std.mem.endsWith(u8, current_type, "]")) {
            const is_ar_singular = for ([_][]const u8{
                "first", "last",                  "take",     "find",
                "find!", "find_by",               "find_by!", "find_or_create_by",
                "take!", "find_or_initialize_by",
            }) |m| {
                if (std.mem.eql(u8, leaf_method, m)) break true;
            } else false;
            if (is_ar_singular) {
                const inner = current_type[1 .. current_type.len - 1];
                const il = @min(inner.len, leaf_type_buf.len);
                @memcpy(leaf_type_buf[0..il], inner[0..il]);
                leaf_type = leaf_type_buf[0..il];
            }
        }
        // `.pluck(:col)` on a Relation returns a plain Array.
        if (leaf_type == null and std.mem.eql(u8, leaf_method, "pluck")) {
            const lt = "Array";
            @memcpy(leaf_type_buf[0..lt.len], lt);
            leaf_type = leaf_type_buf[0..lt.len];
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

    // Deferred receiver-scoped typing for `x = recv.method` (non-constructor): capture the
    // (recv, method) shape and resolve it in the post-index flow-typing pass over the COMPLETE
    // symbol table — receiver-scoped (self→enclosing class, const→named class, ivar→ivar type,
    // local→the local's own type_hint) at confidence 50. Every captured receiver is resolved
    // SCOPED: the flow pass first resolves recv's concrete type, then the method's return on
    // THAT class; a receiver whose type stays unresolvable is left untyped (the 'local' kind is
    // excluded from the unscoped any-same-named-return fallback, which would type x to an
    // arbitrary class and depress member_recall). Mirrors the `@ivar = recv.method` capture.
    if (!inserted and type_hint == null) {
        if (lv.value) |val| {
            if (val.*.type == prism.NODE_CALL) {
                const call: *const prism.CallNode = @ptrCast(@alignCast(val));
                const mname = resolveConstant(ctx.parser, call.name);
                const precise_recv = call.receiver == null or switch (call.receiver.?.*.type) {
                    prism.NODE_SELF, prism.NODE_CONSTANT, prism.NODE_CONSTANT_PATH, prism.NODE_INSTANCE_VAR_READ, prism.NODE_LOCAL_VAR_READ => true,
                    else => false,
                };
                if (precise_recv and !std.mem.eql(u8, mname, "new")) capturePendingRecvReturn(ctx, call, name, lc, mname);
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
    return true;
}

pub fn handleMultiWrite(ctx: *VisitCtx, n: *const prism.Node) bool {
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
}

pub fn handleLocalVarOrWrite(ctx: *VisitCtx, n: *const prism.Node) bool {
    const lw: *const prism.LocalVarOrWriteNode = @ptrCast(@alignCast(n));
    const lname = resolveConstant(ctx.parser, lw.name);
    const llc = locationLineCol(ctx.parser, lw.name_loc.start);
    const rtype = if (lw.value) |val| inferLiteralType(val) orelse extractNewCallType(ctx.parser, val) else null;
    insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, rtype, 20, ctx.scope_id) catch {
        ctx.error_count += 1;
    };
    prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
    return false;
}

pub fn handleLocalVarAndWrite(ctx: *VisitCtx, n: *const prism.Node) bool {
    const lw: *const prism.LocalVarAndWriteNode = @ptrCast(@alignCast(n));
    const lname = resolveConstant(ctx.parser, lw.name);
    const llc = locationLineCol(ctx.parser, lw.name_loc.start);
    const rtype = if (lw.value) |val| inferLiteralType(val) orelse extractNewCallType(ctx.parser, val) else null;
    insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, rtype, 15, ctx.scope_id) catch {
        ctx.error_count += 1;
    };
    prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
    return false;
}

pub fn handleLocalVarOpWrite(ctx: *VisitCtx, n: *const prism.Node) bool {
    const lw: *const prism.LocalVarOpWriteNode = @ptrCast(@alignCast(n));
    const lname = resolveConstant(ctx.parser, lw.name);
    const llc = locationLineCol(ctx.parser, lw.name_loc.start);
    insertLocalVar(ctx.db, ctx.file_id, lname, llc.line, llc.col, null, 20, ctx.scope_id) catch {
        ctx.error_count += 1;
    };
    prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
    return false;
}

pub fn handleGlobalVarWrite(ctx: *VisitCtx, n: *const prism.Node) bool {
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
}

pub fn handleGlobalVarOrAndWrite(ctx: *VisitCtx, n: *const prism.Node) bool {
    const gv: *const prism.GlobalVarOrWriteNode = @ptrCast(@alignCast(n));
    const gname = resolveConstant(ctx.parser, gv.name);
    const glc = locationLineCol(ctx.parser, gv.name_loc.start);
    insertLocalVar(ctx.db, ctx.file_id, gname, glc.line, glc.col, null, 70, null) catch {
        ctx.error_count += 1;
    };
    prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
    return false;
}
