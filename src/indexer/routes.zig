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
        var parts: std.ArrayList([]const u8) = .empty;
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
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(alloc);
        for (0..self.controller_prefix_depth) |i| {
            try parts.append(alloc, self.controller_prefix_stack[i]);
        }
        try parts.append(alloc, base_controller);
        return try std.mem.join(alloc, "", parts.items);
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
                handleResourcesCall(db, file_id, parser, cn, name, false, alloc, ns_ctx) catch |e| {
                    std.debug.print("{s}", .{"refract: route indexing error: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
                };
            }
        } else if (std.mem.eql(u8, mname, "resource")) {
            if (extractSymbolName(parser, first_arg)) |name| {
                handleResourcesCall(db, file_id, parser, cn, name, true, alloc, ns_ctx) catch |e| {
                    std.debug.print("{s}", .{"refract: route indexing error: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
                };
            }
        } else if (std.mem.eql(u8, mname, "member")) {
            handleMemberCollection(db, file_id, parser, cn, alloc, ns_ctx, resource_name, singular, true) catch |e| {
                std.debug.print("{s}", .{"refract: route member error: "});
                std.debug.print("{s}", .{@errorName(e)});
                std.debug.print("{s}", .{"\n"});
            };
        } else if (std.mem.eql(u8, mname, "collection")) {
            handleMemberCollection(db, file_id, parser, cn, alloc, ns_ctx, resource_name, singular, false) catch |e| {
                std.debug.print("{s}", .{"refract: route collection error: "});
                std.debug.print("{s}", .{@errorName(e)});
                std.debug.print("{s}", .{"\n"});
            };
        } else if (std.mem.eql(u8, mname, "get") or std.mem.eql(u8, mname, "post") or
            std.mem.eql(u8, mname, "put") or std.mem.eql(u8, mname, "patch") or
            std.mem.eql(u8, mname, "delete"))
        {
            handleSimpleRoute(db, file_id, parser, cn, mname, ns_ctx, alloc) catch |e| {
                std.debug.print("{s}", .{"refract: route error: "});
                std.debug.print("{s}", .{@errorName(e)});
                std.debug.print("{s}", .{"\n"});
            };
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
                handleResourcesCall(ctx.db, ctx.file_id, ctx.parser, cn, name, false, ctx.alloc, &ctx.ns_ctx) catch |e| {
                    var ebuf: [256]u8 = undefined;
                    const emsg = std.fmt.bufPrint(&ebuf, "refract: route parse error ({s}): {s}\n", .{ "resources", @errorName(e) }) catch "refract: route parse error\n";
                    std.debug.print("{s}", .{emsg});
                };
                if (cn.block != null) return false;
            }
        } else if (std.mem.eql(u8, mname, "resource")) {
            if (extractSymbolName(ctx.parser, first_arg)) |name| {
                handleResourcesCall(ctx.db, ctx.file_id, ctx.parser, cn, name, true, ctx.alloc, &ctx.ns_ctx) catch |e| {
                    var ebuf: [256]u8 = undefined;
                    const emsg = std.fmt.bufPrint(&ebuf, "refract: route parse error ({s}): {s}\n", .{ "resource", @errorName(e) }) catch "refract: route parse error\n";
                    std.debug.print("{s}", .{emsg});
                };
                if (cn.block != null) return false;
            }
        } else if (std.mem.eql(u8, mname, "root")) {
            handleRootRoute(ctx.db, ctx.file_id, ctx.parser, cn, ctx.alloc, &ctx.ns_ctx) catch |e| {
                var ebuf: [256]u8 = undefined;
                const emsg = std.fmt.bufPrint(&ebuf, "refract: route parse error ({s}): {s}\n", .{ "root", @errorName(e) }) catch "refract: route parse error\n";
                std.debug.print("{s}", .{emsg});
            };
        } else if (std.mem.eql(u8, mname, "mount")) {
            handleMountCall(ctx.db, ctx.file_id, ctx.parser, cn, ctx.alloc, &ctx.ns_ctx) catch |e| {
                var ebuf: [256]u8 = undefined;
                const emsg = std.fmt.bufPrint(&ebuf, "refract: route parse error ({s}): {s}\n", .{ "mount", @errorName(e) }) catch "refract: route parse error\n";
                std.debug.print("{s}", .{emsg});
            };
        } else if (std.mem.eql(u8, mname, "get") or std.mem.eql(u8, mname, "post") or
            std.mem.eql(u8, mname, "put") or std.mem.eql(u8, mname, "patch") or
            std.mem.eql(u8, mname, "delete"))
        {
            handleSimpleRoute(ctx.db, ctx.file_id, ctx.parser, cn, mname, &ctx.ns_ctx, ctx.alloc) catch |e| {
                var ebuf: [256]u8 = undefined;
                const emsg = std.fmt.bufPrint(&ebuf, "refract: route parse error ({s}): {s}\n", .{ mname, @errorName(e) }) catch "refract: route parse error\n";
                std.debug.print("{s}", .{emsg});
            };
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
                }) catch {};
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

