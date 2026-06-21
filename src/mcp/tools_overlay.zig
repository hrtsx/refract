const std = @import("std");
const db_mod = @import("../db.zig");
const refactor_mod = @import("../lsp/refactor.zig");
const overlay = @import("../lsp/overlay.zig");
const git_branch = @import("../lsp/git_branch.zig");
const indexer = @import("../indexer/index.zig");
const build_meta = @import("build_meta");
const server = @import("server.zig");
const Server = server.Server;
const overlayTable = Server.overlayTable;
const nowS = Server.nowS;
const gateMsg = Server.gateMsg;
const nowUs = Server.nowUs;
const MAX_LINE_BODY_BYTES = server.MAX_LINE_BODY_BYTES;
const countLines = server.countLines;
const ftsQuote = server.ftsQuote;
const getIntArg = server.getIntArg;
const getStrArg = server.getStrArg;
const normalizeFileArg = server.normalizeFileArg;
const regexMatchLine = server.regexMatchLine;
const splitQualified = server.splitQualified;
const stepLog = server.stepLog;
const validateGlobPattern = server.validateGlobPattern;
const writeJsonStr = server.writeJsonStr;
const writeJsonStrCapped = server.writeJsonStrCapped;

pub fn overlayAnnotate(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const op_s = getStrArg(args, "op") orelse return srv.buildToolError(id, "missing 'op'");
    const op = overlay.parseOp(op_s) orelse return srv.buildToolError(id, "unknown 'op'");
    const reason = getStrArg(args, "reason") orelse return srv.buildToolError(id, "missing 'reason'");
    const ctx = srv.overlayCtx() orelse return srv.buildToolError(id, "no workspace/project identity");
    defer ctx.deinit();
    const scope = getStrArg(args, "scope") orelse "branch";
    // Explicit 'branch' wins; else 'scope':global => project-global (null);
    // else the server-detected current branch.
    const eff_branch: ?[]const u8 = if (getStrArg(args, "branch")) |b|
        b
    else if (std.mem.eql(u8, scope, "global"))
        null
    else
        ctx.branch;
    const is_user = if (getStrArg(args, "source")) |s| std.mem.eql(u8, s, "user") else false;
    const now_s = nowS();

    var new_id: ?i64 = null;
    var affected: ?[]const u8 = null;
    switch (op) {
        .note, .tag, .concept => {
            const fqn = getStrArg(args, "fqn") orelse return srv.buildToolError(id, "missing 'fqn'");
            affected = fqn;
            new_id = overlay.addNode(srv.db, ctx.pid, eff_branch, fqn, op_s, getStrArg(args, "label"), getStrArg(args, "content"), is_user, reason, now_s) catch |e| {
                srv.auditOverlay("overlay_annotate", fqn, "error");
                return srv.buildToolError(id, gateMsg(e));
            };
        },
        .edge => {
            const from = getStrArg(args, "from") orelse return srv.buildToolError(id, "edge requires 'from'");
            const to = getStrArg(args, "to") orelse return srv.buildToolError(id, "edge requires 'to'");
            affected = from;
            new_id = overlay.addEdge(srv.db, ctx.pid, eff_branch, from, to, getStrArg(args, "edge_kind") orelse "related_to", getStrArg(args, "label"), is_user, reason, now_s) catch |e| {
                srv.auditOverlay("overlay_annotate", from, "error");
                return srv.buildToolError(id, gateMsg(e));
            };
        },
        .override => {
            const fqn = getStrArg(args, "fqn") orelse return srv.buildToolError(id, "override requires 'fqn'");
            const type_str = getStrArg(args, "type") orelse return srv.buildToolError(id, "override requires 'type'");
            affected = fqn;
            new_id = overlay.addType(srv.db, ctx.pid, eff_branch, fqn, getStrArg(args, "method"), getIntArg(args, "param_pos") orelse -1, type_str, is_user, reason, now_s) catch |e| {
                srv.auditOverlay("overlay_annotate", fqn, "error");
                return srv.buildToolError(id, gateMsg(e));
            };
        },
        .suppress => {
            const diag_code = getStrArg(args, "diag_code") orelse return srv.buildToolError(id, "suppress requires 'diag_code'");
            const fqn = getStrArg(args, "fqn");
            const file = getStrArg(args, "file");
            affected = fqn orelse file;
            new_id = overlay.addSuppress(srv.db, ctx.pid, eff_branch, fqn, file, diag_code, getIntArg(args, "line"), is_user, reason, now_s) catch |e| {
                srv.auditOverlay("overlay_annotate", affected, "error");
                return srv.buildToolError(id, gateMsg(e));
            };
        },
    }
    const nid = new_id orelse return srv.buildToolError(id, "overlay write failed");
    srv.auditOverlay("overlay_annotate", affected, "ok");
    return srv.overlayOk(id, nid, eff_branch, is_user);
}

pub fn overlayList(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const kind = getStrArg(args, "kind") orelse return srv.buildToolError(id, "missing 'kind'");
    const table = overlayTable(kind) orelse return srv.buildToolError(id, "unknown 'kind'");
    const ctx = srv.overlayCtx() orelse return srv.buildToolError(id, "no workspace/project identity");
    defer ctx.deinit();
    const all = if (args) |m| (if (m.get("all_branches")) |v| (v == .bool and v.bool) else false) else false;
    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    overlay.listJson(srv.db, srv.alloc, &aw.writer, ctx.pid, table, ctx.branch, all);
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}

pub fn overlayRevert(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const kind = getStrArg(args, "kind") orelse return srv.buildToolError(id, "missing 'kind'");
    const table = overlayTable(kind) orelse return srv.buildToolError(id, "unknown 'kind'");
    const row_id = getIntArg(args, "id") orelse return srv.buildToolError(id, "missing 'id'");
    const reason = getStrArg(args, "reason") orelse return srv.buildToolError(id, "missing 'reason'");
    if (std.mem.trim(u8, reason, " \t\r\n").len == 0) return srv.buildToolError(id, "reason is required");
    const ok = overlay.revoke(srv.db, srv.alloc, table, row_id, nowS());
    srv.auditOverlay("overlay_revert", null, if (ok) "ok" else "error");
    if (!ok) return srv.buildToolError(id, "no live overlay row with that id");
    return srv.buildToolResult(id, "{\"ok\":true,\"reverted\":true}");
}

pub fn overlayPromote(srv: *Server, id: ?std.json.Value, args: ?std.json.ObjectMap) !?[]u8 {
    const reason = getStrArg(args, "reason") orelse return srv.buildToolError(id, "missing 'reason'");
    if (std.mem.trim(u8, reason, " \t\r\n").len == 0) return srv.buildToolError(id, "reason is required");
    const ctx = srv.overlayCtx() orelse return srv.buildToolError(id, "no workspace/project identity");
    defer ctx.deinit();
    const from_branch = getStrArg(args, "from_branch") orelse (ctx.branch orelse return srv.buildToolError(id, "detached HEAD — pass 'from_branch'"));
    const n = overlay.promote(srv.db, srv.alloc, ctx.pid, from_branch, nowS());
    srv.auditOverlay("overlay_promote", null, "ok");
    var aw = std.Io.Writer.Allocating.init(srv.alloc);
    errdefer aw.deinit();
    try aw.writer.print("{{\"ok\":true,\"promoted\":{d}}}", .{n});
    const text = try aw.toOwnedSlice();
    defer srv.alloc.free(text);
    return srv.buildToolResult(id, text);
}
