const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

extern fn refract_bind_text(stmt: *c.sqlite3_stmt, col: c_int, ptr: [*]const u8, len: c_int) c_int;
extern fn refract_bind_blob(stmt: *c.sqlite3_stmt, col: c_int, ptr: ?*const anyopaque, len: c_int) c_int;

const schema = @import("db/schema.zig");

pub const CURRENT_SCHEMA: u32 = 7;

pub const DbError = error{
    Open,
    Exec,
    Prepare,
    Step,
    Busy,
};

pub const Stmt = struct {
    raw: *c.sqlite3_stmt,

    pub fn step(self: Stmt) DbError!bool {
        const rc = c.sqlite3_step(self.raw);
        return switch (rc) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            c.SQLITE_BUSY => DbError.Busy,
            else => DbError.Step,
        };
    }

    pub fn column_text(self: Stmt, col: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(self.raw, col);
        if (ptr == null) return "";
        const len = @as(usize, @intCast(c.sqlite3_column_bytes(self.raw, col)));
        return ptr[0..len];
    }

    pub fn column_int(self: Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(self.raw, col);
    }

    pub fn column_type(self: Stmt, col: c_int) c_int {
        return c.sqlite3_column_type(self.raw, col);
    }

    pub fn bind_text(self: Stmt, col: c_int, val: []const u8) void {
        _ = refract_bind_text(self.raw, col, val.ptr, @intCast(val.len));
    }

    pub fn bind_int(self: Stmt, col: c_int, val: i64) void {
        _ = c.sqlite3_bind_int64(self.raw, col, val);
    }

    pub fn bind_null(self: Stmt, col: c_int) void {
        _ = c.sqlite3_bind_null(self.raw, col);
    }

    pub fn bind_blob(self: Stmt, col: c_int, data: []const u8) void {
        _ = refract_bind_blob(self.raw, col, data.ptr, @intCast(data.len));
    }

    pub fn column_blob(self: Stmt, col: c_int) []const u8 {
        const ptr = c.sqlite3_column_blob(self.raw, col);
        if (ptr == null) return "";
        const len = @as(usize, @intCast(c.sqlite3_column_bytes(self.raw, col)));
        return @as([*]const u8, @ptrCast(ptr))[0..len];
    }

    pub fn reset(self: Stmt) void {
        _ = c.sqlite3_reset(self.raw);
    }

    pub fn finalize(self: Stmt) void {
        _ = c.sqlite3_finalize(self.raw);
    }
};

pub const CachedStmt = struct {
    raw: *c.sqlite3_stmt,

    pub fn step(self: CachedStmt) DbError!bool {
        return switch (c.sqlite3_step(self.raw)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            c.SQLITE_BUSY => DbError.Busy,
            else => DbError.Step,
        };
    }

    pub fn column_text(self: CachedStmt, col: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(self.raw, col);
        if (ptr == null) return "";
        return ptr[0..@intCast(c.sqlite3_column_bytes(self.raw, col))];
    }

    pub fn column_int(self: CachedStmt, col: c_int) i64 {
        return c.sqlite3_column_int64(self.raw, col);
    }

    pub fn bind_text(self: CachedStmt, col: c_int, val: []const u8) void {
        _ = refract_bind_text(self.raw, col, val.ptr, @intCast(val.len));
    }

    pub fn bind_int(self: CachedStmt, col: c_int, val: i64) void {
        _ = c.sqlite3_bind_int64(self.raw, col, val);
    }

    pub fn reset(self: CachedStmt) void {
        _ = c.sqlite3_reset(self.raw);
        _ = c.sqlite3_clear_bindings(self.raw);
    }

    pub fn finalize(self: CachedStmt) void {
        _ = c.sqlite3_finalize(self.raw);
    }
};

