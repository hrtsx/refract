const std = @import("std");
const db_mod = @import("../db.zig");

/// OTLP HTTP exporter for `perf_metrics` rows. Off by default; opt-in via
/// environment variable: `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.local:4318`
///
/// Wire format: POST to `<endpoint>/v1/metrics` with OTLP/JSON `MetricsData` payload.
/// Failures (no endpoint, unreachable, non-2xx) are silent no-ops; never blocks the LSP thread.
pub const Config = struct {
    enabled: bool = false,
    endpoint: []u8,
    workspace_label: []u8,

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        alloc.free(self.endpoint);
        alloc.free(self.workspace_label);
    }
};

pub fn parseConfig(alloc: std.mem.Allocator, toml_bytes: []const u8) !Config {
    var cfg = Config{
        .enabled = false,
        .endpoint = try alloc.dupe(u8, ""),
        .workspace_label = try alloc.dupe(u8, "<workspace>"),
    };
    errdefer cfg.deinit(alloc);

    var in_telemetry = false;
    var it = std.mem.splitScalar(u8, toml_bytes, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        if (t[0] == '[') {
            in_telemetry = std.mem.eql(u8, t, "[telemetry]");
            continue;
        }
        if (!in_telemetry) continue;
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        const key = std.mem.trim(u8, t[0..eq], " \t");
        const raw = std.mem.trim(u8, t[eq + 1 ..], " \t");
        const val = std.mem.trim(u8, raw, "\"'");
        if (std.mem.eql(u8, key, "otlp_endpoint")) {
            alloc.free(cfg.endpoint);
            cfg.endpoint = try alloc.dupe(u8, val);
            cfg.enabled = val.len > 0;
        } else if (std.mem.eql(u8, key, "workspace_label")) {
            alloc.free(cfg.workspace_label);
            cfg.workspace_label = try alloc.dupe(u8, val);
        }
    }
    return cfg;
}

/// Build OTLP/JSON payload for the most-recent `perf_metrics` rows.
/// Returns owned bytes the caller must free.
pub fn buildPayload(
    alloc: std.mem.Allocator,
    db: db_mod.Db,
    db_mu: *std.Io.Mutex,
    workspace_label: []const u8,
    max_rows: u32,
) ![]u8 {
    db_mu.lockUncancelable(std.Options.debug_io);
    defer db_mu.unlock(std.Options.debug_io);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    {
        const head = try std.fmt.allocPrint(alloc,
            "{{\"resourceMetrics\":[{{\"resource\":{{\"attributes\":[{{\"key\":\"service.name\",\"value\":{{\"stringValue\":\"refract\"}}}},{{\"key\":\"workspace.label\",\"value\":{{\"stringValue\":\"{s}\"}}}}]}},\"scopeMetrics\":[{{\"scope\":{{\"name\":\"refract.lsp\"}},\"metrics\":[",
            .{workspace_label},
        );
        defer alloc.free(head);
        try out.appendSlice(alloc, head);
    }

    const stmt = try db.prepare(
        "SELECT method, p50_us, p95_us, count, window_start, window_end FROM perf_metrics ORDER BY window_end DESC LIMIT ?",
    );
    defer stmt.finalize();
    stmt.bind_int(1, @intCast(max_rows));

    var first = true;
    while (try stmt.step()) {
        const method = stmt.column_text(0);
        const p50 = stmt.column_int(1);
        const p95 = stmt.column_int(2);
        const count = stmt.column_int(3);
        const wstart = stmt.column_int(4);
        const wend = stmt.column_int(5);

        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        const wstart_ns: i64 = wstart * std.time.ns_per_us;
        const wend_ns: i64 = wend * std.time.ns_per_us;
        const m = try std.fmt.allocPrint(alloc,
            "{{\"name\":\"refract.lsp.duration_us.p50\",\"unit\":\"us\",\"gauge\":{{\"dataPoints\":[{{\"asInt\":{d},\"timeUnixNano\":\"{d}\",\"startTimeUnixNano\":\"{d}\",\"attributes\":[{{\"key\":\"method\",\"value\":{{\"stringValue\":\"{s}\"}}}}]}}]}}}},{{\"name\":\"refract.lsp.duration_us.p95\",\"unit\":\"us\",\"gauge\":{{\"dataPoints\":[{{\"asInt\":{d},\"timeUnixNano\":\"{d}\",\"startTimeUnixNano\":\"{d}\",\"attributes\":[{{\"key\":\"method\",\"value\":{{\"stringValue\":\"{s}\"}}}}]}}]}}}},{{\"name\":\"refract.lsp.requests\",\"unit\":\"1\",\"sum\":{{\"isMonotonic\":true,\"aggregationTemporality\":2,\"dataPoints\":[{{\"asInt\":{d},\"timeUnixNano\":\"{d}\",\"startTimeUnixNano\":\"{d}\",\"attributes\":[{{\"key\":\"method\",\"value\":{{\"stringValue\":\"{s}\"}}}}]}}]}}}}",
            .{ p50, wend_ns, wstart_ns, method, p95, wend_ns, wstart_ns, method, count, wend_ns, wstart_ns, method },
        );
        defer alloc.free(m);
        try out.appendSlice(alloc, m);
    }

    try out.appendSlice(alloc, "]}]}]}");
    return try out.toOwnedSlice(alloc);
}

