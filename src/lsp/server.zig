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

const ruby_block_keywords = [_][]const u8{ "if ", "unless ", "case ", "while ", "until ", "begin", "for " };
const empty_json_array = "[]";
const MAX_INCR_PATHS: usize = 10_000;
const MAX_DELETED_PATHS: usize = 10_000;
const OPEN_DOC_CACHE_SIZE: usize = 200;
const LOG_FILE_SIZE_LIMIT: usize = 10 * 1024 * 1024;
const WORKSPACE_SYMBOL_LIMIT: usize = 500;
const USER_ERROR_RATELIMIT_MS: i64 = 30_000;
const INCR_WATCH_SLEEP_MS: u64 = 10;

fn emitSelRange(wr: *std.Io.Writer, src: []const u8, srv: *const Server, ln: i64, col: i64, name: []const u8) void {
    const line_src = getLineSlice(src, @intCast(@max(ln - 1, 0)));
    const col_u: usize = @intCast(@max(col, 0));
    const sc = srv.toClientCol(line_src, @min(col_u, line_src.len));
    const safe_off = @min(col_u, line_src.len);
    const ec = sc + utf8ColToUtf16(line_src[safe_off..], @min(name.len, line_src.len - safe_off));
    wr.print(",\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{ ln - 1, sc, ln - 1, ec }) catch {};
}

fn computeDiagCol(src: ?[]const u8, enc_utf8: bool, line_0: i64, byte_col: u32) i64 {
    if (enc_utf8 or src == null) return @intCast(byte_col);
    var ln: i64 = 0;
    var i: usize = 0;
    while (i < src.?.len and ln < line_0) : (i += 1) {
        if (src.?[i] == '\n') ln += 1;
    }
    const line_end = std.mem.indexOfPos(u8, src.?, i, "\n") orelse src.?.len;
    return utf8ColToUtf16(src.?[i..line_end], byte_col);
}

fn getMetaInt(db: db_mod.Db, key: []const u8) ?i64 {
    const stmt = db.prepare("SELECT value FROM meta WHERE key=?") catch return null;
    defer stmt.finalize();
    stmt.bind_text(1, key);
    if (stmt.step() catch false) {
        const v = stmt.column_text(0);
        return std.fmt.parseInt(i64, v, 10) catch null;
    }
    return null;
}

fn setMetaInt(db: db_mod.Db, key: []const u8, val: i64, alloc: std.mem.Allocator) void {
    const s = std.fmt.allocPrint(alloc, "{d}", .{val}) catch return;
    defer alloc.free(s);
    const stmt = db.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)") catch return;
    defer stmt.finalize();
    stmt.bind_text(1, key);
    stmt.bind_text(2, s);
    _ = stmt.step() catch |e| {
        var buf: [128]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "refract: setMetaInt failed: {s}\n", .{@errorName(e)}) catch "refract: setMetaInt failed\n";
        std.fs.File.stderr().writeAll(m) catch {};
    };
}

const IndexWork = struct {
    path: []const u8,
    is_gem: bool = false,
};

const WorkQueue = struct {
    items: std.ArrayList(IndexWork) = .{},
    head: usize = 0,
    mu: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    done: bool = false,

    fn push(self: *WorkQueue, item: IndexWork) bool {
        self.mu.lock();
        defer self.mu.unlock();
        self.items.append(std.heap.c_allocator, item) catch return false;
        self.cond.signal();
        return true;
    }

    fn pop(self: *WorkQueue) ?IndexWork {
        self.mu.lock();
        defer self.mu.unlock();
        while (self.head >= self.items.items.len and !self.done) {
            self.cond.wait(&self.mu);
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

fn bgWorkerFn(wctx: BgWorkerCtx) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const db = db_mod.Db.open(wctx.bg_ctx.db_pathz) catch return;
    defer db.close();
    db.exec("PRAGMA foreign_keys=ON") catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "refract: warning: PRAGMA foreign_keys failed: {s}", .{@errorName(err)}) catch "refract: PRAGMA foreign_keys failed";
        wctx.bg_ctx.server_ptr.sendLogMessage(3, msg);
    };
    // Per-worker in-memory DB for the parse phase; no mutex needed during parse
    const mem_db = db_mod.Db.open(":memory:") catch return;
    defer mem_db.close();
    mem_db.init_schema() catch return;
    while (wctx.queue.pop()) |work| {
        if (wctx.bg_ctx.server_ptr.bg_cancelled.load(.acquire)) return;
        // File stat outside mutex
        const stat = std.fs.cwd().statFile(work.path) catch {
            _ = arena.reset(.retain_capacity);
            continue;
        };
        if (stat.size > wctx.bg_ctx.server_ptr.max_file_size.load(.monotonic)) {
            var size_buf: [512]u8 = undefined;
            const size_msg = std.fmt.bufPrint(&size_buf,
                "refract: skipping {s} (file too large)", .{work.path})
                catch "refract: skipping file (too large)";
            wctx.bg_ctx.server_ptr.sendLogMessage(2, size_msg);
            _ = arena.reset(.retain_capacity);
            continue;
        }
        // Quick mtime-based skip check under brief mutex
        const disk_mtime: i64 = @intCast(@divTrunc(stat.mtime, std.time.ns_per_ms));
        {
            wctx.bg_ctx.server_ptr.db_mutex.lock();
            const skip = indexer.shouldSkip(db, work.path, disk_mtime);
            wctx.bg_ctx.server_ptr.db_mutex.unlock();
            if (skip) { _ = arena.reset(.retain_capacity); continue; }
        }
        // Skip files explicitly deleted via didDeleteFiles / didChangeWatchedFiles type=3
        {
            wctx.bg_ctx.server_ptr.deleted_paths_mu.lock();
            const is_deleted = wctx.bg_ctx.server_ptr.deleted_paths.contains(work.path);
            wctx.bg_ctx.server_ptr.deleted_paths_mu.unlock();
            if (is_deleted) { _ = arena.reset(.retain_capacity); continue; }
        }
        // Phase 1: parse into mem_db — outside mutex, fully parallel across workers
        const single_path = [1][]const u8{work.path};
        indexer.reindex(mem_db, &single_path, work.is_gem, arena.allocator(), wctx.bg_ctx.server_ptr.max_file_size.load(.monotonic)) catch |err| {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "refract: parse failed for {s}: {s}", .{ work.path, @errorName(err) }) catch "refract: parse failed";
            wctx.bg_ctx.server_ptr.sendLogMessage(2, msg);
            mem_db.exec("DELETE FROM files") catch {};
            _ = arena.reset(.retain_capacity);
            continue;
        };
        // Phase 2: commit parsed data to real DB — brief mutex, fast write
        wctx.bg_ctx.server_ptr.db_mutex.lock();
        indexer.commitParsed(db, mem_db, work.path, work.is_gem, arena.allocator()) catch |err| {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "refract: indexing failed for {s}: {s}", .{ work.path, @errorName(err) }) catch "refract: indexing failed";
            wctx.bg_ctx.server_ptr.sendLogMessage(2, msg);
        };
        wctx.bg_ctx.server_ptr.db_mutex.unlock();
        // Clear mem_db for next file (CASCADE handles all child tables)
        mem_db.exec("DELETE FROM files") catch {};
        _ = arena.reset(.retain_capacity);
    }
}

fn rubocopWorkerFn(server: *Server) void {
    while (true) {
        server.rubocop_queue_mu.lock();
        while (server.rubocop_pending.count() == 0 and !server.rubocop_thread_done.load(.acquire)) {
            server.rubocop_queue_cond.wait(&server.rubocop_queue_mu);
        }
        if (server.rubocop_pending.count() == 0 and server.rubocop_thread_done.load(.acquire)) {
            server.rubocop_queue_mu.unlock();
            return;
        }
        var key_it = server.rubocop_pending.keyIterator();
        const path_key = key_it.next().?.*;
        const path = server.alloc.dupe(u8, path_key) catch {
            server.rubocop_queue_mu.unlock();
            continue;
        };
        _ = server.rubocop_pending.remove(path_key);
        server.alloc.free(path_key);
        server.rubocop_queue_mu.unlock();
        defer server.alloc.free(path);

        const uri = std.fmt.allocPrint(server.alloc, "file://{s}", .{path}) catch continue;
        defer server.alloc.free(uri);

        const rubocop_diags = server.getRubocopDiags(path) catch &.{};
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
            server.open_docs_mu.lock();
            defer server.open_docs_mu.unlock();
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
        server.writeDiagItems(w, prism_diags, diag_source, &first);
        server.writeDiagItems(w, rubocop_diags, diag_source, &first);
        w.writeAll("]}}") catch continue;
        const json = aw.toOwnedSlice() catch continue;
        defer server.alloc.free(json);
        server.sendNotification(json);
    }
}

const BgCtx = struct {
    db_pathz: [:0]u8,
    root_path: []u8,
    server_ptr: *Server,
    disable_gem_index: bool,
    extra_exclude_dirs: []const []const u8 = &.{},
    gitignore_negations: []const []const u8 = &.{},
    bundle_timeout_ms: u64 = 15_000,
    max_workers: usize = 8,

    fn run(self: *BgCtx) void {
        defer {
            std.heap.c_allocator.free(self.db_pathz);
            std.heap.c_allocator.free(self.root_path);
            std.heap.c_allocator.destroy(self);
        }
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const db = db_mod.Db.open(self.db_pathz) catch return;
        defer db.close();
        db.exec("PRAGMA foreign_keys=ON") catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "refract: warning: PRAGMA foreign_keys failed: {s}", .{@errorName(err)}) catch "refract: PRAGMA foreign_keys failed";
            self.server_ptr.sendLogMessage(3, msg);
        };

        self.server_ptr.sendLogMessage(3, "refract: indexing workspace");
        self.server_ptr.sendProgressBegin();

        const paths = scanner.scanWithNegations(self.root_path, alloc, self.extra_exclude_dirs, self.gitignore_negations) catch {
            self.server_ptr.sendLogMessage(1, "refract: workspace scan failed");
            self.server_ptr.sendProgressEnd();
            return;
        };

        const const_paths = alloc.alloc([]const u8, paths.len) catch return;
        for (paths, 0..) |p, i| const_paths[i] = p;

        const total_files = const_paths.len;

        // Parallel indexing: spawn worker threads (default: min(ncpu, 8), configurable via maxWorkers)
        var queue = WorkQueue{};
        defer queue.items.deinit(std.heap.c_allocator);

        const ncpu = std.Thread.getCpuCount() catch 1;
        const nthreads = @min(ncpu, @min(self.max_workers, 16));
        var threads: [16]?std.Thread = [_]?std.Thread{null} ** 16;
        for (0..nthreads) |ti| {
            const wctx = BgWorkerCtx{ .bg_ctx = self, .queue = &queue };
            threads[ti] = std.Thread.spawn(.{}, bgWorkerFn, .{wctx}) catch null;
        }

        var file_count: usize = 0;
        for (const_paths) |p| {
            if (self.server_ptr.bg_cancelled.load(.acquire)) break;
            std.fs.accessAbsolute(p, .{}) catch |e| {
                var abuf: [512]u8 = undefined;
                const amsg = std.fmt.bufPrint(&abuf, "refract: skipping inaccessible file {s}: {s}", .{ p, @errorName(e) }) catch "refract: skipping inaccessible file";
                self.server_ptr.sendLogMessage(4, amsg);
                continue;
            };
            if (!queue.push(.{ .path = p })) self.server_ptr.sendLogMessage(1, "refract: index queue full (OOM), file skipped");
            file_count += 1;
            if (file_count % 50 == 0) {
                const dir_part = std.fs.path.dirname(p) orelse p;
                const dir_name = std.fs.path.basename(dir_part);
                self.server_ptr.sendProgressReportWithDir(file_count, total_files, dir_name);
            }
        }
        // Signal workers that no more work is coming
        queue.mu.lock();
        queue.done = true;
        queue.mu.unlock();
        queue.cond.broadcast();

        for (threads) |t_opt| {
            if (t_opt) |t| t.join();
        }

        // Push diagnostics for indexed files
        for (const_paths) |p| {
            const bg_diags = indexer.getDiags(p, alloc) catch &.{};
            defer { for (bg_diags) |d| alloc.free(d.message); alloc.free(bg_diags); }
            if (bg_diags.len > 0) {
                var uri_buf: [4096]u8 = undefined;
                if (std.fmt.bufPrint(&uri_buf, "file://{s}", .{p})) |file_uri| {
                    self.server_ptr.publishDiagnostics(file_uri, p, false);
                } else |_| {}
            }
        }

        if (!self.server_ptr.bg_cancelled.load(.acquire)) {
            self.server_ptr.db_mutex.lock();
            indexer.cleanupStale(db, const_paths, self.root_path, alloc) catch |e| {
                var buf: [128]u8 = undefined;
                const m = std.fmt.bufPrint(&buf, "refract: symbol cleanup failed: {s}", .{@errorName(e)}) catch "refract: symbol cleanup failed";
                self.server_ptr.sendLogMessage(2, m);
            };
            self.server_ptr.db_mutex.unlock();
            self.server_ptr.deleted_paths_mu.lock();
            var dp_it = self.server_ptr.deleted_paths.keyIterator();
            while (dp_it.next()) |k| self.server_ptr.alloc.free(k.*);
            self.server_ptr.deleted_paths.clearRetainingCapacity();
            self.server_ptr.deleted_paths_mu.unlock();
        }

        self.server_ptr.sendProgressEnd();
        if (!self.server_ptr.bg_cancelled.load(.acquire)) {
            self.server_ptr.db_mutex.lock();
            var nfiles: i64 = 0;
            var nsyms: i64 = 0;
            if (self.server_ptr.db.prepare("SELECT COUNT(*) FROM files WHERE is_gem=0")) |fs| {
                defer fs.finalize();
                if (fs.step() catch false) nfiles = fs.column_int(0);
            } else |_| {}
            if (self.server_ptr.db.prepare("SELECT COUNT(*) FROM symbols")) |ss| {
                defer ss.finalize();
                if (ss.step() catch false) nsyms = ss.column_int(0);
            } else |_| {}
            self.server_ptr.db.runOptimize();
            self.server_ptr.db_mutex.unlock();
            var stat_buf: [128]u8 = undefined;
            const stat_msg = std.fmt.bufPrint(&stat_buf, "refract: indexed {d} files, {d} symbols", .{ nfiles, nsyms })
                catch "refract: indexing complete";
            self.server_ptr.sendLogMessage(3, stat_msg);
        } else {
            self.server_ptr.db_mutex.lock();
            self.server_ptr.db.runOptimize();
            self.server_ptr.db_mutex.unlock();
            self.server_ptr.sendLogMessage(3, "refract: indexing complete");
        }

        if (!self.disable_gem_index and !self.server_ptr.bg_cancelled.load(.acquire)) {
            // Gem scan: only if Gemfile.lock has changed
            const lock_path = std.fmt.allocPrint(alloc, "{s}/Gemfile.lock", .{self.root_path}) catch return;
            const lock_stat = std.fs.cwd().statFile(lock_path) catch {
                self.server_ptr.sendLogMessage(3, "refract: no Gemfile.lock found; gem indexing skipped");
                return;
            };
            const lock_mtime: i64 = @truncate(@divTrunc(lock_stat.mtime, std.time.ns_per_ms));

            const stored_mtime = getMetaInt(db, "gemfile_lock_mtime") orelse 0;
            if (lock_mtime == stored_mtime) return;

            self.server_ptr.db_mutex.lock();
            db.exec("DELETE FROM files WHERE is_gem=1") catch |e| {
                var gbuf: [256]u8 = undefined;
                const gmsg = std.fmt.bufPrint(&gbuf, "refract: gem table clear failed: {s}", .{@errorName(e)})
                    catch "refract: gem table clear failed";
                self.server_ptr.sendLogMessage(2, gmsg);
            };
            self.server_ptr.db_mutex.unlock();

            const gem_paths = gems.findGemPaths(self.root_path, alloc, self.bundle_timeout_ms * std.time.ns_per_ms) catch {
                self.server_ptr.sendLogMessage(2, "refract: gem index failed");
                self.server_ptr.showUserError("refract: gem indexing failed — completion for gems may be unavailable");
                return;
            };
            const gem_const_paths = alloc.alloc([]const u8, gem_paths.len) catch return;
            for (gem_paths, 0..) |p, i| gem_const_paths[i] = p;

            var gem_queue = WorkQueue{};
            defer gem_queue.items.deinit(std.heap.c_allocator);
            var gem_threads: [16]?std.Thread = [_]?std.Thread{null} ** 16;
            for (0..nthreads) |ti| {
                const wctx = BgWorkerCtx{ .bg_ctx = self, .queue = &gem_queue };
                gem_threads[ti] = std.Thread.spawn(.{}, bgWorkerFn, .{wctx}) catch null;
            }
            for (gem_const_paths) |gp| {
                if (self.server_ptr.bg_cancelled.load(.acquire)) break;
                if (!gem_queue.push(.{ .path = gp, .is_gem = true })) self.server_ptr.sendLogMessage(1, "refract: gem index queue full (OOM), gem skipped");
            }
            gem_queue.mu.lock();
            gem_queue.done = true;
            gem_queue.mu.unlock();
            gem_queue.cond.broadcast();
            for (gem_threads) |t_opt| {
                if (t_opt) |t| t.join();
            }
            {
                var gbuf: [128]u8 = undefined;
                const gmsg = std.fmt.bufPrint(&gbuf, "refract: indexing gems: {d} files", .{gem_const_paths.len}) catch "refract: indexing gems";
                self.server_ptr.sendLogMessage(3, gmsg);
            }
            if (!self.server_ptr.bg_cancelled.load(.acquire)) {
                self.server_ptr.db_mutex.lock();
                setMetaInt(db, "gemfile_lock_mtime", lock_mtime, alloc);
                self.server_ptr.db_mutex.unlock();
            }
        }

        // Incremental reindex watch loop: drain queued paths every 200ms
        while (!self.server_ptr.bg_cancelled.load(.acquire)) {
            var elapsed_ms: u32 = 0;
            while (elapsed_ms < 200) : (elapsed_ms += 10) {
                if (self.server_ptr.bg_cancelled.load(.acquire)) break;
                std.Thread.sleep(INCR_WATCH_SLEEP_MS * std.time.ns_per_ms);
            }
            self.server_ptr.incr_paths_mu.lock();
            if (self.server_ptr.incr_paths.items.len == 0) {
                self.server_ptr.incr_paths_mu.unlock();
                continue;
            }
            const batch = self.server_ptr.incr_paths.toOwnedSlice(self.server_ptr.alloc) catch {
                self.server_ptr.incr_paths_mu.unlock();
                continue;
            };
            self.server_ptr.incr_paths = .{};
            self.server_ptr.incr_paths_mu.unlock();
            defer {
                for (batch) |p| self.server_ptr.alloc.free(p);
                self.server_ptr.alloc.free(batch);
            }
            // Filter out explicitly deleted paths
            var filtered = std.ArrayList([]const u8){};
            defer filtered.deinit(alloc);
            self.server_ptr.deleted_paths_mu.lock();
            for (batch) |p| {
                if (!self.server_ptr.deleted_paths.contains(p) and !self.server_ptr.isExcludedPath(p))
                    filtered.append(alloc, p) catch {};
            }
            self.server_ptr.deleted_paths_mu.unlock();
            if (filtered.items.len == 0) continue;
            self.server_ptr.db_mutex.lock();
            indexer.reindex(db, filtered.items, false, alloc, self.server_ptr.max_file_size.load(.monotonic)) catch |e| {
                var ebuf: [256]u8 = undefined;
                const emsg = std.fmt.bufPrint(&ebuf, "refract: incremental reindex failed: {s}", .{@errorName(e)})
                    catch "refract: incremental reindex failed";
                self.server_ptr.sendLogMessage(2, emsg);
            };
            self.server_ptr.db_mutex.unlock();
            _ = arena.reset(.retain_capacity);
        }
    }
};

const TimeoutCtx = struct {
    child: *std.process.Child,
    done: std.atomic.Value(bool),
    timeout_ns: u64,

    fn run(ctx: *TimeoutCtx) void {
        var elapsed: u64 = 0;
        while (elapsed < ctx.timeout_ns) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            elapsed += 100 * std.time.ns_per_ms;
            if (ctx.done.load(.acquire)) return;
        }
        _ = ctx.child.kill() catch {};
    }
};

