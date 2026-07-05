const std = @import("std");
const db_mod = @import("../db.zig");
const transport = @import("transport.zig");

pub const ServerKind = enum {
    sorbet,
    steep,

    pub fn argv(self: ServerKind) []const []const u8 {
        return switch (self) {
            .sorbet => &.{ "bundle", "exec", "srb", "tc", "--lsp", "--no-config-file" },
            .steep => &.{ "bundle", "exec", "steep", "langserver" },
        };
    }

    pub fn label(self: ServerKind) []const u8 {
        return switch (self) {
            .sorbet => "sorbet",
            .steep => "steep",
        };
    }

    pub fn tableName(self: ServerKind) []const u8 {
        return switch (self) {
            .sorbet => "sorbet_results",
            .steep => "steep_results",
        };
    }
};

/// Workspace detection. A workspace is sorbet-eligible if either a `sorbet/`
/// directory exists OR any `.rb` file with `# typed: ...` has been seen.
/// Cheap path: stat `sorbet/`.
pub fn workspaceHasSorbet(root: []const u8, alloc: std.mem.Allocator) bool {
    const path = std.fs.path.join(alloc, &.{ root, "sorbet" }) catch return false;
    defer alloc.free(path);
    var d = std.Io.Dir.cwd().openDir(std.Options.debug_io, path, .{}) catch return false;
    d.close(std.Options.debug_io);
    return true;
}

/// Workspace detection for Steep. Looks for `Steepfile`.
pub fn workspaceHasSteep(root: []const u8, alloc: std.mem.Allocator) bool {
    const path = std.fs.path.join(alloc, &.{ root, "Steepfile" }) catch return false;
    defer alloc.free(path);
    const f = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return false;
    f.close(std.Options.debug_io);
    return true;
}

pub const Bridge = struct {
    kind: ServerKind,
    child: std.process.Child,
    alloc: std.mem.Allocator,
    next_id: i64 = 1,
    project_root: []u8,
    io_mu: std.Io.Mutex = std.Io.Mutex.init,

    pub fn launch(kind: ServerKind, project_root: []const u8, alloc: std.mem.Allocator) !Bridge {
        const args = kind.argv();
        const cwd_z = try alloc.dupeZ(u8, project_root);
        defer alloc.free(cwd_z);
        const child = try std.process.spawn(std.Options.debug_io, .{
            .argv = args,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .cwd = .{ .path = cwd_z },
        });
        return Bridge{
            .kind = kind,
            .child = child,
            .alloc = alloc,
            .project_root = try alloc.dupe(u8, project_root),
        };
    }

    pub fn deinit(self: *Bridge) void {
        if (self.child.stdin) |s| s.close(std.Options.debug_io);
        self.child.stdin = null;
        self.child.kill(std.Options.debug_io);
        _ = self.child.wait(std.Options.debug_io) catch {};
        self.alloc.free(self.project_root);
    }

    /// Send a JSON-RPC request, await response. Caller frees returned bytes.
    pub fn request(self: *Bridge, method: []const u8, params_json: []const u8) ![]u8 {
        self.io_mu.lockUncancelable(std.Options.debug_io);
        defer self.io_mu.unlock(std.Options.debug_io);
        const id = self.next_id;
        self.next_id += 1;
        const body = try transport.buildRequestBody(self.alloc, id, method, params_json);
        defer self.alloc.free(body);
        try self.writeFrame(body);
        return try self.readFrame();
    }

    fn writeFrame(self: *Bridge, body: []const u8) !void {
        var stdin = self.child.stdin orelse return error.NoStdin;
        try transport.writeStreamFrame(&stdin, body);
    }

    fn readFrame(self: *Bridge) ![]u8 {
        var stdout = self.child.stdout orelse return error.NoStdout;
        return transport.readStreamFrame(&stdout, self.alloc);
    }
};

