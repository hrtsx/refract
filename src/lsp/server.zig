const std = @import("std");
const builtin = @import("builtin");
const build_meta = @import("build_meta");
const db_mod = @import("../db.zig");
const limits = @import("limits.zig");
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
const server_indexing = @import("server_indexing.zig");
const BgCtx = server_indexing.BgCtx;
const WorkQueue = server_indexing.WorkQueue;
const BgWorkerCtx = server_indexing.BgWorkerCtx;
const WarmupCtx = server_indexing.WarmupCtx;
const IndexWork = server_indexing.IndexWork;
const bgWorkerFn = server_indexing.bgWorkerFn;
const flushWorkerFn = server_indexing.flushWorkerFn;
const rubocopWorkerFn = server_indexing.rubocopWorkerFn;
const indexBundledRbsLsp = server_indexing.indexBundledRbsLsp;
const indexStdlibRbsLsp = server_indexing.indexStdlibRbsLsp;
const ensureRefractDir = server_indexing.ensureRefractDir;
pub const init_caps_before_enc = server_util.init_caps_before_enc;
pub const init_caps_after_enc = server_util.init_caps_after_enc;

pub const ruby_block_keywords = [_][]const u8{ "if ", "unless ", "case ", "while ", "until ", "begin", "for " };
pub const empty_json_array = "[]";
pub const MAX_INCR_PATHS: usize = 10_000;
pub const MAX_DELETED_PATHS: usize = 10_000;
pub const OPEN_DOC_CACHE_SIZE: usize = 200;
pub const LOG_FILE_SIZE_LIMIT: usize = 10 * 1024 * 1024;
pub const WORKSPACE_SYMBOL_LIMIT: usize = 500;
pub const USER_ERROR_RATELIMIT_MS: i64 = 30_000;
pub const INCR_WATCH_SLEEP_MS: u64 = 10;

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

const hot_index_management = @import("hot_index_management.zig");
pub const rebuildHotIndex = hot_index_management.rebuildHotIndex;

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

pub const MAX_QUEUE_SIZE: usize = 50_000;

pub fn serverLogSinkCb(ctx: ?*anyopaque, level: u8, msg: []const u8) void {
    const srv_ptr = ctx orelse return;
    const srv: *Server = @ptrCast(@alignCast(srv_ptr));
    srv.sendLogMessage(level, msg);
}

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

/// Lock guard returned by `Server.lockHot`. Carries the hot-index pointer that
/// is valid only while `locked` is true. `deinit` releases the lock (idempotent
/// with `unlock`, which a caller uses to drop the lock early). See `lockHot`.
pub const HotGuard = struct {
    server: *Server,
    hot: ?*hot_index_mod.HotIndex,
    locked: bool,

    pub fn unlock(self: *HotGuard) void {
        if (self.locked) {
            self.server.hot_mu.unlock(std.Options.debug_io);
            self.locked = false;
        }
    }

    pub fn deinit(self: *HotGuard) void {
        self.unlock();
    }
};

