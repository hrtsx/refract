const std = @import("std");
const db_mod = @import("../db.zig");
const sorbet_bridge = @import("sorbet_bridge.zig");

/// Background worker that hydrates `sorbet_results` / `steep_results` from a
/// running bridge.
///
/// Lifecycle:
///   1. Initial pass: phase 1 (workspace/symbol) → phase 2 (per-file hover
///      across typed-true files) → phase 4 (local-var hydration).
///   2. Continuous loop: blocks on a condvar; wakes on `enqueueFile(path)`,
///      debounces 500 ms to coalesce rapid edits, then re-runs phase 2 and
///      phase 4 narrowed to that file.
///
/// Shutdown via `requestStop()` + thread join.
pub const Worker = struct {
    bridge: *sorbet_bridge.Bridge,
    db: db_mod.Db,
    db_mu: *std.Io.Mutex,
    kind: sorbet_bridge.ServerKind,
    alloc: std.mem.Allocator,
    workspace_id: ?i64 = null,
    done: std.atomic.Value(bool),

    pending_mu: std.Io.Mutex = std.Io.Mutex.init,
    pending_cv: std.Io.Condition = std.Io.Condition.init,
    pending: std.StringHashMapUnmanaged(void) = .empty,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Caller-side debounce: how long to wait after the most recent enqueue
    /// before draining. Keeps rapid `didChange` traffic from thrashing the
    /// bridge during typing.
    const DEBOUNCE_NS: u64 = 500 * std.time.ns_per_ms;

    pub fn run(w: *Worker) void {
        defer w.done.store(true, .seq_cst);

        // Sorbet/Steep only answer hovers once their initial typecheck finishes
        // (seconds after `initialized`). Block the scan phases until the checker
        // is warm, else every hover returns empty and we persist zero types.
        waitForSorbetReady(w);

        // Phase 1: workspace/symbol probe. The empty query returns zero rows, but
        // this call is LOAD-BEARING as a readiness barrier — Sorbet only answers a
        // global query after its initial typecheck completes, whereas a hover can
        // return a fast partial answer mid-index. Removing it lets Phase 2 race the
        // typecheck and persist nothing. Keep it even though persistSymbolList is
        // effectively a no-op here.
        const ws_run_id = sorbet_bridge.beginRun(w.db, w.db_mu, w.kind.label()) catch return;
        const ws_params = "{\"query\":\"\"}";
        if (w.bridge.request("workspace/symbol", ws_params)) |resp| {
            defer w.alloc.free(resp);
            _ = persistSymbolList(w.alloc, w.db, w.db_mu, w.kind, w.workspace_id, resp, ws_run_id) catch {};
        } else |err| {
            sorbet_bridge.endRun(w.db, w.db_mu, ws_run_id, 1, @errorName(err)) catch {};
            return;
        }
        sorbet_bridge.endRun(w.db, w.db_mu, ws_run_id, 0, "") catch {};

        // Phase 2: per-file hover scan across all typed-true files.
        const hover_run_id = sorbet_bridge.beginRun(w.db, w.db_mu, "sorbet:hover-scan") catch return;
        var scanned: u32 = 0;
        scanTypedFiles(w, hover_run_id, &scanned) catch {};
        sorbet_bridge.endRun(w.db, w.db_mu, hover_run_id, 0, "") catch {};

        // Phase 4: bulk local-variable type hydration.
        const lv_run_id = sorbet_bridge.beginRun(w.db, w.db_mu, "sorbet:lvar-hydrate") catch return;
        scanLocalVars(w, lv_run_id) catch {};
        sorbet_bridge.endRun(w.db, w.db_mu, lv_run_id, 0, "") catch {};

        // Continuous loop: wait for didSave/didChange-driven enqueues.
        runRescanLoop(w);
    }

    /// Push a path to be re-scanned. Called from didSave/didChange.
    /// Idempotent — duplicate enqueues for the same path coalesce. Non-blocking.
    pub fn enqueueFile(w: *Worker, path: []const u8) void {
        const io = std.Options.debug_io;
        w.pending_mu.lockUncancelable(io);
        defer w.pending_mu.unlock(io);
        const dup = w.alloc.dupe(u8, path) catch return;
        const gop = w.pending.getOrPut(w.alloc, dup) catch {
            w.alloc.free(dup);
            return;
        };
        if (gop.found_existing) {
            w.alloc.free(dup);
        } else {
            gop.key_ptr.* = dup;
        }
        w.pending_cv.signal(io);
    }

    /// Signal the loop to exit. Caller still must `Thread.join()` on the
    /// detached handle (Server keeps it).
    pub fn requestStop(w: *Worker) void {
        w.shutdown.store(true, .seq_cst);
        const io = std.Options.debug_io;
        w.pending_mu.lockUncancelable(io);
        defer w.pending_mu.unlock(io);
        w.pending_cv.signal(io);
    }

    /// Free queue contents. Call after thread joined.
    pub fn deinitQueue(w: *Worker) void {
        var it = w.pending.keyIterator();
        while (it.next()) |k| w.alloc.free(k.*);
        w.pending.deinit(w.alloc);
    }
};

