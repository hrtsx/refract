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
const limits = @import("limits.zig");
const S = @import("server.zig");
const Server = S.Server;
const INCR_WATCH_SLEEP_MS = S.INCR_WATCH_SLEEP_MS;
const rebuildHotIndex = S.rebuildHotIndex;
const writeEscapedJson = S.writeEscapedJson;
const MAX_QUEUE_SIZE = S.MAX_QUEUE_SIZE;
const logOomOnce = S.logOomOnce;
const getMetaInt = S.getMetaInt;
const setMetaInt = S.setMetaInt;
const emitSelRange = S.emitSelRange;
const computeDiagCol = S.computeDiagCol;
const serverLogSinkCb = S.serverLogSinkCb;
const TimeoutCtx = S.TimeoutCtx;

pub fn indexBundledRbsLsp(ctx: *BgCtx) void {
    const db = ctx.server_ptr.db;
    ctx.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
    const bundled_count = indexer.indexBundledRbs(db) catch 0;
    ctx.server_ptr.db_mutex.unlock(std.Options.debug_io);
    if (bundled_count > 0) {
        var bbuf: [128]u8 = undefined;
        const bmsg = std.fmt.bufPrint(&bbuf, "refract: indexed {d} bundled RBS files", .{bundled_count}) catch "refract: indexed bundled RBS";
        ctx.server_ptr.sendLogMessage(3, bmsg);
    }
    rebuildHotIndex(ctx.server_ptr);
}

pub fn indexStdlibRbsLsp(ctx: *BgCtx, alloc: std.mem.Allocator) void {
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
    // Index in small batches, releasing db_mutex between each so query handlers
    // can interleave. Holding the mutex across the whole stdlib reindex (~hundreds
    // of .rbs files) would stall every query for several seconds during cold
    // start — the workspace cold-index avoids this with per-file locking, and the
    // stdlib path must too.
    const max_size = ctx.server_ptr.max_file_size.load(.monotonic);
    const BATCH = 16;
    var bi: usize = 0;
    while (bi < stdlib_const.len) : (bi += BATCH) {
        if (ctx.server_ptr.bg_cancelled.load(.acquire)) return;
        const end = @min(bi + BATCH, stdlib_const.len);
        ctx.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
        indexer.reindex(db, stdlib_const[bi..end], true, alloc, max_size, null) catch |e| {
            var ebuf3: [256]u8 = undefined;
            const emsg3 = std.fmt.bufPrint(&ebuf3, "refract: stdlib reindex failed: {s}", .{@errorName(e)}) catch "refract: stdlib reindex failed";
            ctx.server_ptr.sendLogMessage(2, emsg3);
            ctx.server_ptr.db_mutex.unlock(std.Options.debug_io);
            return;
        };
        ctx.server_ptr.db_mutex.unlock(std.Options.debug_io);
    }
    ctx.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
    setMetaInt(db, "stdlib_rbs_indexed", 1, alloc);
    ctx.server_ptr.db_mutex.unlock(std.Options.debug_io);
    var sbuf: [128]u8 = undefined;
    const smsg = std.fmt.bufPrint(&sbuf, "refract: indexed {d} stdlib RBS files", .{stdlib_const.len}) catch "refract: indexed stdlib RBS";
    ctx.server_ptr.sendLogMessage(3, smsg);
}

/// Return freed heap pages to the OS. glibc's malloc keeps large freed arenas on
/// its own freelist, so RSS stays high after the cold-index workers exit and free
/// their arenas — malloc_trim forces the release. No-op off glibc (musl has no
/// malloc_trim; the extern is only declared under the comptime guard so non-glibc
/// targets never reference the symbol).
pub fn mallocTrim() void {
    if (comptime builtin.os.tag == .linux and builtin.abi == .gnu) {
        const trim = struct {
            extern "c" fn malloc_trim(pad: usize) c_int;
        };
        _ = trim.malloc_trim(0);
    }
}

