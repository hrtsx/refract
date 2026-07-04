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
const editing_ranges = @import("editing_ranges.zig");
const editing_hints = @import("editing_hints.zig");
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
const uriToPath = S.uriToPath;
const init_caps_before_enc = S.init_caps_before_enc;
const init_caps_after_enc = S.init_caps_after_enc;
const MAX_INCR_PATHS = S.MAX_INCR_PATHS;
const empty_json_array = S.empty_json_array;
const rubocopWorkerFn = @import("server_indexing.zig").rubocopWorkerFn;
const flushWorkerFn = @import("server_indexing.zig").flushWorkerFn;
const ReadTxn = S.ReadTxn;
const logOomOnce = S.logOomOnce;
const getMetaInt = S.getMetaInt;
const setMetaInt = S.setMetaInt;
const emitSelRange = S.emitSelRange;
const computeDiagCol = S.computeDiagCol;
const serverLogSinkCb = S.serverLogSinkCb;

pub fn dispatch(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    const t0_ns: i96 = std.Io.Timestamp.now(self.io, .awake).toNanoseconds();
    defer if (self.recorder) |*rec| {
        const t1_ns: i96 = std.Io.Timestamp.now(self.io, .awake).toNanoseconds();
        if (t1_ns > t0_ns) rec.recordRequest(msg.method, @intCast(t1_ns - t0_ns));
    };
    if (std.mem.eql(u8, msg.method, "initialize")) {
        return self.handleInitialize(msg);
    }
    // exit is always honoured regardless of state (LSP 3.17 §3.8)
    if (std.mem.eql(u8, msg.method, "exit")) {
        self.exit_code = if (self.shutdown_requested) 0 else 1;
        return null;
    }
    // After shutdown only exit (above) is valid; reject everything else
    if (self.shutdown_requested) {
        if (msg.id != null) {
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = null, .@"error" = .{ .code = @intFromEnum(types.ErrorCode.invalid_request), .message = "Invalid request: server is shutting down" } };
        }
        return null;
    }
    // Before initialize: reject all requests except shutdown/cancel
    if (!self.initialized and
        !std.mem.eql(u8, msg.method, "initialized") and
        !std.mem.eql(u8, msg.method, "$/cancelRequest") and
        !std.mem.eql(u8, msg.method, "shutdown"))
    {
        if (msg.id != null) {
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = null, .@"error" = .{ .code = @intFromEnum(types.ErrorCode.server_not_initialized), .message = "Server not initialized" } };
        }
        return null;
    }
    // Pluggable registry — opt-in handlers for extension tracks (DAP, code_lens, etc.).
    // Checked before legacy if/else chain so tracks can override or add methods without touching dispatch.
    if (try self.registry.dispatchRequest(@ptrCast(self), msg)) |hit| {
        return hit.response;
    }
    if (std.mem.eql(u8, msg.method, "initialized")) {
        if (self.bg_started) return null;
        self.bg_started = true;
        if (self.db.was_self_healed) {
            self.sendLogMessage(2, "refract: db was rebuilt from a corrupted state on startup; the index is fresh");
            // Custom notification so editors / dashboards can surface a
            // user-visible banner. Distinct from window/showMessage to
            // avoid forcing a modal — clients opt in by listening.
            self.sendNotification(
                \\{"jsonrpc":"2.0","method":"$/refract/recovered","params":{"reason":"db_corruption"}}
            );
        }
        self.startBgIndexer();
        self.recordGitHead();
        if (self.rubocop_thread == null) {
            self.rubocop_thread = std.Thread.spawn(.{}, rubocopWorkerFn, .{self}) catch null;
        }
        if (self.flush_thread == null) {
            self.flush_thread = std.Thread.spawn(.{}, flushWorkerFn, .{self}) catch null;
        }
        self.requestWorkspaceConfiguration();
        return null;
    } else if (std.mem.eql(u8, msg.method, "$/refract/__waitForIdle")) {
        return try document_sync.handleWaitForIdle(self, msg);
    } else if (std.mem.eql(u8, msg.method, "$/cancelRequest")) {
        if (msg.params) |p| {
            const obj = switch (p) {
                .object => |o| o,
                else => return null,
            };
            const id_val = obj.get("id") orelse return null;
            const rid: i64 = switch (id_val) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => return null,
            };
            self.cancel_mutex.lockUncancelable(std.Options.debug_io);
            self.cancelled_ids.put(self.alloc, rid, {}) catch {
                self.sendLogMessage(3, "refract: cancel tracking alloc failed");
            };
            self.cancel_mutex.unlock(std.Options.debug_io);
        }
        return null;
    } else if (std.mem.eql(u8, msg.method, "workspace/symbol")) {
        return try symbols.handleWorkspaceSymbol(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/didOpen")) {
        document_sync.handleDidOpen(self, msg);
        return null;
    } else if (std.mem.eql(u8, msg.method, "textDocument/didClose")) {
        document_sync.handleDidClose(self, msg);
        return null;
    } else if (std.mem.eql(u8, msg.method, "textDocument/didChange")) {
        document_sync.handleDidChange(self, msg);
        return null;
    } else if (std.mem.eql(u8, msg.method, "textDocument/didSave")) {
        document_sync.handleDidSave(self, msg);
        return null;
    } else if (std.mem.eql(u8, msg.method, "workspace/didChangeWatchedFiles")) {
        document_sync.handleDidChangeWatchedFiles(self, msg);
        return null;
    } else if (std.mem.eql(u8, msg.method, "workspace/didChangeConfiguration")) {
        const prev_disable_rubocop = self.disable_rubocop.load(.monotonic);
        if (msg.params) |params| {
            const settings = switch (params) {
                .object => |o| o,
                else => return null,
            };
            const refract_settings = blk: {
                const s = settings.get("settings") orelse break :blk null;
                const so = switch (s) {
                    .object => |o| o,
                    else => break :blk null,
                };
                const r = so.get("refract") orelse break :blk null;
                break :blk switch (r) {
                    .object => |o| o,
                    else => null,
                };
            };
            if (refract_settings) |cfg| {
                if (cfg.get("disableRubocop")) |v| switch (v) {
                    .bool => |b| {
                        self.disable_rubocop.store(b, .monotonic);
                    },
                    else => {},
                };
                if (cfg.get("disableTypeChecker")) |v| switch (v) {
                    .bool => |b| {
                        self.disable_type_checker.store(b, .monotonic);
                    },
                    else => {},
                };
                if (cfg.get("typeCheckerSeverity")) |v| switch (v) {
                    .string => |s| {
                        const sev: u8 = if (std.mem.eql(u8, s, "error")) 1 else if (std.mem.eql(u8, s, "info")) 3 else 2;
                        self.type_checker_severity.store(sev, .monotonic);
                    },
                    else => {},
                };
                if (cfg.get("logLevel")) |v| switch (v) {
                    .integer => |n| {
                        if (n < 1 or n > 4) {
                            self.sendLspLogMessage(2, "refract: logLevel must be 1-4, ignoring invalid value");
                        } else {
                            self.log_level.store(@intCast(n), .monotonic);
                        }
                    },
                    else => {
                        self.sendLspLogMessage(2, "refract: logLevel must be an integer (1-4)");
                    },
                };
                if (cfg.get("disableGemIndex")) |v| switch (v) {
                    .bool => |b| {
                        self.disable_gem_index.store(b, .monotonic);
                    },
                    else => {},
                };
                if (cfg.get("maxWorkers")) |v| switch (v) {
                    .integer => |n| {
                        if (n > 0) self.max_workers = @intCast(@min(n, 64));
                    },
                    else => {},
                };
                if (cfg.get("maxFileSize")) |v| switch (v) {
                    .integer => |n| {
                        if (n > 0) self.max_file_size.store(@intCast(@min(n, 256 * 1024 * 1024)), .monotonic);
                    },
                    else => {},
                };
                if (cfg.get("maxFileSizeMb")) |v| switch (v) {
                    .integer => |n| {
                        if (n > 0) self.max_file_size.store(@intCast(@as(usize, @intCast(@min(n, 256))) * 1024 * 1024), .monotonic);
                    },
                    else => {},
                };
                if (cfg.get("rubocopTimeoutSecs")) |v| switch (v) {
                    .integer => |n| {
                        if (n > 0) self.rubocop_timeout_ms.store(@intCast(@min(n, 300) * 1000), .monotonic);
                    },
                    else => {},
                };
            }
        }
        if (self.disable_rubocop.load(.monotonic) != prev_disable_rubocop) {
            self.rubocop_checked.store(false, .monotonic);
            self.rubocop_available.store(true, .monotonic);
            if (self.disable_rubocop.load(.monotonic)) {
                self.rubocop_queue_mu.lockUncancelable(std.Options.debug_io);
                var rq_it = self.rubocop_pending.keyIterator();
                while (rq_it.next()) |k| self.alloc.free(k.*);
                self.rubocop_pending.clearRetainingCapacity();
                self.rubocop_queue_mu.unlock(std.Options.debug_io);
            } else {
                diagnostics_mod.enqueueAllOpenDocs(self);
            }
        }
        self.requestWorkspaceConfiguration();
        return null;
    } else if (std.mem.eql(u8, msg.method, "workspace/didCreateFiles")) {
        document_sync.handleDidCreateFiles(self, msg);
        return null;
    } else if (std.mem.eql(u8, msg.method, "workspace/didDeleteFiles")) {
        document_sync.handleDidDeleteFiles(self, msg);
        return null;
    } else if (std.mem.eql(u8, msg.method, "workspace/didRenameFiles")) {
        self.db_mutex.lockUncancelable(std.Options.debug_io);
        defer self.db_mutex.unlock(std.Options.debug_io);
        document_sync.handleDidRenameFiles(self, msg);
        return null;
    } else if (std.mem.eql(u8, msg.method, "textDocument/codeAction")) {
        return try code_actions.handleCodeAction(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/definition")) {
        const t0 = std.Io.Timestamp.now(self.io, .real);
        const result = try navigation.handleDefinition(self, msg);
        const t1 = std.Io.Timestamp.now(self.io, .real);
        const ta_ns = t0.toNanoseconds();
        const tb_ns = t1.toNanoseconds();
        const dt_ns: u64 = if (tb_ns > ta_ns) @intCast(tb_ns - ta_ns) else 0;
        if (self.recorder) |*rec| rec.recordRequest("textDocument/definition", dt_ns);
        return result;
    } else if (std.mem.eql(u8, msg.method, "textDocument/implementation")) {
        return try navigation.handleImplementation(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/declaration")) {
        return try navigation.handleDefinition(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/documentSymbol")) {
        return try symbols.handleDocumentSymbol(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/hover")) {
        const t0 = std.Io.Timestamp.now(self.io, .real);
        const result = try hover.handleHover(self, msg);
        const t1 = std.Io.Timestamp.now(self.io, .real);
        const ta_ns = t0.toNanoseconds();
        const tb_ns = t1.toNanoseconds();
        const dt_ns: u64 = if (tb_ns > ta_ns) @intCast(tb_ns - ta_ns) else 0;
        if (self.recorder) |*rec| rec.recordRequest("textDocument/hover", dt_ns);
        return result;
    } else if (std.mem.eql(u8, msg.method, "textDocument/completion")) {
        const t0 = std.Io.Timestamp.now(self.io, .real);
        const result = try completion.handleCompletion(self, msg);
        const t1 = std.Io.Timestamp.now(self.io, .real);
        const ta_ns = t0.toNanoseconds();
        const tb_ns = t1.toNanoseconds();
        const dt_ns: u64 = if (tb_ns > ta_ns) @intCast(tb_ns - ta_ns) else 0;
        if (self.recorder) |*rec| rec.recordRequest("textDocument/completion", dt_ns);
        return result;
    } else if (std.mem.eql(u8, msg.method, "textDocument/inlineCompletion")) {
        return try completion.handleInlineCompletion(self, msg);
    } else if (std.mem.eql(u8, msg.method, "completionItem/resolve")) {
        return try completion.handleCompletionItemResolve(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/references")) {
        const t0 = std.Io.Timestamp.now(self.io, .real);
        const result = try navigation.handleReferences(self, msg);
        const t1 = std.Io.Timestamp.now(self.io, .real);
        const ta_ns = t0.toNanoseconds();
        const tb_ns = t1.toNanoseconds();
        const dt_ns: u64 = if (tb_ns > ta_ns) @intCast(tb_ns - ta_ns) else 0;
        if (self.recorder) |*rec| rec.recordRequest("textDocument/references", dt_ns);
        return result;
    } else if (std.mem.eql(u8, msg.method, "textDocument/signatureHelp")) {
        return try editing_hints.handleSignatureHelp(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/typeDefinition")) {
        return try navigation.handleTypeDefinition(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/inlayHint")) {
        return try editing_hints.handleInlayHint(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/semanticTokens/full")) {
        return try semantic_tokens.handleSemanticTokensFull(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/semanticTokens/range")) {
        return try semantic_tokens.handleSemanticTokensRange(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/documentHighlight")) {
        return try editing_hints.handleDocumentHighlight(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/documentLink")) {
        return try editing_hints.handleDocumentLink(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/prepareRename")) {
        return try rename.handlePrepareRename(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/rename")) {
        const t0 = std.Io.Timestamp.now(self.io, .real);
        const result = try rename.handleRename(self, msg);
        const t1 = std.Io.Timestamp.now(self.io, .real);
        const ta_ns = t0.toNanoseconds();
        const tb_ns = t1.toNanoseconds();
        const dt_ns: u64 = if (tb_ns > ta_ns) @intCast(tb_ns - ta_ns) else 0;
        if (self.recorder) |*rec| rec.recordRequest("textDocument/rename", dt_ns);
        return result;
    } else if (std.mem.eql(u8, msg.method, "textDocument/formatting")) {
        return try code_actions.handleFormatting(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/foldingRange")) {
        return try editing_ranges.handleFoldingRange(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/rangeFormatting")) {
        return try code_actions.handleRangeFormatting(self, msg);
    } else if (std.mem.eql(u8, msg.method, "workspace/executeCommand")) {
        return try code_actions.handleExecuteCommand(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/codeLens")) {
        return try editing_hints.handleCodeLens(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/prepareTypeHierarchy")) {
        return try navigation.handlePrepareTypeHierarchy(self, msg);
    } else if (std.mem.eql(u8, msg.method, "typeHierarchy/supertypes")) {
        return try navigation.handleTypeHierarchySupertypes(self, msg);
    } else if (std.mem.eql(u8, msg.method, "typeHierarchy/subtypes")) {
        return try navigation.handleTypeHierarchySubtypes(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/semanticTokens/full/delta")) {
        return try semantic_tokens.handleSemanticTokensDelta(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/selectionRange")) {
        return try editing_ranges.handleSelectionRange(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/linkedEditingRange")) {
        return try editing_ranges.handleLinkedEditingRange(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/prepareCallHierarchy")) {
        return try navigation.handleCallHierarchyPrepare(self, msg);
    } else if (std.mem.eql(u8, msg.method, "callHierarchy/incomingCalls")) {
        return try navigation.handleCallHierarchyIncomingCalls(self, msg);
    } else if (std.mem.eql(u8, msg.method, "callHierarchy/outgoingCalls")) {
        return try navigation.handleCallHierarchyOutgoingCalls(self, msg);
    } else if (std.mem.eql(u8, msg.method, "textDocument/diagnostic")) {
        return try diagnostics_mod.handlePullDiagnostic(self, msg);
    } else if (std.mem.eql(u8, msg.method, "workspace/willRenameFiles")) {
        return try rename.handleWillRenameFiles(self, msg);
    } else if (std.mem.eql(u8, msg.method, "workspace/willCreateFiles") or
        std.mem.eql(u8, msg.method, "workspace/willDeleteFiles"))
    {
        const raw = try self.alloc.dupe(u8, "null");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = raw, .@"error" = null };
    } else if (std.mem.eql(u8, msg.method, "workspace/didChangeWorkspaceFolders")) {
        if (msg.params) |params| {
            const obj2 = switch (params) {
                .object => |o| o,
                else => return null,
            };
            const event_val = obj2.get("event") orelse return null;
            const ev = switch (event_val) {
                .object => |o| o,
                else => return null,
            };
            if (ev.get("removed")) |removed| switch (removed) {
                .array => |arr| for (arr.items) |item| {
                    const folder = switch (item) {
                        .object => |o| o,
                        else => continue,
                    };
                    const folder_uri = switch (folder.get("uri") orelse continue) {
                        .string => |s| s,
                        else => continue,
                    };
                    const folder_path = uriToPath(self.alloc, folder_uri) catch continue;
                    defer self.alloc.free(folder_path);
                    self.db_mutex.lockUncancelable(std.Options.debug_io);
                    const del_stmt = self.db.prepare("DELETE FROM files WHERE path LIKE ? ESCAPE '\\'") catch {
                        self.db_mutex.unlock(std.Options.debug_io);
                        continue;
                    };
                    var like_buf = std.ArrayList(u8).empty;
                    defer like_buf.deinit(self.alloc);
                    const oom_in_like: bool = blk: {
                        for (folder_path) |fc| {
                            if (fc == '%' or fc == '_' or fc == '\\') like_buf.append(self.alloc, '\\') catch break :blk true;
                            like_buf.append(self.alloc, fc) catch break :blk true;
                        }
                        like_buf.append(self.alloc, '%') catch break :blk true;
                        break :blk false;
                    };
                    if (oom_in_like) {
                        del_stmt.finalize();
                        self.db_mutex.unlock(std.Options.debug_io);
                        continue;
                    }
                    del_stmt.bind_text(1, like_buf.items);
                    _ = del_stmt.step() catch |err| blk: {
                        var del_buf: [128]u8 = undefined;
                        const del_msg = std.fmt.bufPrint(&del_buf, "refract: failed to remove folder from index: {s}", .{@errorName(err)}) catch "refract: failed to remove folder from index";
                        self.sendLogMessage(2, del_msg);
                        break :blk false;
                    };
                    del_stmt.finalize();
                    workspace_config.removeWorkspace(self, folder_uri);
                    self.db_mutex.unlock(std.Options.debug_io);
                    self.incr_paths_mu.lockUncancelable(std.Options.debug_io);
                    var ip_idx: usize = 0;
                    while (ip_idx < self.incr_paths.items.len) {
                        const p = self.incr_paths.items[ip_idx];
                        if (std.mem.startsWith(u8, p, folder_path) and
                            (p.len == folder_path.len or p[folder_path.len] == '/'))
                        {
                            self.alloc.free(p);
                            _ = self.incr_paths.orderedRemove(ip_idx);
                        } else {
                            ip_idx += 1;
                        }
                    }
                    self.incr_paths_mu.unlock(std.Options.debug_io);
                    // Remove from extra_roots if present
                    var er_idx: usize = 0;
                    while (er_idx < self.extra_roots.items.len) {
                        if (std.mem.eql(u8, self.extra_roots.items[er_idx], folder_path)) {
                            self.alloc.free(self.extra_roots.items[er_idx]);
                            _ = self.extra_roots.orderedRemove(er_idx);
                        } else {
                            er_idx += 1;
                        }
                    }
                },
                else => {},
            };
            // Index newly added workspace folders
            if (ev.get("added")) |added| switch (added) {
                .array => |arr| for (arr.items) |item| {
                    const folder = switch (item) {
                        .object => |o| o,
                        else => continue,
                    };
                    const folder_uri = switch (folder.get("uri") orelse continue) {
                        .string => |s| s,
                        else => continue,
                    };
                    const folder_path = uriToPath(self.alloc, folder_uri) catch continue;
                    defer self.alloc.free(folder_path);
                    if (self.alloc.dupe(u8, folder_path)) |rdup| {
                        self.extra_roots.append(self.alloc, rdup) catch self.alloc.free(rdup);
                    } else |_| {}
                    _ = workspace_config.recordWorkspace(self, folder_uri, folder_path, false);
                    const new_paths = scanner.scan(folder_path, self.alloc, self.extra_exclude_dirs) catch |e| {
                        var sbuf: [256]u8 = undefined;
                        const sm = std.fmt.bufPrint(&sbuf, "refract: failed to scan folder {s}: {s}", .{ folder_path, @errorName(e) }) catch "refract: folder scan failed";
                        self.sendLogMessage(2, sm);
                        continue;
                    };
                    var folder_overflow = false;
                    self.incr_paths_mu.lockUncancelable(std.Options.debug_io);
                    for (new_paths) |p| {
                        if (self.incr_paths.items.len < MAX_INCR_PATHS) {
                            self.incr_paths.append(self.alloc, p) catch self.alloc.free(p);
                        } else {
                            self.alloc.free(p);
                            folder_overflow = true;
                        }
                    }
                    self.alloc.free(new_paths);
                    self.incr_paths_mu.unlock(std.Options.debug_io);
                    if (folder_overflow) {
                        self.showUserError("refract: file change queue full — some files skipped. Run Refract: Force Reindex.");
                        self.startBgIndexer();
                    }
                },
                else => {},
            };
        }
        return null;
    } else if (std.mem.eql(u8, msg.method, "shutdown")) {
        self.shutdown_requested = true;
        return types.ResponseMessage{
            .id = msg.id,
            .result = .null,
            .@"error" = null,
        };
    } else if (std.mem.eql(u8, msg.method, "textDocument/willSaveWaitUntil")) {
        const raw = try self.alloc.dupe(u8, empty_json_array);
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = raw, .@"error" = null };
    }

    if (msg.id != null) {
        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .@"error" = .{
                .code = @intFromEnum(types.ErrorCode.method_not_found),
                .message = "Method not found",
            },
        };
    }
    return null;
}

pub fn handleInitialize(self: *Server, msg: types.RequestMessage) types.ResponseMessage {
    const profiling = std.c.getenv("REFRACT_INIT_PROFILE") != null;
    const init_start = if (profiling) std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() else 0;
    if (self.initialized) {
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = null, .@"error" = .{ .code = @intFromEnum(types.ErrorCode.invalid_request), .message = "Server already initialized" } };
    }
    if (msg.params) |params| {
        switch (params) {
            .object => |obj| {
                var uri_set = false;
                if (obj.get("rootUri")) |uri_val| {
                    switch (uri_val) {
                        .string => |s| {
                            if (self.root_uri) |old| self.alloc.free(old);
                            self.root_uri = self.alloc.dupe(u8, s) catch null;
                            if (self.root_path) |old| self.alloc.free(old);
                            if (uriToPath(self.alloc, s) catch null) |rp| {
                                defer self.alloc.free(rp);
                                self.root_path = std.fs.path.resolve(self.alloc, &.{rp}) catch self.alloc.dupe(u8, rp) catch null;
                            } else self.root_path = null;
                            self.maybeSwapDb(s);
                            uri_set = true;
                        },
                        else => {},
                    }
                }
                if (!uri_set) {
                    if (obj.get("workspaceFolders")) |wf_val| {
                        switch (wf_val) {
                            .array => |arr| {
                                if (arr.items.len > 0) {
                                    switch (arr.items[0]) {
                                        .object => |folder| {
                                            if (folder.get("uri")) |folder_uri_val| {
                                                switch (folder_uri_val) {
                                                    .string => |s| {
                                                        if (self.root_uri) |old| self.alloc.free(old);
                                                        self.root_uri = self.alloc.dupe(u8, s) catch null;
                                                        if (self.root_path) |old| self.alloc.free(old);
                                                        if (uriToPath(self.alloc, s) catch null) |rp| {
                                                            defer self.alloc.free(rp);
                                                            self.root_path = std.fs.path.resolve(self.alloc, &.{rp}) catch self.alloc.dupe(u8, rp) catch null;
                                                        } else self.root_path = null;
                                                        self.maybeSwapDb(s);
                                                    },
                                                    else => {},
                                                }
                                            }
                                        },
                                        else => {},
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                }
                if (self.root_path) |rp| {
                    _ = workspace_config.loadAndApply(self, rp);
                }
                if (self.root_uri) |primary_uri| {
                    if (self.root_path) |primary_path| {
                        _ = workspace_config.recordWorkspace(self, primary_uri, primary_path, true);
                    }
                }
                if (obj.get("workspaceFolders")) |wf_all| switch (wf_all) {
                    .array => |arr2| {
                        for (arr2.items, 0..) |it, idx| {
                            if (idx == 0) continue;
                            const folder = switch (it) {
                                .object => |o| o,
                                else => continue,
                            };
                            const folder_uri = switch (folder.get("uri") orelse continue) {
                                .string => |s| s,
                                else => continue,
                            };
                            const folder_path = uriToPath(self.alloc, folder_uri) catch continue;
                            defer self.alloc.free(folder_path);
                            if (self.alloc.dupe(u8, folder_path)) |rdup| {
                                self.extra_roots.append(self.alloc, rdup) catch self.alloc.free(rdup);
                            } else |_| {}
                            _ = workspace_config.recordWorkspace(self, folder_uri, folder_path, false);
                        }
                    },
                    else => {},
                };
                if (obj.get("initializationOptions")) |opts_val| {
                    if (opts_val == .object) {
                        if (opts_val.object.get("disableGemIndex")) |v| {
                            if (v == .bool) self.disable_gem_index.store(v.bool, .monotonic);
                        }
                        if (opts_val.object.get("maxFileSizeBytes")) |v| {
                            if (v == .integer and v.integer > 0) self.max_file_size.store(@intCast(@min(v.integer, @as(i64, 2 * 1024 * 1024 * 1024))), .monotonic);
                        }
                        if (opts_val.object.get("maxFileSizeMb")) |v| {
                            if (v == .integer and v.integer > 0) self.max_file_size.store(@as(usize, @intCast(@min(v.integer, @as(i64, 2048)))) * 1024 * 1024, .monotonic);
                        }
                        if (opts_val.object.get("rubocopTimeoutSecs")) |v| {
                            if (v == .integer and v.integer > 0) self.rubocop_timeout_ms.store(@as(u64, @intCast(@min(v.integer, @as(i64, 3600)))) * 1000, .monotonic);
                        }
                        if (opts_val.object.get("rubocopDebounceMs")) |v| {
                            if (v == .integer and v.integer >= 0) self.rubocop_debounce_ms.store(@as(u64, @intCast(@min(v.integer, @as(i64, 10_000)))), .monotonic);
                        }
                        if (opts_val.object.get("bundleExecTimeoutSecs")) |v| {
                            if (v == .integer and v.integer > 0) self.bundle_timeout_ms = @as(u64, @intCast(@min(v.integer, @as(i64, 3600)))) * 1000;
                        }
                        if (opts_val.object.get("maxWorkers")) |v| {
                            if (v == .integer and v.integer > 0) self.max_workers = @intCast(@min(v.integer, 16));
                        }
                        if (opts_val.object.get("excludeDirs")) |v| {
                            if (v == .array) {
                                var dirs = std.ArrayList([]const u8).empty;
                                for (v.array.items) |item| {
                                    if (item == .string) {
                                        const duped = self.alloc.dupe(u8, item.string) catch continue;
                                        dirs.append(self.alloc, duped) catch {
                                            self.alloc.free(duped);
                                            continue;
                                        };
                                    }
                                }
                                self.extra_exclude_dirs = dirs.toOwnedSlice(self.alloc) catch &.{};
                            }
                        }
                        if (opts_val.object.get("disableRubocop")) |v| {
                            if (v == .bool) self.disable_rubocop.store(v.bool, .monotonic);
                        }
                        if (opts_val.object.get("disableTypeChecker")) |v| {
                            if (v == .bool) self.disable_type_checker.store(v.bool, .monotonic);
                        }
                        if (opts_val.object.get("typeCheckerSeverity")) |v| {
                            if (v == .string) {
                                const sev: u8 = if (std.mem.eql(u8, v.string, "error")) 1 else if (std.mem.eql(u8, v.string, "info")) 3 else 2;
                                self.type_checker_severity.store(sev, .monotonic);
                            }
                        }
                        if (opts_val.object.get("logLevel")) |v| {
                            if (v == .integer and v.integer >= 1 and v.integer <= 4)
                                self.log_level.store(@intCast(v.integer), .monotonic);
                        }

                        // PR10: warn on unknown initializationOptions keys.
                        // Lax-default (log WARN, keep going). Future strict
                        // mode is opt-in via `strictInit:true`; for now we
                        // just point editor authors at typos.
                        const known_keys = [_][]const u8{
                            "disableGemIndex",         "maxFileSizeBytes",
                            "maxFileSizeMb",           "rubocopTimeoutSecs",
                            "rubocopDebounceMs",       "bundleExecTimeoutSecs",
                            "maxWorkers",              "excludeDirs",
                            "extraExcludeDirs",        "disableRubocop",
                            "disableTypeChecker",      "typeCheckerSeverity",
                            "diagnosticsSuppressions", "indexBudget",
                            "typeCheckerConfidence",   "logLevel",
                            "strictInit",
                        };
                        var it = opts_val.object.iterator();
                        while (it.next()) |entry| {
                            var known = false;
                            for (known_keys) |k| {
                                if (std.mem.eql(u8, entry.key_ptr.*, k)) {
                                    known = true;
                                    break;
                                }
                            }
                            if (!known) {
                                var wbuf: [256]u8 = undefined;
                                const wmsg = std.fmt.bufPrint(&wbuf, "refract: ignoring unknown initializationOptions key '{s}'", .{entry.key_ptr.*}) catch "refract: ignoring unknown initializationOption";
                                self.sendLogMessage(2, wmsg);
                            }
                        }
                    }
                }
                if (obj.get("capabilities")) |caps_val| {
                    if (caps_val == .object) {
                        if (caps_val.object.get("window")) |win_val| {
                            if (win_val == .object) {
                                if (win_val.object.get("workDoneProgress")) |wdp_val| {
                                    if (wdp_val == .bool) self.client_caps_work_done_progress = wdp_val.bool;
                                }
                            }
                        }
                        if (caps_val.object.get("workspace")) |ws_val| {
                            if (ws_val == .object) {
                                if (ws_val.object.get("workspaceEdit")) |we_val| {
                                    if (we_val == .object) {
                                        if (we_val.object.get("documentChanges")) |dc_val| {
                                            if (dc_val == .bool) self.client_caps_doc_changes = dc_val.bool;
                                        }
                                    }
                                }
                            }
                        }
                        if (caps_val.object.get("textDocument")) |td_val| {
                            if (td_val == .object) {
                                if (td_val.object.get("definition")) |def_val| {
                                    if (def_val == .object) {
                                        if (def_val.object.get("linkSupport")) |ls_val| {
                                            if (ls_val == .bool) self.client_caps_def_link = ls_val.bool;
                                        }
                                    }
                                }
                            }
                        }
                        if (caps_val.object.get("general")) |gen_val| {
                            if (gen_val == .object) {
                                if (gen_val.object.get("positionEncodings")) |encs_val| {
                                    if (encs_val == .array) {
                                        self.encoding_utf8 = false;
                                        for (encs_val.array.items) |e| {
                                            if (e == .string and std.mem.eql(u8, e.string, "utf-8")) {
                                                self.encoding_utf8 = true;
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }
    if (self.root_uri) |ruri| {
        if (uriToPath(self.alloc, ruri) catch null) |rp| {
            defer self.alloc.free(rp);
            if (scanner.parseGitignoreExcludes(rp, self.alloc) catch null) |gi_excludes| {
                if (gi_excludes.len > 0) {
                    const old_len = self.extra_exclude_dirs.len;
                    if (self.alloc.alloc([]const u8, old_len + gi_excludes.len)) |merged| {
                        if (old_len > 0) @memcpy(merged[0..old_len], self.extra_exclude_dirs);
                        @memcpy(merged[old_len..], gi_excludes);
                        const old_slice = self.extra_exclude_dirs;
                        self.extra_exclude_dirs = merged;
                        if (old_slice.len > 0) self.alloc.free(@constCast(old_slice));
                        self.alloc.free(@constCast(gi_excludes));
                    } else |_| {
                        for (gi_excludes) |e| self.alloc.free(@constCast(e));
                        self.alloc.free(@constCast(gi_excludes));
                    }
                } else {
                    // empty slice — may be &.{} (not heap-allocated), safe to skip
                }
            }
            if (scanner.parseGitignoreNegations(rp, self.alloc) catch null) |gi_negs| {
                if (gi_negs.len > 0) {
                    for (self.gitignore_negations) |n| self.alloc.free(@constCast(n));
                    if (self.gitignore_negations.len > 0) self.alloc.free(@constCast(self.gitignore_negations));
                    self.gitignore_negations = gi_negs;
                } else {
                    self.alloc.free(@constCast(gi_negs));
                }
            }
        }
    }
    self.initialized = true;

    // Wave-0/Wave-1 wiring: spawn observability worker; discover plugins.
    // Failures here are non-fatal and surfaced via window/showMessage.
    if (self.recorder == null) {
        self.recorder = observability.Recorder.init(self.alloc, self.db, self.io, &self.db_mutex);
        self.recorder.?.spawnWorker();
    }
    if (self.plugin_host == null) {
        const plugins_enabled = blk: {
            const env = std.c.getenv("RFC_ENABLE_PLUGINS") orelse break :blk false;
            const v = std.mem.span(env);
            break :blk v.len > 0 and !std.mem.eql(u8, v, "0") and !std.mem.eql(u8, v, "false");
        };
        if (plugins_enabled) {
            self.plugin_host = plugin_host.Host.init(self.alloc, build_meta.version);
            if (self.root_uri) |ruri| {
                if (uriToPath(self.alloc, ruri) catch null) |rp| {
                    defer self.alloc.free(rp);
                    self.plugin_host.?.discoverAndSpawn(rp) catch |err| {
                        var pbuf: [256]u8 = undefined;
                        const pmsg = std.fmt.bufPrint(&pbuf, "refract: plugin host discovery failed: {s}", .{@errorName(err)}) catch "refract: plugin host discovery failed";
                        self.sendLogMessage(2, pmsg);
                    };
                }
            }
        } else {
            self.sendLogMessage(3, "refract: plugins disabled in 0.1.0 (set RFC_ENABLE_PLUGINS=1 to opt in; OS-level sandbox enforcement lands in 0.2.0)");
        }
    }

    // Sorbet/Steep auto-launch: detect via workspace markers, spawn bridge,
    // send LSP `initialize` to wake the server. Failures are non-fatal —
    // the bridge stays null and the type chain falls back to RBS / literal.
    if (self.root_uri) |ruri| {
        if (uriToPath(self.alloc, ruri) catch null) |rp| {
            defer self.alloc.free(rp);
            if (self.sorbet_handle == null and sorbet_bridge.workspaceHasSorbet(rp, self.alloc)) {
                if (sorbet_bridge.Bridge.launch(.sorbet, rp, self.alloc)) |handle| {
                    self.sorbet_handle = handle;
                    const init_resp = self.sorbet_handle.?.request("initialize", "{}") catch null;
                    if (init_resp) |r| self.alloc.free(r);
                    self.sendLogMessage(3, "refract: sorbet bridge ready");
                    self.spawnTypeWorker(.sorbet);
                } else |err| {
                    var sbuf: [256]u8 = undefined;
                    const smsg = std.fmt.bufPrint(&sbuf, "refract: sorbet bridge launch failed: {s}", .{@errorName(err)}) catch "refract: sorbet bridge launch failed";
                    self.sendLogMessage(2, smsg);
                }
            }
            if (self.steep_handle == null and sorbet_bridge.workspaceHasSteep(rp, self.alloc)) {
                if (sorbet_bridge.Bridge.launch(.steep, rp, self.alloc)) |handle| {
                    self.steep_handle = handle;
                    const init_resp = self.steep_handle.?.request("initialize", "{}") catch null;
                    if (init_resp) |r| self.alloc.free(r);
                    self.sendLogMessage(3, "refract: steep bridge ready");
                    self.spawnTypeWorker(.steep);
                } else |err| {
                    var sbuf: [256]u8 = undefined;
                    const smsg = std.fmt.bufPrint(&sbuf, "refract: steep bridge launch failed: {s}", .{@errorName(err)}) catch "refract: steep bridge launch failed";
                    self.sendLogMessage(2, smsg);
                }
            }
            if (self.llm_config == null) {
                self.llm_config = llm_adapter.loadFromWorkspace(self.alloc, rp) catch null;
            }
        }
    }

    {
        var vbuf: [256]u8 = undefined;
        const vmsg = std.fmt.bufPrint(&vbuf, "refract {s} ready", .{build_meta.version}) catch "refract ready";
        self.sendLogMessage(3, vmsg);
        if (builtin.os.tag == .linux) {
            var link_buf: [4096]u8 = undefined;
            if (std.Io.Dir.readLinkAbsolute(std.Options.debug_io, "/proc/self/exe", &link_buf) catch null) |n| {
                const exe_link = link_buf[0..n];
                if (std.mem.endsWith(u8, exe_link, " (deleted)")) {
                    self.sendLogMessage(2, "refract: running binary was replaced on disk — restart the LSP to pick up the new build");
                }
            }
        }
    }
    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const iw = &aw.writer;
    iw.writeAll(init_caps_before_enc) catch return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = null, .@"error" = .{ .code = @intFromEnum(types.ErrorCode.internal_error), .message = "internal error" } };
    iw.writeAll(if (self.encoding_utf8) "\"utf-8\"" else "\"utf-16\"") catch {}; // response building
    iw.writeAll(init_caps_after_enc) catch {}; // response building
    iw.writeAll(build_meta.version) catch {}; // response building
    iw.writeAll("\"}}") catch {}; // response building
    const raw = aw.toOwnedSlice() catch return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = null, .@"error" = .{ .code = @intFromEnum(types.ErrorCode.internal_error), .message = "internal error" } };

    if (profiling) {
        const init_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() - init_start;
        var buf: [256]u8 = undefined;
        const msg_final = std.fmt.bufPrint(&buf, "refract_profile: handleInitialize total={d}ms\n", .{init_ms}) catch "refract_profile: handleInitialize\n";
        std.debug.print("{s}", .{msg_final});
    }

    self.startWarmupIndexer();

    return types.ResponseMessage{
        .id = msg.id,
        .raw_result = raw,
        .result = null,
        .@"error" = null,
    };
}