pub const Db = struct {
    raw: *c.sqlite3,
    was_self_healed: bool = false,

    pub fn open(path: [:0]const u8) DbError!Db {
        const profiling = std.c.getenv("REFRACT_INIT_PROFILE") != null;
        const open_start = if (profiling) std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() else 0;
        var attempt: u8 = 0;
        var healed = false;
        while (attempt < 2) : (attempt += 1) {
            var db: ?*c.sqlite3 = null;
            const rc = c.sqlite3_open(path.ptr, &db);
            if (rc != c.SQLITE_OK) {
                if (db) |h| _ = c.sqlite3_close(h);
                return DbError.Open;
            }
            _ = c.sqlite3_busy_timeout(db.?, 5000);

            var stmt: ?*c.sqlite3_stmt = null;
            const check_start = if (profiling) std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() else 0;
            // Lightweight integrity probe. Forces SQLite to parse the schema btree,
            // which validates the header and the schema page. Microseconds on a warm
            // DB. Fails on garbage files / corrupted headers, keeping the self-heal
            // flow intact while avoiding the multi-second full-DB scan that
            // PRAGMA integrity_check imposes on every Db.open().
            const prc = c.sqlite3_prepare_v2(db.?, "SELECT count(*) FROM sqlite_master", -1, &stmt, null);
            var probe_ok = prc == c.SQLITE_OK;
            if (probe_ok) {
                const sc = c.sqlite3_step(stmt);
                if (sc != c.SQLITE_ROW and sc != c.SQLITE_DONE) probe_ok = false;
                _ = c.sqlite3_finalize(stmt);
            }
            if (probe_ok) {
                if (profiling) {
                    const check_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() - check_start;
                    const open_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() - open_start;
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "refract_profile: db.open={d}ms schema_check={d}ms\n", .{ open_ms, check_ms }) catch "";
                    if (msg.len > 0) std.debug.print("{s}", .{msg});
                }
                return Db{ .raw = db.?, .was_self_healed = healed };
            }

            _ = c.sqlite3_close(db.?);
            if (attempt == 0) {
                std.debug.print("{s}", .{"refract: db self-heal: corrupted file at "});
                std.debug.print("{s}", .{path});
                std.debug.print("{s}", .{", rebuilding\n"});
                std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, path) catch {};
                var buf: [512]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "{s}-wal", .{path})) |wal| {
                    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, wal) catch {};
                } else |_| {}
                if (std.fmt.bufPrint(&buf, "{s}-shm", .{path})) |shm| {
                    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, shm) catch {};
                } else |_| {}
                healed = true;
                continue;
            }
            return DbError.Open;
        }
        unreachable;
    }

    pub fn openReadOnly(path: [:0]const u8) DbError!Db {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_URI, null);
        if (rc != c.SQLITE_OK) {
            if (db) |h| _ = c.sqlite3_close(h);
            return DbError.Open;
        }
        _ = c.sqlite3_busy_timeout(db.?, 5000);
        return Db{ .raw = db.?, .was_self_healed = false };
    }

    pub fn close(self: Db) void {
        _ = c.sqlite3_close(self.raw);
    }

    pub fn exec(self: Db, sql: [*:0]const u8) DbError!void {
        const rc = c.sqlite3_exec(self.raw, sql, null, null, null);
        if (rc != c.SQLITE_OK) return DbError.Exec;
    }

    pub fn execLogged(self: Db, sql: [*:0]const u8) DbError!void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.raw, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg != null) {
                std.debug.print("{s}", .{"refract: sqlite exec error: "});
                std.debug.print("{s}", .{std.mem.span(err_msg)});
                std.debug.print("{s}", .{"\n"});
                c.sqlite3_free(err_msg);
            }
            return DbError.Exec;
        }
    }

    pub fn prepare(self: Db, sql: [*:0]const u8) DbError!Stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.raw, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return DbError.Prepare;
        return Stmt{ .raw = stmt.? };
    }

    pub fn prepareRaw(self: Db, sql: [*:0]const u8) DbError!CachedStmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.raw, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return DbError.Prepare;
        return CachedStmt{ .raw = stmt.? };
    }

    pub fn last_insert_rowid(self: Db) i64 {
        return c.sqlite3_last_insert_rowid(self.raw);
    }

    pub fn lastErrmsg(self: Db) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.raw));
    }

    pub fn begin(self: Db) DbError!void {
        try self.exec("BEGIN");
    }

    pub fn commit(self: Db) DbError!void {
        try self.exec("COMMIT");
    }

    pub fn rollback(self: Db) DbError!void {
        try self.exec("ROLLBACK");
    }

    pub fn init_schema(self: Db) DbError!void {
        return schema.init(self);
    }

    pub fn getSchemaVersion(self: Db) ?i64 {
        const stmt = self.prepare("SELECT value FROM meta WHERE key='schema_version'") catch return null;
        defer stmt.finalize();
        if (stmt.step() catch false) {
            return std.fmt.parseInt(i64, stmt.column_text(0), 10) catch null;
        }
        return null;
    }

    pub fn runOptimize(self: Db) void {
        _ = self.exec("PRAGMA optimize;") catch {}; // maintenance
    }

    pub fn runVacuum(self: Db) void {
        _ = self.exec("PRAGMA incremental_vacuum(64)") catch {}; // maintenance
    }

    pub fn changes(self: Db) i64 {
        return c.sqlite3_changes(self.raw);
    }

    pub fn execMigration(self: Db, sql: [*:0]const u8) void {
        self.exec(sql) catch {
            const errmsg = std.mem.span(c.sqlite3_errmsg(self.raw));
            if (std.mem.indexOf(u8, errmsg, "duplicate column name") != null) return;
            if (std.mem.indexOf(u8, errmsg, "already exists") != null) return;
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "refract: DB migration warning: {s}\n", .{errmsg}) catch "refract: DB migration warning\n";
            std.debug.print("{s}", .{msg});
        };
    }

    pub fn checkpoint(self: Db) void {
        self.exec("PRAGMA wal_checkpoint(TRUNCATE)") catch {}; // maintenance
    }

    pub fn flushAndClose(self: Db) void {
        self.checkpoint();
        self.close();
    }

    pub fn check_integrity(self: Db) DbError!void {
        const profiling = std.c.getenv("REFRACT_INIT_PROFILE") != null;
        const check_start = if (profiling) std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() else 0;
        const stmt = try self.prepare("PRAGMA quick_check");
        defer stmt.finalize();
        if (try stmt.step()) {
            if (!std.mem.eql(u8, stmt.column_text(0), "ok")) return DbError.Exec;
        }
        if (profiling) {
            const check_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() - check_start;
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "refract_profile: check_integrity_quick_check={d}ms\n", .{check_ms}) catch "";
            if (msg.len > 0) std.debug.print("{s}", .{msg});
        }
    }
};

