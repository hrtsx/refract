const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const types = @import("types.zig");
const db_mod = @import("../db.zig");
const indexer = @import("../indexer/index.zig");

const extractTextDocumentUri = S.extractTextDocumentUri;
const emptyResult = S.emptyResult;
const uriToPath = S.uriToPath;
const computeDiagCol = S.computeDiagCol;
const writeEscapedJson = S.writeEscapedJson;
const TimeoutCtx = S.TimeoutCtx;
const LOG_FILE_SIZE_LIMIT = S.LOG_FILE_SIZE_LIMIT;

pub fn writeDiagItems(
    self: *Server,
    w: *std.Io.Writer,
    diags: []const indexer.DiagEntry,
    diag_source: ?[]const u8,
    first_ptr: *bool,
) void {
    for (diags) |d| {
        if (!first_ptr.*) w.writeByte(',') catch return;
        first_ptr.* = false;
        const l: i64 = if (d.line > 0) d.line - 1 else 0;
        const c0 = computeDiagCol(diag_source, self.encoding_utf8, l, d.col);
        const end_char: i64 = if (d.end_col > 0) computeDiagCol(diag_source, self.encoding_utf8, l, d.end_col) else c0 + 1;
        w.print("{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":{d},\"source\":", .{ l, c0, l, end_char, d.severity }) catch return;
        writeEscapedJson(w, d.source) catch return;
        w.writeAll(",\"message\":") catch return;
        writeEscapedJson(w, d.message) catch return;
        if (d.code.len > 0) {
            w.writeAll(",\"code\":") catch return;
            writeEscapedJson(w, d.code) catch return;
            if (!std.mem.startsWith(u8, d.code, "refract/")) {
                const slash = std.mem.indexOfScalar(u8, d.code, '/') orelse d.code.len;
                w.writeAll(",\"codeDescription\":{\"href\":\"https://docs.rubocop.org/rubocop/cops_") catch return;
                for (d.code[0..slash]) |ch| w.writeByte(std.ascii.toLower(ch)) catch return;
                w.writeAll(".html\"}") catch return;
            }
        }
        w.writeByte('}') catch return;
    }
}

pub fn enqueueRubocopPath(self: *Server, path: []const u8) void {
    if (self.disable_rubocop.load(.monotonic)) return;
    const duped = self.alloc.dupe(u8, path) catch return;
    self.rubocop_queue_mu.lockUncancelable(std.Options.debug_io);
    defer self.rubocop_queue_mu.unlock(std.Options.debug_io);
    if (self.rubocop_pending.contains(duped)) {
        self.alloc.free(duped);
        return;
    }
    self.rubocop_pending.put(self.alloc, duped, {}) catch {
        self.alloc.free(duped);
        return;
    };
    self.rubocop_queue_cond.signal(std.Options.debug_io);
}

pub fn enqueueAllOpenDocs(self: *Server) void {
    var uris = std.ArrayList([]const u8).empty;
    defer uris.deinit(self.alloc);
    {
        self.open_docs_mu.lockUncancelable(std.Options.debug_io);
        defer self.open_docs_mu.unlock(std.Options.debug_io);
        var uri_it = self.open_docs.keyIterator();
        while (uri_it.next()) |k| uris.append(self.alloc, k.*) catch S.logOomOnce("diagnostics.uris");
    }
    for (uris.items) |uri| {
        const path = uriToPath(self.alloc, uri) catch continue;
        defer self.alloc.free(path);
        enqueueRubocopPath(self, path);
    }
}