pub const Server = struct {
    db: db_mod.Db,
    db_pathz: [:0]u8,
    // Dedicated read-only connection for the query path. WAL lets it read a
    // committed snapshot concurrently with the writer threads, so reads never
    // block on db_mutex. null for in-memory DBs (a 2nd :memory: connection
    // opens a *different* empty DB) — those fall back to the writer conn under
    // db_mutex via beginRead(). Single-consumer: touched only by the main
    // dispatch thread (MCP + hot-index use their own connections).
    read_db: ?db_mod.Db = null,
    read_stmt_cache: std.AutoHashMapUnmanaged(usize, db_mod.CachedStmt) = .{},
    bg_thread: ?std.Thread,
    warmup_thread: ?std.Thread = null,
    warmup_thread_mu: std.Io.Mutex = std.Io.Mutex.init,
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
    hot_mu: std.Io.Mutex = std.Io.Mutex.init,
    hot: std.atomic.Value(?*hot_index_mod.HotIndex) = std.atomic.Value(?*hot_index_mod.HotIndex).init(null),
    hot_index_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    warmup_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    stdout_writer: ?*std.Io.Writer,
    disable_gem_index: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    disable_rubocop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    disable_type_checker: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    rbi_gen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Set during cold-index when Gemfile.lock names rails/actionpack/activesupport;
    // gates Rails framework-receiver completion (params/request/…) off plain Ruby.
    has_rails: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    type_checker_severity: std.atomic.Value(u8) = std.atomic.Value(u8).init(2),
    type_checker_confidence: workspace_config.TypeCheckerConfidence = .{},
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
    max_workers: usize = limits.DEFAULT_COLD_INDEX_WORKERS,
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
    disabled_diag_codes: std.ArrayListUnmanaged([]u8) = .empty,
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
    // Branch-accuracy: last-seen git (branch,commit) token + the HEAD file path
    // we stat each flush tick. On change the flush worker re-kicks the bg
    // indexer, whose scan + cleanupStale reconciles the graph to the checkout.
    git_head_token: ?[]u8 = null,
    git_head_path: ?[]u8 = null,
    git_head_mtime: i64 = 0,
    git_check_tick: u32 = 0,
    env_keys_cache: std.ArrayListUnmanaged([]u8) = .empty,
    env_keys_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    env_keys_mu: std.Io.Mutex = std.Io.Mutex.init,
    registry: handler_registry.Registry = .{},
    recorder: ?observability.Recorder = null,
    plugin_host: ?plugin_host.Host = null,
    sorbet_handle: ?sorbet_bridge.Bridge = null,
    steep_handle: ?sorbet_bridge.Bridge = null,
    sorbet_worker_handle: ?*sorbet_worker.Worker = null,
    steep_worker_handle: ?*sorbet_worker.Worker = null,
    sorbet_worker_thread: ?std.Thread = null,
    steep_worker_thread: ?std.Thread = null,
    llm_config: ?llm_adapter.Config = null,

    pub const init = @import("server_lifecycle.zig").init;

    /// Open the lockless read-only connection for the query path. Best-effort:
    /// skipped for in-memory DBs and left null on failure (callers fall back to
    /// the writer connection under db_mutex). Safe to call after the writable
    /// connection has applied the schema (WAL/-shm exist by then).
    pub const openReadDb = @import("server_lifecycle.zig").openReadDb;

    /// Finalize + reopen the read connection after a structural change (DB file
    /// replaced, schema migrated, DELETE-all+VACUUM). Ordinary row writes don't
    /// need this — WAL keeps prepared read statements valid across commits.
    pub const reopenReadDb = @import("server_lifecycle.zig").reopenReadDb;

    pub const prePrepareHotStatements = @import("server_lifecycle.zig").prePrepareHotStatements;

    pub const spawnTypeWorker = @import("server_lifecycle.zig").spawnTypeWorker;

    /// Notify type-bridge workers that `path` was edited/saved. Called from
    /// document_sync.didSave/didChange. Workers debounce 500 ms before
    /// re-running phase 2/4 narrowed to that file.
    pub const notifyFileTouched = @import("server_lifecycle.zig").notifyFileTouched;

    /// Resolve refs.def_id for every workspace (non-gem) file after a cold index.
    /// Cross-file binding needs the full symbol table, so it can't run per-file
    /// during the parallel commit; this is the once-per-cold-index pass. A shared
    /// memo amortizes ancestor walks; queries stay live on the lockless read_db.
    pub const resolveWorkspaceRefs = @import("server_lifecycle.zig").resolveWorkspaceRefs;

    pub const requestShutdown = @import("server_lifecycle.zig").requestShutdown;

    pub const deinit = @import("server_lifecycle.zig").deinit;

    pub const startBgIndexer = @import("server_lifecycle.zig").startBgIndexer;

    pub const setMetaStr = @import("server_lifecycle.zig").setMetaStr;

    /// Read git HEAD, persist (branch, commit, project_id) into meta, and cache
    /// the token + HEAD stat path on the server. Call after each (re)index so
    /// the flush worker has a baseline to compare against. No-op outside a repo.
    pub const recordGitHead = @import("server_lifecycle.zig").recordGitHead;

    /// Cheap per-tick check from the flush worker: stat HEAD; on mtime change,
    /// re-read the (branch, commit) token; if it differs, re-kick the bg indexer
    /// to reconcile the derived graph to the new checkout before serving.
    pub const maybeReconcileBranch = @import("server_lifecycle.zig").maybeReconcileBranch;

    pub const startWarmupIndexer = @import("server_lifecycle.zig").startWarmupIndexer;

    /// Prepared-statement cache. Auto-routes by the per-thread read depth:
    /// inside a lockless read (read_depth > 0, set by beginRead) it prepares
    /// against the read-only connection + read_stmt_cache; otherwise (writers,
    /// :memory: fallback under db_mutex) it uses the writer connection. So the
    /// ~90 existing cachedStmt call sites need no edits — a read handler that
    /// opens a ReadTxn transparently runs every query on the read snapshot.
    /// The one blessed way to reach `*self.hot`. Bundles the enable-gate, the
    /// `hot_mu` acquire, and the pointer load so a reader physically cannot
    /// observe the pointer without holding the lock — `rebuildHotIndex` frees
    /// the old index under `hot_mu`, so a load-before-lock is a use-after-free
    /// (the segfault fixed in aa8c2e1). `hot` is non-null only while the lock is
    /// held. Usage:
    ///     var hg = self.lockHot();
    ///     defer hg.deinit();
    ///     if (hg.hot) |hot| { ... }
    /// A handler that must drop the lock early (before SQL round-trips) calls
    /// `hg.unlock()` once it is done dereferencing `hot`; `deinit` is idempotent.
    pub fn lockHot(self: *Server) HotGuard {
        if (!self.hot_index_enabled.load(.monotonic)) return .{ .server = self, .hot = null, .locked = false };
        self.hot_mu.lockUncancelable(std.Options.debug_io);
        return .{ .server = self, .hot = self.hot.load(.acquire), .locked = true };
    }

    pub fn cachedStmt(self: *Server, comptime sql: [*:0]const u8) !db_mod.CachedStmt {
        if (read_depth > 0) return self.readCachedStmt(sql);
        const key: usize = @intFromPtr(sql);
        if (self.stmt_cache.get(key)) |cs| {
            cs.reset();
            return cs;
        }
        const cs = try self.db.prepareRaw(sql);
        try self.stmt_cache.put(self.alloc, key, cs);
        return cs;
    }

    /// Prepared-statement cache for the read-only connection. Single-consumer
    /// (main dispatch thread). Only reached when read_db is non-null.
    pub fn readCachedStmt(self: *Server, comptime sql: [*:0]const u8) !db_mod.CachedStmt {
        const key: usize = @intFromPtr(sql);
        if (self.read_stmt_cache.get(key)) |cs| {
            cs.reset();
            return cs;
        }
        const cs = try self.read_db.?.prepareRaw(sql);
        try self.read_stmt_cache.put(self.alloc, key, cs);
        return cs;
    }

    /// The DB connection a read should use: the read-only snapshot inside a
    /// lockless ReadTxn, else the writer connection. Read handlers that hand a
    /// connection to a helper (e.g. resolveRequireTarget) pass `self.queryDb()`
    /// instead of `self.db`. Safe everywhere: outside a read (writers, write
    /// handlers) read_depth is 0 so it returns the writer connection unchanged.
    pub fn queryDb(self: *Server) db_mod.Db {
        return if (read_depth > 0) self.read_db.? else self.db;
    }

    /// Per-thread lockless-read nesting depth. Only the main dispatch thread
    /// ever raises it (via beginRead); writer threads keep it 0, so their
    /// cachedStmt/queryDb always target the writer connection. threadlocal — a
    /// reader on one thread can't perturb a writer on another.
    threadlocal var read_depth: u32 = 0;

    /// A read transaction over the query path. With a dedicated read_db it runs
    /// lock-free against the WAL snapshot (raising read_depth so cachedStmt +
    /// queryDb route to the read connection); for in-memory DBs (read_db null)
    /// it falls back to the writer connection under db_mutex. Usage:
    ///   var rt = self.beginRead(); defer rt.end();
    /// then keep using self.cachedStmt / self.queryDb as before. Reads only —
    /// never INSERT/UPDATE/DELETE or mutate shared state inside a ReadTxn.
    pub const ReadTxn = struct {
        srv: *Server,
        locked: bool,
        pub fn end(self: ReadTxn) void {
            if (self.locked) {
                self.srv.db_mutex.unlock(std.Options.debug_io);
            } else {
                read_depth -= 1;
            }
        }
    };

    pub fn beginRead(self: *Server) ReadTxn {
        if (self.read_db != null) {
            read_depth += 1;
            return .{ .srv = self, .locked = false };
        }
        self.db_mutex.lockUncancelable(std.Options.debug_io);
        return .{ .srv = self, .locked = true };
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

    pub const clientPosToOffset = @import("server_document_sync.zig").clientPosToOffset;

    pub const readSourceForUri = @import("server_document_sync.zig").readSourceForUri;

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

    pub const dispatch = @import("server_dispatch.zig").dispatch;

    pub const sendNotification = @import("server_notifications.zig").sendNotification;

    pub const logErr = @import("server_notifications.zig").logErr;

    pub const showUserError = @import("server_notifications.zig").showUserError;

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
        if (cfg.get("rbiGen")) |v| switch (v) {
            .bool => |b| {
                self.rbi_gen.store(b, .monotonic);
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

    pub const rotateLogIfNeeded = @import("server_notifications.zig").rotateLogIfNeeded;

    pub const sendLogMessage = @import("server_notifications.zig").sendLogMessage;

    pub const sendShowMessage = @import("server_notifications.zig").sendShowMessage;

    pub const sendLspLogMessage = @import("server_notifications.zig").sendLspLogMessage;

    pub const sendLspWindowMessage = @import("server_notifications.zig").sendLspWindowMessage;

    pub const sendProgressBegin = @import("server_notifications.zig").sendProgressBegin;

    pub const sendProgressEnd = @import("server_notifications.zig").sendProgressEnd;

    pub const sendProgressReport = @import("server_notifications.zig").sendProgressReport;

    pub const sendProgressReportWithDir = @import("server_notifications.zig").sendProgressReportWithDir;

    pub const handleInitialize = @import("server_dispatch.zig").handleInitialize;

    pub const maybeSwapDb = @import("server_document_sync.zig").maybeSwapDb;

    pub const flushIncrPaths = @import("server_document_sync.zig").flushIncrPaths;

    pub const FLUSH_DEBOUNCE_MS: i64 = 150;

    pub const flushDirtyUris = @import("server_document_sync.zig").flushDirtyUris;

    pub const flushDirtyUrisDebounced = @import("server_document_sync.zig").flushDirtyUrisDebounced;

    pub const flushDirtyUrisImpl = @import("server_document_sync.zig").flushDirtyUrisImpl;

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

pub const computeDataDir = server_util.computeDataDir;
pub const computeDbPath = server_util.computeDbPath;
pub const uriToPath = server_util.uriToPath;
pub const pathToUri = server_util.pathToUri;
pub const resolveRequireTarget = server_util.resolveRequireTarget;
pub const normalizeCRLF = server_util.normalizeCRLF;
pub const isInStringOrComment = server_util.isInStringOrComment;
pub const writePathAsUri = server_util.writePathAsUri;
pub const extractParamsObject = server_util.extractParamsObject;
pub const extractTextDocumentUri = server_util.extractTextDocumentUri;
pub const extractPosition = server_util.extractPosition;
pub const matchesCamelInitials = server_util.matchesCamelInitials;
pub const isSubsequence = server_util.isSubsequence;
pub const buildQueryPattern = server_util.buildQueryPattern;
pub const buildPrefixPattern = server_util.buildPrefixPattern;
pub const emptyResult = server_util.emptyResult;
pub const posToOffset = server_util.posToOffset;
pub const utf16ColToUtf8 = server_util.utf16ColToUtf8;
pub const utf8ColToUtf16 = server_util.utf8ColToUtf16;
pub const convertSemBlobToUtf16 = server_util.convertSemBlobToUtf16;
pub const getLineSlice = server_util.getLineSlice;
pub const frcGet = server_util.frcGet;
pub const extractWord = server_util.extractWord;
pub const extractQualifiedName = server_util.extractQualifiedName;
pub const extractBaseClass = server_util.extractBaseClass;
pub const extractGenericElement = server_util.extractGenericElement;
pub const isRubyIdent = server_util.isRubyIdent;
pub const isValidRubyIdent = server_util.isValidRubyIdent;
pub const writeEscapedJsonContent = server_util.writeEscapedJsonContent;
pub const writeEscapedJson = server_util.writeEscapedJson;
pub const writeCodeActionEdits = server_util.writeCodeActionEdits;

test "capability JSON advertises wired experimental flags" {
    const haystack = init_caps_before_enc;
    try std.testing.expect(std.mem.indexOf(u8, haystack, "\"dap\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, haystack, "\"plugins\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, haystack, "\"inlineCompletion\":true") != null);
}
