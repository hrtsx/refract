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

pub const ruby_block_keywords = [_][]const u8{ "if ", "unless ", "case ", "while ", "until ", "begin", "for " };
pub const empty_json_array = "[]";
pub const MAX_INCR_PATHS: usize = 10_000;
pub const MAX_DELETED_PATHS: usize = 10_000;
pub const OPEN_DOC_CACHE_SIZE: usize = 200;
pub const LOG_FILE_SIZE_LIMIT: usize = 10 * 1024 * 1024;
pub const WORKSPACE_SYMBOL_LIMIT: usize = 500;
const USER_ERROR_RATELIMIT_MS: i64 = 30_000;
const INCR_WATCH_SLEEP_MS: u64 = 10;

var last_oom_log_ms: std.atomic.Value(i64) = .{ .raw = 0 };

pub fn logOomOnce(tag: []const u8) void {
    const now_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds();
    const prev = last_oom_log_ms.load(.monotonic);
    if (now_ms - prev < 60_000) return;
    if (last_oom_log_ms.cmpxchgStrong(prev, now_ms, .monotonic, .monotonic) != null) return;
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "refract: OOM drop at {s} (throttled to 1/min)\n", .{tag}) catch "refract: OOM drop\n";
    std.debug.print("{s}", .{msg});
}

pub fn emitSelRange(wr: *std.Io.Writer, src: []const u8, srv: *const Server, ln: i64, col: i64, name: []const u8) void {
    const line_src = getLineSlice(src, @intCast(@max(ln - 1, 0)));
    const col_u: usize = @intCast(@max(col, 0));
    const sc = srv.toClientCol(line_src, @min(col_u, line_src.len));
    const safe_off = @min(col_u, line_src.len);
    const ec = sc + utf8ColToUtf16(line_src[safe_off..], @min(name.len, line_src.len - safe_off));
    wr.print(",\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{ ln - 1, sc, ln - 1, ec }) catch {}; // response building
}

pub fn computeDiagCol(src: ?[]const u8, enc_utf8: bool, line_0: i64, byte_col: u32) i64 {
    if (enc_utf8 or src == null) return @intCast(byte_col);
    var ln: i64 = 0;
    var i: usize = 0;
    while (i < src.?.len and ln < line_0) : (i += 1) {
        if (src.?[i] == '\n') ln += 1;
    }
    const line_end = std.mem.indexOfPos(u8, src.?, i, "\n") orelse src.?.len;
    return utf8ColToUtf16(src.?[i..line_end], byte_col);
}

fn indexBundledRbsLsp(ctx: *BgCtx) void {
    const db = ctx.server_ptr.db;
    ctx.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
    const bundled_count = indexer.indexBundledRbs(db) catch 0;
    ctx.server_ptr.db_mutex.unlock(std.Options.debug_io);
    if (bundled_count > 0) {
        var bbuf: [128]u8 = undefined;
        const bmsg = std.fmt.bufPrint(&bbuf, "refract: indexed {d} bundled RBS files", .{bundled_count}) catch "refract: indexed bundled RBS";
        ctx.server_ptr.sendLogMessage(3, bmsg);
    }
}

fn indexStdlibRbsLsp(ctx: *BgCtx, alloc: std.mem.Allocator) void {
    const db = ctx.server_ptr.db;
    const stdlib_paths = gems.findRbsStdlibPaths(ctx.io, ctx.root_path, alloc, ctx.bundle_timeout_ms * std.time.ns_per_ms) catch |e| {
        var ebuf2: [256]u8 = undefined;
        const emsg2 = std.fmt.bufPrint(&ebuf2, "refract: stdlib path discovery failed: {s}", .{@errorName(e)}) catch "refract: stdlib path discovery failed";
        ctx.server_ptr.sendLogMessage(2, emsg2);
        return;
    };
    defer {
        for (stdlib_paths) |p| alloc.free(p);
        alloc.free(stdlib_paths);
    }
    if (stdlib_paths.len == 0) {
        ctx.server_ptr.sendLogMessage(3, "refract: no stdlib RBS paths found (using bundled only)");
        return;
    }
    const stdlib_const = alloc.alloc([]const u8, stdlib_paths.len) catch return;
    defer alloc.free(stdlib_const);
    for (stdlib_paths, 0..) |p, si| stdlib_const[si] = p;
    ctx.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
    indexer.reindex(db, stdlib_const, true, alloc, ctx.server_ptr.max_file_size.load(.monotonic), null) catch |e| {
        var ebuf3: [256]u8 = undefined;
        const emsg3 = std.fmt.bufPrint(&ebuf3, "refract: stdlib reindex failed: {s}", .{@errorName(e)}) catch "refract: stdlib reindex failed";
        ctx.server_ptr.sendLogMessage(2, emsg3);
        ctx.server_ptr.db_mutex.unlock(std.Options.debug_io);
        return;
    };
    setMetaInt(db, "stdlib_rbs_indexed", 1, alloc);
    ctx.server_ptr.db_mutex.unlock(std.Options.debug_io);
    var sbuf: [128]u8 = undefined;
    const smsg = std.fmt.bufPrint(&sbuf, "refract: indexed {d} stdlib RBS files", .{stdlib_const.len}) catch "refract: indexed stdlib RBS";
    ctx.server_ptr.sendLogMessage(3, smsg);
}

pub fn getMetaInt(db: db_mod.Db, key: []const u8) ?i64 {
    const stmt = db.prepare("SELECT value FROM meta WHERE key=?") catch return null;
    defer stmt.finalize();
    stmt.bind_text(1, key);
    if (stmt.step() catch false) {
        const v = stmt.column_text(0);
        return std.fmt.parseInt(i64, v, 10) catch null;
    }
    return null;
}

pub fn setMetaInt(db: db_mod.Db, key: []const u8, val: i64, alloc: std.mem.Allocator) void {
    const s = std.fmt.allocPrint(alloc, "{d}", .{val}) catch return;
    defer alloc.free(s);
    const stmt = db.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)") catch return;
    defer stmt.finalize();
    stmt.bind_text(1, key);
    stmt.bind_text(2, s);
    _ = stmt.step() catch |e| {
        var buf: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "refract: setMetaInt failed: {s}\n", .{@errorName(e)}) catch "refract: setMetaInt failed\n";
        std.debug.print("{s}", .{m});
    };
}

const IndexWork = struct {
    path: []const u8,
    is_gem: bool = false,
};

pub const MAX_QUEUE_SIZE: usize = 50_000;

const WorkQueue = struct {
    items: std.ArrayList(IndexWork) = .empty,
    head: usize = 0,
    mu: std.Io.Mutex = std.Io.Mutex.init,
    cond: std.Io.Condition = std.Io.Condition.init,
    done: bool = false,

    pub fn push(self: *WorkQueue, item: IndexWork) bool {
        self.mu.lockUncancelable(std.Options.debug_io);
        defer self.mu.unlock(std.Options.debug_io);
        if (self.items.items.len >= MAX_QUEUE_SIZE) return false;
        self.items.append(std.heap.c_allocator, item) catch return false;
        self.cond.signal(std.Options.debug_io);
        return true;
    }

    pub fn pop(self: *WorkQueue) ?IndexWork {
        self.mu.lockUncancelable(std.Options.debug_io);
        defer self.mu.unlock(std.Options.debug_io);
        while (self.head >= self.items.items.len and !self.done) {
            self.cond.waitUncancelable(std.Options.debug_io, &self.mu);
        }
        if (self.head >= self.items.items.len) return null;
        const item = self.items.items[self.head];
        self.head += 1;
        return item;
    }
};

const BgWorkerCtx = struct {
    bg_ctx: *BgCtx,
    queue: *WorkQueue,
};

pub fn bgWorkerFn(wctx: BgWorkerCtx) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    // Per-worker in-memory DB for the parse phase; no mutex needed during parse
    const mem_db = db_mod.Db.open(":memory:") catch return;
    defer mem_db.close();
    mem_db.init_schema() catch return;
    while (wctx.queue.pop()) |work| {
        if (wctx.bg_ctx.server_ptr.bg_cancelled.load(.acquire)) return;
        // File stat outside mutex
        const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, work.path, .{}) catch {
            _ = arena.reset(.retain_capacity);
            continue;
        };
        if (stat.size > wctx.bg_ctx.server_ptr.max_file_size.load(.monotonic)) {
            var size_buf: [512]u8 = undefined;
            const size_msg = std.fmt.bufPrint(&size_buf, "refract: skipping {s} (file too large)", .{work.path}) catch "refract: skipping file (too large)";
            wctx.bg_ctx.server_ptr.sendLogMessage(2, size_msg);
            // Evict any previously-indexed symbols for this path so size-limit changes are observable
            wctx.bg_ctx.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
            if (wctx.bg_ctx.server_ptr.db.prepare("DELETE FROM files WHERE path = ?")) |del_stmt| {
                defer del_stmt.finalize();
                del_stmt.bind_text(1, work.path);
                _ = del_stmt.step() catch {};
            } else |_| {}
            wctx.bg_ctx.server_ptr.db_mutex.unlock(std.Options.debug_io);
            _ = arena.reset(.retain_capacity);
            continue;
        }
        // Quick mtime-based skip check under brief mutex
        const disk_mtime: i64 = stat.mtime.toMilliseconds();
        {
            wctx.bg_ctx.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
            defer wctx.bg_ctx.server_ptr.db_mutex.unlock(std.Options.debug_io);
            const skip = indexer.shouldSkip(wctx.bg_ctx.server_ptr.db, work.path, disk_mtime);
            if (skip) {
                _ = arena.reset(.retain_capacity);
                continue;
            }
        }
        // Skip files explicitly deleted via didDeleteFiles / didChangeWatchedFiles type=3
        {
            wctx.bg_ctx.server_ptr.deleted_paths_mu.lockUncancelable(std.Options.debug_io);
            defer wctx.bg_ctx.server_ptr.deleted_paths_mu.unlock(std.Options.debug_io);
            const is_deleted = wctx.bg_ctx.server_ptr.deleted_paths.contains(work.path);
            if (is_deleted) {
                _ = arena.reset(.retain_capacity);
                continue;
            }
        }
        // Phase 1: parse into mem_db — outside mutex, fully parallel across workers
        const single_path = [1][]const u8{work.path};
        indexer.reindex(mem_db, &single_path, work.is_gem, arena.allocator(), wctx.bg_ctx.server_ptr.max_file_size.load(.monotonic), null) catch |err| {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "refract: parse failed for {s}: {s}", .{ work.path, @errorName(err) }) catch "refract: parse failed";
            wctx.bg_ctx.server_ptr.sendLogMessage(2, msg);
            _ = wctx.bg_ctx.index_failures.fetchAdd(1, .monotonic);
            mem_db.exec("DELETE FROM files") catch {}; // cleanup
            _ = arena.reset(.retain_capacity);
            continue;
        };
        // Phase 2: commit parsed data to real DB — use BgCtx's shared connection under mutex
        {
            wctx.bg_ctx.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
            defer wctx.bg_ctx.server_ptr.db_mutex.unlock(std.Options.debug_io);
            const shared_db = wctx.bg_ctx.server_ptr.db;
            indexer.commitParsed(shared_db, mem_db, work.path, work.is_gem, arena.allocator()) catch |err| {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "refract: indexing failed for {s}: {s}", .{ work.path, @errorName(err) }) catch "refract: indexing failed";
                wctx.bg_ctx.server_ptr.sendLogMessage(2, msg);
                _ = wctx.bg_ctx.index_failures.fetchAdd(1, .monotonic);
            };
        }
        // Clear mem_db for next file (CASCADE handles all child tables)
        mem_db.exec("DELETE FROM files") catch {}; // cleanup
        _ = arena.reset(.retain_capacity);
    }
}

