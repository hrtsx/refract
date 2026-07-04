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
const uriToPath = S.uriToPath;
const rebuildHotIndex = S.rebuildHotIndex;
const server_indexing = @import("server_indexing.zig");
const BgCtx = server_indexing.BgCtx;
const WarmupCtx = server_indexing.WarmupCtx;
const WorkQueue = server_indexing.WorkQueue;
const BgWorkerCtx = server_indexing.BgWorkerCtx;
const IndexWork = server_indexing.IndexWork;
const bgWorkerFn = server_indexing.bgWorkerFn;
const flushWorkerFn = server_indexing.flushWorkerFn;
const rubocopWorkerFn = server_indexing.rubocopWorkerFn;
const indexBundledRbsLsp = server_indexing.indexBundledRbsLsp;
const indexStdlibRbsLsp = server_indexing.indexStdlibRbsLsp;
const ensureRefractDir = server_indexing.ensureRefractDir;
const ReadTxn = S.ReadTxn;
const logOomOnce = S.logOomOnce;
const getMetaInt = S.getMetaInt;
const setMetaInt = S.setMetaInt;
const emitSelRange = S.emitSelRange;
const computeDiagCol = S.computeDiagCol;
const serverLogSinkCb = S.serverLogSinkCb;

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
    s.prePrepareHotStatements();
    s.openReadDb();
    return s;
}

pub fn deinit(self: *Server) void {
    if (self.git_head_token) |t| {
        self.alloc.free(t);
        self.git_head_token = null;
    }
    if (self.git_head_path) |p| {
        self.alloc.free(p);
        self.git_head_path = null;
    }
    if (self.sorbet_worker_handle) |w| {
        w.requestStop();
        if (self.sorbet_worker_thread) |t| {
            t.join();
            self.sorbet_worker_thread = null;
        }
        w.deinitQueue();
        self.alloc.destroy(w);
        self.sorbet_worker_handle = null;
    }
    if (self.steep_worker_handle) |w| {
        w.requestStop();
        if (self.steep_worker_thread) |t| {
            t.join();
            self.steep_worker_thread = null;
        }
        w.deinitQueue();
        self.alloc.destroy(w);
        self.steep_worker_handle = null;
    }
    if (self.sorbet_handle) |*b| b.deinit();
    self.sorbet_handle = null;
    if (self.steep_handle) |*b| b.deinit();
    self.steep_handle = null;
    if (self.llm_config) |*c| c.deinit(self.alloc);
    self.llm_config = null;
    if (self.recorder) |*r| r.deinit();
    self.recorder = null;
    if (self.plugin_host) |*ph| ph.deinit();
    self.plugin_host = null;
    self.registry.deinit(self.alloc);
    self.bg_cancelled.store(true, .seq_cst);
    if (self.bg_thread) |t| t.join();
    if (self.warmup_thread) |t| {
        t.join();
        self.warmup_thread = null;
    }
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
    // Teardown free (a writer, not a reader — the twin of rebuildHotIndex's
    // swap): loads + frees + stores null under hot_mu. Not routed through
    // lockHot because it must free regardless of hot_index_enabled, which
    // lockHot short-circuits on — gating here would leak an index built before
    // the flag was cleared.
    self.hot_mu.lockUncancelable(std.Options.debug_io);
    if (self.hot.load(.acquire)) |h| {
        h.deinit();
        self.alloc.destroy(h);
        self.hot.store(null, .release);
    }
    self.hot_mu.unlock(std.Options.debug_io);
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
    var read_stmt_it = self.read_stmt_cache.valueIterator();
    while (read_stmt_it.next()) |cs| cs.finalize();
    self.read_stmt_cache.deinit(self.alloc);
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
    for (self.disabled_diag_codes.items) |c| self.alloc.free(c);
    self.disabled_diag_codes.deinit(self.alloc);
    for (self.env_keys_cache.items) |k| self.alloc.free(k);
    self.env_keys_cache.deinit(self.alloc);
    if (self.read_db) |rdb| rdb.close();
    self.db.close();
    self.alloc.free(self.db_pathz);
}

pub fn requestShutdown(self: *Server) void {
    self.bg_cancelled.store(true, .seq_cst);
    self.rubocop_thread_done.store(true, .seq_cst);
    self.rubocop_queue_cond.signal(std.Options.debug_io);
    self.flush_thread_done.store(true, .seq_cst);
    self.db.close();
}