test "schema creation" {
    const db = try Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    try db.init_schema();
}

test "transaction commit and rollback" {
    const db = try Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    try db.begin();
    try db.exec("INSERT INTO meta(key,value) VALUES('test_key','test_val')");
    try db.commit();
    const s1 = try db.prepare("SELECT value FROM meta WHERE key='test_key'");
    defer s1.finalize();
    try std.testing.expect(try s1.step());
    try std.testing.expectEqualStrings("test_val", s1.column_text(0));
    try db.begin();
    try db.exec("DELETE FROM meta WHERE key='test_key'");
    try db.rollback();
    const s2 = try db.prepare("SELECT value FROM meta WHERE key='test_key'");
    defer s2.finalize();
    try std.testing.expect(try s2.step());
}

test "check_integrity on valid db" {
    const db = try Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    try db.check_integrity();
}

test "self-heal: corrupted db file is detected, deleted, rebuilt with was_self_healed=true" {
    // Write a garbage non-SQLite file to a temp path. Db.open's lightweight
    // schema probe fails → self-heal deletes + recreates a fresh DB.
    const pid: u64 = @intCast(std.c.getpid());
    var path_buf: [96]u8 = undefined;
    const path_str = try std.fmt.bufPrint(&path_buf, "/tmp/refract_crash_recovery_{d}.db", .{pid});
    path_buf[path_str.len] = 0;
    const path_z: [:0]const u8 = path_buf[0..path_str.len :0];

    const garbage = "NOT_SQLITE_GARBAGE_PAYLOAD_PADDING_FOR_HEADER_PROBE";
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = path_z, .data = garbage });

    const db = try Db.open(path_z);
    defer db.close();
    try std.testing.expect(db.was_self_healed);
    try db.init_schema();
    try db.check_integrity();

    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path_z) catch {};
    var aux_buf: [128]u8 = undefined;
    if (std.fmt.bufPrint(&aux_buf, "{s}-wal", .{path_z})) |wal| {
        aux_buf[wal.len] = 0;
        const wal_z: [:0]const u8 = aux_buf[0..wal.len :0];
        std.Io.Dir.cwd().deleteFile(std.Options.debug_io, wal_z) catch {};
    } else |_| {}
    if (std.fmt.bufPrint(&aux_buf, "{s}-shm", .{path_z})) |shm| {
        aux_buf[shm.len] = 0;
        const shm_z: [:0]const u8 = aux_buf[0..shm.len :0];
        std.Io.Dir.cwd().deleteFile(std.Options.debug_io, shm_z) catch {};
    } else |_| {}
}

test "getSchemaVersion returns current version" {
    const db = try Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    const ver = db.getSchemaVersion() orelse 0;
    try std.testing.expectEqual(@as(i64, CURRENT_SCHEMA), ver);
}

test "schema idempotent: init twice does not error" {
    const db = try Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    try db.init_schema();
    const ver = db.getSchemaVersion() orelse 0;
    try std.testing.expectEqual(@as(i64, CURRENT_SCHEMA), ver);
}

