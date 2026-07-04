const std = @import("std");
const db_mod = @import("../db.zig");
const prism = @import("../prism.zig");
const prism_util = @import("prism_util.zig");
const routes_common = @import("routes_common.zig");

const resolveConstant = prism_util.resolveConstant;
const locationLineCol = prism_util.locationLineCol;
const insertRoute = routes_common.insertRoute;
const extractSymbolName = routes_common.extractSymbolName;

const RodaCtx = struct {
    db: db_mod.Db,
    file_id: i64,
    parser: *prism.Parser,
    alloc: std.mem.Allocator,
    path_stack: [32][]const u8,
    path_depth: u32,
    route_count: *u32,
    controller: []const u8,

    fn pushPath(self: *RodaCtx, segment: []const u8) void {
        if (self.path_depth >= 32) return;
        self.path_stack[self.path_depth] = segment;
        self.path_depth += 1;
    }

    fn popPath(self: *RodaCtx) void {
        if (self.path_depth > 0) self.path_depth -= 1;
    }

    fn buildPath(self: *const RodaCtx, buf: []u8) []const u8 {
        var pos: usize = 0;
        for (0..self.path_depth) |i| {
            const seg = self.path_stack[i];
            if (seg.len == 0) continue;
            if (seg[0] != '/' and pos > 0) {
                if (pos < buf.len) {
                    buf[pos] = '/';
                    pos += 1;
                }
            }
            const copy_len = @min(seg.len, buf.len - pos);
            @memcpy(buf[pos..][0..copy_len], seg[0..copy_len]);
            pos += copy_len;
        }
        if (pos == 0) {
            buf[0] = '/';
            return buf[0..1];
        }
        return buf[0..pos];
    }
};

fn deriveHelperFromPath(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    for (path) |c| {
        if (c == ':' or c == '/') {
            if (pos > 0 and buf[pos - 1] != '_') {
                if (pos < buf.len) {
                    buf[pos] = '_';
                    pos += 1;
                }
            }
        } else {
            if (pos < buf.len) {
                buf[pos] = c;
                pos += 1;
            }
        }
    }
    while (pos > 0 and buf[pos - 1] == '_') pos -= 1;
    if (pos == 0) return alloc.dupe(u8, "root");
    return std.fmt.allocPrint(alloc, "{s}_path", .{buf[0..pos]});
}

fn getBlockBody(cn: *const prism.CallNode) ?*const prism.Node {
    const block_ptr = cn.block orelse return null;
    const block_generic: *const prism.Node = @ptrCast(@alignCast(block_ptr));
    if (block_generic.*.type != prism.NODE_BLOCK) return null;
    const block_node: *const prism.BlockNode = @ptrCast(@alignCast(block_ptr));
    return block_node.body;
}

fn isReceiverMethodCall(cn: *const prism.CallNode) bool {
    if (cn.receiver == null) return false;
    const recv = cn.receiver.?;
    if (recv.*.type == prism.NODE_LOCAL_VAR_READ) return true;
    if (recv.*.type == prism.NODE_CALL) {
        const recv_cn: *const prism.CallNode = @ptrCast(@alignCast(recv));
        return recv_cn.receiver == null and recv_cn.arguments == null;
    }
    return false;
}

fn rodaVisitStatements(ctx: *RodaCtx, node: *const prism.Node) void {
    if (node.*.type != prism.NODE_STATEMENTS) return;
    const stmts: *const prism.StatementsNode = @ptrCast(@alignCast(node));
    for (0..stmts.body.size) |i| {
        rodaVisitNode(ctx, stmts.body.nodes[i]);
    }
}