pub fn publishDiagnostics(self: *Server, uri: []const u8, path: []const u8, run_rubocop: bool) void {
    const diag_source: ?[]const u8 = self.open_docs.get(uri);
    const prism_diags = if (diag_source) |src|
        indexer.getDiagsFromSource(src, path, self.alloc) catch return
    else
        indexer.getDiags(path, self.alloc) catch return;
    defer {
        for (prism_diags) |d| self.alloc.free(d.message);
        self.alloc.free(prism_diags);
    }

    if (run_rubocop) {
        var is_gem_file = false;
        self.db_mutex.lockUncancelable(std.Options.debug_io);
        if (self.db.prepare("SELECT is_gem FROM files WHERE path = ?")) |gs| {
            defer gs.finalize();
            gs.bind_text(1, path);
            if (gs.step() catch false) is_gem_file = gs.column_int(0) != 0;
        } else |_| {}
        self.db_mutex.unlock(std.Options.debug_io);
        if (!is_gem_file) enqueueRubocopPath(self, path);
    }

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":") catch return;
    writeEscapedJson(w, uri) catch return;
    w.writeAll(",\"diagnostics\":[") catch return;
    var first = true;
    writeDiagItems(self, w, prism_diags, diag_source, &first);

    // Semantic checks (unused vars, undefined methods)
    sem_blk: {
        self.db_mutex.lockUncancelable(std.Options.debug_io);
        defer self.db_mutex.unlock(std.Options.debug_io);
        const fid_stmt = self.db.prepare("SELECT id FROM files WHERE path = ?") catch break :sem_blk;
        defer fid_stmt.finalize();
        fid_stmt.bind_text(1, path);
        if (!(fid_stmt.step() catch false)) break :sem_blk;
        const fid = fid_stmt.column_int(0);
        var sem_diags = indexer.runSemanticChecks(self.db, fid, self.alloc) catch break :sem_blk;
        defer {
            for (sem_diags.items) |d| self.alloc.free(d.message);
            sem_diags.deinit(self.alloc);
        }
        writeDiagItems(self, w, sem_diags.items, diag_source, &first);
    }

    w.writeAll("]}}") catch return;

    const json = aw.toOwnedSlice() catch return;
    defer self.alloc.free(json);
    self.sendNotification(json);
}

