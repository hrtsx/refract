const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const TimeoutCtx = S.TimeoutCtx;
const types = @import("types.zig");
const db_mod = @import("../db.zig");
const diagnostics = @import("diagnostics.zig");
const refactor = @import("refactor.zig");

const extractTextDocumentUri = S.extractTextDocumentUri;
const extractParamsObject = S.extractParamsObject;
const extractPosition = S.extractPosition;
const uriToPath = S.uriToPath;
const emptyResult = S.emptyResult;
const writeEscapedJsonContent = S.writeEscapedJsonContent;
const writeCodeActionEdits = S.writeCodeActionEdits;
const writeEscapedJson = S.writeEscapedJson;
const empty_json_array = S.empty_json_array;

pub fn handleFormatting(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
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
    if (!self.pathInBounds(path)) return emptyResult(msg);
    const source = self.readSourceForUri(uri, path) catch
        return emptyResult(msg);
    defer self.alloc.free(source);

    const source_dir = std.fs.path.dirname(path) orelse "/tmp";
    const tmp_base = self.tmp_dir orelse "/tmp";
    if (self.tmp_dir) |d| std.Io.Dir.createDirAbsolute(std.Options.debug_io, d, .default_dir) catch {}; // best-effort
    const actual_tmp = try std.fmt.allocPrint(self.alloc, "{s}/fmt-{d}.rb", .{ tmp_base, self.fmt_counter });
    self.fmt_counter +%= 1;
    defer {
        std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, actual_tmp) catch {}; // cleanup — ignore error
        self.alloc.free(actual_tmp);
    }
    std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = actual_tmp, .data = source }) catch return emptyResult(msg);

    diagnostics.probeRubocopBundle(
        self,
    );
    const fmt_argv: []const []const u8 = if (self.rubocop_use_bundle.load(.monotonic))
        &.{ "bundle", "exec", "rubocop", "--autocorrect-all", "--no-color", "-f", "quiet", actual_tmp }
    else
        &.{ "rubocop", "--autocorrect-all", "--no-color", "-f", "quiet", actual_tmp };
    var child = std.process.spawn(self.io, .{
        .argv = fmt_argv,
        .cwd = .{ .path = self.root_path orelse source_dir },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {
        if (!self.rubocop_checked.load(.monotonic)) {
            self.rubocop_checked.store(true, .monotonic);
            self.rubocop_available.store(false, .monotonic);
            self.sendShowMessage(2, "refract: formatting requires rubocop in PATH");
        }
        const empty = try self.alloc.dupe(u8, empty_json_array);
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = empty, .@"error" = null };
    };
    var tctx_fmt = TimeoutCtx{ .child = &child, .done = std.atomic.Value(bool).init(false), .timeout_ns = self.rubocop_timeout_ms.load(.monotonic) * std.time.ns_per_ms };
    const tkill_fmt = std.Thread.spawn(.{}, TimeoutCtx.run, .{&tctx_fmt}) catch null;
    if (child.wait(std.Options.debug_io)) |term| {
        tctx_fmt.done.store(true, .release);
        if (tkill_fmt) |t| t.join();
        switch (term) {
            .exited => |code| if (code >= 2) self.sendLogMessage(2, "refract: rubocop failed (check rubocop config)"),
            else => {},
        }
    } else |_| {
        tctx_fmt.done.store(true, .release);
        if (tkill_fmt) |t| t.join();
    }

    const formatted = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, actual_tmp, self.alloc, std.Io.Limit.limited(self.max_file_size.load(.monotonic))) catch {
        const empty = try self.alloc.dupe(u8, empty_json_array);
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = empty, .@"error" = null };
    };
    defer self.alloc.free(formatted);

    if (std.mem.eql(u8, source, formatted)) {
        const empty = try self.alloc.dupe(u8, empty_json_array);
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = empty, .@"error" = null };
    }

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    const actual_lines_fmt: i64 = @intCast(std.mem.count(u8, source, "\n") + 1);
    try w.print("[{{\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}},\"newText\":", .{actual_lines_fmt});
    try writeEscapedJson(w, formatted);
    try w.writeAll("}]");
    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn handleCodeAction(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    if (self.isCancelled(msg.id)) return self.cancelledResponse(msg.id);
    self.db_mutex.lockUncancelable(std.Options.debug_io);
    defer self.db_mutex.unlock(std.Options.debug_io);
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

    // Extract range for refactoring support
    var action_line: u32 = 0;
    var action_char: u32 = 0;
    var end_line: u32 = 0;
    var end_char: u32 = 0;
    if (obj.get("range")) |range_val| {
        const range_obj = switch (range_val) {
            .object => |o| o,
            else => null,
        };
        if (range_obj) |ro| {
            if (ro.get("start")) |sv| {
                const so = switch (sv) {
                    .object => |o| o,
                    else => null,
                };
                if (so) |s| {
                    if (s.get("line")) |l| {
                        action_line = switch (l) {
                            .integer => |i| @intCast(i),
                            else => 0,
                        };
                    }
                    if (s.get("character")) |c| {
                        action_char = switch (c) {
                            .integer => |i| @intCast(i),
                            else => 0,
                        };
                    }
                }
            }
            if (ro.get("end")) |ev| {
                const eo = switch (ev) {
                    .object => |o| o,
                    else => null,
                };
                if (eo) |e| {
                    if (e.get("line")) |l| {
                        end_line = switch (l) {
                            .integer => |i| @intCast(i),
                            else => 0,
                        };
                    }
                    if (e.get("character")) |c| {
                        end_char = switch (c) {
                            .integer => |i| @intCast(i),
                            else => 0,
                        };
                    }
                }
            }
        }
    }

    var has_rubocop = false;
    if (obj.get("context")) |ctx_val| {
        const ctx_obj = switch (ctx_val) {
            .object => |o| o,
            else => null,
        };
        if (ctx_obj) |co| {
            if (co.get("diagnostics")) |diags_val| {
                const diags_arr = switch (diags_val) {
                    .array => |a| a,
                    else => null,
                };
                if (diags_arr) |da| {
                    for (da.items) |diag| {
                        const d = switch (diag) {
                            .object => |o| o,
                            else => continue,
                        };
                        const src = d.get("source") orelse continue;
                        const src_str = switch (src) {
                            .string => |s| s,
                            else => continue,
                        };
                        if (std.mem.indexOf(u8, src_str, "RuboCop") != null) {
                            has_rubocop = true;
                            break;
                        }
                    }
                }
            }
        }
    }

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);
    if (!self.pathInBounds(path)) return emptyResult(msg);
    const source = self.readSourceForUri(uri, path) catch return emptyResult(msg);
    defer self.alloc.free(source);

    var aw_ca = std.Io.Writer.Allocating.init(self.alloc);
    const wa = &aw_ca.writer;
    try wa.writeByte('[');
    var action_count: usize = 0;

    // Refactoring actions based on cursor/selection context
    {
        const kinds = refactor.availableRefactors(source, action_line, action_char, end_line, end_char);
        for (kinds) |kind| {
            switch (kind) {
                .extract_method => {
                    var result = refactor.extractMethod(self.alloc, source, action_line, end_line, "extracted_method") catch continue;
                    defer result.deinit();
                    if (result.edits.len == 0) continue;
                    if (action_count > 0) try wa.writeByte(',');
                    action_count += 1;
                    try writeCodeActionEdits(wa, "Extract method", "refactor.extract", uri, result.edits);
                },
                .extract_variable => {
                    var result = refactor.extractVariable(self.alloc, source, action_line, action_char, end_line, end_char, "extracted_var") catch continue;
                    defer result.deinit();
                    if (result.edits.len == 0) continue;
                    if (action_count > 0) try wa.writeByte(',');
                    action_count += 1;
                    try writeCodeActionEdits(wa, "Extract variable", "refactor.extract", uri, result.edits);
                },
                .extract_constant => {
                    var result = refactor.extractConstant(self.alloc, source, action_line, action_char, end_line, end_char, "EXTRACTED_CONST") catch continue;
                    defer result.deinit();
                    if (result.edits.len == 0) continue;
                    if (action_count > 0) try wa.writeByte(',');
                    action_count += 1;
                    try writeCodeActionEdits(wa, "Extract constant", "refactor.extract", uri, result.edits);
                },
                .inline_variable => {
                    var result = refactor.inlineVariable(self.alloc, source, action_line, action_char) catch continue;
                    defer result.deinit();
                    if (result.edits.len == 0) continue;
                    if (action_count > 0) try wa.writeByte(',');
                    action_count += 1;
                    try writeCodeActionEdits(wa, "Inline variable", "refactor.inline", uri, result.edits);
                },
                .convert_string_style => {
                    const cursor_off = self.clientPosToOffset(source, action_line, action_char);
                    if (cursor_off < source.len) {
                        const ch = source[cursor_off];
                        if (ch == '\'') {
                            var result = refactor.convertStringStyle(self.alloc, source, action_line, action_char, .single_to_double) catch continue;
                            defer result.deinit();
                            if (result.edits.len > 0) {
                                if (action_count > 0) try wa.writeByte(',');
                                action_count += 1;
                                try writeCodeActionEdits(wa, "Convert to double quotes", "refactor.rewrite", uri, result.edits);
                            }
                        } else if (ch == '"') {
                            {
                                var result = refactor.convertStringStyle(self.alloc, source, action_line, action_char, .double_to_single) catch continue;
                                defer result.deinit();
                                if (result.edits.len > 0) {
                                    if (action_count > 0) try wa.writeByte(',');
                                    action_count += 1;
                                    try writeCodeActionEdits(wa, "Convert to single quotes", "refactor.rewrite", uri, result.edits);
                                }
                            }
                            {
                                var result = refactor.convertStringStyle(self.alloc, source, action_line, action_char, .string_to_symbol) catch continue;
                                defer result.deinit();
                                if (result.edits.len > 0) {
                                    if (action_count > 0) try wa.writeByte(',');
                                    action_count += 1;
                                    try writeCodeActionEdits(wa, "Convert to symbol", "refactor.rewrite", uri, result.edits);
                                }
                            }
                        }
                    }
                },
            }
        }
    }

    // RuboCop quickfix
    if (has_rubocop) rubocop_blk: {
        const source_dir_ca = std.fs.path.dirname(path) orelse "/tmp";
        const tmp_base_ca = self.tmp_dir orelse "/tmp";
        if (self.tmp_dir) |d| std.Io.Dir.createDirAbsolute(std.Options.debug_io, d, .default_dir) catch {}; // best-effort
        const actual_tmp_ca = std.fmt.allocPrint(self.alloc, "{s}/ca-{d}.rb", .{ tmp_base_ca, self.fmt_counter }) catch break :rubocop_blk;
        self.fmt_counter +%= 1;
        defer {
            std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, actual_tmp_ca) catch {}; // cleanup
            self.alloc.free(actual_tmp_ca);
        }
        std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = actual_tmp_ca, .data = source }) catch break :rubocop_blk;

        var child_ca = std.process.spawn(self.io, .{
            .argv = &.{ "rubocop", "--autocorrect-all", "--no-color", "-f", "quiet", actual_tmp_ca },
            .cwd = .{ .path = self.root_path orelse source_dir_ca },
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch {
            if (!self.rubocop_checked.load(.monotonic)) {
                self.rubocop_checked.store(true, .monotonic);
                self.rubocop_available.store(false, .monotonic);
                self.sendShowMessage(2, "refract: formatting requires rubocop in PATH");
            }
            break :rubocop_blk;
        };
        var tctx_ca = TimeoutCtx{ .child = &child_ca, .done = std.atomic.Value(bool).init(false), .timeout_ns = self.rubocop_timeout_ms.load(.monotonic) * std.time.ns_per_ms };
        const tkill_ca = std.Thread.spawn(.{}, TimeoutCtx.run, .{&tctx_ca}) catch null;
        if (child_ca.wait(std.Options.debug_io)) |term| {
            tctx_ca.done.store(true, .release);
            if (tkill_ca) |t| t.join();
            switch (term) {
                .exited => |code| if (code >= 2) self.sendLogMessage(2, "refract: rubocop failed (check rubocop config)"),
                else => {},
            }
        } else |_| {
            tctx_ca.done.store(true, .release);
            if (tkill_ca) |t| t.join();
        }

        const formatted = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, actual_tmp_ca, self.alloc, std.Io.Limit.limited(self.max_file_size.load(.monotonic))) catch break :rubocop_blk;
        defer self.alloc.free(formatted);
        if (std.mem.eql(u8, source, formatted)) break :rubocop_blk;

        if (action_count > 0) try wa.writeByte(',');
        action_count += 1;
        const actual_lines_ca: i64 = @intCast(std.mem.count(u8, source, "\n") + 1);
        try wa.writeAll("{\"title\":\"Fix with RuboCop\",\"kind\":\"quickfix\",\"isPreferred\":true,\"diagnostics\":[],\"edit\":{\"changes\":{");
        try writeEscapedJson(wa, uri);
        try wa.print(":[{{\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}},\"newText\":", .{actual_lines_ca});
        try writeEscapedJson(wa, formatted);
        try wa.writeAll("}]}}}");
    }

    try wa.writeByte(']');
    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw_ca.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn handleRangeFormatting(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
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
    const range_val = obj.get("range") orelse return emptyResult(msg);
    const range = switch (range_val) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const start_obj = switch (range.get("start") orelse return emptyResult(msg)) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const end_obj = switch (range.get("end") orelse return emptyResult(msg)) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const start_line: i64 = switch (start_obj.get("line") orelse return emptyResult(msg)) {
        .integer => |i| i,
        else => return emptyResult(msg),
    };
    const end_line: i64 = switch (end_obj.get("line") orelse return emptyResult(msg)) {
        .integer => |i| i,
        else => return emptyResult(msg),
    };

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);
    if (!self.pathInBounds(path)) return emptyResult(msg);
    const source = self.readSourceForUri(uri, path) catch return emptyResult(msg);
    defer self.alloc.free(source);

    const source_dir_rf = std.fs.path.dirname(path) orelse "/tmp";
    const tmp_base_rf = self.tmp_dir orelse "/tmp";
    if (self.tmp_dir) |d| std.Io.Dir.createDirAbsolute(std.Options.debug_io, d, .default_dir) catch {}; // best-effort
    const actual_tmp_rf = try std.fmt.allocPrint(self.alloc, "{s}/rfmt-{d}.rb", .{ tmp_base_rf, self.fmt_counter });
    self.fmt_counter +%= 1;
    defer {
        std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, actual_tmp_rf) catch {}; // cleanup — ignore error
        self.alloc.free(actual_tmp_rf);
    }
    std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = actual_tmp_rf, .data = source }) catch return emptyResult(msg);

    var child = std.process.spawn(self.io, .{
        .argv = &.{ "rubocop", "--autocorrect-all", "--no-color", "-f", "quiet", actual_tmp_rf },
        .cwd = .{ .path = self.root_path orelse source_dir_rf },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {
        if (!self.rubocop_checked.load(.monotonic)) {
            self.rubocop_checked.store(true, .monotonic);
            self.rubocop_available.store(false, .monotonic);
            self.sendShowMessage(2, "refract: formatting requires rubocop in PATH");
        }
        const empty = try self.alloc.dupe(u8, empty_json_array);
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = empty, .@"error" = null };
    };
    var tctx_rf = TimeoutCtx{ .child = &child, .done = std.atomic.Value(bool).init(false), .timeout_ns = self.rubocop_timeout_ms.load(.monotonic) * std.time.ns_per_ms };
    const tkill_rf = std.Thread.spawn(.{}, TimeoutCtx.run, .{&tctx_rf}) catch null;
    if (child.wait(std.Options.debug_io)) |term| {
        tctx_rf.done.store(true, .release);
        if (tkill_rf) |t| t.join();
        switch (term) {
            .exited => |code| if (code >= 2) self.sendLogMessage(2, "refract: rubocop failed (check rubocop config)"),
            else => {},
        }
    } else |_| {
        tctx_rf.done.store(true, .release);
        if (tkill_rf) |t| t.join();
    }

    const formatted = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, actual_tmp_rf, self.alloc, std.Io.Limit.limited(self.max_file_size.load(.monotonic))) catch {
        const empty = try self.alloc.dupe(u8, empty_json_array);
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = empty, .@"error" = null };
    };
    defer self.alloc.free(formatted);

    if (std.mem.eql(u8, source, formatted)) {
        const empty = try self.alloc.dupe(u8, empty_json_array);
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = empty, .@"error" = null };
    }

    // Build line-range edit covering [start_line, 0] to [end_line+1, 0]
    // Extract just the formatted lines for the requested range
    var lines_buf = std.ArrayList(u8).empty;
    defer lines_buf.deinit(self.alloc);
    var line_iter = std.mem.splitScalar(u8, formatted, '\n');
    var cur_line: i64 = 0;
    while (line_iter.next()) |line| {
        if (cur_line >= start_line and cur_line <= end_line) {
            try lines_buf.appendSlice(self.alloc, line);
            try lines_buf.append(self.alloc, '\n');
        }
        cur_line += 1;
    }

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.print("[{{\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}},\"newText\":", .{ start_line, end_line + 1 });
    try writeEscapedJson(w, lines_buf.items);
    try w.writeAll("}]");
    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}

