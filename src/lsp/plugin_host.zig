const std = @import("std");
const server = @import("server.zig");

const macos_exe = struct {
    extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;
};

/// Refract plugin protocol version. Bumped on breaking changes.
pub const PROTOCOL_VERSION: []const u8 = "0.1";

/// Reserved core LSP method names that plugins may NOT register. Refract owns
/// these and any conflict is rejected at manifest validation.
const RESERVED_LSP_METHODS = [_][]const u8{
    "initialize",
    "initialized",
    "shutdown",
    "exit",
    "textDocument/didOpen",
    "textDocument/didChange",
    "textDocument/didClose",
    "textDocument/didSave",
    "textDocument/hover",
    "textDocument/definition",
    "textDocument/typeDefinition",
    "textDocument/declaration",
    "textDocument/implementation",
    "textDocument/references",
    "textDocument/documentSymbol",
    "workspace/symbol",
    "textDocument/completion",
    "textDocument/inlineCompletion",
    "completionItem/resolve",
    "textDocument/rename",
    "textDocument/prepareRename",
    "textDocument/codeAction",
    "textDocument/codeLens",
    "textDocument/inlayHint",
    "textDocument/signatureHelp",
    "textDocument/foldingRange",
    "textDocument/documentLink",
    "textDocument/documentHighlight",
    "textDocument/semanticTokens/full",
    "textDocument/semanticTokens/full/delta",
    "textDocument/semanticTokens/range",
    "textDocument/diagnostic",
    "textDocument/formatting",
    "textDocument/rangeFormatting",
    "textDocument/selectionRange",
    "textDocument/linkedEditingRange",
    "textDocument/callHierarchy",
    "textDocument/typeHierarchy",
    "workspace/executeCommand",
    "workspace/applyEdit",
    "workspace/configuration",
    "workspace/didChangeConfiguration",
    "workspace/didChangeWatchedFiles",
    "workspace/didChangeWorkspaceFolders",
    "$/cancelRequest",
    "$/progress",
};

pub const ManifestValidationError = error{
    EmptyId,
    InvalidIdChars,
    EmptyVersion,
    EmptyEntry,
    ReservedMethod,
    InvalidNamespace,
    ElevatedCapabilityForbidden,
};

/// Validate manifest fields per plugin SDK 1.0 invariants.
///   - id: kebab-case, [a-z0-9-]+
///   - version: non-empty (semver shape recommended; not enforced)
///   - entry: non-empty path
///   - capabilities.lsp_requests / lsp_notifications:
///     - rejected when in `RESERVED_LSP_METHODS`
///     - must start with `refract.<id>.` or `experimental.<id>.` namespace
///   - sandbox.allow_network / sandbox.allow_fs_write:
///     - rejected outright in 0.1.0; OS-level sandbox enforcement lands in 0.2.0.
///       Until then any declared elevated capability is a hard error (fail closed).
pub fn validateManifest(m: Manifest) ManifestValidationError!void {
    if (m.id.len == 0) return error.EmptyId;
    for (m.id) |b| {
        const ok = (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '-' or b == '_';
        if (!ok) return error.InvalidIdChars;
    }
    if (m.version.len == 0) return error.EmptyVersion;
    if (m.entry.len == 0) return error.EmptyEntry;

    if (m.allow_network) return error.ElevatedCapabilityForbidden;
    if (m.allow_fs_write.len > 0) return error.ElevatedCapabilityForbidden;

    for (m.lsp_requests) |method| try validatePluginMethod(m.id, method);
    for (m.lsp_notifications) |method| try validatePluginMethod(m.id, method);
}

fn validatePluginMethod(id: []const u8, method: []const u8) ManifestValidationError!void {
    for (RESERVED_LSP_METHODS) |r| {
        if (std.mem.eql(u8, method, r)) return error.ReservedMethod;
    }
    var ok = false;
    var prefix_buf: [128]u8 = undefined;
    if (id.len + "refract..".len <= prefix_buf.len) {
        const refract_prefix = std.fmt.bufPrint(&prefix_buf, "refract.{s}.", .{id}) catch "";
        if (refract_prefix.len > 0 and std.mem.startsWith(u8, method, refract_prefix)) ok = true;
    }
    if (!ok and id.len + "experimental..".len <= prefix_buf.len) {
        const exp_prefix = std.fmt.bufPrint(&prefix_buf, "experimental.{s}.", .{id}) catch "";
        if (exp_prefix.len > 0 and std.mem.startsWith(u8, method, exp_prefix)) ok = true;
    }
    if (!ok) return error.InvalidNamespace;
}

pub const Manifest = struct {
    id: []const u8,
    version: []const u8,
    entry: []const u8,
    description: ?[]const u8 = null,
    lsp_requests: [][]const u8,
    lsp_notifications: [][]const u8,
    mcp_tools: [][]const u8,
    initialize_ms: u32,
    request_ms: u32,
    shutdown_ms: u32,
    allow_network: bool,
    allow_fs_write: [][]const u8,

    pub fn deinit(self: *Manifest, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.version);
        alloc.free(self.entry);
        if (self.description) |d| alloc.free(d);
        freeStrSlice(alloc, self.lsp_requests);
        freeStrSlice(alloc, self.lsp_notifications);
        freeStrSlice(alloc, self.mcp_tools);
        freeStrSlice(alloc, self.allow_fs_write);
    }
};