pub fn serverLogSinkCb(ctx: ?*anyopaque, level: u8, msg: []const u8) void {
    const srv_ptr = ctx orelse return;
    const srv: *Server = @ptrCast(@alignCast(srv_ptr));
    srv.sendLogMessage(level, msg);
}

pub fn flushWorkerFn(server: *Server) void {
    const tick_ns: u64 = 75 * std.time.ns_per_ms;
    while (!server.flush_thread_done.load(.acquire) and !server.bg_cancelled.load(.acquire)) {
        {
            var _sleep_ts: std.c.timespec = .{ .sec = @intCast((tick_ns) / std.time.ns_per_s), .nsec = @intCast((tick_ns) % std.time.ns_per_s) };
            _ = std.c.nanosleep(&_sleep_ts, null);
        }
        if (server.flush_thread_done.load(.acquire) or server.bg_cancelled.load(.acquire)) break;
        server.flushDirtyUrisDebounced();
    }
}

pub fn rubocopWorkerFn(server: *Server) void {
    while (true) {
        server.rubocop_queue_mu.lockUncancelable(std.Options.debug_io);
        while (server.rubocop_pending.count() == 0 and !server.rubocop_thread_done.load(.acquire)) {
            server.rubocop_queue_cond.waitUncancelable(std.Options.debug_io, &server.rubocop_queue_mu);
        }
        if (server.rubocop_pending.count() == 0 and server.rubocop_thread_done.load(.acquire)) {
            server.rubocop_queue_mu.unlock(std.Options.debug_io);
            return;
        }
        var key_it = server.rubocop_pending.keyIterator();
        const path_key = key_it.next().?.*;
        const path = server.alloc.dupe(u8, path_key) catch {
            server.rubocop_queue_mu.unlock(std.Options.debug_io);
            continue;
        };
        _ = server.rubocop_pending.remove(path_key);
        server.alloc.free(path_key);
        server.rubocop_queue_mu.unlock(std.Options.debug_io);
        defer server.alloc.free(path);

        // Debounce: wait before running RuboCop so rapid saves coalesce into one run.
        const debounce_ms = server.rubocop_debounce_ms.load(.monotonic);
        if (debounce_ms > 0) {
            const debounce_ns = debounce_ms * std.time.ns_per_ms;
            var _deb_ts: std.c.timespec = .{
                .sec = @intCast(debounce_ns / std.time.ns_per_s),
                .nsec = @intCast(debounce_ns % std.time.ns_per_s),
            };
            _ = std.c.nanosleep(&_deb_ts, null);
        }

        const uri = std.fmt.allocPrint(server.alloc, "file://{s}", .{path}) catch continue;
        defer server.alloc.free(uri);

        const rubocop_diags = diagnostics_mod.getRubocopDiags(server, path) catch &.{};
        defer {
            for (rubocop_diags) |d| {
                server.alloc.free(d.message);
                if (d.code.len > 0) server.alloc.free(@constCast(d.code));
            }
            server.alloc.free(rubocop_diags);
        }
        if (rubocop_diags.len == 0) continue;

        var open_source: ?[]u8 = null;
        defer if (open_source) |s| server.alloc.free(s);
        {
            server.open_docs_mu.lockUncancelable(std.Options.debug_io);
            defer server.open_docs_mu.unlock(std.Options.debug_io);
            if (server.open_docs.get(uri)) |src|
                open_source = server.alloc.dupe(u8, src) catch null;
        }
        const diag_source: ?[]const u8 = open_source;
        const prism_diags = if (diag_source) |src|
            indexer.getDiagsFromSource(src, path, server.alloc) catch &.{}
        else
            indexer.getDiags(path, server.alloc) catch &.{};
        defer {
            for (prism_diags) |d| server.alloc.free(d.message);
            server.alloc.free(prism_diags);
        }

        var aw = std.Io.Writer.Allocating.init(server.alloc);
        const w = &aw.writer;
        w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":") catch continue;
        writeEscapedJson(w, uri) catch continue;
        w.writeAll(",\"diagnostics\":[") catch continue;
        var first = true;
        diagnostics_mod.writeDiagItems(server, w, prism_diags, diag_source, &first);
        diagnostics_mod.writeDiagItems(server, w, rubocop_diags, diag_source, &first);
        w.writeAll("]}}") catch continue;
        const json = aw.toOwnedSlice() catch continue;
        defer server.alloc.free(json);
        server.sendNotification(json);
    }
}

fn ensureRefractDir(root_path: []const u8, alloc: std.mem.Allocator) !void {
    const dir_path = try std.fmt.allocPrint(alloc, "{s}/.refract", .{root_path});
    defer alloc.free(dir_path);
    std.Io.Dir.createDirAbsolute(std.Options.debug_io, dir_path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    const gi_path = try std.fmt.allocPrint(alloc, "{s}/.gitignore", .{dir_path});
    defer alloc.free(gi_path);
    std.Io.Dir.accessAbsolute(std.Options.debug_io, gi_path, .{}) catch {
        const content = "# Auto-created by refract; safe to edit\n*\n!.gitignore\n!disabled.txt\n";
        std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = gi_path, .data = content }) catch {};
    };
}

