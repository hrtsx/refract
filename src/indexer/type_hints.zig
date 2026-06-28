const std = @import("std");
const db_mod = @import("../db.zig");
const prism = @import("../prism.zig");
const visit_ctx = @import("visit_ctx.zig");
const VisitCtx = visit_ctx.VisitCtx;
const prism_util = @import("prism_util.zig");
const type_inference = @import("type_inference.zig");
const stdlib_types = @import("stdlib_types.zig");
const symbol_insert = @import("symbol_insert.zig");
const rbs_parser = @import("rbs_parser.zig");

const resolveConstant = prism_util.resolveConstant;
const inferLiteralType = type_inference.inferLiteralType;
const lookupStdlibReturn = stdlib_types.lookupStdlibReturn;
const namespaceFromStack = symbol_insert.namespaceFromStack;
const isRbsIdent = rbs_parser.isRbsIdent;

threadlocal var ar_plural_buf: [128]u8 = undefined;
threadlocal var const_path_buf: [256]u8 = undefined;
threadlocal var factory_class_buf: [128]u8 = undefined;

// Camelize a snake_case factory name into a class (`admin_user` → `AdminUser`).
fn camelizeSnake(name: []const u8, buf: []u8) ?[]const u8 {
    if (name.len == 0) return null;
    var len: usize = 0;
    var cap_next = true;
    for (name) |ch| {
        if (ch == '_') {
            cap_next = true;
            continue;
        }
        if (len >= buf.len) return null;
        buf[len] = if (cap_next) std.ascii.toUpper(ch) else ch;
        cap_next = false;
        len += 1;
    }
    if (len == 0) return null;
    return buf[0..len];
}

fn isFactoryBuilder(m: []const u8) bool {
    const names = [_][]const u8{ "create", "create!", "build", "build!", "build_stubbed", "Fabricate", "fabricate" };
    for (names) |n| if (std.mem.eql(u8, m, n)) return true;
    return false;
}

/// Build the fully-qualified name (`A::B::Post`) of a constant or constant-path
/// receiver into a thread-local buffer. Returns the borrowed result (valid until
/// the next call on this thread — callers consume it immediately). Returns null
/// for non-constant nodes or paths that overflow the buffer / nesting bound.
/// Without this, `AccuracyModel::Post.new` would infer the bare tail `Post`,
/// which can't disambiguate two same-named classes in different namespaces.
pub fn qualifyConstPath(parser: *prism.Parser, recv: *const prism.Node) ?[]const u8 {
    var segs: [16][]const u8 = undefined;
    var n: usize = 0;
    var cur: ?*const prism.Node = recv;
    while (cur) |node| {
        if (n >= segs.len) return null;
        switch (node.*.type) {
            prism.NODE_CONSTANT => {
                const cn: *const prism.ConstReadNode = @ptrCast(@alignCast(node));
                segs[n] = resolveConstant(parser, cn.name);
                n += 1;
                cur = null;
            },
            prism.NODE_CONSTANT_PATH => {
                const cp: *const prism.ConstantPathNode = @ptrCast(@alignCast(node));
                if (cp.name == 0) return null;
                segs[n] = resolveConstant(parser, cp.name);
                n += 1;
                cur = cp.parent;
            },
            else => return null,
        }
    }
    if (n == 0) return null;
    if (n == 1) return segs[0];
    var len: usize = 0;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        if (len != 0) {
            if (len + 2 > const_path_buf.len) return null;
            const_path_buf[len] = ':';
            const_path_buf[len + 1] = ':';
            len += 2;
        }
        const s = segs[i];
        if (len + s.len > const_path_buf.len) return null;
        @memcpy(const_path_buf[len..][0..s.len], s);
        len += s.len;
    }
    return const_path_buf[0..len];
}

pub fn updateSymbolReturnType(db: db_mod.Db, symbol_id: i64, return_type: []const u8) !void {
    const stmt = try db.prepare("UPDATE symbols SET return_type = ? WHERE id = ?");
    defer stmt.finalize();
    stmt.bind_text(1, return_type);
    stmt.bind_int(2, symbol_id);
    _ = try stmt.step();
}

pub fn extractTypeAnnotation(source: []const u8, offset: usize) ?[]const u8 {
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

pub fn extractNewCallType(parser: *prism.Parser, node: ?*const prism.Node) ?[]const u8 {
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
    // Factory builders: `create(:user)`/`build(:user)`/`Fabricate(:user)` yield an
    // instance of the camelized factory name. Dominant in specs
    // (`let(:user) { Fabricate(:user) }`) — the biggest untyped-receiver source.
    if (call.receiver == null and isFactoryBuilder(mname) and call.arguments != null) {
        const fargs = call.arguments[0].arguments;
        if (fargs.size > 0 and fargs.nodes[0].*.type == prism.NODE_SYMBOL) {
            const fs: *const prism.SymbolNode = @ptrCast(@alignCast(fargs.nodes[0]));
            if (fs.unescaped.source != null) {
                const sym = fs.unescaped.source[0..fs.unescaped.length];
                if (camelizeSnake(sym, &factory_class_buf)) |c| return c;
            }
        }
    }
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
        // Receiver is the class: bare (`CreditCard`) or namespaced
        // (`Spree::CreditCard`, a CONSTANT_PATH). Solidus/engine code is almost all
        // namespaced, so handle both — otherwise `let(:x){ Spree::Model.find(..) }`
        // types nothing and the spec receiver stays uncompletable.
        const class_name: []const u8 = switch (recv.*.type) {
            prism.NODE_CONSTANT => blk: {
                const rc: *const prism.ConstReadNode = @ptrCast(@alignCast(recv));
                break :blk resolveConstant(parser, rc.name);
            },
            prism.NODE_CONSTANT_PATH => qualifyConstPath(parser, recv) orelse return null,
            else => return null,
        };
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
    if (recv.*.type == prism.NODE_CONSTANT or recv.*.type == prism.NODE_CONSTANT_PATH) {
        return qualifyConstPath(parser, recv);
    }
    return null;
}

pub fn inferReceiverType(ctx: *VisitCtx, recv: *const prism.Node) ?[]const u8 {
    return inferReceiverTypeDepth(ctx, recv, 0);
}

pub fn inferReceiverTypeDepth(ctx: *VisitCtx, recv: *const prism.Node, depth: u8) ?[]const u8 {
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

pub fn lookupMethodReturn(db: db_mod.Db, parent_name: []const u8, method_name: []const u8) ?[]const u8 {
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

pub fn detectTypeGuard(parser: *prism.Parser, cond: *const prism.Node) ?struct { name: []const u8, narrowed_type: []const u8 } {
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

pub fn detectNilGuard(parser: *prism.Parser, cond: *const prism.Node) ?[]const u8 {
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

pub fn extractSorbetSig(source: []const u8, def_start: u32) ?[]const u8 {
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

pub fn findLastSorbetSig(slice: []const u8) ?[]const u8 {
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

pub fn findCallArgs(slice: []const u8, name: []const u8) ?[]const u8 {
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

pub fn updateSorbetParamType(db: db_mod.Db, symbol_id: i64, param_name: []const u8, type_hint: []const u8) void {
    const u = db.prepare("UPDATE params SET type_hint=?, confidence=90 WHERE symbol_id=? AND name=?") catch return;
    defer u.finalize();
    u.bind_text(1, type_hint);
    u.bind_int(2, symbol_id);
    u.bind_text(3, param_name);
    _ = u.step() catch {};
}

pub fn parseSorbetParams(db: db_mod.Db, symbol_id: i64, body: []const u8) void {
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