pub fn probeRubocopBundle(self: *Server) void {
    if (self.rubocop_bundle_probed.load(.monotonic)) return;
    self.rubocop_bundle_probed.store(true, .monotonic);
    const root = self.root_path orelse return;
    const gl = std.fmt.allocPrint(self.alloc, "{s}/Gemfile.lock", .{root}) catch return;
    defer self.alloc.free(gl);
    std.Io.Dir.accessAbsolute(std.Options.debug_io, gl, .{}) catch return;
    var probe = std.process.spawn(self.io, .{
        .argv = &.{ "bundle", "exec", "rubocop", "--version" },
        .cwd = .{ .path = root },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    const term = probe.wait(std.Options.debug_io) catch return;
    if (term == .exited and term.exited == 0) self.rubocop_use_bundle.store(true, .monotonic);
}

pub fn getRubocopDiags(self: *Server, path: []const u8) ![]indexer.DiagEntry {
    if (self.rubocop_checked.load(.monotonic) and !self.rubocop_available.load(.monotonic)) return &.{};
    const file_mtime: ?i64 = if (std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{})) |st| st.mtime.toMilliseconds() else |_| null;
    if (file_mtime) |mt| {
        self.rubocop_mtime_mu.lockUncancelable(std.Options.debug_io);
        const cached = self.rubocop_mtime_cache.get(path);
        self.rubocop_mtime_mu.unlock(std.Options.debug_io);
        if (cached) |c| if (c == mt) return &.{};
    }
    probeRubocopBundle(
        self,
    );
    const argv: []const []const u8 = if (self.rubocop_use_bundle.load(.monotonic))
        &.{ "bundle", "exec", "rubocop", "--format", "json", "--no-color", "--no-cache", path }
    else
        &.{ "rubocop", "--format", "json", "--no-color", "--no-cache", path };
    var child = std.process.spawn(self.io, .{
        .argv = argv,
        .cwd = .{ .path = self.root_path orelse std.fs.path.dirname(path) orelse "." },
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        if (err == error.FileNotFound and !self.rubocop_checked.load(.monotonic)) {
            self.rubocop_checked.store(true, .monotonic);
            self.rubocop_available.store(false, .monotonic);
            self.sendShowMessage(3, "refract: rubocop not found — install it or add to PATH for diagnostics");
        }
        return &.{};
    };
    self.rubocop_checked.store(true, .monotonic);

    var tctx = TimeoutCtx{ .child = &child, .done = std.atomic.Value(bool).init(false), .timeout_ns = self.rubocop_timeout_ms.load(.monotonic) * std.time.ns_per_ms };
    const tkill = std.Thread.spawn(.{}, TimeoutCtx.run, .{&tctx}) catch null;
    // Always reap the child to avoid zombie processes, even on early-return paths
    defer {
        tctx.done.store(true, .release);
        if (tkill) |t| t.join();
        _ = child.wait(std.Options.debug_io) catch {}; // cleanup
    }

    var stdout_buf = std.ArrayList(u8).empty;
    defer stdout_buf.deinit(self.alloc);
    var buf: [4096]u8 = undefined;
    const max_rubocop_bytes: usize = LOG_FILE_SIZE_LIMIT;
    while (true) {
        if (stdout_buf.items.len >= max_rubocop_bytes) {
            child.stdout.?.close(std.Options.debug_io);
            child.stdout = null;
            break;
        }
        const n = child.stdout.?.readStreaming(std.Options.debug_io, &.{buf[0..]}) catch break;
        if (n == 0) break;
        stdout_buf.appendSlice(self.alloc, buf[0..n]) catch return &.{};
    }

    var stderr_bytes: [1024]u8 = undefined;
    const stderr_n: usize = if (child.stderr) |se| se.readStreaming(std.Options.debug_io, &.{stderr_bytes[0..]}) catch 0 else 0;
    child.stderr = null;

    if (stdout_buf.items.len == 0) {
        if (stderr_n > 0) {
            const nl = std.mem.indexOfScalar(u8, stderr_bytes[0..stderr_n], '\n') orelse stderr_n;
            const first_line = stderr_bytes[0..@min(nl, 256)];
            var msg_buf: [320]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "refract: rubocop error — {s}", .{first_line}) catch "refract: rubocop returned no output — check .rubocop.yml";
            self.sendShowMessage(2, msg);
        } else {
            self.sendLogMessage(2, "refract: rubocop produced no output");
        }
        return &.{};
    }

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        self.alloc,
        stdout_buf.items,
        .{ .ignore_unknown_fields = true },
    ) catch {
        self.sendLogMessage(2, "refract: rubocop output was not valid JSON — check rubocop version");
        return &.{};
    };
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return &.{},
    };
    const files_json = root_obj.get("files") orelse return &.{};
    const files_arr = switch (files_json) {
        .array => |a| a,
        else => return &.{},
    };
    if (files_arr.items.len == 0) return &.{};
    const file_obj = switch (files_arr.items[0]) {
        .object => |o| o,
        else => return &.{},
    };
    const offenses_json = file_obj.get("offenses") orelse return &.{};
    const offenses_arr = switch (offenses_json) {
        .array => |a| a,
        else => return &.{},
    };

    var list = std.ArrayList(indexer.DiagEntry).empty;
    errdefer {
        for (list.items) |e| {
            self.alloc.free(e.message);
            if (e.code.len > 0) self.alloc.free(@constCast(e.code));
        }
        list.deinit(self.alloc);
    }

    for (offenses_arr.items) |offense_val| {
        const offense = switch (offense_val) {
            .object => |o| o,
            else => continue,
        };
        const sev_json = offense.get("severity") orelse continue;
        const sev_str = switch (sev_json) {
            .string => |s| s,
            else => continue,
        };
        const msg_json = offense.get("message") orelse continue;
        const msg_str = switch (msg_json) {
            .string => |s| s,
            else => continue,
        };
        const cop_json = offense.get("cop_name");
        const cop_str: []const u8 = if (cop_json) |cj| switch (cj) {
            .string => |s| s,
            else => "",
        } else "";
        const loc_json = offense.get("location") orelse continue;
        const loc_obj = switch (loc_json) {
            .object => |o| o,
            else => continue,
        };
        const line_json = loc_obj.get("line") orelse continue;
        const rb_line: i32 = switch (line_json) {
            .integer => |i| if (i >= 0 and i <= std.math.maxInt(i32)) @intCast(i) else continue,
            else => continue,
        };
        const col_json = loc_obj.get("start_column") orelse continue;
        const rb_col_1: u32 = switch (col_json) {
            .integer => |i| if (i >= 0) @intCast(i) else continue,
            else => continue,
        };
        const len_json = loc_obj.get("length");
        const rb_len: u32 = if (len_json) |lj| switch (lj) {
            .integer => |i| if (i >= 0) @intCast(i) else 0,
            else => 0,
        } else 0;

        const severity: u8 = if (std.mem.eql(u8, sev_str, "error") or std.mem.eql(u8, sev_str, "fatal")) 1 else if (std.mem.eql(u8, sev_str, "warning")) 2 else 3;

        const col_0: u32 = if (rb_col_1 > 0) rb_col_1 - 1 else 0;
        const code_duped: []const u8 = if (cop_str.len > 0) try self.alloc.dupe(u8, cop_str) else "";
        try list.append(self.alloc, .{
            .line = rb_line,
            .col = col_0,
            .message = try self.alloc.dupe(u8, msg_str),
            .severity = severity,
            .source = "RuboCop",
            .end_col = col_0 + rb_len,
            .code = code_duped,
        });
    }

    if (file_mtime) |mt| updateRubocopMtime(self, path, mt);
    return list.toOwnedSlice(self.alloc);
}

