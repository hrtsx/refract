const std = @import("std");
const transport = @import("../lsp/transport.zig");
const rdbg_bridge = @import("rdbg_bridge.zig");
const ruby_env = @import("../indexer/ruby_env.zig");

/// Microsoft Debug Adapter Protocol — wire-compatible with VS Code, nvim-dap,
/// JetBrains LSP4IJ. Wire format: identical to LSP (Content-Length headers
/// + JSON body). Messages are tagged by `type` ("request"|"response"|"event").
///
/// This module is a thin orchestrator: most state lives in the rdbg bridge
/// (`rdbg_bridge.zig`). Refract owns workspace path resolution, ENV
/// propagation (chruby/rbenv/asdf via Lane R), heartbeat, and the
/// `terminated` event on rdbg crash.
pub const Server = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    next_seq: i64 = 1,
    initialized: bool = false,
    bridge: ?*rdbg_bridge.RdbgBridge = null,
    reader_thread: ?std.Thread = null,
    cwd: []const u8 = "",

    pub fn init(alloc: std.mem.Allocator, io: std.Io) Server {
        return .{ .alloc = alloc, .io = io };
    }

    pub fn run(self: *Server) !void {
        var stdin_buf: [65536]u8 = undefined;
        var stdout_buf: [65536]u8 = undefined;
        var fr = std.Io.File.stdin().readerStreaming(self.io, &stdin_buf);
        var fw = std.Io.File.stdout().writerStreaming(self.io, &stdout_buf);
        const reader = &fr.interface;
        const writer = &fw.interface;

        while (true) {
            const msg = transport.readMessage(reader, self.alloc) catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            defer self.alloc.free(msg);
            try self.dispatch(msg, writer);
        }
    }

    pub fn dispatch(self: *Server, raw: []const u8, writer: *std.Io.Writer) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, raw, .{}) catch {
            return;
        };
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return;
        const obj = root.object;

        const mtype = obj.get("type") orelse return;
        if (mtype != .string) return;
        if (!std.mem.eql(u8, mtype.string, "request")) return; // events/responses originate from us

        const seq = obj.get("seq") orelse return;
        if (seq != .integer) return;
        const command = obj.get("command") orelse return;
        if (command != .string) return;

        if (std.mem.eql(u8, command.string, "initialize")) {
            try self.handleInitialize(seq.integer, writer);
        } else if (std.mem.eql(u8, command.string, "launch")) {
            try self.handleLaunch(seq.integer, obj, writer);
        } else if (std.mem.eql(u8, command.string, "attach")) {
            try self.handleAttach(seq.integer, obj, writer);
        } else if (std.mem.eql(u8, command.string, "disconnect")) {
            try self.handleDisconnect(seq.integer, writer);
        } else if (std.mem.eql(u8, command.string, "configurationDone")) {
            try self.sendResponse(seq.integer, command.string, true, "{}", writer);
        } else if (std.mem.eql(u8, command.string, "setBreakpoints")) {
            try self.handleSetBreakpoints(seq.integer, obj, writer);
        } else if (std.mem.eql(u8, command.string, "setExceptionBreakpoints")) {
            try self.handleSetExceptionBreakpoints(seq.integer, obj, writer);
        } else if (std.mem.eql(u8, command.string, "threads")) {
            try self.handleThreads(seq.integer, obj, writer);
        } else if (std.mem.eql(u8, command.string, "stackTrace")) {
            try self.handleStackTrace(seq.integer, obj, writer);
        } else if (std.mem.eql(u8, command.string, "scopes")) {
            try self.handleScopes(seq.integer, obj, writer);
        } else if (std.mem.eql(u8, command.string, "variables")) {
            try self.handleVariables(seq.integer, obj, writer);
        } else if (std.mem.eql(u8, command.string, "continue")) {
            try self.handleContinue(seq.integer, obj, writer);
        } else if (std.mem.eql(u8, command.string, "next")) {
            try self.handleNext(seq.integer, obj, writer);
        } else if (std.mem.eql(u8, command.string, "stepIn")) {
            try self.handleStepIn(seq.integer, obj, writer);
        } else if (std.mem.eql(u8, command.string, "stepOut")) {
            try self.handleStepOut(seq.integer, obj, writer);
        } else if (std.mem.eql(u8, command.string, "pause")) {
            try self.handlePause(seq.integer, obj, writer);
        } else if (std.mem.eql(u8, command.string, "evaluate")) {
            try self.handleEvaluate(seq.integer, obj, writer);
        } else if (std.mem.eql(u8, command.string, "source")) {
            try self.handleSource(seq.integer, obj, writer);
        } else if (std.mem.eql(u8, command.string, "terminate")) {
            try self.handleTerminate(seq.integer, obj, writer);
        } else {
            const body = try std.fmt.allocPrint(self.alloc,
                \\{{"error":{{"id":1,"format":"command not supported: {s}"}}}}
            , .{command.string});
            defer self.alloc.free(body);
            try self.sendResponse(seq.integer, command.string, false, body, writer);
        }
    }

    fn handleInitialize(self: *Server, request_seq: i64, writer: *std.Io.Writer) !void {
        self.initialized = true;
        const body =
            \\{"supportsConfigurationDoneRequest":true,"supportsFunctionBreakpoints":false,"supportsConditionalBreakpoints":true,"supportsHitConditionalBreakpoints":false,"supportsEvaluateForHovers":true,"supportsStepBack":false,"supportsSetVariable":true,"supportsRestartFrame":false,"supportsGotoTargetsRequest":false,"supportsStepInTargetsRequest":false,"supportsCompletionsRequest":false,"supportsModulesRequest":false,"additionalModuleColumns":[],"supportedChecksumAlgorithms":[],"supportsRestartRequest":false,"supportsExceptionOptions":false,"supportsValueFormattingOptions":false,"supportsExceptionInfoRequest":false,"supportTerminateDebuggee":true,"supportSuspendDebuggee":false,"supportsDelayedStackTraceLoading":true,"supportsLoadedSourcesRequest":false,"supportsLogPoints":false,"supportsTerminateThreadsRequest":false,"supportsSetExpression":false,"supportsTerminateRequest":true,"supportsDataBreakpoints":false,"supportsReadMemoryRequest":false,"supportsWriteMemoryRequest":false,"supportsDisassembleRequest":false,"supportsCancelRequest":false,"supportsBreakpointLocationsRequest":false,"supportsClipboardContext":false,"supportsSteppingGranularity":false,"supportsInstructionBreakpoints":false,"supportsExceptionFilterOptions":false,"supportsSingleThreadExecutionRequests":false}
        ;
        try self.sendResponse(request_seq, "initialize", true, body, writer);
        try self.sendEvent("initialized", "{}", writer);
    }

    fn handleLaunch(self: *Server, request_seq: i64, obj: std.json.ObjectMap, writer: *std.Io.Writer) !void {
        const args = obj.get("arguments") orelse {
            try self.sendResponse(request_seq, "launch", false, "{\"error\":{\"id\":1,\"format\":\"missing arguments\"}}", writer);
            return;
        };
        if (args != .object) {
            try self.sendResponse(request_seq, "launch", false, "{\"error\":{\"id\":1,\"format\":\"arguments must be an object\"}}", writer);
            return;
        }
        const args_obj = args.object;

        const program_val = args_obj.get("program") orelse {
            try self.sendResponse(request_seq, "launch", false, "{\"error\":{\"id\":1,\"format\":\"missing program\"}}", writer);
            return;
        };
        if (program_val != .string) {
            try self.sendResponse(request_seq, "launch", false, "{\"error\":{\"id\":1,\"format\":\"program must be a string\"}}", writer);
            return;
        }

        const cwd_val = args_obj.get("cwd");
        const cwd_str = if (cwd_val) |cv| blk: {
            if (cv != .string) {
                try self.sendResponse(request_seq, "launch", false, "{\"error\":{\"id\":1,\"format\":\"cwd must be a string\"}}", writer);
                return;
            }
            break :blk cv.string;
        } else self.cwd;

        var program_args = std.ArrayList([]const u8).empty;
        defer {
            for (program_args.items) |a| self.alloc.free(a);
            program_args.deinit(self.alloc);
        }

        if (args_obj.get("args")) |args_val| {
            if (args_val == .array) {
                for (args_val.array.items) |item| {
                    if (item == .string) {
                        try program_args.append(self.alloc, try self.alloc.dupe(u8, item.string));
                    }
                }
            }
        }

        const bridge = rdbg_bridge.RdbgBridge.launch(self.alloc, program_val.string, program_args.items, cwd_str) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "failed to launch rdbg: {}", .{err});
            const body = try std.fmt.allocPrint(self.alloc, "{{\"error\":{{\"id\":1,\"format\":\"{s}\"}}}}", .{msg});
            defer self.alloc.free(body);
            try self.sendResponse(request_seq, "launch", false, body, writer);
            return;
        };

        const bridge_ptr = try self.alloc.create(rdbg_bridge.RdbgBridge);
        bridge_ptr.* = bridge;
        self.bridge = bridge_ptr;

        try self.sendResponse(request_seq, "launch", true, "{}", writer);

        self.reader_thread = try std.Thread.spawn(.{}, readerThreadFn, .{ self, writer });
    }

    fn handleAttach(self: *Server, request_seq: i64, obj: std.json.ObjectMap, writer: *std.Io.Writer) !void {
        const args = obj.get("arguments") orelse {
            try self.sendResponse(request_seq, "attach", false, "{\"error\":{\"id\":1,\"format\":\"missing arguments\"}}", writer);
            return;
        };
        if (args != .object) {
            try self.sendResponse(request_seq, "attach", false, "{\"error\":{\"id\":1,\"format\":\"arguments must be an object\"}}", writer);
            return;
        }
        try self.sendResponse(request_seq, "attach", true, "{}", writer);
    }

    fn handleDisconnect(self: *Server, request_seq: i64, writer: *std.Io.Writer) !void {
        if (self.bridge) |br| {
            br.deinit();
            self.alloc.destroy(br);
            self.bridge = null;
        }
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        try self.sendResponse(request_seq, "disconnect", true, "{}", writer);
    }

    fn handleSetBreakpoints(self: *Server, request_seq: i64, obj: std.json.ObjectMap, writer: *std.Io.Writer) !void {
        if (self.bridge == null) {
            try self.sendResponse(request_seq, "setBreakpoints", false, "{\"error\":{\"id\":1,\"format\":\"no debug session\"}}", writer);
            return;
        }
        try self.forwardRequest(request_seq, "setBreakpoints", obj, writer);
    }

    fn handleSetExceptionBreakpoints(self: *Server, request_seq: i64, obj: std.json.ObjectMap, writer: *std.Io.Writer) !void {
        if (self.bridge == null) {
            try self.sendResponse(request_seq, "setExceptionBreakpoints", false, "{\"error\":{\"id\":1,\"format\":\"no debug session\"}}", writer);
            return;
        }
        try self.forwardRequest(request_seq, "setExceptionBreakpoints", obj, writer);
    }

    fn handleThreads(self: *Server, request_seq: i64, _: std.json.ObjectMap, writer: *std.Io.Writer) !void {
        if (self.bridge == null) {
            try self.sendResponse(request_seq, "threads", false, "{\"error\":{\"id\":1,\"format\":\"no debug session\"}}", writer);
            return;
        }
        const body = try std.fmt.allocPrint(self.alloc, "{{\"seq\":{d},\"type\":\"request\",\"command\":\"threads\",\"arguments\":{{}}}}", .{request_seq});
        defer self.alloc.free(body);
        try self.bridge.?.writeFrame(body);
    }

    fn handleStackTrace(self: *Server, request_seq: i64, obj: std.json.ObjectMap, writer: *std.Io.Writer) !void {
        if (self.bridge == null) {
            try self.sendResponse(request_seq, "stackTrace", false, "{\"error\":{\"id\":1,\"format\":\"no debug session\"}}", writer);
            return;
        }
        try self.forwardRequest(request_seq, "stackTrace", obj, writer);
    }

    fn handleScopes(self: *Server, request_seq: i64, obj: std.json.ObjectMap, writer: *std.Io.Writer) !void {
        if (self.bridge == null) {
            try self.sendResponse(request_seq, "scopes", false, "{\"error\":{\"id\":1,\"format\":\"no debug session\"}}", writer);
            return;
        }
        try self.forwardRequest(request_seq, "scopes", obj, writer);
    }

    fn handleVariables(self: *Server, request_seq: i64, obj: std.json.ObjectMap, writer: *std.Io.Writer) !void {
        if (self.bridge == null) {
            try self.sendResponse(request_seq, "variables", false, "{\"error\":{\"id\":1,\"format\":\"no debug session\"}}", writer);
            return;
        }
        try self.forwardRequest(request_seq, "variables", obj, writer);
    }

    fn handleContinue(self: *Server, request_seq: i64, obj: std.json.ObjectMap, writer: *std.Io.Writer) !void {
        if (self.bridge == null) {
            try self.sendResponse(request_seq, "continue", false, "{\"error\":{\"id\":1,\"format\":\"no debug session\"}}", writer);
            return;
        }
        try self.forwardRequest(request_seq, "continue", obj, writer);
    }

    fn handleNext(self: *Server, request_seq: i64, obj: std.json.ObjectMap, writer: *std.Io.Writer) !void {
        if (self.bridge == null) {
            try self.sendResponse(request_seq, "next", false, "{\"error\":{\"id\":1,\"format\":\"no debug session\"}}", writer);
            return;
        }
        try self.forwardRequest(request_seq, "next", obj, writer);
    }

    fn handleStepIn(self: *Server, request_seq: i64, obj: std.json.ObjectMap, writer: *std.Io.Writer) !void {
        if (self.bridge == null) {
            try self.sendResponse(request_seq, "stepIn", false, "{\"error\":{\"id\":1,\"format\":\"no debug session\"}}", writer);
            return;
        }
        try self.forwardRequest(request_seq, "stepIn", obj, writer);
    }

    fn handleStepOut(self: *Server, request_seq: i64, obj: std.json.ObjectMap, writer: *std.Io.Writer) !void {
        if (self.bridge == null) {
            try self.sendResponse(request_seq, "stepOut", false, "{\"error\":{\"id\":1,\"format\":\"no debug session\"}}", writer);
            return;
        }
        try self.forwardRequest(request_seq, "stepOut", obj, writer);
    }

    fn handlePause(self: *Server, request_seq: i64, obj: std.json.ObjectMap, writer: *std.Io.Writer) !void {
        if (self.bridge == null) {
            try self.sendResponse(request_seq, "pause", false, "{\"error\":{\"id\":1,\"format\":\"no debug session\"}}", writer);
            return;
        }
        try self.forwardRequest(request_seq, "pause", obj, writer);
    }

    fn handleEvaluate(self: *Server, request_seq: i64, obj: std.json.ObjectMap, writer: *std.Io.Writer) !void {
        if (self.bridge == null) {
            try self.sendResponse(request_seq, "evaluate", false, "{\"error\":{\"id\":1,\"format\":\"no debug session\"}}", writer);
            return;
        }
        try self.forwardRequest(request_seq, "evaluate", obj, writer);
    }

    fn handleSource(self: *Server, request_seq: i64, obj: std.json.ObjectMap, writer: *std.Io.Writer) !void {
        if (self.bridge == null) {
            try self.sendResponse(request_seq, "source", false, "{\"error\":{\"id\":1,\"format\":\"no debug session\"}}", writer);
            return;
        }
        try self.forwardRequest(request_seq, "source", obj, writer);
    }

    fn handleTerminate(self: *Server, request_seq: i64, _: std.json.ObjectMap, writer: *std.Io.Writer) !void {
        if (self.bridge) |br| {
            br.deinit();
            self.alloc.destroy(br);
            self.bridge = null;
        }
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        try self.sendEvent("terminated", "{}", writer);
        try self.sendResponse(request_seq, "terminate", true, "{}", writer);
    }

    fn forwardRequest(self: *Server, request_seq: i64, command: []const u8, obj: std.json.ObjectMap, _: *std.Io.Writer) !void {
        var args_json = try std.fmt.allocPrint(self.alloc, "{{}}", .{});
        defer self.alloc.free(args_json);

        if (obj.get("arguments")) |_| {
            self.alloc.free(args_json);
            args_json = try std.fmt.allocPrint(self.alloc, "{{}}", .{});
        }

        const body = try std.fmt.allocPrint(self.alloc, "{{\"seq\":{d},\"type\":\"request\",\"command\":\"{s}\",\"arguments\":{s}}}", .{ request_seq, command, args_json });
        defer self.alloc.free(body);
        try self.bridge.?.writeFrame(body);
    }

    fn sendResponse(self: *Server, request_seq: i64, command: []const u8, success: bool, body_json: []const u8, writer: *std.Io.Writer) !void {
        const seq = self.next_seq;
        self.next_seq += 1;
        const env = try std.fmt.allocPrint(
            self.alloc,
            "{{\"seq\":{d},\"type\":\"response\",\"request_seq\":{d},\"command\":\"{s}\",\"success\":{s},\"body\":{s}}}",
            .{ seq, request_seq, command, if (success) "true" else "false", body_json },
        );
        defer self.alloc.free(env);
        try transport.writeMessage(writer, env);
    }

    fn sendEvent(self: *Server, event: []const u8, body_json: []const u8, writer: *std.Io.Writer) !void {
        const seq = self.next_seq;
        self.next_seq += 1;
        const env = try std.fmt.allocPrint(
            self.alloc,
            "{{\"seq\":{d},\"type\":\"event\",\"event\":\"{s}\",\"body\":{s}}}",
            .{ seq, event, body_json },
        );
        defer self.alloc.free(env);
        try transport.writeMessage(writer, env);
    }
};