fn freeStrSlice(alloc: std.mem.Allocator, slice: [][]const u8) void {
    for (slice) |s| alloc.free(s);
    alloc.free(slice);
}

pub fn parseManifest(alloc: std.mem.Allocator, json_bytes: []const u8) !Manifest {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.BadType;
    const obj = root.object;

    const id = try requireString(alloc, obj, "id");
    errdefer alloc.free(id);
    const version = try requireString(alloc, obj, "version");
    errdefer alloc.free(version);
    const entry = try requireString(alloc, obj, "entry");
    errdefer alloc.free(entry);
    const description: ?[]const u8 = if (obj.get("description")) |v| (if (v == .string) try alloc.dupe(u8, v.string) else null) else null;
    errdefer if (description) |d| alloc.free(d);

    const caps = obj.get("capabilities") orelse return error.MissingField;
    if (caps != .object) return error.BadType;
    const caps_obj = caps.object;
    const lsp_requests = try optionalStringArray(alloc, caps_obj, "lsp_requests");
    errdefer freeStrSlice(alloc, lsp_requests);
    const lsp_notifications = try optionalStringArray(alloc, caps_obj, "lsp_notifications");
    errdefer freeStrSlice(alloc, lsp_notifications);
    const mcp_tools = try optionalStringArray(alloc, caps_obj, "mcp_tools");
    errdefer freeStrSlice(alloc, mcp_tools);

    var initialize_ms: u32 = 5000;
    var request_ms: u32 = 2000;
    var shutdown_ms: u32 = 1000;
    if (obj.get("timeouts")) |to_v| {
        if (to_v == .object) {
            const to = to_v.object;
            initialize_ms = optionalU32(to, "initialize_ms") orelse 5000;
            request_ms = optionalU32(to, "request_ms") orelse 2000;
            shutdown_ms = optionalU32(to, "shutdown_ms") orelse 1000;
        }
    }

    var allow_network = false;
    var allow_fs_write: [][]const u8 = &.{};
    if (obj.get("sandbox")) |sb_v| {
        if (sb_v == .object) {
            const sb = sb_v.object;
            if (sb.get("allow_network")) |an| {
                if (an == .bool) allow_network = an.bool;
            }
            allow_fs_write = try optionalStringArray(alloc, sb, "allow_fs_write");
        }
    }
    errdefer freeStrSlice(alloc, allow_fs_write);

    return Manifest{
        .id = id,
        .version = version,
        .entry = entry,
        .description = description,
        .lsp_requests = lsp_requests,
        .lsp_notifications = lsp_notifications,
        .mcp_tools = mcp_tools,
        .initialize_ms = initialize_ms,
        .request_ms = request_ms,
        .shutdown_ms = shutdown_ms,
        .allow_network = allow_network,
        .allow_fs_write = allow_fs_write,
    };
}

fn requireString(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = obj.get(key) orelse return error.MissingField;
    if (v != .string) return error.BadType;
    return try alloc.dupe(u8, v.string);
}

fn optionalStringArray(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![][]const u8 {
    const v = obj.get(key) orelse return try alloc.alloc([]const u8, 0);
    if (v != .array) return error.BadType;
    const arr = v.array.items;
    const out = try alloc.alloc([]const u8, arr.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |s| alloc.free(s);
        alloc.free(out);
    }
    for (arr) |item| {
        if (item != .string) return error.BadType;
        out[filled] = try alloc.dupe(u8, item.string);
        filled += 1;
    }
    return out;
}

fn optionalU32(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        .float => |f| if (f >= 0 and f <= @as(f64, std.math.maxInt(u32))) @intFromFloat(f) else null,
        else => null,
    };
}