const BgCtx = struct {
    root_path: []u8,
    server_ptr: *Server,
    disable_gem_index: bool,
    extra_exclude_dirs: []const []const u8 = &.{},
    gitignore_negations: []const []const u8 = &.{},
    bundle_timeout_ms: u64 = 15_000,
    max_workers: usize = 8,
    index_failures: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    io: std.Io = std.Options.debug_io,

    pub fn run(self: *BgCtx) void {
        defer {
            std.heap.c_allocator.free(self.root_path);
            std.heap.c_allocator.destroy(self);
        }
        self.server_ptr.bg_started_event.store(true, .release);
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const db = self.server_ptr.db;

        self.server_ptr.sendLogMessage(3, "refract: indexing workspace");
        self.server_ptr.sendProgressBegin();

        ensureRefractDir(self.root_path, alloc) catch {};

        const paths = scanner.scanWithNegations(self.root_path, alloc, self.extra_exclude_dirs, self.gitignore_negations) catch {
            self.server_ptr.sendLogMessage(1, "refract: workspace scan failed");
            self.server_ptr.sendProgressEnd();
            return;
        };
        defer {
            for (paths) |p| alloc.free(p);
            alloc.free(paths);
        }

        const const_paths = alloc.alloc([]const u8, paths.len) catch return;
        defer alloc.free(const_paths);
        for (paths, 0..) |p, i| const_paths[i] = p;

        // Filter scanned paths so bg's initial workspace reindex doesn't
        // overwrite state the client already set via notifications:
        //   - `deleted_paths`: didChangeWatchedFiles type=3 (explicit delete)
        //   - `open_docs`: didOpen/didChange — client content is authoritative
        // Without this, bg's reindex-from-disk races with the notification path
        // and can silently clobber newer in-memory edits (observed on macOS).
        var filtered_paths = std.ArrayList([]const u8).empty;
        defer filtered_paths.deinit(alloc);
        {
            var open_set: std.StringHashMapUnmanaged(void) = .empty;
            defer {
                var it = open_set.keyIterator();
                while (it.next()) |k| alloc.free(k.*);
                open_set.deinit(alloc);
            }
            {
                self.server_ptr.open_docs_mu.lockUncancelable(std.Options.debug_io);
                defer self.server_ptr.open_docs_mu.unlock(std.Options.debug_io);
                var uri_it = self.server_ptr.open_docs.keyIterator();
                while (uri_it.next()) |uri_ptr| {
                    const uri = uri_ptr.*;
                    if (!std.mem.startsWith(u8, uri, "file://")) continue;
                    const p = alloc.dupe(u8, uri["file://".len..]) catch continue;
                    open_set.put(alloc, p, {}) catch alloc.free(p);
                }
            }
            self.server_ptr.deleted_paths_mu.lockUncancelable(std.Options.debug_io);
            defer self.server_ptr.deleted_paths_mu.unlock(std.Options.debug_io);
            for (const_paths) |p| {
                if (self.server_ptr.deleted_paths.contains(p)) continue;
                if (open_set.contains(p)) continue;
                filtered_paths.append(alloc, p) catch {};
            }
        }

        // Index workspace files — wire live progress into $/progress notifications
        const ProgressCtx = struct {
            server: *Server,
            fn report(ctx_opaque: *anyopaque, done: usize, total: usize, path: []const u8) void {
                const self_pg: *@This() = @ptrCast(@alignCast(ctx_opaque));
                // Show the parent directory name in the status message
                const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
                const dir_part = if (slash > 0) blk: {
                    const parent = path[0..slash];
                    const prev_slash = std.mem.lastIndexOfScalar(u8, parent, '/') orelse 0;
                    break :blk parent[if (prev_slash > 0) prev_slash + 1 else 0..];
                } else path;
                self_pg.server.sendProgressReportWithDir(done, total, dir_part);
            }
        };
        var pg_ctx = ProgressCtx{ .server = self.server_ptr };
        const progress_cb = indexer.ProgressCallback{
            .ctx = &pg_ctx,
            .report = ProgressCtx.report,
        };
        self.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
        // Re-filter against deleted_paths after acquiring db_mutex — covers the race
        // where type=3 added a path AFTER the snapshot above but BEFORE we got db_mutex.
        // type=3 grabs db_mutex serially, so once we hold it, all earlier type=3 deletions
        // are visible in deleted_paths.
        var refiltered_paths = std.ArrayList([]const u8).empty;
        defer refiltered_paths.deinit(alloc);
        {
            self.server_ptr.deleted_paths_mu.lockUncancelable(std.Options.debug_io);
            defer self.server_ptr.deleted_paths_mu.unlock(std.Options.debug_io);
            for (filtered_paths.items) |p| {
                if (self.server_ptr.deleted_paths.contains(p)) continue;
                refiltered_paths.append(alloc, p) catch {};
            }
        }
        indexer.reindex(db, refiltered_paths.items, false, alloc, self.server_ptr.max_file_size.load(.monotonic), progress_cb) catch |err| {
            var ebuf: [256]u8 = undefined;
            const emsg = std.fmt.bufPrint(&ebuf, "refract: indexing failed: {s}", .{@errorName(err)}) catch "refract: indexing failed";
            self.server_ptr.sendLogMessage(2, emsg);
        };
        self.server_ptr.db_mutex.unlock(std.Options.debug_io);

        // Push diagnostics only for currently-open documents
        {
            var open_paths_list = std.ArrayList([]const u8).empty;
            defer {
                for (open_paths_list.items) |op| alloc.free(op);
                open_paths_list.deinit(alloc);
            }
            self.server_ptr.open_docs_mu.lockUncancelable(std.Options.debug_io);
            var uri_it = self.server_ptr.open_docs.keyIterator();
            while (uri_it.next()) |uri_ptr| {
                const uri = uri_ptr.*;
                if (std.mem.startsWith(u8, uri, "file://")) {
                    if (alloc.dupe(u8, uri["file://".len..])) |p| {
                        open_paths_list.append(alloc, p) catch alloc.free(p);
                    } else |_| {}
                }
            }
            self.server_ptr.open_docs_mu.unlock(std.Options.debug_io);

            for (open_paths_list.items) |p| {
                if (self.server_ptr.bg_cancelled.load(.acquire)) break;
                var uri_buf: [4096]u8 = undefined;
                if (std.fmt.bufPrint(&uri_buf, "file://{s}", .{p})) |file_uri| {
                    diagnostics_mod.publishDiagnostics(self.server_ptr, file_uri, p, false);
                } else |_| {}
            }
        }

        if (!self.server_ptr.bg_cancelled.load(.acquire)) {
            var keep_paths: std.StringHashMapUnmanaged(void) = .empty;
            defer {
                var kit = keep_paths.keyIterator();
                while (kit.next()) |k| alloc.free(k.*);
                keep_paths.deinit(alloc);
            }
            {
                self.server_ptr.open_docs_mu.lockUncancelable(std.Options.debug_io);
                defer self.server_ptr.open_docs_mu.unlock(std.Options.debug_io);
                var uri_it = self.server_ptr.open_docs.keyIterator();
                while (uri_it.next()) |uri_ptr| {
                    const uri = uri_ptr.*;
                    if (!std.mem.startsWith(u8, uri, "file://")) continue;
                    const p = alloc.dupe(u8, uri["file://".len..]) catch continue;
                    keep_paths.put(alloc, p, {}) catch alloc.free(p);
                }
            }
            self.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
            indexer.cleanupStale(db, const_paths, self.root_path, alloc, &keep_paths) catch |e| {
                var buf: [128]u8 = undefined;
                const m = std.fmt.bufPrint(&buf, "refract: symbol cleanup failed: {s}", .{@errorName(e)}) catch "refract: symbol cleanup failed";
                self.server_ptr.sendLogMessage(2, m);
            };
            indexer.ensureBundledRbs(db);
            self.server_ptr.db_mutex.unlock(std.Options.debug_io);
        }

        self.server_ptr.sendProgressEnd();
        if (!self.server_ptr.bg_cancelled.load(.acquire)) {
            self.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
            var nfiles: i64 = 0;
            var nsyms: i64 = 0;
            if (db.prepare("SELECT COUNT(*) FROM files WHERE is_gem=0")) |fs| {
                defer fs.finalize();
                if (fs.step() catch false) nfiles = fs.column_int(0);
            } else |_| {}
            if (db.prepare("SELECT COUNT(*) FROM symbols")) |ss| {
                defer ss.finalize();
                if (ss.step() catch false) nsyms = ss.column_int(0);
            } else |_| {}
            self.server_ptr.db_mutex.unlock(std.Options.debug_io);
            const nfailures = self.index_failures.load(.monotonic);
            var stat_buf: [192]u8 = undefined;
            if (nfailures > 0) {
                const stat_msg = std.fmt.bufPrint(&stat_buf, "refract: indexed {d} files, {d} symbols ({d} failures)", .{ nfiles, nsyms, nfailures }) catch "refract: indexing complete";
                self.server_ptr.sendLogMessage(3, stat_msg);
                if (nfiles > 0 and nfailures > @as(u32, @intCast(@divTrunc(nfiles * 2, 10)))) {
                    self.server_ptr.showUserError("refract: high indexing failure rate — some features may be incomplete");
                }
            } else {
                const stat_msg = std.fmt.bufPrint(&stat_buf, "refract: indexed {d} files, {d} symbols", .{ nfiles, nsyms }) catch "refract: indexing complete";
                self.server_ptr.sendLogMessage(3, stat_msg);
            }
        } else {
            self.server_ptr.sendLogMessage(3, "refract: indexing complete");
        }

        // Always index bundled RBS — cheap, idempotent (keyed by <bundled>/... path).
        // Ensures fresh hover/completion coverage after binary upgrades, regardless of DB age.
        if (!self.server_ptr.bg_cancelled.load(.acquire)) {
            indexBundledRbsLsp(self);
        }

        // Expensive: system RBS discovery + reindex — only once per DB.
        if (!self.server_ptr.bg_cancelled.load(.acquire)) {
            self.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
            const stored_stdlib = getMetaInt(db, "stdlib_rbs_indexed") orelse 0;
            self.server_ptr.db_mutex.unlock(std.Options.debug_io);
            if (stored_stdlib == 0) {
                indexStdlibRbsLsp(self, alloc);
            }
        }

        if (!self.disable_gem_index and !self.server_ptr.bg_cancelled.load(.acquire)) gems: {
            // Gem scan: only if Gemfile.lock has changed
            const lock_path = std.fmt.allocPrint(alloc, "{s}/Gemfile.lock", .{self.root_path}) catch break :gems;
            const lock_stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, lock_path, .{}) catch {
                self.server_ptr.sendLogMessage(3, "refract: no Gemfile.lock found; gem indexing skipped");
                break :gems;
            };
            const lock_mtime: i64 = lock_stat.mtime.toMilliseconds();

            self.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
            const stored_mtime = getMetaInt(db, "gemfile_lock_mtime") orelse 0;
            if (lock_mtime == stored_mtime) {
                self.server_ptr.db_mutex.unlock(std.Options.debug_io);
                break :gems;
            }
            db.exec("DELETE FROM files WHERE is_gem=1") catch |e| {
                var gbuf: [256]u8 = undefined;
                const gmsg = std.fmt.bufPrint(&gbuf, "refract: gem table clear failed: {s}", .{@errorName(e)}) catch "refract: gem table clear failed";
                self.server_ptr.sendLogMessage(2, gmsg);
            };
            self.server_ptr.db_mutex.unlock(std.Options.debug_io);

            const gem_paths = gems.findGemPaths(self.io, self.root_path, alloc, self.bundle_timeout_ms * std.time.ns_per_ms) catch {
                self.server_ptr.sendLogMessage(2, "refract: gem index failed");
                self.server_ptr.showUserError("refract: gem indexing failed — completion for gems may be unavailable");
                break :gems;
            };
            defer {
                for (gem_paths) |p| alloc.free(p);
                alloc.free(gem_paths);
            }
            const gem_const_paths = alloc.alloc([]const u8, gem_paths.len) catch break :gems;
            defer alloc.free(gem_const_paths);
            for (gem_paths, 0..) |p, i| gem_const_paths[i] = p;

            self.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
            indexer.reindex(db, gem_const_paths, true, alloc, self.server_ptr.max_file_size.load(.monotonic), null) catch |e| {
                std.debug.print("{s}", .{@errorName(e)});
            };
            self.server_ptr.db_mutex.unlock(std.Options.debug_io);
            {
                var gbuf: [128]u8 = undefined;
                const gmsg = std.fmt.bufPrint(&gbuf, "refract: indexing gems: {d} files", .{gem_const_paths.len}) catch "refract: indexing gems";
                self.server_ptr.sendLogMessage(3, gmsg);
            }
            if (!self.server_ptr.bg_cancelled.load(.acquire)) {
                self.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
                setMetaInt(db, "gemfile_lock_mtime", lock_mtime, alloc);
                self.server_ptr.db_mutex.unlock(std.Options.debug_io);
            }

            // Index RBS collection paths (rbs_collection.lock.yaml)
            if (!self.server_ptr.bg_cancelled.load(.acquire)) {
                if (gems.findRbsCollectionPaths(self.root_path, alloc)) |rbs_coll_paths| {
                    defer {
                        for (rbs_coll_paths) |p| alloc.free(p);
                        alloc.free(rbs_coll_paths);
                    }
                    if (rbs_coll_paths.len > 0) {
                        const rbs_const = alloc.alloc([]const u8, rbs_coll_paths.len) catch break :gems;
                        defer alloc.free(rbs_const);
                        for (rbs_coll_paths, 0..) |p, i| rbs_const[i] = p;
                        self.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
                        defer self.server_ptr.db_mutex.unlock(std.Options.debug_io);
                        indexer.reindex(db, rbs_const, true, alloc, self.server_ptr.max_file_size.load(.monotonic), null) catch |e| {
                            std.debug.print("{s}", .{@errorName(e)});
                        };
                        var rbuf: [128]u8 = undefined;
                        const rmsg = std.fmt.bufPrint(&rbuf, "refract: indexed {d} RBS collection files", .{rbs_const.len}) catch "refract: indexed RBS collection";
                        self.server_ptr.sendLogMessage(3, rmsg);
                    }
                } else |_| {}
            }
        }

        self.server_ptr.bg_indexing_done.store(true, .release);

        // Incremental reindex watch loop: drain queued paths every 200ms
        while (!self.server_ptr.bg_cancelled.load(.acquire)) {
            var elapsed_ms: u32 = 0;
            while (elapsed_ms < 200) : (elapsed_ms += 10) {
                if (self.server_ptr.bg_cancelled.load(.acquire)) break;
                {
                    var _sleep_ts: std.c.timespec = .{ .sec = @intCast((INCR_WATCH_SLEEP_MS * std.time.ns_per_ms) / std.time.ns_per_s), .nsec = @intCast((INCR_WATCH_SLEEP_MS * std.time.ns_per_ms) % std.time.ns_per_s) };
                    _ = std.c.nanosleep(&_sleep_ts, null);
                }
            }
            self.server_ptr.incr_paths_mu.lockUncancelable(std.Options.debug_io);
            if (self.server_ptr.incr_paths.items.len == 0) {
                self.server_ptr.incr_paths_mu.unlock(std.Options.debug_io);
                continue;
            }
            const batch = self.server_ptr.incr_paths.toOwnedSlice(self.server_ptr.alloc) catch {
                self.server_ptr.incr_paths_mu.unlock(std.Options.debug_io);
                continue;
            };
            self.server_ptr.incr_paths = .empty;
            self.server_ptr.incr_paths_mu.unlock(std.Options.debug_io);
            defer {
                for (batch) |p| self.server_ptr.alloc.free(p);
                self.server_ptr.alloc.free(batch);
            }
            // Filter out explicitly deleted paths AFTER acquiring db_mutex —
            // type=3 grabs db_mutex serially, so once we hold it, all earlier
            // type=3 deletions are visible in deleted_paths. Filtering before
            // the lock would race against an in-flight delete.
            // Use server alloc (not bg arena) — arena.reset below would invalidate
            // arena-backed storage before the defer fires, causing a UAF on musl.
            self.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
            var filtered = std.ArrayList([]const u8).empty;
            defer filtered.deinit(self.server_ptr.alloc);
            {
                self.server_ptr.deleted_paths_mu.lockUncancelable(std.Options.debug_io);
                defer self.server_ptr.deleted_paths_mu.unlock(std.Options.debug_io);
                for (batch) |p| {
                    if (!self.server_ptr.deleted_paths.contains(p) and !self.server_ptr.isExcludedPath(p))
                        filtered.append(self.server_ptr.alloc, p) catch logOomOnce("bgctx.filtered");
                }
            }
            if (filtered.items.len > 0) {
                indexer.reindex(db, filtered.items, false, alloc, self.server_ptr.max_file_size.load(.monotonic), null) catch |e| {
                    var ebuf: [256]u8 = undefined;
                    const emsg = std.fmt.bufPrint(&ebuf, "refract: incremental reindex failed: {s}", .{@errorName(e)}) catch "refract: incremental reindex failed";
                    self.server_ptr.sendLogMessage(2, emsg);
                };
            }
            self.server_ptr.db_mutex.unlock(std.Options.debug_io);
            _ = arena.reset(.retain_capacity);
        }
    }
};

