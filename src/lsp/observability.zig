const std = @import("std");
const db_mod = @import("../db.zig");
const otlp_exporter = @import("otlp_exporter.zig");
const redact = @import("redact.zig");

const FLUSH_INTERVAL_NS: u64 = 5 * std.time.ns_per_s;
const MAX_SAMPLES_PER_METHOD: usize = 4096;
const MAX_AUDIT_ARGS_BYTES: usize = 4096;

pub const Recorder = struct {
    alloc: std.mem.Allocator,
    db: db_mod.Db,
    io: std.Io,
    db_mu: *std.Io.Mutex,
    samples_mu: std.Io.Mutex = std.Io.Mutex.init,
    samples: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u64)) = .{},
    window_start_us: i64 = 0,
    flush_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    flush_thread: ?std.Thread = null,

    pub fn init(alloc: std.mem.Allocator, db: db_mod.Db, io: std.Io, db_mu: *std.Io.Mutex) Recorder {
        return .{
            .alloc = alloc,
            .db = db,
            .io = io,
            .db_mu = db_mu,
            .window_start_us = nowUs(),
        };
    }

    pub fn deinit(self: *Recorder) void {
        self.flush_done.store(true, .seq_cst);
        if (self.flush_thread) |t| t.join();
        self.flush_thread = null;
        self.samples_mu.lockUncancelable(self.io);
        defer self.samples_mu.unlock(self.io);
        var it = self.samples.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(self.alloc);
            self.alloc.free(e.key_ptr.*);
        }
        self.samples.deinit(self.alloc);
    }

    pub fn spawnWorker(self: *Recorder) void {
        if (self.flush_thread != null) return;
        self.flush_thread = std.Thread.spawn(.{}, workerFn, .{self}) catch null;
    }

    pub fn recordRequest(self: *Recorder, method: []const u8, duration_ns: u64) void {
        const us: u64 = duration_ns / std.time.ns_per_us;
        self.samples_mu.lockUncancelable(self.io);
        defer self.samples_mu.unlock(self.io);
        const gop = self.samples.getOrPut(self.alloc, method) catch return;
        if (!gop.found_existing) {
            const owned = self.alloc.dupe(u8, method) catch {
                _ = self.samples.remove(method);
                return;
            };
            gop.key_ptr.* = owned;
            gop.value_ptr.* = .empty;
        }
        if (gop.value_ptr.items.len >= MAX_SAMPLES_PER_METHOD) return;
        gop.value_ptr.append(self.alloc, us) catch {};
    }

    pub fn recordTool(
        self: *Recorder,
        tool_name: []const u8,
        request_id: []const u8,
        args_json: []const u8,
        result_kind: []const u8,
        duration_ns: u64,
    ) void {
        const ts = nowUs();
        const redacted = redact.redactAlloc(self.alloc, args_json) catch null;
        defer if (redacted) |r| self.alloc.free(r);
        const src = if (redacted) |r| r else args_json;
        const args_capped = if (src.len > MAX_AUDIT_ARGS_BYTES) src[0..MAX_AUDIT_ARGS_BYTES] else src;
        const us: i64 = @intCast(duration_ns / std.time.ns_per_us);
        self.db_mu.lockUncancelable(self.io);
        defer self.db_mu.unlock(self.io);
        const stmt = self.db.prepare(
            "INSERT INTO audit_log(ts_us, tool_name, request_id, args_json, result_kind, duration_us) VALUES(?,?,?,?,?,?)",
        ) catch return;
        defer stmt.finalize();
        stmt.bind_int(1, ts);
        stmt.bind_text(2, tool_name);
        stmt.bind_text(3, request_id);
        stmt.bind_text(4, args_capped);
        stmt.bind_text(5, result_kind);
        stmt.bind_int(6, us);
        _ = stmt.step() catch {};
    }

    pub fn flushNow(self: *Recorder) void {
        var drained = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u64)){};
        var window_start: i64 = 0;
        var window_end: i64 = 0;
        {
            self.samples_mu.lockUncancelable(self.io);
            defer self.samples_mu.unlock(self.io);
            window_start = self.window_start_us;
            window_end = nowUs();
            self.window_start_us = window_end;
            const tmp = self.samples;
            self.samples = .{};
            drained = tmp;
        }
        defer {
            var it = drained.iterator();
            while (it.next()) |e| {
                e.value_ptr.deinit(self.alloc);
                self.alloc.free(e.key_ptr.*);
            }
            drained.deinit(self.alloc);
        }

        if (drained.size == 0) return;
        self.db_mu.lockUncancelable(self.io);
        defer self.db_mu.unlock(self.io);
        const stmt = self.db.prepare(
            "INSERT INTO perf_metrics(method, p50_us, p95_us, count, window_start, window_end) VALUES(?,?,?,?,?,?)",
        ) catch return;
        defer stmt.finalize();

        var it = drained.iterator();
        while (it.next()) |e| {
            const samples = e.value_ptr.items;
            if (samples.len == 0) continue;
            std.mem.sort(u64, samples, {}, std.sort.asc(u64));
            const p50 = percentile(samples, 50);
            const p95 = percentile(samples, 95);
            stmt.reset();
            stmt.bind_text(1, e.key_ptr.*);
            stmt.bind_int(2, @intCast(p50));
            stmt.bind_int(3, @intCast(p95));
            stmt.bind_int(4, @intCast(samples.len));
            stmt.bind_int(5, window_start);
            stmt.bind_int(6, window_end);
            _ = stmt.step() catch {};
        }

        const endpoint_cstr = std.c.getenv("OTEL_EXPORTER_OTLP_ENDPOINT") orelse return;
        const endpoint = std.mem.span(endpoint_cstr);
        if (endpoint.len == 0) return;

        const payload = otlp_exporter.buildPayload(self.alloc, self.db, self.db_mu, "<workspace>", 100) catch return;
        defer self.alloc.free(payload);

        otlp_exporter.sendPayloadAsync(self.alloc, endpoint, payload);
    }
};