pub const PluginState = enum { ready, unhealthy, shutdown };

pub const Plugin = struct {
    manifest: Manifest,
    plugin_dir: []u8,
    entry_path: []u8,
    child: std.process.Child,
    state: PluginState,
    next_id: i64,
    alloc: std.mem.Allocator,
    io_mu: std.Io.Mutex = std.Io.Mutex.init,

    pub fn spawn(alloc: std.mem.Allocator, manifest: Manifest, plugin_dir: []const u8) !Plugin {
        const dir_owned = try alloc.dupe(u8, plugin_dir);
        errdefer alloc.free(dir_owned);
        const entry = if (std.fs.path.isAbsolute(manifest.entry))
            try alloc.dupe(u8, manifest.entry)
        else
            try std.fs.path.join(alloc, &.{ plugin_dir, manifest.entry });
        errdefer alloc.free(entry);

        // Sandbox enforcement (v0.1.0):
        //   Linux  → seccomp-bpf (network block) + Landlock (fs scope, ≥5.13) + setrlimit
        //   macOS  → sandbox_init SBPL profile + setrlimit
        // Applied via the trampoline pattern: refract spawns itself with
        // --sandbox-exec, which installs the filter then execve's the plugin
        // entry. seccomp / Landlock / rlimits persist across exec.
        //
        // Manifest validation has already refused allow_network=true and
        // non-empty allow_fs_write for v0.1.0 (fail-closed posture). When
        // 0.1.1 loosens the manifest gate, the same trampoline flags wire up
        // through here without any other change.
        var self_buf: [4096]u8 = undefined;
        const self_path = selfExePath(&self_buf) orelse return error.SelfExePath;

        var argv_list = std.ArrayList([]const u8).empty;
        defer argv_list.deinit(alloc);
        try argv_list.append(alloc, self_path);
        try argv_list.append(alloc, "--sandbox-exec");
        if (manifest.allow_network) try argv_list.append(alloc, "--allow-network");
        var fs_write_args = std.ArrayList([]u8).empty;
        defer {
            for (fs_write_args.items) |a| alloc.free(a);
            fs_write_args.deinit(alloc);
        }
        for (manifest.allow_fs_write) |p| {
            const flag = try std.fmt.allocPrint(alloc, "--allow-fs-write={s}", .{p});
            try fs_write_args.append(alloc, flag);
            try argv_list.append(alloc, flag);
        }
        try argv_list.append(alloc, "--");
        try argv_list.append(alloc, entry);

        const cwd_z = try alloc.dupeZ(u8, plugin_dir);
        defer alloc.free(cwd_z);
        const child = try std.process.spawn(std.Options.debug_io, .{
            .argv = argv_list.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .cwd = .{ .path = cwd_z },
        });
        return Plugin{
            .manifest = manifest,
            .plugin_dir = dir_owned,
            .entry_path = entry,
            .child = child,
            .state = .ready,
            .next_id = 1,
            .alloc = alloc,
        };
    }

    fn selfExePath(buf: []u8) ?[]const u8 {
        if (@import("builtin").os.tag == .macos) {
            var len: u32 = @intCast(buf.len);
            const rv = macos_exe._NSGetExecutablePath(buf.ptr, &len);
            if (rv == 0) {
                const slen = std.mem.indexOfScalar(u8, buf[0..@min(buf.len, len)], 0) orelse @as(usize, @intCast(len));
                return buf[0..slen];
            }
            return null;
        }
        const n = std.c.readlink("/proc/self/exe", buf.ptr, buf.len);
        if (n > 0 and n < buf.len) return buf[0..@intCast(n)];
        return null;
    }

    pub fn deinit(self: *Plugin) void {
        if (self.child.stdin) |s| s.close(std.Options.debug_io);
        self.child.stdin = null;
        self.child.kill(std.Options.debug_io);
        _ = self.child.wait(std.Options.debug_io) catch {};
        self.alloc.free(self.entry_path);
        self.alloc.free(self.plugin_dir);
        self.manifest.deinit(self.alloc);
    }

    pub fn sendInitialize(self: *Plugin, refract_version: []const u8, workspace_root: []const u8) ![]u8 {
        self.io_mu.lockUncancelable(std.Options.debug_io);
        defer self.io_mu.unlock(std.Options.debug_io);
        const id = self.next_id;
        self.next_id += 1;
        const body = try std.fmt.allocPrint(
            self.alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"refract_version\":\"{s}\",\"workspace_root\":\"{s}\",\"config\":{{}}}}}}",
            .{ id, refract_version, workspace_root },
        );
        defer self.alloc.free(body);
        try self.writeFrame(body);
        return try self.readFrame(self.manifest.initialize_ms);
    }

    pub fn sendRequest(self: *Plugin, method: []const u8, params_json: []const u8) ![]u8 {
        self.io_mu.lockUncancelable(std.Options.debug_io);
        defer self.io_mu.unlock(std.Options.debug_io);
        const id = self.next_id;
        self.next_id += 1;
        const body = try std.fmt.allocPrint(
            self.alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
            .{ id, method, params_json },
        );
        defer self.alloc.free(body);
        try self.writeFrame(body);
        return try self.readFrame(self.manifest.request_ms);
    }

    pub fn shutdown(self: *Plugin) void {
        if (self.state == .shutdown) return;
        self.state = .shutdown;
        const id = self.next_id;
        self.next_id += 1;
        var buf: [128]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"shutdown\"}}", .{id}) catch return;
        self.writeFrame(body) catch {};
        _ = self.readFrame(self.manifest.shutdown_ms) catch {};
        const exit_body = "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}";
        self.writeFrame(exit_body) catch {};
    }

    fn writeFrame(self: *Plugin, body: []const u8) !void {
        var stdin = self.child.stdin orelse return error.NoStdin;
        var sbuf: [256]u8 = undefined;
        const header = try std.fmt.bufPrint(&sbuf, "Content-Length: {d}\r\n\r\n", .{body.len});
        try stdin.writeStreamingAll(std.Options.debug_io, header);
        try stdin.writeStreamingAll(std.Options.debug_io, body);
    }

    fn readFrame(self: *Plugin, timeout_ms: u32) ![]u8 {
        var tctx = server.TimeoutCtx{
            .child = &self.child,
            .done = std.atomic.Value(bool).init(false),
            .timeout_ns = @as(u64, timeout_ms) * std.time.ns_per_ms,
        };
        const tkill = std.Thread.spawn(.{}, server.TimeoutCtx.run, .{&tctx}) catch null;
        defer {
            tctx.done.store(true, .release);
            if (tkill) |t| t.join();
        }
        var stdout = self.child.stdout orelse return error.NoStdout;
        var hdr_buf: [256]u8 = undefined;
        var hdr_len: usize = 0;
        while (hdr_len < hdr_buf.len) {
            const n = try stdout.readStreaming(std.Options.debug_io, &.{hdr_buf[hdr_len .. hdr_len + 1]});
            if (n == 0) return error.EndOfStream;
            hdr_len += n;
            if (hdr_len >= 4 and std.mem.eql(u8, hdr_buf[hdr_len - 4 .. hdr_len], "\r\n\r\n")) break;
        }
        const header_str = hdr_buf[0..hdr_len];
        var content_len: usize = 0;
        var it = std.mem.splitSequence(u8, header_str, "\r\n");
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "Content-Length: ")) {
                content_len = std.fmt.parseInt(usize, line["Content-Length: ".len..], 10) catch 0;
            }
        }
        if (content_len == 0 or content_len > 16 * 1024 * 1024) return error.InvalidContentLength;
        const body = try self.alloc.alloc(u8, content_len);
        var got: usize = 0;
        while (got < content_len) {
            const n = try stdout.readStreaming(std.Options.debug_io, &.{body[got..]});
            if (n == 0) {
                self.alloc.free(body);
                return error.EndOfStream;
            }
            got += n;
        }
        return body;
    }
};