fn runRescanLoop(w: *Worker) void {
    const io = std.Options.debug_io;
    while (!w.shutdown.load(.acquire)) {
        // Drain into a local snapshot; clear the shared map.
        var batch = std.ArrayList([]const u8).empty;
        defer {
            for (batch.items) |p| w.alloc.free(@constCast(p));
            batch.deinit(w.alloc);
        }
        {
            w.pending_mu.lockUncancelable(io);
            defer w.pending_mu.unlock(io);
            while (w.pending.count() == 0 and !w.shutdown.load(.acquire)) {
                w.pending_cv.waitUncancelable(io, &w.pending_mu);
            }
            if (w.shutdown.load(.acquire)) return;
            var it = w.pending.keyIterator();
            while (it.next()) |k| {
                batch.append(w.alloc, k.*) catch continue;
            }
            // Hand ownership of the keys to `batch`; clear without freeing.
            w.pending.clearAndFree(w.alloc);
        }

        // Debounce: sleep so further edits coalesce. Re-check pending after
        // the nap and merge those into this batch before running.
        sleepNs(Worker.DEBOUNCE_NS);
        {
            w.pending_mu.lockUncancelable(io);
            defer w.pending_mu.unlock(io);
            var it = w.pending.keyIterator();
            while (it.next()) |k| {
                batch.append(w.alloc, k.*) catch continue;
            }
            w.pending.clearAndFree(w.alloc);
        }

        const run_id = sorbet_bridge.beginRun(w.db, w.db_mu, "sorbet:rescan-file") catch continue;
        for (batch.items) |path| {
            rescanFile(w, path, run_id) catch {};
        }
        sorbet_bridge.endRun(w.db, w.db_mu, run_id, 0, "") catch {};
    }
}

fn sleepNs(ns: u64) void {
    var ts: std.c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&ts, null);
}

/// Re-run phase 2 (method symbol hovers) + phase 4 (local-var hovers) for
/// a single file. Cheap-skips when the file is no longer typed-true or
/// when its row vanished from `files`.
fn rescanFile(w: *Worker, abs_path: []const u8, run_id: i64) !void {
    if (!fileIsTyped(w.alloc, abs_path)) return;

    // Resolve file_id.
    const file_id = blk: {
        w.db_mu.lockUncancelable(std.Options.debug_io);
        defer w.db_mu.unlock(std.Options.debug_io);
        const stmt = try w.db.prepare("SELECT id FROM files WHERE path = ?");
        defer stmt.finalize();
        stmt.bind_text(1, abs_path);
        if (!(try stmt.step())) return;
        break :blk stmt.column_int(0);
    };

    // Phase 2 narrow: re-hover all method-like symbols.
    const symbols = readMethodSymbols(w, file_id) catch &[_]SymbolPos{};
    defer {
        for (symbols) |s| w.alloc.free(s.name);
        w.alloc.free(symbols);
    }
    for (symbols, 0..) |sym, idx| {
        if (idx >= MAX_HOVERS_PER_FILE) break;
        queryHoverAndPersist(w, abs_path, sym, run_id) catch continue;
    }

    // Phase 4 narrow: re-hover all local_vars in this file (always, so edits
    // that change a var's type are picked up — not gated on `type_hint IS NULL`).
    var rows = std.ArrayList(LvarRow).empty;
    defer {
        for (rows.items) |r| {
            w.alloc.free(r.name);
            w.alloc.free(r.file_path);
        }
        rows.deinit(w.alloc);
    }
    {
        w.db_mu.lockUncancelable(std.Options.debug_io);
        defer w.db_mu.unlock(std.Options.debug_io);
        const stmt = try w.db.prepare(
            "SELECT id, name, line, col FROM local_vars WHERE file_id = ? LIMIT 500",
        );
        defer stmt.finalize();
        stmt.bind_int(1, file_id);
        while (try stmt.step()) {
            const name = try w.alloc.dupe(u8, stmt.column_text(1));
            const path = try w.alloc.dupe(u8, abs_path);
            try rows.append(w.alloc, .{
                .id = stmt.column_int(0),
                .name = name,
                .line = stmt.column_int(2),
                .col = stmt.column_int(3),
                .file_path = path,
            });
        }
    }
    for (rows.items) |row| {
        hydrateLocalVar(w, row) catch continue;
    }
}