/// Current resident set size in bytes, or 0 if unavailable. Linux-only
/// (`/proc/self/statm` field 2 = resident pages). Used only under
/// REFRACT_INIT_PROFILE for peak attribution.
fn readRssBytes() usize {
    if (comptime builtin.os.tag != .linux) return 0;
    var buf: [256]u8 = undefined;
    const f = std.Io.Dir.cwd().openFile(std.Options.debug_io, "/proc/self/statm", .{}) catch return 0;
    defer f.close(std.Options.debug_io);
    const n = f.readStreaming(std.Options.debug_io, &.{buf[0..]}) catch return 0;
    var it = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
    _ = it.next() orelse return 0; // total program size
    const res = it.next() orelse return 0; // resident pages
    const pages = std.fmt.parseInt(usize, std.mem.trim(u8, res, " \n"), 10) catch return 0;
    return pages * std.heap.pageSize();
}

/// Available RAM in bytes from `/proc/meminfo` MemAvailable, or 0 if unknown.
/// Drives the memory-aware worker-count floor on constrained hosts.
fn readAvailableRamBytes() usize {
    if (comptime builtin.os.tag != .linux) return 0;
    var buf: [4096]u8 = undefined;
    const f = std.Io.Dir.cwd().openFile(std.Options.debug_io, "/proc/meminfo", .{}) catch return 0;
    defer f.close(std.Options.debug_io);
    const n = f.readStreaming(std.Options.debug_io, &.{buf[0..]}) catch return 0;
    var lines = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            var toks = std.mem.tokenizeScalar(u8, line["MemAvailable:".len..], ' ');
            const kb_str = toks.next() orelse return 0;
            const kb = std.fmt.parseInt(usize, kb_str, 10) catch return 0;
            return kb * 1024;
        }
    }
    return 0;
}

pub fn bgWorkerFn(wctx: BgWorkerCtx) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    // Per-worker in-memory DB for the parse phase; no mutex needed during parse
    const mem_db = db_mod.Db.open(":memory:") catch return;
    defer mem_db.close();
    mem_db.init_schema() catch return;
    // Cold-index RAM bound: without a periodic trim each worker retains the
    // high-water of its biggest file (arena + in-mem DB freelist) for its whole
    // lifetime; N workers × that is the transient peak RSS. Trim on a file-count
    // cadence (and immediately if the arena blows past its cap) so the footprint
    // stays bounded while the workers keep running in parallel. See limits.zig.
    var processed: usize = 0;
    var commits_since_ckpt: usize = 0;
    while (wctx.queue.pop()) |work| {
        processed += 1;
        if (processed % limits.RSS_TRIM_BATCH == 0 or arena.queryCapacity() > limits.WORKER_ARENA_CAP_BYTES) {
            // Prior iteration already reset (retain_capacity); free_all now returns
            // the retained high-water to the OS. VACUUM compacts the in-memory DB's
            // page freelist (rows are already cleared per file via DELETE FROM files).
            _ = arena.reset(.free_all);
            mem_db.exec("VACUUM") catch {};
        }
        // Count every consumed work item, regardless of skip/error/success.
        // The cold-index poll loop watches this counter; if skips don't count,
        // it spins until bg_cancelled fires.
        defer _ = wctx.bg_ctx.progress_done.fetchAdd(1, .monotonic);
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
            // Bound WAL growth during the burst: left alone the shared-DB WAL
            // accumulates every insert until the maintenance checkpoint, ballooning
            // to the full index size in memory (wal-index/shm) and on disk. A
            // PASSIVE checkpoint on a commit cadence keeps it small without blocking
            // readers. Cheap and already under db_mutex here.
            commits_since_ckpt += 1;
            if (commits_since_ckpt >= limits.RSS_TRIM_BATCH) {
                commits_since_ckpt = 0;
                shared_db.exec("PRAGMA wal_checkpoint(PASSIVE)") catch {};
            }
        }
        // Clear mem_db for next file (CASCADE handles all child tables)
        mem_db.exec("DELETE FROM files") catch {}; // cleanup
        _ = arena.reset(.retain_capacity);
    }
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
        // ~1s debounce (13 × 75ms): cheap HEAD stat → reconcile on branch switch.
        server.git_check_tick +%= 1;
        if (server.git_check_tick % 13 == 0) server.maybeReconcileBranch();
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
        diagnostics_mod.writeDiagItems(server, w, prism_diags, diag_source, &first, path);
        diagnostics_mod.writeDiagItems(server, w, rubocop_diags, diag_source, &first, path);
        w.writeAll("]}}") catch continue;
        const json = aw.toOwnedSlice() catch continue;
        defer server.alloc.free(json);
        server.sendNotification(json);
    }
}