fn updateRubocopMtime(self: *Server, path: []const u8, mtime_ns: i64) void {
    self.rubocop_mtime_mu.lockUncancelable(std.Options.debug_io);
    defer self.rubocop_mtime_mu.unlock(std.Options.debug_io);
    if (self.rubocop_mtime_cache.getPtr(path)) |v| {
        v.* = mtime_ns;
        return;
    }
    if (self.rubocop_mtime_cache.count() >= 512) {
        var oldest: ?[]const u8 = null;
        var it = self.rubocop_mtime_cache.keyIterator();
        if (it.next()) |k| oldest = k.*;
        if (oldest) |k| {
            if (self.rubocop_mtime_cache.fetchRemove(k)) |kv| {
                self.alloc.free(kv.key);
            }
        }
    }
    const dup_key = self.alloc.dupe(u8, path) catch return;
    self.rubocop_mtime_cache.put(self.alloc, dup_key, mtime_ns) catch {
        self.alloc.free(dup_key);
    };
}

pub fn handlePullDiagnostic(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    if (self.isCancelled(msg.id)) return self.cancelledResponse(msg.id);
    const params = msg.params orelse return emptyResult(msg);
    const obj = switch (params) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const td_val = obj.get("textDocument") orelse return emptyResult(msg);
    const td = switch (td_val) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const uri_val = td.get("uri") orelse return emptyResult(msg);
    const uri = switch (uri_val) {
        .string => |s| s,
        else => return emptyResult(msg),
    };
    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);

    const diag_source: ?[]const u8 = self.open_docs.get(uri);
    const src_for_hash: []const u8 = diag_source orelse "";
    const content_hash = std.hash.Wyhash.hash(0, src_for_hash);
    var result_id_buf: [20]u8 = undefined;
    const result_id = std.fmt.bufPrint(&result_id_buf, "{x}", .{content_hash}) catch "0";

    const prev_result_id: ?[]const u8 = if (obj.get("previousResultId")) |v| switch (v) {
        .string => |s| s,
        else => null,
    } else null;
    if (prev_result_id) |prid| {
        if (std.mem.eql(u8, prid, result_id)) {
            var aw2 = std.Io.Writer.Allocating.init(self.alloc);
            try aw2.writer.print("{{\"kind\":\"unchanged\",\"resultId\":\"{s}\"}}", .{result_id});
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw2.toOwnedSlice(), .@"error" = null };
        }
    }

    const prism_diags: []indexer.DiagEntry = if (diag_source) |src|
        indexer.getDiagsFromSource(src, path, self.alloc) catch &.{}
    else
        indexer.getDiags(path, self.alloc) catch &.{};
    defer {
        for (prism_diags) |d| self.alloc.free(d.message);
        self.alloc.free(prism_diags);
    }

    {
        var is_gem_file = false;
        self.db_mutex.lockUncancelable(std.Options.debug_io);
        if (self.db.prepare("SELECT is_gem FROM files WHERE path = ?")) |gs| {
            defer gs.finalize();
            gs.bind_text(1, path);
            if (gs.step() catch false) is_gem_file = gs.column_int(0) != 0;
        } else |_| {}
        self.db_mutex.unlock(std.Options.debug_io);
        if (!is_gem_file) enqueueRubocopPath(self, path);
    }

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.print("{{\"kind\":\"full\",\"resultId\":\"{s}\",\"items\":[", .{result_id});
    var first = true;
    writeDiagItems(self, w, prism_diags, diag_source, &first);
    try w.writeAll("]}");
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}