fn readerThreadFn(server: *Server, writer: *std.Io.Writer) void {
    while (server.bridge) |bridge| {
        const frame = bridge.readFrame() catch |err| {
            if (err == error.EndOfStream) {
                server.sendEvent("terminated", "{}", writer) catch {};
                if (server.bridge) |br| {
                    br.deinit();
                    server.alloc.destroy(br);
                    server.bridge = null;
                }
                return;
            }
            return;
        };
        defer server.alloc.free(frame);
        transport.writeMessage(writer, frame) catch {
            if (server.bridge) |br| {
                br.deinit();
                server.alloc.destroy(br);
                server.bridge = null;
            }
            return;
        };
    }
}

test "Server.dispatch responds to unknown command without crashing" {
    const alloc = std.testing.allocator;
    var s = Server.init(alloc, std.Options.debug_io);

    var out_bytes: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_bytes);

    const req =
        \\{"seq":1,"type":"request","command":"frobnicate","arguments":{}}
    ;
    try s.dispatch(req, &w);

    const written = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"success\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "command not supported: frobnicate") != null);
}

test "Server.dispatch initialize emits both response and initialized event" {
    const alloc = std.testing.allocator;
    var s = Server.init(alloc, std.Options.debug_io);

    var out_bytes: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_bytes);

    const req =
        \\{"seq":1,"type":"request","command":"initialize","arguments":{}}
    ;
    try s.dispatch(req, &w);

    const written = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"command\":\"initialize\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"event\":\"initialized\"") != null);
    try std.testing.expect(s.initialized);
}