pub const TimeoutCtx = struct {
    child: *std.process.Child,
    done: std.atomic.Value(bool),
    timeout_ns: u64,

    pub fn run(ctx: *TimeoutCtx) void {
        var elapsed: u64 = 0;
        while (elapsed < ctx.timeout_ns) {
            {
                var _sleep_ts: std.c.timespec = .{ .sec = @intCast((100 * std.time.ns_per_ms) / std.time.ns_per_s), .nsec = @intCast((100 * std.time.ns_per_ms) % std.time.ns_per_s) };
                _ = std.c.nanosleep(&_sleep_ts, null);
            }
            elapsed += 100 * std.time.ns_per_ms;
            if (ctx.done.load(.acquire)) return;
        }
        _ = ctx.child.kill(std.Options.debug_io); // cleanup
    }
};

pub const ParamHintCtx = struct {
    db: db_mod.Db,
    alloc: std.mem.Allocator,
    parser: *prism_mod.Parser,
    w: *std.Io.Writer,
    file_id: i64,
    db_start: i64,
    db_end: i64,
    first_ptr: *bool,
    source: []const u8,
    encoding_utf8: bool,
};

pub fn paramHintVisitor(node: ?*const prism_mod.Node, data: ?*anyopaque) callconv(.c) bool {
    const ctx: *ParamHintCtx = @ptrCast(@alignCast(data.?));
    const n = node.?;
    if (n.*.type != prism_mod.NODE_CALL) return true;
    const cn: *const prism_mod.CallNode = @ptrCast(@alignCast(n));
    if (cn.arguments == null) return true;
    const args = cn.arguments[0].arguments;
    if (args.size < 2) return true;

    const call_lc = prism_mod.lineOffsetListLineColumn(&ctx.parser.line_offsets, n.*.location.start, ctx.parser.start_line);
    const call_line: i64 = call_lc.line;
    if (call_line < ctx.db_start or call_line > ctx.db_end) return true;

    const ct = prism_mod.constantPoolIdToConstant(&ctx.parser.constant_pool, cn.name);
    const mname = ct[0].start[0..ct[0].length];

    // Only render hints when we can pin the call to a concrete receiver class.
    // Unscoped hints pick any def with the same name and emit its param names —
    // that's the ENV.fetch → "default:" bug. Resolve the receiver first; skip if we can't.
    var recv_class_buf: [256]u8 = undefined;
    const recv_class: ?[]const u8 = blk: {
        const recv = cn.receiver orelse break :blk null;
        switch (recv.*.type) {
            prism_mod.NODE_CONSTANT => {
                const rc: *const prism_mod.ConstReadNode = @ptrCast(@alignCast(recv));
                const cc = prism_mod.constantPoolIdToConstant(&ctx.parser.constant_pool, rc.name);
                if (cc[0].length == 0 or cc[0].length > recv_class_buf.len) break :blk null;
                @memcpy(recv_class_buf[0..cc[0].length], cc[0].start[0..cc[0].length]);
                break :blk recv_class_buf[0..cc[0].length];
            },
            prism_mod.NODE_CONSTANT_PATH => {
                const cp: *const prism_mod.ConstantPathNode = @ptrCast(@alignCast(recv));
                if (cp.name == 0) break :blk null;
                const cc = prism_mod.constantPoolIdToConstant(&ctx.parser.constant_pool, cp.name);
                if (cc[0].length == 0 or cc[0].length > recv_class_buf.len) break :blk null;
                @memcpy(recv_class_buf[0..cc[0].length], cc[0].start[0..cc[0].length]);
                break :blk recv_class_buf[0..cc[0].length];
            },
            prism_mod.NODE_LOCAL_VAR_READ => {
                const rv: *const prism_mod.LocalVarReadNode = @ptrCast(@alignCast(recv));
                const info = prism_mod.constantPoolIdToConstant(&ctx.parser.constant_pool, rv.name);
                if (info[0].length == 0) break :blk null;
                const rv_name = info[0].start[0..info[0].length];
                const lv = ctx.db.prepare("SELECT type_hint FROM local_vars WHERE file_id=?1 AND name=?2 AND line<=?3 AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1") catch break :blk null;
                defer lv.finalize();
                lv.bind_int(1, ctx.file_id);
                lv.bind_text(2, rv_name);
                lv.bind_int(3, call_line);
                if (lv.step() catch false) {
                    const t_raw = lv.column_text(0);
                    const t = extractBaseClass(t_raw);
                    if (t.len > 0 and t.len <= recv_class_buf.len) {
                        @memcpy(recv_class_buf[0..t.len], t);
                        break :blk recv_class_buf[0..t.len];
                    }
                }
                break :blk null;
            },
            prism_mod.NODE_INSTANCE_VAR_READ => {
                const rv: *const prism_mod.InstanceVarReadNode = @ptrCast(@alignCast(recv));
                const info = prism_mod.constantPoolIdToConstant(&ctx.parser.constant_pool, rv.name);
                if (info[0].length == 0) break :blk null;
                const rv_name = info[0].start[0..info[0].length];
                const lv = ctx.db.prepare("SELECT type_hint FROM local_vars WHERE file_id=?1 AND name=?2 AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1") catch break :blk null;
                defer lv.finalize();
                lv.bind_int(1, ctx.file_id);
                lv.bind_text(2, rv_name);
                if (lv.step() catch false) {
                    const t_raw = lv.column_text(0);
                    const t = extractBaseClass(t_raw);
                    if (t.len > 0 and t.len <= recv_class_buf.len) {
                        @memcpy(recv_class_buf[0..t.len], t);
                        break :blk recv_class_buf[0..t.len];
                    }
                }
                break :blk null;
            },
            else => break :blk null,
        }
    };
    if (recv_class == null) return true;

    const mp_stmt = ctx.db.prepare(
        \\SELECT p.name, p.kind
        \\FROM params p JOIN symbols s ON p.symbol_id=s.id
        \\WHERE s.name=?1 AND s.kind IN ('def','classdef')
        \\  AND (s.parent_name=?2 OR (s.parent_name IS NULL AND s.file_id IN (
        \\    SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?2
        \\  )))
        \\  AND p.kind IN ('required','optional','positional')
        \\ORDER BY (s.doc IS NOT NULL) DESC, p.symbol_id, p.position LIMIT 20
    ) catch return true;
    mp_stmt.bind_text(1, mname);
    mp_stmt.bind_text(2, recv_class.?);
    defer mp_stmt.finalize();

    var pidx: usize = 0;
    while (mp_stmt.step() catch false) {
        if (pidx >= args.size or pidx >= 20) break;
        const pname = mp_stmt.column_text(0);
        const pkind = mp_stmt.column_text(1);
        const arg = args.nodes[pidx];
        if (arg.*.type == prism_mod.NODE_KEYWORD_HASH) break;
        // Only label positional-style params. Keyword/rest/block are user-visible already
        // or not expressible as a leading label.
        if (!(std.mem.eql(u8, pkind, "required") or std.mem.eql(u8, pkind, "optional") or std.mem.eql(u8, pkind, "positional"))) {
            pidx += 1;
            continue;
        }
        const arg_lc = prism_mod.lineOffsetListLineColumn(&ctx.parser.line_offsets, arg.*.location.start, ctx.parser.start_line);
        if (!ctx.first_ptr.*) ctx.w.writeByte(',') catch {}; // response building
        ctx.first_ptr.* = false;
        const arg_line_0: u32 = @intCast(arg_lc.line - 1);
        const arg_line_src = getLineSlice(ctx.source, arg_line_0);
        const char_col: u32 = if (ctx.encoding_utf8) @intCast(arg_lc.column) else utf8ColToUtf16(arg_line_src, arg_lc.column);
        ctx.w.print("{{\"position\":{{\"line\":{d},\"character\":{d}}},\"label\":\"", .{ arg_line_0, char_col }) catch {}; // response building
        writeEscapedJsonContent(ctx.w, pname) catch {}; // response building
        ctx.w.writeAll(":\",\"kind\":2,\"paddingLeft\":false,\"paddingRight\":true}") catch {}; // response building
        pidx += 1;
    }
    return true;
}