const RunTestCtx = struct {
    server: *Server,
    file_path: []const u8,
    line_num: ?u32,

    fn run(ctx: *RunTestCtx) void {
        defer {
            std.heap.c_allocator.free(ctx.file_path);
            std.heap.c_allocator.destroy(ctx);
        }
        var cmd_buf: [2048]u8 = undefined;
        const cmd_str = if (ctx.line_num) |ln|
            std.fmt.bufPrint(&cmd_buf, "bundle exec rspec {s}:{d} 2>&1", .{ ctx.file_path, ln }) catch return
        else
            std.fmt.bufPrint(&cmd_buf, "bundle exec rspec {s} 2>&1", .{ctx.file_path}) catch return;

        // Announce what we're running
        var hdr_buf: [2200]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf, "refract: running {s}", .{cmd_str}) catch "refract: running tests";
        ctx.server.sendLogMessage(3, hdr);

        // Spawn the test subprocess; use sh -c so shell builtins and PATH work
        // stderr is already merged into stdout via "2>&1" in cmd_str (sh -c)
        var child = std.process.spawn(ctx.server.io, .{
            .argv = &.{ "sh", "-c", cmd_str },
            .cwd = if (ctx.server.root_path) |rp| .{ .path = rp } else .{ .path = "." },
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch {
            ctx.server.sendShowMessage(2, "refract: failed to spawn rspec — ensure bundle exec rspec is available");
            return;
        };
        // Stream stdout lines as window/logMessage (level 4 = log)
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = child.stdout.?.readStreaming(ctx.server.io, &.{read_buf[0..]}) catch break;
            if (n == 0) break;
            const chunk = std.mem.trimEnd(u8, read_buf[0..n], "\r\n");
            if (chunk.len > 0) ctx.server.sendLogMessage(4, chunk);
        }

        const term = child.wait(ctx.server.io) catch {
            ctx.server.sendShowMessage(2, "refract: rspec process wait failed");
            return;
        };
        const exit_code: u8 = if (term == .exited) term.exited else 1;
        if (exit_code == 0) {
            ctx.server.sendShowMessage(3, "refract: tests passed");
        } else {
            var fail_buf: [64]u8 = undefined;
            const fail_msg = std.fmt.bufPrint(&fail_buf, "refract: tests failed (exit {d})", .{exit_code}) catch "refract: tests failed";
            ctx.server.sendShowMessage(2, fail_msg);
        }
    }
};