test "schema v5 tables present" {
    const db = try Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    const tables = [_][]const u8{
        "sorbet_results",
        "steep_results",
        "coverage_lines",
        "brakeman_findings",
        "semgrep_findings",
        "plugin_state",
        "runs",
    };
    for (tables) |t| {
        const stmt = try db.prepare("SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?");
        defer stmt.finalize();
        stmt.bind_text(1, t);
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqual(@as(i64, 1), stmt.column_int(0));
    }
}

test "schema v5 runs/sorbet round-trip" {
    const db = try Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    try db.exec("INSERT INTO runs(kind, started_at, ended_at, exit_code) VALUES('sorbet', 1000, 2000, 0)");
    const run_id = db.last_insert_rowid();
    try std.testing.expect(run_id > 0);
    const ins = try db.prepare(
        "INSERT INTO sorbet_results(symbol_id, fqn, kind, type_str, source, confidence, run_id, ts_us) VALUES(NULL, ?, 'method', ?, 'sorbet', 100, ?, 3000)",
    );
    defer ins.finalize();
    ins.bind_text(1, "Foo#bar");
    ins.bind_text(2, "Integer");
    ins.bind_int(3, run_id);
    try std.testing.expect(!(try ins.step()));
    const sel = try db.prepare("SELECT type_str FROM sorbet_results WHERE fqn=?");
    defer sel.finalize();
    sel.bind_text(1, "Foo#bar");
    try std.testing.expect(try sel.step());
    try std.testing.expectEqualStrings("Integer", sel.column_text(0));
}

test "schema v5 type_resolution view unifies bridge + oracle rows" {
    const db = try Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    try db.exec("INSERT INTO sorbet_results(fqn, kind, type_str, source, confidence, ts_us) VALUES('Foo','class','User','sorbet:hover',95,100)");
    try db.exec("INSERT INTO steep_results(fqn, kind, type_str, source, confidence, ts_us) VALUES('Bar','class','Order','steep',90,200)");
    try db.exec("INSERT INTO type_oracle(fqn, type_str, source, confidence) VALUES('Baz','Item','rbs',70)");

    const stmt = try db.prepare("SELECT source, type_str, confidence FROM type_resolution WHERE fqn = ?");
    defer stmt.finalize();

    stmt.bind_text(1, "Foo");
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("sorbet", stmt.column_text(0));
    try std.testing.expectEqualStrings("User", stmt.column_text(1));
    try std.testing.expectEqual(@as(i64, 95), stmt.column_int(2));
    stmt.reset();

    stmt.bind_text(1, "Bar");
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("steep", stmt.column_text(0));
    stmt.reset();

    stmt.bind_text(1, "Baz");
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("rbs", stmt.column_text(0));
}

test "schema v5 plugin_state unique key per plugin" {
    const db = try Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    try db.exec("INSERT INTO plugin_state(plugin_id, key, value, ts_us) VALUES('hello','greeting','hi',1000)");
    try db.exec("INSERT OR REPLACE INTO plugin_state(plugin_id, key, value, ts_us) VALUES('hello','greeting','bonjour',2000)");
    const sel = try db.prepare("SELECT value FROM plugin_state WHERE plugin_id='hello' AND key='greeting'");
    defer sel.finalize();
    try std.testing.expect(try sel.step());
    try std.testing.expectEqualStrings("bonjour", sel.column_text(0));
}

test "runOptimize and runVacuum do not crash" {
    const db = try Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    db.runOptimize();
    db.runVacuum();
}

test "stmt bind and column operations" {
    const db = try Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    try db.exec("INSERT INTO files(path, mtime) VALUES('test.rb', 1000)");
    const fid = db.last_insert_rowid();
    try std.testing.expect(fid > 0);
    const s = try db.prepare("SELECT path, mtime FROM files WHERE id=?");
    defer s.finalize();
    s.bind_int(1, fid);
    try std.testing.expect(try s.step());
    try std.testing.expectEqualStrings("test.rb", s.column_text(0));
    try std.testing.expectEqual(@as(i64, 1000), s.column_int(1));
    try std.testing.expect(!(try s.step()));
}

test "CachedStmt bind and reset" {
    const db = try Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    try db.exec("INSERT INTO files(path, mtime) VALUES('a.rb', 1)");
    try db.exec("INSERT INTO files(path, mtime) VALUES('b.rb', 2)");
    const cs = try db.prepareRaw("SELECT path FROM files WHERE mtime=?");
    defer cs.finalize();
    cs.bind_int(1, 1);
    try std.testing.expect(try cs.step());
    try std.testing.expectEqualStrings("a.rb", cs.column_text(0));
    cs.reset();
    cs.bind_int(1, 2);
    try std.testing.expect(try cs.step());
    try std.testing.expectEqualStrings("b.rb", cs.column_text(0));
}