pub const Server = struct {
    db: db_mod.Db,
    db_pathz: [:0]u8,
    bg_thread: ?std.Thread,
    alloc: std.mem.Allocator,
    io: std.Io,
    initialized: bool,
    bg_started: bool,
    bg_started_event: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    bg_indexing_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    shutdown_requested: bool,
    root_uri: ?[]u8,
    writer_mutex: std.Io.Mutex,
    db_mutex: std.Io.Mutex,
    log_mutex: std.Io.Mutex,
    stdout_writer: ?*std.Io.Writer,
    disable_gem_index: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    disable_rubocop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    disable_type_checker: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    type_checker_severity: std.atomic.Value(u8) = std.atomic.Value(u8).init(2),
    log_path: ?[]const u8 = null,
    log_file: ?std.Io.File = null,
    log_level: std.atomic.Value(u8) = std.atomic.Value(u8).init(2),
    max_file_size: std.atomic.Value(usize) = std.atomic.Value(usize).init(8 * 1024 * 1024),
    client_caps_work_done_progress: bool = false,
    stmt_cache: std.AutoHashMapUnmanaged(usize, db_mod.CachedStmt) = .{},
    bg_cancelled: std.atomic.Value(bool) = .{ .raw = false },
    cancelled_ids: std.AutoHashMapUnmanaged(i64, void) = .{},
    cancel_mutex: std.Io.Mutex = std.Io.Mutex.init,
    open_docs: std.StringHashMapUnmanaged([]u8) = .{},
    open_docs_order: std.ArrayList([]const u8) = .empty,
    open_docs_mu: std.Io.Mutex = std.Io.Mutex.init,
    progress_req_counter: std.atomic.Value(i64) = std.atomic.Value(i64).init(1000),
    active_progress_token_id: i64 = 0,
    rubocop_timeout_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(30_000),
    rubocop_debounce_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(1500),
    bundle_timeout_ms: u64 = 15_000,
    max_workers: usize = 8,
    extra_exclude_dirs: []const []const u8 = &.{},
    gitignore_negations: []const []const u8 = &.{},
    rubocop_checked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    rubocop_available: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    rubocop_bundle_probed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    rubocop_use_bundle: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    lock_db_path: bool = false,
    last_index_mu: std.Io.Mutex = std.Io.Mutex.init,
    last_index_ms: std.StringHashMap(i64) = undefined,
    incr_paths: std.ArrayList([]u8) = undefined,
    incr_paths_mu: std.Io.Mutex = std.Io.Mutex.init,
    open_docs_version: std.StringHashMapUnmanaged(i64) = .{},
    client_caps_doc_changes: bool = false,
    client_caps_def_link: bool = false,
    root_path: ?[]u8 = null,
    tmp_dir: ?[]u8 = null,
    fmt_counter: u32 = 0,
    extra_roots: std.ArrayList([]u8) = .empty,
    encoding_utf8: bool = false,
    deleted_paths_mu: std.Io.Mutex = std.Io.Mutex.init,
    deleted_paths: std.StringHashMapUnmanaged(void) = .{},
    exit_code: ?u8 = null,
    last_user_error_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    rubocop_thread: ?std.Thread = null,
    rubocop_queue_mu: std.Io.Mutex = std.Io.Mutex.init,
    rubocop_queue_cond: std.Io.Condition = std.Io.Condition.init,
    rubocop_pending: std.StringHashMapUnmanaged(void) = .{},
    rubocop_thread_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    rubocop_mtime_cache: std.StringHashMapUnmanaged(i64) = .{},
    rubocop_mtime_mu: std.Io.Mutex = std.Io.Mutex.init,
    flush_thread: ?std.Thread = null,
    flush_thread_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    env_keys_cache: std.ArrayListUnmanaged([]u8) = .empty,
    env_keys_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    env_keys_mu: std.Io.Mutex = std.Io.Mutex.init,

    pub fn init(io: std.Io, db: db_mod.Db, db_pathz: [:0]const u8, alloc: std.mem.Allocator) !Server {
        var s = Server{
            .db = db,
            .db_pathz = try alloc.dupeZ(u8, db_pathz),
            .bg_thread = null,
            .alloc = alloc,
            .io = io,
            .initialized = false,
            .bg_started = false,
            .shutdown_requested = false,
            .root_uri = null,
            .writer_mutex = std.Io.Mutex.init,
            .db_mutex = std.Io.Mutex.init,
            .log_mutex = std.Io.Mutex.init,
            .stdout_writer = null,
            .disable_gem_index = std.atomic.Value(bool).init(false),
            .disable_rubocop = std.atomic.Value(bool).init(false),
            .disable_type_checker = std.atomic.Value(bool).init(false),
            .type_checker_severity = std.atomic.Value(u8).init(2),
            .log_path = null,
            .log_level = std.atomic.Value(u8).init(2),
            .max_file_size = std.atomic.Value(usize).init(8 * 1024 * 1024),
            .client_caps_work_done_progress = false,
            .stmt_cache = .{},
            .last_index_ms = std.StringHashMap(i64).init(alloc),
            .incr_paths = .empty,
        };
        const pid = std.c.getpid();
        var rand_bytes: [4]u8 = undefined;
        std.Options.debug_io.random(&rand_bytes);
        const tmp_base: []const u8 = if (std.c.getenv("TMPDIR")) |p| std.mem.span(p) else if (std.c.getenv("TMP")) |p| std.mem.span(p) else "/tmp";
        const tmp_dir = std.fmt.allocPrint(alloc, "{s}/refract-{d}-{x}", .{ tmp_base, pid, std.mem.readInt(u32, &rand_bytes, .little) }) catch null;
        s.tmp_dir = tmp_dir;
        return s;
    }

    pub fn deinit(self: *Server) void {
        self.bg_cancelled.store(true, .seq_cst);
        if (self.bg_thread) |t| t.join();
        self.rubocop_thread_done.store(true, .seq_cst);
        self.rubocop_queue_cond.signal(std.Options.debug_io);
        if (self.rubocop_thread) |t| t.join();
        self.flush_thread_done.store(true, .seq_cst);
        if (self.flush_thread) |t| t.join();
        var rq_it = self.rubocop_pending.keyIterator();
        while (rq_it.next()) |k| self.alloc.free(k.*);
        self.rubocop_pending.deinit(self.alloc);
        var rmc_it = self.rubocop_mtime_cache.keyIterator();
        while (rmc_it.next()) |k| self.alloc.free(k.*);
        self.rubocop_mtime_cache.deinit(self.alloc);
        self.db.runOptimize();
        self.db.runVacuum();
        if (self.root_uri) |uri| self.alloc.free(uri);
        if (self.root_path) |rp| self.alloc.free(rp);
        if (self.log_path) |lp| self.alloc.free(lp);
        if (self.log_file) |f| f.close(std.Options.debug_io);
        var doc_it = self.open_docs.iterator();
        while (doc_it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        self.open_docs.deinit(self.alloc);
        var ver_it = self.open_docs_version.iterator();
        while (ver_it.next()) |e| self.alloc.free(e.key_ptr.*);
        self.open_docs_version.deinit(self.alloc);
        for (self.open_docs_order.items) |k| self.alloc.free(@constCast(k));
        self.open_docs_order.deinit(self.alloc);
        var stmt_it = self.stmt_cache.valueIterator();
        while (stmt_it.next()) |cs| cs.finalize();
        self.stmt_cache.deinit(self.alloc);
        self.cancelled_ids.deinit(self.alloc);
        {
            var lim_it = self.last_index_ms.iterator();
            while (lim_it.next()) |e| self.alloc.free(e.key_ptr.*);
        }
        self.last_index_ms.deinit();
        for (self.incr_paths.items) |p| self.alloc.free(p);
        self.incr_paths.deinit(self.alloc);
        for (self.extra_exclude_dirs) |d| self.alloc.free(@constCast(d));
        if (self.extra_exclude_dirs.len > 0) self.alloc.free(@constCast(self.extra_exclude_dirs));
        for (self.gitignore_negations) |n| self.alloc.free(@constCast(n));
        if (self.gitignore_negations.len > 0) self.alloc.free(@constCast(self.gitignore_negations));
        if (self.tmp_dir) |d| {
            std.Io.Dir.cwd().deleteTree(std.Options.debug_io, d) catch |e| {
                var tbuf: [256]u8 = undefined;
                const tmsg = std.fmt.bufPrint(&tbuf, "refract: failed to delete tmp dir {s}: {s}\n", .{ d, @errorName(e) }) catch "refract: failed to delete tmp dir\n";
                std.debug.print("{s}", .{tmsg});
            };
            self.alloc.free(d);
        }
        for (self.extra_roots.items) |r| self.alloc.free(r);
        self.extra_roots.deinit(self.alloc);
        var dp_it = self.deleted_paths.keyIterator();
        while (dp_it.next()) |k| self.alloc.free(k.*);
        self.deleted_paths.deinit(self.alloc);
        for (self.env_keys_cache.items) |k| self.alloc.free(k);
        self.env_keys_cache.deinit(self.alloc);
        self.db.close();
        self.alloc.free(self.db_pathz);
    }

    pub fn startBgIndexer(self: *Server) void {
        indexer.log_sink = serverLogSinkCb;
        indexer.log_sink_ctx = self;
        const uri = self.root_uri orelse return;
        const decoded_path = uriToPath(std.heap.c_allocator, uri) catch return;
        const ctx = std.heap.c_allocator.create(BgCtx) catch {
            std.heap.c_allocator.free(decoded_path);
            return;
        };
        ctx.root_path = decoded_path;
        ctx.server_ptr = self;
        ctx.disable_gem_index = self.disable_gem_index.load(.monotonic);
        ctx.extra_exclude_dirs = self.extra_exclude_dirs;
        ctx.gitignore_negations = self.gitignore_negations;
        ctx.bundle_timeout_ms = self.bundle_timeout_ms;
        ctx.max_workers = self.max_workers;
        ctx.index_failures = std.atomic.Value(u32).init(0);
        ctx.io = self.io;
        self.bg_cancelled.store(true, .seq_cst);
        if (self.bg_thread) |t| t.join();
        self.bg_thread = null;
        self.bg_cancelled.store(false, .seq_cst);
        self.bg_indexing_done.store(false, .release);
        self.bg_started_event.store(false, .release);
        self.bg_thread = std.Thread.spawn(.{}, BgCtx.run, .{ctx}) catch blk: {
            ctx.run();
            break :blk null;
        };
    }

    pub fn cachedStmt(self: *Server, comptime sql: [*:0]const u8) !db_mod.CachedStmt {
        const key: usize = @intFromPtr(sql);
        if (self.stmt_cache.get(key)) |cs| {
            cs.reset();
            return cs;
        }
        const cs = try self.db.prepareRaw(sql);
        try self.stmt_cache.put(self.alloc, key, cs);
        return cs;
    }

    pub fn isNilableMethod(self: *Server, method_name: []const u8) bool {
        _ = self;
        const nilable_methods = [_][]const u8{ "find", "detect", "first", "last", "find_by", "find_by!", "[]", "presence", "at" };
        for (nilable_methods) |m| {
            if (std.mem.eql(u8, method_name, m)) return true;
        }
        return false;
    }

    pub fn pathInBounds(self: *Server, path: []const u8) bool {
        if (self.root_path == null and self.extra_roots.items.len == 0) return true;
        const canonical = std.fs.path.resolve(self.alloc, &.{path}) catch return false;
        defer self.alloc.free(canonical);
        if (self.root_path) |rp| {
            if (std.mem.startsWith(u8, canonical, rp) and
                (canonical.len == rp.len or canonical[rp.len] == '/')) return true;
        }
        for (self.extra_roots.items) |r| {
            if (std.mem.startsWith(u8, canonical, r) and
                (canonical.len == r.len or canonical[r.len] == '/')) return true;
        }
        return false;
    }

    pub fn isExcludedPath(self: *Server, path: []const u8) bool {
        for (self.extra_exclude_dirs) |excl| {
            var it = std.mem.splitSequence(u8, path, "/");
            while (it.next()) |part| {
                if (std.mem.eql(u8, part, excl)) return true;
            }
        }
        return false;
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

    pub fn isCancelled(self: *Server, id: ?std.json.Value) bool {
        const id_val = id orelse return false;
        const rid: i64 = switch (id_val) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => return false,
        };
        self.cancel_mutex.lockUncancelable(std.Options.debug_io);
        defer self.cancel_mutex.unlock(std.Options.debug_io);
        const found = self.cancelled_ids.contains(rid);
        if (found) _ = self.cancelled_ids.remove(rid);
        return found;
    }

    pub fn cancelledResponse(_: *Server, id: ?std.json.Value) types.ResponseMessage {
        return .{
            .id = id,
            .result = null,
            .@"error" = .{ .code = @intFromEnum(types.ErrorCode.request_cancelled), .message = "request cancelled" },
        };
    }

    pub fn dispatch(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
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
        if (std.mem.eql(u8, msg.method, "initialized")) {
            if (self.bg_started) return null;
            self.bg_started = true;
            if (self.db.was_self_healed) {
                self.sendLogMessage(2, "refract: db was rebuilt from a corrupted state on startup; the index is fresh");
            }
            self.startBgIndexer();
            if (self.rubocop_thread == null) {
                self.rubocop_thread = std.Thread.spawn(.{}, rubocopWorkerFn, .{self}) catch null;
            }
            if (self.flush_thread == null) {
                self.flush_thread = std.Thread.spawn(.{}, flushWorkerFn, .{self}) catch null;
            }
            self.requestWorkspaceConfiguration();
            return null;
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
            return try navigation.handleDefinition(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/implementation")) {
            return try navigation.handleImplementation(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/declaration")) {
            return try navigation.handleDefinition(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/documentSymbol")) {
            return try symbols.handleDocumentSymbol(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/hover")) {
            return try hover.handleHover(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/completion")) {
            return try completion.handleCompletion(self, msg);
        } else if (std.mem.eql(u8, msg.method, "completionItem/resolve")) {
            return try completion.handleCompletionItemResolve(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/references")) {
            return try navigation.handleReferences(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/signatureHelp")) {
            return try editing.handleSignatureHelp(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/typeDefinition")) {
            return try navigation.handleTypeDefinition(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/inlayHint")) {
            return try editing.handleInlayHint(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/semanticTokens/full")) {
            return try semantic_tokens.handleSemanticTokensFull(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/semanticTokens/range")) {
            return try semantic_tokens.handleSemanticTokensRange(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/documentHighlight")) {
            return try editing.handleDocumentHighlight(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/documentLink")) {
            return try editing.handleDocumentLink(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/prepareRename")) {
            return try rename.handlePrepareRename(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/rename")) {
            return try rename.handleRename(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/formatting")) {
            return try code_actions.handleFormatting(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/foldingRange")) {
            return try editing.handleFoldingRange(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/rangeFormatting")) {
            return try code_actions.handleRangeFormatting(self, msg);
        } else if (std.mem.eql(u8, msg.method, "workspace/executeCommand")) {
            return try code_actions.handleExecuteCommand(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/codeLens")) {
            return try editing.handleCodeLens(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/prepareTypeHierarchy")) {
            return try navigation.handlePrepareTypeHierarchy(self, msg);
        } else if (std.mem.eql(u8, msg.method, "typeHierarchy/supertypes")) {
            return try navigation.handleTypeHierarchySupertypes(self, msg);
        } else if (std.mem.eql(u8, msg.method, "typeHierarchy/subtypes")) {
            return try navigation.handleTypeHierarchySubtypes(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/semanticTokens/full/delta")) {
            return try semantic_tokens.handleSemanticTokensDelta(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/selectionRange")) {
            return try editing.handleSelectionRange(self, msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/linkedEditingRange")) {
            return try editing.handleLinkedEditingRange(self, msg);
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

    pub fn handleServerResponse(self: *Server, obj: std.json.ObjectMap) !void {
        if (obj.get("error") != null) {
            self.client_caps_work_done_progress = false;
            return;
        }
        const result = obj.get("result") orelse return;
        switch (result) {
            .array => |arr| self.applyConfigurationResult(arr),
            else => {},
        }
    }

    pub fn applyConfigurationResult(self: *Server, arr: std.json.Array) void {
        if (arr.items.len == 0) return;
        const cfg = switch (arr.items[0]) {
            .object => |o| o,
            else => return,
        };
        if (cfg.get("disableRubocop")) |v| switch (v) {
            .bool => |b| {
                self.disable_rubocop.store(b, .monotonic);
            },
            else => {},
        };
        if (cfg.get("logLevel")) |v| switch (v) {
            .integer => |n| {
                self.log_level.store(@min(@as(u8, @intCast(@max(n, 0))), 4), .monotonic);
            },
            else => {},
        };
        if (cfg.get("disableGemIndex")) |v| switch (v) {
            .bool => |b| {
                self.disable_gem_index.store(b, .monotonic);
            },
            else => {},
        };
    }

    pub fn requestWorkspaceConfiguration(self: *Server) void {
        const req_id = self.progress_req_counter.fetchAdd(1, .monotonic);
        var buf: [256]u8 = undefined;
        const req = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"workspace/configuration\",\"params\":{{\"items\":[{{\"section\":\"refract\"}}]}}}}", .{req_id}) catch return;
        const w = self.stdout_writer orelse return;
        self.writer_mutex.lockUncancelable(std.Options.debug_io);
        defer self.writer_mutex.unlock(std.Options.debug_io);
        transport.writeMessage(w, req) catch |e| {
            var wc_buf: [128]u8 = undefined;
            const wc_msg = std.fmt.bufPrint(&wc_buf, "refract: send workspace/configuration request: {s}", .{@errorName(e)}) catch "refract: send failed";
            self.sendLogMessage(2, wc_msg);
        };
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
            f.writePositionalAll(std.Options.debug_io, msg, append_off + ts_str.len) catch |e| {
                self.log_file.?.close(std.Options.debug_io);
                self.log_file = null;
                var fbuf: [128]u8 = undefined;
                const fmsg = std.fmt.bufPrint(&fbuf, "refract log write failed: {s}\n", .{@errorName(e)}) catch "refract log write failed\n";
                std.debug.print("{s}", .{fmsg});
                break :blk;
            };
            f.writePositionalAll(std.Options.debug_io, "\n", append_off + ts_str.len + msg.len) catch {};
        }
        var aw = std.Io.Writer.Allocating.init(std.heap.c_allocator);
        const w = &aw.writer;
        w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{\"type\":") catch return;
        w.print("{d}", .{level}) catch return;
        w.writeAll(",\"message\":") catch return;
        writeEscapedJson(w, msg) catch return;
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
        var aw = std.Io.Writer.Allocating.init(std.heap.c_allocator);
        const w = &aw.writer;
        w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"") catch return;
        w.writeAll(method) catch return;
        w.writeAll("\",\"params\":{\"type\":") catch return;
        w.print("{d}", .{level}) catch return;
        w.writeAll(",\"message\":") catch return;
        writeEscapedJson(w, msg) catch return;
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

    pub fn handleInitialize(self: *Server, msg: types.RequestMessage) types.ResponseMessage {
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
        {
            var vbuf: [256]u8 = undefined;
            const vmsg = std.fmt.bufPrint(&vbuf, "refract {s} ready", .{build_meta.version}) catch "refract ready";
            self.sendLogMessage(3, vmsg);
            var link_buf: [4096]u8 = undefined;
            if (std.Io.Dir.readLinkAbsolute(std.Options.debug_io, "/proc/self/exe", &link_buf) catch null) |n| {
                const exe_link = link_buf[0..n];
                if (std.mem.endsWith(u8, exe_link, " (deleted)")) {
                    self.sendLogMessage(2, "refract: running binary was replaced on disk — restart the LSP to pick up the new build");
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
        return types.ResponseMessage{
            .id = msg.id,
            .raw_result = raw,
            .result = null,
            .@"error" = null,
        };
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

    pub const FLUSH_DEBOUNCE_MS: i64 = 150;

    pub fn flushDirtyUris(self: *Server) void {
        self.flushIncrPaths();
        self.flushDirtyUrisImpl(true);
    }

    pub fn flushDirtyUrisDebounced(self: *Server) void {
        self.flushDirtyUrisImpl(false);
    }

    fn flushDirtyUrisImpl(self: *Server, force: bool) void {
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
            }
            self.last_index_mu.lockUncancelable(std.Options.debug_io);
            if (self.last_index_ms.fetchRemove(uri_key)) |kv| self.alloc.free(kv.key);
            self.last_index_mu.unlock(std.Options.debug_io);
        }
    }

    pub fn detectI18nContext(source: []const u8, offset: usize) bool {
        if (offset == 0) return false;
        var i = offset;
        const limit = if (offset > 30) offset - 30 else 0;
        while (i > limit) {
            i -= 1;
            if (source[i] == '\n') return false;
            if (source[i] == '"' or source[i] == '\'') {
                if (i >= 1 and source[i - 1] == '(') {
                    if (i >= 2 and source[i - 2] == 't') return true;
                    if (i >= 7 and std.mem.eql(u8, source[i - 7 .. i - 1], "I18n.t")) return true;
                }
            }
        }
        return false;
    }

    // Returns the scope_id if the cursor is on a local variable (write or scoped read),
    // null if it's a global/method symbol, or error.NotFound if nothing matches.

    pub fn offsetToClientChar(self: *const Server, source: []const u8, offset: usize, line: u32) u32 {
        var line_start: usize = 0;
        var l: u32 = 0;
        var i: usize = 0;
        while (i < source.len and l < line) : (i += 1) {
            if (source[i] == '\n') {
                l += 1;
                line_start = i + 1;
            }
        }
        const col = if (offset >= line_start) offset - line_start else 0;
        if (self.encoding_utf8) return @intCast(col);
        const line_end = std.mem.indexOfPos(u8, source, line_start, "\n") orelse source.len;
        return utf8ColToUtf16(source[line_start..line_end], col);
    }

    pub fn toClientCol(self: *const Server, line_src: []const u8, col: usize) u32 {
        if (self.encoding_utf8) return @intCast(col);
        return utf8ColToUtf16(line_src, col);
    }

    pub fn toClientColFromPath(
        self: *const Server,
        frc: *std.StringHashMapUnmanaged([]const u8),
        path: []const u8,
        line_0: i64,
        col: i64,
    ) u32 {
        if (self.encoding_utf8) return @intCast(col);
        const src = frcGet(frc, self.alloc, path) orelse return @intCast(col);
        const line_src = getLineSlice(src, @intCast(line_0));
        return utf8ColToUtf16(line_src, @intCast(col));
    }
};

pub fn computeDbPath(alloc: std.mem.Allocator, root_path: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(root_path);
    const hash = hasher.final();

    const home: []const u8 = if (std.c.getenv("HOME")) |p| std.mem.span(p) else "/tmp";
    const data_dir = if (std.c.getenv("XDG_DATA_HOME")) |xdg|
        try std.fmt.allocPrint(alloc, "{s}/refract", .{std.mem.span(xdg)})
    else if (builtin.os.tag == .macos)
        try std.fmt.allocPrint(alloc, "{s}/Library/Application Support/refract", .{home})
    else
        try std.fmt.allocPrint(alloc, "{s}/.local/share/refract", .{home});
    defer alloc.free(data_dir);

    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, data_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    return std.fmt.allocPrint(alloc, "{s}/{x}.db", .{ data_dir, hash });
}

pub fn uriToPath(alloc: std.mem.Allocator, uri: []const u8) ![]u8 {
    const rest = if (std.mem.startsWith(u8, uri, "file://")) uri[7..] else uri;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < rest.len) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            const hi = std.fmt.charToDigit(rest[i + 1], 16) catch std.math.maxInt(u8);
            const lo = std.fmt.charToDigit(rest[i + 2], 16) catch std.math.maxInt(u8);
            if (hi < 16 and lo < 16) {
                try out.append(alloc, @intCast(hi * 16 + lo));
                i += 3;
                continue;
            }
        }
        try out.append(alloc, rest[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

pub fn pathToUri(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "file://");
    for (path) |c| {
        const safe = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '/' or c == '.' or c == '_' or c == '-' or c == '~' or
            c == ':' or c == '@' or c == '!' or c == '$' or c == '&' or
            c == '\'' or c == '(' or c == ')' or c == '*' or c == '+' or
            c == ',' or c == ';' or c == '=';
        if (safe) {
            try out.append(alloc, c);
        } else {
            var hex_buf: [3]u8 = undefined;
            const hex = try std.fmt.bufPrint(&hex_buf, "%{X:0>2}", .{c});
            try out.appendSlice(alloc, hex);
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn resolveRequireTarget(alloc: std.mem.Allocator, db: db_mod.Db, source: []const u8, cursor_offset: usize, current_file: []const u8) ?[]u8 {
    // Find line bounds containing cursor
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < cursor_offset) : (i += 1) {
        if (source[i] == '\n') line_start = i + 1;
    }
    var line_end = cursor_offset;
    while (line_end < source.len and source[line_end] != '\n') line_end += 1;
    const line_src = source[line_start..line_end];

    // Match require or require_relative with a string literal
    const rel_prefix = "require_relative";
    const req_prefix = "require";
    var is_relative = false;
    var rest: []const u8 = undefined;

    const trimmed = std.mem.trimStart(u8, line_src, " \t");
    if (std.mem.startsWith(u8, trimmed, rel_prefix)) {
        is_relative = true;
        rest = std.mem.trimStart(u8, trimmed[rel_prefix.len..], " \t");
    } else if (std.mem.startsWith(u8, trimmed, req_prefix)) {
        rest = std.mem.trimStart(u8, trimmed[req_prefix.len..], " \t");
    } else return null;

    if (rest.len < 2) return null;
    const quote = rest[0];
    if (quote != '\'' and quote != '"') return null;
    const close = std.mem.indexOfScalarPos(u8, rest, 1, quote) orelse return null;
    const req_str = rest[1..close];
    if (req_str.len == 0) return null;

    // Check cursor is within the string literal
    const str_abs_start = line_start + (@intFromPtr(rest.ptr) - @intFromPtr(line_src.ptr)) + 1;
    const str_abs_end = str_abs_start + req_str.len;
    if (cursor_offset < str_abs_start - 1 or cursor_offset > str_abs_end + 1) return null;

    if (is_relative) {
        const dir = std.fs.path.dirname(current_file) orelse return null;
        const candidate = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, req_str }) catch return null;
        defer alloc.free(candidate);
        // Try with .rb extension if not already present
        if (std.mem.endsWith(u8, candidate, ".rb")) {
            std.Io.Dir.accessAbsolute(std.Options.debug_io, candidate, .{}) catch return null;
            return alloc.dupe(u8, candidate) catch null;
        }
        const with_rb = std.fmt.allocPrint(alloc, "{s}.rb", .{candidate}) catch return null;
        defer alloc.free(with_rb);
        std.Io.Dir.accessAbsolute(std.Options.debug_io, with_rb, .{}) catch return null;
        return alloc.dupe(u8, with_rb) catch null;
    } else {
        // Search workspace DB
        const stmt = db.prepare("SELECT f.path FROM files f WHERE f.is_gem=0 AND f.path LIKE ? LIMIT 5") catch return null;
        defer stmt.finalize();
        const pattern = std.fmt.allocPrint(alloc, "%/{s}.rb", .{req_str}) catch return null;
        defer alloc.free(pattern);
        stmt.bind_text(1, pattern);
        if (stmt.step() catch false) {
            return alloc.dupe(u8, stmt.column_text(0)) catch null;
        }
        return null;
    }
}

pub fn normalizeCRLF(buf: []u8) []u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '\r' and i + 1 < buf.len and buf[i + 1] == '\n') continue;
        buf[w] = buf[i];
        w += 1;
    }
    return buf[0..w];
}

pub fn isInStringOrComment(source: []const u8, offset: usize) bool {
    var in_string: u8 = 0;
    var interp_depth: u32 = 0;
    var in_comment = false;
    var in_heredoc = false;
    var heredoc_term: []const u8 = "";
    var i: usize = 0;
    while (i < offset and i < source.len) : (i += 1) {
        const c = source[i];
        const at_line_start = (i == 0 or source[i - 1] == '\n');
        if (in_comment) {
            if (c == '\n') in_comment = false;
        } else if (in_heredoc) {
            if (at_line_start and heredoc_term.len > 0 and
                i + heredoc_term.len <= source.len and
                std.mem.eql(u8, source[i .. i + heredoc_term.len], heredoc_term))
            {
                const after = i + heredoc_term.len;
                if (after >= source.len or source[after] == '\n') {
                    in_heredoc = false;
                    i = after - 1;
                }
            }
        } else if (in_string != 0) {
            if (c == '\\' and i + 1 < source.len) {
                i += 1;
            } else if (in_string == '"' and c == '#' and i + 1 < source.len and source[i + 1] == '{') {
                interp_depth += 1;
                i += 1;
            } else if (interp_depth > 0 and c == '}') {
                interp_depth -= 1;
            } else if (interp_depth == 0 and c == in_string) {
                in_string = 0;
            }
        } else {
            if (c == '#') {
                in_comment = true;
            } else if (c == '\'' or c == '"') {
                in_string = c;
            } else if (c == '<' and i + 1 < source.len and source[i + 1] == '<') {
                var j = i + 2;
                if (j < source.len and (source[j] == '-' or source[j] == '~')) j += 1;
                const close_quote: u8 = if (j < source.len and (source[j] == '\'' or source[j] == '"')) blk: {
                    const q = source[j];
                    j += 1;
                    break :blk q;
                } else 0;
                const term_start = j;
                while (j < source.len and source[j] != '\n') {
                    if (close_quote != 0 and source[j] == close_quote) break;
                    if (close_quote == 0 and (source[j] == ' ' or source[j] == '\t' or
                        source[j] == ';' or source[j] == ',' or source[j] == ')')) break;
                    j += 1;
                }
                if (j > term_start) {
                    heredoc_term = source[term_start..j];
                    while (j < source.len and source[j] != '\n') j += 1;
                    in_heredoc = true;
                    i = j;
                }
            }
        }
    }
    return (in_string != 0 and interp_depth == 0) or in_comment or in_heredoc;
}

pub fn writePathAsUri(w: *std.Io.Writer, path: []const u8) !void {
    for (path) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '/' => try w.writeByte(c),
            else => try w.print("%{X:0>2}", .{c}),
        }
    }
}

pub fn extractParamsObject(params: ?std.json.Value) ?std.json.ObjectMap {
    return switch (params orelse return null) {
        .object => |o| o,
        else => null,
    };
}

pub fn extractTextDocumentUri(params: ?std.json.Value) ?[]const u8 {
    const obj = extractParamsObject(params) orelse return null;
    const td = switch (obj.get("textDocument") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return switch (td.get("uri") orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn extractPosition(params: ?std.json.Value) ?struct { line: u32, character: u32 } {
    const obj = extractParamsObject(params) orelse return null;
    const pos = switch (obj.get("position") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const ln = switch (pos.get("line") orelse return null) {
        .integer => |i| i,
        else => return null,
    };
    const ch = switch (pos.get("character") orelse return null) {
        .integer => |i| i,
        else => return null,
    };
    if (ln < 0 or ch < 0) return null;
    return .{ .line = @intCast(ln), .character = @intCast(ch) };
}

pub fn matchesCamelInitials(query: []const u8, name: []const u8) bool {
    if (query.len == 0) return true;
    var qi: usize = 0;
    for (name) |c| {
        if (qi >= query.len) break;
        if (std.ascii.toUpper(c) == std.ascii.toUpper(query[qi])) qi += 1;
    }
    return qi == query.len;
}

pub fn isSubsequence(query: []const u8, name: []const u8) bool {
    if (query.len == 0) return true;
    var qi: usize = 0;
    for (name) |c| {
        if (qi >= query.len) break;
        if (std.ascii.toLower(c) == std.ascii.toLower(query[qi])) qi += 1;
    }
    return qi == query.len;
}

pub fn buildQueryPattern(alloc: std.mem.Allocator, query: []const u8) ![]u8 {
    if (query.len == 0) return alloc.dupe(u8, "%");
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);
    const short = query.len <= 3;
    if (!short) try buf.append(alloc, '%');
    for (query) |c| {
        if (c == '%' or c == '_' or c == '\\') try buf.append(alloc, '\\');
        try buf.append(alloc, c);
    }
    try buf.append(alloc, '%');
    return buf.toOwnedSlice(alloc);
}

pub fn buildPrefixPattern(alloc: std.mem.Allocator, word: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);
    for (word) |c| {
        if (c == '%' or c == '_' or c == '\\') try buf.append(alloc, '\\');
        try buf.append(alloc, c);
    }
    try buf.append(alloc, '%');
    return buf.toOwnedSlice(alloc);
}

pub fn emptyResult(msg: types.RequestMessage) ?types.ResponseMessage {
    return types.ResponseMessage{ .id = msg.id, .result = null, .@"error" = null };
}

pub fn posToOffset(source: []const u8, line: u32, character: u32) usize {
    var cur_line: u32 = 0;
    var i: usize = 0;
    while (i < source.len and cur_line < line) : (i += 1) {
        if (source[i] == '\n') cur_line += 1;
    }
    return @min(i + character, source.len);
}

pub fn utf16ColToUtf8(line_src: []const u8, utf16_col: u32) usize {
    var units: u32 = 0;
    var i: usize = 0;
    while (i < line_src.len and units < utf16_col) {
        const b = line_src[i];
        const seq: usize = if (b < 0x80) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
        units += if (seq == 4) 2 else 1;
        i += seq;
    }
    // If utf16_col extends past the line, carry the overshoot through so posToOffset
    // clamps to source.len — matching the UTF-8 path behaviour for out-of-range positions.
    return i + (utf16_col - @min(utf16_col, units));
}

pub fn utf8ColToUtf16(line_src: []const u8, utf8_col: usize) u32 {
    var utf16: u32 = 0;
    var i: usize = 0;
    while (i < utf8_col and i < line_src.len) {
        const b = line_src[i];
        const seq: usize = if (b < 0x80) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
        utf16 += if (seq == 4) 2 else 1;
        i += seq;
    }
    return utf16;
}

pub fn convertSemBlobToUtf16(blob: []const u8, source: []const u8, alloc: std.mem.Allocator) ![]u8 {
    if (blob.len == 0) return alloc.dupe(u8, &.{});
    const n = blob.len / 20;
    const out = try alloc.alloc(u8, blob.len);
    var prev_utf16_col: u32 = 0;
    var abs_line: u32 = 0;
    var abs_col: u32 = 0;
    for (0..n) |i| {
        const dl = std.mem.readInt(u32, blob[i * 20 ..][0..4], .little);
        const dc = std.mem.readInt(u32, blob[i * 20 + 4 ..][0..4], .little);
        const lb = std.mem.readInt(u32, blob[i * 20 + 8 ..][0..4], .little);
        const tt = std.mem.readInt(u32, blob[i * 20 + 12 ..][0..4], .little);
        const tm = std.mem.readInt(u32, blob[i * 20 + 16 ..][0..4], .little);
        abs_line += dl;
        abs_col = if (dl == 0) abs_col + dc else dc;
        const ln = getLineSlice(source, abs_line);
        const col16 = utf8ColToUtf16(ln, @min(abs_col, ln.len));
        const end16 = utf8ColToUtf16(ln, @min(abs_col + lb, ln.len));
        const len16 = end16 - col16;
        const odc: u32 = if (dl == 0) col16 - prev_utf16_col else col16;
        prev_utf16_col = col16;
        std.mem.writeInt(u32, out[i * 20 ..][0..4], dl, .little);
        std.mem.writeInt(u32, out[i * 20 + 4 ..][0..4], odc, .little);
        std.mem.writeInt(u32, out[i * 20 + 8 ..][0..4], len16, .little);
        std.mem.writeInt(u32, out[i * 20 + 12 ..][0..4], tt, .little);
        std.mem.writeInt(u32, out[i * 20 + 16 ..][0..4], tm, .little);
    }
    return out;
}

pub fn getLineSlice(source: []const u8, line_0: u32) []const u8 {
    var l: u32 = 0;
    var i: usize = 0;
    while (i < source.len and l < line_0) : (i += 1) {
        if (source[i] == '\n') l += 1;
    }
    const start = i;
    while (i < source.len and source[i] != '\n') : (i += 1) {}
    return source[start..i];
}

pub fn frcGet(frc: *std.StringHashMapUnmanaged([]const u8), alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    if (frc.get(path)) |src| return src;
    const src = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, alloc, std.Io.Limit.limited(1 << 24)) catch return null;
    const owned_path = alloc.dupe(u8, path) catch {
        alloc.free(src);
        return null;
    };
    frc.put(alloc, owned_path, src) catch {
        alloc.free(owned_path);
        alloc.free(src);
        return null;
    };
    return src;
}

pub fn extractWord(source: []const u8, offset: usize) []const u8 {
    if (offset >= source.len) return "";
    var start = offset;
    while (start > 0 and isRubyIdent(source[start - 1])) start -= 1;
    var end = offset;
    while (end < source.len and isRubyIdent(source[end])) end += 1;
    return source[start..end];
}

pub fn extractQualifiedName(source: []const u8, offset: usize) []const u8 {
    if (offset >= source.len) return "";
    var end = offset;
    while (end < source.len and isRubyIdent(source[end])) end += 1;
    var start = offset;
    while (start > 0 and isRubyIdent(source[start - 1])) start -= 1;
    while (start >= 2 and source[start - 1] == ':' and source[start - 2] == ':') {
        var new_start = start - 2;
        while (new_start > 0 and isRubyIdent(source[new_start - 1])) new_start -= 1;
        if (new_start == start - 2) break;
        start = new_start;
    }
    return source[start..end];
}

pub fn extractBaseClass(type_str: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, type_str, '[')) |bracket| {
        return std.mem.trim(u8, type_str[0..bracket], " \t");
    }
    return std.mem.trim(u8, type_str, " \t");
}

pub fn extractGenericElement(type_str: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, type_str, '[') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, type_str, ']') orelse return null;
    if (close <= open + 1) return null;
    const inner = std.mem.trim(u8, type_str[open + 1 .. close], " \t");
    if (std.mem.indexOfScalar(u8, inner, ',')) |comma| {
        return std.mem.trim(u8, inner[0..comma], " \t");
    }
    return inner;
}

pub fn isRubyIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '?' or c == '!' or c == '@' or c == '$' or c >= 0x80;
}

pub fn isValidRubyIdent(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_' and name[0] < 0x80) return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '?' and c != '!' and c < 0x80) return false;
    }
    return true;
}

pub fn writeEscapedJsonContent(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
}

pub fn writeEscapedJson(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    try writeEscapedJsonContent(w, s);
    try w.writeByte('"');
}

pub fn writeCodeActionEdits(w: *std.Io.Writer, title: []const u8, kind: []const u8, uri: []const u8, edits: []const refactor.RefactorEdit) !void {
    try w.writeAll("{\"title\":");
    try writeEscapedJson(w, title);
    try w.writeAll(",\"kind\":");
    try writeEscapedJson(w, kind);
    try w.writeAll(",\"edit\":{\"changes\":{");
    try writeEscapedJson(w, uri);
    try w.writeAll(":[");
    for (edits, 0..) |edit, ei| {
        if (ei > 0) try w.writeByte(',');
        try w.print("{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":", .{
            edit.start_line, edit.start_col, edit.end_line, edit.end_col,
        });
        try writeEscapedJson(w, edit.new_text);
        try w.writeByte('}');
    }
    try w.writeAll("]}}}");
}

const init_caps_before_enc =
    \\{"capabilities":{"textDocumentSync":{"change":1,"save":{"includeText":true},"openClose":true},"workspaceSymbolProvider":true,"definitionProvider":true,"implementationProvider":true,"declarationProvider":true,"documentSymbolProvider":true,"hoverProvider":true,"completionProvider":{"triggerCharacters":[".","::", "@","$"],"resolveProvider":true},"referencesProvider":true,"signatureHelpProvider":{"triggerCharacters":["(",","]},"typeDefinitionProvider":true,"inlayHintProvider":true,"semanticTokensProvider":{"legend":{"tokenTypes":["class","namespace","method","parameter","variable","type"],"tokenModifiers":["declaration","readonly","deprecated","static"]},"full":{"delta":true},"range":true},"renameProvider":true,"prepareRenameProvider":true,"documentHighlightProvider":true,"documentLinkProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix","refactor.extract","refactor.inline","refactor.rewrite"]},"foldingRangeProvider":true,"documentRangeFormattingProvider":true,"callHierarchyProvider":true,"codeLensProvider":{"resolveProvider":false},"typeHierarchyProvider":true,"selectionRangeProvider":true,"linkedEditingRangeProvider":true,"diagnosticProvider":{"identifier":"refract","interFileDependencies":false,"workspaceDiagnostics":false},"executeCommandProvider":{"commands":["refract.restartIndexer","refract.forceReindex","refract.toggleGemIndex","refract.showReferences","refract.runTest","refract.recheckRubocop","refract.disableDiagnostic"]},"workspace":{"workspaceFolders":{"supported":true,"changeNotifications":true},"didChangeConfiguration":{"dynamicRegistration":true},"fileOperations":{"didCreate":{"filters":[{"scheme":"file","pattern":{"glob":"**/*.{rb,rbs,rbi,erb,rake,gemspec,ru}"}}]},"didDelete":{"filters":[{"scheme":"file","pattern":{"glob":"**/*.{rb,rbs,rbi,erb,rake,gemspec,ru}"}}]},"didChange":{"filters":[{"scheme":"file","pattern":{"glob":"**/*.{rb,rbs,rbi,erb,rake,gemspec,ru}"}}]},"willRename":{"filters":[{"scheme":"file","pattern":{"glob":"**/*.{rb,rbs,rbi,erb,rake,gemspec,ru}"}}]}}},"positionEncoding":
;
const init_caps_after_enc =
    \\},"serverInfo":{"name":"refract","version":"
;