pub fn handleExecuteCommand(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    const params = msg.params orelse return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try self.alloc.dupe(u8, "null"), .@"error" = null };
    const obj = switch (params) {
        .object => |o| o,
        else => return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try self.alloc.dupe(u8, "null"), .@"error" = null },
    };
    const cmd_val = obj.get("command") orelse return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try self.alloc.dupe(u8, "null"), .@"error" = null };
    const cmd = switch (cmd_val) {
        .string => |s| s,
        else => return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try self.alloc.dupe(u8, "null"), .@"error" = null },
    };
    var known_cmd = false;
    if (std.mem.eql(u8, cmd, "refract.recheckRubocop")) {
        known_cmd = true;
        self.rubocop_checked.store(false, .monotonic);
        self.rubocop_available.store(true, .monotonic);
        self.rubocop_bundle_probed.store(false, .monotonic);
        self.rubocop_use_bundle.store(false, .monotonic);
        self.sendShowMessage(3, "Refract: re-checking rubocop availability...");
        diagnostics.enqueueAllOpenDocs(
            self,
        );
    }
    if (std.mem.eql(u8, cmd, "refract.restartIndexer") or
        std.mem.eql(u8, cmd, "refract.forceReindex") or
        std.mem.eql(u8, cmd, "refract.toggleGemIndex"))
    {
        known_cmd = true;
        if (std.mem.eql(u8, cmd, "refract.forceReindex")) {
            self.db_mutex.lockUncancelable(std.Options.debug_io);
            self.db.exec("DELETE FROM symbols WHERE file_id IN (SELECT id FROM files WHERE is_gem=0)") catch {
                self.sendLogMessage(2, "refract: failed to clear symbols for reindex");
            };
            self.db.exec("DELETE FROM files WHERE is_gem=0") catch {
                self.sendLogMessage(2, "refract: failed to clear files for reindex");
            };
            self.db_mutex.unlock(std.Options.debug_io);
        } else if (std.mem.eql(u8, cmd, "refract.toggleGemIndex")) {
            self.disable_gem_index.store(!self.disable_gem_index.load(.monotonic), .monotonic);
        }
        self.startBgIndexer();
        const msg_str = if (std.mem.eql(u8, cmd, "refract.forceReindex"))
            "Refract: force reindexing workspace..."
        else if (std.mem.eql(u8, cmd, "refract.toggleGemIndex"))
            "Refract: gem index toggled, reindexing..."
        else
            "Refract: reindexing workspace...";
        self.sendShowMessage(3, msg_str);
    }
    if (std.mem.eql(u8, cmd, "refract.showReferences")) {
        known_cmd = true;
    } else if (std.mem.eql(u8, cmd, "refract.runTest")) {
        known_cmd = true;
        if (obj.get("arguments")) |args_val| switch (args_val) {
            .array => |arr| if (arr.items.len >= 1) {
                const file_uri = switch (arr.items[0]) {
                    .string => |s| s,
                    else => "",
                };
                const line_num: ?u32 = if (arr.items.len >= 2) switch (arr.items[1]) {
                    .integer => |i| if (i > 0) @intCast(i) else null,
                    else => null,
                } else null;
                const path2 = uriToPath(std.heap.c_allocator, file_uri) catch null;
                if (path2) |p| spawn: {
                    const rctx = std.heap.c_allocator.create(RunTestCtx) catch {
                        std.heap.c_allocator.free(p);
                        break :spawn;
                    };
                    rctx.* = .{ .server = self, .file_path = p, .line_num = line_num };
                    _ = std.Thread.spawn(.{}, RunTestCtx.run, .{rctx}) catch {
                        std.heap.c_allocator.destroy(rctx);
                        std.heap.c_allocator.free(p);
                        break :spawn;
                    };
                }
            },
            else => {},
        };
    }
    if (!known_cmd) return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = null,
        .@"error" = .{ .code = @intFromEnum(types.ErrorCode.method_not_found), .message = "Unknown command" },
    };
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try self.alloc.dupe(u8, "null"), .@"error" = null };
}