pub fn indexRoutes(db: db_mod.Db, file_id: i64, source: []const u8, alloc: std.mem.Allocator) !void {
    indexRoutesWithPath(db, file_id, source, alloc, "");
}

pub fn indexRoutesWithPath(db: db_mod.Db, file_id: i64, source: []const u8, backing_alloc: std.mem.Allocator, file_path: []const u8) void {
    var route_arena = std.heap.ArenaAllocator.init(backing_alloc);
    defer route_arena.deinit();
    const alloc = route_arena.allocator();

    // Delete existing routes for this file
    const del = db.prepare("DELETE FROM routes WHERE file_id = ?") catch return;
    defer del.finalize();
    del.bind_int(1, file_id);
    _ = del.step() catch return;

    // Parse source
    var arena = prism.Arena{ .current = null, .block_count = 0 };
    defer prism.arena_free(&arena);
    var parser: prism.Parser = undefined;
    prism.parser_init(&arena, &parser, source.ptr, source.len, null);
    defer prism.parser_free(&parser);

    const root = prism.parse(&parser);
    if (root == null) return;

    // Try Rails visitor first
    const ns_ctx: NamespaceContext = NamespaceContext.init();
    var ctx = VisitCtx{
        .db = db,
        .file_id = file_id,
        .parser = &parser,
        .alloc = alloc,
        .ns_ctx = ns_ctx,
    };

    prism.visit_node(root, visitor, &ctx);

    // Check if any routes were found — if not, try Roda visitor
    const count_stmt = db.prepare("SELECT COUNT(*) FROM routes WHERE file_id = ?") catch return;
    defer count_stmt.finalize();
    count_stmt.bind_int(1, file_id);
    const has_routes = if (count_stmt.step() catch false) count_stmt.column_int(0) > 0 else false;

    if (!has_routes) {
        var route_count: u32 = 0;
        const controller = controllerFromPath(alloc, file_path);
        var roda_ctx = RodaCtx{
            .db = db,
            .file_id = file_id,
            .parser = &parser,
            .alloc = alloc,
            .path_stack = undefined,
            .path_depth = 0,
            .route_count = &route_count,
            .controller = controller,
        };
        rodaVisitNode(&roda_ctx, @ptrCast(@alignCast(root)));
    }
}

test "indexRoutes parses basic get route" {
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    try db.exec("INSERT INTO files(path, mtime) VALUES('config/routes.rb', 0)");
    const fid = db.last_insert_rowid();
    try indexRoutes(db, fid,
        \\Rails.application.routes.draw do
        \\  get '/health', to: 'health#index'
        \\end
    , std.testing.allocator);
    const s = try db.prepare("SELECT http_method, path_pattern FROM routes WHERE file_id=?");
    defer s.finalize();
    s.bind_int(1, fid);
    try std.testing.expect(try s.step());
    try std.testing.expectEqualStrings("GET", s.column_text(0));
    try std.testing.expectEqualStrings("/health", s.column_text(1));
}

test "indexRoutes handles nested resources" {
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    try db.exec("INSERT INTO files(path, mtime) VALUES('config/routes.rb', 0)");
    const fid = db.last_insert_rowid();
    try indexRoutes(db, fid,
        \\Rails.application.routes.draw do
        \\  resources :posts do
        \\    resources :comments
        \\  end
        \\end
    , std.testing.allocator);
    const s = try db.prepare("SELECT COUNT(*) FROM routes WHERE file_id=?");
    defer s.finalize();
    s.bind_int(1, fid);
    try std.testing.expect(try s.step());
    try std.testing.expect(s.column_int(0) > 0);
}

test "indexRoutes handles empty source" {
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    try db.exec("INSERT INTO files(path, mtime) VALUES('config/routes.rb', 0)");
    const fid = db.last_insert_rowid();
    try indexRoutes(db, fid, "", std.testing.allocator);
    const s = try db.prepare("SELECT COUNT(*) FROM routes WHERE file_id=?");
    defer s.finalize();
    s.bind_int(1, fid);
    try std.testing.expect(try s.step());
    try std.testing.expectEqual(@as(i64, 0), s.column_int(0));
}