fn hydrateLocalVar(w: *Worker, row: LvarRow) !void {
    const params = try std.fmt.allocPrint(
        w.alloc,
        "{{\"textDocument\":{{\"uri\":\"file://{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ row.file_path, row.line - 1, row.col },
    );
    defer w.alloc.free(params);

    const resp = w.bridge.request("textDocument/hover", params) catch return;
    defer w.alloc.free(resp);

    const type_str_opt = extractHoverType(w.alloc, resp) catch null;
    defer if (type_str_opt) |t| w.alloc.free(t);
    if (type_str_opt == null or type_str_opt.?.len == 0) return;
    const stripped = stripVarPrefix(type_str_opt.?, row.name);

    w.db_mu.lockUncancelable(std.Options.debug_io);
    defer w.db_mu.unlock(std.Options.debug_io);
    const upd = w.db.prepare(
        "UPDATE local_vars SET type_hint = ?, confidence = 90 WHERE id = ?",
    ) catch return;
    defer upd.finalize();
    upd.bind_text(1, stripped);
    upd.bind_int(2, row.id);
    _ = upd.step() catch {};
}

const MAX_LVARS_PER_RUN: u32 = 4000;

const LvarRow = struct {
    id: i64,
    name: []u8,
    line: i64,
    col: i64,
    file_path: []u8,
};

/// Bulk-hydrate `local_vars.type_hint` from Sorbet/Steep hover responses.
/// One pass: select up to `MAX_LVARS_PER_RUN` unhinted rows in typed files,
/// query bridge per row, persist via UPDATE.
fn scanLocalVars(w: *Worker, run_id: i64) !void {
    _ = run_id;
    var rows = std.ArrayList(LvarRow).empty;
    defer {
        for (rows.items) |r| {
            w.alloc.free(r.name);
            w.alloc.free(r.file_path);
        }
        rows.deinit(w.alloc);
    }
    {
        w.db_mu.lockUncancelable(std.Options.debug_io);
        defer w.db_mu.unlock(std.Options.debug_io);
        const stmt = try w.db.prepare(
            \\SELECT lv.id, lv.name, lv.line, lv.col, f.path
            \\FROM local_vars lv
            \\JOIN files f ON f.id = lv.file_id
            \\WHERE lv.type_hint IS NULL
            \\  AND f.path LIKE '%.rb'
            \\  AND f.is_gem = 0
            \\LIMIT ?
        );
        defer stmt.finalize();
        stmt.bind_int(1, MAX_LVARS_PER_RUN);
        while (try stmt.step()) {
            const name = try w.alloc.dupe(u8, stmt.column_text(1));
            const path = try w.alloc.dupe(u8, stmt.column_text(4));
            try rows.append(w.alloc, .{
                .id = stmt.column_int(0),
                .name = name,
                .line = stmt.column_int(2),
                .col = stmt.column_int(3),
                .file_path = path,
            });
        }
    }

    // Group by file_path so we run `fileIsTyped` once per file.
    var typed_cache = std.StringHashMapUnmanaged(bool){};
    defer typed_cache.deinit(w.alloc);

    for (rows.items) |row| {
        const gop = try typed_cache.getOrPut(w.alloc, row.file_path);
        if (!gop.found_existing) {
            gop.value_ptr.* = fileIsTyped(w.alloc, row.file_path);
        }
        if (!gop.value_ptr.*) continue;

        const params = std.fmt.allocPrint(
            w.alloc,
            "{{\"textDocument\":{{\"uri\":\"file://{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
            .{ row.file_path, row.line - 1, row.col },
        ) catch continue;
        defer w.alloc.free(params);

        const resp = w.bridge.request("textDocument/hover", params) catch continue;
        defer w.alloc.free(resp);

        const type_str_opt = extractHoverType(w.alloc, resp) catch null;
        defer if (type_str_opt) |t| w.alloc.free(t);
        if (type_str_opt == null or type_str_opt.?.len == 0) continue;

        // The hover response is markdown with a Ruby fenced block; the first
        // non-empty line of that block is typically the variable's type sig
        // ("x: Integer" or just "Integer"). Take the bare type by trimming
        // any leading "<name>: " prefix.
        const stripped = stripVarPrefix(type_str_opt.?, row.name);

        w.db_mu.lockUncancelable(std.Options.debug_io);
        defer w.db_mu.unlock(std.Options.debug_io);
        const upd = w.db.prepare(
            "UPDATE local_vars SET type_hint = ?, confidence = 90 WHERE id = ?",
        ) catch continue;
        defer upd.finalize();
        upd.bind_text(1, stripped);
        upd.bind_int(2, row.id);
        _ = upd.step() catch {};
    }
}

