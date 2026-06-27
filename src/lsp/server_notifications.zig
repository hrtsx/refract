const std = @import("std");
const builtin = @import("builtin");
const build_meta = @import("build_meta");
const db_mod = @import("../db.zig");
const types = @import("types.zig");
const scanner = @import("../indexer/scanner.zig");
const indexer = @import("../indexer/index.zig");
const gems = @import("../indexer/gems.zig");
const transport = @import("transport.zig");
const prism_mod = @import("../prism.zig");
const refactor = @import("refactor.zig");
const snippets = @import("snippets.zig");
const erb_mapping = @import("erb_mapping.zig");
const hover = @import("hover.zig");
const completion = @import("completion.zig");
const symbols = @import("symbols.zig");
const document_sync = @import("document_sync.zig");
const navigation = @import("navigation.zig");
const diagnostics_mod = @import("diagnostics.zig");
const semantic_tokens = @import("semantic_tokens.zig");
const code_actions = @import("code_actions.zig");
const editing = @import("editing.zig");
const rename = @import("rename.zig");
const hot_index_mod = @import("hot_index.zig");
const workspace_config = @import("workspace_config.zig");
const git_branch = @import("git_branch.zig");
const handler_registry = @import("handler_registry.zig");
const observability = @import("observability.zig");
const plugin_host = @import("plugin_host.zig");
const redact = @import("redact.zig");
const sorbet_bridge = @import("sorbet_bridge.zig");
const sorbet_worker = @import("sorbet_worker.zig");
const llm_adapter = @import("llm_adapter.zig");
const server_util = @import("server_util.zig");
const S = @import("server.zig");
const Server = S.Server;
const writeEscapedJson = S.writeEscapedJson;
const USER_ERROR_RATELIMIT_MS = S.USER_ERROR_RATELIMIT_MS;
const LOG_FILE_SIZE_LIMIT = S.LOG_FILE_SIZE_LIMIT;
const ReadTxn = S.ReadTxn;
const logOomOnce = S.logOomOnce;
const getMetaInt = S.getMetaInt;
const setMetaInt = S.setMetaInt;
const emitSelRange = S.emitSelRange;
const computeDiagCol = S.computeDiagCol;
const serverLogSinkCb = S.serverLogSinkCb;

pub fn sendNotification(self: *Server, json: []const u8) void {
    const w = self.stdout_writer orelse return;
    self.writer_mutex.lockUncancelable(std.Options.debug_io);
    defer self.writer_mutex.unlock(std.Options.debug_io);
    transport.writeMessage(w, json) catch |e| {
        var tw_buf: [128]u8 = undefined;
        const tw_msg = std.fmt.bufPrint(&tw_buf, "refract: transport write: {s}\n", .{@errorName(e)}) catch "refract: transport write failed\n";
        std.debug.print("{s}", .{tw_msg});
    };
}

pub fn logErr(self: *Server, comptime ctx: []const u8, err: anyerror) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "refract: {s}: {s}", .{ ctx, @errorName(err) }) catch "refract: error";
    self.sendLogMessage(2, msg);
}

pub fn showUserError(self: *Server, msg: []const u8) void {
    const now = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds();
    const last = self.last_user_error_ms.load(.monotonic);
    if (now - last < USER_ERROR_RATELIMIT_MS) return;
    self.last_user_error_ms.store(now, .monotonic);
    self.sendShowMessage(2, msg);
}

pub fn rotateLogIfNeeded(self: *Server) void {
    const lp = self.log_path orelse return;
    const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, lp, .{}) catch return;
    if (stat.size < LOG_FILE_SIZE_LIMIT) return;
    var old_buf: [4096]u8 = undefined;
    const old_path = std.fmt.bufPrint(&old_buf, "{s}.old", .{lp}) catch return;
    if (self.log_file) |f| {
        f.close(std.Options.debug_io);
        self.log_file = null;
    }
    std.Io.Dir.cwd().rename(lp, std.Io.Dir.cwd(), old_path, std.Options.debug_io) catch {}; // log rotation best-effort
}

pub fn sendLogMessage(self: *Server, level: u8, msg: []const u8) void {
    if (level > self.log_level.load(.monotonic)) return;
    const redacted_owned = redact.redactAlloc(std.heap.c_allocator, msg) catch null;
    defer if (redacted_owned) |r| std.heap.c_allocator.free(r);
    const safe_msg: []const u8 = if (redacted_owned) |r| r else msg;
    if (self.log_path) |lp| blk: {
        self.log_mutex.lockUncancelable(std.Options.debug_io);
        defer self.log_mutex.unlock(std.Options.debug_io);
        self.rotateLogIfNeeded();
        if (self.log_file == null) {
            self.log_file = std.Io.Dir.cwd().createFile(std.Options.debug_io, lp, .{ .truncate = false }) catch break :blk;
        }
        const f = self.log_file.?;
        const ts = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds();
        const ts_s = @divTrunc(ts, 1000);
        const ts_ms = @mod(ts, 1000);
        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts_s) };
        const day = epoch.getDaySeconds();
        const year_day = epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        var ts_buf: [28]u8 = undefined;
        const ts_str = std.fmt.bufPrint(&ts_buf, "[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}] ", .{
            year_day.year,         month_day.month.numeric(), month_day.day_index + 1,
            day.getHoursIntoDay(), day.getMinutesIntoHour(),  day.getSecondsIntoMinute(),
            ts_ms,
        }) catch "";
        const append_off = f.length(std.Options.debug_io) catch 0;
        f.writePositionalAll(std.Options.debug_io, ts_str, append_off) catch {};
        f.writePositionalAll(std.Options.debug_io, safe_msg, append_off + ts_str.len) catch |e| {
            self.log_file.?.close(std.Options.debug_io);
            self.log_file = null;
            var fbuf: [128]u8 = undefined;
            const fmsg = std.fmt.bufPrint(&fbuf, "refract log write failed: {s}\n", .{@errorName(e)}) catch "refract log write failed\n";
            std.debug.print("{s}", .{fmsg});
            break :blk;
        };
        f.writePositionalAll(std.Options.debug_io, "\n", append_off + ts_str.len + safe_msg.len) catch {};
    }
    var aw = std.Io.Writer.Allocating.init(std.heap.c_allocator);
    const w = &aw.writer;
    w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{\"type\":") catch return;
    w.print("{d}", .{level}) catch return;
    w.writeAll(",\"message\":") catch return;
    writeEscapedJson(w, safe_msg) catch return;
    w.writeAll("}}") catch return;
    const json = aw.toOwnedSlice() catch return;
    defer std.heap.c_allocator.free(json);
    self.sendNotification(json);
}