test "parseConfig honors [telemetry] section" {
    const alloc = std.testing.allocator;
    const toml =
        \\# global comment
        \\[other]
        \\otlp_endpoint = "ignored"
        \\
        \\[telemetry]
        \\otlp_endpoint = "http://otel.local:4318/v1/metrics"
        \\workspace_label = "acme"
    ;
    var cfg = try parseConfig(alloc, toml);
    defer cfg.deinit(alloc);
    try std.testing.expect(cfg.enabled);
    try std.testing.expectEqualStrings("http://otel.local:4318/v1/metrics", cfg.endpoint);
    try std.testing.expectEqualStrings("acme", cfg.workspace_label);
}

test "parseConfig disabled when telemetry block absent" {
    const alloc = std.testing.allocator;
    var cfg = try parseConfig(alloc, "[other]\nfoo = 1\n");
    defer cfg.deinit(alloc);
    try std.testing.expect(!cfg.enabled);
}

/// Fire-and-forget HTTP POST of payload to OTLP endpoint.
/// Spawns background thread; never blocks or crashes the LSP main thread.
/// If endpoint is unset or request fails, returns silently.
var in_flight = std.atomic.Value(u32).init(0);
const MAX_IN_FLIGHT: u32 = 4;

pub fn sendPayloadAsync(
    alloc: std.mem.Allocator,
    endpoint: []const u8,
    payload: []const u8,
) void {
    if (endpoint.len == 0) return;
    const cur = in_flight.load(.acquire);
    if (cur >= MAX_IN_FLIGHT) return;
    _ = in_flight.fetchAdd(1, .acq_rel);

    const ctx = alloc.create(SendCtx) catch {
        _ = in_flight.fetchSub(1, .acq_rel);
        return;
    };
    ctx.* = .{
        .alloc = alloc,
        .endpoint = alloc.dupe(u8, endpoint) catch {
            alloc.destroy(ctx);
            _ = in_flight.fetchSub(1, .acq_rel);
            return;
        },
        .payload = alloc.dupe(u8, payload) catch {
            alloc.free(ctx.endpoint);
            alloc.destroy(ctx);
            _ = in_flight.fetchSub(1, .acq_rel);
            return;
        },
    };
    const t = std.Thread.spawn(.{}, sendWorker, .{ctx}) catch {
        alloc.free(ctx.endpoint);
        alloc.free(ctx.payload);
        alloc.destroy(ctx);
        _ = in_flight.fetchSub(1, .acq_rel);
        return;
    };
    t.detach();
}

const SendCtx = struct {
    alloc: std.mem.Allocator,
    endpoint: []u8,
    payload: []u8,
};

fn sendWorker(ctx: *SendCtx) void {
    defer {
        ctx.alloc.free(ctx.endpoint);
        ctx.alloc.free(ctx.payload);
        ctx.alloc.destroy(ctx);
        _ = in_flight.fetchSub(1, .acq_rel);
    }
    doHttpSend(ctx.alloc, ctx.endpoint, ctx.payload) catch {};
}

fn doHttpSend(
    alloc: std.mem.Allocator,
    endpoint: []const u8,
    payload: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const url = try buildUrl(aalloc, endpoint);

    const io = std.Options.debug_io;
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    if (std.mem.startsWith(u8, endpoint, "https://")) {
        const now_ts = std.Io.Timestamp.now(io, .real);
        client.ca_bundle.rescan(alloc, io, now_ts) catch return;
    }

    var resp = std.Io.Writer.Allocating.init(alloc);
    defer resp.deinit();

    _ = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .response_writer = &resp.writer,
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
    }) catch return;
}

fn buildUrl(alloc: std.mem.Allocator, endpoint: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, endpoint);
    if (!std.mem.endsWith(u8, endpoint, "/")) {
        try buf.append(alloc, '/');
    }
    try buf.appendSlice(alloc, "v1/metrics");
    return try buf.toOwnedSlice(alloc);
}

test "otlp_exporter no-ops with unset endpoint" {
    const alloc = std.testing.allocator;
    sendPayloadAsync(alloc, "", "{}");
}

test "buildPayload emits 3 metrics per row" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    var mu: std.Io.Mutex = std.Io.Mutex.init;

    try db.exec("INSERT INTO perf_metrics(method, p50_us, p95_us, count, window_start, window_end) VALUES('textDocument/hover', 200, 800, 100, 1000, 60000)");

    const payload = try buildPayload(alloc, db, &mu, "<workspace>", 10);
    defer alloc.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "refract.lsp.duration_us.p50") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "refract.lsp.duration_us.p95") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "refract.lsp.requests") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "textDocument/hover") != null);
}
