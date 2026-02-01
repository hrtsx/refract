const std = @import("std");
const db_mod = @import("../db.zig");
const prism = @import("../prism.zig");

const RouteInfo = struct {
    http_method: []const u8,
    path_pattern: []const u8,
    helper_name: []const u8,
    controller: []const u8,
    action: []const u8,
    line: i32,
    col: u32,
};

const NamespaceContext = struct {
    path_prefix_stack: [16][]const u8,
    path_prefix_depth: u32,
    controller_prefix_stack: [16][]const u8,
    controller_prefix_depth: u32,

    fn init() NamespaceContext {
        return .{
            .path_prefix_stack = undefined,
            .path_prefix_depth = 0,
            .controller_prefix_stack = undefined,
            .controller_prefix_depth = 0,
        };
    }

    fn pushPathPrefix(self: *NamespaceContext, prefix: []const u8) !void {
        if (self.path_prefix_depth >= 16) return error.NestingTooDeep;
        self.path_prefix_stack[self.path_prefix_depth] = prefix;
        self.path_prefix_depth += 1;
    }

    fn popPathPrefix(self: *NamespaceContext) void {
        if (self.path_prefix_depth > 0) {
            self.path_prefix_depth -= 1;
        }
    }

    fn pushControllerPrefix(self: *NamespaceContext, prefix: []const u8) !void {
        if (self.controller_prefix_depth >= 16) return error.NestingTooDeep;
        self.controller_prefix_stack[self.controller_prefix_depth] = prefix;
        self.controller_prefix_depth += 1;
    }

    fn popControllerPrefix(self: *NamespaceContext) void {
        if (self.controller_prefix_depth > 0) {
            self.controller_prefix_depth -= 1;
        }
    }

    fn getFullPath(self: *const NamespaceContext, alloc: std.mem.Allocator, base_path: []const u8) ![]const u8 {
        if (self.path_prefix_depth == 0) {
            return try alloc.dupe(u8, base_path);
        }
        var parts: std.ArrayList([]const u8) = .{};
        defer parts.deinit(alloc);
        for (0..self.path_prefix_depth) |i| {
            try parts.append(alloc, self.path_prefix_stack[i]);
        }
        try parts.append(alloc, base_path);
        return try std.mem.join(alloc, "", parts.items);
    }

    fn getFullController(self: *const NamespaceContext, alloc: std.mem.Allocator, base_controller: []const u8) ![]const u8 {
        if (self.controller_prefix_depth == 0) {
            return try alloc.dupe(u8, base_controller);
        }
        var parts: std.ArrayList([]const u8) = .{};
        defer parts.deinit(alloc);
        for (0..self.controller_prefix_depth) |i| {
            try parts.append(alloc, self.controller_prefix_stack[i]);
        }
        try parts.append(alloc, base_controller);
        return try std.mem.join(alloc, "::", parts.items);
    }
};

fn singularize(alloc: std.mem.Allocator, plural: []const u8) ![]const u8 {
    if (plural.len == 0) return alloc.dupe(u8, "");

    const irregular_plurals = [_]struct { singular: []const u8, plural: []const u8 }{
        .{ .singular = "person", .plural = "people" },
        .{ .singular = "child", .plural = "children" },
        .{ .singular = "datum", .plural = "data" },
        .{ .singular = "ox", .plural = "oxen" },
        .{ .singular = "man", .plural = "men" },
        .{ .singular = "woman", .plural = "women" },
        .{ .singular = "mouse", .plural = "mice" },
        .{ .singular = "goose", .plural = "geese" },
        .{ .singular = "tooth", .plural = "teeth" },
        .{ .singular = "foot", .plural = "feet" },
        .{ .singular = "fish", .plural = "fish" },
        .{ .singular = "sheep", .plural = "sheep" },
        .{ .singular = "series", .plural = "series" },
        .{ .singular = "species", .plural = "species" },
    };

    for (irregular_plurals) |entry| {
        if (std.mem.eql(u8, plural, entry.plural)) {
            return try alloc.dupe(u8, entry.singular);
        }
    }

    // -ies -> -y (categories -> category)
    if (plural.len > 3 and std.mem.endsWith(u8, plural, "ies")) {
        const base = plural[0 .. plural.len - 3];
        return try std.fmt.allocPrint(alloc, "{s}y", .{base});
    }

    // -ses -> -s (addresses -> address)
    if (plural.len > 3 and std.mem.endsWith(u8, plural, "ses")) {
        const base = plural[0 .. plural.len - 2];
        return try alloc.dupe(u8, base);
    }

    // -ves -> -f (wolves -> wolf)
    if (plural.len > 3 and std.mem.endsWith(u8, plural, "ves")) {
        const base = plural[0 .. plural.len - 3];
        return try std.fmt.allocPrint(alloc, "{s}f", .{base});
    }

    // Default: remove trailing 's' (users -> user)
    if (std.mem.endsWith(u8, plural, "s") and plural.len > 1) {
        return try alloc.dupe(u8, plural[0 .. plural.len - 1]);
    }

    return alloc.dupe(u8, plural);
}