fn rodaVisitNode(ctx: *RodaCtx, node: *const prism.Node) void {
    // Handle root ProgramNode directly (bypass visit_child_nodes)
    if (node.*.type == prism.NODE_PROGRAM) {
        const pn: *const prism.ProgramNode = @ptrCast(@alignCast(node));
        if (pn.statements) |stmts| rodaVisitNode(ctx, @ptrCast(@alignCast(stmts)));
        return;
    }

    if (node.*.type == prism.NODE_STATEMENTS) {
        rodaVisitStatements(ctx, node);
        return;
    }

    // Descend into class/module bodies (Roda routes are inside `class Clover`)
    if (node.*.type == prism.NODE_CLASS) {
        const cn: *const prism.ClassNode = @ptrCast(@alignCast(node));
        if (cn.body) |body| rodaVisitNode(ctx, body);
        return;
    }
    if (node.*.type == prism.NODE_MODULE) {
        const mn: *const prism.ModuleNode = @ptrCast(@alignCast(node));
        if (mn.body) |body| rodaVisitNode(ctx, body);
        return;
    }
    if (node.*.type == prism.NODE_SINGLETON_CLASS) {
        const sn: *const prism.SingletonClassNode = @ptrCast(@alignCast(node));
        if (sn.body) |body| rodaVisitNode(ctx, body);
        return;
    }
    if (node.*.type == prism.NODE_DEF) {
        const dn: *const prism.DefNode = @ptrCast(@alignCast(node));
        if (dn.body) |body| rodaVisitNode(ctx, body);
        return;
    }

    if (node.*.type == prism.NODE_CALL) {
        const cn: *const prism.CallNode = @ptrCast(@alignCast(node));
        const mname = resolveConstant(ctx.parser, cn.name);

        if (std.mem.eql(u8, mname, "hash_branch")) {
            if (cn.arguments != null) {
                const args = cn.arguments[0].arguments;
                if (args.size > 0) {
                    if (extractSymbolName(ctx.parser, args.nodes[0])) |branch_name| {
                        var seg_buf: [128]u8 = undefined;
                        const segment = std.fmt.bufPrint(&seg_buf, "/{s}", .{branch_name}) catch return;
                        const seg_copy = ctx.alloc.dupe(u8, segment) catch return;
                        ctx.pushPath(seg_copy);
                        if (getBlockBody(cn)) |body| rodaVisitStatements(ctx, body);
                        ctx.popPath();
                        return;
                    }
                }
            }
            if (getBlockBody(cn)) |body| rodaVisitStatements(ctx, body);
            return;
        }

        if (isReceiverMethodCall(cn)) {
            if (std.mem.eql(u8, mname, "on")) {
                var segment: []const u8 = "/:id";
                if (cn.arguments != null) {
                    const args = cn.arguments[0].arguments;
                    if (args.size > 0) {
                        const first = args.nodes[0];
                        if (first.*.type == prism.NODE_STRING) {
                            const sn: *const prism.StringNode = @ptrCast(@alignCast(first));
                            if (sn.unescaped.source) |src| {
                                var seg_buf: [128]u8 = undefined;
                                const raw = src[0..sn.unescaped.length];
                                segment = std.fmt.bufPrint(&seg_buf, "/{s}", .{raw}) catch return;
                            }
                        } else if (first.*.type == prism.NODE_CONSTANT) {
                            segment = "/:id";
                        } else if (first.*.type == prism.NODE_SYMBOL) {
                            const sym: *const prism.SymbolNode = @ptrCast(@alignCast(first));
                            if (sym.unescaped.source) |src| {
                                var seg_buf: [128]u8 = undefined;
                                const name = src[0..sym.unescaped.length];
                                segment = std.fmt.bufPrint(&seg_buf, "/:{s}", .{name}) catch return;
                            }
                        }
                    }
                }
                const seg_copy = ctx.alloc.dupe(u8, segment) catch return;
                ctx.pushPath(seg_copy);
                if (getBlockBody(cn)) |body| rodaVisitStatements(ctx, body);
                ctx.popPath();
                return;
            }

            if (std.mem.eql(u8, mname, "is")) {
                if (getBlockBody(cn)) |body| rodaVisitStatements(ctx, body);
                return;
            }

            const http_method: ?[]const u8 = if (std.mem.eql(u8, mname, "get"))
                "GET"
            else if (std.mem.eql(u8, mname, "post"))
                "POST"
            else if (std.mem.eql(u8, mname, "put"))
                "PUT"
            else if (std.mem.eql(u8, mname, "patch"))
                "PATCH"
            else if (std.mem.eql(u8, mname, "delete"))
                "DELETE"
            else
                null;

            if (http_method) |method| {
                var path_buf: [512]u8 = undefined;
                const path = ctx.buildPath(&path_buf);
                const lc = locationLineCol(ctx.parser, cn.base.location.start);
                const path_copy = ctx.alloc.dupe(u8, path) catch return;
                defer ctx.alloc.free(path_copy);
                const helper = deriveHelperFromPath(ctx.alloc, path) catch return;
                defer ctx.alloc.free(helper);
                insertRoute(ctx.db, ctx.file_id, .{
                    .http_method = method,
                    .path_pattern = path_copy,
                    .helper_name = helper,
                    .controller = ctx.controller,
                    .action = method,
                    .line = lc.line,
                    .col = lc.col,
                }) catch |e| std.log.warn("routes: insert req: {s}", .{@errorName(e)});
                ctx.route_count.* += 1;
                return;
            }
        }

        if (getBlockBody(cn)) |body| rodaVisitStatements(ctx, body);
        return;
    }

    prism.visit_child_nodes(node, rodaChildVisitor, @ptrCast(@constCast(ctx)));
}

fn rodaChildVisitor(child: ?*const prism.Node, data: ?*anyopaque) callconv(.c) bool {
    const ctx: *RodaCtx = @ptrCast(@alignCast(data.?));
    if (child) |c| rodaVisitNode(ctx, c);
    return false;
}

fn controllerFromPath(alloc: std.mem.Allocator, file_path: []const u8) []const u8 {
    const basename = blk: {
        if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |idx| {
            break :blk file_path[idx + 1 ..];
        }
        break :blk file_path;
    };
    if (std.mem.endsWith(u8, basename, ".rb")) {
        return alloc.dupe(u8, basename[0 .. basename.len - 3]) catch basename;
    }
    return alloc.dupe(u8, basename) catch basename;
}

/// Roda fallback: called when the Rails visitor found no routes in this file.
/// Walks the tree for Roda `hash_branch`/`on`/`is` + HTTP-verb calls and inserts
/// the routes it derives from the accumulated path stack.
pub fn indexRoda(db: db_mod.Db, file_id: i64, parser: *prism.Parser, root: *const prism.Node, alloc: std.mem.Allocator, file_path: []const u8) void {
    var route_count: u32 = 0;
    const controller = controllerFromPath(alloc, file_path);
    var roda_ctx = RodaCtx{
        .db = db,
        .file_id = file_id,
        .parser = parser,
        .alloc = alloc,
        .path_stack = undefined,
        .path_depth = 0,
        .route_count = &route_count,
        .controller = controller,
    };
    rodaVisitNode(&roda_ctx, root);
}