/// Sorbet hover output for a local var typically looks like:
///   "x: Integer"  or  "Integer"  or  "x = Integer"
/// Trim the leading "name: " / "name = " prefix when present so what we
/// store in `local_vars.type_hint` is the bare type.
fn stripVarPrefix(text: []const u8, var_name: []const u8) []const u8 {
    const first_line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const first_line = std.mem.trim(u8, text[0..first_line_end], " \t");
    if (first_line.len <= var_name.len) return first_line;
    if (!std.mem.startsWith(u8, first_line, var_name)) return first_line;
    var i: usize = var_name.len;
    while (i < first_line.len and (first_line[i] == ' ' or first_line[i] == '\t')) : (i += 1) {}
    if (i >= first_line.len) return first_line;
    if (first_line[i] != ':' and first_line[i] != '=') return first_line;
    i += 1;
    while (i < first_line.len and (first_line[i] == ' ' or first_line[i] == '\t')) : (i += 1) {}
    return first_line[i..];
}

const MAX_TYPED_FILES_PER_RUN: u32 = 2000;
const MAX_HEADER_BYTES: usize = 2048; // first ~50 lines is enough to find "# typed:"
const MAX_HOVERS_PER_FILE: u32 = 96; // method/class symbols per file

/// Iterate workspace `.rb` files in DB, find typed-true ones, send hover
/// for each indexed method symbol, persist results.
/// Poll one method-def position until a hover returns a type (the checker has
/// finished its initial typecheck) or we give up after ~18s. Best-effort: on
/// timeout the scan proceeds anyway. No usable symbol → returns immediately.
fn waitForSorbetReady(w: *Worker) void {
    var probe_path: ?[]u8 = null;
    var probe_line: i64 = 0;
    var probe_col: i64 = 0;
    {
        w.db_mu.lockUncancelable(std.Options.debug_io);
        defer w.db_mu.unlock(std.Options.debug_io);
        const stmt = w.db.prepare(
            "SELECT f.path, s.line, s.col FROM symbols s JOIN files f ON s.file_id=f.id " ++
                "WHERE f.path LIKE '%.rb' AND f.is_gem=0 AND s.kind='def' LIMIT 1",
        ) catch return;
        defer stmt.finalize();
        if (stmt.step() catch false) {
            probe_path = w.alloc.dupe(u8, stmt.column_text(0)) catch null;
            probe_line = stmt.column_int(1);
            probe_col = stmt.column_int(2);
        }
    }
    const path = probe_path orelse return;
    defer w.alloc.free(path);

    var i: u32 = 0;
    while (i < 400) : (i += 1) {
        const params = std.fmt.allocPrint(
            w.alloc,
            "{{\"textDocument\":{{\"uri\":\"file://{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
            .{ path, probe_line - 1, probe_col },
        ) catch return;
        defer w.alloc.free(params);
        if (w.bridge.request("textDocument/hover", params)) |resp| {
            defer w.alloc.free(resp);
            const t = extractHoverType(w.alloc, resp) catch null;
            defer if (t) |tt| w.alloc.free(tt);
            if (t != null and t.?.len > 0) return;
        } else |_| {}
        sleepNs(750 * std.time.ns_per_ms);
    }
}

