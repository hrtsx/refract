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

// Look up the recorded type of an `@ivar` read in the enclosing class, for
// accessor return-type inference (`def account; @account; end`). Returns a copy in
// a thread-local buffer valid until the next call — the caller (updateSymbolReturnType)
// consumes it immediately. Null when no class scope or no recorded ivar type.
threadlocal var ivar_rt_buf: [128]u8 = undefined;
fn ivarReturnType(ctx: *VisitCtx, node: *const prism.Node) ?[]const u8 {
    const class_id = ctx.current_class_id orelse return null;
    const ivar: *const prism.InstanceVarReadNode = @ptrCast(@alignCast(node));
    var iname = resolveConstant(ctx.parser, ivar.name);
    if (iname.len > 0 and iname[0] == '@') iname = iname[1..];
    if (iname.len == 0) return null;
    const stmt = ctx.db.prepare("SELECT type_hint FROM local_vars WHERE class_id=? AND name=? AND type_hint IS NOT NULL ORDER BY confidence DESC LIMIT 1") catch return null;
    defer stmt.finalize();
    stmt.bind_int(1, class_id);
    stmt.bind_text(2, iname);
    if (stmt.step() catch false) {
        const t = stmt.column_text(0);
        if (t.len > 0 and t.len <= ivar_rt_buf.len) {
            @memcpy(ivar_rt_buf[0..t.len], t);
            return ivar_rt_buf[0..t.len];
        }
    }
    return null;
}

pub fn handleClass(ctx: *VisitCtx, n: *const prism.Node) bool {
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
        const sc_owned = buildQualifiedName(ctx.parser, sc, ctx.alloc) catch null;
        defer if (sc_owned) |p| ctx.alloc.free(p);
        const sc_name: []const u8 = sc_owned orelse "";
        if (sc_name.len > 0 and class_sym_id > 0) {
            // Record the real superclass for every class. parent_name keeps
            // its existing meaning (namespace for nested classes, superclass
            // for top-level ones) so rename/refs/completion are unaffected.
            if (ctx.db.prepare("UPDATE symbols SET superclass=? WHERE id=?")) |u| {
                defer u.finalize();
                u.bind_text(1, sc_name);
                u.bind_int(2, class_sym_id);
                _ = u.step() catch false;
            } else |_| {}
            if (ns_parent == null) {
                if (ctx.db.prepare("UPDATE symbols SET parent_name=? WHERE id=?")) |u| {
                    defer u.finalize();
                    u.bind_text(1, sc_name);
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
}

pub fn handleModule(ctx: *VisitCtx, n: *const prism.Node) bool {
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
}

pub fn handleDef(ctx: *VisitCtx, n: *const prism.Node) bool {
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
                } else if (last_node.*.type == prism.NODE_INSTANCE_VAR_READ) {
                    // Memoized accessor: `def account; @account; end` → return the
                    // ivar's recorded type. Unlocks chains/locals through accessors.
                    if (ivarReturnType(ctx, last_node)) |rt| {
                        updateSymbolReturnType(ctx.db, sym_id, rt) catch {
                            ctx.error_count += 1;
                        };
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
                            } else if (rargs.nodes[0].*.type == prism.NODE_INSTANCE_VAR_READ) {
                                if (ivarReturnType(ctx, rargs.nodes[0])) |rt| {
                                    updateSymbolReturnType(ctx.db, sym_id, rt) catch {
                                        ctx.error_count += 1;
                                    };
                                }
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
            } else if (body.*.type == prism.NODE_INSTANCE_VAR_READ) {
                if (ivarReturnType(ctx, body)) |rt| {
                    updateSymbolReturnType(ctx.db, sym_id, rt) catch {
                        ctx.error_count += 1;
                    };
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
}

pub fn handleAliasMethod(ctx: *VisitCtx, n: *const prism.Node) bool {
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
            insertRef(ctx.db, ctx.file_id, src[0..osym.unescaped.length], lc.line, lc.col, null, "alias", null) catch {
                ctx.error_count += 1;
            };
        }
    }
    return true;
}

pub fn handleSingletonClass(ctx: *VisitCtx, n: *const prism.Node) bool {
    const sn: *const prism.SingletonClassNode = @ptrCast(@alignCast(n));
    const prev = ctx.in_singleton;
    if (sn.expression.*.type == prism.NODE_SELF) ctx.in_singleton = true;
    prism.visit_child_nodes(n, visitor, @ptrCast(ctx));
    ctx.in_singleton = prev;
    return false;
}