/// Insert a type result into the appropriate table (sorbet_results / steep_results).
/// `confidence` is 0..100. Caller-owned strings; copied into DB.
/// `workspace_id` enforces multi-root isolation (plan invariant W0.1 / Wave-3).
pub fn persistResult(
    db: db_mod.Db,
    db_mu: *std.Io.Mutex,
    kind: ServerKind,
    workspace_id: ?i64,
    fqn: []const u8,
    decl_kind: []const u8, // "method", "class", "var"
    type_str: []const u8,
    source: []const u8, // raw provenance label ("sorbet:typed-true", etc.)
    confidence: u8,
    run_id: ?i64,
) !void {
    const sql = switch (kind) {
        .sorbet => "INSERT INTO sorbet_results(workspace_id, fqn, kind, type_str, source, confidence, run_id, ts_us) VALUES(?,?,?,?,?,?,?,?)",
        .steep => "INSERT INTO steep_results(workspace_id, fqn, kind, type_str, source, confidence, run_id, ts_us) VALUES(?,?,?,?,?,?,?,?)",
    };
    db_mu.lockUncancelable(std.Options.debug_io);
    defer db_mu.unlock(std.Options.debug_io);
    const stmt = try db.prepare(sql);
    defer stmt.finalize();
    if (workspace_id) |w| stmt.bind_int(1, w) else stmt.bind_null(1);
    stmt.bind_text(2, fqn);
    stmt.bind_text(3, decl_kind);
    stmt.bind_text(4, type_str);
    stmt.bind_text(5, source);
    stmt.bind_int(6, @intCast(confidence));
    if (run_id) |r| stmt.bind_int(7, r) else stmt.bind_null(7);
    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds(), std.time.ns_per_us));
    stmt.bind_int(8, ts);
    _ = try stmt.step();
}

/// Open a `runs` row. Returns the new run_id.
pub fn beginRun(db: db_mod.Db, db_mu: *std.Io.Mutex, kind: []const u8) !i64 {
    db_mu.lockUncancelable(std.Options.debug_io);
    defer db_mu.unlock(std.Options.debug_io);
    const stmt = try db.prepare("INSERT INTO runs(kind, started_at) VALUES(?, ?)");
    defer stmt.finalize();
    stmt.bind_text(1, kind);
    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds(), std.time.ns_per_us));
    stmt.bind_int(2, ts);
    _ = try stmt.step();
    return db.last_insert_rowid();
}

pub fn endRun(db: db_mod.Db, db_mu: *std.Io.Mutex, run_id: i64, exit_code: i32, stderr_tail: []const u8) !void {
    db_mu.lockUncancelable(std.Options.debug_io);
    defer db_mu.unlock(std.Options.debug_io);
    const stmt = try db.prepare("UPDATE runs SET ended_at = ?, exit_code = ?, stderr_tail = ? WHERE run_id = ?");
    defer stmt.finalize();
    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(std.Options.debug_io, .real).toNanoseconds(), std.time.ns_per_us));
    stmt.bind_int(1, ts);
    stmt.bind_int(2, @intCast(exit_code));
    stmt.bind_text(3, stderr_tail);
    stmt.bind_int(4, run_id);
    _ = try stmt.step();
}

test "persistResult writes sorbet row" {
    const alloc = std.testing.allocator;
    _ = alloc;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    var mu: std.Io.Mutex = std.Io.Mutex.init;
    const run_id = try beginRun(db, &mu, "sorbet");
    try persistResult(db, &mu, .sorbet, null, "Foo#bar", "method", "Integer", "sorbet:typed-true", 95, run_id);
    try endRun(db, &mu, run_id, 0, "");

    const stmt = try db.prepare("SELECT type_str, confidence, run_id FROM sorbet_results WHERE fqn='Foo#bar'");
    defer stmt.finalize();
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("Integer", stmt.column_text(0));
    try std.testing.expectEqual(@as(i64, 95), stmt.column_int(1));
    try std.testing.expectEqual(run_id, stmt.column_int(2));
}

test "persistResult writes steep row" {
    const alloc = std.testing.allocator;
    _ = alloc;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    var mu: std.Io.Mutex = std.Io.Mutex.init;
    try persistResult(db, &mu, .steep, null, "Bar", "class", "Class<Bar>", "steep", 100, null);

    const stmt = try db.prepare("SELECT type_str FROM steep_results WHERE fqn='Bar'");
    defer stmt.finalize();
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("Class<Bar>", stmt.column_text(0));
}

test "workspaceHasSorbet false for non-sorbet workspace" {
    const alloc = std.testing.allocator;
    try std.testing.expect(!workspaceHasSorbet("/tmp/refract-no-such-workspace-99999", alloc));
}

test "workspaceHasSteep false when Steepfile missing" {
    const alloc = std.testing.allocator;
    try std.testing.expect(!workspaceHasSteep("/tmp/refract-no-such-workspace-99999", alloc));
}