pub fn ensureRefractDir(root_path: []const u8, alloc: std.mem.Allocator) !void {
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

pub const IndexWork = struct {
    path: []const u8,
    is_gem: bool = false,
};

pub const WorkQueue = struct {
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

    pub fn markDone(self: *WorkQueue) void {
        self.mu.lockUncancelable(std.Options.debug_io);
        self.done = true;
        self.cond.broadcast(std.Options.debug_io);
        self.mu.unlock(std.Options.debug_io);
    }

    pub fn deinit(self: *WorkQueue) void {
        self.items.deinit(std.heap.c_allocator);
    }
};

pub const BgWorkerCtx = struct {
    bg_ctx: *BgCtx,
    queue: *WorkQueue,
};

pub const WarmupCtx = struct {
    server_ptr: *Server,

    pub fn run(self: *WarmupCtx) void {
        defer std.heap.c_allocator.destroy(self);
        rebuildHotIndex(self.server_ptr);
    }
};

pub const BgCtx = struct {
    root_path: []u8,
    server_ptr: *Server,
    disable_gem_index: bool,
    extra_exclude_dirs: []const []const u8 = &.{},
    gitignore_negations: []const []const u8 = &.{},
    bundle_timeout_ms: u64 = 15_000,
    max_workers: usize = limits.DEFAULT_COLD_INDEX_WORKERS,
    index_failures: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    progress_done: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    io: std.Io = std.Options.debug_io,

    // Drain a path list through the parallel worker pool: workers parse (CPU-bound)
    // outside db_mutex and grab it briefly PER FILE to commit, so queries interleave
    // and the LSP stays responsive during indexing. Used for the workspace cold-index
    // AND gem/RBS indexing — the latter previously held db_mutex for the entire
    // reindex, blocking every query for seconds on gem-heavy repos.
    fn indexPathsViaWorkers(self: *BgCtx, paths: []const []const u8, is_gem: bool, report_progress: bool, label: []const u8) void {
        const total_paths = paths.len;
        if (total_paths == 0) return;
        const db = self.server_ptr.db;
        const cpu_count = std.Thread.getCpuCount() catch 4;
        const desired_workers = @min(@max(cpu_count, 1), self.max_workers);
        // Memory-aware floor: each worker's transient footprint is bounded by the
        // trims in bgWorkerFn, so we can divide available RAM by that estimate to
        // avoid oversubscribing memory on constrained hosts (containers, CI). Only
        // lowers the pool when RAM is genuinely scarce; a roomy host keeps the full
        // CPU/`--max-workers` count. 0 (unknown RAM) disables the floor.
        const avail_ram = readAvailableRamBytes();
        const ram_cap: usize = if (avail_ram > 0)
            @max(1, avail_ram / limits.PER_WORKER_RAM_ESTIMATE_BYTES)
        else
            desired_workers;
        const num_workers: usize = @min(@min(desired_workers, ram_cap), total_paths);
        if (num_workers == 0) return;

        const profiling = std.c.getenv("REFRACT_INIT_PROFILE") != null;
        const rss_start = if (profiling) readRssBytes() else 0;

        std.debug.print("refract: {s} start: {d} files, {d} workers\n", .{ label, total_paths, num_workers });
        self.index_failures.store(0, .monotonic);

        const ProgressCtx = struct {
            server: *Server,
            fn report(ctx_opaque: *anyopaque, done: usize, total: usize, path: []const u8) void {
                const self_pg: *@This() = @ptrCast(@alignCast(ctx_opaque));
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
        const progress_cb = indexer.ProgressCallback{ .ctx = &pg_ctx, .report = ProgressCtx.report };

        var queue = WorkQueue{};
        defer queue.deinit();
        var dropped: usize = 0;
        for (paths) |p| {
            if (!queue.push(.{ .path = p, .is_gem = is_gem })) dropped += 1;
        }
        queue.markDone();
        if (dropped > 0) {
            var drop_buf: [160]u8 = undefined;
            const drop_msg = std.fmt.bufPrint(&drop_buf, "refract: index queue full — {d} of {d} paths not indexed (exceeds cap)", .{ dropped, paths.len }) catch "refract: index queue full — some paths not indexed";
            self.server_ptr.sendLogMessage(2, drop_msg);
        }

        self.progress_done.store(0, .monotonic);
        const wctx = BgWorkerCtx{ .bg_ctx = self, .queue = &queue };
        var workers = std.ArrayList(std.Thread).empty;
        defer workers.deinit(std.heap.c_allocator);
        var w: usize = 0;
        while (w < num_workers) : (w += 1) {
            const t = std.Thread.spawn(.{}, bgWorkerFn, .{wctx}) catch break;
            workers.append(std.heap.c_allocator, t) catch {
                t.detach();
                break;
            };
        }

        if (workers.items.len > 0) {
            var last_reported: usize = 0;
            while (true) {
                const done_now = self.progress_done.load(.monotonic);
                if (report_progress and done_now != last_reported) {
                    const sample_path = if (done_now > 0 and done_now <= total_paths)
                        paths[done_now - 1]
                    else
                        paths[0];
                    progress_cb.report(progress_cb.ctx, done_now, total_paths, sample_path);
                    last_reported = done_now;
                }
                if (done_now >= total_paths) break;
                if (self.server_ptr.bg_cancelled.load(.acquire)) break;
                var poll_ts: std.c.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
                _ = std.c.nanosleep(&poll_ts, null);
            }
            for (workers.items) |t| t.join();
            // Workers have exited and freed their arenas + in-mem DBs; force glibc
            // to return those pages to the OS so peak RSS actually drops after the
            // burst instead of lingering on malloc's freelist. Also checkpoint the
            // shared WAL back into the main DB now that inserts are done.
            db.exec("PRAGMA wal_checkpoint(TRUNCATE)") catch {};
            mallocTrim();
            const done_final = self.progress_done.load(.monotonic);
            const fail_n = self.index_failures.load(.monotonic);
            if (self.server_ptr.bg_cancelled.load(.acquire))
                std.debug.print("refract: {s} CANCELLED at {d}/{d} files ({d} failures)\n", .{ label, done_final, total_paths, fail_n })
            else
                std.debug.print("refract: {s} complete: {d}/{d} files ({d} failures)\n", .{ label, done_final, total_paths, fail_n });
            if (profiling) {
                const rss_end = readRssBytes();
                std.debug.print("refract_profile: {s} rss start={d}MB end={d}MB workers={d}\n", .{ label, rss_start / (1024 * 1024), rss_end / (1024 * 1024), num_workers });
            }
        } else {
            // Worker spawn failed entirely — fall back to serial reindex on the main thread.
            self.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
            indexer.reindex(db, paths, is_gem, std.heap.c_allocator, self.server_ptr.max_file_size.load(.monotonic), if (report_progress) progress_cb else null) catch |err| {
                var ebuf: [256]u8 = undefined;
                const emsg = std.fmt.bufPrint(&ebuf, "refract: indexing failed: {s}", .{@errorName(err)}) catch "refract: indexing failed";
                self.server_ptr.sendLogMessage(2, emsg);
            };
            self.server_ptr.db_mutex.unlock(std.Options.debug_io);
        }
    }

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

        // B3 opt-in Ruby-at-index hybrid: when `--rbi-gen`/`rbiGen` is set, run tapioca to
        // emit Rails-DSL RBI into the tree BEFORE the scan, so the generated `.rbi` is picked
        // up by the normal scanner/Prism path. No-op when the flag is off or no bundle exists.
        if (self.server_ptr.rbi_gen.load(.monotonic)) {
            self.server_ptr.sendLogMessage(3, "refract: generating RBI (tapioca)…");
            gems.generateProjectRbi(self.io, self.root_path, alloc, 600 * std.time.ns_per_s);
        }

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

        // Re-filter against deleted_paths just before fanning out — type=3 grabs
        // db_mutex serially. Workers grab db_mutex per-file in their commit phase,
        // so any type=3 that runs concurrently is observed at filter time.
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

        // Workspace cold-index via the shared parallel worker pool — per-file
        // db_mutex so go-to-def/hover stay responsive while it runs.
        self.indexPathsViaWorkers(refiltered_paths.items, false, true, "cold-index");

        // Bind refs.def_id across the freshly cold-indexed workspace. Per-file commits
        // can't resolve cross-file references (the full symbol table isn't present
        // until every file lands), so the binding pass runs once here. Reads use the
        // lockless read_db, so holding db_mutex for the walk doesn't stall queries.
        if (!self.server_ptr.bg_cancelled.load(.acquire)) self.server_ptr.resolveWorkspaceRefs();

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

        // Detect a Rails/ActiveSupport project so framework-receiver completion
        // (params/request/cookies/…) fires only where those helpers exist. Cheap,
        // independent of the mtime-gated gem index below.
        if (!self.server_ptr.has_rails.load(.monotonic)) {
            if (std.fmt.allocPrint(alloc, "{s}/Gemfile.lock", .{self.root_path})) |lp| {
                defer alloc.free(lp);
                if (std.Io.Dir.cwd().readFileAlloc(self.io, lp, alloc, std.Io.Limit.limited(4 * 1024 * 1024))) |buf| {
                    defer alloc.free(buf);
                    if (std.mem.indexOf(u8, buf, "\n    rails ") != null or
                        std.mem.indexOf(u8, buf, "actionpack ") != null or
                        std.mem.indexOf(u8, buf, "activesupport ") != null or
                        std.mem.indexOf(u8, buf, "railties ") != null)
                    {
                        self.server_ptr.has_rails.store(true, .monotonic);
                    }
                } else |_| {}
            } else |_| {}
        }

        // Parameter-type backfill: type otherwise-untyped positional params from the
        // dominant captured call-site argument type (completion-only, confidence 50 —
        // semantic.zig reads params for arity only, never type_hint, so this is FP-safe).
        // Runs once after the workspace cold index, before the hot rebuild.
        if (!self.server_ptr.bg_cancelled.load(.acquire)) {
            self.server_ptr.db_mutex.lockUncancelable(std.Options.debug_io);
            db.exec(
                \\UPDATE params SET type_hint = (
                \\    SELECT c.arg_type FROM call_arg_types c
                \\    WHERE c.callee = (SELECT name FROM symbols WHERE id = params.symbol_id)
                \\      AND c.position = params.position
                \\    GROUP BY c.arg_type ORDER BY COUNT(*) DESC LIMIT 1
                \\  ), confidence = 50
                \\WHERE type_hint IS NULL
                \\  AND kind NOT IN ('keyword','keyword_rest','rest','block')
                \\  AND (SELECT name FROM symbols WHERE id = params.symbol_id) IN (SELECT callee FROM call_arg_types)
            ) catch {};
            // Repair mis-singularized schema-column parents: a table like `statuses`
            // singularizes to `Statuse` (bare strip-`s`) when the real model is `Status`
            // — the generic singularizer can't disambiguate `-ses` (statuses→status vs
            // houses→house) without a dictionary. Reality-check instead: if a member's
            // parent model isn't an indexed class but the trailing-`e`-trimmed form is
            // (`Statuse`→`Status`, `Addresse`→`Address`), re-parent to the real model.
            db.exec(
                \\UPDATE symbols SET parent_name = substr(parent_name, 1, length(parent_name) - 1)
                \\WHERE parent_name LIKE '%e'
                \\  AND parent_name NOT IN (SELECT name FROM symbols WHERE kind IN ('class','module'))
                \\  AND substr(parent_name, 1, length(parent_name) - 1) IN (SELECT name FROM symbols WHERE kind IN ('class','module'))
            ) catch {};
            // Post-index flow-typing: resolve deferred `@ivar = recv.method` typings over the
            // now-complete table (receiver-scoped, deterministic). Replaces the racy single-pass
            // index-write lookup. Completion-only (confidence 50 < the 70 diagnostic gate).
            indexer.runFlowTypingPass(db);
            self.server_ptr.db_mutex.unlock(std.Options.debug_io);
        }

        // Always index bundled RBS — cheap, idempotent (keyed by <bundled>/... path).
        // Ensures fresh hover/completion coverage after binary upgrades, regardless of DB age.
        if (!self.server_ptr.bg_cancelled.load(.acquire)) {
            indexBundledRbsLsp(self);
        }

        // Rebuild the hot index now that the workspace + bundled RBS are
        // indexed. System stdlib RBS + gem indexing below add more, but
        // blocking query handlers on those is wasteful — what most queries
        // need (workspace symbols + Time/String/Integer/etc.) is already in
        // place. Incremental rebuilds catch the rest later.
        if (!self.server_ptr.bg_cancelled.load(.acquire)) {
            rebuildHotIndex(self.server_ptr);
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
            // The is_gem=1 clear also drops the bundled RBS (curated stdlib/Rails stubs
            // are stored is_gem=1). Re-add them immediately — BEFORE the slow gem worker
            // indexing — so their curated surfaces (e.g. the `respond_to |format|`
            // Collector) are present even if the gem index is still running or the
            // session ends early.
            indexer.ensureBundledRbs(db);
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

            // Index gems via the shared worker pool (per-file db_mutex) so queries
            // stay responsive — previously this held db_mutex for the whole reindex,
            // blocking every go-to-def for seconds on gem-heavy repos.
            self.indexPathsViaWorkers(gem_const_paths, true, true, "gem-index");
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
                        self.indexPathsViaWorkers(rbs_const, true, false, "rbs-collection");
                        var rbuf: [128]u8 = undefined;
                        const rmsg = std.fmt.bufPrint(&rbuf, "refract: indexed {d} RBS collection files", .{rbs_const.len}) catch "refract: indexed RBS collection";
                        self.server_ptr.sendLogMessage(3, rmsg);
                    }
                } else |_| {}
            }
        }

        self.server_ptr.bg_indexing_done.store(true, .release);
        rebuildHotIndex(self.server_ptr);

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
            const incr_did_index = filtered.items.len > 0;
            if (incr_did_index) {
                indexer.reindex(db, filtered.items, false, alloc, self.server_ptr.max_file_size.load(.monotonic), null) catch |e| {
                    var ebuf: [256]u8 = undefined;
                    const emsg = std.fmt.bufPrint(&ebuf, "refract: incremental reindex failed: {s}", .{@errorName(e)}) catch "refract: incremental reindex failed";
                    self.server_ptr.sendLogMessage(2, emsg);
                };
            }
            self.server_ptr.db_mutex.unlock(std.Options.debug_io);
            if (incr_did_index) rebuildHotIndex(self.server_ptr);
            _ = arena.reset(.retain_capacity);
        }
    }
};