fn scanTypedFiles(w: *Worker, run_id: i64, scanned: *u32) !void {
    var paths = std.ArrayList(struct { id: i64, path: []u8 }).empty;
    defer {
        for (paths.items) |p| w.alloc.free(p.path);
        paths.deinit(w.alloc);
    }
    {
        w.db_mu.lockUncancelable(std.Options.debug_io);
        defer w.db_mu.unlock(std.Options.debug_io);
        const stmt = try w.db.prepare("SELECT id, path FROM files WHERE path LIKE '%.rb' AND is_gem = 0 LIMIT ?");
        defer stmt.finalize();
        stmt.bind_int(1, MAX_TYPED_FILES_PER_RUN);
        while (try stmt.step()) {
            const path_dup = try w.alloc.dupe(u8, stmt.column_text(1));
            try paths.append(w.alloc, .{ .id = stmt.column_int(0), .path = path_dup });
        }
    }

    for (paths.items) |entry| {
        if (!fileIsTyped(w.alloc, entry.path)) continue;
        scanned.* += 1;
        const symbols = readMethodSymbols(w, entry.id) catch continue;
        defer {
            for (symbols) |s| w.alloc.free(s.name);
            w.alloc.free(symbols);
        }
        for (symbols, 0..) |sym, idx| {
            if (idx >= MAX_HOVERS_PER_FILE) break;
            queryHoverAndPersist(w, entry.path, sym, run_id) catch continue;
        }
    }
}

const SymbolPos = struct {
    name: []u8,
    line: i64,
    col: i64,
};

fn readMethodSymbols(w: *Worker, file_id: i64) ![]SymbolPos {
    var out = std.ArrayList(SymbolPos).empty;
    errdefer {
        for (out.items) |s| w.alloc.free(s.name);
        out.deinit(w.alloc);
    }
    w.db_mu.lockUncancelable(std.Options.debug_io);
    defer w.db_mu.unlock(std.Options.debug_io);
    const stmt = try w.db.prepare(
        "SELECT name, line, col FROM symbols WHERE file_id = ? AND kind IN ('def','classdef','class','module') ORDER BY line LIMIT ?",
    );
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_int(2, @intCast(MAX_HOVERS_PER_FILE));
    while (try stmt.step()) {
        const name = try w.alloc.dupe(u8, stmt.column_text(0));
        try out.append(w.alloc, .{ .name = name, .line = stmt.column_int(1), .col = stmt.column_int(2) });
    }
    return try out.toOwnedSlice(w.alloc);
}