fn resolveConstant(parser: *prism.Parser, id: prism.ConstantId) []const u8 {
    const ct = prism.constantPoolIdToConstant(&parser.constant_pool, id);
    return ct[0].start[0..ct[0].length];
}

fn locationLineCol(parser: *prism.Parser, offset: u32) struct { line: i32, col: u32 } {
    const lc = prism.lineOffsetListLineColumn(&parser.line_offsets, offset, parser.start_line);
    return .{ .line = lc.line, .col = lc.column };
}

fn extractSymbolName(_: *prism.Parser, node: *const prism.Node) ?[]const u8 {
    if (node.*.type == prism.NODE_SYMBOL) {
        const sym: *const prism.SymbolNode = @ptrCast(@alignCast(node));
        if (sym.unescaped.source) |src| {
            return src[0..sym.unescaped.length];
        }
    } else if (node.*.type == prism.NODE_STRING) {
        const sn: *const prism.StringNode = @ptrCast(@alignCast(node));
        if (sn.unescaped.source) |src| {
            return src[0..sn.unescaped.length];
        }
    }
    return null;
}

fn extractToArgument(_: *prism.Parser, args_list: anytype) ?struct { controller: []const u8, action: []const u8 } {
    for (0..args_list.size) |i| {
        const arg = args_list.nodes[i];
        if (arg.*.type == prism.NODE_KEYWORD_HASH) {
            const kh: *const prism.KeywordHashNode = @ptrCast(@alignCast(arg));
            for (0..kh.elements.size) |ki| {
                const elem = kh.elements.nodes[ki];
                if (elem.*.type == prism.NODE_ASSOC) {
                    const assoc: *const prism.AssocNode = @ptrCast(@alignCast(elem));
                    if (assoc.key.*.type == prism.NODE_SYMBOL) {
                        const ksym: *const prism.SymbolNode = @ptrCast(@alignCast(assoc.key));
                        if (ksym.unescaped.source) |src| {
                            const key = src[0..ksym.unescaped.length];
                            if (std.mem.eql(u8, key, "to")) {
                                if (assoc.value.*.type == prism.NODE_STRING) {
                                    const sn: *const prism.StringNode = @ptrCast(@alignCast(assoc.value));
                                    if (sn.unescaped.source) |val_src| {
                                        const val = val_src[0..sn.unescaped.length];
                                        if (std.mem.indexOf(u8, val, "#")) |sep| {
                                            return .{
                                                .controller = val[0..sep],
                                                .action = val[sep + 1 ..],
                                            };
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else if (arg.*.type == prism.NODE_HASH) {
            const hn: *const prism.HashNode = @ptrCast(@alignCast(arg));
            for (0..hn.elements.size) |ki| {
                const elem = hn.elements.nodes[ki];
                if (elem.*.type == prism.NODE_ASSOC) {
                    const assoc: *const prism.AssocNode = @ptrCast(@alignCast(elem));
                    if (assoc.key.*.type == prism.NODE_SYMBOL) {
                        const ksym: *const prism.SymbolNode = @ptrCast(@alignCast(assoc.key));
                        if (ksym.unescaped.source) |src| {
                            const key = src[0..ksym.unescaped.length];
                            if (std.mem.eql(u8, key, "to")) {
                                if (assoc.value.*.type == prism.NODE_STRING) {
                                    const sn: *const prism.StringNode = @ptrCast(@alignCast(assoc.value));
                                    if (sn.unescaped.source) |val_src| {
                                        const val = val_src[0..sn.unescaped.length];
                                        if (std.mem.indexOf(u8, val, "#")) |sep| {
                                            return .{
                                                .controller = val[0..sep],
                                                .action = val[sep + 1 ..],
                                            };
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
    return null;
}

fn insertRoute(db: db_mod.Db, file_id: i64, info: RouteInfo) !void {
    const ins = try db.prepare(
        \\INSERT INTO routes (file_id, http_method, path_pattern, helper_name, controller, action, line, col)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer ins.finalize();
    ins.bind_int(1, file_id);
    ins.bind_text(2, info.http_method);
    ins.bind_text(3, info.path_pattern);
    ins.bind_text(4, info.helper_name);
    ins.bind_text(5, info.controller);
    ins.bind_text(6, info.action);
    ins.bind_int(7, info.line);
    ins.bind_int(8, info.col);
    _ = try ins.step();
}

fn extractAsOption(args_list: anytype) ?[]const u8 {
    for (0..args_list.size) |i| {
        const arg = args_list.nodes[i];
        if (arg.*.type == prism.NODE_KEYWORD_HASH) {
            const kh: *const prism.KeywordHashNode = @ptrCast(@alignCast(arg));
            for (0..kh.elements.size) |ki| {
                const elem = kh.elements.nodes[ki];
                if (elem.*.type == prism.NODE_ASSOC) {
                    const assoc: *const prism.AssocNode = @ptrCast(@alignCast(elem));
                    if (assoc.key.*.type == prism.NODE_SYMBOL) {
                        const ksym: *const prism.SymbolNode = @ptrCast(@alignCast(assoc.key));
                        if (ksym.unescaped.source) |src| {
                            const key = src[0..ksym.unescaped.length];
                            if (std.mem.eql(u8, key, "as")) {
                                if (assoc.value.*.type == prism.NODE_SYMBOL) {
                                    const vsym: *const prism.SymbolNode = @ptrCast(@alignCast(assoc.value));
                                    if (vsym.unescaped.source) |vsrc| return vsrc[0..vsym.unescaped.length];
                                } else if (assoc.value.*.type == prism.NODE_STRING) {
                                    const vstr: *const prism.StringNode = @ptrCast(@alignCast(assoc.value));
                                    if (vstr.unescaped.source) |vsrc| return vsrc[0..vstr.unescaped.length];
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return null;
}

fn actionInOnlyExcept(_: *prism.Parser, args_list: anytype, action: []const u8) bool {
    var has_only = false;
    var action_in_only = false;
    var has_except = false;
    var action_in_except = false;

    for (0..args_list.size) |i| {
        const arg = args_list.nodes[i];
        if (arg.*.type == prism.NODE_KEYWORD_HASH) {
            const kh: *const prism.KeywordHashNode = @ptrCast(@alignCast(arg));
            for (0..kh.elements.size) |ki| {
                const elem = kh.elements.nodes[ki];
                if (elem.*.type == prism.NODE_ASSOC) {
                    const assoc: *const prism.AssocNode = @ptrCast(@alignCast(elem));
                    if (assoc.key.*.type == prism.NODE_SYMBOL) {
                        const ksym: *const prism.SymbolNode = @ptrCast(@alignCast(assoc.key));
                        if (ksym.unescaped.source) |src| {
                            const key = src[0..ksym.unescaped.length];
                            if (std.mem.eql(u8, key, "only")) {
                                if (assoc.value.*.type == prism.NODE_ARRAY) {
                                    const arr: *const prism.ArrayNode = @ptrCast(@alignCast(assoc.value));
                                    has_only = true;
                                    for (0..arr.elements.size) |ai| {
                                        const elem_node = arr.elements.nodes[ai];
                                        if (elem_node.*.type == prism.NODE_SYMBOL) {
                                            const asym: *const prism.SymbolNode = @ptrCast(@alignCast(elem_node));
                                            if (asym.unescaped.source) |act_src| {
                                                const act = act_src[0..asym.unescaped.length];
                                                if (std.mem.eql(u8, act, action)) {
                                                    action_in_only = true;
                                                }
                                            }
                                        }
                                    }
                                }
                            } else if (std.mem.eql(u8, key, "except")) {
                                if (assoc.value.*.type == prism.NODE_ARRAY) {
                                    const arr: *const prism.ArrayNode = @ptrCast(@alignCast(assoc.value));
                                    has_except = true;
                                    for (0..arr.elements.size) |ai| {
                                        const elem_node = arr.elements.nodes[ai];
                                        if (elem_node.*.type == prism.NODE_SYMBOL) {
                                            const asym: *const prism.SymbolNode = @ptrCast(@alignCast(elem_node));
                                            if (asym.unescaped.source) |act_src| {
                                                const act = act_src[0..asym.unescaped.length];
                                                if (std.mem.eql(u8, act, action)) {
                                                    action_in_except = true;
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
        }
    }

    if (has_only) {
        return action_in_only;
    }
    if (has_except) {
        return !action_in_except;
    }
    return true;
}

fn handleResourcesCall(db: db_mod.Db, file_id: i64, parser: *prism.Parser, cn: *const prism.CallNode, resource_name: []const u8, is_singular: bool, alloc: std.mem.Allocator, ns_ctx: *NamespaceContext) !void {
    const lc = locationLineCol(parser, cn.base.location.start);
    const as_override = if (cn.arguments != null) extractAsOption(cn.arguments[0].arguments) else null;
    const effective_name = if (as_override) |as_name| as_name else resource_name;
    const singular = if (as_override) |as_name| as_name else if (is_singular) resource_name else try singularize(alloc, resource_name);
    defer if (as_override == null and !is_singular) alloc.free(singular);

    const rest_routes = [_]struct { method: []const u8, path_suffix: []const u8, action: []const u8 }{
        .{ .method = "GET", .path_suffix = "", .action = if (is_singular) "show" else "index" },
        .{ .method = "GET", .path_suffix = "/new", .action = "new" },
        .{ .method = "POST", .path_suffix = "", .action = "create" },
        .{ .method = "GET", .path_suffix = "/:id", .action = "show" },
        .{ .method = "GET", .path_suffix = "/:id/edit", .action = "edit" },
        .{ .method = "PATCH", .path_suffix = "/:id", .action = "update" },
        .{ .method = "DELETE", .path_suffix = "/:id", .action = "destroy" },
    };

    var route_idx: usize = 0;
    const args_list = if (cn.arguments != null) cn.arguments[0].arguments else return;

    for (rest_routes) |r| {
        if (is_singular and route_idx == 0) {
            route_idx += 1;
            continue;
        }

        if (!actionInOnlyExcept(parser, args_list, r.action)) {
            route_idx += 1;
            continue;
        }

        const base_path = try std.fmt.allocPrint(alloc, "/{s}{s}", .{ resource_name, r.path_suffix });
        defer alloc.free(base_path);
        const path_pattern = try ns_ctx.getFullPath(alloc, base_path);
        defer alloc.free(path_pattern);

        const base_controller = resource_name;
        const controller = try ns_ctx.getFullController(alloc, base_controller);
        defer alloc.free(controller);

        const helper_base = if (as_override) |_| singular else if (is_singular) resource_name else singular;
        var helper_name: []const u8 = undefined;
        if (route_idx == 0 and is_singular) {
            helper_name = try alloc.dupe(u8, effective_name);
        } else if (route_idx == 1 or (is_singular and route_idx == 2)) {
            helper_name = try std.fmt.allocPrint(alloc, "new_{s}", .{singular});
        } else if (route_idx >= 3 and !is_singular) {
            if (std.mem.eql(u8, r.action, "show")) {
                helper_name = try alloc.dupe(u8, singular);
            } else if (std.mem.eql(u8, r.action, "edit")) {
                helper_name = try std.fmt.allocPrint(alloc, "edit_{s}", .{singular});
            } else if (std.mem.eql(u8, r.action, "update") or std.mem.eql(u8, r.action, "destroy")) {
                helper_name = try alloc.dupe(u8, singular);
            } else {
                helper_name = try alloc.dupe(u8, resource_name);
            }
        } else {
            helper_name = try alloc.dupe(u8, helper_base);
        }
        defer alloc.free(helper_name);

        try insertRoute(db, file_id, .{
            .http_method = r.method,
            .path_pattern = path_pattern,
            .helper_name = helper_name,
            .controller = controller,
            .action = r.action,
            .line = lc.line,
            .col = lc.col,
        });

        route_idx += 1;
    }

    // Handle nested block: resources :posts do; resources :comments; end
    if (cn.block) |block_ptr| {
        const block_generic: *const prism.Node = @ptrCast(@alignCast(block_ptr));
        if (block_generic.*.type == prism.NODE_BLOCK) {
            const block_node: *const prism.BlockNode = @ptrCast(@alignCast(block_ptr));
            if (block_node.body) |body| {
                const id_param = if (is_singular) "_id" else "_id";
                const nested_prefix = std.fmt.allocPrint(alloc, "/{s}/:{s}{s}", .{ resource_name, singular, id_param }) catch return;
                ns_ctx.pushPathPrefix(nested_prefix) catch return;
                ns_ctx.pushControllerPrefix(std.fmt.allocPrint(alloc, "{s}/", .{resource_name}) catch return) catch return;
                visitBlockStatements(db, file_id, parser, body, alloc, ns_ctx, resource_name, singular);
                ns_ctx.popControllerPrefix();
                ns_ctx.popPathPrefix();
            }
        }
    }
}

fn visitBlockStatements(db: db_mod.Db, file_id: i64, parser: *prism.Parser, body: *const prism.Node, alloc: std.mem.Allocator, ns_ctx: *NamespaceContext, resource_name: []const u8, singular: []const u8) void {
    if (body.*.type != prism.NODE_STATEMENTS) return;
    const stmts: *const prism.StatementsNode = @ptrCast(@alignCast(body));
    for (0..stmts.body.size) |i| {
        const stmt = stmts.body.nodes[i];
        if (stmt.*.type != prism.NODE_CALL) continue;
        const cn: *const prism.CallNode = @ptrCast(@alignCast(stmt));
        const mname = resolveConstant(parser, cn.name);

        if (cn.arguments == null) continue;
        const args_list = cn.arguments[0].arguments;
        if (args_list.size == 0) continue;
        const first_arg = args_list.nodes[0];

        if (std.mem.eql(u8, mname, "resources")) {
            if (extractSymbolName(parser, first_arg)) |name| {
                handleResourcesCall(db, file_id, parser, cn, name, false, alloc, ns_ctx) catch {};
            }
        } else if (std.mem.eql(u8, mname, "resource")) {
            if (extractSymbolName(parser, first_arg)) |name| {
                handleResourcesCall(db, file_id, parser, cn, name, true, alloc, ns_ctx) catch {};
            }
        } else if (std.mem.eql(u8, mname, "member")) {
            handleMemberCollection(db, file_id, parser, cn, alloc, ns_ctx, resource_name, singular, true) catch {};
        } else if (std.mem.eql(u8, mname, "collection")) {
            handleMemberCollection(db, file_id, parser, cn, alloc, ns_ctx, resource_name, singular, false) catch {};
        } else if (std.mem.eql(u8, mname, "get") or std.mem.eql(u8, mname, "post") or
            std.mem.eql(u8, mname, "put") or std.mem.eql(u8, mname, "patch") or
            std.mem.eql(u8, mname, "delete"))
        {
            handleSimpleRoute(db, file_id, parser, cn, mname, ns_ctx, alloc) catch {};
        }
    }
}

fn handleMemberCollection(db: db_mod.Db, file_id: i64, parser: *prism.Parser, cn: *const prism.CallNode, alloc: std.mem.Allocator, ns_ctx: *NamespaceContext, resource_name: []const u8, singular: []const u8, is_member: bool) !void {
    const block_ptr = cn.block orelse return;
    const block_generic: *const prism.Node = @ptrCast(@alignCast(block_ptr));
    if (block_generic.*.type != prism.NODE_BLOCK) return;
    const block_node: *const prism.BlockNode = @ptrCast(@alignCast(block_ptr));
    const body = block_node.body orelse return;
    if (body.*.type != prism.NODE_STATEMENTS) return;
    const stmts: *const prism.StatementsNode = @ptrCast(@alignCast(body));

    for (0..stmts.body.size) |i| {
        const stmt = stmts.body.nodes[i];
        if (stmt.*.type != prism.NODE_CALL) continue;
        const verb_cn: *const prism.CallNode = @ptrCast(@alignCast(stmt));
        const verb = resolveConstant(parser, verb_cn.name);
        const http_method: []const u8 = if (std.mem.eql(u8, verb, "get")) "GET" else if (std.mem.eql(u8, verb, "post")) "POST" else if (std.mem.eql(u8, verb, "put")) "PUT" else if (std.mem.eql(u8, verb, "patch")) "PATCH" else if (std.mem.eql(u8, verb, "delete")) "DELETE" else continue;

        if (verb_cn.arguments == null) continue;
        const args = verb_cn.arguments[0].arguments;
        if (args.size == 0) continue;
        const action_name = extractSymbolName(parser, args.nodes[0]) orelse continue;
        const lc = locationLineCol(parser, verb_cn.base.location.start);

        const path_pattern = if (is_member)
            std.fmt.allocPrint(alloc, "/{s}/:{s}_id/{s}", .{ resource_name, singular, action_name }) catch continue
        else
            std.fmt.allocPrint(alloc, "/{s}/{s}", .{ resource_name, action_name }) catch continue;
        defer alloc.free(path_pattern);
        const full_path = ns_ctx.getFullPath(alloc, path_pattern) catch continue;
        defer alloc.free(full_path);

        const helper_name = if (is_member)
            std.fmt.allocPrint(alloc, "{s}_{s}", .{ action_name, singular }) catch continue
        else
            std.fmt.allocPrint(alloc, "{s}_{s}", .{ action_name, resource_name }) catch continue;
        defer alloc.free(helper_name);

        insertRoute(db, file_id, .{
            .http_method = http_method,
            .path_pattern = full_path,
            .helper_name = helper_name,
            .controller = resource_name,
            .action = action_name,
            .line = lc.line,
            .col = lc.col,
        }) catch {};
    }
}

fn handleSimpleRoute(db: db_mod.Db, file_id: i64, parser: *prism.Parser, cn: *const prism.CallNode, method: []const u8, ns_ctx: *const NamespaceContext, alloc: std.mem.Allocator) !void {
    if (cn.arguments == null) return;
    const args_list = cn.arguments[0].arguments;
    if (args_list.size < 1) return;

    const lc = locationLineCol(parser, cn.base.location.start);
    const first_arg = args_list.nodes[0];

    var path_pattern: []const u8 = "";
    if (first_arg.*.type == prism.NODE_STRING) {
        const sn: *const prism.StringNode = @ptrCast(@alignCast(first_arg));
        if (sn.unescaped.source) |src| {
            path_pattern = src[0..sn.unescaped.length];
        }
    } else {
        return;
    }

    if (extractToArgument(parser, args_list)) |to_arg| {
        const full_path = try ns_ctx.getFullPath(alloc, path_pattern);
        defer alloc.free(full_path);
        const full_controller = try ns_ctx.getFullController(alloc, to_arg.controller);
        defer alloc.free(full_controller);

        var helper_name_buf: [256]u8 = undefined;
        const helper_len = std.fmt.bufPrint(&helper_name_buf, "{s}_path", .{path_pattern}) catch return;
        const helper_name = helper_len;

        try insertRoute(db, file_id, .{
            .http_method = method,
            .path_pattern = full_path,
            .helper_name = try alloc.dupe(u8, helper_name),
            .controller = full_controller,
            .action = try alloc.dupe(u8, to_arg.action),
            .line = lc.line,
            .col = lc.col,
        });
    }
}

fn handleRootRoute(db: db_mod.Db, file_id: i64, parser: *prism.Parser, cn: *const prism.CallNode, alloc: std.mem.Allocator, ns_ctx: *const NamespaceContext) !void {
    if (cn.arguments == null) return;
    const args_list = cn.arguments[0].arguments;
    if (args_list.size < 1) return;

    const lc = locationLineCol(parser, cn.base.location.start);

    var controller: []const u8 = "";
    var action: []const u8 = "";

    if (args_list.nodes[0].*.type == prism.NODE_STRING) {
        const sn: *const prism.StringNode = @ptrCast(@alignCast(args_list.nodes[0]));
        if (sn.unescaped.source) |src| {
            const val = src[0..sn.unescaped.length];
            if (std.mem.indexOf(u8, val, "#")) |sep| {
                controller = val[0..sep];
                action = val[sep + 1 ..];
            }
        }
    }

    if (controller.len > 0 and action.len > 0) {
        const full_controller = try ns_ctx.getFullController(alloc, controller);
        defer alloc.free(full_controller);

        try insertRoute(db, file_id, .{
            .http_method = "GET",
            .path_pattern = "/",
            .helper_name = try alloc.dupe(u8, "root_path"),
            .controller = full_controller,
            .action = try alloc.dupe(u8, action),
            .line = lc.line,
            .col = lc.col,
        });
    }
}

fn handleMountCall(db: db_mod.Db, file_id: i64, parser: *prism.Parser, cn: *const prism.CallNode, alloc: std.mem.Allocator, ns_ctx: *const NamespaceContext) !void {
    if (cn.arguments == null) return;
    const args_list = cn.arguments[0].arguments;
    if (args_list.size < 1) return;

    const lc = locationLineCol(parser, cn.base.location.start);
    var engine_name: []const u8 = "";
    var mount_path: []const u8 = "";

    if (args_list.nodes[0].*.type == prism.NODE_CONSTANT) {
        const const_node: *const prism.ConstReadNode = @ptrCast(@alignCast(args_list.nodes[0]));
        engine_name = resolveConstant(parser, const_node.name);
    }

    for (0..args_list.size) |i| {
        const arg = args_list.nodes[i];
        if (arg.*.type == prism.NODE_KEYWORD_HASH) {
            const kh: *const prism.KeywordHashNode = @ptrCast(@alignCast(arg));
            for (0..kh.elements.size) |ki| {
                const elem = kh.elements.nodes[ki];
                if (elem.*.type == prism.NODE_ASSOC) {
                    const assoc: *const prism.AssocNode = @ptrCast(@alignCast(elem));
                    if (assoc.key.*.type == prism.NODE_SYMBOL) {
                        const ksym: *const prism.SymbolNode = @ptrCast(@alignCast(assoc.key));
                        if (ksym.unescaped.source) |src| {
                            const key = src[0..ksym.unescaped.length];
                            if (std.mem.eql(u8, key, "at")) {
                                if (assoc.value.*.type == prism.NODE_STRING) {
                                    const sn: *const prism.StringNode = @ptrCast(@alignCast(assoc.value));
                                    if (sn.unescaped.source) |val_src| {
                                        mount_path = val_src[0..sn.unescaped.length];
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (engine_name.len > 0 and mount_path.len > 0) {
        const full_path = try ns_ctx.getFullPath(alloc, mount_path);
        defer alloc.free(full_path);

        try insertRoute(db, file_id, .{
            .http_method = "ANY",
            .path_pattern = full_path,
            .helper_name = try alloc.dupe(u8, ""),
            .controller = try alloc.dupe(u8, engine_name),
            .action = try alloc.dupe(u8, ""),
            .line = lc.line,
            .col = lc.col,
        });
    }
}

fn visitor(node: ?*const prism.Node, data: ?*anyopaque) callconv(.c) bool {
    const ctx: *VisitCtx = @ptrCast(@alignCast(data.?));
    const n = node orelse return true;

    if (n.*.type == prism.NODE_CALL) {
        const cn: *const prism.CallNode = @ptrCast(@alignCast(n));
        const mname = resolveConstant(ctx.parser, cn.name);

        if (cn.arguments == null) return true;
        const args_list = cn.arguments[0].arguments;
        if (args_list.size == 0) return true;

        const first_arg = args_list.nodes[0];

        if (std.mem.eql(u8, mname, "namespace")) {
            if (extractSymbolName(ctx.parser, first_arg)) |ns_name| {
                const path_prefix = (std.fmt.allocPrint(ctx.alloc, "/{s}", .{ns_name}) catch return true);
                const controller_prefix = (std.fmt.allocPrint(ctx.alloc, "{s}::", .{ns_name}) catch return true);
                ctx.ns_ctx.pushPathPrefix(path_prefix) catch {};
                ctx.ns_ctx.pushControllerPrefix(controller_prefix) catch {};
            }
        } else if (std.mem.eql(u8, mname, "scope")) {
            if (extractSymbolName(ctx.parser, first_arg)) |scope_path| {
                const path_prefix = ctx.alloc.dupe(u8, scope_path) catch return true;
                ctx.ns_ctx.pushPathPrefix(path_prefix) catch {};
            }
        } else if (std.mem.eql(u8, mname, "resources")) {
            if (extractSymbolName(ctx.parser, first_arg)) |name| {
                handleResourcesCall(ctx.db, ctx.file_id, ctx.parser, cn, name, false, ctx.alloc, &ctx.ns_ctx) catch {};
                if (cn.block != null) return false;
            }
        } else if (std.mem.eql(u8, mname, "resource")) {
            if (extractSymbolName(ctx.parser, first_arg)) |name| {
                handleResourcesCall(ctx.db, ctx.file_id, ctx.parser, cn, name, true, ctx.alloc, &ctx.ns_ctx) catch {};
                if (cn.block != null) return false;
            }
        } else if (std.mem.eql(u8, mname, "root")) {
            handleRootRoute(ctx.db, ctx.file_id, ctx.parser, cn, ctx.alloc, &ctx.ns_ctx) catch {};
        } else if (std.mem.eql(u8, mname, "mount")) {
            handleMountCall(ctx.db, ctx.file_id, ctx.parser, cn, ctx.alloc, &ctx.ns_ctx) catch {};
        } else if (std.mem.eql(u8, mname, "get") or std.mem.eql(u8, mname, "post") or
                   std.mem.eql(u8, mname, "put") or std.mem.eql(u8, mname, "patch") or
                   std.mem.eql(u8, mname, "delete")) {
            handleSimpleRoute(ctx.db, ctx.file_id, ctx.parser, cn, mname, &ctx.ns_ctx, ctx.alloc) catch {};
        }
    }

    return true;
}

const VisitCtx = struct {
    db: db_mod.Db,
    file_id: i64,
    parser: *prism.Parser,
    alloc: std.mem.Allocator,
    ns_ctx: NamespaceContext,
};

pub fn indexRoutes(db: db_mod.Db, file_id: i64, source: []const u8, alloc: std.mem.Allocator) !void {
    // Delete existing routes for this file
    const del = try db.prepare("DELETE FROM routes WHERE file_id = ?");
    defer del.finalize();
    del.bind_int(1, file_id);
    _ = try del.step();

    // Parse source
    var arena = prism.Arena{ .current = null, .block_count = 0 };
    defer prism.arena_free(&arena);
    var parser: prism.Parser = undefined;
    prism.parser_init(&arena, &parser, source.ptr, source.len, null);
    defer prism.parser_free(&parser);

    const root = prism.parse(&parser);
    if (root == null) return;

    const ns_ctx: NamespaceContext = NamespaceContext.init();
    var ctx = VisitCtx{
        .db = db,
        .file_id = file_id,
        .parser = &parser,
        .alloc = alloc,
        .ns_ctx = ns_ctx,
    };

    prism.visit_node(root, visitor, &ctx);
}