const ParamHintCtx = struct {
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

fn paramHintVisitor(node: ?*const prism_mod.Node, data: ?*anyopaque) callconv(.c) bool {
    const ctx: *ParamHintCtx = @ptrCast(@alignCast(data.?));
    const n = node.?;
    if (n.*.type != prism_mod.NODE_CALL) return true;
    const cn: *const prism_mod.CallNode = @ptrCast(@alignCast(n));
    if (cn.arguments == null) return true;
    const args = cn.arguments.?[0].arguments;
    if (args.size < 2) return true;

    const call_lc = prism_mod.lineOffsetListLineColumn(&ctx.parser.line_offsets, n.*.location.start, ctx.parser.start_line);
    const call_line: i64 = call_lc.line;
    if (call_line < ctx.db_start or call_line > ctx.db_end) return true;

    const ct = prism_mod.constantPoolIdToConstant(&ctx.parser.constant_pool, cn.name);
    const mname = ct[0].start[0..ct[0].length];

    const cnt_stmt = ctx.db.prepare(
        "SELECT COUNT(*) FROM params p JOIN symbols s ON p.symbol_id=s.id WHERE s.name=? AND s.kind='def' AND p.kind IN ('required','optional')"
    ) catch return true;
    cnt_stmt.bind_text(1, mname);
    const pcount: i64 = if (cnt_stmt.step() catch false) cnt_stmt.column_int(0) else 0;
    cnt_stmt.finalize();
    if (pcount < 2) return true;

    const mp_stmt = ctx.db.prepare(
        "SELECT p.name FROM params p JOIN symbols s ON p.symbol_id=s.id WHERE s.name=? AND s.kind='def' AND p.kind IN ('required','optional') ORDER BY p.position LIMIT 20"
    ) catch return true;
    mp_stmt.bind_text(1, mname);
    defer mp_stmt.finalize();

    var pidx: usize = 0;
    while (mp_stmt.step() catch false) {
        if (pidx >= args.size or pidx >= 20) break;
        const pname = mp_stmt.column_text(0);
        const arg = args.nodes[pidx];
        if (arg.*.type == prism_mod.NODE_KEYWORD_HASH) break;
        const arg_lc = prism_mod.lineOffsetListLineColumn(&ctx.parser.line_offsets, arg.*.location.start, ctx.parser.start_line);
        if (!ctx.first_ptr.*) ctx.w.writeByte(',') catch {};
        ctx.first_ptr.* = false;
        const arg_line_0: u32 = @intCast(arg_lc.line - 1);
        const arg_line_src = getLineSlice(ctx.source, arg_line_0);
        const char_col: u32 = if (ctx.encoding_utf8) @intCast(arg_lc.column)
                              else utf8ColToUtf16(arg_line_src, arg_lc.column);
        ctx.w.print("{{\"position\":{{\"line\":{d},\"character\":{d}}},\"label\":\"", .{ arg_line_0, char_col }) catch {};
        writeEscapedJsonContent(ctx.w, pname) catch {};
        ctx.w.writeAll(":\",\"kind\":2,\"paddingLeft\":false,\"paddingRight\":true}") catch {};
        pidx += 1;
    }
    return true;
}

pub const Server = struct {
    db: db_mod.Db,
    db_pathz: [:0]u8,
    bg_thread: ?std.Thread,
    alloc: std.mem.Allocator,
    initialized: bool,
    bg_started: bool,
    shutdown_requested: bool,
    root_uri: ?[]u8,
    writer_mutex: std.Thread.Mutex,
    db_mutex: std.Thread.Mutex,
    log_mutex: std.Thread.Mutex,
    stdout_writer: ?*std.Io.Writer,
    disable_gem_index: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    disable_rubocop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    log_path: ?[]const u8 = null,
    log_file: ?std.fs.File = null,
    log_level: std.atomic.Value(u8) = std.atomic.Value(u8).init(2),
    max_file_size: std.atomic.Value(usize) = std.atomic.Value(usize).init(8 * 1024 * 1024),
    client_caps_work_done_progress: bool = false,
    stmt_cache: std.AutoHashMapUnmanaged(usize, db_mod.CachedStmt) = .{},
    bg_cancelled: std.atomic.Value(bool) = .{ .raw = false },
    cancelled_ids: std.AutoHashMapUnmanaged(i64, void) = .{},
    cancel_mutex: std.Thread.Mutex = .{},
    open_docs: std.StringHashMapUnmanaged([]u8) = .{},
    open_docs_order: std.ArrayList([]const u8) = .{},
    open_docs_mu: std.Thread.Mutex = .{},
    progress_req_counter: std.atomic.Value(i64) = std.atomic.Value(i64).init(1000),
    active_progress_token_id: i64 = 0,
    rubocop_timeout_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(30_000),
    bundle_timeout_ms: u64 = 15_000,
    max_workers: usize = 8,
    extra_exclude_dirs: []const []const u8 = &.{},
    gitignore_negations: []const []const u8 = &.{},
    rubocop_checked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    rubocop_available: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    rubocop_bundle_probed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    rubocop_use_bundle: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    lock_db_path: bool = false,
    last_index_mu: std.Thread.Mutex = .{},
    last_index_ms: std.StringHashMap(i64) = undefined,
    incr_paths: std.ArrayList([]u8) = undefined,
    incr_paths_mu: std.Thread.Mutex = .{},
    open_docs_version: std.StringHashMapUnmanaged(i64) = .{},
    client_caps_doc_changes: bool = false,
    client_caps_def_link: bool = false,
    root_path: ?[]u8 = null,
    tmp_dir: ?[]u8 = null,
    fmt_counter: u32 = 0,
    extra_roots: std.ArrayList([]u8) = .{},
    encoding_utf8: bool = false,
    deleted_paths_mu: std.Thread.Mutex = .{},
    deleted_paths: std.StringHashMapUnmanaged(void) = .{},
    exit_code: ?u8 = null,
    last_user_error_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    rubocop_thread: ?std.Thread = null,
    rubocop_queue_mu: std.Thread.Mutex = .{},
    rubocop_queue_cond: std.Thread.Condition = .{},
    rubocop_pending: std.StringHashMapUnmanaged(void) = .{},
    rubocop_thread_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(db: db_mod.Db, db_pathz: [:0]const u8, alloc: std.mem.Allocator) !Server {
        var s = Server{
            .db = db,
            .db_pathz = try alloc.dupeZ(u8, db_pathz),
            .bg_thread = null,
            .alloc = alloc,
            .initialized = false,
            .bg_started = false,
            .shutdown_requested = false,
            .root_uri = null,
            .writer_mutex = .{},
            .db_mutex = .{},
            .log_mutex = .{},
            .stdout_writer = null,
            .disable_gem_index = std.atomic.Value(bool).init(false),
            .disable_rubocop = std.atomic.Value(bool).init(false),
            .log_path = null,
            .log_level = std.atomic.Value(u8).init(2),
            .max_file_size = std.atomic.Value(usize).init(8 * 1024 * 1024),
            .client_caps_work_done_progress = false,
            .stmt_cache = .{},
            .last_index_ms = std.StringHashMap(i64).init(alloc),
            .incr_paths = .{},
        };
        const pid = std.c.getpid();
        var rand_bytes: [4]u8 = undefined;
        std.crypto.random.bytes(&rand_bytes);
        const tmp_base = std.posix.getenv("TMPDIR") orelse std.posix.getenv("TMP") orelse "/tmp";
        const tmp_dir = std.fmt.allocPrint(alloc, "{s}/refract-{d}-{x}", .{ tmp_base, pid, std.mem.readInt(u32, &rand_bytes, .little) }) catch null;
        s.tmp_dir = tmp_dir;
        return s;
    }

    pub fn deinit(self: *Server) void {
        self.bg_cancelled.store(true, .seq_cst);
        if (self.bg_thread) |t| t.join();
        self.rubocop_thread_done.store(true, .seq_cst);
        self.rubocop_queue_cond.signal();
        if (self.rubocop_thread) |t| t.join();
        var rq_it = self.rubocop_pending.keyIterator();
        while (rq_it.next()) |k| self.alloc.free(k.*);
        self.rubocop_pending.deinit(self.alloc);
        self.db.runOptimize();
        if (self.root_uri) |uri| self.alloc.free(uri);
        if (self.root_path) |rp| self.alloc.free(rp);
        if (self.log_path) |lp| self.alloc.free(lp);
        if (self.log_file) |f| f.close();
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
            std.fs.deleteTreeAbsolute(d) catch |e| {
                var tbuf: [256]u8 = undefined;
                const tmsg = std.fmt.bufPrint(&tbuf, "refract: failed to delete tmp dir {s}: {s}\n", .{ d, @errorName(e) }) catch "refract: failed to delete tmp dir\n";
                std.fs.File.stderr().writeAll(tmsg) catch {};
            };
            self.alloc.free(d);
        }
        for (self.extra_roots.items) |r| self.alloc.free(r);
        self.extra_roots.deinit(self.alloc);
        var dp_it = self.deleted_paths.keyIterator();
        while (dp_it.next()) |k| self.alloc.free(k.*);
        self.deleted_paths.deinit(self.alloc);
        self.db.close();
        self.alloc.free(self.db_pathz);
    }

    fn startBgIndexer(self: *Server) void {
        const uri = self.root_uri orelse return;
        const decoded_path = uriToPath(std.heap.c_allocator, uri) catch return;
        const ctx = std.heap.c_allocator.create(BgCtx) catch {
            std.heap.c_allocator.free(decoded_path);
            return;
        };
        ctx.db_pathz = std.heap.c_allocator.dupeZ(u8, self.db_pathz) catch {
            std.heap.c_allocator.free(decoded_path);
            std.heap.c_allocator.destroy(ctx);
            return;
        };
        ctx.root_path = decoded_path;
        ctx.server_ptr = self;
        ctx.disable_gem_index = self.disable_gem_index.load(.monotonic);
        ctx.extra_exclude_dirs = self.extra_exclude_dirs;
        ctx.gitignore_negations = self.gitignore_negations;
        ctx.bundle_timeout_ms = self.bundle_timeout_ms;
        ctx.max_workers = self.max_workers;
        self.bg_cancelled.store(true, .seq_cst);
        if (self.bg_thread) |t| t.join();
        self.bg_thread = null;
        self.bg_cancelled.store(false, .seq_cst);
        self.bg_thread = std.Thread.spawn(.{}, BgCtx.run, .{ctx}) catch blk: {
            ctx.run();
            break :blk null;
        };
    }

    fn cachedStmt(self: *Server, comptime sql: [*:0]const u8) !db_mod.CachedStmt {
        const key: usize = @intFromPtr(sql);
        if (self.stmt_cache.get(key)) |cs| {
            cs.reset();
            return cs;
        }
        const cs = try self.db.prepareRaw(sql);
        try self.stmt_cache.put(self.alloc, key, cs);
        return cs;
    }

    fn pathInBounds(self: *Server, path: []const u8) bool {
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

    fn isExcludedPath(self: *Server, path: []const u8) bool {
        for (self.extra_exclude_dirs) |excl| {
            var it = std.mem.splitSequence(u8, path, "/");
            while (it.next()) |part| {
                if (std.mem.eql(u8, part, excl)) return true;
            }
        }
        return false;
    }

    fn clientPosToOffset(self: *Server, source: []const u8, line: u32, character: u32) usize {
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

    fn readSourceForUri(self: *Server, uri: []const u8, path: []const u8) ![]u8 {
        if (self.open_docs.get(uri)) |cached| return self.alloc.dupe(u8, cached);
        const raw = try std.fs.cwd().readFileAlloc(self.alloc, path, self.max_file_size.load(.monotonic));
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

    fn isCancelled(self: *Server, id: ?std.json.Value) bool {
        const id_val = id orelse return false;
        const rid: i64 = switch (id_val) {
            .integer => |i| i, .float => |f| @intFromFloat(f), else => return false,
        };
        self.cancel_mutex.lock();
        defer self.cancel_mutex.unlock();
        const found = self.cancelled_ids.contains(rid);
        if (found) _ = self.cancelled_ids.remove(rid);
        return found;
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
                return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = null,
                    .@"error" = .{ .code = @intFromEnum(types.ErrorCode.invalid_request), .message = "Invalid request: server is shutting down" } };
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
                return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = null,
                    .@"error" = .{ .code = @intFromEnum(types.ErrorCode.server_not_initialized), .message = "Server not initialized" } };
            }
            return null;
        }
        if (std.mem.eql(u8, msg.method, "initialized")) {
            if (self.bg_started) return null;
            self.bg_started = true;
            self.startBgIndexer();
            if (self.rubocop_thread == null) {
                self.rubocop_thread = std.Thread.spawn(.{}, rubocopWorkerFn, .{self}) catch null;
            }
            self.requestWorkspaceConfiguration();
            return null;
        } else if (std.mem.eql(u8, msg.method, "$/cancelRequest")) {
            if (msg.params) |p| {
                const obj = switch (p) { .object => |o| o, else => return null };
                const id_val = obj.get("id") orelse return null;
                const rid: i64 = switch (id_val) {
                    .integer => |i| i, .float => |f| @intFromFloat(f), else => return null,
                };
                self.cancel_mutex.lock();
                self.cancelled_ids.put(self.alloc, rid, {}) catch {}; // cleanup — ignore error
                self.cancel_mutex.unlock();
            }
            return null;
        } else if (std.mem.eql(u8, msg.method, "workspace/symbol")) {
            return try self.handleWorkspaceSymbol(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/didOpen")) {
            self.handleDidOpen(msg);
            return null;
        } else if (std.mem.eql(u8, msg.method, "textDocument/didClose")) {
            self.handleDidClose(msg);
            return null;
        } else if (std.mem.eql(u8, msg.method, "textDocument/didChange")) {
            self.handleDidChange(msg);
            return null;
        } else if (std.mem.eql(u8, msg.method, "textDocument/didSave")) {
            self.handleDidSave(msg);
            return null;
        } else if (std.mem.eql(u8, msg.method, "workspace/didChangeWatchedFiles")) {
            self.handleDidChangeWatchedFiles(msg);
            return null;
        } else if (std.mem.eql(u8, msg.method, "workspace/didChangeConfiguration")) {
            const prev_disable_rubocop = self.disable_rubocop.load(.monotonic);
            if (msg.params) |params| {
                const settings = switch (params) { .object => |o| o, else => return null };
                const refract_settings = blk: {
                    const s = settings.get("settings") orelse break :blk null;
                    const so = switch (s) { .object => |o| o, else => break :blk null };
                    const r = so.get("refract") orelse break :blk null;
                    break :blk switch (r) { .object => |o| o, else => null };
                };
                if (refract_settings) |cfg| {
                    if (cfg.get("disableRubocop")) |v| switch (v) {
                        .bool => |b| { self.disable_rubocop.store(b, .monotonic); },
                        else => {},
                    };
                    if (cfg.get("logLevel")) |v| switch (v) {
                        .integer => |n| { self.log_level.store(@intCast(@min(n, 4)), .monotonic); },
                        else => {},
                    };
                    if (cfg.get("disableGemIndex")) |v| switch (v) {
                        .bool => |b| { self.disable_gem_index.store(b, .monotonic); },
                        else => {},
                    };
                    if (cfg.get("maxWorkers")) |v| switch (v) {
                        .integer => |n| { if (n > 0) self.max_workers = @intCast(@min(n, 64)); },
                        else => {},
                    };
                    if (cfg.get("maxFileSize")) |v| switch (v) {
                        .integer => |n| { if (n > 0) self.max_file_size.store(@intCast(@min(n, 256 * 1024 * 1024)), .monotonic); },
                        else => {},
                    };
                    if (cfg.get("maxFileSizeMb")) |v| switch (v) {
                        .integer => |n| { if (n > 0) self.max_file_size.store(@intCast(@as(usize, @intCast(@min(n, 256))) * 1024 * 1024), .monotonic); },
                        else => {},
                    };
                    if (cfg.get("rubocopTimeoutSecs")) |v| switch (v) {
                        .integer => |n| { if (n > 0) self.rubocop_timeout_ms.store(@intCast(@min(n, 300) * 1000), .monotonic); },
                        else => {},
                    };
                }
            }
            if (self.disable_rubocop.load(.monotonic) != prev_disable_rubocop) {
                self.rubocop_checked.store(false, .monotonic);
                self.rubocop_available.store(true, .monotonic);
                if (self.disable_rubocop.load(.monotonic)) {
                    self.rubocop_queue_mu.lock();
                    var rq_it = self.rubocop_pending.keyIterator();
                    while (rq_it.next()) |k| self.alloc.free(k.*);
                    self.rubocop_pending.clearRetainingCapacity();
                    self.rubocop_queue_mu.unlock();
                } else {
                    self.enqueueAllOpenDocs();
                }
            }
            self.requestWorkspaceConfiguration();
            return null;
        } else if (std.mem.eql(u8, msg.method, "workspace/didCreateFiles")) {
            self.handleDidCreateFiles(msg);
            return null;
        } else if (std.mem.eql(u8, msg.method, "workspace/didDeleteFiles")) {
            self.handleDidDeleteFiles(msg);
            return null;
        } else if (std.mem.eql(u8, msg.method, "workspace/didRenameFiles")) {
            self.db_mutex.lock();
            defer self.db_mutex.unlock();
            self.handleDidRenameFiles(msg);
            return null;
        } else if (std.mem.eql(u8, msg.method, "textDocument/codeAction")) {
            return try self.handleCodeAction(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/definition")) {
            return try self.handleDefinition(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/implementation")) {
            return try self.handleDefinition(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/declaration")) {
            return try self.handleDefinition(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/documentSymbol")) {
            return try self.handleDocumentSymbol(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/hover")) {
            return try self.handleHover(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/completion")) {
            return try self.handleCompletion(msg);
        } else if (std.mem.eql(u8, msg.method, "completionItem/resolve")) {
            return try self.handleCompletionItemResolve(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/references")) {
            return try self.handleReferences(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/signatureHelp")) {
            return try self.handleSignatureHelp(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/typeDefinition")) {
            return try self.handleTypeDefinition(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/inlayHint")) {
            return try self.handleInlayHint(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/semanticTokens/full")) {
            return try self.handleSemanticTokensFull(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/semanticTokens/range")) {
            return try self.handleSemanticTokensRange(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/documentHighlight")) {
            return try self.handleDocumentHighlight(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/prepareRename")) {
            return try self.handlePrepareRename(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/rename")) {
            return try self.handleRename(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/formatting")) {
            return try self.handleFormatting(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/foldingRange")) {
            return try self.handleFoldingRange(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/rangeFormatting")) {
            return try self.handleRangeFormatting(msg);
        } else if (std.mem.eql(u8, msg.method, "workspace/executeCommand")) {
            return try self.handleExecuteCommand(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/codeLens")) {
            return try self.handleCodeLens(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/prepareTypeHierarchy")) {
            return try self.handlePrepareTypeHierarchy(msg);
        } else if (std.mem.eql(u8, msg.method, "typeHierarchy/supertypes")) {
            return try self.handleTypeHierarchySupertypes(msg);
        } else if (std.mem.eql(u8, msg.method, "typeHierarchy/subtypes")) {
            return try self.handleTypeHierarchySubtypes(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/semanticTokens/full/delta")) {
            return try self.handleSemanticTokensDelta(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/selectionRange")) {
            return try self.handleSelectionRange(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/linkedEditingRange")) {
            return try self.handleLinkedEditingRange(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/prepareCallHierarchy")) {
            return try self.handleCallHierarchyPrepare(msg);
        } else if (std.mem.eql(u8, msg.method, "callHierarchy/incomingCalls")) {
            return try self.handleCallHierarchyIncomingCalls(msg);
        } else if (std.mem.eql(u8, msg.method, "callHierarchy/outgoingCalls")) {
            return try self.handleCallHierarchyOutgoingCalls(msg);
        } else if (std.mem.eql(u8, msg.method, "textDocument/diagnostic")) {
            return try self.handlePullDiagnostic(msg);
        } else if (std.mem.eql(u8, msg.method, "workspace/willRenameFiles")) {
            return try self.handleWillRenameFiles(msg);
        } else if (std.mem.eql(u8, msg.method, "workspace/willCreateFiles") or
                   std.mem.eql(u8, msg.method, "workspace/willDeleteFiles")) {
            const raw = try self.alloc.dupe(u8, "null");
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = raw, .@"error" = null };
        } else if (std.mem.eql(u8, msg.method, "workspace/didChangeWorkspaceFolders")) {
            if (msg.params) |params| {
                const obj2 = switch (params) { .object => |o| o, else => return null };
                const event_val = obj2.get("event") orelse return null;
                const ev = switch (event_val) { .object => |o| o, else => return null };
                if (ev.get("removed")) |removed| switch (removed) {
                    .array => |arr| for (arr.items) |item| {
                        const folder = switch (item) { .object => |o| o, else => continue };
                        const folder_uri = switch (folder.get("uri") orelse continue) {
                            .string => |s| s, else => continue };
                        const folder_path = uriToPath(self.alloc, folder_uri) catch continue;
                        defer self.alloc.free(folder_path);
                        self.db_mutex.lock();
                        const del_stmt = self.db.prepare(
                            "DELETE FROM files WHERE path LIKE ? ESCAPE '\\'") catch {
                            self.db_mutex.unlock();
                            continue;
                        };
                        var like_buf = std.ArrayList(u8){};
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
                            self.db_mutex.unlock();
                            continue;
                        }
                        del_stmt.bind_text(1, like_buf.items);
                        _ = del_stmt.step() catch |err| blk: {
                            var del_buf: [128]u8 = undefined;
                            const del_msg = std.fmt.bufPrint(&del_buf,
                                "refract: failed to remove folder from index: {s}", .{@errorName(err)})
                                catch "refract: failed to remove folder from index";
                            self.sendLogMessage(2, del_msg);
                            break :blk false;
                        };
                        del_stmt.finalize();
                        self.db_mutex.unlock();
                        self.incr_paths_mu.lock();
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
                        self.incr_paths_mu.unlock();
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
                        const folder = switch (item) { .object => |o| o, else => continue };
                        const folder_uri = switch (folder.get("uri") orelse continue) {
                            .string => |s| s, else => continue };
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
                        self.incr_paths_mu.lock();
                        for (new_paths) |p| {
                            if (self.incr_paths.items.len < MAX_INCR_PATHS) {
                                self.incr_paths.append(self.alloc, p) catch self.alloc.free(p);
                            } else {
                                self.alloc.free(p);
                                folder_overflow = true;
                            }
                        }
                        self.alloc.free(new_paths);
                        self.incr_paths_mu.unlock();
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
        self.writer_mutex.lock();
        defer self.writer_mutex.unlock();
        transport.writeMessage(w, json) catch |e| {
            var tw_buf: [128]u8 = undefined;
            const tw_msg = std.fmt.bufPrint(&tw_buf, "refract: transport write: {s}\n", .{@errorName(e)}) catch "refract: transport write failed\n";
            std.fs.File.stderr().writeAll(tw_msg) catch {};
        };
    }

    pub fn logErr(self: *Server, comptime ctx: []const u8, err: anyerror) void {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "refract: {s}: {s}", .{ ctx, @errorName(err) }) catch "refract: error";
        self.sendLogMessage(2, msg);
    }

    pub fn showUserError(self: *Server, msg: []const u8) void {
        const now = std.time.milliTimestamp();
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

    fn applyConfigurationResult(self: *Server, arr: std.json.Array) void {
        if (arr.items.len == 0) return;
        const cfg = switch (arr.items[0]) { .object => |o| o, else => return };
        if (cfg.get("disableRubocop")) |v| switch (v) {
            .bool => |b| { self.disable_rubocop.store(b, .monotonic); },
            else => {},
        };
        if (cfg.get("logLevel")) |v| switch (v) {
            .integer => |n| { self.log_level.store(@min(@as(u8, @intCast(@max(n, 0))), 4), .monotonic); },
            else => {},
        };
        if (cfg.get("disableGemIndex")) |v| switch (v) {
            .bool => |b| { self.disable_gem_index.store(b, .monotonic); },
            else => {},
        };
    }

    fn requestWorkspaceConfiguration(self: *Server) void {
        const req_id = self.progress_req_counter.fetchAdd(1, .monotonic);
        var buf: [256]u8 = undefined;
        const req = std.fmt.bufPrint(&buf,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"workspace/configuration\",\"params\":{{\"items\":[{{\"section\":\"refract\"}}]}}}}",
            .{req_id}) catch return;
        const w = self.stdout_writer orelse return;
        self.writer_mutex.lock();
        defer self.writer_mutex.unlock();
        transport.writeMessage(w, req) catch |e| {
            var wc_buf: [128]u8 = undefined;
            const wc_msg = std.fmt.bufPrint(&wc_buf, "refract: send workspace/configuration request: {s}\n", .{@errorName(e)}) catch "refract: send failed\n";
            std.fs.File.stderr().writeAll(wc_msg) catch {};
        };
    }

    fn rotateLogIfNeeded(self: *Server) void {
        const lp = self.log_path orelse return;
        const stat = std.fs.cwd().statFile(lp) catch return;
        if (stat.size < LOG_FILE_SIZE_LIMIT) return;
        var old_buf: [4096]u8 = undefined;
        const old_path = std.fmt.bufPrint(&old_buf, "{s}.old", .{lp}) catch return;
        if (self.log_file) |f| {
            f.close();
            self.log_file = null;
        }
        std.fs.cwd().rename(lp, old_path) catch {};
    }

    pub fn sendLogMessage(self: *Server, level: u8, msg: []const u8) void {
        if (level > self.log_level.load(.monotonic)) return;
        if (self.log_path) |lp| blk: {
            self.log_mutex.lock();
            defer self.log_mutex.unlock();
            self.rotateLogIfNeeded();
            if (self.log_file == null) {
                self.log_file = std.fs.cwd().openFile(lp, .{ .mode = .write_only }) catch
                    (std.fs.cwd().createFile(lp, .{}) catch break :blk);
                _ = self.log_file.?.seekFromEnd(0) catch {};
            }
            const f = self.log_file.?;
            const ts = std.time.milliTimestamp();
            const ts_s = @divTrunc(ts, 1000);
            const ts_ms = @mod(ts, 1000);
            const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts_s) };
            const day = epoch.getDaySeconds();
            const year_day = epoch.getEpochDay().calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            var ts_buf: [28]u8 = undefined;
            const ts_str = std.fmt.bufPrint(&ts_buf, "[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}] ", .{
                year_day.year, month_day.month.numeric(), month_day.day_index + 1,
                day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute(), ts_ms,
            }) catch "";
            f.writeAll(ts_str) catch {};
            f.writeAll(msg) catch |e| {
                self.log_file.?.close();
                self.log_file = null;
                var fbuf: [128]u8 = undefined;
                const fmsg = std.fmt.bufPrint(&fbuf, "refract log write failed: {s}\n", .{@errorName(e)}) catch "refract log write failed\n";
                std.fs.File.stderr().writeAll(fmsg) catch {};
                break :blk;
            };
            f.writeAll("\n") catch {};
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
        var aw = std.Io.Writer.Allocating.init(std.heap.c_allocator);
        const w = &aw.writer;
        w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"window/showMessage\",\"params\":{\"type\":") catch return;
        w.print("{d}", .{level}) catch return;
        w.writeAll(",\"message\":") catch return;
        writeEscapedJson(w, msg) catch return;
        w.writeAll("}}") catch return;
        const json = aw.toOwnedSlice() catch return;
        defer std.heap.c_allocator.free(json);
        self.sendNotification(json);
    }

    fn sendProgressBegin(self: *Server) void {
        if (!self.client_caps_work_done_progress) return;
        const req_id = self.progress_req_counter.fetchAdd(1, .monotonic);
        self.active_progress_token_id = req_id;
        var token_buf: [32]u8 = undefined;
        const token = std.fmt.bufPrint(&token_buf, "refract_{d}", .{req_id}) catch "refract_0";
        var buf: [512]u8 = undefined;
        const create_msg = std.fmt.bufPrint(&buf,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"window/workDoneProgress/create\",\"params\":{{\"token\":\"{s}\"}}}}",
            .{ req_id, token }) catch return;
        self.sendNotification(create_msg);
        var begin_buf: [256]u8 = undefined;
        const begin_msg = std.fmt.bufPrint(&begin_buf,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"$/progress\",\"params\":{{\"token\":\"{s}\",\"value\":{{\"kind\":\"begin\",\"title\":\"Indexing\"}}}}}}",
            .{token}) catch return;
        self.sendNotification(begin_msg);
    }

    fn sendProgressEnd(self: *Server) void {
        if (!self.client_caps_work_done_progress) return;
        var token_buf: [32]u8 = undefined;
        const token = std.fmt.bufPrint(&token_buf, "refract_{d}", .{self.active_progress_token_id}) catch "refract_0";
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"$/progress\",\"params\":{{\"token\":\"{s}\",\"value\":{{\"kind\":\"end\"}}}}}}",
            .{token}) catch return;
        self.sendNotification(msg);
    }

    pub fn sendProgressReport(self: *Server, done: usize, total: usize) void {
        if (!self.client_caps_work_done_progress) return;
        const pct: u32 = if (total > 0) @intCast(@min(100, done * 100 / total)) else 0;
        var token_buf: [32]u8 = undefined;
        const token = std.fmt.bufPrint(&token_buf, "refract_{d}", .{self.active_progress_token_id}) catch "refract_0";
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
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
        const msg = std.fmt.bufPrint(&buf,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"$/progress\",\"params\":{{\"token\":\"{s}\",\"value\":{{\"kind\":\"report\",\"message\":\"{d}% ({s})\",\"percentage\":{d}}}}}}}",
            .{ token, pct, dir_name, pct },
        ) catch return;
        self.sendNotification(msg);
    }

    fn handleInitialize(self: *Server, msg: types.RequestMessage) types.ResponseMessage {
        if (self.initialized) {
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = null,
                .@"error" = .{ .code = @intFromEnum(types.ErrorCode.invalid_request), .message = "Server already initialized" } };
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
                                if (v == .integer and v.integer > 0) self.max_file_size.store(
                                    @intCast(@min(v.integer, @as(i64, 2 * 1024 * 1024 * 1024))), .monotonic);
                            }
                            if (opts_val.object.get("maxFileSizeMb")) |v| {
                                if (v == .integer and v.integer > 0) self.max_file_size.store(
                                    @as(usize, @intCast(@min(v.integer, @as(i64, 2048)))) * 1024 * 1024, .monotonic);
                            }
                            if (opts_val.object.get("rubocopTimeoutSecs")) |v| {
                                if (v == .integer and v.integer > 0) self.rubocop_timeout_ms.store(@as(u64, @intCast(@min(v.integer, @as(i64, 3600)))) * 1000, .monotonic);
                            }
                            if (opts_val.object.get("bundleExecTimeoutSecs")) |v| {
                                if (v == .integer and v.integer > 0) self.bundle_timeout_ms = @as(u64, @intCast(@min(v.integer, @as(i64, 3600)))) * 1000;
                            }
                            if (opts_val.object.get("maxWorkers")) |v| {
                                if (v == .integer and v.integer > 0) self.max_workers = @intCast(@min(v.integer, 16));
                            }
                            if (opts_val.object.get("excludeDirs")) |v| {
                                if (v == .array) {
                                    var dirs = std.ArrayList([]const u8){};
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
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const iw = &aw.writer;
        iw.writeAll(init_caps_before_enc) catch return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = null, .@"error" = .{ .code = @intFromEnum(types.ErrorCode.internal_error), .message = "internal error" } };
        iw.writeAll(if (self.encoding_utf8) "\"utf-8\"" else "\"utf-16\"") catch {};
        iw.writeAll(init_caps_after_enc) catch {};
        iw.writeAll(build_meta.version) catch {};
        iw.writeAll("\"}}") catch {};
        const raw = aw.toOwnedSlice() catch return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = null, .@"error" = .{ .code = @intFromEnum(types.ErrorCode.internal_error), .message = "internal error" } };
        return types.ResponseMessage{
            .id = msg.id,
            .raw_result = raw,
            .result = null,
            .@"error" = null,
        };
    }

    fn maybeSwapDb(self: *Server, raw_uri: []const u8) void {
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
                std.fs.deleteFileAbsolute(new_pathz) catch {}; // cleanup — ignore error
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

    fn handleWorkspaceSymbol(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.flushIncrPaths();
        self.flushDirtyUris();
        if (self.isCancelled(msg.id)) return null;
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
        const query = blk: {
            if (msg.params) |params| {
                switch (params) {
                    .object => |obj| {
                        if (obj.get("query")) |q| {
                            switch (q) {
                                .string => |s| break :blk s,
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            }
            break :blk "";
        };

        const pattern = try buildQueryPattern(self.alloc, query);
        defer self.alloc.free(pattern);
        const prefix_pattern = try buildPrefixPattern(self.alloc, query);
        defer self.alloc.free(prefix_pattern);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeByte('[');
        var first = true;
        var result_count: usize = 0;
        var frc_ws: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer {
            var frc_it = frc_ws.iterator();
            while (frc_it.next()) |e| { self.alloc.free(e.key_ptr.*); self.alloc.free(e.value_ptr.*); }
            frc_ws.deinit(self.alloc);
        }

        // @-prefixed word: search local_vars for instance variable type hints
        if (query.len > 0 and query[0] == '@') {
            const iv_stmt = try self.db.prepare(
                \\SELECT DISTINCT lv.name, lv.line, lv.col, f.path
                \\FROM local_vars lv JOIN files f ON lv.file_id=f.id
                \\WHERE lv.name LIKE ? ESCAPE '\' AND lv.name LIKE '@%' AND f.is_gem = 0
                \\LIMIT 100
            );
            defer iv_stmt.finalize();
            iv_stmt.bind_text(1, pattern);
            while (try iv_stmt.step()) {
                if (!first) try w.writeByte(',');
                first = false;
                result_count += 1;
                const name = iv_stmt.column_text(0);
                const line = iv_stmt.column_int(1);
                const col = iv_stmt.column_int(2);
                const path = iv_stmt.column_text(3);
                const start_char = self.toClientColFromPath(&frc_ws, path, line - 1, col);
                try w.writeAll("{\"name\":");
                try writeEscapedJson(w, name);
                try w.print(",\"kind\":7,\"location\":{{\"uri\":\"file://", .{});
                try writePathAsUri(w, path);
                try w.writeAll("\",\"range\":{\"start\":{\"line\":");
                try w.print("{d}", .{line - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{start_char});
                try w.writeAll("},\"end\":{\"line\":");
                try w.print("{d}", .{line - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{start_char + @as(u32, @intCast(name.len))});
                try w.writeAll("}}}}");
            }
        } else if (query.len > 0 and query[0] == '$') {
            // $-prefixed query → search local_vars for global variables
            const gv_ws_stmt = try self.db.prepare(
                \\SELECT DISTINCT lv.name, lv.line, lv.col, f.path
                \\FROM local_vars lv JOIN files f ON lv.file_id=f.id
                \\WHERE lv.name LIKE ? ESCAPE '\' AND lv.name LIKE '$%' AND f.is_gem = 0
                \\ORDER BY lv.name LIMIT 100
            );
            defer gv_ws_stmt.finalize();
            gv_ws_stmt.bind_text(1, pattern);
            while (try gv_ws_stmt.step()) {
                if (!first) try w.writeByte(',');
                first = false;
                result_count += 1;
                const gv_name = gv_ws_stmt.column_text(0);
                const gv_line = gv_ws_stmt.column_int(1);
                const gv_col  = gv_ws_stmt.column_int(2);
                const gv_path = gv_ws_stmt.column_text(3);
                const gv_start_char = self.toClientColFromPath(&frc_ws, gv_path, gv_line - 1, gv_col);
                try w.writeAll("{\"name\":");
                try writeEscapedJson(w, gv_name);
                try w.print(",\"kind\":13,\"location\":{{\"uri\":\"file://", .{});
                try writePathAsUri(w, gv_path);
                try w.writeAll("\",\"range\":{\"start\":{\"line\":");
                try w.print("{d}", .{gv_line - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{gv_start_char});
                try w.writeAll("},\"end\":{\"line\":");
                try w.print("{d}", .{gv_line - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{gv_start_char + @as(u32, @intCast(gv_name.len))});
                try w.writeAll("}}}}");
            }
        } else {
            const sql = if (query.len > 0)
                "SELECT s.name, s.kind, s.line, s.col, f.path, s.parent_name FROM symbols s JOIN files f ON s.file_id = f.id WHERE s.name LIKE ? ESCAPE '\\' AND f.is_gem = 0 ORDER BY length(s.name), s.name LIMIT 500"
            else
                "SELECT s.name, s.kind, s.line, s.col, f.path, s.parent_name FROM symbols s JOIN files f ON s.file_id = f.id WHERE f.is_gem = 0 ORDER BY s.name LIMIT 100";
            const stmt = try self.db.prepare(sql);
            defer stmt.finalize();
            if (query.len > 0) stmt.bind_text(1, prefix_pattern);
            while (try stmt.step()) {
                if (!first) try w.writeByte(',');
                first = false;
                result_count += 1;
                const name = stmt.column_text(0);
                const kind_str = stmt.column_text(1);
                const line = stmt.column_int(2);
                const col = stmt.column_int(3);
                const path = stmt.column_text(4);
                const cname = stmt.column_text(5);
                const kind_num: u8 = if (std.mem.eql(u8, kind_str, "class")) 5 else if (std.mem.eql(u8, kind_str, "module")) 2 else if (std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) 6 else if (std.mem.eql(u8, kind_str, "constant")) 13 else 14;
                const start_char = self.toClientColFromPath(&frc_ws, path, line - 1, col);
                try w.writeAll("{\"name\":");
                try writeEscapedJson(w, name);
                try w.print(",\"kind\":{d},\"location\":{{\"uri\":\"file://", .{kind_num});
                try writePathAsUri(w, path);
                try w.writeAll("\",\"range\":{\"start\":{\"line\":");
                try w.print("{d}", .{line - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{start_char});
                try w.writeAll("},\"end\":{\"line\":");
                try w.print("{d}", .{line - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{start_char + @as(u32, @intCast(name.len))});
                try w.writeAll("}}}");
                if (cname.len > 0) {
                    try w.writeAll(",\"containerName\":");
                    try writeEscapedJson(w, cname);
                }
                try w.writeByte('}');
            }

            // Infix fallback: add symbols where query appears anywhere but not as prefix
            if (result_count < 10 and query.len > 0) {
                const infix_stmt = try self.db.prepare(
                    \\SELECT s.name, s.kind, s.line, s.col, f.path, s.parent_name
                    \\FROM symbols s JOIN files f ON s.file_id = f.id
                    \\WHERE s.name LIKE ? ESCAPE '\' AND s.name NOT LIKE ? ESCAPE '\'
                    \\LIMIT 100
                );
                defer infix_stmt.finalize();
                infix_stmt.bind_text(1, pattern);
                infix_stmt.bind_text(2, prefix_pattern);
                while (try infix_stmt.step()) {
                    if (!first) try w.writeByte(',');
                    first = false;
                    const name = infix_stmt.column_text(0);
                    const kind_str = infix_stmt.column_text(1);
                    const line = infix_stmt.column_int(2);
                    const col = infix_stmt.column_int(3);
                    const path = infix_stmt.column_text(4);
                    const cname = infix_stmt.column_text(5);
                    const kind_num: u8 = if (std.mem.eql(u8, kind_str, "class")) 5 else if (std.mem.eql(u8, kind_str, "module")) 2 else if (std.mem.eql(u8, kind_str, "def")) 6 else if (std.mem.eql(u8, kind_str, "constant")) 13 else 14;
                    const start_char = self.toClientColFromPath(&frc_ws, path, line - 1, col);
                    try w.writeAll("{\"name\":");
                    try writeEscapedJson(w, name);
                    try w.print(",\"kind\":{d},\"location\":{{\"uri\":\"file://", .{kind_num});
                    try writePathAsUri(w, path);
                    try w.writeAll("\",\"range\":{\"start\":{\"line\":");
                    try w.print("{d}", .{line - 1});
                    try w.writeAll(",\"character\":");
                    try w.print("{d}", .{start_char});
                    try w.writeAll("},\"end\":{\"line\":");
                    try w.print("{d}", .{line - 1});
                    try w.writeAll(",\"character\":");
                    try w.print("{d}", .{start_char + @as(u32, @intCast(name.len))});
                    try w.writeAll("}}}");
                    if (cname.len > 0) {
                        try w.writeAll(",\"containerName\":");
                        try writeEscapedJson(w, cname);
                    }
                    try w.writeByte('}');
                }
            }

            // Fuzzy: CamelCase initials + subsequence (for queries like "UC" → UserController)
            if (result_count < 10 and query.len >= 2) {
                const fuzzy_exclude = try buildQueryPattern(self.alloc, query);
                defer self.alloc.free(fuzzy_exclude);
                const fuzzy_stmt = try self.db.prepare(
                    \\SELECT s.name, s.kind, s.line, s.col, f.path
                    \\FROM symbols s JOIN files f ON s.file_id = f.id
                    \\WHERE s.name NOT LIKE ? ESCAPE '\'
                    \\LIMIT 500
                );
                defer fuzzy_stmt.finalize();
                fuzzy_stmt.bind_text(1, fuzzy_exclude);
                while (try fuzzy_stmt.step()) {
                    const fname = fuzzy_stmt.column_text(0);
                    if (!matchesCamelInitials(query, fname) and !isSubsequence(query, fname)) continue;
                    if (!first) try w.writeByte(',');
                    first = false;
                    result_count += 1;
                    const fkind_str = fuzzy_stmt.column_text(1);
                    const fline = fuzzy_stmt.column_int(2);
                    const fcol = fuzzy_stmt.column_int(3);
                    const fpath = fuzzy_stmt.column_text(4);
                    const fkind_num: u8 = if (std.mem.eql(u8, fkind_str, "class")) 5 else if (std.mem.eql(u8, fkind_str, "module")) 2 else if (std.mem.eql(u8, fkind_str, "def") or std.mem.eql(u8, fkind_str, "classdef")) 6 else if (std.mem.eql(u8, fkind_str, "constant")) 13 else 14;
                    const fstart_char = self.toClientColFromPath(&frc_ws, fpath, fline - 1, fcol);
                    try w.writeAll("{\"name\":");
                    try writeEscapedJson(w, fname);
                    try w.print(",\"kind\":{d},\"location\":{{\"uri\":\"file://", .{fkind_num});
                    try writePathAsUri(w, fpath);
                    try w.writeAll("\",\"range\":{\"start\":{\"line\":");
                    try w.print("{d}", .{fline - 1});
                    try w.writeAll(",\"character\":");
                    try w.print("{d}", .{fstart_char});
                    try w.writeAll("},\"end\":{\"line\":");
                    try w.print("{d}", .{fline - 1});
                    try w.writeAll(",\"character\":");
                    try w.print("{d}", .{fstart_char + @as(u32, @intCast(fname.len))});
                    try w.writeAll("}}}");
                    try w.writeByte('}');
                }
            }
        }
        try w.writeByte(']');

        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = try aw.toOwnedSlice(),
            .@"error" = null,
        };
    }

    fn handleDidSave(self: *Server, msg: types.RequestMessage) void {
        const params = msg.params orelse return;
        const obj = switch (params) {
            .object => |o| o,
            else => return,
        };
        const td_val = obj.get("textDocument") orelse return;
        const td = switch (td_val) {
            .object => |o| o,
            else => return,
        };
        const uri_val = td.get("uri") orelse return;
        const uri = switch (uri_val) {
            .string => |s| s,
            else => return,
        };
        const path = uriToPath(self.alloc, uri) catch return;
        defer self.alloc.free(path);
        if (!self.pathInBounds(path)) return;
        if (self.isExcludedPath(path)) return;
        if (obj.get("text")) |tv| {
            if (tv == .string) {
                const raw_text = tv.string;
                const buf = self.alloc.dupe(u8, raw_text) catch null;
                if (buf) |b| {
                    const norm = normalizeCRLF(b);
                    const norm_owned = self.alloc.dupe(u8, norm) catch blk: {
                        self.alloc.free(b);
                        break :blk null;
                    };
                    self.alloc.free(b);
                    if (norm_owned) |n| {
                        defer self.alloc.free(n);
                        var index_failed = false;
                        self.db_mutex.lock();
                        indexer.indexSource(n, path, self.db, self.alloc) catch { index_failed = true; };
                        self.db_mutex.unlock();
                        if (index_failed) self.sendLogMessage(2, "refract: index failed on save");
                        self.publishDiagnostics(uri, path, true);
                        return;
                    }
                }
            }
        }
        const paths = [_][]const u8{path};
        var reindex_save_failed = false;
        self.db_mutex.lock();
        indexer.reindex(self.db, &paths, false, self.alloc, self.max_file_size.load(.monotonic)) catch { reindex_save_failed = true; };
        self.db_mutex.unlock();
        if (reindex_save_failed) self.sendLogMessage(2, "refract: reindex failed on save");
        self.publishDiagnostics(uri, path, true);
    }

    fn handleDidChange(self: *Server, msg: types.RequestMessage) void {
        const params = msg.params orelse return;
        const obj = switch (params) {
            .object => |o| o,
            else => return,
        };
        const td_val = obj.get("textDocument") orelse return;
        const td = switch (td_val) {
            .object => |o| o,
            else => return,
        };
        const uri_val = td.get("uri") orelse return;
        const uri = switch (uri_val) {
            .string => |s| s,
            else => return,
        };
        const incoming_version: i64 = if (td.get("version")) |v|
            switch (v) { .integer => |i| i, else => std.math.minInt(i64) }
        else
            std.math.minInt(i64);
        const stored_version = self.open_docs_version.get(uri) orelse std.math.minInt(i64);
        if (incoming_version <= stored_version) return;
        const changes_val = obj.get("contentChanges") orelse return;
        const changes = switch (changes_val) {
            .array => |a| a,
            else => return,
        };
        if (changes.items.len == 0) return;
        if (changes.items.len > 1) self.sendLogMessage(4, "refract: unexpected multiple contentChanges");
        const first = switch (changes.items[0]) {
            .object => |o| o,
            else => return,
        };
        const text_val = first.get("text") orelse return;
        const text = switch (text_val) {
            .string => |s| s,
            else => return,
        };

        const real_path = uriToPath(self.alloc, uri) catch return;
        defer self.alloc.free(real_path);
        if (!self.pathInBounds(real_path)) return;

        {
            const already_tracked = self.open_docs.contains(uri);
            const doc_key = self.alloc.dupe(u8, uri) catch return;
            const raw_val = self.alloc.dupe(u8, text) catch {
                self.alloc.free(doc_key);
                return;
            };
            const norm_val = normalizeCRLF(raw_val);
            var doc_val: []u8 = if (norm_val.len < raw_val.len)
                (self.alloc.realloc(raw_val, norm_val.len) catch blk: {
                    defer self.alloc.free(raw_val);
                    break :blk self.alloc.dupe(u8, norm_val) catch {
                        self.alloc.free(doc_key);
                        return;
                    };
                })
            else
                raw_val;
            if (doc_val.len >= 3 and doc_val[0] == 0xEF and doc_val[1] == 0xBB and doc_val[2] == 0xBF) {
                const stripped = self.alloc.dupe(u8, doc_val[3..]) catch doc_val;
                if (stripped.ptr != doc_val.ptr) { self.alloc.free(doc_val); doc_val = stripped; }
            }
            self.open_docs_mu.lock();
            defer self.open_docs_mu.unlock();
            if (self.open_docs.fetchRemove(doc_key)) |old| {
                self.alloc.free(old.key);
                self.alloc.free(old.value);
            }
            _ = if (self.open_docs_version.fetchRemove(uri)) |old_ver| blk: {
                self.alloc.free(old_ver.key);
                break :blk {};
            } else {};
            const ver_key = self.alloc.dupe(u8, uri) catch {
                self.alloc.free(doc_key);
                self.alloc.free(doc_val);
                return;
            };
            self.open_docs_version.put(self.alloc, ver_key, incoming_version) catch self.alloc.free(ver_key);
            self.open_docs.put(self.alloc, doc_key, doc_val) catch {
                self.alloc.free(doc_key);
                self.alloc.free(doc_val);
            };
            if (!already_tracked) {
                const order_key2 = self.alloc.dupe(u8, uri) catch "";
                if (order_key2.len > 0) self.open_docs_order.append(self.alloc, order_key2) catch self.alloc.free(order_key2);
            }
            while (self.open_docs.count() > OPEN_DOC_CACHE_SIZE) {
                if (self.open_docs_order.items.len == 0) break;
                const lru_uri = self.open_docs_order.swapRemove(0);
                defer self.alloc.free(@constCast(lru_uri));
                if (self.open_docs.fetchRemove(lru_uri)) |evicted| {
                    self.alloc.free(evicted.key);
                    self.alloc.free(evicted.value);
                }
                if (self.open_docs_version.fetchRemove(lru_uri)) |old_ver| {
                    self.alloc.free(old_ver.key);
                }
            }
        }
        // Mark URI dirty with current timestamp; flush happens lazily at query time
        const now_ms = std.time.milliTimestamp();
        {
            self.last_index_mu.lock();
            defer self.last_index_mu.unlock();
            const gop = self.last_index_ms.getOrPut(uri) catch {
                self.publishDiagnostics(uri, real_path, false);
                return;
            };
            if (!gop.found_existing) {
                if (self.alloc.dupe(u8, uri)) |k| {
                    gop.key_ptr.* = k;
                } else |_| {
                    _ = self.last_index_ms.remove(uri);
                }
            }
            gop.value_ptr.* = now_ms;
        }
        self.publishDiagnostics(uri, real_path, false);
    }

    fn handleDidChangeWatchedFiles(self: *Server, msg: types.RequestMessage) void {
        const params = msg.params orelse return;
        const obj = switch (params) {
            .object => |o| o,
            else => return,
        };
        const changes_val = obj.get("changes") orelse return;
        const changes = switch (changes_val) {
            .array => |a| a,
            else => return,
        };

        var watched_overflow = false;
        for (changes.items) |change| {
            const c = switch (change) {
                .object => |o| o,
                else => continue,
            };
            const uri_val = c.get("uri") orelse continue;
            const uri = switch (uri_val) {
                .string => |s| s,
                else => continue,
            };
            const type_val = c.get("type") orelse continue;
            const change_type: i64 = switch (type_val) {
                .integer => |i| i,
                else => continue,
            };
            const path = uriToPath(self.alloc, uri) catch continue;
            if (!self.pathInBounds(path)) { self.alloc.free(path); continue; }
            defer self.alloc.free(path);
            const is_indexed = std.mem.endsWith(u8, path, ".rb") or
                std.mem.endsWith(u8, path, ".rbs") or
                std.mem.endsWith(u8, path, ".rbi") or
                std.mem.endsWith(u8, path, ".erb") or
                std.mem.endsWith(u8, path, ".rake") or
                std.mem.endsWith(u8, path, ".gemspec") or
                std.mem.endsWith(u8, path, ".ru") or
                std.mem.endsWith(u8, path, "/Rakefile") or
                std.mem.endsWith(u8, path, "/Gemfile");
            if (!is_indexed) continue;

            if (change_type == 3) {
                self.last_index_mu.lock();
                if (self.last_index_ms.fetchRemove(uri)) |kv| self.alloc.free(kv.key);
                self.last_index_mu.unlock();
                self.incr_paths_mu.lock();
                var incr_idx: usize = 0;
                while (incr_idx < self.incr_paths.items.len) {
                    if (std.mem.eql(u8, self.incr_paths.items[incr_idx], path)) {
                        self.alloc.free(self.incr_paths.items[incr_idx]);
                        _ = self.incr_paths.swapRemove(incr_idx);
                    } else {
                        incr_idx += 1;
                    }
                }
                self.incr_paths_mu.unlock();
                // Mark path as explicitly deleted so background workers skip it
                self.deleted_paths_mu.lock();
                if (self.alloc.dupe(u8, path)) |dp| {
                    if (self.deleted_paths.count() < MAX_DELETED_PATHS) {
                        self.deleted_paths.put(self.alloc, dp, {}) catch self.alloc.free(dp);
                    } else {
                        self.alloc.free(dp);
                    }
                } else |_| {}
                self.deleted_paths_mu.unlock();
                self.db_mutex.lock();
                self.db.begin() catch {
                    self.db_mutex.unlock();
                    continue;
                };
                const del = self.db.prepare("DELETE FROM files WHERE path = ?") catch {
                    self.db.rollback() catch {}; // cleanup — ignore error
                    self.db_mutex.unlock();
                    continue;
                };
                del.bind_text(1, path);
                _ = del.step() catch |e| {
                    self.logErr("delete file step", e);
                    del.finalize();
                    self.db.rollback() catch {}; // cleanup — ignore error
                    self.db_mutex.unlock();
                    continue;
                };
                del.finalize();
                self.db.commit() catch |e| {
                    self.logErr("delete file commit", e);
                    self.db.rollback() catch {}; // cleanup — ignore error
                };
                self.db_mutex.unlock();
            } else {
                // Remove from deleted_paths if the file is being re-created/modified
                self.deleted_paths_mu.lock();
                if (self.deleted_paths.fetchRemove(path)) |old_dp| self.alloc.free(old_dp.key);
                self.deleted_paths_mu.unlock();
                // Try synchronous reindex; if db_mutex is contended, queue for background
                if (self.db_mutex.tryLock()) {
                    const paths_arr = [_][]const u8{path};
                    _ = indexer.reindex(self.db, &paths_arr, false, self.alloc, self.max_file_size.load(.monotonic)) catch |e| {
                        var buf: [128]u8 = undefined;
                        const m = std.fmt.bufPrint(&buf, "refract: reindex failed for watched file: {s}", .{@errorName(e)}) catch "refract: reindex failed for watched file";
                        self.sendLogMessage(2, m);
                    };
                    self.db_mutex.unlock();
                } else {
                    const duped = self.alloc.dupe(u8, path) catch continue;
                    self.incr_paths_mu.lock();
                    if (self.incr_paths.items.len < MAX_INCR_PATHS) {
                        self.incr_paths.append(self.alloc, duped) catch {
                            self.alloc.free(duped);
                            self.incr_paths_mu.unlock();
                            continue;
                        };
                    } else {
                        self.alloc.free(duped);
                        watched_overflow = true;
                    }
                    self.incr_paths_mu.unlock();
                }
            }
        }
        if (watched_overflow) {
            self.showUserError("refract: file change queue full — some files skipped. Run Refract: Force Reindex.");
            self.startBgIndexer();
        }
    }

    fn handleDidOpen(self: *Server, msg: types.RequestMessage) void {
        const params = msg.params orelse return;
        const obj = switch (params) {
            .object => |o| o,
            else => return,
        };
        const td_val = obj.get("textDocument") orelse return;
        const td = switch (td_val) {
            .object => |o| o,
            else => return,
        };
        const uri_val = td.get("uri") orelse return;
        const uri = switch (uri_val) {
            .string => |s| s,
            else => return,
        };
        const path = uriToPath(self.alloc, uri) catch return;
        defer self.alloc.free(path);
        if (!self.pathInBounds(path)) return;
        if (td.get("text")) |txt_val| {
            if (txt_val == .string) {
                var index_open_err: ?[]const u8 = null;
                var index_open_err_buf: [512]u8 = undefined;
                self.db_mutex.lock();
                indexer.indexSource(txt_val.string, path, self.db, self.alloc) catch |e| {
                    index_open_err = std.fmt.bufPrint(&index_open_err_buf, "refract: index failed for {s}: {s}", .{ path, @errorName(e) }) catch "refract: index failed";
                };
                self.db_mutex.unlock();
                if (index_open_err) |msg_str| self.sendLogMessage(2, msg_str);
                const doc_key = self.alloc.dupe(u8, uri) catch return;
                const raw_val = self.alloc.dupe(u8, txt_val.string) catch {
                    self.alloc.free(doc_key);
                    return;
                };
                const norm_val = normalizeCRLF(raw_val);
                var doc_val: []u8 = if (norm_val.len < raw_val.len)
                    (self.alloc.realloc(raw_val, norm_val.len) catch blk: {
                        defer self.alloc.free(raw_val);
                        break :blk self.alloc.dupe(u8, norm_val) catch {
                            self.alloc.free(doc_key);
                            return;
                        };
                    })
                else
                    raw_val;
                if (doc_val.len >= 3 and doc_val[0] == 0xEF and doc_val[1] == 0xBB and doc_val[2] == 0xBF) {
                    const stripped = self.alloc.dupe(u8, doc_val[3..]) catch doc_val;
                    if (stripped.ptr != doc_val.ptr) { self.alloc.free(doc_val); doc_val = stripped; }
                }
                self.open_docs_mu.lock();
                defer self.open_docs_mu.unlock();
                if (self.open_docs.fetchRemove(doc_key)) |old| {
                    self.alloc.free(old.key);
                    self.alloc.free(old.value);
                }
                self.open_docs.put(self.alloc, doc_key, doc_val) catch {
                    self.alloc.free(doc_key);
                    self.alloc.free(doc_val);
                    return;
                };
                const open_version: i64 = if (td.get("version")) |v|
                    switch (v) { .integer => |i| i, else => std.math.minInt(i64) }
                else
                    std.math.minInt(i64);
                _ = if (self.open_docs_version.fetchRemove(uri)) |old_ver| blk: {
                    self.alloc.free(old_ver.key);
                    break :blk {};
                } else {};
                const ver_key2 = self.alloc.dupe(u8, uri) catch "";
                if (ver_key2.len > 0) self.open_docs_version.put(self.alloc, ver_key2, open_version) catch self.alloc.free(ver_key2);
                const order_key = self.alloc.dupe(u8, uri) catch "";
                if (order_key.len > 0) self.open_docs_order.append(self.alloc, order_key) catch self.alloc.free(order_key);
                while (self.open_docs.count() > OPEN_DOC_CACHE_SIZE) {
                    if (self.open_docs_order.items.len == 0) break;
                    const oldest = self.open_docs_order.swapRemove(0);
                    defer self.alloc.free(@constCast(oldest));
                    if (self.open_docs.fetchRemove(oldest)) |old| {
                        self.alloc.free(old.key);
                        self.alloc.free(old.value);
                    }
                    if (self.open_docs_version.fetchRemove(oldest)) |old_ver| {
                        self.alloc.free(old_ver.key);
                    }
                }
            }
        } else {
            const paths = [_][]const u8{path};
            var reindex_open_failed = false;
            self.db_mutex.lock();
            indexer.reindex(self.db, &paths, false, self.alloc, self.max_file_size.load(.monotonic)) catch { reindex_open_failed = true; };
            self.db_mutex.unlock();
            if (reindex_open_failed) self.sendLogMessage(2, "refract: reindex failed on open");
        }
        self.publishDiagnostics(uri, path, false);
    }

    fn handleDidClose(self: *Server, msg: types.RequestMessage) void {
        const params = msg.params orelse return;
        const obj = switch (params) {
            .object => |o| o,
            else => return,
        };
        const td_val = obj.get("textDocument") orelse return;
        const td = switch (td_val) {
            .object => |o| o,
            else => return,
        };
        const uri_val = td.get("uri") orelse return;
        const uri = switch (uri_val) {
            .string => |s| s,
            else => return,
        };
        {
            self.open_docs_mu.lock();
            defer self.open_docs_mu.unlock();
            if (self.open_docs.fetchRemove(uri)) |old| {
                self.alloc.free(old.key);
                self.alloc.free(old.value);
            }
            if (self.open_docs_version.fetchRemove(uri)) |old_ver| self.alloc.free(old_ver.key);
            var i: usize = self.open_docs_order.items.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, self.open_docs_order.items[i], uri)) {
                    const removed = self.open_docs_order.swapRemove(i);
                    self.alloc.free(@constCast(removed));
                    break;
                }
            }
        }
        self.last_index_mu.lock();
        if (self.last_index_ms.fetchRemove(uri)) |kv| self.alloc.free(kv.key);
        self.last_index_mu.unlock();
        {
            const close_path = uriToPath(self.alloc, uri) catch return;
            defer self.alloc.free(close_path);
            if (self.pathInBounds(close_path)) {
                const paths = [_][]const u8{close_path};
                var close_err: ?[]const u8 = null;
                var close_err_buf: [512]u8 = undefined;
                self.db_mutex.lock();
                indexer.reindex(self.db, &paths, false, self.alloc, self.max_file_size.load(.monotonic)) catch |e| {
                    close_err = std.fmt.bufPrint(&close_err_buf, "refract: index failed for {s}: {s}", .{ close_path, @errorName(e) }) catch "refract: index failed";
                };
                self.db_mutex.unlock();
                if (close_err) |msg_str| self.sendLogMessage(2, msg_str);
            }
        }
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":") catch return;
        writeEscapedJson(w, uri) catch return;
        w.writeAll(",\"diagnostics\":[]}}") catch return;
        const json = aw.toOwnedSlice() catch return;
        defer self.alloc.free(json);
        self.sendNotification(json);
    }

    fn handleDocumentSymbol(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        if (self.isCancelled(msg.id)) return null;
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
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

        const stmt = try self.db.prepare(
            \\SELECT s.name, s.kind, s.line, s.col, s.return_type, s.end_line
            \\FROM symbols s JOIN files f ON s.file_id = f.id
            \\WHERE f.path = ? ORDER BY s.line
        );
        defer stmt.finalize();
        stmt.bind_text(1, path);

        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        const src_opt: ?[]u8 = self.readSourceForUri(uri, path) catch null;
        defer if (src_opt) |s| self.alloc.free(s);
        const doc_src = src_opt orelse "";

        const DocSym = struct { name: []const u8, kind: []const u8, line: i64, col: i64, return_type: []const u8, end_line: i64 };
        var syms = std.ArrayList(DocSym){};
        while (try stmt.step()) {
            try syms.append(a, .{
                .name = try a.dupe(u8, stmt.column_text(0)),
                .kind = try a.dupe(u8, stmt.column_text(1)),
                .line = stmt.column_int(2),
                .col  = stmt.column_int(3),
                .return_type = try a.dupe(u8, stmt.column_text(4)),
                .end_line = stmt.column_int(5),
            });
        }

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeByte('[');

        var first_top = true;
        var si: usize = 0;
        while (si < syms.items.len) {
            const s = syms.items[si];
            const is_container = std.mem.eql(u8, s.kind, "class") or std.mem.eql(u8, s.kind, "module");
            if (is_container) {
                var next_ci: usize = si + 1;
                while (next_ci < syms.items.len) : (next_ci += 1) {
                    const nk = syms.items[next_ci].kind;
                    if (std.mem.eql(u8, nk, "class") or std.mem.eql(u8, nk, "module")) break;
                }
                const end_line: i64 = if (s.end_line > 0) s.end_line else if (next_ci < syms.items.len) syms.items[next_ci].line - 1 else s.line + 50;
                const kind_num: u8 = if (std.mem.eql(u8, s.kind, "class")) 5 else 2;
                if (!first_top) try w.writeByte(',');
                first_top = false;
                try w.writeAll("{\"name\":");
                try writeEscapedJson(w, s.name);
                try w.print(",\"kind\":{d}", .{kind_num});
                try w.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}}", .{ s.line - 1, end_line - 1 });
                emitSelRange(w, doc_src, self, s.line, s.col, s.name);
                try w.writeAll(",\"children\":[");
                var first_child = true;
                var ci: usize = si + 1;
                while (ci < next_ci) : (ci += 1) {
                    const c = syms.items[ci];
                    if (std.mem.eql(u8, c.kind, "def") or std.mem.eql(u8, c.kind, "classdef") or std.mem.eql(u8, c.kind, "constant")) {
                        const ck: u8 = if (std.mem.eql(u8, c.kind, "constant")) 13 else 6;
                        if (!first_child) try w.writeByte(',');
                        first_child = false;
                        try w.writeAll("{\"name\":");
                        try writeEscapedJson(w, c.name);
                        try w.print(",\"kind\":{d}", .{ck});
                        if (c.return_type.len > 0) {
                            try w.writeAll(",\"detail\":");
                            try writeEscapedJson(w, c.return_type);
                        }
                        const c_end: i64 = if (c.end_line > 0) c.end_line - 1 else c.line - 1;
                        try w.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}}", .{ c.line - 1, c_end });
                        emitSelRange(w, doc_src, self, c.line, c.col, c.name);
                        try w.writeByte('}');
                    }
                }
                try w.writeAll("]}");
                si = next_ci;
            } else {
                const kind_num: u8 = if (std.mem.eql(u8, s.kind, "def") or std.mem.eql(u8, s.kind, "classdef")) 6 else if (std.mem.eql(u8, s.kind, "constant")) 13 else 14;
                if (!first_top) try w.writeByte(',');
                first_top = false;
                try w.writeAll("{\"name\":");
                try writeEscapedJson(w, s.name);
                try w.print(",\"kind\":{d}", .{kind_num});
                if (s.return_type.len > 0) {
                    try w.writeAll(",\"detail\":");
                    try writeEscapedJson(w, s.return_type);
                }
                const s_end: i64 = if (s.end_line > 0) s.end_line - 1 else s.line - 1;
                try w.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}}", .{ s.line - 1, s_end });
                emitSelRange(w, doc_src, self, s.line, s.col, s.name);
                try w.writeByte('}');
                si += 1;
            }
        }

        try w.writeByte(']');
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    }

    fn handleFoldingRange(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        if (self.isCancelled(msg.id)) return null;
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
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

        const file_stmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
        defer file_stmt.finalize();
        file_stmt.bind_text(1, path);
        if (!(try file_stmt.step())) return emptyResult(msg);
        const file_id = file_stmt.column_int(0);

        const stmt = try self.db.prepare("SELECT kind, line, end_line FROM symbols WHERE file_id=? ORDER BY line");
        defer stmt.finalize();
        stmt.bind_int(1, file_id);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeAll("[");
        var first = true;

        var sym_ranges = std.ArrayList(struct { start: i64, end: i64 }){};
        defer sym_ranges.deinit(self.alloc);

        while (try stmt.step()) {
            const kind = stmt.column_text(0);
            const sym_line = stmt.column_int(1);
            const sym_end = stmt.column_int(2);
            if ((std.mem.eql(u8, kind, "class") or std.mem.eql(u8, kind, "module") or std.mem.eql(u8, kind, "def") or std.mem.eql(u8, kind, "classdef")) and sym_end > sym_line) {
                if (!first) try w.writeByte(',');
                first = false;
                try w.print("{{\"startLine\":{d},\"endLine\":{d},\"kind\":\"region\"}}", .{ sym_line - 1, sym_end - 1 });
                sym_ranges.append(self.alloc, .{ .start = sym_line - 1, .end = sym_end - 1 }) catch {};
            }
        }

        const source = self.readSourceForUri(uri, path) catch null;
        if (source) |src| {
            defer self.alloc.free(src);
            var line_list = std.ArrayList([]const u8){};
            defer line_list.deinit(self.alloc);
            var lit = std.mem.splitScalar(u8, src, '\n');
            while (lit.next()) |ln| {
                line_list.append(self.alloc, ln) catch break;
            }
            const lines = line_list.items;

            var stack_lines = std.ArrayList(i64){};
            defer stack_lines.deinit(self.alloc);

            for (lines, 0..) |raw_line, li| {
                const trimmed = std.mem.trim(u8, raw_line, " \t\r");
                const is_do = std.mem.endsWith(u8, trimmed, " do") or
                    (std.mem.indexOfScalar(u8, trimmed, '|') != null and std.mem.endsWith(u8, trimmed, "|"));
                var is_kw = false;
                for (ruby_block_keywords) |k| {
                    if (std.mem.startsWith(u8, trimmed, k)) { is_kw = true; break; }
                }
                if (is_do or is_kw) {
                    stack_lines.append(self.alloc, @intCast(li)) catch {};
                } else if (std.mem.eql(u8, trimmed, "end") or
                           std.mem.startsWith(u8, trimmed, "end ") or
                           std.mem.startsWith(u8, trimmed, "end#")) {
                    if (stack_lines.items.len > 0) {
                        const start_l = stack_lines.pop() orelse continue;
                        const end_l: i64 = @intCast(li);
                        if (end_l > start_l + 1) {
                            var dup = false;
                            for (sym_ranges.items) |sr| {
                                if (sr.start == start_l and sr.end == end_l) { dup = true; break; }
                            }
                            if (!dup) {
                                if (!first) try w.writeByte(',');
                                first = false;
                                try w.print("{{\"startLine\":{d},\"endLine\":{d},\"kind\":\"region\"}}", .{ start_l, end_l - 1 });
                            }
                        }
                    }
                }
            }

            // Comment block folding: fold 3 or more consecutive '#'-prefixed comment lines
            var comment_start: ?usize = null;
            for (lines, 0..) |raw_line, li| {
                const trimmed = std.mem.trim(u8, raw_line, " \t\r");
                if (std.mem.startsWith(u8, trimmed, "#")) {
                    if (comment_start == null) comment_start = li;
                } else {
                    if (comment_start) |cs| {
                        if (li - cs >= 3) {
                            if (!first) try w.writeByte(',');
                            first = false;
                            try w.print("{{\"startLine\":{d},\"endLine\":{d},\"kind\":\"comment\"}}", .{ cs, li - 1 });
                        }
                        comment_start = null;
                    }
                }
            }
            if (comment_start) |cs| {
                if (lines.len - cs >= 3) {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try w.print("{{\"startLine\":{d},\"endLine\":{d},\"kind\":\"comment\"}}", .{ cs, lines.len - 1 });
                }
            }

            // Require block folding: fold 2 or more consecutive require/require_relative lines
            var req_start: ?usize = null;
            var req_end: usize = 0;
            var req_count: usize = 0;
            for (lines, 0..) |raw_line, li| {
                const trimmed = std.mem.trim(u8, raw_line, " \t\r");
                const is_req = std.mem.startsWith(u8, trimmed, "require ") or
                               std.mem.startsWith(u8, trimmed, "require_relative ");
                if (is_req) {
                    if (req_start == null) req_start = li;
                    req_end = li;
                    req_count += 1;
                } else if (trimmed.len > 0) {
                    if (req_start) |rs| {
                        if (req_count >= 2) {
                            if (!first) try w.writeByte(',');
                            first = false;
                            try w.print("{{\"startLine\":{d},\"endLine\":{d},\"kind\":\"imports\"}}", .{ rs, req_end });
                        }
                        req_start = null;
                        req_count = 0;
                    }
                }
            }
            if (req_start) |rs| {
                if (req_count >= 2) {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try w.print("{{\"startLine\":{d},\"endLine\":{d},\"kind\":\"imports\"}}", .{ rs, req_end });
                }
            }
        }

        try w.writeAll("]");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    }

    fn handleDefinition(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.flushDirtyUris();
        if (self.isCancelled(msg.id)) return null;
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
        const uri = extractTextDocumentUri(msg.params) orelse return emptyResult(msg);
        const pos = extractPosition(msg.params) orelse return emptyResult(msg);
        const line: u32 = pos.line;
        const character: u32 = pos.character;

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);
        if (!self.pathInBounds(path)) return emptyResult(msg);
        const source = self.readSourceForUri(uri, path) catch
            return emptyResult(msg);
        defer self.alloc.free(source);

        const offset = self.clientPosToOffset(source, line, character);

        if (resolveRequireTarget(self.alloc, self.db, source, offset, path)) |target_path| {
            defer self.alloc.free(target_path);
            const target_uri = pathToUri(self.alloc, target_path) catch return emptyResult(msg);
            defer self.alloc.free(target_uri);
            var req_aw = std.Io.Writer.Allocating.init(self.alloc);
            const rw = &req_aw.writer;
            if (self.client_caps_def_link) {
                // Scan for the enclosing quote characters to build originSelectionRange
                var qs = offset;
                while (qs > 0 and source[qs - 1] != '"' and source[qs - 1] != '\'' and source[qs - 1] != '\n') qs -= 1;
                if (qs > 0) qs -= 1; // include the opening quote
                var qe = offset;
                while (qe < source.len and source[qe] != '"' and source[qe] != '\'' and source[qe] != '\n') qe += 1;
                if (qe < source.len and (source[qe] == '"' or source[qe] == '\'')) qe += 1; // include closing quote
                const origin_sc = self.offsetToClientChar(source, qs, line);
                const origin_ec = self.offsetToClientChar(source, qe, line);
                try rw.print(
                    "[{{\"targetUri\":\"{s}\",\"targetRange\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}},\"targetSelectionRange\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}},\"originSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}]",
                    .{ target_uri, line, origin_sc, line, origin_ec },
                );
            } else {
                try rw.print("[{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}}}}]", .{target_uri});
            }
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try req_aw.toOwnedSlice(), .@"error" = null };
        }

        const word = extractWord(source, offset);
        if (word.len == 0) return emptyResult(msg);

        // Compute origin selection range for LocationLink support
        const word_start_offset = @intFromPtr(word.ptr) - @intFromPtr(source.ptr);
        const origin_char = self.offsetToClientChar(source, word_start_offset, line);
        const origin_end_char = self.offsetToClientChar(source, word_start_offset + word.len, line);
        const def_origin = DefOrigin{ .line = line, .start_char = origin_char, .end_char = origin_end_char };

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeByte('[');
        var found_any = false;
        var frc_def: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer {
            var frc_it = frc_def.iterator();
            while (frc_it.next()) |e| { self.alloc.free(e.key_ptr.*); self.alloc.free(e.value_ptr.*); }
            frc_def.deinit(self.alloc);
        }

        try queryAndEmitDefinitions(self, w, word, &found_any, &frc_def, def_origin);

        if (!found_any) {
            const qualified = extractQualifiedName(source, offset);
            if (!std.mem.eql(u8, qualified, word)) {
                try queryAndEmitDefinitions(self, w, qualified, &found_any, &frc_def, def_origin);
            }
        }

        if (!found_any) {
            const cursor_line: i64 = @intCast(line + 1);

            var def_word_start: usize = offset;
            while (def_word_start > 0 and isRubyIdent(source[def_word_start - 1])) def_word_start -= 1;
            var def_line_start: usize = 0;
            var dj: usize = 0;
            while (dj < def_word_start) : (dj += 1) {
                if (source[dj] == '\n') def_line_start = dj + 1;
            }
            const def_col_0: i64 = @intCast(def_word_start - def_line_start);

            const f_stmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
            defer f_stmt.finalize();
            f_stmt.bind_text(1, path);
            if (try f_stmt.step()) {
                const fid = f_stmt.column_int(0);
                const scope_opt = resolveScopeId(self, fid, word, cursor_line, def_col_0);
                const lv_stmt = if (scope_opt) |sid| blk: {
                    if (sid != 0) {
                        const s = try self.db.prepare(
                            \\SELECT name, line, col FROM local_vars
                            \\WHERE file_id=? AND name=? AND scope_id=?
                            \\ORDER BY line DESC LIMIT 1
                        );
                        s.bind_int(1, fid);
                        s.bind_text(2, word);
                        s.bind_int(3, sid);
                        break :blk s;
                    } else {
                        const s = try self.db.prepare(
                            \\SELECT name, line, col FROM local_vars
                            \\WHERE file_id=? AND name=? AND scope_id IS NULL
                            \\ORDER BY line DESC LIMIT 1
                        );
                        s.bind_int(1, fid);
                        s.bind_text(2, word);
                        break :blk s;
                    }
                } else blk: {
                    const s = try self.db.prepare(
                        \\SELECT name, line, col FROM local_vars
                        \\WHERE file_id = ? AND name = ? AND line <= ?
                        \\ORDER BY line DESC LIMIT 1
                    );
                    s.bind_int(1, fid);
                    s.bind_text(2, word);
                    s.bind_int(3, cursor_line);
                    break :blk s;
                };
                defer lv_stmt.finalize();
                if (try lv_stmt.step()) {
                    const lv_name = lv_stmt.column_text(0);
                    const lv_line = lv_stmt.column_int(1);
                    const lv_col = lv_stmt.column_int(2);
                    const lv_line_src = getLineSlice(source, @intCast(lv_line - 1));
                    const lv_start = self.toClientCol(lv_line_src, @intCast(lv_col));
                    try w.writeAll("{\"uri\":\"file://");
                    try writePathAsUri(w, path);
                    try w.writeAll("\",\"range\":{\"start\":{\"line\":");
                    try w.print("{d}", .{lv_line - 1});
                    try w.writeAll(",\"character\":");
                    try w.print("{d}", .{lv_start});
                    try w.writeAll("},\"end\":{\"line\":");
                    try w.print("{d}", .{lv_line - 1});
                    try w.writeAll(",\"character\":");
                    try w.print("{d}", .{lv_start + @as(u32, @intCast(lv_name.len))});
                    try w.writeAll("}}}");
                }
            }
        }

        try w.writeByte(']');

        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = try aw.toOwnedSlice(),
            .@"error" = null,
        };
    }

    fn flushIncrPaths(self: *Server) void {
        self.incr_paths_mu.lock();
        if (self.incr_paths.items.len == 0) {
            self.incr_paths_mu.unlock();
            return;
        }
        const batch = self.incr_paths.toOwnedSlice(self.alloc) catch {
            self.incr_paths_mu.unlock();
            return;
        };
        self.incr_paths = .{};
        self.incr_paths_mu.unlock();
        defer {
            for (batch) |p| self.alloc.free(p);
            self.alloc.free(batch);
        }
        // Filter out explicitly deleted paths
        var filtered = std.ArrayList([]const u8){};
        defer filtered.deinit(self.alloc);
        self.deleted_paths_mu.lock();
        for (batch) |p| {
            if (!self.deleted_paths.contains(p)) filtered.append(self.alloc, p) catch {};
        }
        self.deleted_paths_mu.unlock();
        if (filtered.items.len == 0) return;
        self.db_mutex.lock();
        indexer.reindex(self.db, filtered.items, false, self.alloc, self.max_file_size.load(.monotonic)) catch |e| {
            var warn_buf: [128]u8 = undefined;
            const warn_msg = std.fmt.bufPrint(&warn_buf, "refract: batch reindex failed ({d} files): {s}", .{ filtered.items.len, @errorName(e) }) catch "refract: batch reindex failed";
            self.sendLogMessage(2, warn_msg);
        };
        self.db_mutex.unlock();
    }

    fn flushDirtyUris(self: *Server) void {
        const now = std.time.milliTimestamp();
        var due = std.ArrayList([]const u8){};
        defer due.deinit(self.alloc);
        {
            self.last_index_mu.lock();
            defer self.last_index_mu.unlock();
            var it = self.last_index_ms.iterator();
            while (it.next()) |e| {
                if (now - e.value_ptr.* >= 0)
                    due.append(self.alloc, e.key_ptr.*) catch {};
            }
        }
        for (due.items) |uri_key| {
            const path = uriToPath(self.alloc, uri_key) catch continue;
            defer self.alloc.free(path);
            if (self.open_docs.get(uri_key)) |src| {
                self.db_mutex.lock();
                indexer.indexSource(src, path, self.db, self.alloc) catch |e| {
                    var buf: [512]u8 = undefined;
                    const msg_str = std.fmt.bufPrint(&buf, "refract: index failed for {s}: {s}", .{ path, @errorName(e) }) catch "refract: index failed";
                    self.sendLogMessage(2, msg_str);
                };
                self.db_mutex.unlock();
            }
            self.last_index_mu.lock();
            if (self.last_index_ms.fetchRemove(uri_key)) |kv| self.alloc.free(kv.key);
            self.last_index_mu.unlock();
        }
    }

    fn handleHover(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.flushDirtyUris();
        if (self.isCancelled(msg.id)) return null;
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
        const uri = extractTextDocumentUri(msg.params) orelse return emptyResult(msg);
        const pos = extractPosition(msg.params) orelse return emptyResult(msg);
        const line: u32 = pos.line;
        const character: u32 = pos.character;

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);
        if (!self.pathInBounds(path)) return emptyResult(msg);
        const source = self.readSourceForUri(uri, path) catch
            return emptyResult(msg);
        defer self.alloc.free(source);

        const offset = self.clientPosToOffset(source, line, character);

        if (resolveRequireTarget(self.alloc, self.db, source, offset, path)) |target_path| {
            defer self.alloc.free(target_path);
            var rq_aw = std.Io.Writer.Allocating.init(self.alloc);
            const rq_w = &rq_aw.writer;
            try rq_w.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":\"**Requires:** `");
            try writeEscapedJsonContent(rq_w, target_path);
            try rq_w.writeAll("`\"}");
            try rq_w.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":999}}}}}}", .{ line, line });
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try rq_aw.toOwnedSlice(), .@"error" = null };
        }

        const word = extractWord(source, offset);
        if (word.len == 0) return emptyResult(msg);

        const hover_line_src = getLineSlice(source, line);
        const word_col_byte = if (@intFromPtr(word.ptr) >= @intFromPtr(hover_line_src.ptr))
            @intFromPtr(word.ptr) - @intFromPtr(hover_line_src.ptr)
        else 0;
        const hover_wc16 = self.toClientCol(hover_line_src, word_col_byte);
        const hover_we16 = utf8ColToUtf16(hover_line_src, @min(word_col_byte + word.len, hover_line_src.len));

        // Check local_vars first for concrete inferred types
        const cursor_line: i64 = @intCast(line + 1);
        const fstmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
        defer fstmt.finalize();
        fstmt.bind_text(1, path);
        if (try fstmt.step()) {
            const fid = fstmt.column_int(0);
            const lv_stmt = try self.db.prepare(
                "SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND line<=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 10"
            );
            defer lv_stmt.finalize();
            lv_stmt.bind_int(1, fid);
            lv_stmt.bind_text(2, word);
            lv_stmt.bind_int(3, cursor_line);
            var type_hints: [3][]u8 = undefined;
            var hint_count: usize = 0;
            while (try lv_stmt.step()) {
                const th = lv_stmt.column_text(0);
                var found = false;
                for (type_hints[0..hint_count]) |s| {
                    if (std.mem.eql(u8, s, th)) { found = true; break; }
                }
                if (!found and hint_count < 3) {
                    type_hints[hint_count] = self.alloc.dupe(u8, th) catch break;
                    hint_count += 1;
                }
            }
            defer for (type_hints[0..hint_count]) |t| self.alloc.free(t);
            if (hint_count > 0) {
                var aw = std.Io.Writer.Allocating.init(self.alloc);
                const w = &aw.writer;
                try w.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":\"`");
                try writeEscapedJsonContent(w, word);
                try w.writeAll("`: ");
                for (type_hints[0..hint_count], 0..) |th, ti| {
                    if (ti > 0) try w.writeAll(" | ");
                    try writeEscapedJsonContent(w, th);
                }
                try w.writeAll("\"}");
                try w.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ line, hover_wc16, line, hover_we16 });
                return types.ResponseMessage{
                    .id = msg.id,
                    .result = null,
                    .raw_result = try aw.toOwnedSlice(),
                    .@"error" = null,
                };
            }
            // Check for untyped local var
            const lv_exist = try self.db.prepare(
                "SELECT 1 FROM local_vars WHERE file_id=? AND name=? AND line<=? LIMIT 1"
            );
            defer lv_exist.finalize();
            lv_exist.bind_int(1, fid);
            lv_exist.bind_text(2, word);
            lv_exist.bind_int(3, cursor_line);
            if (try lv_exist.step()) {
                var aw_lv = std.Io.Writer.Allocating.init(self.alloc);
                const w_lv = &aw_lv.writer;
                try w_lv.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":\"*(local variable)* `");
                try writeEscapedJsonContent(w_lv, word);
                try w_lv.writeAll("\"}");
                try w_lv.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ line, hover_wc16, line, hover_we16 });
                return types.ResponseMessage{
                    .id = msg.id,
                    .result = null,
                    .raw_result = try aw_lv.toOwnedSlice(),
                    .@"error" = null,
                };
            }
        }

        if (try self.hoverLookup(msg, word, path, line, hover_wc16, hover_we16)) |r| return r;

        const qualified = extractQualifiedName(source, offset);
        if (!std.mem.eql(u8, qualified, word)) {
            if (try self.hoverLookup(msg, qualified, path, line, hover_wc16, hover_we16)) |r| return r;
        }

        return emptyResult(msg);
    }

    fn hoverLookup(self: *Server, msg: types.RequestMessage, name: []const u8, current_path: []const u8, hover_line: u32, wc16: u32, we16: u32) !?types.ResponseMessage {
        const stmt = try self.db.prepare(
            \\SELECT s.kind, s.line, s.return_type, s.doc, f.path, s.id, s.value_snippet, s.parent_name
            \\FROM symbols s JOIN files f ON s.file_id = f.id
            \\WHERE s.name = ?
            \\ORDER BY CASE WHEN f.path = ? THEN 0 ELSE 1 END, s.id
            \\LIMIT 1
        );
        defer stmt.finalize();
        stmt.bind_text(1, name);
        stmt.bind_text(2, current_path);

        if (!(try stmt.step())) return null;

        const kind_str = stmt.column_text(0);
        const sym_line = stmt.column_int(1);
        const return_type = stmt.column_text(2);
        const doc = stmt.column_text(3);
        const sym_path = stmt.column_text(4);
        const sym_id = stmt.column_int(5);
        const value_snippet = stmt.column_text(6);
        const parent_name = stmt.column_text(7);

        const kind_label: []const u8 = if (std.mem.eql(u8, kind_str, "classdef")) "def self" else kind_str;

        // Fetch parameter signature for def symbols
        var param_sig_buf = std.ArrayList(u8){};
        defer param_sig_buf.deinit(self.alloc);
        if (std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) {
            const ps = self.db.prepare(
                \\SELECT GROUP_CONCAT(
                \\  CASE p.kind WHEN 'keyword' THEN p.name||':' WHEN 'rest' THEN '*'||p.name
                \\  WHEN 'keyword_rest' THEN '**'||p.name WHEN 'block' THEN '&'||p.name
                \\  ELSE p.name END, ', ')
                \\FROM params p WHERE p.symbol_id=? ORDER BY p.position
            ) catch null;
            if (ps) |s| {
                defer s.finalize();
                s.bind_int(1, sym_id);
                if (s.step() catch false) {
                    const sig = s.column_text(0);
                    if (sig.len > 0) param_sig_buf.appendSlice(self.alloc, sig) catch {};
                }
            }
        }

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":\"*(");
        try writeEscapedJsonContent(w, kind_label);
        try w.writeAll(")* `");
        try writeEscapedJsonContent(w, name);
        if (param_sig_buf.items.len > 0) {
            try w.writeAll("(");
            try writeEscapedJsonContent(w, param_sig_buf.items);
            try w.writeAll(")");
        }
        try w.writeByte('`');
        if ((std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) and return_type.len > 0) {
            try w.writeAll(" \\u2192 ");
            try writeEscapedJsonContent(w, return_type);
        }
        if (std.mem.eql(u8, kind_str, "constant") and value_snippet.len > 0) {
            try w.writeAll(" = `");
            try writeEscapedJsonContent(w, value_snippet);
            try w.writeByte('`');
        }
        try w.writeAll("\\n\\n\\u2192 ");
        try writeEscapedJsonContent(w, sym_path);
        try w.print(":{d}", .{sym_line});
        if (doc.len > 0) {
            try w.writeAll("\\n\\n");
            try writeEscapedJsonContent(w, doc);
        }
        if (std.mem.eql(u8, kind_str, "class") or std.mem.eql(u8, kind_str, "module")) {
            if (parent_name.len > 0 and !std.mem.eql(u8, parent_name, "Object")) {
                try w.writeAll("\\n\\n**Inherits:** `");
                try writeEscapedJsonContent(w, parent_name);
                try w.writeByte('`');
            }
            const mx_stmt = self.db.prepare(
                "SELECT module_name FROM mixins WHERE class_id = ? AND kind IN ('include','prepend') ORDER BY rowid"
            ) catch null;
            if (mx_stmt) |ms| {
                defer ms.finalize();
                ms.bind_int(1, sym_id);
                var first_mx = true;
                while (ms.step() catch false) {
                    const mod = ms.column_text(0);
                    if (first_mx) {
                        try w.writeAll("\\n\\n**Includes:** `");
                        first_mx = false;
                    } else {
                        try w.writeAll("`, `");
                    }
                    try writeEscapedJsonContent(w, mod);
                }
                if (!first_mx) try w.writeByte('`');
            }
        }
        try w.writeAll("\"}");
        try w.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ hover_line, wc16, hover_line, we16 });

        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = try aw.toOwnedSlice(),
            .@"error" = null,
        };
    }

    const RequireKind = enum { require, require_relative };

    fn detectRequireContext(source: []const u8, offset: usize) ?RequireKind {
        if (offset == 0) return null;
        var i = offset;
        // Skip back over any partial string
        while (i > 0 and source[i - 1] != '\'' and source[i - 1] != '"') i -= 1;
        if (i == 0) return null;
        i -= 1; // skip the opening quote
        // Skip whitespace
        while (i > 0 and (source[i - 1] == ' ' or source[i - 1] == '\t')) i -= 1;
        // Check for 'require_relative' (16 chars) or 'require' (7 chars)
        if (i >= 16 and std.mem.eql(u8, source[i - 16 .. i], "require_relative")) return .require_relative;
        if (i >= 7 and std.mem.eql(u8, source[i - 7 .. i], "require")) return .require;
        return null;
    }

    fn completeRequirePath(self: *Server, msg: types.RequestMessage, path: []const u8, source: []const u8, offset: usize) !types.ResponseMessage {
        const req_kind = detectRequireContext(source, offset).?;
        const prefix_start = blk: {
            var idx = offset;
            while (idx > 0 and source[idx - 1] != '\'' and source[idx - 1] != '"') idx -= 1;
            break :blk idx;
        };
        const prefix = source[prefix_start..offset];
        var aw_req = std.Io.Writer.Allocating.init(self.alloc);
        const wr = &aw_req.writer;
        try wr.writeAll("{\"isIncomplete\":false,\"items\":[");
        var first_req = true;
        if (req_kind == .require) {
            const stdlib = [_][]const u8{
                "json", "set", "date", "pathname", "fileutils", "ostruct",
                "digest", "base64", "uri", "net/http", "open-uri", "tempfile",
                "stringio", "securerandom", "yaml", "csv", "optparse",
                "logger", "singleton", "forwardable", "delegate", "observer",
                "thread", "mutex_m", "monitor", "timeout", "benchmark",
                "pp", "pstore", "dbm", "socket", "resolv", "zlib",
                "rake", "minitest/autorun", "test/unit",
            };
            for (stdlib) |lib| {
                if (prefix.len == 0 or std.mem.startsWith(u8, lib, prefix)) {
                    if (!first_req) try wr.writeByte(',');
                    first_req = false;
                    try wr.writeAll("{\"label\":");
                    try writeEscapedJson(wr, lib);
                    try wr.writeAll(",\"kind\":17}");
                }
            }
        }
        if (req_kind == .require_relative) {
            const dir_path = std.fs.path.dirname(path) orelse ".";
            var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
                try wr.writeAll("]}");
                return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw_req.toOwnedSlice(), .@"error" = null };
            };
            defer dir.close();
            var it = dir.iterate();
            while (it.next() catch null) |entry| {
                if (!std.mem.endsWith(u8, entry.name, ".rb")) continue;
                const stem = entry.name[0 .. entry.name.len - 3];
                const rel = try std.fmt.allocPrint(self.alloc, "./{s}", .{stem});
                defer self.alloc.free(rel);
                if (prefix.len == 0 or std.mem.startsWith(u8, rel, prefix)) {
                    if (!first_req) try wr.writeByte(',');
                    first_req = false;
                    try wr.writeAll("{\"label\":");
                    try writeEscapedJson(wr, rel);
                    try wr.writeAll(",\"kind\":17}");
                }
            }
        }
        try wr.writeAll("]}");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw_req.toOwnedSlice(), .@"error" = null };
    }

    fn completeDot(self: *Server, msg: types.RequestMessage, path: []const u8, source: []const u8, line: u32, character: u32, offset: usize, word: []const u8) !?types.ResponseMessage {
        _ = word;
        var recv_offset = if (offset >= 2) offset - 2 else 0;
        var recv_word = extractWord(source, recv_offset);
        if (recv_word.len == 0 and recv_offset > 0 and source[recv_offset] == '&') {
            recv_offset = if (recv_offset >= 1) recv_offset - 1 else 0;
            recv_word = extractWord(source, recv_offset);
        }
        if (recv_word.len == 0) return null;
        {
            const fdc_stmt = try self.cachedStmt("SELECT id FROM files WHERE path = ?");
            defer fdc_stmt.reset();
            fdc_stmt.bind_text(1, path);
            if (try fdc_stmt.step()) {
                const fdc_id = fdc_stmt.column_int(0);
                const cursor_line_db: i64 = @intCast(line + 1);
                const th_stmt = try self.cachedStmt(
                    "SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND line<=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1"
                );
                defer th_stmt.reset();
                th_stmt.bind_int(1, fdc_id);
                th_stmt.bind_text(2, recv_word);
                th_stmt.bind_int(3, cursor_line_db);
                const th_hit = try th_stmt.step();
                var chain_class_buf: ?[]u8 = null;
                defer if (chain_class_buf) |b| self.alloc.free(b);
                if (!th_hit) {
                    var rv_start: usize = if (recv_offset < source.len and !isRubyIdent(source[recv_offset])) recv_offset else recv_offset + 1;
                    while (rv_start > 0 and isRubyIdent(source[rv_start - 1])) rv_start -= 1;
                    if (rv_start >= 2 and source[rv_start - 1] == '.') {
                        var outer_offset = rv_start - 2;
                        if (outer_offset >= 1 and source[outer_offset] == '&') outer_offset -= 1;
                        const outer_word = extractWord(source, outer_offset);
                        if (outer_word.len > 0) {
                            const oth_stmt = try self.cachedStmt(
                                "SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND line<=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1"
                            );
                            defer oth_stmt.reset();
                            oth_stmt.bind_int(1, fdc_id);
                            oth_stmt.bind_text(2, outer_word);
                            oth_stmt.bind_int(3, cursor_line_db);
                            if (try oth_stmt.step()) {
                                const outer_type = oth_stmt.column_text(0);
                                if (outer_type.len > 0) {
                                    const ret_stmt = try self.cachedStmt(
                                        "SELECT return_type FROM symbols WHERE name=? AND kind='def' AND return_type IS NOT NULL AND file_id IN (SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?) LIMIT 1"
                                    );
                                    defer ret_stmt.reset();
                                    ret_stmt.bind_text(1, recv_word);
                                    ret_stmt.bind_text(2, outer_type);
                                    if (try ret_stmt.step()) {
                                        const cc = ret_stmt.column_text(0);
                                        if (cc.len > 0) chain_class_buf = try self.alloc.dupe(u8, cc);
                                    }
                                    if (chain_class_buf == null) {
                                        if (indexer.lookupStdlibReturn(outer_type, recv_word)) |rt| {
                                            chain_class_buf = try self.alloc.dupe(u8, rt);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if (chain_class_buf == null and std.mem.eql(u8, recv_word, "self")) {
                    const sc_stmt = try self.db.prepare(
                        "SELECT name FROM symbols WHERE file_id=? AND kind IN ('class','module') AND line<=? ORDER BY line DESC LIMIT 1"
                    );
                    defer sc_stmt.finalize();
                    sc_stmt.bind_int(1, fdc_id);
                    sc_stmt.bind_int(2, cursor_line_db);
                    if (try sc_stmt.step()) {
                        const sc = sc_stmt.column_text(0);
                        if (sc.len > 0) chain_class_buf = try self.alloc.dupe(u8, sc);
                    }
                }
                const is_constant_recv = recv_word.len > 0 and std.ascii.isUpper(recv_word[0]);
                if (chain_class_buf == null and is_constant_recv) {
                    chain_class_buf = try self.alloc.dupe(u8, recv_word);
                }
                const is_self_recv = std.mem.eql(u8, recv_word, "self");
                const class_name: []const u8 = if (th_hit) th_stmt.column_text(0)
                                                else if (chain_class_buf) |cc| cc
                                                else "";
                if (class_name.len > 0) {
                        var mro_arena = std.heap.ArenaAllocator.init(self.alloc);
                        defer mro_arena.deinit();
                        const ma = mro_arena.allocator();

                        var aw_dot = std.Io.Writer.Allocating.init(self.alloc);
                        const wd = &aw_dot.writer;
                        try wd.writeAll("{\"isIncomplete\":false,\"items\":[");
                        var first_dot = true;
                        var seen_names = std.StringHashMap(void).init(ma);
                        var seen_classes = std.StringHashMap(void).init(ma);
                        var current = try ma.dupe(u8, class_name);
                        const own_stmt_hoisted = if (is_self_recv)
                            self.db.prepare(
                                \\SELECT s.name, s.doc,
                                \\  (SELECT GROUP_CONCAT(
                                \\    CASE p.kind WHEN 'keyword' THEN p.name||':' WHEN 'rest' THEN '*'||p.name
                                \\    WHEN 'keyword_rest' THEN '**'||p.name WHEN 'block' THEN '&'||p.name
                                \\    ELSE p.name END, ', ')
                                \\   FROM params p WHERE p.symbol_id=s.id ORDER BY p.position)
                                \\FROM symbols s
                                \\WHERE s.kind='def' AND s.file_id IN (
                                \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?
                                \\)
                            ) catch null
                        else
                            self.db.prepare(
                                \\SELECT s.name, s.doc,
                                \\  (SELECT GROUP_CONCAT(
                                \\    CASE p.kind WHEN 'keyword' THEN p.name||':' WHEN 'rest' THEN '*'||p.name
                                \\    WHEN 'keyword_rest' THEN '**'||p.name WHEN 'block' THEN '&'||p.name
                                \\    ELSE p.name END, ', ')
                                \\   FROM params p WHERE p.symbol_id=s.id ORDER BY p.position)
                                \\FROM symbols s
                                \\WHERE s.kind='def' AND s.file_id IN (
                                \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?
                                \\) AND (s.visibility IS NULL OR s.visibility = 'public')
                            ) catch null;
                        defer if (own_stmt_hoisted) |s2| s2.finalize();
                        const cls_stmt_hoisted = if (is_constant_recv)
                            self.db.prepare(
                                \\SELECT s.name, s.doc FROM symbols s
                                \\WHERE s.kind='classdef' AND s.file_id IN (
                                \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?
                                \\) AND (s.visibility IS NULL OR s.visibility = 'public')
                            ) catch null
                        else null;
                        defer if (cls_stmt_hoisted) |s2| s2.finalize();
                        var depth: u8 = 0;
                        while (depth < 8) : (depth += 1) {
                            if (seen_classes.contains(current)) break;
                            try seen_classes.put(try ma.dupe(u8, current), {});

                            const prep_stmt = try self.cachedStmt(
                                \\SELECT DISTINCT s2.name, s2.doc FROM symbols s2
                                \\JOIN mixins m ON s2.file_id IN (
                                \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=m.module_name
                                \\)
                                \\WHERE m.class_id IN (
                                \\  SELECT id FROM symbols WHERE kind IN ('class','module') AND name=?
                                \\) AND s2.kind='def' AND m.kind='prepend'
                            );
                            defer prep_stmt.reset();
                            prep_stmt.bind_text(1, current);
                            while (try prep_stmt.step()) {
                                const mname2 = prep_stmt.column_text(0);
                                if (seen_names.contains(mname2)) continue;
                                try seen_names.put(try ma.dupe(u8, mname2), {});
                                if (!first_dot) try wd.writeByte(',');
                                first_dot = false;
                                const mdoc = prep_stmt.column_text(1);
                                try wd.writeAll("{\"label\":");
                                try writeEscapedJson(wd, mname2);
                                try wd.writeAll(",\"kind\":3,\"detail\":\"(def)\",\"sortText\":\"0_");
                                try writeEscapedJsonContent(wd, mname2);
                                try wd.writeAll("\",\"filterText\":\"");
                                try writeEscapedJsonContent(wd, mname2);
                                try wd.writeAll("\",\"commitCharacters\":[\"(\"]");
                                if (mdoc.len > 0) {
                                    try wd.writeAll(",\"documentation\":\"");
                                    try writeEscapedJsonContent(wd, mdoc);
                                    try wd.writeByte('"');
                                }
                                try wd.writeAll(",\"textEdit\":{\"range\":{\"start\":{\"line\":");
                                try wd.print("{d}", .{line});
                                try wd.writeAll(",\"character\":");
                                try wd.print("{d}", .{character});
                                try wd.writeAll("},\"end\":{\"line\":");
                                try wd.print("{d}", .{line});
                                try wd.writeAll(",\"character\":");
                                try wd.print("{d}", .{character});
                                try wd.writeAll("}},\"newText\":\"");
                                try writeEscapedJsonContent(wd, mname2);
                                try wd.writeAll("\"},\"data\":{\"name\":");
                                try writeEscapedJson(wd, mname2);
                                try wd.writeAll("}");
                                try wd.writeByte('}');
                            }

                            const own_stmt = own_stmt_hoisted orelse continue;
                            own_stmt.reset();
                            own_stmt.bind_text(1, current);
                            while (try own_stmt.step()) {
                                const mname2 = own_stmt.column_text(0);
                                if (seen_names.contains(mname2)) continue;
                                try seen_names.put(try ma.dupe(u8, mname2), {});
                                if (!first_dot) try wd.writeByte(',');
                                first_dot = false;
                                const mdoc = own_stmt.column_text(1);
                                const msig = own_stmt.column_text(2);
                                try wd.writeAll("{\"label\":");
                                try writeEscapedJson(wd, mname2);
                                try wd.writeAll(",\"kind\":3,\"detail\":\"(def)\",\"sortText\":\"0_");
                                try writeEscapedJsonContent(wd, mname2);
                                try wd.writeAll("\",\"filterText\":\"");
                                try writeEscapedJsonContent(wd, mname2);
                                try wd.writeAll("\",\"commitCharacters\":[\"(\"]");
                                if (msig.len > 0) writeInsertTextSnippet(wd, mname2, msig) catch {};
                                if (mdoc.len > 0) {
                                    try wd.writeAll(",\"documentation\":\"");
                                    try writeEscapedJsonContent(wd, mdoc);
                                    try wd.writeByte('"');
                                }
                                try wd.writeAll(",\"textEdit\":{\"range\":{\"start\":{\"line\":");
                                try wd.print("{d}", .{line});
                                try wd.writeAll(",\"character\":");
                                try wd.print("{d}", .{character});
                                try wd.writeAll("},\"end\":{\"line\":");
                                try wd.print("{d}", .{line});
                                try wd.writeAll(",\"character\":");
                                try wd.print("{d}", .{character});
                                try wd.writeAll("}},\"newText\":\"");
                                try writeEscapedJsonContent(wd, mname2);
                                try wd.writeAll("\"},\"data\":{\"name\":");
                                try writeEscapedJson(wd, mname2);
                                try wd.writeAll("}");
                                try wd.writeByte('}');
                            }

                            if (is_constant_recv) {
                                if (cls_stmt_hoisted) |cls_stmt| {
                                    cls_stmt.reset();
                                    cls_stmt.bind_text(1, current);
                                    while (try cls_stmt.step()) {
                                        const mname2 = cls_stmt.column_text(0);
                                        if (seen_names.contains(mname2)) continue;
                                        try seen_names.put(try ma.dupe(u8, mname2), {});
                                        if (!first_dot) try wd.writeByte(',');
                                        first_dot = false;
                                        const mdoc = cls_stmt.column_text(1);
                                        try wd.writeAll("{\"label\":");
                                        try writeEscapedJson(wd, mname2);
                                        try wd.writeAll(",\"kind\":3,\"detail\":\"(def self)\",\"sortText\":\"0_");
                                        try writeEscapedJsonContent(wd, mname2);
                                        try wd.writeAll("\",\"filterText\":\"");
                                        try writeEscapedJsonContent(wd, mname2);
                                        try wd.writeAll("\",\"commitCharacters\":[\"(\"]");
                                        if (mdoc.len > 0) {
                                            try wd.writeAll(",\"documentation\":\"");
                                            try writeEscapedJsonContent(wd, mdoc);
                                            try wd.writeByte('"');
                                        }
                                        try wd.writeAll(",\"textEdit\":{\"range\":{\"start\":{\"line\":");
                                        try wd.print("{d}", .{line});
                                        try wd.writeAll(",\"character\":");
                                        try wd.print("{d}", .{character});
                                        try wd.writeAll("},\"end\":{\"line\":");
                                        try wd.print("{d}", .{line});
                                        try wd.writeAll(",\"character\":");
                                        try wd.print("{d}", .{character});
                                        try wd.writeAll("}},\"newText\":\"");
                                        try writeEscapedJsonContent(wd, mname2);
                                        try wd.writeAll("\"},\"data\":{\"name\":");
                                        try writeEscapedJson(wd, mname2);
                                        try wd.writeAll("}");
                                        try wd.writeByte('}');
                                    }
                                }
                            }

                            const mix_stmt = try self.cachedStmt(
                                \\SELECT DISTINCT s2.name, s2.doc FROM symbols s2
                                \\JOIN mixins m ON s2.file_id IN (
                                \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=m.module_name
                                \\)
                                \\WHERE m.class_id IN (
                                \\  SELECT id FROM symbols WHERE kind IN ('class','module') AND name=?
                                \\) AND s2.kind='def' AND m.kind IN ('include','extend')
                            );
                            defer mix_stmt.reset();
                            mix_stmt.bind_text(1, current);
                            while (try mix_stmt.step()) {
                                const mname2 = mix_stmt.column_text(0);
                                if (seen_names.contains(mname2)) continue;
                                try seen_names.put(try ma.dupe(u8, mname2), {});
                                if (!first_dot) try wd.writeByte(',');
                                first_dot = false;
                                const mdoc = mix_stmt.column_text(1);
                                try wd.writeAll("{\"label\":");
                                try writeEscapedJson(wd, mname2);
                                try wd.writeAll(",\"kind\":3,\"detail\":\"(def)\",\"sortText\":\"0_");
                                try writeEscapedJsonContent(wd, mname2);
                                try wd.writeAll("\",\"filterText\":\"");
                                try writeEscapedJsonContent(wd, mname2);
                                try wd.writeAll("\",\"commitCharacters\":[\"(\"]");
                                if (mdoc.len > 0) {
                                    try wd.writeAll(",\"documentation\":\"");
                                    try writeEscapedJsonContent(wd, mdoc);
                                    try wd.writeByte('"');
                                }
                                try wd.writeAll(",\"textEdit\":{\"range\":{\"start\":{\"line\":");
                                try wd.print("{d}", .{line});
                                try wd.writeAll(",\"character\":");
                                try wd.print("{d}", .{character});
                                try wd.writeAll("},\"end\":{\"line\":");
                                try wd.print("{d}", .{line});
                                try wd.writeAll(",\"character\":");
                                try wd.print("{d}", .{character});
                                try wd.writeAll("}},\"newText\":\"");
                                try writeEscapedJsonContent(wd, mname2);
                                try wd.writeAll("\"},\"data\":{\"name\":");
                                try writeEscapedJson(wd, mname2);
                                try wd.writeAll("}");
                                try wd.writeByte('}');
                            }

                            const par_stmt = try self.cachedStmt("SELECT parent_name FROM symbols WHERE kind='class' AND name=? AND parent_name IS NOT NULL LIMIT 1");
                            defer par_stmt.reset();
                            par_stmt.bind_text(1, current);
                            if (try par_stmt.step()) {
                                const pname = par_stmt.column_text(0);
                                if (pname.len == 0) break;
                                current = try ma.dupe(u8, pname);
                            } else break;
                        }
                        var has_enumerable = false;
                        var has_comparable = false;
                        {
                            const enum_stmt = self.db.prepare(
                                "SELECT module_name FROM mixins WHERE class_id IN (SELECT id FROM symbols WHERE kind IN ('class','module') AND name=?) AND kind IN ('include','prepend')"
                            ) catch null;
                            if (enum_stmt) |es| {
                                defer es.finalize();
                                es.bind_text(1, class_name);
                                while (es.step() catch false) {
                                    const mn = es.column_text(0);
                                    if (std.mem.eql(u8, mn, "Enumerable")) has_enumerable = true;
                                    if (std.mem.eql(u8, mn, "Comparable")) has_comparable = true;
                                }
                            }
                        }
                        if (has_enumerable) {
                            const enum_methods = [_][]const u8{
                                "map", "select", "reject", "each", "each_with_index", "each_with_object",
                                "find", "detect", "any?", "all?", "none?", "count", "first", "min", "max",
                                "min_by", "max_by", "sort", "sort_by", "flat_map", "reduce", "inject",
                                "include?", "group_by", "zip", "take", "drop", "to_a",
                                "each_slice", "each_cons", "chunk", "tally", "sum", "filter_map",
                            };
                            for (enum_methods) |em| {
                                if (seen_names.contains(em)) continue;
                                if (!first_dot) try wd.writeByte(',');
                                first_dot = false;
                                try wd.writeAll("{\"label\":");
                                try writeEscapedJson(wd, em);
                                try wd.writeAll(",\"kind\":2}");
                            }
                        }
                        if (has_comparable) {
                            const cmp_methods = [_][]const u8{ "<", ">", "<=", ">=", "between?", "clamp" };
                            for (cmp_methods) |cm| {
                                if (seen_names.contains(cm)) continue;
                                if (!first_dot) try wd.writeByte(',');
                                first_dot = false;
                                try wd.writeAll("{\"label\":");
                                try writeEscapedJson(wd, cm);
                                try wd.writeAll(",\"kind\":2}");
                            }
                        }
                        try addStdlibCompletions(wd, class_name, &first_dot, line, character);
                        try wd.writeAll("]}");

                        return types.ResponseMessage{
                            .id = msg.id,
                            .result = null,
                            .raw_result = try aw_dot.toOwnedSlice(),
                            .@"error" = null,
                        };
                    }
            }
        }
        return null;
    }

    fn completeNamespace(self: *Server, msg: types.RequestMessage, source: []const u8, offset: usize, word: []const u8) !?types.ResponseMessage {
        _ = word;
        const ns_offset = if (offset >= 3) offset - 3 else 0;
        const ns_word = extractWord(source, ns_offset);
        if (ns_word.len == 0) return null;
        const ns_stmt = try self.db.prepare(
            \\SELECT name, kind
            \\FROM symbols
            \\WHERE parent_name = ?
            \\  AND kind IN ('classdef', 'moduledef', 'constant', 'def', 'class', 'module')
            \\ORDER BY name LIMIT 100
        );
        defer ns_stmt.finalize();
        ns_stmt.bind_text(1, ns_word);
        var aw_ns = std.Io.Writer.Allocating.init(self.alloc);
        const wns = &aw_ns.writer;
        try wns.writeAll("{\"isIncomplete\":false,\"items\":[");
        var first_ns = true;
        while (try ns_stmt.step()) {
            if (!first_ns) try wns.writeByte(',');
            first_ns = false;
            const cname = ns_stmt.column_text(0);
            const ckind_str = ns_stmt.column_text(1);
            const ckind_num: u8 = if (std.mem.eql(u8, ckind_str, "classdef") or std.mem.eql(u8, ckind_str, "class")) 7
                else if (std.mem.eql(u8, ckind_str, "moduledef") or std.mem.eql(u8, ckind_str, "module")) 9
                else if (std.mem.eql(u8, ckind_str, "constant")) 21
                else 3;
            try wns.writeAll("{\"label\":");
            try writeEscapedJson(wns, cname);
            try wns.print(",\"kind\":{d}", .{ckind_num});
            try wns.writeByte('}');
        }
        try wns.writeAll("]}");
        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = try aw_ns.toOwnedSlice(),
            .@"error" = null,
        };
    }

    fn completeAllSymbols(self: *Server, msg: types.RequestMessage) !types.ResponseMessage {
        const stmt2 = try self.db.prepare(
            \\SELECT DISTINCT name, kind FROM symbols ORDER BY length(name), name LIMIT 500
        );
        defer stmt2.finalize();
        var items_aw2 = std.Io.Writer.Allocating.init(self.alloc);
        var first2 = true;
        var count2: usize = 0;
        while (try stmt2.step()) {
            if (!first2) try items_aw2.writer.writeByte(',');
            first2 = false;
            count2 += 1;
            const cname = stmt2.column_text(0);
            const ckind_str = stmt2.column_text(1);
            const ckind_num: u8 = if (std.mem.eql(u8, ckind_str, "class")) 7 else if (std.mem.eql(u8, ckind_str, "module")) 9 else if (std.mem.eql(u8, ckind_str, "def") or std.mem.eql(u8, ckind_str, "classdef")) 3 else if (std.mem.eql(u8, ckind_str, "constant")) 21 else 1;
            try items_aw2.writer.writeAll("{\"label\":");
            try writeEscapedJson(&items_aw2.writer, cname);
            try items_aw2.writer.print(",\"kind\":{d},\"detail\":\"(", .{ckind_num});
            try writeEscapedJsonContent(&items_aw2.writer, ckind_str);
            try items_aw2.writer.writeAll(")\"");
            const csort_prefix: []const u8 = if (std.mem.eql(u8, ckind_str, "def") or std.mem.eql(u8, ckind_str, "classdef")) "0_" else if (std.mem.eql(u8, ckind_str, "class") or std.mem.eql(u8, ckind_str, "module")) "1_" else "2_";
            try items_aw2.writer.writeAll(",\"sortText\":\"");
            try writeEscapedJsonContent(&items_aw2.writer, csort_prefix);
            try writeEscapedJsonContent(&items_aw2.writer, cname);
            try items_aw2.writer.writeByte('"');
            try items_aw2.writer.writeAll(",\"filterText\":\"");
            try writeEscapedJsonContent(&items_aw2.writer, cname);
            try items_aw2.writer.writeByte('"');
            if (std.mem.eql(u8, ckind_str, "def") or std.mem.eql(u8, ckind_str, "classdef")) {
                try items_aw2.writer.writeAll(",\"commitCharacters\":[\"(\"]");
            }
            try items_aw2.writer.writeByte('}');
        }
        const items2 = try items_aw2.toOwnedSlice();
        defer self.alloc.free(items2);
        var aw2 = std.Io.Writer.Allocating.init(self.alloc);
        const w2 = &aw2.writer;
        try w2.writeAll(if (count2 >= 200) "{\"isIncomplete\":true,\"items\":[" else "{\"isIncomplete\":false,\"items\":[");
        try w2.writeAll(items2);
        try w2.writeAll("]}");

        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = try aw2.toOwnedSlice(),
            .@"error" = null,
        };
    }

    fn completeInstanceVars(self: *Server, msg: types.RequestMessage, path: []const u8, source: []const u8, line: u32, word: []const u8) !types.ResponseMessage {
        _ = source;
        const ivar_pattern = try buildQueryPattern(self.alloc, word);
        defer self.alloc.free(ivar_pattern);
        const ifc_stmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
        defer ifc_stmt.finalize();
        ifc_stmt.bind_text(1, path);
        var aw_iv = std.Io.Writer.Allocating.init(self.alloc);
        const wi = &aw_iv.writer;
        try wi.writeAll("{\"isIncomplete\":false,\"items\":[");
        var first_iv = true;
        if (try ifc_stmt.step()) {
            const fid = ifc_stmt.column_int(0);
            const cls_stmt = self.db.prepare(
                "SELECT id FROM symbols WHERE file_id=? AND line<=? AND (kind='class' OR kind='module') ORDER BY line DESC LIMIT 1"
            ) catch null;
            const class_id: i64 = blk: {
                if (cls_stmt) |cs| {
                    defer cs.finalize();
                    cs.bind_int(1, fid);
                    cs.bind_int(2, @intCast(line + 1));
                    if (cs.step() catch false) break :blk cs.column_int(0);
                }
                break :blk 0;
            };
            const iv_stmt = try self.db.prepare(
                "SELECT DISTINCT name, type_hint FROM local_vars WHERE file_id=? AND (class_id=? OR class_id IS NULL) AND name LIKE ? ESCAPE '\\'");
            defer iv_stmt.finalize();
            iv_stmt.bind_int(1, fid);
            iv_stmt.bind_int(2, class_id);
            iv_stmt.bind_text(3, ivar_pattern);
            while (try iv_stmt.step()) {
                const iv_name = iv_stmt.column_text(0);
                const iv_type = iv_stmt.column_text(1);
                if (!first_iv) try wi.writeByte(',');
                first_iv = false;
                try wi.writeAll("{\"label\":");
                try writeEscapedJson(wi, iv_name);
                try wi.writeAll(",\"kind\":5");
                if (iv_type.len > 0) {
                    try wi.writeAll(",\"detail\":\"");
                    try writeEscapedJsonContent(wi, iv_type);
                    try wi.writeByte('"');
                }
                try wi.writeAll(",\"sortText\":\"2_");
                try writeEscapedJsonContent(wi, iv_name);
                try wi.writeByte('"');
                try wi.writeAll(",\"filterText\":\"");
                try writeEscapedJsonContent(wi, iv_name);
                try wi.writeByte('"');
                try wi.writeByte('}');
            }
        }
        try wi.writeAll("]}");

        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = try aw_iv.toOwnedSlice(),
            .@"error" = null,
        };
    }

    fn completeGlobalVars(self: *Server, msg: types.RequestMessage, word: []const u8) !types.ResponseMessage {
        const gv_pat = try buildPrefixPattern(self.alloc, word);
        defer self.alloc.free(gv_pat);
        const gv_stmt = try self.db.prepare(
            \\SELECT DISTINCT name FROM local_vars
            \\WHERE name LIKE ? ESCAPE '\'
            \\ORDER BY name LIMIT 200
        );
        defer gv_stmt.finalize();
        gv_stmt.bind_text(1, gv_pat);
        var aw_gv = std.Io.Writer.Allocating.init(self.alloc);
        const wg = &aw_gv.writer;
        try wg.writeAll("{\"isIncomplete\":false,\"items\":[");
        var gv_first = true;
        var gv_seen_arena = std.heap.ArenaAllocator.init(self.alloc);
        defer gv_seen_arena.deinit();
        var gv_seen = std.StringHashMap(void).init(gv_seen_arena.allocator());
        while (try gv_stmt.step()) {
            const gv_name = gv_stmt.column_text(0);
            if (gv_seen.contains(gv_name)) continue;
            gv_seen.put(try gv_seen_arena.allocator().dupe(u8, gv_name), {}) catch {};
            if (!gv_first) try wg.writeByte(',');
            gv_first = false;
            try wg.writeAll("{\"label\":");
            try writeEscapedJson(wg, gv_name);
            try wg.writeAll(",\"kind\":6,\"sortText\":\"1_");
            try writeEscapedJsonContent(wg, gv_name);
            try wg.writeAll("\",\"filterText\":");
            try writeEscapedJson(wg, gv_name);
            try wg.writeByte('}');
        }
        const ruby_globals = [_]struct { name: []const u8, doc: []const u8 }{
            .{ .name = "$stdout",          .doc = "Standard output stream." },
            .{ .name = "$stderr",          .doc = "Standard error stream." },
            .{ .name = "$stdin",           .doc = "Standard input stream." },
            .{ .name = "$PROGRAM_NAME",    .doc = "Current script name (same as $0)." },
            .{ .name = "$0",               .doc = "Current script name." },
            .{ .name = "$LOAD_PATH",       .doc = "Load path array (same as $:)." },
            .{ .name = "$:",               .doc = "Load path array." },
            .{ .name = "$LOADED_FEATURES", .doc = "Loaded files array (same as $\")." },
            .{ .name = "$VERBOSE",         .doc = "Verbose mode flag." },
            .{ .name = "$DEBUG",           .doc = "Debug mode flag." },
            .{ .name = "$?",               .doc = "Exit status of last child process." },
            .{ .name = "$~",               .doc = "MatchData from last match." },
            .{ .name = "$&",               .doc = "String matched by last regex." },
            .{ .name = "$1",               .doc = "First capture group of last match." },
            .{ .name = "$2",               .doc = "Second capture group of last match." },
            .{ .name = "$3",               .doc = "Third capture group of last match." },
        };
        for (ruby_globals) |rg| {
            if (!std.mem.startsWith(u8, rg.name, word)) continue;
            if (gv_seen.contains(rg.name)) continue;
            if (!gv_first) try wg.writeByte(',');
            gv_first = false;
            try wg.writeAll("{\"label\":");
            try writeEscapedJson(wg, rg.name);
            try wg.writeAll(",\"kind\":6,\"detail\":\"(built-in)\",\"documentation\":{\"kind\":\"plaintext\",\"value\":");
            try writeEscapedJson(wg, rg.doc);
            try wg.writeAll("},\"sortText\":\"9_");
            try writeEscapedJsonContent(wg, rg.name);
            try wg.writeAll("\",\"filterText\":");
            try writeEscapedJson(wg, rg.name);
            try wg.writeByte('}');
        }
        try wg.writeAll("]}");

        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = try aw_gv.toOwnedSlice(),
            .@"error" = null,
        };
    }

    fn completeGeneral(self: *Server, msg: types.RequestMessage, path: []const u8, source: []const u8, line: u32, character: u32, word: []const u8, offset: usize) !types.ResponseMessage {
        const pattern = try buildQueryPattern(self.alloc, word);
        defer self.alloc.free(pattern);
        const prefix_pattern = try buildPrefixPattern(self.alloc, word);
        defer self.alloc.free(prefix_pattern);

        const stmt = try self.db.prepare(
            \\SELECT s.name, s.kind,
            \\  (SELECT GROUP_CONCAT(
            \\    CASE p.kind WHEN 'keyword' THEN p.name||':' WHEN 'rest' THEN '*'||p.name
            \\    WHEN 'keyword_rest' THEN '**'||p.name WHEN 'block' THEN '&'||p.name
            \\    ELSE p.name END, ', ')
            \\   FROM params p WHERE p.symbol_id=s.id ORDER BY p.position),
            \\  s.doc
            \\FROM symbols s WHERE s.name LIKE ? ESCAPE '\'
            \\ORDER BY CASE WHEN s.name LIKE ? ESCAPE '\' THEN 0 ELSE 1 END, length(s.name), s.name LIMIT 1000
        );
        defer stmt.finalize();
        stmt.bind_text(1, pattern);
        stmt.bind_text(2, prefix_pattern);

        var seen_arena = std.heap.ArenaAllocator.init(self.alloc);
        defer seen_arena.deinit();
        var seen = std.StringHashMap(void).init(seen_arena.allocator());

        var items_aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &items_aw.writer;
        var first = true;
        var symbol_count: usize = 0;
        while (try stmt.step()) {
            const name = stmt.column_text(0);
            if (seen.contains(name)) continue;
            try seen.put(try seen_arena.allocator().dupe(u8, name), {});
            if (!first) try w.writeByte(',');
            first = false;
            symbol_count += 1;
            const kind_str = stmt.column_text(1);
            const sig = stmt.column_text(2);
            const doc = stmt.column_text(3);
            const kind_num: u8 = if (std.mem.eql(u8, kind_str, "class")) 7 else if (std.mem.eql(u8, kind_str, "module")) 9 else if (std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) 3 else if (std.mem.eql(u8, kind_str, "constant")) 21 else 1;
            try w.writeAll("{\"label\":");
            try writeEscapedJson(w, name);
            try w.print(",\"kind\":{d},\"detail\":\"(", .{kind_num});
            if ((std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) and sig.len > 0) {
                try writeEscapedJsonContent(w, sig);
            } else {
                try writeEscapedJsonContent(w, kind_str);
            }
            try w.writeAll(")\"");
            const sort_prefix: []const u8 = if (std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) "0_" else if (std.mem.eql(u8, kind_str, "class") or std.mem.eql(u8, kind_str, "module")) "1_" else "2_";
            try w.writeAll(",\"sortText\":\"");
            try writeEscapedJsonContent(w, sort_prefix);
            try writeEscapedJsonContent(w, name);
            try w.writeByte('"');
            try w.writeAll(",\"filterText\":\"");
            try writeEscapedJsonContent(w, name);
            try w.writeByte('"');
            if (std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) {
                try w.writeAll(",\"commitCharacters\":[\"(\"]");
            }
            if ((std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) and sig.len > 0) {
                writeInsertTextSnippet(w, name, sig) catch {};
            }
            if (doc.len > 0) {
                try w.writeAll(",\"documentation\":{\"kind\":\"markdown\",\"value\":");
                try writeEscapedJson(w, doc);
                try w.writeByte('}');
            }
            const te_start_char = @as(u32, @intCast(character)) -| @as(u32, @intCast(word.len));
            try w.print(",\"textEdit\":{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":", .{
                line, te_start_char, line, character,
            });
            try writeEscapedJson(w, name);
            try w.writeByte('}');
            try w.writeByte('}');
        }
        const truncated = symbol_count >= 1000;

        if (word.len <= 9) {
            const kw_items = [_]struct { label: []const u8, snippet: []const u8, kind: u8 }{
                .{ .label = "def",    .snippet = "def ${1:method_name}\\n  $0\\nend",          .kind = 3  },
                .{ .label = "class",  .snippet = "class ${1:ClassName}\\n  $0\\nend",          .kind = 7  },
                .{ .label = "module", .snippet = "module ${1:ModuleName}\\n  $0\\nend",        .kind = 9  },
                .{ .label = "if",     .snippet = "if ${1:condition}\\n  $0\\nend",             .kind = 14 },
                .{ .label = "unless", .snippet = "unless ${1:condition}\\n  $0\\nend",         .kind = 14 },
                .{ .label = "while",  .snippet = "while ${1:condition}\\n  $0\\nend",          .kind = 14 },
                .{ .label = "until",  .snippet = "until ${1:condition}\\n  $0\\nend",          .kind = 14 },
                .{ .label = "begin",  .snippet = "begin\\n  $0\\nrescue => e\\n  raise\\nend", .kind = 14 },
                .{ .label = "do",     .snippet = "do |${1:arg}|\\n  $0\\nend",                .kind = 14 },
            };
            for (kw_items) |ki| {
                if (word.len > 0 and !std.mem.startsWith(u8, ki.label, word)) continue;
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll("{\"label\":");
                try writeEscapedJson(w, ki.label);
                try w.print(",\"kind\":{d},\"insertTextFormat\":2,\"insertText\":", .{ki.kind});
                try writeEscapedJson(w, ki.snippet);
                try w.writeAll(",\"sortText\":\"z_kw_");
                try writeEscapedJsonContent(w, ki.label);
                try w.writeByte('"');
                try w.writeByte('}');
            }
        }

        const fc_stmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
        defer fc_stmt.finalize();
        fc_stmt.bind_text(1, path);
        if (try fc_stmt.step()) {
            const fid = fc_stmt.column_int(0);
            const lv_stmt = try self.db.prepare("SELECT DISTINCT name, type_hint FROM local_vars WHERE file_id = ? AND name LIKE ? ESCAPE '\\'");
            defer lv_stmt.finalize();
            lv_stmt.bind_int(1, fid);
            lv_stmt.bind_text(2, pattern);
            while (try lv_stmt.step()) {
                const lv_name = lv_stmt.column_text(0);
                if (seen.contains(lv_name)) continue;
                try seen.put(try seen_arena.allocator().dupe(u8, lv_name), {});
                const lv_type = lv_stmt.column_text(1);
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll("{\"label\":");
                try writeEscapedJson(w, lv_name);
                try w.writeAll(",\"kind\":6");
                if (lv_type.len > 0) {
                    try w.writeAll(",\"detail\":\"");
                    try writeEscapedJsonContent(w, lv_type);
                    try w.writeByte('"');
                }
                try w.writeAll(",\"sortText\":\"2_");
                try writeEscapedJsonContent(w, lv_name);
                try w.writeByte('"');
                try w.writeAll(",\"filterText\":\"");
                try writeEscapedJsonContent(w, lv_name);
                try w.writeByte('"');
                try w.writeByte('}');
            }
        }

        const word_start_pos: usize = if (offset >= word.len) offset - word.len else 0;
        const is_dot_context = word_start_pos > 0 and source[word_start_pos - 1] == '.';
        if (!is_dot_context) {
            const kernel_methods = [_]struct { name: []const u8, doc: []const u8 }{
                .{ .name = "puts",             .doc = "Writes to stdout followed by newline." },
                .{ .name = "print",            .doc = "Writes to stdout without newline." },
                .{ .name = "p",                .doc = "Inspects and prints objects, returns them." },
                .{ .name = "pp",               .doc = "Pretty-prints objects." },
                .{ .name = "require",          .doc = "Loads a library." },
                .{ .name = "require_relative", .doc = "Loads library relative to current file." },
                .{ .name = "raise",            .doc = "Raises an exception." },
                .{ .name = "fail",             .doc = "Alias for raise." },
                .{ .name = "rand",             .doc = "Returns a random number." },
                .{ .name = "sleep",            .doc = "Suspends for duration." },
                .{ .name = "lambda",           .doc = "Creates a lambda proc." },
                .{ .name = "proc",             .doc = "Creates a proc object." },
                .{ .name = "format",           .doc = "Formats a string." },
                .{ .name = "sprintf",          .doc = "Formats a string." },
                .{ .name = "loop",             .doc = "Loops forever, calling the block." },
                .{ .name = "at_exit",          .doc = "Registers a block to run at exit." },
                .{ .name = "abort",            .doc = "Prints message and exits with failure." },
                .{ .name = "exit",             .doc = "Exits the process." },
            };
            for (kernel_methods) |km| {
                if (word.len > 0 and !std.mem.startsWith(u8, km.name, word)) continue;
                if (seen.contains(km.name)) continue;
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll("{\"label\":");
                try writeEscapedJson(w, km.name);
                try w.writeAll(",\"kind\":3,\"detail\":\"(Kernel)\",\"documentation\":{\"kind\":\"plaintext\",\"value\":");
                try writeEscapedJson(w, km.doc);
                try w.writeAll("},\"sortText\":\"9_");
                try writeEscapedJsonContent(w, km.name);
                try w.writeByte('"');
                try w.writeAll(",\"filterText\":\"");
                try writeEscapedJsonContent(w, km.name);
                try w.writeByte('"');
                try w.writeByte('}');
            }
        }

        kw_params_detect: {
            var kp_scan: usize = offset;
            var kp_depth: i32 = 0;
            var kp_open: ?usize = null;
            while (kp_scan > 0) {
                kp_scan -= 1;
                switch (source[kp_scan]) {
                    ')', ']', '}' => kp_depth += 1,
                    '(' => {
                        if (kp_depth == 0) { kp_open = kp_scan; break; }
                        kp_depth -= 1;
                    },
                    '[', '{' => { if (kp_depth > 0) { kp_depth -= 1; } else break :kw_params_detect; },
                    '\n' => break :kw_params_detect,
                    else => {},
                }
            }
            const kco = kp_open orelse break :kw_params_detect;
            const kp_method = extractWord(source, if (kco > 0) kco - 1 else 0);
            if (kp_method.len == 0) break :kw_params_detect;
            const kp_q = self.db.prepare(
                "SELECT p.name FROM params p JOIN symbols s ON p.symbol_id=s.id WHERE s.name=? AND s.kind='def' AND p.kind='keyword' ORDER BY p.position LIMIT 20"
            ) catch break :kw_params_detect;
            defer kp_q.finalize();
            kp_q.bind_text(1, kp_method);
            while (kp_q.step() catch false) {
                const pname = kp_q.column_text(0);
                if (word.len > 0 and !std.mem.startsWith(u8, pname, word)) continue;
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll("{\"label\":\"");
                try writeEscapedJsonContent(w, pname);
                try w.writeAll(":\",\"filterText\":\"");
                try writeEscapedJsonContent(w, pname);
                try w.writeAll("\",\"insertText\":\"");
                try writeEscapedJsonContent(w, pname);
                try w.writeAll(": \",\"kind\":5,\"sortText\":\"0_");
                try writeEscapedJsonContent(w, pname);
                try w.writeByte('"');
                try w.writeByte('}');
            }
        }

        const items_json = try items_aw.toOwnedSlice();
        defer self.alloc.free(items_json);
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const wr = &aw.writer;
        try wr.writeAll(if (truncated) "{\"isIncomplete\":true,\"items\":[" else "{\"isIncomplete\":false,\"items\":[");
        try wr.writeAll(items_json);
        try wr.writeAll("]}");

        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = try aw.toOwnedSlice(),
            .@"error" = null,
        };
    }

    fn handleCompletion(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.flushDirtyUris();
        if (self.isCancelled(msg.id)) return null;
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
        const uri = extractTextDocumentUri(msg.params) orelse return emptyResult(msg);
        const pos = extractPosition(msg.params) orelse return emptyResult(msg);
        const line: u32 = pos.line;
        const character: u32 = pos.character;

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);
        if (!self.pathInBounds(path)) return emptyResult(msg);
        const source = self.readSourceForUri(uri, path) catch
            return emptyResult(msg);
        defer self.alloc.free(source);

        const offset = self.clientPosToOffset(source, line, character);
        const word = extractWord(source, offset);

        if (detectRequireContext(source, offset) != null)
            return try self.completeRequirePath(msg, path, source, offset);
        if (isInStringOrComment(source, offset)) {
            var aw_empty = std.Io.Writer.Allocating.init(self.alloc);
            try aw_empty.writer.writeAll("{\"isIncomplete\":false,\"items\":[]}");
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw_empty.toOwnedSlice(), .@"error" = null };
        }
        if (word.len == 0 and offset > 0 and source[offset - 1] == '.')
            if (try self.completeDot(msg, path, source, line, character, offset, word)) |r| return r;
        if (word.len == 0 and offset >= 2 and source[offset - 1] == ':' and source[offset - 2] == ':')
            if (try self.completeNamespace(msg, source, offset, word)) |r| return r;
        if (word.len == 0)
            return try self.completeAllSymbols(msg);
        if (word.len > 0 and word[0] == '@')
            return try self.completeInstanceVars(msg, path, source, line, word);
        if (word.len > 0 and word[0] == '$')
            return try self.completeGlobalVars(msg, word);
        return try self.completeGeneral(msg, path, source, line, character, word, offset);
    }

    fn handleReferences(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        if (self.isCancelled(msg.id)) return null;
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
        const uri = extractTextDocumentUri(msg.params) orelse return emptyResult(msg);
        const pos = extractPosition(msg.params) orelse return emptyResult(msg);
        const line: u32 = pos.line;
        const character: u32 = pos.character;

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);
        if (!self.pathInBounds(path)) return emptyResult(msg);
        const source = self.readSourceForUri(uri, path) catch
            return emptyResult(msg);
        defer self.alloc.free(source);

        const offset = self.clientPosToOffset(source, line, character);
        const word = extractWord(source, offset);
        if (word.len == 0) return emptyResult(msg);

        const cursor_line_1based: i64 = @intCast(line + 1);
        var ref_word_start: usize = offset;
        while (ref_word_start > 0 and isRubyIdent(source[ref_word_start - 1])) ref_word_start -= 1;
        var ref_line_start: usize = 0;
        var ri: usize = 0;
        while (ri < ref_word_start) : (ri += 1) {
            if (source[ri] == '\n') ref_line_start = ri + 1;
        }
        const ref_col_0: i64 = @intCast(ref_word_start - ref_line_start);

        // Check if cursor is on a local variable; if so, scope the query
        const file_stmt_ref = try self.db.prepare("SELECT id FROM files WHERE path = ?");
        defer file_stmt_ref.finalize();
        file_stmt_ref.bind_text(1, path);
        var ref_scope_id: ?i64 = null;
        var is_local_ref = false;
        if (try file_stmt_ref.step()) {
            const fid = file_stmt_ref.column_int(0);
            if (resolveScopeId(self, fid, word, cursor_line_1based, ref_col_0)) |sid| {
                is_local_ref = true;
                ref_scope_id = if (sid != 0) sid else null;
            }
        }

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeByte('[');
        var first = true;
        var frc_ref: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer {
            var frc_it = frc_ref.iterator();
            while (frc_it.next()) |e| { self.alloc.free(e.key_ptr.*); self.alloc.free(e.value_ptr.*); }
            frc_ref.deinit(self.alloc);
        }

        if (is_local_ref) {
            if (ref_scope_id) |sid| {
                // Scoped: emit local_var writes + scoped refs for this scope only
                const lv_stmt = try self.db.prepare(
                    \\SELECT f.path, lv.line, lv.col FROM local_vars lv JOIN files f ON lv.file_id=f.id
                    \\WHERE lv.name=? AND lv.scope_id=?
                );
                defer lv_stmt.finalize();
                lv_stmt.bind_text(1, word);
                lv_stmt.bind_int(2, sid);
                while (try lv_stmt.step()) {
                    if (!first) try w.writeByte(',');
                    first = false;
                    const rp = lv_stmt.column_text(0);
                    const rl = lv_stmt.column_int(1);
                    const rc = lv_stmt.column_int(2);
                    const rc_client = self.toClientColFromPath(&frc_ref, rp, rl - 1, rc);
                    try w.writeAll("{\"uri\":\"file://");
                    try writePathAsUri(w, rp);
                    try w.writeAll("\",\"range\":{\"start\":{\"line\":");
                    try w.print("{d}", .{rl - 1});
                    try w.writeAll(",\"character\":");
                    try w.print("{d}", .{rc_client});
                    try w.writeAll("},\"end\":{\"line\":");
                    try w.print("{d}", .{rl - 1});
                    try w.writeAll(",\"character\":");
                    try w.print("{d}", .{rc_client + @as(u32, @intCast(word.len))});
                    try w.writeAll("}}}");
                }
                const scoped_ref = try self.db.prepare(
                    \\SELECT f.path, r.line, r.col FROM refs r JOIN files f ON r.file_id=f.id
                    \\WHERE r.name=? AND r.scope_id=?
                );
                defer scoped_ref.finalize();
                scoped_ref.bind_text(1, word);
                scoped_ref.bind_int(2, sid);
                while (try scoped_ref.step()) {
                    if (!first) try w.writeByte(',');
                    first = false;
                    const rp = scoped_ref.column_text(0);
                    const rl = scoped_ref.column_int(1);
                    const rc = scoped_ref.column_int(2);
                    const rc_client = self.toClientColFromPath(&frc_ref, rp, rl - 1, rc);
                    try w.writeAll("{\"uri\":\"file://");
                    try writePathAsUri(w, rp);
                    try w.writeAll("\",\"range\":{\"start\":{\"line\":");
                    try w.print("{d}", .{rl - 1});
                    try w.writeAll(",\"character\":");
                    try w.print("{d}", .{rc_client});
                    try w.writeAll("},\"end\":{\"line\":");
                    try w.print("{d}", .{rl - 1});
                    try w.writeAll(",\"character\":");
                    try w.print("{d}", .{rc_client + @as(u32, @intCast(word.len))});
                    try w.writeAll("}}}");
                }
            }
            // else top-level local — no cross-file refs, return empty
        } else {
            // Global: all refs across all files
            const stmt = try self.db.prepare(
                \\SELECT f.path, r.line, r.col
                \\FROM refs r JOIN files f ON r.file_id = f.id
                \\WHERE r.name = ?
            );
            defer stmt.finalize();
            stmt.bind_text(1, word);
            while (try stmt.step()) {
                if (!first) try w.writeByte(',');
                first = false;
                const ref_path = stmt.column_text(0);
                const ref_line = stmt.column_int(1);
                const ref_col = stmt.column_int(2);
                const ref_col_client = self.toClientColFromPath(&frc_ref, ref_path, ref_line - 1, ref_col);
                try w.writeAll("{\"uri\":\"file://");
                try writePathAsUri(w, ref_path);
                try w.writeAll("\",\"range\":{\"start\":{\"line\":");
                try w.print("{d}", .{ref_line - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{ref_col_client});
                try w.writeAll("},\"end\":{\"line\":");
                try w.print("{d}", .{ref_line - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{ref_col_client + @as(u32, @intCast(word.len))});
                try w.writeAll("}}}");
            }
        }
        try w.writeByte(']');

        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = try aw.toOwnedSlice(),
            .@"error" = null,
        };
    }

    fn writeDiagItems(
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
                const slash = std.mem.indexOfScalar(u8, d.code, '/') orelse d.code.len;
                w.writeAll(",\"codeDescription\":{\"href\":\"https://docs.rubocop.org/rubocop/cops_") catch return;
                for (d.code[0..slash]) |ch| w.writeByte(std.ascii.toLower(ch)) catch return;
                w.writeAll(".html\"}") catch return;
            }
            w.writeByte('}') catch return;
        }
    }

    fn enqueueRubocopPath(self: *Server, path: []const u8) void {
        if (self.disable_rubocop.load(.monotonic)) return;
        const duped = self.alloc.dupe(u8, path) catch return;
        self.rubocop_queue_mu.lock();
        defer self.rubocop_queue_mu.unlock();
        if (self.rubocop_pending.contains(duped)) {
            self.alloc.free(duped);
            return;
        }
        self.rubocop_pending.put(self.alloc, duped, {}) catch {
            self.alloc.free(duped);
            return;
        };
        self.rubocop_queue_cond.signal();
    }

    fn enqueueAllOpenDocs(self: *Server) void {
        var uris = std.ArrayList([]const u8){};
        defer uris.deinit(self.alloc);
        {
            self.open_docs_mu.lock();
            defer self.open_docs_mu.unlock();
            var uri_it = self.open_docs.keyIterator();
            while (uri_it.next()) |k| uris.append(self.alloc, k.*) catch {};
        }
        for (uris.items) |uri| {
            const path = uriToPath(self.alloc, uri) catch continue;
            defer self.alloc.free(path);
            self.enqueueRubocopPath(path);
        }
    }

    fn publishDiagnostics(self: *Server, uri: []const u8, path: []const u8, run_rubocop: bool) void {
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
            self.db_mutex.lock();
            if (self.db.prepare("SELECT is_gem FROM files WHERE path = ?")) |gs| {
                defer gs.finalize();
                gs.bind_text(1, path);
                if (gs.step() catch false) is_gem_file = gs.column_int(0) != 0;
            } else |_| {}
            self.db_mutex.unlock();
            if (!is_gem_file) self.enqueueRubocopPath(path);
        }

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":") catch return;
        writeEscapedJson(w, uri) catch return;
        w.writeAll(",\"diagnostics\":[") catch return;
        var first = true;
        self.writeDiagItems(w, prism_diags, diag_source, &first);
        w.writeAll("]}}") catch return;

        const json = aw.toOwnedSlice() catch return;
        defer self.alloc.free(json);
        self.sendNotification(json);
    }

    fn probeRubocopBundle(self: *Server) void {
        if (self.rubocop_bundle_probed.load(.monotonic)) return;
        self.rubocop_bundle_probed.store(true, .monotonic);
        const root = self.root_path orelse return;
        const gl = std.fmt.allocPrint(self.alloc, "{s}/Gemfile.lock", .{root}) catch return;
        defer self.alloc.free(gl);
        std.fs.accessAbsolute(gl, .{}) catch return;
        var probe = std.process.Child.init(&.{ "bundle", "exec", "rubocop", "--version" }, self.alloc);
        probe.stdout_behavior = .Ignore;
        probe.stderr_behavior = .Ignore;
        probe.cwd = root;
        probe.spawn() catch return;
        const term = probe.wait() catch return;
        if (term == .Exited and term.Exited == 0) self.rubocop_use_bundle.store(true, .monotonic);
    }

    fn getRubocopDiags(self: *Server, path: []const u8) ![]indexer.DiagEntry {
        if (self.rubocop_checked.load(.monotonic) and !self.rubocop_available.load(.monotonic)) return &.{};
        self.probeRubocopBundle();
        const argv: []const []const u8 = if (self.rubocop_use_bundle.load(.monotonic))
            &.{ "bundle", "exec", "rubocop", "--format", "json", "--no-color", "--no-cache", path }
        else
            &.{ "rubocop", "--format", "json", "--no-color", "--no-cache", path };
        var child = std.process.Child.init(argv, self.alloc);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.cwd = self.root_path orelse std.fs.path.dirname(path) orelse ".";
        child.spawn() catch |err| {
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
            _ = child.wait() catch {};
        }

        var stdout_buf = std.ArrayList(u8){};
        defer stdout_buf.deinit(self.alloc);
        var buf: [4096]u8 = undefined;
        const max_rubocop_bytes: usize = LOG_FILE_SIZE_LIMIT;
        while (true) {
            if (stdout_buf.items.len >= max_rubocop_bytes) {
                child.stdout.?.close();
                child.stdout = null;
                break;
            }
            const n = child.stdout.?.read(&buf) catch break;
            if (n == 0) break;
            stdout_buf.appendSlice(self.alloc, buf[0..n]) catch return &.{};
        }

        var stderr_bytes: [1024]u8 = undefined;
        const stderr_n: usize = if (child.stderr) |se| se.read(&stderr_bytes) catch 0 else 0;
        child.stderr = null;

        if (stdout_buf.items.len == 0) {
            if (stderr_n > 0) {
                const nl = std.mem.indexOfScalar(u8, stderr_bytes[0..stderr_n], '\n') orelse stderr_n;
                const first_line = stderr_bytes[0..@min(nl, 256)];
                var msg_buf: [320]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "refract: rubocop error — {s}", .{first_line})
                    catch "refract: rubocop returned no output — check .rubocop.yml";
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

        var list = std.ArrayList(indexer.DiagEntry){};
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

        return list.toOwnedSlice(self.alloc);
    }

    fn handleSignatureHelp(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
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
        const pos_val = obj.get("position") orelse return emptyResult(msg);
        const pos = switch (pos_val) {
            .object => |o| o,
            else => return emptyResult(msg),
        };
        const line_val = pos.get("line") orelse return emptyResult(msg);
        const line: u32 = switch (line_val) {
            .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
            else => return emptyResult(msg),
        };
        const char_val = pos.get("character") orelse return emptyResult(msg);
        const character: u32 = switch (char_val) {
            .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
            else => return emptyResult(msg),
        };

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);
        if (!self.pathInBounds(path)) return emptyResult(msg);
        const source = self.readSourceForUri(uri, path) catch
            return emptyResult(msg);
        defer self.alloc.free(source);

        const offset = self.clientPosToOffset(source, line, character);

        // Find enclosing call: walk backward for unmatched '('
        var active_param: u32 = 0;
        var depth: i32 = 0;
        var call_offset: ?usize = null;
        var i: usize = offset;
        while (i > 0) {
            i -= 1;
            switch (source[i]) {
                ')', ']', '}' => depth += 1,
                '(' => {
                    if (depth > 0) {
                        depth -= 1;
                    } else {
                        call_offset = i;
                        break;
                    }
                },
                '[', '{' => if (depth > 0) {
                    depth -= 1;
                },
                ',' => if (depth == 0) {
                    active_param += 1;
                },
                else => {},
            }
        }

        const co = call_offset orelse return emptyResult(msg);

        // Detect keyword argument context: scan backward for `word:` at paren depth 0
        var kw_active_param: ?u32 = null;
        var kw_name_buf: [128]u8 = undefined;
        var kw_name_len: usize = 0;
        {
            var scan: usize = if (offset > 0) offset - 1 else 0;
            var kw_depth: i32 = 0;
            kw_scan: while (scan > co) : (scan -= 1) {
                const ch = source[scan];
                if (ch == ')') kw_depth += 1;
                if (ch == '(') { if (kw_depth == 0) break; kw_depth -= 1; }
                if (kw_depth > 0) continue;
                if (ch == ',') break;
                if (ch == ':' and scan > 0 and source[scan - 1] != ':') {
                    const ne = scan;
                    var ns = ne;
                    while (ns > 0 and (std.ascii.isAlphanumeric(source[ns - 1]) or source[ns - 1] == '_')) ns -= 1;
                    const kw = source[ns..ne];
                    if (kw.len > 0 and kw.len <= kw_name_buf.len) {
                        @memcpy(kw_name_buf[0..kw.len], kw);
                        kw_name_len = kw.len;
                    }
                    break :kw_scan;
                }
            }
        }
        // Extract method name before '('
        const method_name = extractWord(source, if (co > 0) co - 1 else 0);
        if (method_name.len == 0) return emptyResult(msg);

        const sym_stmt = try self.db.prepare(
            \\SELECT id, return_type, doc FROM symbols WHERE name = ? AND kind = 'def' LIMIT 1
        );
        defer sym_stmt.finalize();
        sym_stmt.bind_text(1, method_name);
        if (!(try sym_stmt.step())) return emptyResult(msg);
        const symbol_id = sym_stmt.column_int(0);

        const param_stmt = try self.db.prepare(
            \\SELECT name, kind, type_hint FROM params WHERE symbol_id = ? ORDER BY position
        );
        defer param_stmt.finalize();
        param_stmt.bind_int(1, symbol_id);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;

        // Build label and parameters array
        var label_aw = std.Io.Writer.Allocating.init(self.alloc);
        const lw = &label_aw.writer;
        try lw.writeAll(method_name);
        try lw.writeByte('(');

        var param_labels = std.ArrayList([]u8){};
        defer {
            for (param_labels.items) |p| self.alloc.free(p);
            param_labels.deinit(self.alloc);
        }

        var param_index: u32 = 0;
        var first_param = true;
        while (try param_stmt.step()) {
            const pname = param_stmt.column_text(0);
            const pkind = param_stmt.column_text(1);
            // Match the active parameter by keyword argument name
            if (kw_name_len > 0 and kw_active_param == null) {
                if ((std.mem.eql(u8, pkind, "keyword") or std.mem.eql(u8, pkind, "optional")) and
                    std.mem.eql(u8, pname, kw_name_buf[0..kw_name_len]))
                {
                    kw_active_param = param_index;
                }
            }
            const ptype = param_stmt.column_text(2);

            if (!first_param) try lw.writeByte(',');
            first_param = false;

            var plw = std.Io.Writer.Allocating.init(self.alloc);
            const pw = &plw.writer;

            if (std.mem.eql(u8, pkind, "rest")) {
                try pw.print("*{s}", .{pname});
            } else if (std.mem.eql(u8, pkind, "keyword_rest")) {
                try pw.print("**{s}", .{pname});
            } else if (std.mem.eql(u8, pkind, "block")) {
                try pw.print("&{s}", .{pname});
            } else if (std.mem.eql(u8, pkind, "keyword")) {
                if (ptype.len > 0) {
                    try pw.print("{s}: {s}", .{ pname, ptype });
                } else {
                    try pw.print("{s}:", .{pname});
                }
            } else if (std.mem.eql(u8, pkind, "optional")) {
                if (ptype.len > 0) {
                    try pw.print("{s}?: {s}", .{ pname, ptype });
                } else {
                    try pw.print("{s}?", .{pname});
                }
            } else {
                if (ptype.len > 0) {
                    try pw.print("{s}: {s}", .{ pname, ptype });
                } else {
                    try pw.writeAll(pname);
                }
            }

            const pl = try plw.toOwnedSlice();
            try lw.writeAll(pl);
            try param_labels.append(self.alloc, pl);
            param_index += 1;
        }
        // Apply keyword-argument-matched active parameter index if found
        if (kw_active_param) |kwap| active_param = kwap;
        try lw.writeByte(')');

        const sig_return_type = sym_stmt.column_text(1);
        if (sig_return_type.len > 0) {
            try lw.writeAll(" \xe2\x86\x92 ");
            try lw.writeAll(sig_return_type);
        }

        const label = try label_aw.toOwnedSlice();
        defer self.alloc.free(label);

        const sym_doc = sym_stmt.column_text(2);

        try w.writeAll("{\"signatures\":[{\"label\":");
        try writeEscapedJson(w, label);
        try w.writeAll(",\"parameters\":[");
        for (param_labels.items, 0..) |pl, idx| {
            if (idx > 0) try w.writeByte(',');
            try w.writeAll("{\"label\":");
            try writeEscapedJson(w, pl);
            try w.writeByte('}');
        }
        try w.writeAll("],\"documentation\":\"");
        if (sym_doc.len > 0) {
            try writeEscapedJsonContent(w, sym_doc);
        }
        try w.writeAll("\"}],\"activeSignature\":0,\"activeParameter\":");
        try w.print("{d}", .{active_param});
        try w.writeByte('}');

        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = try aw.toOwnedSlice(),
            .@"error" = null,
        };
    }

    fn handleTypeDefinition(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
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
        const pos_val = obj.get("position") orelse return emptyResult(msg);
        const pos = switch (pos_val) {
            .object => |o| o,
            else => return emptyResult(msg),
        };
        const line_val = pos.get("line") orelse return emptyResult(msg);
        const line: u32 = switch (line_val) {
            .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
            else => return emptyResult(msg),
        };
        const char_val = pos.get("character") orelse return emptyResult(msg);
        const character: u32 = switch (char_val) {
            .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
            else => return emptyResult(msg),
        };

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);
        const source = self.readSourceForUri(uri, path) catch
            return emptyResult(msg);
        defer self.alloc.free(source);

        const offset = self.clientPosToOffset(source, line, character);
        const word = extractWord(source, offset);
        if (word.len == 0) return emptyResult(msg);

        const cursor_line: i64 = @intCast(line + 1); // 1-based for DB

        // Check local_vars for type_hint
        const file_stmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
        defer file_stmt.finalize();
        file_stmt.bind_text(1, path);
        if (!(try file_stmt.step())) return emptyResult(msg);
        const file_id = file_stmt.column_int(0);

        var type_name: ?[]const u8 = null;

        const lv_stmt = try self.db.prepare(
            \\SELECT type_hint FROM local_vars
            \\WHERE file_id = ? AND name = ? AND line <= ? AND type_hint IS NOT NULL
            \\ORDER BY line DESC LIMIT 1
        );
        defer lv_stmt.finalize();
        lv_stmt.bind_int(1, file_id);
        lv_stmt.bind_text(2, word);
        lv_stmt.bind_int(3, cursor_line);
        if (try lv_stmt.step()) {
            type_name = lv_stmt.column_text(0);
        }

        // If no local var, check if word is itself a class/module
        if (type_name == null) {
            type_name = word;
        }

        const tn = type_name.?;

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeByte('[');
        var found_any = false;
        var frc_td: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer {
            var frc_it = frc_td.iterator();
            while (frc_it.next()) |e| { self.alloc.free(e.key_ptr.*); self.alloc.free(e.value_ptr.*); }
            frc_td.deinit(self.alloc);
        }

        const sym_stmt = try self.db.prepare(
            \\SELECT s.name, s.line, s.col, f.path
            \\FROM symbols s JOIN files f ON s.file_id = f.id
            \\WHERE s.name = ? AND s.kind IN ('class', 'module') LIMIT 5
        );
        defer sym_stmt.finalize();
        sym_stmt.bind_text(1, tn);
        while (try sym_stmt.step()) {
            if (found_any) try w.writeByte(',');
            found_any = true;
            const sym_name = sym_stmt.column_text(0);
            const sym_line = sym_stmt.column_int(1);
            const sym_col = sym_stmt.column_int(2);
            const sym_path = sym_stmt.column_text(3);
            const start_char = self.toClientColFromPath(&frc_td, sym_path, sym_line - 1, sym_col);
            try w.writeAll("{\"uri\":\"file://");
            try writePathAsUri(w, sym_path);
            try w.writeAll("\",\"range\":{\"start\":{\"line\":");
            try w.print("{d}", .{sym_line - 1});
            try w.writeAll(",\"character\":");
            try w.print("{d}", .{start_char});
            try w.writeAll("},\"end\":{\"line\":");
            try w.print("{d}", .{sym_line - 1});
            try w.writeAll(",\"character\":");
            try w.print("{d}", .{start_char + @as(u32, @intCast(sym_name.len))});
            try w.writeAll("}}}");
        }
        try w.writeByte(']');

        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = try aw.toOwnedSlice(),
            .@"error" = null,
        };
    }

    fn handleInlayHint(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
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
        const start_val = range.get("start") orelse return emptyResult(msg);
        const start = switch (start_val) {
            .object => |o| o,
            else => return emptyResult(msg),
        };
        const end_val = range.get("end") orelse return emptyResult(msg);
        const end_range = switch (end_val) {
            .object => |o| o,
            else => return emptyResult(msg),
        };
        const start_line_val = start.get("line") orelse return emptyResult(msg);
        const start_line: i64 = switch (start_line_val) {
            .integer => |i| i,
            else => return emptyResult(msg),
        };
        const end_line_val = end_range.get("line") orelse return emptyResult(msg);
        const end_line: i64 = switch (end_line_val) {
            .integer => |i| i,
            else => return emptyResult(msg),
        };

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);

        const file_stmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
        defer file_stmt.finalize();
        file_stmt.bind_text(1, path);
        if (!(try file_stmt.step())) {
            var aw2 = std.Io.Writer.Allocating.init(self.alloc);
            try aw2.writer.writeAll("[]");
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw2.toOwnedSlice(), .@"error" = null };
        }
        const file_id = file_stmt.column_int(0);

        // LSP lines are 0-based; DB stores 1-based
        const db_start = start_line + 1;
        const db_end = end_line + 1;

        const stmt = try self.db.prepare(
            \\SELECT name, line, type_hint, col FROM local_vars
            \\WHERE file_id = ? AND type_hint IS NOT NULL AND line BETWEEN ? AND ?
            \\ORDER BY line
        );
        defer stmt.finalize();
        stmt.bind_int(1, file_id);
        stmt.bind_int(2, db_start);
        stmt.bind_int(3, db_end);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeByte('[');
        var first = true;
        while (try stmt.step()) {
            if (!first) try w.writeByte(',');
            first = false;
            const vname = stmt.column_text(0);
            const vline = stmt.column_int(1);
            const vtype = stmt.column_text(2);
            const vcol = stmt.column_int(3);
            const lsp_line = vline - 1;
            const vlen: i64 = @intCast(vname.len);
            try w.print("{{\"position\":{{\"line\":{d},\"character\":{d}}},\"label\":\"", .{ lsp_line, vcol + vlen });
            try writeEscapedJsonContent(w, ": ");
            try writeEscapedJsonContent(w, vtype);
            try w.writeAll("\",\"kind\":1,\"paddingLeft\":false,\"paddingRight\":true}");
        }

        // Return type hints for def methods
        const def_stmt = try self.db.prepare(
            \\SELECT name, line, col, return_type
            \\FROM symbols
            \\WHERE file_id = ? AND kind = 'def' AND return_type IS NOT NULL
            \\  AND line BETWEEN ? AND ?
            \\ORDER BY line
        );
        defer def_stmt.finalize();
        def_stmt.bind_int(1, file_id);
        def_stmt.bind_int(2, db_start);
        def_stmt.bind_int(3, db_end);
        while (try def_stmt.step()) {
            if (!first) try w.writeByte(',');
            first = false;
            const dname = def_stmt.column_text(0);
            const dline = def_stmt.column_int(1);
            const dcol = def_stmt.column_int(2);
            const dret = def_stmt.column_text(3);
            const dlsp_line = dline - 1;
            const dlen: i64 = @intCast(dname.len);
            try w.print("{{\"position\":{{\"line\":{d},\"character\":{d}}},\"label\":\"", .{ dlsp_line, dcol + dlen });
            try writeEscapedJsonContent(w, "\u{2192} ");
            try writeEscapedJsonContent(w, dret);
            try w.writeAll("\",\"kind\":1,\"paddingLeft\":true,\"paddingRight\":false}");
        }

        // Parameter name hints at call sites (AST-based, avoids source scanning bugs)
        const source = self.readSourceForUri(uri, path) catch null;
        defer if (source) |s| self.alloc.free(s);
        if (source) |src| {
            // Need null-terminated source for Prism
            const src_z = self.alloc.allocSentinel(u8, src.len, 0) catch null;
            defer if (src_z) |sz| self.alloc.free(sz);
            if (src_z) |sz| {
                @memcpy(sz, src);
                var arena = prism_mod.Arena{ .current = null, .block_count = 0 };
                defer prism_mod.arena_free(&arena);
                var pparser: prism_mod.Parser = undefined;
                prism_mod.parser_init(&arena, &pparser, sz.ptr, src.len, null);
                defer prism_mod.parser_free(&pparser);
                const root = prism_mod.parse(&pparser);
                if (root != null) {
                    var hint_ctx = ParamHintCtx{
                        .db = self.db,
                        .alloc = self.alloc,
                        .parser = &pparser,
                        .w = w,
                        .file_id = file_id,
                        .db_start = db_start,
                        .db_end = db_end,
                        .first_ptr = &first,
                        .source = src,
                        .encoding_utf8 = self.encoding_utf8,
                    };
                    prism_mod.visit_node(root, paramHintVisitor, &hint_ctx);
                }
            }
        }

        try w.writeByte(']');

        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = try aw.toOwnedSlice(),
            .@"error" = null,
        };
    }

    fn handleSemanticTokensFull(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
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

        // Look up file_id
        const file_stmt = try self.db.prepare("SELECT id, mtime FROM files WHERE path = ?");
        defer file_stmt.finalize();
        file_stmt.bind_text(1, path);
        if (!(try file_stmt.step())) {
            var aw2 = std.Io.Writer.Allocating.init(self.alloc);
            try aw2.writer.writeAll("{\"resultId\":\"0\",\"data\":[]}");
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw2.toOwnedSlice(), .@"error" = null };
        }
        const file_id = file_stmt.column_int(0);
        const file_mtime = file_stmt.column_int(1);
        var mtime_buf: [32]u8 = undefined;
        const result_id = std.fmt.bufPrint(&mtime_buf, "{d}", .{file_mtime}) catch "0";

        const tok_stmt = try self.db.prepare("SELECT blob FROM sem_tokens WHERE file_id = ?");
        defer tok_stmt.finalize();
        tok_stmt.bind_int(1, file_id);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.print("{{\"resultId\":\"{s}\",\"data\":[", .{result_id});

        if (try tok_stmt.step()) {
            var blob = tok_stmt.column_blob(0);
            var conv_blob: ?[]u8 = null;
            defer if (conv_blob) |b| self.alloc.free(b);
            if (!self.encoding_utf8) {
                if (self.readSourceForUri(uri, path)) |src| {
                    defer self.alloc.free(src);
                    conv_blob = convertSemBlobToUtf16(blob, src, self.alloc) catch null;
                    if (conv_blob) |b| blob = b;
                } else |_| {}
            }
            const count = blob.len / 4;
            var first = true;
            for (0..count) |idx| {
                if (!first) try w.writeByte(',');
                first = false;
                const val = std.mem.readInt(u32, blob[idx * 4 ..][0..4], .little);
                try w.print("{d}", .{val});
            }
            // Store token count for delta accuracy
            const u32_count = blob.len / 4;
            const token_count: i64 = @intCast(u32_count / 5);
            var meta_key_buf: [64]u8 = undefined;
            const meta_key = std.fmt.bufPrint(&meta_key_buf, "sem_token_count_{d}", .{file_id}) catch "sem_token_count_0";
            setMetaInt(self.db, meta_key, token_count, self.alloc);
        }

        try w.writeAll("]}");

        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = try aw.toOwnedSlice(),
            .@"error" = null,
        };
    }

    const DefOrigin = struct {
        line: u32,
        start_char: u32,
        end_char: u32,
    };

    fn queryAndEmitDefinitions(self: *Server, w: *std.Io.Writer, name: []const u8, found_any: *bool, frc: *std.StringHashMapUnmanaged([]const u8), origin: ?DefOrigin) !void {
        const stmt = try self.db.prepare(
            \\SELECT s.name, s.line, s.col, f.path
            \\FROM symbols s JOIN files f ON s.file_id = f.id
            \\WHERE s.name = ?
            \\UNION
            \\SELECT s2.name, s2.line, s2.col, f2.path
            \\FROM symbols s2 JOIN files f2 ON s2.file_id = f2.id
            \\JOIN mixins m ON s2.file_id IN (
            \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=m.module_name
            \\)
            \\WHERE s2.name = ? AND s2.kind = 'def'
            \\LIMIT 10
        );
        defer stmt.finalize();
        stmt.bind_text(1, name);
        stmt.bind_text(2, name);
        while (try stmt.step()) {
            if (found_any.*) try w.writeByte(',');
            found_any.* = true;
            const sym_name = stmt.column_text(0);
            const sym_line = stmt.column_int(1);
            const sym_col = stmt.column_int(2);
            const sym_path = stmt.column_text(3);
            const start_char = self.toClientColFromPath(frc, sym_path, sym_line - 1, sym_col);
            if (self.client_caps_def_link) {
                // LocationLink format (LSP 3.14+)
                try w.writeAll("{\"targetUri\":\"file://");
                try writePathAsUri(w, sym_path);
                try w.print("\",\"targetRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                    sym_line - 1, start_char, sym_line - 1, start_char + @as(u32, @intCast(sym_name.len)),
                });
                try w.print(",\"targetSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                    sym_line - 1, start_char, sym_line - 1, start_char + @as(u32, @intCast(sym_name.len)),
                });
                if (origin) |orig| {
                    try w.print(",\"originSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                        orig.line, orig.start_char, orig.line, orig.end_char,
                    });
                }
                try w.writeByte('}');
            } else {
                // Location format (legacy)
                try w.writeAll("{\"uri\":\"file://");
                try writePathAsUri(w, sym_path);
                try w.writeAll("\",\"range\":{\"start\":{\"line\":");
                try w.print("{d}", .{sym_line - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{start_char});
                try w.writeAll("},\"end\":{\"line\":");
                try w.print("{d}", .{sym_line - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{start_char + @as(u32, @intCast(sym_name.len))});
                try w.writeAll("}}}");
            }
        }
    }

    fn handleFormatting(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
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
        if (self.tmp_dir) |d| std.fs.makeDirAbsolute(d) catch {};
        const actual_tmp = try std.fmt.allocPrint(self.alloc, "{s}/fmt-{d}.rb", .{ tmp_base, self.fmt_counter });
        self.fmt_counter +%= 1;
        defer {
            std.fs.deleteFileAbsolute(actual_tmp) catch {}; // cleanup — ignore error
            self.alloc.free(actual_tmp);
        }
        std.fs.cwd().writeFile(.{ .sub_path = actual_tmp, .data = source }) catch return emptyResult(msg);

        self.probeRubocopBundle();
        const fmt_argv: []const []const u8 = if (self.rubocop_use_bundle.load(.monotonic))
            &.{ "bundle", "exec", "rubocop", "--autocorrect-all", "--no-color", "-f", "quiet", actual_tmp }
        else
            &.{ "rubocop", "--autocorrect-all", "--no-color", "-f", "quiet", actual_tmp };
        var child = std.process.Child.init(fmt_argv, self.alloc);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.cwd = self.root_path orelse source_dir;
        child.spawn() catch {
            if (!self.rubocop_checked.load(.monotonic)) {
                self.rubocop_checked.store(true, .monotonic);
                self.rubocop_available.store(false, .monotonic);
                self.sendShowMessage(2, "refract: formatting requires rubocop in PATH");
            }
            return emptyResult(msg);
        };
        var tctx_fmt = TimeoutCtx{ .child = &child, .done = std.atomic.Value(bool).init(false), .timeout_ns = self.rubocop_timeout_ms.load(.monotonic) * std.time.ns_per_ms };
        const tkill_fmt = std.Thread.spawn(.{}, TimeoutCtx.run, .{&tctx_fmt}) catch null;
        if (child.wait()) |term| {
            tctx_fmt.done.store(true, .release);
            if (tkill_fmt) |t| t.join();
            switch (term) {
                .Exited => |code| if (code >= 2) self.sendLogMessage(2, "refract: rubocop failed (check rubocop config)"),
                else => {},
            }
        } else |_| {
            tctx_fmt.done.store(true, .release);
            if (tkill_fmt) |t| t.join();
        }

        const formatted = std.fs.cwd().readFileAlloc(self.alloc, actual_tmp, self.max_file_size.load(.monotonic)) catch {
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

    fn handleCodeAction(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
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

        if (!has_rubocop) {
            const empty = try self.alloc.dupe(u8, empty_json_array);
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = empty, .@"error" = null };
        }

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);
        if (!self.pathInBounds(path)) return emptyResult(msg);
        const source = self.readSourceForUri(uri, path) catch return emptyResult(msg);
        defer self.alloc.free(source);

        const source_dir_ca = std.fs.path.dirname(path) orelse "/tmp";
        const tmp_base_ca = self.tmp_dir orelse "/tmp";
        if (self.tmp_dir) |d| std.fs.makeDirAbsolute(d) catch {};
        const actual_tmp_ca = try std.fmt.allocPrint(self.alloc, "{s}/ca-{d}.rb", .{ tmp_base_ca, self.fmt_counter });
        self.fmt_counter +%= 1;
        defer {
            std.fs.deleteFileAbsolute(actual_tmp_ca) catch {}; // cleanup — ignore error
            self.alloc.free(actual_tmp_ca);
        }
        std.fs.cwd().writeFile(.{ .sub_path = actual_tmp_ca, .data = source }) catch return emptyResult(msg);

        var child = std.process.Child.init(
            &.{ "rubocop", "--autocorrect-all", "--no-color", "-f", "quiet", actual_tmp_ca },
            self.alloc,
        );
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.cwd = self.root_path orelse source_dir_ca;
        child.spawn() catch {
            if (!self.rubocop_checked.load(.monotonic)) {
                self.rubocop_checked.store(true, .monotonic);
                self.rubocop_available.store(false, .monotonic);
                self.sendShowMessage(2, "refract: formatting requires rubocop in PATH");
            }
            return emptyResult(msg);
        };
        var tctx_ca = TimeoutCtx{ .child = &child, .done = std.atomic.Value(bool).init(false), .timeout_ns = self.rubocop_timeout_ms.load(.monotonic) * std.time.ns_per_ms };
        const tkill_ca = std.Thread.spawn(.{}, TimeoutCtx.run, .{&tctx_ca}) catch null;
        if (child.wait()) |term| {
            tctx_ca.done.store(true, .release);
            if (tkill_ca) |t| t.join();
            switch (term) {
                .Exited => |code| if (code >= 2) self.sendLogMessage(2, "refract: rubocop failed (check rubocop config)"),
                else => {},
            }
        } else |_| {
            tctx_ca.done.store(true, .release);
            if (tkill_ca) |t| t.join();
        }

        const formatted = std.fs.cwd().readFileAlloc(self.alloc, actual_tmp_ca, self.max_file_size.load(.monotonic)) catch {
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
        const actual_lines_ca: i64 = @intCast(std.mem.count(u8, source, "\n") + 1);
        try w.writeAll("[{\"title\":\"Fix with RuboCop\",\"kind\":\"quickfix\",\"isPreferred\":true,\"diagnostics\":[],\"edit\":{\"changes\":{");
        try writeEscapedJson(w, uri);
        try w.print(":[{{\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}},\"newText\":", .{actual_lines_ca});
        try writeEscapedJson(w, formatted);
        try w.writeAll("}]}}}]");
        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = try aw.toOwnedSlice(),
            .@"error" = null,
        };
    }

    fn handleDidCreateFiles(self: *Server, msg: types.RequestMessage) void {
        const params = msg.params orelse return;
        const obj = switch (params) {
            .object => |o| o,
            else => return,
        };
        const files_val = obj.get("files") orelse return;
        const files = switch (files_val) {
            .array => |a| a,
            else => return,
        };

        for (files.items) |file| {
            const f = switch (file) {
                .object => |o| o,
                else => continue,
            };
            const uri_val = f.get("uri") orelse continue;
            const uri = switch (uri_val) {
                .string => |s| s,
                else => continue,
            };
            const path = uriToPath(self.alloc, uri) catch continue;
            defer self.alloc.free(path);
            const is_indexed = std.mem.endsWith(u8, path, ".rb") or
                std.mem.endsWith(u8, path, ".rbs") or
                std.mem.endsWith(u8, path, ".rbi") or
                std.mem.endsWith(u8, path, ".erb") or
                std.mem.endsWith(u8, path, ".rake") or
                std.mem.endsWith(u8, path, ".gemspec") or
                std.mem.endsWith(u8, path, ".ru") or
                std.mem.endsWith(u8, path, "/Rakefile") or
                std.mem.endsWith(u8, path, "/Gemfile");
            if (!is_indexed) continue;
            const paths = [_][]const u8{path};
            self.db_mutex.lock();
            indexer.reindex(self.db, &paths, false, self.alloc, self.max_file_size.load(.monotonic)) catch self.sendLogMessage(2, "refract: reindex failed");
            self.db_mutex.unlock();
        }
    }

    fn handleDidDeleteFiles(self: *Server, msg: types.RequestMessage) void {
        const params = msg.params orelse return;
        const obj = switch (params) {
            .object => |o| o,
            else => return,
        };
        const files_val = obj.get("files") orelse return;
        const files = switch (files_val) {
            .array => |a| a,
            else => return,
        };

        for (files.items) |file| {
            const f = switch (file) {
                .object => |o| o,
                else => continue,
            };
            const uri_val = f.get("uri") orelse continue;
            const uri = switch (uri_val) {
                .string => |s| s,
                else => continue,
            };
            const path = uriToPath(self.alloc, uri) catch continue;
            defer self.alloc.free(path);
            self.db_mutex.lock();
            const sel = self.db.prepare("SELECT id FROM files WHERE path = ?") catch {
                self.db_mutex.unlock();
                continue;
            };
            sel.bind_text(1, path);
            const file_id: ?i64 = if (sel.step() catch false) sel.column_int(0) else null;
            sel.finalize();
            if (file_id) |fid| {
                const dels = [_][*:0]const u8{
                    "DELETE FROM sem_tokens WHERE file_id = ?",
                    "DELETE FROM local_vars WHERE file_id = ?",
                    "DELETE FROM refs WHERE file_id = ?",
                    "DELETE FROM symbols WHERE file_id = ?",
                    "DELETE FROM files WHERE id = ?",
                };
                for (dels) |sql| {
                    const st = self.db.prepare(sql) catch continue;
                    st.bind_int(1, fid);
                    _ = st.step() catch |e| {
                        var buf: [128]u8 = undefined;
                        const m = std.fmt.bufPrint(&buf, "refract: rename symbol update failed: {s}", .{@errorName(e)}) catch "refract: rename symbol update failed";
                        self.sendLogMessage(2, m);
                    };
                    st.finalize();
                }
            }
            self.db_mutex.unlock();
            // Remove from incr_paths so flushIncrPaths doesn't re-add deleted files
            self.incr_paths_mu.lock();
            var ip_idx: usize = 0;
            while (ip_idx < self.incr_paths.items.len) {
                if (std.mem.eql(u8, self.incr_paths.items[ip_idx], path)) {
                    self.alloc.free(self.incr_paths.items[ip_idx]);
                    _ = self.incr_paths.orderedRemove(ip_idx);
                } else {
                    ip_idx += 1;
                }
            }
            self.incr_paths_mu.unlock();
            // Mark as explicitly deleted so background scan workers skip it
            self.deleted_paths_mu.lock();
            if (self.alloc.dupe(u8, path)) |dp| {
                if (self.deleted_paths.count() < MAX_DELETED_PATHS) {
                    self.deleted_paths.put(self.alloc, dp, {}) catch self.alloc.free(dp);
                } else {
                    self.alloc.free(dp);
                }
            } else |_| {}
            self.deleted_paths_mu.unlock();
            var aw2 = std.Io.Writer.Allocating.init(self.alloc);
            const w2 = &aw2.writer;
            w2.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":") catch continue;
            writeEscapedJson(w2, uri) catch { aw2.deinit(); continue; };
            w2.writeAll(",\"diagnostics\":[]}}") catch { aw2.deinit(); continue; };
            const json2 = aw2.toOwnedSlice() catch continue;
            defer self.alloc.free(json2);
            self.sendNotification(json2);
        }
    }

    fn handleDidRenameFiles(self: *Server, msg: types.RequestMessage) void {
        const params = msg.params orelse return;
        const obj = switch (params) { .object => |o| o, else => return };
        const files_val = obj.get("files") orelse return;
        const files = switch (files_val) { .array => |a| a.items, else => return };
        for (files) |f| {
            const fobj = switch (f) { .object => |o| o, else => continue };
            const old_uri = switch (fobj.get("oldUri") orelse continue) { .string => |s| s, else => continue };
            const new_uri = switch (fobj.get("newUri") orelse continue) { .string => |s| s, else => continue };
            const old_path = uriToPath(self.alloc, old_uri) catch continue;
            defer self.alloc.free(old_path);
            const new_path = uriToPath(self.alloc, new_uri) catch continue;
            defer self.alloc.free(new_path);
            const stmt = self.db.prepare("UPDATE files SET path=? WHERE path=?") catch continue;
            defer stmt.finalize();
            stmt.bind_text(1, new_path);
            stmt.bind_text(2, old_path);
            _ = stmt.step() catch |e| {
                var buf: [128]u8 = undefined;
                const m = std.fmt.bufPrint(&buf, "refract: rename symbol update failed: {s}", .{@errorName(e)}) catch "refract: rename symbol update failed";
                self.sendLogMessage(2, m);
            };
            var aw3 = std.Io.Writer.Allocating.init(self.alloc);
            const w3 = &aw3.writer;
            w3.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":") catch continue;
            writeEscapedJson(w3, old_uri) catch { aw3.deinit(); continue; };
            w3.writeAll(",\"diagnostics\":[]}}") catch { aw3.deinit(); continue; };
            const json3 = aw3.toOwnedSlice() catch continue;
            defer self.alloc.free(json3);
            self.sendNotification(json3);
        }
    }

    fn handleRangeFormatting(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        const params = msg.params orelse return emptyResult(msg);
        const obj = switch (params) { .object => |o| o, else => return emptyResult(msg) };
        const td_val = obj.get("textDocument") orelse return emptyResult(msg);
        const td = switch (td_val) { .object => |o| o, else => return emptyResult(msg) };
        const uri_val = td.get("uri") orelse return emptyResult(msg);
        const uri = switch (uri_val) { .string => |s| s, else => return emptyResult(msg) };
        const range_val = obj.get("range") orelse return emptyResult(msg);
        const range = switch (range_val) { .object => |o| o, else => return emptyResult(msg) };
        const start_obj = switch (range.get("start") orelse return emptyResult(msg)) { .object => |o| o, else => return emptyResult(msg) };
        const end_obj = switch (range.get("end") orelse return emptyResult(msg)) { .object => |o| o, else => return emptyResult(msg) };
        const start_line: i64 = switch (start_obj.get("line") orelse return emptyResult(msg)) { .integer => |i| i, else => return emptyResult(msg) };
        const end_line: i64 = switch (end_obj.get("line") orelse return emptyResult(msg)) { .integer => |i| i, else => return emptyResult(msg) };

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);
        if (!self.pathInBounds(path)) return emptyResult(msg);
        const source = self.readSourceForUri(uri, path) catch return emptyResult(msg);
        defer self.alloc.free(source);

        const source_dir_rf = std.fs.path.dirname(path) orelse "/tmp";
        const tmp_base_rf = self.tmp_dir orelse "/tmp";
        if (self.tmp_dir) |d| std.fs.makeDirAbsolute(d) catch {};
        const actual_tmp_rf = try std.fmt.allocPrint(self.alloc, "{s}/rfmt-{d}.rb", .{ tmp_base_rf, self.fmt_counter });
        self.fmt_counter +%= 1;
        defer {
            std.fs.deleteFileAbsolute(actual_tmp_rf) catch {}; // cleanup — ignore error
            self.alloc.free(actual_tmp_rf);
        }
        std.fs.cwd().writeFile(.{ .sub_path = actual_tmp_rf, .data = source }) catch return emptyResult(msg);

        var child = std.process.Child.init(
            &.{ "rubocop", "--autocorrect-all", "--no-color", "-f", "quiet", actual_tmp_rf },
            self.alloc,
        );
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.cwd = self.root_path orelse source_dir_rf;
        child.spawn() catch {
            if (!self.rubocop_checked.load(.monotonic)) {
                self.rubocop_checked.store(true, .monotonic);
                self.rubocop_available.store(false, .monotonic);
                self.sendShowMessage(2, "refract: formatting requires rubocop in PATH");
            }
            return emptyResult(msg);
        };
        var tctx_rf = TimeoutCtx{ .child = &child, .done = std.atomic.Value(bool).init(false), .timeout_ns = self.rubocop_timeout_ms.load(.monotonic) * std.time.ns_per_ms };
        const tkill_rf = std.Thread.spawn(.{}, TimeoutCtx.run, .{&tctx_rf}) catch null;
        if (child.wait()) |term| {
            tctx_rf.done.store(true, .release);
            if (tkill_rf) |t| t.join();
            switch (term) {
                .Exited => |code| if (code >= 2) self.sendLogMessage(2, "refract: rubocop failed (check rubocop config)"),
                else => {},
            }
        } else |_| {
            tctx_rf.done.store(true, .release);
            if (tkill_rf) |t| t.join();
        }

        const formatted = std.fs.cwd().readFileAlloc(self.alloc, actual_tmp_rf, self.max_file_size.load(.monotonic)) catch {
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
        var lines_buf = std.ArrayList(u8){};
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
            .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null,
        };
    }

    fn handleDocumentHighlight(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
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
        const pos_val = obj.get("position") orelse return emptyResult(msg);
        const pos = switch (pos_val) {
            .object => |o| o,
            else => return emptyResult(msg),
        };
        const line_val = pos.get("line") orelse return emptyResult(msg);
        const line: u32 = switch (line_val) {
            .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
            else => return emptyResult(msg),
        };
        const char_val = pos.get("character") orelse return emptyResult(msg);
        const character: u32 = switch (char_val) {
            .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
            else => return emptyResult(msg),
        };

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);
        if (!self.pathInBounds(path)) return emptyResult(msg);
        const source = self.readSourceForUri(uri, path) catch
            return emptyResult(msg);
        defer self.alloc.free(source);

        const offset = self.clientPosToOffset(source, line, character);
        const word = extractWord(source, offset);
        if (word.len == 0) return emptyResult(msg);

        const file_stmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
        defer file_stmt.finalize();
        file_stmt.bind_text(1, path);
        if (!(try file_stmt.step())) return emptyResult(msg);
        const file_id = file_stmt.column_int(0);

        // Resolve scope for local-var-aware highlight
        const cursor_line_1based_hl: i64 = @intCast(line + 1);
        var hl_word_start: usize = offset;
        while (hl_word_start > 0 and isRubyIdent(source[hl_word_start - 1])) hl_word_start -= 1;
        var hl_line_start: usize = 0;
        var hi: usize = 0;
        while (hi < hl_word_start) : (hi += 1) {
            if (source[hi] == '\n') hl_line_start = hi + 1;
        }
        const hl_col_0: i64 = @intCast(hl_word_start - hl_line_start);
        const hl_scope_id = resolveScopeId(self, file_id, word, cursor_line_1based_hl, hl_col_0);
        const is_hl_local = hl_scope_id != null;

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeByte('[');
        var first = true;

        // Symbol definitions in this file
        const sym_stmt = try self.db.prepare(
            \\SELECT line, col FROM symbols WHERE file_id=? AND name=?
        );
        defer sym_stmt.finalize();
        sym_stmt.bind_int(1, file_id);
        sym_stmt.bind_text(2, word);
        while (try sym_stmt.step()) {
            if (!first) try w.writeByte(',');
            first = false;
            const hl = sym_stmt.column_int(0);
            const hc = sym_stmt.column_int(1);
            const hl_line_src = getLineSlice(source, @intCast(hl - 1));
            const hc_client = self.toClientCol(hl_line_src, @intCast(hc));
            try w.writeAll("{\"range\":{\"start\":{\"line\":");
            try w.print("{d}", .{hl - 1});
            try w.writeAll(",\"character\":");
            try w.print("{d}", .{hc_client});
            try w.writeAll("},\"end\":{\"line\":");
            try w.print("{d}", .{hl - 1});
            try w.writeAll(",\"character\":");
            try w.print("{d}", .{hc_client + @as(u32, @intCast(word.len))});
            try w.writeAll("}},\"kind\":1}");
        }

        // Refs in this file (scope-filtered for local vars to avoid cross-method highlights)
        const ref_stmt = if (is_hl_local) blk: {
            const sid = hl_scope_id.?;
            if (sid != 0) {
                const s = try self.db.prepare(
                    \\SELECT line, col FROM refs WHERE file_id=? AND name=? AND scope_id=?
                );
                s.bind_int(1, file_id);
                s.bind_text(2, word);
                s.bind_int(3, sid);
                break :blk s;
            } else {
                const s = try self.db.prepare(
                    \\SELECT line, col FROM refs WHERE file_id=? AND name=? AND scope_id IS NULL
                );
                s.bind_int(1, file_id);
                s.bind_text(2, word);
                break :blk s;
            }
        } else blk: {
            const s = try self.db.prepare(
                \\SELECT line, col FROM refs WHERE file_id=? AND name=?
            );
            s.bind_int(1, file_id);
            s.bind_text(2, word);
            break :blk s;
        };
        defer ref_stmt.finalize();
        while (try ref_stmt.step()) {
            if (!first) try w.writeByte(',');
            first = false;
            const hl = ref_stmt.column_int(0);
            const hc = ref_stmt.column_int(1);
            const hl_line_src = getLineSlice(source, @intCast(hl - 1));
            const hc_client = self.toClientCol(hl_line_src, @intCast(hc));
            try w.writeAll("{\"range\":{\"start\":{\"line\":");
            try w.print("{d}", .{hl - 1});
            try w.writeAll(",\"character\":");
            try w.print("{d}", .{hc_client});
            try w.writeAll("},\"end\":{\"line\":");
            try w.print("{d}", .{hl - 1});
            try w.writeAll(",\"character\":");
            try w.print("{d}", .{hc_client + @as(u32, @intCast(word.len))});
            const ref_kind: u32 = if (is_hl_local) 2 else 1;
            try w.print("}}}},\"kind\":{d}}}", .{ref_kind});
        }

        // Local var writes in this file (scope-filtered to avoid cross-method highlights)
        if (is_hl_local) {
            const sid = hl_scope_id.?;
            const lv_stmt = if (sid != 0)
                try self.db.prepare(
                    \\SELECT line, col FROM local_vars WHERE file_id=? AND name=? AND scope_id=?
                )
            else
                try self.db.prepare(
                    \\SELECT line, col FROM local_vars WHERE file_id=? AND name=? AND scope_id IS NULL
                );
            defer lv_stmt.finalize();
            lv_stmt.bind_int(1, file_id);
            lv_stmt.bind_text(2, word);
            if (sid != 0) lv_stmt.bind_int(3, sid);
            while (try lv_stmt.step()) {
                if (!first) try w.writeByte(',');
                first = false;
                const hl = lv_stmt.column_int(0);
                const hc = lv_stmt.column_int(1);
                const hl_line_src = getLineSlice(source, @intCast(hl - 1));
                const hc_client = self.toClientCol(hl_line_src, @intCast(hc));
                try w.writeAll("{\"range\":{\"start\":{\"line\":");
                try w.print("{d}", .{hl - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{hc_client});
                try w.writeAll("},\"end\":{\"line\":");
                try w.print("{d}", .{hl - 1});
                try w.writeAll(",\"character\":");
                try w.print("{d}", .{hc_client + @as(u32, @intCast(word.len))});
                try w.writeAll("}},\"kind\":3}");
            }
        }

        try w.writeByte(']');
        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = try aw.toOwnedSlice(),
            .@"error" = null,
        };
    }

    // Returns the scope_id if the cursor is on a local variable (write or scoped read),
    // null if it's a global/method symbol, or error.NotFound if nothing matches.
    fn resolveScopeId(self: *Server, file_id: i64, name: []const u8, cursor_line_1based: i64, cursor_col: i64) ?i64 {
        // Check local_vars writes at/before cursor (closest one wins)
        const lv = self.db.prepare(
            \\SELECT scope_id FROM local_vars
            \\WHERE file_id=? AND name=? AND line<=?
            \\ORDER BY line DESC LIMIT 1
        ) catch return null;
        defer lv.finalize();
        lv.bind_int(1, file_id);
        lv.bind_text(2, name);
        lv.bind_int(3, cursor_line_1based);
        if (lv.step() catch false) {
            if (lv.column_type(0) != 5) return lv.column_int(0); // SQLITE_NULL=5
            return 0; // scope_id IS NULL means top-level local
        }
        // Check scoped refs at cursor position
        const rf = self.db.prepare(
            \\SELECT scope_id FROM refs
            \\WHERE file_id=? AND name=? AND line=? AND col<=? AND scope_id IS NOT NULL
            \\LIMIT 1
        ) catch return null;
        defer rf.finalize();
        rf.bind_int(1, file_id);
        rf.bind_text(2, name);
        rf.bind_int(3, cursor_line_1based);
        rf.bind_int(4, cursor_col);
        if (rf.step() catch false) {
            if (rf.column_type(0) != 5) return rf.column_int(0);
        }
        return null;
    }

    fn handleSelectionRange(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
        const params = msg.params orelse return emptyResult(msg);
        const obj = switch (params) { .object => |o| o, else => return emptyResult(msg) };
        const td = switch (obj.get("textDocument") orelse return emptyResult(msg)) { .object => |o| o, else => return emptyResult(msg) };
        const uri = switch (td.get("uri") orelse return emptyResult(msg)) { .string => |s| s, else => return emptyResult(msg) };
        const positions_val = obj.get("positions") orelse return emptyResult(msg);
        const positions = switch (positions_val) { .array => |a| a, else => return emptyResult(msg) };
        if (positions.items.len == 0) return emptyResult(msg);
        const pos = switch (positions.items[0]) { .object => |o| o, else => return emptyResult(msg) };
        const line: u32 = switch (pos.get("line") orelse return emptyResult(msg)) { .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg), else => return emptyResult(msg) };
        _ = switch (pos.get("character") orelse return emptyResult(msg)) { .integer => |i| if (i >= 0) @as(u32, @intCast(i)) else return emptyResult(msg), else => return emptyResult(msg) };

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);

        const file_stmt = try self.db.prepare("SELECT id FROM files WHERE path=?");
        defer file_stmt.finalize();
        file_stmt.bind_text(1, path);
        if (!(try file_stmt.step())) return emptyResult(msg);
        const file_id = file_stmt.column_int(0);

        const db_line: i64 = @intCast(line + 1);
        // Find innermost symbol containing cursor
        const sym_stmt = try self.db.prepare(
            \\SELECT name, line, col, end_line FROM symbols WHERE file_id=? AND line<=? AND end_line>=? ORDER BY (end_line-line) ASC LIMIT 1
        );
        defer sym_stmt.finalize();
        sym_stmt.bind_int(1, file_id);
        sym_stmt.bind_int(2, db_line);
        sym_stmt.bind_int(3, db_line);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeByte('[');

        if (try sym_stmt.step()) {
            const sym_name = sym_stmt.column_text(0);
            const sym_line = sym_stmt.column_int(1);
            const sym_col = sym_stmt.column_int(2);
            const sym_end = sym_stmt.column_int(3);

            // Word range (innermost)
            const word_end_col = sym_col + @as(i64, @intCast(sym_name.len));
            // Method body range (parent)
            try w.print("{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":999}}}},\"parent\":{{\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":999}}}}}}}}", .{
                sym_line - 1, sym_col,
                sym_line - 1,
                sym_line - 1, sym_end - 1,
            });
            _ = word_end_col;
        }

        try w.writeByte(']');
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    }

    fn handleLinkedEditingRange(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        if (self.isCancelled(msg.id)) return null;
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
        const params = msg.params orelse return emptyResult(msg);
        const obj = switch (params) { .object => |o| o, else => return emptyResult(msg) };
        const td = switch (obj.get("textDocument") orelse return emptyResult(msg)) { .object => |o| o, else => return emptyResult(msg) };
        const uri = switch (td.get("uri") orelse return emptyResult(msg)) { .string => |s| s, else => return emptyResult(msg) };
        const pos = switch (obj.get("position") orelse return emptyResult(msg)) { .object => |o| o, else => return emptyResult(msg) };
        const line: u32 = switch (pos.get("line") orelse return emptyResult(msg)) { .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg), else => return emptyResult(msg) };
        const character: u32 = switch (pos.get("character") orelse return emptyResult(msg)) { .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg), else => return emptyResult(msg) };

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);
        if (!self.pathInBounds(path)) return emptyResult(msg);
        const source = self.readSourceForUri(uri, path) catch return emptyResult(msg);
        defer self.alloc.free(source);

        const offset = self.clientPosToOffset(source, line, character);
        const word = extractWord(source, offset);
        if (word.len == 0) return emptyResult(msg);

        const file_stmt = try self.db.prepare("SELECT id FROM files WHERE path=?");
        defer file_stmt.finalize();
        file_stmt.bind_text(1, path);
        if (!(try file_stmt.step())) return emptyResult(msg);
        const file_id = file_stmt.column_int(0);

        // Find scope_id for the variable at this position
        const scope_stmt = try self.db.prepare(
            "SELECT scope_id FROM local_vars WHERE file_id=? AND name=? " ++
            "AND line<=? ORDER BY line DESC LIMIT 1"
        );
        defer scope_stmt.finalize();
        scope_stmt.bind_int(1, file_id);
        scope_stmt.bind_text(2, word);
        scope_stmt.bind_int(3, @intCast(line + 1));
        var scope_id_opt: ?i64 = null;
        if (try scope_stmt.step()) {
            const sv = scope_stmt.column_int(0);
            if (scope_stmt.column_type(0) != 5) scope_id_opt = sv; // 5 = SQLITE_NULL
        }

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeAll("{\"ranges\":[");
        var first = true;

        const has_scope = scope_id_opt != null;
        const q: [*:0]const u8 = if (has_scope)
            "SELECT line, col FROM local_vars WHERE file_id=? AND name=? AND scope_id=? ORDER BY line"
        else
            "SELECT line, col FROM local_vars WHERE file_id=? AND name=? AND scope_id IS NULL ORDER BY line";
        const occ_stmt = try self.db.prepare(q);
        defer occ_stmt.finalize();
        occ_stmt.bind_int(1, file_id);
        occ_stmt.bind_text(2, word);
        if (has_scope) occ_stmt.bind_int(3, scope_id_opt.?);

        while (try occ_stmt.step()) {
            const ln = occ_stmt.column_int(0) - 1;
            const col = occ_stmt.column_int(1);
            const ln_src = getLineSlice(source, @intCast(ln));
            const start_char = self.toClientCol(ln_src, @intCast(col));
            const end_char = start_char + @as(u32, @intCast(word.len));
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
                .{ ln, start_char, ln, end_char });
        }
        try w.writeAll("]}");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    }

    fn handlePrepareRename(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
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
        const pos_val = obj.get("position") orelse return emptyResult(msg);
        const pos = switch (pos_val) {
            .object => |o| o,
            else => return emptyResult(msg),
        };
        const line_val = pos.get("line") orelse return emptyResult(msg);
        const line: u32 = switch (line_val) {
            .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
            else => return emptyResult(msg),
        };
        const char_val = pos.get("character") orelse return emptyResult(msg);
        const character: u32 = switch (char_val) {
            .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
            else => return emptyResult(msg),
        };

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);
        if (!self.pathInBounds(path)) return emptyResult(msg);
        const source = self.readSourceForUri(uri, path) catch
            return emptyResult(msg);
        defer self.alloc.free(source);

        const offset = self.clientPosToOffset(source, line, character);
        const word = extractWord(source, offset);
        if (word.len == 0) return emptyResult(msg);

        var word_start = offset;
        while (word_start > 0 and isRubyIdent(source[word_start - 1])) word_start -= 1;

        var line_start: usize = 0;
        var j: usize = 0;
        while (j < word_start) : (j += 1) {
            if (source[j] == '\n') line_start = j + 1;
        }
        const word_col: usize = word_start - line_start;
        const word_line_src = getLineSlice(source, line);
        const word_col_client = self.toClientCol(word_line_src, word_col);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeAll("{\"range\":{\"start\":{\"line\":");
        try w.print("{d}", .{line});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{word_col_client});
        try w.writeAll("},\"end\":{\"line\":");
        try w.print("{d}", .{line});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{word_col_client + @as(u32, @intCast(word.len))});
        try w.writeAll("}},\"placeholder\":\"");
        for (word) |wc| {
            if (wc == '"' or wc == '\\') try w.writeByte('\\');
            try w.writeByte(wc);
        }
        try w.writeAll("\"}");

        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = try aw.toOwnedSlice(),
            .@"error" = null,
        };
    }

    fn handleRename(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
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
        const pos_val = obj.get("position") orelse return emptyResult(msg);
        const pos = switch (pos_val) {
            .object => |o| o,
            else => return emptyResult(msg),
        };
        const line_val = pos.get("line") orelse return emptyResult(msg);
        const line: u32 = switch (line_val) {
            .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
            else => return emptyResult(msg),
        };
        const char_val = pos.get("character") orelse return emptyResult(msg);
        const character: u32 = switch (char_val) {
            .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
            else => return emptyResult(msg),
        };
        const new_name_val = obj.get("newName") orelse return emptyResult(msg);
        const new_name = switch (new_name_val) {
            .string => |s| s,
            else => return emptyResult(msg),
        };

        if (!isValidRubyIdent(new_name)) {
            return types.ResponseMessage{
                .id = msg.id,
                .result = null,
                .@"error" = .{ .code = -32602, .message = "Invalid Ruby identifier" },
            };
        }

        const path_for_conflict = uriToPath(self.alloc, uri) catch null;
        defer if (path_for_conflict) |p| self.alloc.free(p);
        if (path_for_conflict) |pfc| {
            if (self.db.prepare("SELECT 1 FROM symbols WHERE name=? AND file_id=(SELECT id FROM files WHERE path=?)")) |cs| {
                defer cs.finalize();
                cs.bind_text(1, new_name);
                cs.bind_text(2, pfc);
                if (cs.step() catch false) {
                    return types.ResponseMessage{
                        .id = msg.id,
                        .result = null,
                        .@"error" = .{ .code = -32600, .message = "Name already exists in this file" },
                    };
                }
            } else |_| {}
        }

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);
        if (!self.pathInBounds(path)) return emptyResult(msg);
        const source = self.readSourceForUri(uri, path) catch
            return emptyResult(msg);
        defer self.alloc.free(source);

        const offset = self.clientPosToOffset(source, line, character);
        const word = extractWord(source, offset);
        if (word.len == 0) return emptyResult(msg);

        const Edit = struct { line: i64, col: i64 };
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var edits_map = std.StringHashMap(std.ArrayList(Edit)).init(a);

        // Determine if this is a local variable rename (scoped) or a global symbol rename.
        // Local scope is checked FIRST — a local var named `foo` must not trigger a global
        // rename of `def foo` elsewhere in the codebase.
        const cursor_line_1based: i64 = @intCast(line + 1);

        var word_col_start: usize = offset;
        while (word_col_start > 0 and isRubyIdent(source[word_col_start - 1])) word_col_start -= 1;
        var rename_line_start: usize = 0;
        var rj: usize = 0;
        while (rj < word_col_start) : (rj += 1) {
            if (source[rj] == '\n') rename_line_start = rj + 1;
        }
        const cursor_col_0: i64 = @intCast(word_col_start - rename_line_start);

        var is_local_rename = false;
        var rename_scope_id: ?i64 = null;

        // Step 1: check if cursor is on a local var in this file
        const fid_check = try self.db.prepare("SELECT id FROM files WHERE path=?");
        defer fid_check.finalize();
        fid_check.bind_text(1, path);
        if (try fid_check.step()) {
            const fid = fid_check.column_int(0);
            if (resolveScopeId(self, fid, word, cursor_line_1based, cursor_col_0)) |sid| {
                is_local_rename = true;
                rename_scope_id = if (sid != 0) sid else null;
            }
        }

        // Step 2: fall through to global only if no local var found at cursor

        if (!is_local_rename) {
            var method_parent: ?[]const u8 = null;
            defer if (method_parent) |mp| self.alloc.free(mp);
            if (self.db.prepare(
                "SELECT parent_name FROM symbols WHERE name=? AND kind IN ('def','classdef') AND parent_name IS NOT NULL LIMIT 1"
            )) |ps| {
                defer ps.finalize();
                ps.bind_text(1, word);
                if (ps.step() catch false) {
                    const pn = ps.column_text(0);
                    if (pn.len > 0) method_parent = self.alloc.dupe(u8, pn) catch null;
                }
            } else |_| {}

            if (method_parent) |mp| {
                const sym_stmt = try self.db.prepare(
                    \\SELECT s.line, s.col, f.path FROM symbols s JOIN files f ON s.file_id=f.id
                    \\WHERE s.name=? AND f.is_gem=0 AND s.file_id IN (
                    \\  SELECT file_id FROM symbols WHERE name=? AND kind IN ('class','module','classdef','def')
                    \\)
                );
                defer sym_stmt.finalize();
                sym_stmt.bind_text(1, word);
                sym_stmt.bind_text(2, mp);
                while (try sym_stmt.step()) {
                    const sym_line = sym_stmt.column_int(0);
                    const sym_col = sym_stmt.column_int(1);
                    const sym_path = sym_stmt.column_text(2);
                    const key = try a.dupe(u8, sym_path);
                    const gop = try edits_map.getOrPut(key);
                    if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Edit){};
                    try gop.value_ptr.append(a, .{ .line = sym_line, .col = sym_col });
                }
                const ref_stmt = try self.db.prepare(
                    \\SELECT r.line, r.col, f.path FROM refs r JOIN files f ON r.file_id=f.id
                    \\WHERE r.name=? AND f.is_gem=0 AND r.file_id IN (
                    \\  SELECT file_id FROM symbols WHERE name=? AND kind IN ('class','module','classdef','def')
                    \\)
                );
                defer ref_stmt.finalize();
                ref_stmt.bind_text(1, word);
                ref_stmt.bind_text(2, mp);
                while (try ref_stmt.step()) {
                    const ref_line = ref_stmt.column_int(0);
                    const ref_col = ref_stmt.column_int(1);
                    const ref_path = ref_stmt.column_text(2);
                    const key = try a.dupe(u8, ref_path);
                    const gop = try edits_map.getOrPut(key);
                    if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Edit){};
                    try gop.value_ptr.append(a, .{ .line = ref_line, .col = ref_col });
                }
            } else {
                const sym_stmt = try self.db.prepare(
                    \\SELECT s.line, s.col, f.path FROM symbols s JOIN files f ON s.file_id=f.id WHERE s.name=? AND f.is_gem=0
                );
                defer sym_stmt.finalize();
                sym_stmt.bind_text(1, word);
                while (try sym_stmt.step()) {
                    const sym_line = sym_stmt.column_int(0);
                    const sym_col = sym_stmt.column_int(1);
                    const sym_path = sym_stmt.column_text(2);
                    const key = try a.dupe(u8, sym_path);
                    const gop = try edits_map.getOrPut(key);
                    if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Edit){};
                    try gop.value_ptr.append(a, .{ .line = sym_line, .col = sym_col });
                }

                const ref_stmt = try self.db.prepare(
                    \\SELECT r.line, r.col, f.path FROM refs r JOIN files f ON r.file_id=f.id WHERE r.name=? AND f.is_gem=0
                );
                defer ref_stmt.finalize();
                ref_stmt.bind_text(1, word);
                while (try ref_stmt.step()) {
                    const ref_line = ref_stmt.column_int(0);
                    const ref_col = ref_stmt.column_int(1);
                    const ref_path = ref_stmt.column_text(2);
                    const key = try a.dupe(u8, ref_path);
                    const gop = try edits_map.getOrPut(key);
                    if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Edit){};
                    try gop.value_ptr.append(a, .{ .line = ref_line, .col = ref_col });
                }
            }
        } else {
            // Local variable rename: scoped to the enclosing method
            if (rename_scope_id) |sid| {
                const lv_stmt = try self.db.prepare(
                    \\SELECT lv.line, lv.col, f.path FROM local_vars lv JOIN files f ON lv.file_id=f.id
                    \\WHERE lv.name=? AND lv.scope_id=?
                );
                defer lv_stmt.finalize();
                lv_stmt.bind_text(1, word);
                lv_stmt.bind_int(2, sid);
                while (try lv_stmt.step()) {
                    const lv_line = lv_stmt.column_int(0);
                    const lv_col = lv_stmt.column_int(1);
                    const lv_path = lv_stmt.column_text(2);
                    const key = try a.dupe(u8, lv_path);
                    const gop = try edits_map.getOrPut(key);
                    if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Edit){};
                    try gop.value_ptr.append(a, .{ .line = lv_line, .col = lv_col });
                }

                const ref_stmt = try self.db.prepare(
                    \\SELECT r.line, r.col, f.path FROM refs r JOIN files f ON r.file_id=f.id
                    \\WHERE r.name=? AND r.scope_id=?
                );
                defer ref_stmt.finalize();
                ref_stmt.bind_text(1, word);
                ref_stmt.bind_int(2, sid);
                while (try ref_stmt.step()) {
                    const ref_line = ref_stmt.column_int(0);
                    const ref_col = ref_stmt.column_int(1);
                    const ref_path = ref_stmt.column_text(2);
                    const key = try a.dupe(u8, ref_path);
                    const gop = try edits_map.getOrPut(key);
                    if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Edit){};
                    try gop.value_ptr.append(a, .{ .line = ref_line, .col = ref_col });
                }
            } else {
                // Top-level (no enclosing def): rename in file only
                const fid_stmt2 = try self.db.prepare("SELECT id FROM files WHERE path=?");
                defer fid_stmt2.finalize();
                fid_stmt2.bind_text(1, path);
                if (try fid_stmt2.step()) {
                    const fid = fid_stmt2.column_int(0);
                    const lv_stmt = try self.db.prepare(
                        \\SELECT lv.line, lv.col, f.path FROM local_vars lv JOIN files f ON lv.file_id=f.id
                        \\WHERE lv.name=? AND lv.file_id=? AND lv.scope_id IS NULL
                    );
                    defer lv_stmt.finalize();
                    lv_stmt.bind_text(1, word);
                    lv_stmt.bind_int(2, fid);
                    while (try lv_stmt.step()) {
                        const lv_line = lv_stmt.column_int(0);
                        const lv_col = lv_stmt.column_int(1);
                        const lv_path = lv_stmt.column_text(2);
                        const key = try a.dupe(u8, lv_path);
                        const gop = try edits_map.getOrPut(key);
                        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Edit){};
                        try gop.value_ptr.append(a, .{ .line = lv_line, .col = lv_col });
                    }

                    const ref_stmt = try self.db.prepare(
                        \\SELECT r.line, r.col, f.path FROM refs r JOIN files f ON r.file_id=f.id
                        \\WHERE r.name=? AND r.file_id=? AND r.scope_id IS NULL
                    );
                    defer ref_stmt.finalize();
                    ref_stmt.bind_text(1, word);
                    ref_stmt.bind_int(2, fid);
                    while (try ref_stmt.step()) {
                        const ref_line = ref_stmt.column_int(0);
                        const ref_col = ref_stmt.column_int(1);
                        const ref_path = ref_stmt.column_text(2);
                        const key = try a.dupe(u8, ref_path);
                        const gop = try edits_map.getOrPut(key);
                        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Edit){};
                        try gop.value_ptr.append(a, .{ .line = ref_line, .col = ref_col });
                    }
                }
            }
        }

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        var frc_rn: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer {
            var frc_it = frc_rn.iterator();
            while (frc_it.next()) |e| { self.alloc.free(e.key_ptr.*); self.alloc.free(e.value_ptr.*); }
            frc_rn.deinit(self.alloc);
        }
        var it = edits_map.iterator();
        if (self.client_caps_doc_changes) {
            try w.writeAll("{\"documentChanges\":[");
            var first_path = true;
            while (it.next()) |entry| {
                if (!first_path) try w.writeByte(',');
                first_path = false;
                try w.writeAll("{\"textDocument\":{\"uri\":\"file://");
                try writePathAsUri(w, entry.key_ptr.*);
                try w.writeAll("\",\"version\":1},\"edits\":[");
                var first_edit = true;
                for (entry.value_ptr.items) |edit| {
                    if (!first_edit) try w.writeByte(',');
                    first_edit = false;
                    const edit_start = self.toClientColFromPath(&frc_rn, entry.key_ptr.*, edit.line - 1, edit.col);
                    try w.writeAll("{\"range\":{\"start\":{\"line\":");
                    try w.print("{d}", .{edit.line - 1});
                    try w.writeAll(",\"character\":");
                    try w.print("{d}", .{edit_start});
                    try w.writeAll("},\"end\":{\"line\":");
                    try w.print("{d}", .{edit.line - 1});
                    try w.writeAll(",\"character\":");
                    try w.print("{d}", .{edit_start + @as(u32, @intCast(word.len))});
                    try w.writeAll("}},\"newText\":");
                    try writeEscapedJson(w, new_name);
                    try w.writeByte('}');
                }
                try w.writeAll("]}");
            }
            try w.writeAll("]}");
        } else {
            try w.writeAll("{\"changes\":{");
            var first_path = true;
            while (it.next()) |entry| {
                if (!first_path) try w.writeByte(',');
                first_path = false;
                try w.writeAll("\"file://");
                try writePathAsUri(w, entry.key_ptr.*);
                try w.writeAll("\":[");
                var first_edit = true;
                for (entry.value_ptr.items) |edit| {
                    if (!first_edit) try w.writeByte(',');
                    first_edit = false;
                    const edit_start = self.toClientColFromPath(&frc_rn, entry.key_ptr.*, edit.line - 1, edit.col);
                    try w.writeAll("{\"range\":{\"start\":{\"line\":");
                    try w.print("{d}", .{edit.line - 1});
                    try w.writeAll(",\"character\":");
                    try w.print("{d}", .{edit_start});
                    try w.writeAll("},\"end\":{\"line\":");
                    try w.print("{d}", .{edit.line - 1});
                    try w.writeAll(",\"character\":");
                    try w.print("{d}", .{edit_start + @as(u32, @intCast(word.len))});
                    try w.writeAll("}},\"newText\":");
                    try writeEscapedJson(w, new_name);
                    try w.writeByte('}');
                }
                try w.writeByte(']');
            }
            try w.writeAll("}}");
        }

        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = try aw.toOwnedSlice(),
            .@"error" = null,
        };
    }

    fn handleSemanticTokensRange(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
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
        const range_obj = switch (range_val) {
            .object => |o| o,
            else => return emptyResult(msg),
        };
        const start_obj = switch (range_obj.get("start") orelse return emptyResult(msg)) {
            .object => |o| o,
            else => return emptyResult(msg),
        };
        const end_obj = switch (range_obj.get("end") orelse return emptyResult(msg)) {
            .object => |o| o,
            else => return emptyResult(msg),
        };
        const start_line: u32 = switch (start_obj.get("line") orelse return emptyResult(msg)) {
            .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
            else => return emptyResult(msg),
        };
        const end_line: u32 = switch (end_obj.get("line") orelse return emptyResult(msg)) {
            .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
            else => return emptyResult(msg),
        };

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);

        const file_stmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
        defer file_stmt.finalize();
        file_stmt.bind_text(1, path);
        if (!(try file_stmt.step())) {
            var aw2 = std.Io.Writer.Allocating.init(self.alloc);
            try aw2.writer.writeAll("{\"data\":[]}");
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw2.toOwnedSlice(), .@"error" = null };
        }
        const file_id = file_stmt.column_int(0);

        const tok_stmt = try self.db.prepare("SELECT blob FROM sem_tokens WHERE file_id = ?");
        defer tok_stmt.finalize();
        tok_stmt.bind_int(1, file_id);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeAll("{\"data\":[");

        if (try tok_stmt.step()) {
            var blob = tok_stmt.column_blob(0);
            var conv_blob_r: ?[]u8 = null;
            defer if (conv_blob_r) |b| self.alloc.free(b);
            if (!self.encoding_utf8) {
                if (self.readSourceForUri(uri, path)) |src| {
                    defer self.alloc.free(src);
                    conv_blob_r = convertSemBlobToUtf16(blob, src, self.alloc) catch null;
                    if (conv_blob_r) |b| blob = b;
                } else |_| {}
            }
            const num_tokens = blob.len / 20;
            // Decode absolute positions and collect filtered tokens as flat u32 array
            // 5 values per token: abs_line, abs_col, len, tt, tm
            const max_filtered = num_tokens * 5;
            const filtered_buf = try self.alloc.alloc(u32, max_filtered);
            defer self.alloc.free(filtered_buf);
            var filtered_count: usize = 0;
            var abs_line: u32 = 0;
            var abs_col: u32 = 0;
            for (0..num_tokens) |i| {
                const dl = std.mem.readInt(u32, blob[i * 20 + 0 ..][0..4], .little);
                const dc = std.mem.readInt(u32, blob[i * 20 + 4 ..][0..4], .little);
                const len = std.mem.readInt(u32, blob[i * 20 + 8 ..][0..4], .little);
                const tt = std.mem.readInt(u32, blob[i * 20 + 12 ..][0..4], .little);
                const tm = std.mem.readInt(u32, blob[i * 20 + 16 ..][0..4], .little);
                abs_line += dl;
                abs_col = if (dl == 0) abs_col + dc else dc;
                if (abs_line >= start_line and abs_line <= end_line) {
                    filtered_buf[filtered_count * 5 + 0] = abs_line;
                    filtered_buf[filtered_count * 5 + 1] = abs_col;
                    filtered_buf[filtered_count * 5 + 2] = len;
                    filtered_buf[filtered_count * 5 + 3] = tt;
                    filtered_buf[filtered_count * 5 + 4] = tm;
                    filtered_count += 1;
                }
            }
            // Re-encode filtered tokens as delta sequence
            var prev_line: u32 = start_line;
            var prev_col: u32 = 0;
            var first = true;
            for (0..filtered_count) |i| {
                const tok_line = filtered_buf[i * 5 + 0];
                const tok_col = filtered_buf[i * 5 + 1];
                const tok_len = filtered_buf[i * 5 + 2];
                const tok_tt = filtered_buf[i * 5 + 3];
                const tok_tm = filtered_buf[i * 5 + 4];
                if (!first) try w.writeByte(',');
                first = false;
                const out_dl = tok_line - prev_line;
                const out_dc = if (out_dl == 0) tok_col - prev_col else tok_col;
                try w.print("{d},{d},{d},{d},{d}", .{ out_dl, out_dc, tok_len, tok_tt, tok_tm });
                prev_line = tok_line;
                prev_col = tok_col;
            }
        }

        try w.writeAll("]}");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    }

    fn handleExecuteCommand(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
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
            self.enqueueAllOpenDocs();
        }
        if (std.mem.eql(u8, cmd, "refract.restartIndexer") or
            std.mem.eql(u8, cmd, "refract.forceReindex") or
            std.mem.eql(u8, cmd, "refract.toggleGemIndex"))
        {
            known_cmd = true;
            if (std.mem.eql(u8, cmd, "refract.forceReindex")) {
                self.db_mutex.lock();
                self.db.exec("DELETE FROM symbols WHERE file_id IN (SELECT id FROM files WHERE is_gem=0)") catch {};
                self.db.exec("DELETE FROM files WHERE is_gem=0") catch {};
                self.db_mutex.unlock();
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
                .array => |arr| if (arr.items.len >= 2) {
                    const file_uri = switch (arr.items[0]) { .string => |s| s, else => "" };
                    const path2 = uriToPath(self.alloc, file_uri) catch null;
                    defer if (path2) |p| self.alloc.free(p);
                    if (path2) |p| {
                        var msg_buf: [1024]u8 = undefined;
                        const run_msg = std.fmt.bufPrint(&msg_buf, "Run: bundle exec rspec {s}", .{p}) catch "Run: bundle exec rspec";
                        self.sendShowMessage(3, run_msg);
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

    fn handlePullDiagnostic(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        if (self.isCancelled(msg.id)) return null;
        const params = msg.params orelse return emptyResult(msg);
        const obj = switch (params) { .object => |o| o, else => return emptyResult(msg) };
        const td_val = obj.get("textDocument") orelse return emptyResult(msg);
        const td = switch (td_val) { .object => |o| o, else => return emptyResult(msg) };
        const uri_val = td.get("uri") orelse return emptyResult(msg);
        const uri = switch (uri_val) { .string => |s| s, else => return emptyResult(msg) };
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
            self.db_mutex.lock();
            if (self.db.prepare("SELECT is_gem FROM files WHERE path = ?")) |gs| {
                defer gs.finalize();
                gs.bind_text(1, path);
                if (gs.step() catch false) is_gem_file = gs.column_int(0) != 0;
            } else |_| {}
            self.db_mutex.unlock();
            if (!is_gem_file) self.enqueueRubocopPath(path);
        }

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.print("{{\"kind\":\"full\",\"resultId\":\"{s}\",\"items\":[", .{result_id});
        var first = true;
        self.writeDiagItems(w, prism_diags, diag_source, &first);
        try w.writeAll("]}");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    }

    fn handleWillRenameFiles(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        const params = msg.params orelse {
            var aw0 = std.Io.Writer.Allocating.init(self.alloc);
            try aw0.writer.writeAll("{\"changes\":{}}");
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw0.toOwnedSlice(), .@"error" = null };
        };
        const obj = switch (params) {
            .object => |o| o,
            else => {
                var aw0 = std.Io.Writer.Allocating.init(self.alloc);
                try aw0.writer.writeAll("{\"changes\":{}}");
                return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw0.toOwnedSlice(), .@"error" = null };
            },
        };
        const files_val = obj.get("files") orelse {
            var aw0 = std.Io.Writer.Allocating.init(self.alloc);
            try aw0.writer.writeAll("{\"changes\":{}}");
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw0.toOwnedSlice(), .@"error" = null };
        };
        const files = switch (files_val) {
            .array => |a| a,
            else => {
                var aw0 = std.Io.Writer.Allocating.init(self.alloc);
                try aw0.writer.writeAll("{\"changes\":{}}");
                return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw0.toOwnedSlice(), .@"error" = null };
            },
        };

        // Build WorkspaceEdit: {"changes": {"file://...": [TextEdit, ...]}}
        var changes_map = std.StringHashMap(std.ArrayList(struct { line: i64, col_start: usize, col_end: usize, new_text: []const u8 })).init(self.alloc);
        defer {
            var cit = changes_map.iterator();
            while (cit.next()) |e| {
                for (e.value_ptr.items) |edit| self.alloc.free(@constCast(edit.new_text));
                e.value_ptr.deinit(self.alloc);
                self.alloc.free(e.key_ptr.*);
            }
            changes_map.deinit();
        }

        for (files.items) |file_val| {
            const file_obj = switch (file_val) {
                .object => |o| o,
                else => continue,
            };
            const old_uri_val = file_obj.get("oldUri") orelse continue;
            const new_uri_val = file_obj.get("newUri") orelse continue;
            const old_uri = switch (old_uri_val) { .string => |s| s, else => continue };
            const new_uri = switch (new_uri_val) { .string => |s| s, else => continue };

            // Only handle .rb renames
            if (!std.mem.endsWith(u8, old_uri, ".rb") or !std.mem.endsWith(u8, new_uri, ".rb")) continue;

            // Extract stem (filename without .rb)
            const old_base = std.fs.path.basename(old_uri);
            const new_base = std.fs.path.basename(new_uri);
            if (old_base.len < 3 or new_base.len < 3) continue;
            const old_stem = old_base[0 .. old_base.len - 3];
            const new_stem = new_base[0 .. new_base.len - 3];
            if (std.mem.eql(u8, old_stem, new_stem)) continue;

            // Query all non-gem files
            self.db_mutex.lock();
            const fstmt = self.db.prepare("SELECT path FROM files WHERE is_gem=0") catch {
                self.db_mutex.unlock();
                continue;
            };
            defer fstmt.finalize();
            var caller_paths = std.ArrayList([]u8){};
            defer { for (caller_paths.items) |p| self.alloc.free(p); caller_paths.deinit(self.alloc); }
            while (fstmt.step() catch false) {
                const p = fstmt.column_text(0);
                if (p.len > 0) {
                    caller_paths.append(self.alloc, self.alloc.dupe(u8, p) catch continue) catch {};
                }
            }
            self.db_mutex.unlock();

            for (caller_paths.items) |cpath| {
                const content = std.fs.cwd().readFileAlloc(self.alloc, cpath, self.max_file_size.load(.monotonic)) catch continue;
                defer self.alloc.free(content);

                var line_num: i64 = 0;
                var line_start: usize = 0;
                while (line_start <= content.len) {
                    const line_end = std.mem.indexOfScalar(u8, content[line_start..], '\n') orelse content.len - line_start;
                    const line_slice = content[line_start .. line_start + line_end];

                    // Find require_relative with old_stem as final path component
                    if (std.mem.indexOf(u8, line_slice, "require_relative") != null) {
                        // Find the string literal in this line
                        var col: usize = 0;
                        while (col < line_slice.len) {
                            if (line_slice[col] == '\'' or line_slice[col] == '"') {
                                const quote = line_slice[col];
                                const str_start = col + 1;
                                const str_end = std.mem.indexOfScalarPos(u8, line_slice, str_start, quote) orelse break;
                                const str = line_slice[str_start..str_end];
                                // Check if old_stem is the final component of this path
                                const last_sep = std.mem.lastIndexOfScalar(u8, str, '/') orelse 0;
                                const final = if (last_sep > 0) str[last_sep + 1 ..] else str;
                                if (std.mem.eql(u8, final, old_stem)) {
                                    // Build new string: replace the final component
                                    const new_str = if (last_sep > 0)
                                        std.fmt.allocPrint(self.alloc, "{c}{s}/{s}{c}", .{ quote, str[0..last_sep], new_stem, quote }) catch break
                                    else
                                        std.fmt.allocPrint(self.alloc, "{c}{s}{c}", .{ quote, new_stem, quote }) catch break;

                                    const file_uri = std.fmt.allocPrint(self.alloc, "file://{s}", .{cpath}) catch { self.alloc.free(new_str); break; };
                                    const gop = changes_map.getOrPut(file_uri) catch { self.alloc.free(new_str); self.alloc.free(file_uri); break; };
                                    if (!gop.found_existing) {
                                        gop.value_ptr.* = .{};
                                    } else {
                                        self.alloc.free(file_uri);
                                    }
                                    gop.value_ptr.append(self.alloc, .{
                                        .line = line_num,
                                        .col_start = col,
                                        .col_end = str_end + 1,
                                        .new_text = new_str,
                                    }) catch { self.alloc.free(new_str); };
                                }
                                col = str_end + 1;
                            } else {
                                col += 1;
                            }
                        }
                    }

                    if (line_start + line_end >= content.len) break;
                    line_start += line_end + 1;
                    line_num += 1;
                }
            }
        }

        // Serialize WorkspaceEdit
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        var cit2 = changes_map.iterator();
        if (self.client_caps_doc_changes) {
            try w.writeAll("{\"documentChanges\":[");
            var first_file = true;
            while (cit2.next()) |e| {
                if (!first_file) try w.writeByte(',');
                first_file = false;
                try w.writeAll("{\"textDocument\":{\"uri\":");
                try writeEscapedJson(w, e.key_ptr.*);
                try w.writeAll(",\"version\":1},\"edits\":[");
                var first_edit = true;
                for (e.value_ptr.items) |edit| {
                    if (!first_edit) try w.writeByte(',');
                    first_edit = false;
                    try w.print(
                        "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":",
                        .{ edit.line, edit.col_start, edit.line, edit.col_end },
                    );
                    try writeEscapedJson(w, edit.new_text);
                    try w.writeByte('}');
                }
                try w.writeAll("]}");
            }
            try w.writeAll("]}");
        } else {
            try w.writeAll("{\"changes\":{");
            var first_file = true;
            while (cit2.next()) |e| {
                if (!first_file) try w.writeByte(',');
                first_file = false;
                try writeEscapedJson(w, e.key_ptr.*);
                try w.writeAll(":[");
                var first_edit = true;
                for (e.value_ptr.items) |edit| {
                    if (!first_edit) try w.writeByte(',');
                    first_edit = false;
                    try w.print(
                        "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":",
                        .{ edit.line, edit.col_start, edit.line, edit.col_end },
                    );
                    try writeEscapedJson(w, edit.new_text);
                    try w.writeByte('}');
                }
                try w.writeByte(']');
            }
            try w.writeAll("}}");
        }
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    }

    fn handleCodeLens(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
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

        const file_stmt = try self.db.prepare("SELECT id FROM files WHERE path=?");
        defer file_stmt.finalize();
        file_stmt.bind_text(1, path);
        if (!(try file_stmt.step())) {
            var aw2 = std.Io.Writer.Allocating.init(self.alloc);
            try aw2.writer.writeAll("[]");
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw2.toOwnedSlice(), .@"error" = null };
        }
        const file_id = file_stmt.column_int(0);

        const sym_stmt = try self.db.prepare(
            \\SELECT s.id, s.name, s.kind, s.line FROM symbols s WHERE s.file_id=?
            \\ORDER BY s.line LIMIT 5000
        );
        defer sym_stmt.finalize();
        sym_stmt.bind_int(1, file_id);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeByte('[');
        var first = true;

        while (try sym_stmt.step()) {
            const sym_name = sym_stmt.column_text(1);
            const sym_kind = sym_stmt.column_text(2);
            const sym_line = sym_stmt.column_int(3);
            const lsp_line = sym_line - 1;

            const ref_stmt = self.db.prepare(
                "SELECT (file_id=?) as local, COUNT(*) FROM refs WHERE name=? GROUP BY local"
            ) catch continue;
            defer ref_stmt.finalize();
            ref_stmt.bind_int(1, file_id);
            ref_stmt.bind_text(2, sym_name);
            var local_count: i64 = 0;
            var other_count: i64 = 0;
            while (try ref_stmt.step()) {
                const is_local = ref_stmt.column_int(0);
                const cnt = ref_stmt.column_int(1);
                if (is_local != 0) local_count += cnt else other_count += cnt;
            }
            const ref_count = local_count + other_count;

            if (!first) try w.writeByte(',');
            first = false;
            try w.print("{{\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}},\"command\":{{\"title\":", .{ lsp_line, lsp_line });
            const ref_label = if (other_count > 0)
                try std.fmt.allocPrint(self.alloc, "{d} refs ({d} files)", .{ ref_count, other_count })
            else
                try std.fmt.allocPrint(self.alloc, "{d} ref{s}", .{ ref_count, if (ref_count == 1) "" else "s" });
            defer self.alloc.free(ref_label);
            try writeEscapedJson(w, ref_label);
            try w.writeAll(",\"command\":\"refract.showReferences\",\"arguments\":[");
            try writeEscapedJson(w, uri);
            try w.print(",{{\"line\":{d},\"character\":0}}]}}}}", .{lsp_line});

            if (std.mem.eql(u8, sym_kind, "test") or std.mem.startsWith(u8, sym_name, "test_")) {
                try w.writeByte(',');
                try w.print("{{\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}},\"command\":{{\"title\":\"\u{25b6} Run\",\"command\":\"refract.runTest\",\"arguments\":[", .{ lsp_line, lsp_line });
                try writeEscapedJson(w, uri);
                try w.print(",{d}]}}}}", .{sym_line});
            }
        }
        try w.writeByte(']');
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    }

    fn handlePrepareTypeHierarchy(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
        const params = msg.params orelse return emptyResult(msg);
        const obj = switch (params) { .object => |o| o, else => return emptyResult(msg) };
        const td = switch (obj.get("textDocument") orelse return emptyResult(msg)) { .object => |o| o, else => return emptyResult(msg) };
        const uri = switch (td.get("uri") orelse return emptyResult(msg)) { .string => |s| s, else => return emptyResult(msg) };
        const pos_val = obj.get("position") orelse return emptyResult(msg);
        const pos = switch (pos_val) { .object => |o| o, else => return emptyResult(msg) };
        const line: u32 = switch (pos.get("line") orelse return emptyResult(msg)) { .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg), else => return emptyResult(msg) };
        const character: u32 = switch (pos.get("character") orelse return emptyResult(msg)) { .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg), else => return emptyResult(msg) };

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);
        if (!self.pathInBounds(path)) return emptyResult(msg);
        const source = self.readSourceForUri(uri, path) catch return emptyResult(msg);
        defer self.alloc.free(source);
        const offset = self.clientPosToOffset(source, line, character);
        const word = extractWord(source, offset);
        if (word.len == 0) return emptyResult(msg);

        const stmt = try self.db.prepare(
            "SELECT s.id, s.name, s.kind, s.line, s.col, f.path FROM symbols s JOIN files f ON s.file_id=f.id WHERE s.name=? AND s.kind IN ('class','module','classdef') LIMIT 1"
        );
        defer stmt.finalize();
        stmt.bind_text(1, word);
        if (!(try stmt.step())) return emptyResult(msg);
        const sym_id = stmt.column_int(0);
        const sym_name = stmt.column_text(1);
        const sym_kind = stmt.column_text(2);
        const sym_line = stmt.column_int(3);
        const sym_col = stmt.column_int(4);
        const sym_path = stmt.column_text(5);
        const kind_num: u8 = if (std.mem.eql(u8, sym_kind, "class")) 5 else 2;
        var frc_pth: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer {
            var frc_it = frc_pth.iterator();
            while (frc_it.next()) |e| { self.alloc.free(e.key_ptr.*); self.alloc.free(e.value_ptr.*); }
            frc_pth.deinit(self.alloc);
        }
        const sym_col_client = self.toClientColFromPath(&frc_pth, sym_path, sym_line - 1, sym_col);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeByte('[');
        try w.writeAll("{\"name\":");
        try writeEscapedJson(w, sym_name);
        try w.print(",\"kind\":{d},\"uri\":\"file://", .{kind_num});
        try writePathAsUri(w, sym_path);
        try w.print("\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"data\":{{\"symbol_id\":{d}}}}}", .{
            sym_line - 1, sym_col_client, sym_line - 1, sym_col_client + @as(u32, @intCast(sym_name.len)),
            sym_line - 1, sym_col_client, sym_line - 1, sym_col_client + @as(u32, @intCast(sym_name.len)),
            sym_id,
        });
        try w.writeByte(']');
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    }

    fn handleTypeHierarchySupertypes(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
        const params = msg.params orelse return emptyResult(msg);
        const obj = switch (params) { .object => |o| o, else => return emptyResult(msg) };
        const item = switch (obj.get("item") orelse return emptyResult(msg)) { .object => |o| o, else => return emptyResult(msg) };
        const name_val = item.get("name") orelse return emptyResult(msg);
        const class_name = switch (name_val) { .string => |s| s, else => return emptyResult(msg) };

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeByte('[');
        var first = true;
        var current_name = try self.alloc.dupe(u8, class_name);
        defer self.alloc.free(current_name);
        var depth: u8 = 0;
        while (depth < 10) : (depth += 1) {
            const parent_stmt = self.db.prepare(
                "SELECT parent_name FROM symbols WHERE name=? AND kind IN ('class','module') LIMIT 1"
            ) catch break;
            defer parent_stmt.finalize();
            parent_stmt.bind_text(1, current_name);
            if (!(parent_stmt.step() catch false)) break;
            const parent_name_raw = parent_stmt.column_text(0);
            if (parent_name_raw.len == 0) break;
            const parent_name_owned = self.alloc.dupe(u8, parent_name_raw) catch break;
            self.alloc.free(current_name);
            current_name = parent_name_owned;

            const sym_stmt = self.db.prepare(
                "SELECT s.id, s.name, s.kind, s.line, s.col, f.path FROM symbols s JOIN files f ON s.file_id=f.id WHERE s.name=? AND s.kind IN ('class','module') LIMIT 1"
            ) catch break;
            defer sym_stmt.finalize();
            sym_stmt.bind_text(1, current_name);
            if (!(sym_stmt.step() catch false)) {
                // Parent exists in DB but no file — emit minimal item
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll("{\"name\":");
                try writeEscapedJson(w, current_name);
                try w.writeAll(",\"kind\":5,\"uri\":\"\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}}}");
                continue;
            }
            const sym_id = sym_stmt.column_int(0);
            const sym_name = sym_stmt.column_text(1);
            const sym_kind = sym_stmt.column_text(2);
            const sym_line = sym_stmt.column_int(3);
            const sym_col = sym_stmt.column_int(4);
            const sym_path = sym_stmt.column_text(5);
            const kind_num: u8 = if (std.mem.eql(u8, sym_kind, "class")) 5 else 2;
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"name\":");
            try writeEscapedJson(w, sym_name);
            try w.print(",\"kind\":{d},\"uri\":\"file://", .{kind_num});
            try writePathAsUri(w, sym_path);
            try w.print("\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"data\":{{\"symbol_id\":{d}}}}}", .{
                sym_line - 1, sym_col, sym_line - 1, sym_col + @as(i64, @intCast(sym_name.len)),
                sym_line - 1, sym_col, sym_line - 1, sym_col + @as(i64, @intCast(sym_name.len)),
                sym_id,
            });
        }
        // Also include mixins as supertypes
        const mix_stmt = self.db.prepare(
            "SELECT m.module_name FROM mixins m JOIN symbols s ON m.class_id=s.id WHERE s.name=?"
        ) catch {
            try w.writeByte(']');
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
        };
        defer mix_stmt.finalize();
        mix_stmt.bind_text(1, class_name);
        while (mix_stmt.step() catch false) {
            const mod_name = mix_stmt.column_text(0);
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"name\":");
            try writeEscapedJson(w, mod_name);
            try w.writeAll(",\"kind\":2,\"uri\":\"\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}}}");
        }
        try w.writeByte(']');
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    }

    fn handleTypeHierarchySubtypes(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
        const params = msg.params orelse return emptyResult(msg);
        const obj = switch (params) { .object => |o| o, else => return emptyResult(msg) };
        const item = switch (obj.get("item") orelse return emptyResult(msg)) { .object => |o| o, else => return emptyResult(msg) };
        const name_val = item.get("name") orelse return emptyResult(msg);
        const class_name = switch (name_val) { .string => |s| s, else => return emptyResult(msg) };

        const stmt = try self.db.prepare(
            "SELECT s.id, s.name, s.kind, s.line, s.col, f.path FROM symbols s JOIN files f ON s.file_id=f.id WHERE s.parent_name=? AND s.kind='class' LIMIT 50"
        );
        defer stmt.finalize();
        stmt.bind_text(1, class_name);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeByte('[');
        var first = true;
        while (try stmt.step()) {
            const sym_id = stmt.column_int(0);
            const sym_name = stmt.column_text(1);
            const sym_line = stmt.column_int(3);
            const sym_col = stmt.column_int(4);
            const sym_path = stmt.column_text(5);
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"name\":");
            try writeEscapedJson(w, sym_name);
            try w.writeAll(",\"kind\":5,\"uri\":\"file://");
            try writePathAsUri(w, sym_path);
            try w.print("\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"data\":{{\"symbol_id\":{d}}}}}", .{
                sym_line - 1, sym_col, sym_line - 1, sym_col + @as(i64, @intCast(sym_name.len)),
                sym_line - 1, sym_col, sym_line - 1, sym_col + @as(i64, @intCast(sym_name.len)),
                sym_id,
            });
        }
        try w.writeByte(']');
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    }

    fn handleSemanticTokensDelta(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
        const params = msg.params orelse return emptyResult(msg);
        const obj = switch (params) { .object => |o| o, else => return emptyResult(msg) };
        const td = switch (obj.get("textDocument") orelse return emptyResult(msg)) { .object => |o| o, else => return emptyResult(msg) };
        const uri = switch (td.get("uri") orelse return emptyResult(msg)) { .string => |s| s, else => return emptyResult(msg) };
        const prev_id: []const u8 = switch (obj.get("previousResultId") orelse std.json.Value{ .string = "" }) {
            .string => |s| s,
            else => "",
        };

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);

        const file_stmt = try self.db.prepare("SELECT id FROM files WHERE path=?");
        defer file_stmt.finalize();
        file_stmt.bind_text(1, path);
        if (!(try file_stmt.step())) {
            var aw2 = std.Io.Writer.Allocating.init(self.alloc);
            try aw2.writer.writeAll("{\"resultId\":\"0\",\"edits\":[]}");
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw2.toOwnedSlice(), .@"error" = null };
        }
        const file_id = file_stmt.column_int(0);

        // Get current mtime from files table
        const mtime_stmt = try self.db.prepare("SELECT mtime FROM files WHERE id=?");
        defer mtime_stmt.finalize();
        mtime_stmt.bind_int(1, file_id);
        const mtime: i64 = if (try mtime_stmt.step()) mtime_stmt.column_int(0) else 0;
        var mtime_buf: [32]u8 = undefined;
        const result_id = std.fmt.bufPrint(&mtime_buf, "{d}", .{mtime}) catch "0";

        if (std.mem.eql(u8, prev_id, result_id)) {
            // No change
            var aw2 = std.Io.Writer.Allocating.init(self.alloc);
            try aw2.writer.print("{{\"resultId\":\"{s}\",\"edits\":[]}}", .{result_id});
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw2.toOwnedSlice(), .@"error" = null };
        }

        // Load current blob and prev_blob for real diff
        const tok_stmt = try self.db.prepare("SELECT blob, prev_blob FROM sem_tokens WHERE file_id=?");
        defer tok_stmt.finalize();
        tok_stmt.bind_int(1, file_id);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        if (!(try tok_stmt.step())) {
            try w.print("{{\"resultId\":\"{s}\",\"edits\":[]}}", .{result_id});
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
        }
        const new_blob = tok_stmt.column_blob(0);
        const prev_blob_raw = tok_stmt.column_blob(1);

        const new_u32 = new_blob.len / 4;
        const old_u32 = if (prev_blob_raw.len > 0) prev_blob_raw.len / 4 else 0;

        if (!self.encoding_utf8) {
            var aw2 = std.Io.Writer.Allocating.init(self.alloc);
            const w2 = &aw2.writer;
            try w2.print("{{\"resultId\":\"{s}\",\"data\":[", .{result_id});
            var out_blob = new_blob;
            var conv2: ?[]u8 = null;
            defer if (conv2) |b| self.alloc.free(b);
            if (self.readSourceForUri(uri, path)) |src| {
                defer self.alloc.free(src);
                conv2 = convertSemBlobToUtf16(new_blob, src, self.alloc) catch null;
                if (conv2) |b| out_blob = b;
            } else |_| {}
            for (0..out_blob.len / 4) |idx| {
                if (idx > 0) try w2.writeByte(',');
                try w2.print("{d}", .{std.mem.readInt(u32, out_blob[idx * 4 ..][0..4], .little)});
            }
            try w2.writeAll("]}");
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw2.toOwnedSlice(), .@"error" = null };
        }

        if (old_u32 == 0) {
            if (prev_id.len > 0) {
                // Editor had tokens we can't diff against — return full SemanticTokens
                var aw2 = std.Io.Writer.Allocating.init(self.alloc);
                const w2 = &aw2.writer;
                try w2.print("{{\"resultId\":\"{s}\",\"data\":[", .{result_id});
                for (0..new_u32) |idx| {
                    if (idx > 0) try w2.writeByte(',');
                    try w2.print("{d}", .{std.mem.readInt(u32, new_blob[idx * 4 ..][0..4], .little)});
                }
                try w2.writeAll("]}");
                return types.ResponseMessage{
                    .id = msg.id, .result = null,
                    .raw_result = try aw2.toOwnedSlice(), .@"error" = null,
                };
            }
            // prev_id empty → initial request → delta insert at 0 is correct
            try w.print("{{\"resultId\":\"{s}\",\"edits\":[{{\"start\":0,\"deleteCount\":0,\"data\":[", .{result_id});
            for (0..new_u32) |idx| {
                if (idx > 0) try w.writeByte(',');
                try w.print("{d}", .{std.mem.readInt(u32, new_blob[idx * 4 ..][0..4], .little)});
            }
            try w.writeAll("]}]}");
        } else {
            // Find first and last differing u32 index
            var first_diff: usize = 0;
            while (first_diff < @min(new_u32, old_u32)) : (first_diff += 1) {
                const nv = std.mem.readInt(u32, new_blob[first_diff * 4 ..][0..4], .little);
                const ov = std.mem.readInt(u32, prev_blob_raw[first_diff * 4 ..][0..4], .little);
                if (nv != ov) break;
            }
            if (first_diff == new_u32 and first_diff == old_u32) {
                // Identical
                try w.print("{{\"resultId\":\"{s}\",\"edits\":[]}}", .{result_id});
            } else {
                var last_new = new_u32;
                var last_old = old_u32;
                while (last_new > first_diff and last_old > first_diff) {
                    const nv = std.mem.readInt(u32, new_blob[(last_new - 1) * 4 ..][0..4], .little);
                    const ov = std.mem.readInt(u32, prev_blob_raw[(last_old - 1) * 4 ..][0..4], .little);
                    if (nv != ov) break;
                    last_new -= 1;
                    last_old -= 1;
                }
                const delete_count = last_old - first_diff;
                try w.print("{{\"resultId\":\"{s}\",\"edits\":[{{\"start\":{d},\"deleteCount\":{d},\"data\":[",
                    .{ result_id, first_diff, delete_count });
                for (first_diff..last_new) |idx| {
                    if (idx > first_diff) try w.writeByte(',');
                    try w.print("{d}", .{std.mem.readInt(u32, new_blob[idx * 4 ..][0..4], .little)});
                }
                try w.writeAll("]}]}");
            }
        }
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    }

    fn handleCallHierarchyPrepare(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
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
        const pos_val = obj.get("position") orelse return emptyResult(msg);
        const pos = switch (pos_val) {
            .object => |o| o,
            else => return emptyResult(msg),
        };
        const line_val = pos.get("line") orelse return emptyResult(msg);
        const line: u32 = switch (line_val) {
            .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
            else => return emptyResult(msg),
        };
        const char_val = pos.get("character") orelse return emptyResult(msg);
        const character: u32 = switch (char_val) {
            .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
            else => return emptyResult(msg),
        };

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);
        if (!self.pathInBounds(path)) return emptyResult(msg);
        const source = self.readSourceForUri(uri, path) catch
            return emptyResult(msg);
        defer self.alloc.free(source);

        const offset = self.clientPosToOffset(source, line, character);
        const word = extractWord(source, offset);
        if (word.len == 0) return emptyResult(msg);

        const stmt = try self.db.prepare(
            \\SELECT s.name, s.kind, s.line, s.col, f.path
            \\FROM symbols s JOIN files f ON s.file_id=f.id
            \\WHERE s.name=? LIMIT 1
        );
        defer stmt.finalize();
        stmt.bind_text(1, word);
        if (!(try stmt.step())) return emptyResult(msg);

        const sym_name = stmt.column_text(0);
        const sym_kind = stmt.column_text(1);
        const sym_line = stmt.column_int(2);
        const sym_col = stmt.column_int(3);
        const sym_path = stmt.column_text(4);

        const kind_num: u8 = if (std.mem.eql(u8, sym_kind, "class")) 5 else if (std.mem.eql(u8, sym_kind, "module")) 2 else 6;
        var frc_chp: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer {
            var frc_it = frc_chp.iterator();
            while (frc_it.next()) |e| { self.alloc.free(e.key_ptr.*); self.alloc.free(e.value_ptr.*); }
            frc_chp.deinit(self.alloc);
        }
        const sym_col_client = self.toClientColFromPath(&frc_chp, sym_path, sym_line - 1, sym_col);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeAll("[{\"name\":");
        try writeEscapedJson(w, sym_name);
        try w.print(",\"kind\":{d},\"uri\":\"file://", .{kind_num});
        try writePathAsUri(w, sym_path);
        try w.print("\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
            sym_line - 1, sym_col_client, sym_line - 1, sym_col_client + @as(u32, @intCast(sym_name.len)),
        });
        try w.print(",\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
            sym_line - 1, sym_col_client, sym_line - 1, sym_col_client + @as(u32, @intCast(sym_name.len)),
        });
        try w.writeAll("}]");

        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    }

    fn handleCallHierarchyIncomingCalls(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
        const params = msg.params orelse return emptyResult(msg);
        const obj = switch (params) {
            .object => |o| o,
            else => return emptyResult(msg),
        };
        const item_val = obj.get("item") orelse return emptyResult(msg);
        const item = switch (item_val) {
            .object => |o| o,
            else => return emptyResult(msg),
        };
        const name_val = item.get("name") orelse return emptyResult(msg);
        const name = switch (name_val) {
            .string => |s| s,
            else => return emptyResult(msg),
        };

        const ref_stmt = try self.db.prepare(
            \\SELECT r.line, r.col, f.path FROM refs r JOIN files f ON r.file_id=f.id
            \\WHERE r.name=? ORDER BY f.path, r.line LIMIT 100
        );
        defer ref_stmt.finalize();
        ref_stmt.bind_text(1, name);

        // Enclosing-method lookup: given (path, line), find innermost def/classdef/test
        const enc_stmt = self.db.prepare(
            \\SELECT s.name, s.kind FROM symbols s JOIN files f ON s.file_id=f.id
            \\WHERE f.path=? AND s.kind IN ('def','classdef','test') AND s.line<=?
            \\ORDER BY s.line DESC LIMIT 1
        ) catch null;
        defer if (enc_stmt) |es| es.finalize();

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        var frc_chi: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer {
            var frc_it = frc_chi.iterator();
            while (frc_it.next()) |e| { self.alloc.free(e.key_ptr.*); self.alloc.free(e.value_ptr.*); }
            frc_chi.deinit(self.alloc);
        }
        try w.writeAll("[");
        var first = true;
        while (try ref_stmt.step()) {
            const ref_line = ref_stmt.column_int(0);
            const ref_col = ref_stmt.column_int(1);
            const ref_path = ref_stmt.column_text(2);
            const ref_col_client = self.toClientColFromPath(&frc_chi, ref_path, ref_line - 1, ref_col);
            // Resolve the enclosing method name; fall back to file basename
            var from_name_buf: [256]u8 = undefined;
            var from_name: []const u8 = std.fs.path.basename(ref_path);
            var from_kind: u32 = 1; // File fallback
            if (enc_stmt) |es| {
                es.reset();
                es.bind_text(1, ref_path);
                es.bind_int(2, ref_line);
                if (es.step() catch false) {
                    const enc_name = es.column_text(0);
                    const enc_kind_str = es.column_text(1);
                    if (enc_name.len > 0 and enc_name.len <= from_name_buf.len) {
                        @memcpy(from_name_buf[0..enc_name.len], enc_name);
                        from_name = from_name_buf[0..enc_name.len];
                    }
                    from_kind = if (std.mem.eql(u8, enc_kind_str, "classdef")) 5 else 6;
                }
            }
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"from\":{\"name\":");
            try writeEscapedJson(w, from_name);
            try w.print(",\"kind\":{d},\"uri\":\"file://", .{from_kind});
            try writePathAsUri(w, ref_path);
            try w.print("\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                ref_line - 1, ref_col_client, ref_line - 1, ref_col_client,
            });
            try w.print(",\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                ref_line - 1, ref_col_client, ref_line - 1, ref_col_client,
            });
            try w.print("}},\"fromRanges\":[{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}]}}", .{
                ref_line - 1, ref_col_client, ref_line - 1, ref_col_client + @as(u32, @intCast(name.len)),
            });
        }
        try w.writeAll("]");

        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    }

    fn handleCallHierarchyOutgoingCalls(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        const RefPos = struct { line: i64, col: i64 };
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
        const params = msg.params orelse return emptyResult(msg);
        const obj = switch (params) {
            .object => |o| o,
            else => return emptyResult(msg),
        };
        const item_val = obj.get("item") orelse return emptyResult(msg);
        const item = switch (item_val) {
            .object => |o| o,
            else => return emptyResult(msg),
        };
        const uri_val = item.get("uri") orelse return emptyResult(msg);
        const uri = switch (uri_val) {
            .string => |s| s,
            else => return emptyResult(msg),
        };
        const range_val = item.get("range") orelse return emptyResult(msg);
        const range = switch (range_val) {
            .object => |o| o,
            else => return emptyResult(msg),
        };
        const start_val = range.get("start") orelse return emptyResult(msg);
        const start_obj = switch (start_val) {
            .object => |o| o,
            else => return emptyResult(msg),
        };
        const start_line_val = start_obj.get("line") orelse return emptyResult(msg);
        const start_line: i64 = switch (start_line_val) {
            .integer => |i| i,
            else => return emptyResult(msg),
        };
        const end_val = range.get("end") orelse return emptyResult(msg);
        const end_obj = switch (end_val) {
            .object => |o| o,
            else => return emptyResult(msg),
        };
        const end_line_val = end_obj.get("line") orelse return emptyResult(msg);
        const end_line: i64 = switch (end_line_val) {
            .integer => |i| i,
            else => return emptyResult(msg),
        };

        const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
        defer self.alloc.free(path);

        const fid_stmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
        defer fid_stmt.finalize();
        fid_stmt.bind_text(1, path);
        if (!(try fid_stmt.step())) {
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try self.alloc.dupe(u8, empty_json_array), .@"error" = null };
        }
        const file_id = fid_stmt.column_int(0);

        const db_start_line: i64 = start_line + 1;
        const db_end_line: i64 = end_line + 1;

        const ref_stmt = try self.db.prepare(
            \\SELECT DISTINCT r.name, r.line, r.col FROM refs r
            \\WHERE r.file_id = ? AND r.line BETWEEN ? AND ?
        );
        defer ref_stmt.finalize();
        ref_stmt.bind_int(1, file_id);
        ref_stmt.bind_int(2, db_start_line);
        ref_stmt.bind_int(3, db_end_line);

        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var ref_names = std.StringHashMap(std.ArrayList(RefPos)).init(a);

        while (try ref_stmt.step()) {
            const ref_name = ref_stmt.column_text(0);
            const ref_line = ref_stmt.column_int(1);
            const ref_col = ref_stmt.column_int(2);
            const gop = try ref_names.getOrPut(ref_name);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(RefPos){};
            }
            try gop.value_ptr.append(a, .{ .line = ref_line, .col = ref_col });
        }

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeAll("[");
        var first = true;

        var iter = ref_names.iterator();
        while (iter.next()) |entry| {
            const ref_name = entry.key_ptr.*;
            const ref_positions = entry.value_ptr.*;

            const def_stmt = try self.db.prepare(
                \\SELECT s.name, s.line, s.col, f.path FROM symbols s JOIN files f ON s.file_id=f.id
                \\WHERE s.name = ? AND s.kind = 'def' LIMIT 1
            );
            defer def_stmt.finalize();
            def_stmt.bind_text(1, ref_name);
            if (!(try def_stmt.step())) continue;

            const def_name = def_stmt.column_text(0);
            const def_line = def_stmt.column_int(1);
            const def_col = def_stmt.column_int(2);
            const def_path = def_stmt.column_text(3);

            if (!first) try w.writeByte(',');
            first = false;

            try w.writeAll("{\"to\":{\"name\":");
            try writeEscapedJson(w, def_name);
            try w.print(",\"kind\":12,\"uri\":\"file://", .{});
            try writePathAsUri(w, def_path);
            try w.print("\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                def_line - 1, def_col, def_line - 1, def_col,
            });
            try w.print(",\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{
                def_line - 1, def_col, def_line - 1, def_col + @as(i64, @intCast(def_name.len)),
            });
            try w.writeAll("},\"fromRanges\":[");
            for (ref_positions.items, 0..) |pos, idx| {
                if (idx > 0) try w.writeByte(',');
                try w.print("{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                    pos.line - 1, pos.col, pos.line - 1, pos.col + @as(i64, @intCast(ref_name.len)),
                });
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]");

        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    }

    fn handleCompletionItemResolve(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
        self.db_mutex.lock();
        defer self.db_mutex.unlock();
        const params = msg.params orelse return emptyResult(msg);
        const item_obj = switch (params) {
            .object => |o| o,
            else => return emptyResult(msg),
        };

        const data_val = item_obj.get("data") orelse {
            const raw = std.json.Stringify.valueAlloc(self.alloc, params, .{}) catch null;
            return types.ResponseMessage{
                .id = msg.id,
                .result = null,
                .raw_result = raw,
                .@"error" = null,
            };
        };
        const data_obj = switch (data_val) {
            .object => |o| o,
            else => {
                const raw = std.json.Stringify.valueAlloc(self.alloc, params, .{}) catch null;
                return types.ResponseMessage{
                    .id = msg.id,
                    .result = null,
                    .raw_result = raw,
                    .@"error" = null,
                };
            },
        };
        const name_val = data_obj.get("name") orelse {
            const raw = std.json.Stringify.valueAlloc(self.alloc, params, .{}) catch null;
            return types.ResponseMessage{
                .id = msg.id,
                .result = null,
                .raw_result = raw,
                .@"error" = null,
            };
        };
        const name = switch (name_val) {
            .string => |s| s,
            else => {
                const raw = std.json.Stringify.valueAlloc(self.alloc, params, .{}) catch null;
                return types.ResponseMessage{
                    .id = msg.id,
                    .result = null,
                    .raw_result = raw,
                    .@"error" = null,
                };
            },
        };

        const def_stmt = try self.db.prepare("SELECT doc, return_type FROM symbols WHERE name = ? AND kind = 'def' LIMIT 1");
        defer def_stmt.finalize();
        def_stmt.bind_text(1, name);
        if (!(try def_stmt.step())) {
            const raw = std.json.Stringify.valueAlloc(self.alloc, params, .{}) catch null;
            return types.ResponseMessage{
                .id = msg.id,
                .result = null,
                .raw_result = raw,
                .@"error" = null,
            };
        }

        const doc = def_stmt.column_text(0);
        const return_type = def_stmt.column_text(1);

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try w.writeByte('{');

        var first_field = true;
        var iter = item_obj.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "data")) continue;
            if (!first_field) try w.writeByte(',');
            first_field = false;
            try writeEscapedJson(w, entry.key_ptr.*);
            try w.writeByte(':');
            const val_str = std.json.Stringify.valueAlloc(self.alloc, entry.value_ptr.*, .{}) catch "null";
            defer self.alloc.free(val_str);
            try w.writeAll(val_str);
        }

        if (return_type.len > 0) {
            if (!first_field) try w.writeByte(',');
            first_field = false;
            try w.writeAll("\"detail\":\"");
            try w.writeAll("\u{2192} ");
            try writeEscapedJsonContent(w, return_type);
            try w.writeByte('"');
        }

        if (doc.len > 0) {
            if (!first_field) try w.writeByte(',');
            first_field = false;
            try w.writeAll("\"documentation\":{\"kind\":\"markdown\",\"value\":\"");
            try writeEscapedJsonContent(w, doc);
            try w.writeAll("\"}");
        }

        try w.writeByte('}');

        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    }

    fn offsetToClientChar(self: *const Server, source: []const u8, offset: usize, line: u32) u32 {
        var line_start: usize = 0;
        var l: u32 = 0;
        var i: usize = 0;
        while (i < source.len and l < line) : (i += 1) {
            if (source[i] == '\n') { l += 1; line_start = i + 1; }
        }
        const col = if (offset >= line_start) offset - line_start else 0;
        if (self.encoding_utf8) return @intCast(col);
        const line_end = std.mem.indexOfPos(u8, source, line_start, "\n") orelse source.len;
        return utf8ColToUtf16(source[line_start..line_end], col);
    }

    fn toClientCol(self: *const Server, line_src: []const u8, col: usize) u32 {
        if (self.encoding_utf8) return @intCast(col);
        return utf8ColToUtf16(line_src, col);
    }

    fn toClientColFromPath(
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

    const home = std.posix.getenv("HOME") orelse "/tmp";
    const data_dir = if (std.posix.getenv("XDG_DATA_HOME")) |xdg|
        try std.fmt.allocPrint(alloc, "{s}/refract", .{xdg})
    else if (builtin.os.tag == .macos)
        try std.fmt.allocPrint(alloc, "{s}/Library/Application Support/refract", .{home})
    else
        try std.fmt.allocPrint(alloc, "{s}/.local/share/refract", .{home});
    defer alloc.free(data_dir);

    std.fs.makeDirAbsolute(data_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    return std.fmt.allocPrint(alloc, "{s}/{x}.db", .{ data_dir, hash });
}

fn uriToPath(alloc: std.mem.Allocator, uri: []const u8) ![]u8 {
    const rest = if (std.mem.startsWith(u8, uri, "file://")) uri[7..] else uri;
    var out = std.ArrayList(u8){};
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

fn pathToUri(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
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

fn resolveRequireTarget(alloc: std.mem.Allocator, db: db_mod.Db, source: []const u8, cursor_offset: usize, current_file: []const u8) ?[]u8 {
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

    const trimmed = std.mem.trimLeft(u8, line_src, " \t");
    if (std.mem.startsWith(u8, trimmed, rel_prefix)) {
        is_relative = true;
        rest = std.mem.trimLeft(u8, trimmed[rel_prefix.len..], " \t");
    } else if (std.mem.startsWith(u8, trimmed, req_prefix)) {
        rest = std.mem.trimLeft(u8, trimmed[req_prefix.len..], " \t");
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
            std.fs.accessAbsolute(candidate, .{}) catch return null;
            return alloc.dupe(u8, candidate) catch null;
        }
        const with_rb = std.fmt.allocPrint(alloc, "{s}.rb", .{candidate}) catch return null;
        defer alloc.free(with_rb);
        std.fs.accessAbsolute(with_rb, .{}) catch return null;
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

fn normalizeCRLF(buf: []u8) []u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '\r' and i + 1 < buf.len and buf[i + 1] == '\n') continue;
        buf[w] = buf[i];
        w += 1;
    }
    return buf[0..w];
}

fn isInStringOrComment(source: []const u8, offset: usize) bool {
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

fn writePathAsUri(w: *std.Io.Writer, path: []const u8) !void {
    for (path) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '/' => try w.writeByte(c),
            else => try w.print("%{X:0>2}", .{c}),
        }
    }
}