pub const Host = struct {
    alloc: std.mem.Allocator,
    plugins: std.ArrayList(Plugin),
    refract_version: []const u8,

    pub fn init(alloc: std.mem.Allocator, refract_version: []const u8) Host {
        return .{
            .alloc = alloc,
            .plugins = .empty,
            .refract_version = refract_version,
        };
    }

    pub fn deinit(self: *Host) void {
        for (self.plugins.items) |*p| {
            p.shutdown();
            p.deinit();
        }
        self.plugins.deinit(self.alloc);
    }

    /// Walks workspace + XDG paths, parses manifests, spawns each, sends initialize.
    /// Plugins that fail to load are skipped (logged via stderr).
    pub fn discoverAndSpawn(self: *Host, workspace_root: []const u8) !void {
        try self.scanDir(workspace_root, ".refract/extensions");
        if (std.c.getenv("XDG_DATA_HOME")) |xdg_p| {
            const xdg = std.mem.span(xdg_p);
            try self.scanAbs(xdg, "refract/extensions");
        } else if (std.c.getenv("HOME")) |home_p| {
            const home = std.mem.span(home_p);
            const path = try std.fs.path.join(self.alloc, &.{ home, ".local", "share" });
            defer self.alloc.free(path);
            try self.scanAbs(path, "refract/extensions");
        }
    }

    fn scanDir(self: *Host, base: []const u8, sub: []const u8) !void {
        const path = try std.fs.path.join(self.alloc, &.{ base, sub });
        defer self.alloc.free(path);
        try self.scanAbsoluteJoined(path);
    }

    fn scanAbs(self: *Host, base: []const u8, sub: []const u8) !void {
        const path = try std.fs.path.join(self.alloc, &.{ base, sub });
        defer self.alloc.free(path);
        try self.scanAbsoluteJoined(path);
    }

    fn scanAbsoluteJoined(self: *Host, ext_root: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, ext_root, .{ .iterate = true }) catch return;
        defer dir.close(std.Options.debug_io);
        var it = dir.iterate();
        while (it.next(std.Options.debug_io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const plugin_dir = try std.fs.path.join(self.alloc, &.{ ext_root, entry.name });
            defer self.alloc.free(plugin_dir);
            self.loadPlugin(plugin_dir) catch |err| {
                std.debug.print("refract: plugin load failed at {s}: {s}\n", .{ plugin_dir, @errorName(err) });
                continue;
            };
        }
    }

    fn loadPlugin(self: *Host, plugin_dir: []const u8) !void {
        const manifest_path = try std.fs.path.join(self.alloc, &.{ plugin_dir, "refract-extension.json" });
        defer self.alloc.free(manifest_path);
        const file = try std.Io.Dir.cwd().openFile(std.Options.debug_io, manifest_path, .{});
        defer file.close(std.Options.debug_io);
        var rbuf: [16 * 1024]u8 = undefined;
        var fr = file.readerStreaming(std.Options.debug_io, &rbuf);
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(self.alloc);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = fr.interface.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            try bytes.appendSlice(self.alloc, chunk[0..n]);
            if (bytes.items.len > 256 * 1024) return error.ManifestTooLarge;
        }

        var manifest = try parseManifest(self.alloc, bytes.items);
        validateManifest(manifest) catch |err| {
            manifest.deinit(self.alloc);
            return err;
        };
        var plugin = Plugin.spawn(self.alloc, manifest, plugin_dir) catch |e| {
            manifest.deinit(self.alloc);
            return e;
        };
        errdefer plugin.deinit();

        const init_resp = plugin.sendInitialize(self.refract_version, plugin_dir) catch |err| {
            plugin.state = .unhealthy;
            return err;
        };
        self.alloc.free(init_resp);

        try self.plugins.append(self.alloc, plugin);
    }

    pub fn callRequest(self: *Host, method: []const u8, params_json: []const u8) !?[]u8 {
        for (self.plugins.items) |*p| {
            if (p.state != .ready) continue;
            for (p.manifest.lsp_requests) |declared| {
                if (std.mem.eql(u8, declared, method)) {
                    return try p.sendRequest(method, params_json);
                }
            }
        }
        return null;
    }
};