/// Returns true when the first ~2 KB of `path` contains a Sorbet sigil
/// `# typed: true|strict|strong`. `false`/`ignore` files are skipped.
fn fileIsTyped(alloc: std.mem.Allocator, path: []const u8) bool {
    var f = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return false;
    defer f.close(std.Options.debug_io);
    var buf: [MAX_HEADER_BYTES]u8 = undefined;
    var fr = f.readerStreaming(std.Options.debug_io, &buf);
    var head: [MAX_HEADER_BYTES]u8 = undefined;
    var got: usize = 0;
    while (got < head.len) {
        const n = fr.interface.readSliceShort(head[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    _ = alloc;
    return scanForTypedDirective(head[0..got]);
}

/// Scan the given header bytes for `# typed: true|strict|strong`. Tolerant
/// of leading shebang, magic comments, and whitespace. Returns true only
/// for accept-listed sigils.
pub fn scanForTypedDirective(header: []const u8) bool {
    var it = std.mem.splitScalar(u8, header, '\n');
    var lines_seen: u8 = 0;
    while (it.next()) |line| : (lines_seen += 1) {
        if (lines_seen > 50) break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] != '#') continue;
        const after_hash = std.mem.trim(u8, trimmed[1..], " \t");
        if (!std.mem.startsWith(u8, after_hash, "typed:")) continue;
        const rhs = std.mem.trim(u8, after_hash["typed:".len..], " \t");
        if (std.mem.eql(u8, rhs, "true")) return true;
        if (std.mem.eql(u8, rhs, "strict")) return true;
        if (std.mem.eql(u8, rhs, "strong")) return true;
        return false; // false / ignore — explicit opt-out
    }
    return false;
}

fn queryHoverAndPersist(w: *Worker, abs_path: []const u8, sym: SymbolPos, run_id: i64) !void {
    const params = try std.fmt.allocPrint(
        w.alloc,
        "{{\"textDocument\":{{\"uri\":\"file://{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ abs_path, sym.line - 1, sym.col },
    );
    defer w.alloc.free(params);
    const resp = w.bridge.request("textDocument/hover", params) catch return;
    defer w.alloc.free(resp);

    const type_str = extractHoverType(w.alloc, resp) catch return;
    defer if (type_str) |t| w.alloc.free(t);
    if (type_str == null or type_str.?.len == 0) return;

    const source_label = switch (w.kind) {
        .sorbet => "sorbet:hover",
        .steep => "steep:hover",
    };
    sorbet_bridge.persistResult(
        w.db,
        w.db_mu,
        w.kind,
        w.workspace_id,
        sym.name,
        "method",
        type_str.?,
        source_label,
        90,
        run_id,
    ) catch {};
}

/// Extract the first ` ```ruby ... ``` ` fenced block from an LSP hover
/// response's `result.contents.value`. Falls back to the raw `result.contents`
/// string. Returns owned bytes the caller must free, or null.
pub fn extractHoverType(alloc: std.mem.Allocator, response_bytes: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response_bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const result_v = parsed.value.object.get("result") orelse return null;
    if (result_v != .object) return null;
    const contents_v = result_v.object.get("contents") orelse return null;
    const text: []const u8 = switch (contents_v) {
        .string => |s| s,
        .object => |o| blk: {
            const v = o.get("value") orelse break :blk "";
            if (v != .string) break :blk "";
            break :blk v.string;
        },
        else => "",
    };
    if (text.len == 0) return null;

    const fence_start = std.mem.indexOf(u8, text, "```ruby") orelse return try alloc.dupe(u8, text);
    const after_fence = fence_start + "```ruby".len;
    const body_start = if (after_fence < text.len and text[after_fence] == '\n') after_fence + 1 else after_fence;
    const fence_end_rel = std.mem.indexOf(u8, text[body_start..], "```") orelse return try alloc.dupe(u8, text[body_start..]);
    const trimmed = std.mem.trim(u8, text[body_start .. body_start + fence_end_rel], " \n\r\t");
    if (trimmed.len == 0) return null;
    return try alloc.dupe(u8, trimmed);
}

/// Parse a Sorbet/Steep `workspace/symbol` response and persist each
/// SymbolInformation into the appropriate results table.
/// Response shape: `{"id":N,"jsonrpc":"2.0","result":[{name,kind,location:{uri,range}},...]}`.
pub fn persistSymbolList(
    alloc: std.mem.Allocator,
    db: db_mod.Db,
    db_mu: *std.Io.Mutex,
    kind: sorbet_bridge.ServerKind,
    workspace_id: ?i64,
    response_bytes: []const u8,
    run_id: i64,
) !u32 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return 0;
    const result_v = parsed.value.object.get("result") orelse return 0;
    if (result_v != .array) return 0;

    var written: u32 = 0;
    for (result_v.array.items) |sym| {
        if (sym != .object) continue;
        const name_v = sym.object.get("name") orelse continue;
        if (name_v != .string) continue;
        const lsp_kind_v = sym.object.get("kind");
        const decl_kind: []const u8 = blk: {
            if (lsp_kind_v) |k| if (k == .integer) break :blk lspSymbolKindToString(k.integer);
            break :blk "symbol";
        };
        const source_label = switch (kind) {
            .sorbet => "sorbet:workspace/symbol",
            .steep => "steep:workspace/symbol",
        };
        const type_str = try std.fmt.allocPrint(alloc, "Class<{s}>", .{name_v.string});
        defer alloc.free(type_str);

        sorbet_bridge.persistResult(
            db,
            db_mu,
            kind,
            workspace_id,
            name_v.string,
            decl_kind,
            type_str,
            source_label,
            100,
            run_id,
        ) catch continue;
        written += 1;
    }
    return written;
}

/// LSP SymbolKind → refract decl_kind string.
fn lspSymbolKindToString(k: i64) []const u8 {
    return switch (k) {
        2 => "module",
        4 => "package",
        5 => "class",
        6 => "method",
        7 => "property",
        8 => "field",
        9 => "constructor",
        10 => "enum",
        11 => "interface",
        12 => "function",
        13 => "variable",
        14 => "constant",
        else => "symbol",
    };
}

