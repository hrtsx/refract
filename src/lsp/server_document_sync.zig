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
const normalizeCRLF = S.normalizeCRLF;
const utf16ColToUtf8 = S.utf16ColToUtf8;
const uriToPath = S.uriToPath;
const FLUSH_DEBOUNCE_MS = S.Server.FLUSH_DEBOUNCE_MS;
const posToOffset = S.posToOffset;
const computeDbPath = S.computeDbPath;
const ReadTxn = S.ReadTxn;
const logOomOnce = S.logOomOnce;
const getMetaInt = S.getMetaInt;
const setMetaInt = S.setMetaInt;
const emitSelRange = S.emitSelRange;
const computeDiagCol = S.computeDiagCol;
const serverLogSinkCb = S.serverLogSinkCb;

pub fn readSourceForUri(self: *Server, uri: []const u8, path: []const u8) ![]u8 {
    if (self.open_docs.get(uri)) |cached| return self.alloc.dupe(u8, cached);
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, self.alloc, std.Io.Limit.limited(self.max_file_size.load(.monotonic)));
    defer self.alloc.free(raw);
    const norm = normalizeCRLF(raw);
    var result = try self.alloc.dupe(u8, norm);
    if (result.len >= 3 and result[0] == 0xEF and result[1] == 0xBB and result[2] == 0xBF) {
        const stripped = try self.alloc.dupe(u8, result[3..]);
        self.alloc.free(result);
        return stripped;
    }
    return result;
}

pub fn clientPosToOffset(self: *Server, source: []const u8, line: u32, character: u32) usize {
    if (!self.encoding_utf8) {
        var l: u32 = 0;
        var i: usize = 0;
        while (i < source.len and l < line) : (i += 1) {
            if (source[i] == '\n') l += 1;
        }
        const line_start = i;
        const line_end = std.mem.indexOfPos(u8, source, line_start, "\n") orelse source.len;
        const utf8_char = utf16ColToUtf8(source[line_start..line_end], character);
        return posToOffset(source, line, @intCast(utf8_char));
    }
    return posToOffset(source, line, character);
}

pub fn maybeSwapDb(self: *Server, raw_uri: []const u8) void {
    if (self.lock_db_path) return;
    const root_path = uriToPath(self.alloc, raw_uri) catch return;
    defer self.alloc.free(root_path);
    const new_path = computeDbPath(self.alloc, root_path) catch return;
    defer self.alloc.free(new_path);
    if (std.mem.eql(u8, new_path, self.db_pathz)) return;
    const new_pathz = self.alloc.dupeZ(u8, new_path) catch return;
    const new_db = blk: {
        if (db_mod.Db.open(new_pathz)) |d| {
            break :blk d;
        } else |_| {
            std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, new_pathz) catch {}; // cleanup — ignore error
            break :blk db_mod.Db.open(new_pathz) catch {
                self.sendShowMessage(1, "refract: failed to open database after recovery — check disk space");
                self.alloc.free(new_pathz);
                return;
            };
        }
    };
    new_db.init_schema() catch {
        self.sendShowMessage(1, "refract: database init failed — check disk space/permissions");
        new_db.close();
        self.alloc.free(new_pathz);
        return;
    };
    var stmt_it = self.stmt_cache.valueIterator();
    while (stmt_it.next()) |cs| cs.finalize();
    self.stmt_cache.clearRetainingCapacity();
    self.db.close();
    self.db = new_db;
    self.alloc.free(self.db_pathz);
    self.db_pathz = new_pathz;
    self.reopenReadDb();
}

pub fn flushIncrPaths(self: *Server) void {
    self.incr_paths_mu.lockUncancelable(std.Options.debug_io);
    if (self.incr_paths.items.len == 0) {
        self.incr_paths_mu.unlock(std.Options.debug_io);
        return;
    }
    const batch = self.incr_paths.toOwnedSlice(self.alloc) catch {
        self.incr_paths_mu.unlock(std.Options.debug_io);
        return;
    };
    self.incr_paths = .empty;
    self.incr_paths_mu.unlock(std.Options.debug_io);
    defer {
        for (batch) |p| self.alloc.free(p);
        self.alloc.free(batch);
    }
    // Filter out explicitly deleted paths AFTER acquiring db_mutex —
    // covers the race where type=3 commits a delete between the filter
    // and the reindex.
    self.db_mutex.lockUncancelable(std.Options.debug_io);
    defer self.db_mutex.unlock(std.Options.debug_io);
    var filtered = std.ArrayList([]const u8).empty;
    defer filtered.deinit(self.alloc);
    {
        self.deleted_paths_mu.lockUncancelable(std.Options.debug_io);
        defer self.deleted_paths_mu.unlock(std.Options.debug_io);
        for (batch) |p| {
            if (!self.deleted_paths.contains(p)) filtered.append(self.alloc, p) catch logOomOnce("batchReindex.filtered");
        }
    }
    if (filtered.items.len == 0) return;
    indexer.reindex(self.db, filtered.items, false, self.alloc, self.max_file_size.load(.monotonic), null) catch |e| {
        var warn_buf: [128]u8 = undefined;
        const warn_msg = std.fmt.bufPrint(&warn_buf, "refract: batch reindex failed ({d} files): {s}", .{ filtered.items.len, @errorName(e) }) catch "refract: batch reindex failed";
        self.sendLogMessage(2, warn_msg);
    };
}

pub fn flushDirtyUris(self: *Server) void {
    self.flushIncrPaths();
    self.flushDirtyUrisImpl(true);
}

pub fn flushDirtyUrisDebounced(self: *Server) void {
    self.flushDirtyUrisImpl(false);
}

pub fn flushDirtyUrisImpl(self: *Server, force: bool) void {
    const now = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds();
    var due = std.ArrayList([]const u8).empty;
    defer due.deinit(self.alloc);
    {
        self.last_index_mu.lockUncancelable(std.Options.debug_io);
        defer self.last_index_mu.unlock(std.Options.debug_io);
        var it = self.last_index_ms.iterator();
        while (it.next()) |e| {
            if (force or now - e.value_ptr.* >= FLUSH_DEBOUNCE_MS)
                due.append(self.alloc, e.key_ptr.*) catch logOomOnce("flushDirty.due");
        }
    }
    for (due.items) |uri_key| {
        const path = uriToPath(self.alloc, uri_key) catch continue;
        defer self.alloc.free(path);
        if (self.open_docs.get(uri_key)) |src| {
            self.db_mutex.lockUncancelable(std.Options.debug_io);
            indexer.indexSource(src, path, self.db, self.alloc) catch |e| {
                var buf: [512]u8 = undefined;
                const msg_str = std.fmt.bufPrint(&buf, "refract: index failed for {s}: {s}", .{ path, @errorName(e) }) catch "refract: index failed";
                self.sendLogMessage(2, msg_str);
            };
            self.db_mutex.unlock(std.Options.debug_io);
            // Publish deferred diagnostics for didChange edits once typing
            // settles (debounced path only). The forced path is driven by
            // documentSymbol queries, which must not trigger notifications.
            if (!force) diagnostics_mod.publishDiagnostics(self, uri_key, path, false);
        }
        self.last_index_mu.lockUncancelable(std.Options.debug_io);
        if (self.last_index_ms.fetchRemove(uri_key)) |kv| self.alloc.free(kv.key);
        self.last_index_mu.unlock(std.Options.debug_io);
    }
}