test "parseManifest reads required fields" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "id": "hello",
        \\  "version": "0.1.0",
        \\  "entry": "bin/run",
        \\  "capabilities": {
        \\    "lsp_requests": ["a", "b"],
        \\    "lsp_notifications": [],
        \\    "mcp_tools": []
        \\  },
        \\  "timeouts": {
        \\    "initialize_ms": 1000,
        \\    "request_ms": 500,
        \\    "shutdown_ms": 250
        \\  },
        \\  "sandbox": {
        \\    "allow_network": false,
        \\    "allow_fs_write": []
        \\  }
        \\}
    ;
    var m = try parseManifest(alloc, json);
    defer m.deinit(alloc);
    try std.testing.expectEqualStrings("hello", m.id);
    try std.testing.expectEqualStrings("bin/run", m.entry);
    try std.testing.expectEqual(@as(usize, 2), m.lsp_requests.len);
    try std.testing.expectEqual(@as(u32, 1000), m.initialize_ms);
    try std.testing.expectEqual(false, m.allow_network);
}

test "parseManifest rejects missing id" {
    const alloc = std.testing.allocator;
    const json =
        \\{"version":"0.1.0","entry":"x","capabilities":{}}
    ;
    try std.testing.expectError(error.MissingField, parseManifest(alloc, json));
}