fn extractParamsObject(params: ?std.json.Value) ?std.json.ObjectMap {
    return switch (params orelse return null) {
        .object => |o| o,
        else => null,
    };
}

fn extractTextDocumentUri(params: ?std.json.Value) ?[]const u8 {
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

fn extractPosition(params: ?std.json.Value) ?struct { line: u32, character: u32 } {
    const obj = extractParamsObject(params) orelse return null;
    const pos = switch (obj.get("position") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const ln = switch (pos.get("line") orelse return null) { .integer => |i| i, else => return null };
    const ch = switch (pos.get("character") orelse return null) { .integer => |i| i, else => return null };
    if (ln < 0 or ch < 0) return null;
    return .{ .line = @intCast(ln), .character = @intCast(ch) };
}

fn matchesCamelInitials(query: []const u8, name: []const u8) bool {
    if (query.len == 0) return true;
    var qi: usize = 0;
    for (name) |c| {
        if (qi >= query.len) break;
        if (std.ascii.toUpper(c) == std.ascii.toUpper(query[qi])) qi += 1;
    }
    return qi == query.len;
}

fn isSubsequence(query: []const u8, name: []const u8) bool {
    if (query.len == 0) return true;
    var qi: usize = 0;
    for (name) |c| {
        if (qi >= query.len) break;
        if (std.ascii.toLower(c) == std.ascii.toLower(query[qi])) qi += 1;
    }
    return qi == query.len;
}

fn buildQueryPattern(alloc: std.mem.Allocator, query: []const u8) ![]u8 {
    if (query.len == 0) return alloc.dupe(u8, "%");
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(alloc);
    try buf.append(alloc, '%');
    for (query) |c| {
        if (c == '%' or c == '_' or c == '\\') try buf.append(alloc, '\\');
        try buf.append(alloc, c);
    }
    try buf.append(alloc, '%');
    return buf.toOwnedSlice(alloc);
}

fn buildPrefixPattern(alloc: std.mem.Allocator, word: []const u8) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(alloc);
    for (word) |c| {
        if (c == '%' or c == '_' or c == '\\') try buf.append(alloc, '\\');
        try buf.append(alloc, c);
    }
    try buf.append(alloc, '%');
    return buf.toOwnedSlice(alloc);
}

fn emptyResult(msg: types.RequestMessage) ?types.ResponseMessage {
    return types.ResponseMessage{ .id = msg.id, .result = null, .@"error" = null };
}

fn posToOffset(source: []const u8, line: u32, character: u32) usize {
    var cur_line: u32 = 0;
    var i: usize = 0;
    while (i < source.len and cur_line < line) : (i += 1) {
        if (source[i] == '\n') cur_line += 1;
    }
    return @min(i + character, source.len);
}

fn utf16ColToUtf8(line_src: []const u8, utf16_col: u32) usize {
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

fn utf8ColToUtf16(line_src: []const u8, utf8_col: usize) u32 {
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

fn convertSemBlobToUtf16(blob: []const u8, source: []const u8, alloc: std.mem.Allocator) ![]u8 {
    if (blob.len == 0) return alloc.dupe(u8, &.{});
    const n = blob.len / 20;
    const out = try alloc.alloc(u8, blob.len);
    var prev_utf16_col: u32 = 0;
    var abs_line: u32 = 0;
    var abs_col: u32 = 0;
    for (0..n) |i| {
        const dl  = std.mem.readInt(u32, blob[i*20..][0..4], .little);
        const dc  = std.mem.readInt(u32, blob[i*20+4..][0..4], .little);
        const lb  = std.mem.readInt(u32, blob[i*20+8..][0..4], .little);
        const tt  = std.mem.readInt(u32, blob[i*20+12..][0..4], .little);
        const tm  = std.mem.readInt(u32, blob[i*20+16..][0..4], .little);
        abs_line += dl;
        abs_col = if (dl == 0) abs_col + dc else dc;
        const ln = getLineSlice(source, abs_line);
        const col16  = utf8ColToUtf16(ln, @min(abs_col, ln.len));
        const end16  = utf8ColToUtf16(ln, @min(abs_col + lb, ln.len));
        const len16  = end16 - col16;
        const odc: u32 = if (dl == 0) col16 - prev_utf16_col else col16;
        prev_utf16_col = col16;
        std.mem.writeInt(u32, out[i*20..][0..4], dl, .little);
        std.mem.writeInt(u32, out[i*20+4..][0..4], odc, .little);
        std.mem.writeInt(u32, out[i*20+8..][0..4], len16, .little);
        std.mem.writeInt(u32, out[i*20+12..][0..4], tt, .little);
        std.mem.writeInt(u32, out[i*20+16..][0..4], tm, .little);
    }
    return out;
}

fn getLineSlice(source: []const u8, line_0: u32) []const u8 {
    var l: u32 = 0;
    var i: usize = 0;
    while (i < source.len and l < line_0) : (i += 1) {
        if (source[i] == '\n') l += 1;
    }
    const start = i;
    while (i < source.len and source[i] != '\n') : (i += 1) {}
    return source[start..i];
}

fn frcGet(frc: *std.StringHashMapUnmanaged([]const u8), alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    if (frc.get(path)) |src| return src;
    const src = std.fs.cwd().readFileAlloc(alloc, path, 1 << 24) catch return null;
    const owned_path = alloc.dupe(u8, path) catch { alloc.free(src); return null; };
    frc.put(alloc, owned_path, src) catch { alloc.free(owned_path); alloc.free(src); return null; };
    return src;
}

fn extractWord(source: []const u8, offset: usize) []const u8 {
    if (offset >= source.len) return "";
    var start = offset;
    while (start > 0 and isRubyIdent(source[start - 1])) start -= 1;
    var end = offset;
    while (end < source.len and isRubyIdent(source[end])) end += 1;
    return source[start..end];
}

fn extractQualifiedName(source: []const u8, offset: usize) []const u8 {
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

fn isRubyIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '?' or c == '!' or c == '@' or c == '$' or c >= 0x80;
}

fn isValidRubyIdent(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_' and name[0] < 0x80) return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '?' and c != '!' and c < 0x80) return false;
    }
    return true;
}

fn writeEscapedJsonContent(w: *std.Io.Writer, s: []const u8) !void {
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

fn writeEscapedJson(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    try writeEscapedJsonContent(w, s);
    try w.writeByte('"');
}

fn addStdlibCompletions(w: *std.Io.Writer, class_name: []const u8, first_item: *bool, line: u32, character: u32) !void {
    const methods: []const []const u8 = if (std.mem.eql(u8, class_name, "String"))
        &[_][]const u8{ "upcase", "downcase", "strip", "lstrip", "rstrip", "chomp", "chop", "length",
            "size", "empty?", "include?", "split", "gsub", "sub", "reverse", "start_with?", "end_with?",
            "to_i", "to_f", "to_sym", "chars", "bytes", "scan", "lines", "match?", "capitalize",
            "swapcase", "squeeze", "delete", "encode", "tr", "center", "ljust", "rjust", "freeze", "to_s",
            "count", "bytesize", "hex", "oct", "concat", "prepend", "slice", "valid_encoding?" }
    else if (std.mem.eql(u8, class_name, "Integer") or std.mem.eql(u8, class_name, "Numeric"))
        &[_][]const u8{ "to_s", "to_f", "to_i", "abs", "ceil", "floor", "round", "truncate", "times",
            "zero?", "positive?", "negative?", "odd?", "even?", "between?", "digits", "divmod",
            "chr", "next", "succ", "pred", "gcd", "lcm", "upto", "downto", "inspect" }
    else if (std.mem.eql(u8, class_name, "Float"))
        &[_][]const u8{ "to_i", "to_f", "to_s", "ceil", "floor", "round", "truncate", "abs",
            "positive?", "negative?", "zero?", "finite?", "nan?", "infinite?", "inspect" }
    else if (std.mem.eql(u8, class_name, "Array"))
        &[_][]const u8{ "length", "size", "count", "first", "last", "empty?", "include?",
            "push", "pop", "shift", "unshift", "append", "prepend", "flatten", "compact", "uniq",
            "sort", "reverse", "map", "collect", "select", "filter", "reject", "each", "any?",
            "all?", "none?", "one?", "join", "zip", "sample", "shuffle", "rotate", "tally",
            "filter_map", "flat_map", "sum", "to_h", "intersection", "union", "difference",
            "product", "combination", "permutation", "entries" }
    else if (std.mem.eql(u8, class_name, "Hash"))
        &[_][]const u8{ "keys", "values", "each", "map", "select", "filter", "reject", "merge",
            "update", "delete", "fetch", "has_key?", "key?", "include?", "has_value?", "value?",
            "empty?", "size", "count", "any?", "all?", "none?", "invert", "compact", "except",
            "slice", "flat_map", "to_a", "each_with_object", "group_by", "transform_values",
            "transform_keys", "each_key", "each_value", "each_pair", "deep_symbolize_keys",
            "deep_stringify_keys", "with_indifferent_access" }
    else if (std.mem.eql(u8, class_name, "Symbol"))
        &[_][]const u8{ "to_s", "id2name", "to_sym", "inspect", "upcase", "downcase",
            "length", "size", "match?", "empty?", "to_proc" }
    else return;
    for (methods) |m| {
        if (!first_item.*) try w.writeByte(',');
        first_item.* = false;
        try w.writeAll("{\"label\":");
        try writeEscapedJson(w, m);
        try w.print(",\"kind\":3,\"detail\":\"(stdlib)\",\"sortText\":\"1_", .{});
        try writeEscapedJsonContent(w, m);
        try w.writeAll("\",\"filterText\":\"");
        try writeEscapedJsonContent(w, m);
        try w.writeAll("\",\"textEdit\":{\"range\":{\"start\":{\"line\":");
        try w.print("{d}", .{line});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{character});
        try w.writeAll("},\"end\":{\"line\":");
        try w.print("{d}", .{line});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{character});
        try w.writeAll("}},\"newText\":\"");
        try writeEscapedJsonContent(w, m);
        try w.writeAll("\"},\"data\":{\"name\":");
        try writeEscapedJson(w, m);
        try w.writeAll("}}");
    }
}

fn writeInsertTextSnippet(w: *std.Io.Writer, name: []const u8, sig: []const u8) !void {
    try w.writeAll(",\"insertTextFormat\":2,\"insertText\":\"");
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (name[i] == '"' or name[i] == '\\') try w.writeByte('\\');
        try w.writeByte(name[i]);
    }
    try w.writeByte('(');
    var n: u32 = 1;
    var it = std.mem.splitSequence(u8, sig, ", ");
    var first_p = true;
    while (it.next()) |param| {
        if (!first_p) try w.writeAll(", ");
        first_p = false;
        try w.print("${{{}:{s}}}", .{ n, param });
        n += 1;
    }
    try w.writeAll(")$0\"");
}