test "persistSymbolList writes class rows from workspace/symbol response" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    var mu: std.Io.Mutex = std.Io.Mutex.init;

    const run_id = try sorbet_bridge.beginRun(db, &mu, "sorbet");
    const resp =
        \\{"jsonrpc":"2.0","id":1,"result":[
        \\  {"name":"Foo","kind":5,"location":{"uri":"file:///x.rb","range":{}}},
        \\  {"name":"Bar","kind":2,"location":{"uri":"file:///y.rb","range":{}}},
        \\  {"name":"baz","kind":6,"location":{"uri":"file:///z.rb","range":{}}}
        \\]}
    ;
    const wrote = try persistSymbolList(alloc, db, &mu, .sorbet, null, resp, run_id);
    try std.testing.expectEqual(@as(u32, 3), wrote);

    const sel = try db.prepare("SELECT fqn, kind FROM sorbet_results ORDER BY fqn");
    defer sel.finalize();
    try std.testing.expect(try sel.step());
    try std.testing.expectEqualStrings("Bar", sel.column_text(0));
    try std.testing.expectEqualStrings("module", sel.column_text(1));
    try std.testing.expect(try sel.step());
    try std.testing.expectEqualStrings("Foo", sel.column_text(0));
    try std.testing.expectEqualStrings("class", sel.column_text(1));
    try std.testing.expect(try sel.step());
    try std.testing.expectEqualStrings("baz", sel.column_text(0));
    try std.testing.expectEqualStrings("method", sel.column_text(1));
}

test "scanForTypedDirective accepts true|strict|strong, rejects false" {
    try std.testing.expect(scanForTypedDirective("# typed: true\nclass Foo\nend\n"));
    try std.testing.expect(scanForTypedDirective("# frozen_string_literal: true\n# typed: strict\n"));
    try std.testing.expect(scanForTypedDirective("#typed:strong\n"));
    try std.testing.expect(!scanForTypedDirective("# typed: false\n"));
    try std.testing.expect(!scanForTypedDirective("# typed: ignore\n"));
    try std.testing.expect(!scanForTypedDirective("class Foo\nend\n"));
}

test "extractHoverType pulls fenced ruby block" {
    const alloc = std.testing.allocator;
    const resp =
        \\{"id":1,"jsonrpc":"2.0","result":{"contents":{"kind":"markdown","value":"```ruby\nsig { params(x: Integer).returns(String) }\ndef compute(x); end\n```\n\nDoc text."}}}
    ;
    const got = (try extractHoverType(alloc, resp)) orelse return error.NoText;
    defer alloc.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "params(x: Integer)") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "Doc text") == null);
}

test "extractHoverType falls back to raw contents string" {
    const alloc = std.testing.allocator;
    const resp =
        \\{"result":{"contents":"plain string"}}
    ;
    const got = (try extractHoverType(alloc, resp)) orelse return error.NoText;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("plain string", got);
}

test "stripVarPrefix trims `name: ` from sorbet hover text" {
    try std.testing.expectEqualStrings("Integer", stripVarPrefix("x: Integer", "x"));
    try std.testing.expectEqualStrings("String", stripVarPrefix("user_name = String", "user_name"));
    try std.testing.expectEqualStrings("Array[User]", stripVarPrefix("xs: Array[User]\nDoc text", "xs"));
}

test "stripVarPrefix returns first line when no name match" {
    try std.testing.expectEqualStrings("Integer", stripVarPrefix("Integer", "x"));
    try std.testing.expectEqualStrings("Foo", stripVarPrefix("Foo\nBar", "x"));
}

test "extractHoverType returns null for empty / missing result" {
    const alloc = std.testing.allocator;
    try std.testing.expect((try extractHoverType(alloc, "{\"jsonrpc\":\"2.0\"}")) == null);
    try std.testing.expect((try extractHoverType(alloc, "{\"result\":null}")) == null);
}

test "persistSymbolList tolerates missing result key" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    var mu: std.Io.Mutex = std.Io.Mutex.init;

    const run_id = try sorbet_bridge.beginRun(db, &mu, "steep");
    const resp =
        \\{"jsonrpc":"2.0","id":1}
    ;
    const wrote = try persistSymbolList(alloc, db, &mu, .steep, null, resp, run_id);
    try std.testing.expectEqual(@as(u32, 0), wrote);
}