fn workerFn(r: *Recorder) void {
    const tick_ns: u64 = 250 * std.time.ns_per_ms;
    var elapsed: u64 = 0;
    while (!r.flush_done.load(.acquire)) {
        var ts: std.c.timespec = .{
            .sec = @intCast(tick_ns / std.time.ns_per_s),
            .nsec = @intCast(tick_ns % std.time.ns_per_s),
        };
        _ = std.c.nanosleep(&ts, null);
        elapsed += tick_ns;
        if (elapsed < FLUSH_INTERVAL_NS) continue;
        elapsed = 0;
        r.flushNow();
    }
    r.flushNow();
}

fn nowUs() i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds(), std.time.ns_per_us));
}

fn percentile(sorted: []const u64, p: u32) u64 {
    if (sorted.len == 0) return 0;
    if (sorted.len == 1) return sorted[0];
    const idx_f = (@as(f64, @floatFromInt(p)) / 100.0) * @as(f64, @floatFromInt(sorted.len - 1));
    const idx: usize = @intFromFloat(idx_f);
    return sorted[idx];
}

test "Recorder records and flushes p50/p95" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    var db_mu: std.Io.Mutex = std.Io.Mutex.init;
    var rec = Recorder.init(alloc, db, std.Options.debug_io, &db_mu);
    defer rec.deinit();

    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        rec.recordRequest("textDocument/hover", (i + 1) * std.time.ns_per_us);
    }
    rec.flushNow();

    const sel = try db.prepare("SELECT count, p50_us, p95_us FROM perf_metrics WHERE method=?");
    defer sel.finalize();
    sel.bind_text(1, "textDocument/hover");
    try std.testing.expect(try sel.step());
    try std.testing.expectEqual(@as(i64, 1000), sel.column_int(0));
    const p50 = sel.column_int(1);
    const p95 = sel.column_int(2);
    try std.testing.expect(p50 > 0);
    try std.testing.expect(p95 >= p50);
}

test "Recorder caps audit args_json" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    var db_mu: std.Io.Mutex = std.Io.Mutex.init;
    var rec = Recorder.init(alloc, db, std.Options.debug_io, &db_mu);
    defer rec.deinit();

    var big: [8192]u8 = undefined;
    @memset(&big, 'x');
    rec.recordTool("test_tool", "req-1", &big, "ok", 1234 * std.time.ns_per_us);

    const sel = try db.prepare("SELECT length(args_json), duration_us FROM audit_log WHERE tool_name='test_tool'");
    defer sel.finalize();
    try std.testing.expect(try sel.step());
    try std.testing.expectEqual(@as(i64, 4096), sel.column_int(0));
    try std.testing.expectEqual(@as(i64, 1234), sel.column_int(1));
}

test "observability records and flushes histogram" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    var db_mu: std.Io.Mutex = std.Io.Mutex.init;
    var rec = Recorder.init(alloc, db, std.Options.debug_io, &db_mu);
    defer rec.deinit();

    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        rec.recordRequest("textDocument/completion", (i + 1) * std.time.ns_per_us);
    }
    rec.flushNow();

    const sel = try db.prepare("SELECT count FROM perf_metrics WHERE method=?");
    defer sel.finalize();
    sel.bind_text(1, "textDocument/completion");
    try std.testing.expect(try sel.step());
    try std.testing.expectEqual(@as(i64, 100), sel.column_int(0));
}