pub fn notifyFileTouched(self: *Server, path: []const u8) void {
    if (self.sorbet_worker_handle) |w| w.enqueueFile(path);
    if (self.steep_worker_handle) |w| w.enqueueFile(path);
}

pub fn resolveWorkspaceRefs(self: *Server) void {
    self.db_mutex.lockUncancelable(std.Options.debug_io);
    defer self.db_mutex.unlock(std.Options.debug_io);
    var ids = std.ArrayList(i64).empty;
    defer ids.deinit(self.alloc);
    if (self.db.prepare("SELECT id FROM files WHERE is_gem = 0")) |s| {
        defer s.finalize();
        while (s.step() catch false) ids.append(self.alloc, s.column_int(0)) catch break;
    } else |_| {}
    if (ids.items.len == 0) return;
    var memo = std.StringHashMap(i64).init(self.alloc);
    defer {
        var it = memo.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        memo.deinit();
    }
    self.db.begin() catch return;
    for (ids.items) |fid| {
        if (self.bg_cancelled.load(.acquire)) break;
        indexer.resolveRefsForFile(self.db, fid, self.alloc, &memo);
    }
    self.db.commit() catch self.db.rollback() catch {};
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

pub fn recordGitHead(self: *Server) void {
    const root = self.root_path orelse return;
    const head = git_branch.readHead(self.alloc, root) orelse return;
    defer head.deinit();
    const token = std.fmt.allocPrint(self.alloc, "{s}\x1f{s}", .{ head.branch orelse "(detached)", head.commit }) catch return;

    self.db_mutex.lockUncancelable(self.io);
    self.setMetaStr("git_branch", head.branch orelse "(detached)");
    self.setMetaStr("git_commit", head.commit);
    const pid = git_branch.projectId(self.alloc, root);
    defer self.alloc.free(pid);
    self.setMetaStr("project_id", pid);
    self.db_mutex.unlock(self.io);

    if (self.git_head_token) |old| self.alloc.free(old);
    self.git_head_token = token;
    if (self.git_head_path == null) self.git_head_path = git_branch.headStatPath(self.alloc, root);
    if (self.git_head_path) |p| {
        if (std.Io.Dir.cwd().statFile(self.io, p, .{})) |st| {
            self.git_head_mtime = st.mtime.toMilliseconds();
        } else |_| {}
    }
}

pub fn maybeReconcileBranch(self: *Server) void {
    const path = self.git_head_path orelse return;
    const st = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return;
    const m = st.mtime.toMilliseconds();
    if (m == self.git_head_mtime) return;
    self.git_head_mtime = m;

    const root = self.root_path orelse return;
    const token = git_branch.readToken(self.alloc, root) orelse return;
    const changed = if (self.git_head_token) |old| !std.mem.eql(u8, old, token) else true;
    if (!changed) {
        self.alloc.free(token);
        return;
    }
    self.alloc.free(token);
    self.sendLogMessage(3, "refract: git HEAD changed — reconciling index to current checkout");
    // startBgIndexer cancels+rejoins any running pass, then re-scans and
    // runs cleanupStale; recordGitHead refreshes the baseline token+meta.
    self.startBgIndexer();
    self.recordGitHead();
}

pub fn startWarmupIndexer(self: *Server) void {
    if (!self.warmup_enabled.load(.monotonic)) return;
    if (self.hot.load(.acquire) != null) return;

    const warmup_start = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds();
    rebuildHotIndex(self);
    const warmup_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() - warmup_start;

    if (warmup_ms > 200) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "refract: synchronous warmup took {d}ms (exceeded 200ms budget)", .{warmup_ms}) catch "refract: synchronous warmup exceeded budget";
        self.sendLogMessage(2, msg);
    }
}

pub fn spawnTypeWorker(self: *Server, kind: sorbet_bridge.ServerKind) void {
    const bridge_ptr: *sorbet_bridge.Bridge = switch (kind) {
        .sorbet => if (self.sorbet_handle) |*b| b else return,
        .steep => if (self.steep_handle) |*b| b else return,
    };
    const w = self.alloc.create(sorbet_worker.Worker) catch return;
    w.* = .{
        .bridge = bridge_ptr,
        .db = self.db,
        .db_mu = &self.db_mutex,
        .kind = kind,
        .alloc = self.alloc,
        .done = std.atomic.Value(bool).init(false),
    };
    const t = std.Thread.spawn(.{}, sorbet_worker.Worker.run, .{w}) catch {
        self.alloc.destroy(w);
        return;
    };
    switch (kind) {
        .sorbet => {
            self.sorbet_worker_handle = w;
            self.sorbet_worker_thread = t;
        },
        .steep => {
            self.steep_worker_handle = w;
            self.steep_worker_thread = t;
        },
    }
}

