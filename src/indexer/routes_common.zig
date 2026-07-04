const std = @import("std");
const db_mod = @import("../db.zig");
const prism = @import("../prism.zig");

pub fn extractSymbolName(_: *prism.Parser, node: *const prism.Node) ?[]const u8 {
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

pub const RouteInfo = struct {
    http_method: []const u8,
    path_pattern: []const u8,
    helper_name: []const u8,
    controller: []const u8,
    action: []const u8,
    line: i32,
    col: u32,
};

pub fn insertRoute(db: db_mod.Db, file_id: i64, info: RouteInfo) !void {
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