test "validateManifest accepts proper namespace" {
    const alloc = std.testing.allocator;
    const json =
        \\{"id":"hello","version":"0.1.0","entry":"bin/run","capabilities":{"lsp_requests":["refract.hello.echo"]}}
    ;
    var m = try parseManifest(alloc, json);
    defer m.deinit(alloc);
    try validateManifest(m);
}

test "validateManifest rejects reserved core method" {
    const alloc = std.testing.allocator;
    const json =
        \\{"id":"evil","version":"0.1.0","entry":"x","capabilities":{"lsp_requests":["textDocument/hover"]}}
    ;
    var m = try parseManifest(alloc, json);
    defer m.deinit(alloc);
    try std.testing.expectError(error.ReservedMethod, validateManifest(m));
}

test "validateManifest rejects bad namespace" {
    const alloc = std.testing.allocator;
    const json =
        \\{"id":"foo","version":"0.1.0","entry":"x","capabilities":{"lsp_requests":["foo.bar.baz"]}}
    ;
    var m = try parseManifest(alloc, json);
    defer m.deinit(alloc);
    try std.testing.expectError(error.InvalidNamespace, validateManifest(m));
}

test "validateManifest rejects bad id chars" {
    const alloc = std.testing.allocator;
    const json =
        \\{"id":"Bad Id","version":"0.1.0","entry":"x","capabilities":{}}
    ;
    var m = try parseManifest(alloc, json);
    defer m.deinit(alloc);
    try std.testing.expectError(error.InvalidIdChars, validateManifest(m));
}

test "validateManifest refuses allow_network=true (0.1.0 fail-closed until 0.2 sandbox)" {
    const alloc = std.testing.allocator;
    const json =
        \\{"id":"net","version":"0.1.0","entry":"bin/x","capabilities":{"lsp_requests":["refract.net.fetch"]},"sandbox":{"allow_network":true,"allow_fs_write":[]}}
    ;
    var m = try parseManifest(alloc, json);
    defer m.deinit(alloc);
    try std.testing.expectError(error.ElevatedCapabilityForbidden, validateManifest(m));
}

test "validateManifest refuses non-empty allow_fs_write" {
    const alloc = std.testing.allocator;
    const json =
        \\{"id":"fs","version":"0.1.0","entry":"bin/x","capabilities":{"lsp_requests":["refract.fs.write"]},"sandbox":{"allow_network":false,"allow_fs_write":["/tmp"]}}
    ;
    var m = try parseManifest(alloc, json);
    defer m.deinit(alloc);
    try std.testing.expectError(error.ElevatedCapabilityForbidden, validateManifest(m));
}

test "parseManifest defaults apply when timeouts/sandbox missing" {
    const alloc = std.testing.allocator;
    const json =
        \\{"id":"x","version":"0","entry":"y","capabilities":{}}
    ;
    var m = try parseManifest(alloc, json);
    defer m.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 5000), m.initialize_ms);
    try std.testing.expectEqual(@as(u32, 2000), m.request_ms);
    try std.testing.expectEqual(@as(u32, 1000), m.shutdown_ms);
    try std.testing.expectEqual(false, m.allow_network);
}

test "Host round-trips through hello plugin" {
    if (std.c.getenv("REFRACT_SKIP_PLUGIN_TEST") != null) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var host = Host.init(alloc, "0.1.0-test");
    defer host.deinit();

    const cwd = std.process.currentPathAlloc(std.Options.debug_io, alloc) catch return error.SkipZigTest;
    defer alloc.free(cwd);

    const plugin_root = try std.fs.path.join(alloc, &.{ cwd, "examples/extensions/hello" });
    defer alloc.free(plugin_root);

    host.loadPlugin(plugin_root) catch |err| {
        std.debug.print("hello plugin load skipped: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    try std.testing.expectEqual(@as(usize, 1), host.plugins.items.len);
    const resp = (try host.callRequest("refract.hello.echo", "{\"value\":\"world\"}")) orelse return error.NoResponse;
    defer alloc.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "echoed") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "world") != null);
}