pub fn openReadDb(self: *Server) void {
    if (self.read_db != null) return;
    if (std.mem.indexOf(u8, self.db_pathz, ":memory:") != null) return;
    self.read_db = db_mod.Db.openReadOnly(self.db_pathz) catch null;
}

pub fn reopenReadDb(self: *Server) void {
    if (self.read_db) |rdb| {
        var it = self.read_stmt_cache.valueIterator();
        while (it.next()) |cs| cs.finalize();
        self.read_stmt_cache.clearRetainingCapacity();
        rdb.close();
        self.read_db = null;
    }
    self.openReadDb();
}

pub fn prePrepareHotStatements(self: *Server) void {
    _ = self.cachedStmt("SELECT id FROM files WHERE path = ?") catch {};
    _ = self.cachedStmt("SELECT id FROM symbols WHERE file_id = ? AND kind IN ('class','module') LIMIT 1") catch {};
    _ = self.cachedStmt("SELECT s.id, s.name, s.kind, s.line, s.col, f.path FROM symbols s JOIN files f ON s.file_id=f.id WHERE s.name=? AND s.kind IN ('class','module','classdef') LIMIT 1") catch {};
    _ = self.cachedStmt("SELECT p.name FROM params p JOIN symbols s ON p.symbol_id=s.id WHERE s.name=? AND s.kind='def' AND p.kind='keyword' ORDER BY p.position LIMIT 20") catch {};
    _ = self.cachedStmt("SELECT module_name FROM mixins WHERE class_id = ? AND kind IN ('include','prepend') ORDER BY rowid") catch {};
    _ = self.cachedStmt("SELECT DISTINCT name FROM symbols WHERE file_id = ? LIMIT 100") catch {};
    _ = self.cachedStmt("SELECT DISTINCT name FROM symbols LIMIT 1000") catch {};
    _ = self.cachedStmt("SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND line<=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1") catch {};
    _ = self.cachedStmt("SELECT name FROM refs WHERE name = ? LIMIT 100") catch {};
    _ = self.cachedStmt("SELECT s.id, s.name, s.kind, s.line, s.col, f.path FROM symbols s JOIN files f ON s.file_id=f.id WHERE s.name LIKE ? ESCAPE '\\' LIMIT 50") catch {};
    // PR2: pre-prepare def + comp hot-path queries. Matches the SQL paths
    // in navigation.zig:queryAndEmitDefinitions and
    // completion.zig:completeGeneral; cap def-exact at 20 (was unbounded).
    _ = self.cachedStmt(
        \\SELECT s.name, s.line, s.col, f.path
        \\FROM symbols s JOIN files f ON s.file_id = f.id
        \\WHERE s.name = ? LIMIT 20
    ) catch {};
    _ = self.cachedStmt(
        \\SELECT s.name, s.kind,
        \\  (SELECT GROUP_CONCAT(
        \\    CASE p.kind WHEN 'keyword' THEN p.name||':' WHEN 'rest' THEN '*'||p.name
        \\    WHEN 'keyword_rest' THEN '**'||p.name WHEN 'block' THEN '&'||p.name
        \\    ELSE p.name END, ', ')
        \\   FROM params p WHERE p.symbol_id=s.id ORDER BY p.position),
        \\  s.doc
        \\FROM symbols s WHERE s.name LIKE ? ESCAPE '\'
        \\ORDER BY CASE WHEN s.name LIKE ? ESCAPE '\' THEN 0 ELSE 1 END, length(s.name), s.name LIMIT 200
    ) catch {};
}

pub fn setMetaStr(self: *Server, key: []const u8, val: []const u8) void {
    const stmt = self.db.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)") catch return;
    defer stmt.finalize();
    stmt.bind_text(1, key);
    stmt.bind_text(2, val);
    _ = stmt.step() catch {};
}