pub fn sendShowMessage(self: *Server, level: u8, msg: []const u8) void {
    self.sendLspWindowMessage("window/showMessage", level, msg);
}

pub fn sendLspLogMessage(self: *Server, level: u8, msg: []const u8) void {
    self.sendLspWindowMessage("window/logMessage", level, msg);
}

pub fn sendLspWindowMessage(self: *Server, method: []const u8, level: u8, msg: []const u8) void {
    const redacted_owned = redact.redactAlloc(std.heap.c_allocator, msg) catch null;
    defer if (redacted_owned) |r| std.heap.c_allocator.free(r);
    const safe_msg: []const u8 = if (redacted_owned) |r| r else msg;
    var aw = std.Io.Writer.Allocating.init(std.heap.c_allocator);
    const w = &aw.writer;
    w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"") catch return;
    w.writeAll(method) catch return;
    w.writeAll("\",\"params\":{\"type\":") catch return;
    w.print("{d}", .{level}) catch return;
    w.writeAll(",\"message\":") catch return;
    writeEscapedJson(w, safe_msg) catch return;
    w.writeAll("}}") catch return;
    const json = aw.toOwnedSlice() catch return;
    defer std.heap.c_allocator.free(json);
    self.sendNotification(json);
}

pub fn sendProgressBegin(self: *Server) void {
    if (!self.client_caps_work_done_progress) return;
    const req_id = self.progress_req_counter.fetchAdd(1, .monotonic);
    self.active_progress_token_id = req_id;
    var token_buf: [32]u8 = undefined;
    const token = std.fmt.bufPrint(&token_buf, "refract_{d}", .{req_id}) catch "refract_0";
    var buf: [512]u8 = undefined;
    const create_msg = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"window/workDoneProgress/create\",\"params\":{{\"token\":\"{s}\"}}}}", .{ req_id, token }) catch return;
    self.sendNotification(create_msg);
    var begin_buf: [256]u8 = undefined;
    const begin_msg = std.fmt.bufPrint(&begin_buf, "{{\"jsonrpc\":\"2.0\",\"method\":\"$/progress\",\"params\":{{\"token\":\"{s}\",\"value\":{{\"kind\":\"begin\",\"title\":\"Indexing\"}}}}}}", .{token}) catch return;
    self.sendNotification(begin_msg);
}

pub fn sendProgressEnd(self: *Server) void {
    if (!self.client_caps_work_done_progress) return;
    var token_buf: [32]u8 = undefined;
    const token = std.fmt.bufPrint(&token_buf, "refract_{d}", .{self.active_progress_token_id}) catch "refract_0";
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"method\":\"$/progress\",\"params\":{{\"token\":\"{s}\",\"value\":{{\"kind\":\"end\"}}}}}}", .{token}) catch return;
    self.sendNotification(msg);
}

pub fn sendProgressReport(self: *Server, done: usize, total: usize) void {
    if (!self.client_caps_work_done_progress) return;
    const pct: u32 = if (total > 0) @intCast(@min(100, done * 100 / total)) else 0;
    var token_buf: [32]u8 = undefined;
    const token = std.fmt.bufPrint(&token_buf, "refract_{d}", .{self.active_progress_token_id}) catch "refract_0";
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"$/progress\",\"params\":{{\"token\":\"{s}\",\"value\":{{\"kind\":\"report\",\"message\":\"{d}/{d} files\",\"percentage\":{d}}}}}}}",
        .{ token, done, total, pct },
    ) catch return;
    self.sendNotification(msg);
}

pub fn sendProgressReportWithDir(self: *Server, done: usize, total: usize, dir_name: []const u8) void {
    if (!self.client_caps_work_done_progress) return;
    const pct: u32 = if (total > 0) @intCast(@min(100, done * 100 / total)) else 0;
    var token_buf: [32]u8 = undefined;
    const token = std.fmt.bufPrint(&token_buf, "refract_{d}", .{self.active_progress_token_id}) catch "refract_0";
    var buf: [320]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"$/progress\",\"params\":{{\"token\":\"{s}\",\"value\":{{\"kind\":\"report\",\"message\":\"{d}% ({s})\",\"percentage\":{d}}}}}}}",
        .{ token, pct, dir_name, pct },
    ) catch return;
    self.sendNotification(msg);
}