const init_caps_before_enc =
    \\{"capabilities":{"textDocumentSync":{"change":2,"save":{"includeText":true},"openClose":true},"workspaceSymbolProvider":true,"definitionProvider":true,"implementationProvider":true,"declarationProvider":true,"documentSymbolProvider":true,"hoverProvider":true,"completionProvider":{"triggerCharacters":[".","::", "@","$"],"resolveProvider":true},"referencesProvider":true,"signatureHelpProvider":{"triggerCharacters":["(",","]},"typeDefinitionProvider":true,"inlayHintProvider":true,"semanticTokensProvider":{"legend":{"tokenTypes":["class","namespace","method","parameter","variable","type"],"tokenModifiers":["declaration","readonly","deprecated","static"]},"full":{"delta":true},"range":true},"renameProvider":true,"prepareRenameProvider":true,"documentHighlightProvider":true,"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["quickfix"]},"foldingRangeProvider":true,"documentRangeFormattingProvider":true,"callHierarchyProvider":true,"codeLensProvider":{"resolveProvider":false},"typeHierarchyProvider":true,"selectionRangeProvider":true,"linkedEditingRangeProvider":true,"diagnosticProvider":{"identifier":"refract","interFileDependencies":false,"workspaceDiagnostics":false},"executeCommandProvider":{"commands":["refract.restartIndexer","refract.forceReindex","refract.toggleGemIndex","refract.showReferences","refract.runTest","refract.recheckRubocop"]},"workspace":{"workspaceFolders":{"supported":true,"changeNotifications":true},"didChangeConfiguration":{"dynamicRegistration":true},"fileOperations":{"didCreate":{"filters":[{"scheme":"file","pattern":{"glob":"**/*.{rb,rbs,rbi,erb,rake,gemspec,ru}"}}]},"didDelete":{"filters":[{"scheme":"file","pattern":{"glob":"**/*.{rb,rbs,rbi,erb,rake,gemspec,ru}"}}]},"didChange":{"filters":[{"scheme":"file","pattern":{"glob":"**/*.{rb,rbs,rbi,erb,rake,gemspec,ru}"}}]},"willRename":{"filters":[{"scheme":"file","pattern":{"glob":"**/*.{rb,rbs,rbi,erb,rake,gemspec,ru}"}}]}}},"positionEncoding":
;
const init_caps_after_enc =
    \\},"serverInfo":{"name":"refract","version":"
;
