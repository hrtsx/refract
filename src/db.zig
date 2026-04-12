const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

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
        _ = c.sqlite3_bind_text(self.raw, col, val.ptr, @intCast(val.len), c.SQLITE_TRANSIENT);
    }

    pub fn bind_int(self: Stmt, col: c_int, val: i64) void {
        _ = c.sqlite3_bind_int64(self.raw, col, val);
    }

    pub fn bind_null(self: Stmt, col: c_int) void {
        _ = c.sqlite3_bind_null(self.raw, col);
    }

    pub fn bind_blob(self: Stmt, col: c_int, data: []const u8) void {
        _ = c.sqlite3_bind_blob(self.raw, col, data.ptr, @intCast(data.len), c.SQLITE_TRANSIENT);
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
        _ = c.sqlite3_bind_text(self.raw, col, val.ptr, @intCast(val.len), c.SQLITE_TRANSIENT);
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

    pub fn open(path: [:0]const u8) DbError!Db {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path.ptr, &db);
        if (rc != c.SQLITE_OK) return DbError.Open;
        _ = c.sqlite3_busy_timeout(db.?, 5000);
        return Db{ .raw = db.? };
    }

    pub fn close(self: Db) void {
        _ = c.sqlite3_close(self.raw);
    }

    pub fn exec(self: Db, sql: [*:0]const u8) DbError!void {
        const rc = c.sqlite3_exec(self.raw, sql, null, null, null);
        if (rc != c.SQLITE_OK) return DbError.Exec;
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
        const CURRENT_SCHEMA: u32 = 5;
        {
            var needs_reset = false;
            var needs_reindex = false;
            {
                const ver_stmt = self.prepare("SELECT value FROM meta WHERE key='schema_version'") catch null;
                if (ver_stmt) |vs| {
                    defer vs.finalize();
                    if (vs.step() catch false) {
                        const stored_str = vs.column_text(0);
                        const stored = std.fmt.parseInt(u32, stored_str, 10) catch 0;
                        if (stored > CURRENT_SCHEMA) needs_reset = true;
                        if (stored < CURRENT_SCHEMA) needs_reindex = true;
                    }
                }
            }
            if (needs_reindex) {
                self.exec("UPDATE files SET mtime=0, content_hash=0") catch |e| {
                    std.fs.File.stderr().writeAll("refract: db reindex: ") catch {};
                    std.fs.File.stderr().writeAll(@errorName(e)) catch {};
                    std.fs.File.stderr().writeAll("\n") catch {};
                };
            }
            if (needs_reset) {
                std.fs.File.stderr().writeAll("refract: resetting DB (schema newer than binary)\n") catch {};
                self.begin() catch |e| {
                    std.fs.File.stderr().writeAll("refract: db reset begin: ") catch {};
                    std.fs.File.stderr().writeAll(@errorName(e)) catch {};
                    std.fs.File.stderr().writeAll("\n") catch {};
                };
                errdefer self.rollback() catch {};
                self.exec("DROP TABLE IF EXISTS sem_tokens") catch {};
                self.exec("DROP TABLE IF EXISTS diagnostics") catch {};
                self.exec("DROP TABLE IF EXISTS mixins") catch {};
                self.exec("DROP TABLE IF EXISTS params") catch {};
                self.exec("DROP TABLE IF EXISTS local_vars") catch {};
                self.exec("DROP TABLE IF EXISTS refs") catch {};
                self.exec("DROP TABLE IF EXISTS routes") catch {};
                self.exec("DROP TABLE IF EXISTS i18n_keys") catch {};
                self.exec("DROP TABLE IF EXISTS aliases") catch {};
                self.exec("DROP TABLE IF EXISTS symbols") catch {};
                self.exec("DROP TABLE IF EXISTS files") catch {};
                self.exec("DROP TABLE IF EXISTS meta") catch {};
                self.commit() catch |e| {
                    std.fs.File.stderr().writeAll("refract: db reset commit: ") catch {};
                    std.fs.File.stderr().writeAll(@errorName(e)) catch {};
                    std.fs.File.stderr().writeAll("\n") catch {};
                };
            }
        }
        try self.exec(
            \\PRAGMA journal_mode=WAL;
            \\PRAGMA wal_autocheckpoint=100;
            \\PRAGMA journal_size_limit=67108864;
            \\PRAGMA synchronous=NORMAL;
            \\PRAGMA cache_size=-32000;
            \\PRAGMA temp_store=MEMORY;
            \\PRAGMA mmap_size=268435456;
            \\PRAGMA busy_timeout=5000;
            \\PRAGMA foreign_keys=ON;
            \\CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
            \\CREATE TABLE IF NOT EXISTS files (
            \\  id    INTEGER PRIMARY KEY,
            \\  path  TEXT NOT NULL UNIQUE,
            \\  mtime INTEGER NOT NULL DEFAULT 0
            \\);
            \\CREATE TABLE IF NOT EXISTS symbols (
            \\  id          INTEGER PRIMARY KEY,
            \\  file_id     INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            \\  name        TEXT NOT NULL,
            \\  kind        TEXT NOT NULL,
            \\  line        INTEGER NOT NULL,
            \\  col         INTEGER NOT NULL,
            \\  return_type TEXT
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name);
            \\CREATE INDEX IF NOT EXISTS idx_symbols_file ON symbols(file_id);
            \\CREATE TABLE IF NOT EXISTS refs (
            \\  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            \\  name    TEXT NOT NULL,
            \\  line    INTEGER NOT NULL,
            \\  col     INTEGER NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_refs_name ON refs(name);
            \\CREATE UNIQUE INDEX IF NOT EXISTS idx_refs_unique
            \\  ON refs(file_id, name, line, col);
            \\CREATE TABLE IF NOT EXISTS params (
            \\  id         INTEGER PRIMARY KEY,
            \\  symbol_id  INTEGER NOT NULL REFERENCES symbols(id) ON DELETE CASCADE,
            \\  position   INTEGER NOT NULL,
            \\  name       TEXT NOT NULL,
            \\  kind       TEXT NOT NULL,
            \\  type_hint  TEXT,
            \\  confidence INTEGER NOT NULL DEFAULT 0
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_params_symbol ON params(symbol_id);
            \\CREATE UNIQUE INDEX IF NOT EXISTS idx_params_unique ON params(symbol_id, position);
            \\CREATE TABLE IF NOT EXISTS local_vars (
            \\  id         INTEGER PRIMARY KEY,
            \\  file_id    INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            \\  name       TEXT NOT NULL,
            \\  line       INTEGER NOT NULL,
            \\  type_hint  TEXT,
            \\  confidence INTEGER NOT NULL DEFAULT 0
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_local_vars_file ON local_vars(file_id);
            \\CREATE INDEX IF NOT EXISTS idx_local_vars_name ON local_vars(name);
            \\CREATE TABLE IF NOT EXISTS sem_tokens (
            \\  file_id    INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
            \\  blob       BLOB NOT NULL
            \\);
        );
        // Migration guard for databases created before return_type was added
        self.execMigration("ALTER TABLE symbols ADD COLUMN return_type TEXT");
        // Migration guard for databases created before col was added to local_vars
        self.execMigration("ALTER TABLE local_vars ADD COLUMN col INTEGER DEFAULT 0");
        // Migration guard for databases created before doc was added to symbols
        self.execMigration("ALTER TABLE symbols ADD COLUMN doc TEXT");
        // Migration guards for scope-aware rename (Phase 7)
        self.execMigration("ALTER TABLE local_vars ADD COLUMN scope_id INTEGER DEFAULT NULL");
        self.execMigration("ALTER TABLE refs ADD COLUMN scope_id INTEGER DEFAULT NULL");
        // Mixins table for include/prepend/extend tracking
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS mixins (
            \\  class_id    INTEGER NOT NULL REFERENCES symbols(id) ON DELETE CASCADE,
            \\  module_name TEXT NOT NULL,
            \\  kind        TEXT NOT NULL
            \\)
        );
        // Diagnostics table (queried by diagnostic_summary, workspace_health, etc.)
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS diagnostics (
            \\  id       INTEGER PRIMARY KEY,
            \\  file_id  INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            \\  line     INTEGER NOT NULL,
            \\  col      INTEGER NOT NULL,
            \\  message  TEXT NOT NULL,
            \\  severity INTEGER NOT NULL DEFAULT 1,
            \\  code     TEXT
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_diagnostics_file ON diagnostics(file_id)") catch {}; // migration
        // i18n keys table (populated by i18n.zig locale file indexer)
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS i18n_keys (
            \\  id      INTEGER PRIMARY KEY,
            \\  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            \\  key     TEXT NOT NULL,
            \\  value   TEXT,
            \\  locale  TEXT
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_i18n_key ON i18n_keys(key)") catch {}; // migration
        // Routes table (populated by routes.zig route parser)
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS routes (
            \\  id             INTEGER PRIMARY KEY,
            \\  file_id        INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            \\  http_method    TEXT NOT NULL,
            \\  path_pattern   TEXT NOT NULL,
            \\  helper_name    TEXT,
            \\  controller     TEXT,
            \\  action         TEXT,
            \\  line           INTEGER NOT NULL,
            \\  col            INTEGER NOT NULL
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_routes_file ON routes(file_id)") catch {}; // migration
        self.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_routes_unique ON routes(file_id, http_method, path_pattern, line)") catch {}; // migration
        // Migration guards for gem indexing (Phase 8)
        self.execMigration("ALTER TABLE files ADD COLUMN is_gem INTEGER NOT NULL DEFAULT 0");
        self.exec("CREATE INDEX IF NOT EXISTS idx_files_isgem ON files(is_gem)") catch {}; // migration
        // Mixin indexes (Phase 8)
        self.exec("CREATE INDEX IF NOT EXISTS idx_mixins_class ON mixins(class_id)") catch {}; // migration
        self.exec("CREATE INDEX IF NOT EXISTS idx_mixins_module ON mixins(module_name)") catch {}; // migration
        self.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_local_vars_unique ON local_vars(file_id, name, line, col)") catch {}; // migration guard: col column may be absent on older schemas
        self.exec("CREATE INDEX IF NOT EXISTS idx_symbols_kind ON symbols(kind)") catch {}; // migration guard: index already exists on migrated schemas
        self.execMigration("ALTER TABLE symbols ADD COLUMN parent_name TEXT"); // migration guard: column already exists on migrated schemas
        self.exec("CREATE INDEX IF NOT EXISTS idx_symbols_parent ON symbols(parent_name)") catch {}; // migration guard: index already exists on migrated schemas
        self.exec("CREATE INDEX IF NOT EXISTS idx_refs_scope ON refs(scope_id)") catch {}; // migration guard: scope_id column may be absent on older schemas
        self.exec("CREATE INDEX IF NOT EXISTS idx_local_vars_scope ON local_vars(scope_id)") catch {}; // migration guard: scope_id column may be absent on older schemas
        self.execMigration("ALTER TABLE symbols ADD COLUMN end_line INTEGER DEFAULT NULL"); // migration guard: column already exists on migrated schemas
        self.execMigration("ALTER TABLE symbols ADD COLUMN visibility TEXT DEFAULT 'public'"); // migration guard: column already exists on migrated schemas
        self.exec("CREATE INDEX IF NOT EXISTS idx_symbols_name_kind ON symbols(name, kind)") catch {}; // migration guard: index already exists on migrated schemas
        self.exec("CREATE INDEX IF NOT EXISTS idx_local_vars_file_name ON local_vars(file_id, name)") catch {}; // migration guard: index already exists on migrated schemas
        self.exec("CREATE INDEX IF NOT EXISTS idx_refs_file_name ON refs(file_id, name)") catch {}; // migration guard: index already exists on migrated schemas
        self.execMigration("ALTER TABLE symbols ADD COLUMN value_snippet TEXT"); // migration guard: column already exists on migrated schemas
        self.exec("CREATE INDEX IF NOT EXISTS idx_symbols_file_kind_name ON symbols(file_id, kind, name)") catch {}; // migration guard: index already exists on migrated schemas
        self.exec("CREATE INDEX IF NOT EXISTS idx_local_vars_file_name_line ON local_vars(file_id, name, line)") catch {}; // migration guard: index already exists on migrated schemas
        self.exec("CREATE INDEX IF NOT EXISTS idx_refs_file_line ON refs(file_id, line)") catch {}; // migration guard: index already exists on migrated schemas
        self.execMigration("ALTER TABLE files ADD COLUMN content_hash INTEGER DEFAULT 0"); // migration guard: column already exists on migrated schemas
        // Partial index for fast workspace-only (non-gem) file lookups used by workspace/symbol
        self.exec("CREATE INDEX IF NOT EXISTS idx_files_workspace ON files(id) WHERE is_gem = 0") catch {}; // migration guard: is_gem column may be absent on older schemas
        self.exec("CREATE INDEX IF NOT EXISTS idx_symbols_file_kind_line ON symbols(file_id, kind, line)") catch {}; // migration guard: index already exists on migrated schemas
        self.execMigration("ALTER TABLE local_vars ADD COLUMN class_id INTEGER DEFAULT NULL"); // migration guard: column already exists on migrated schemas
        self.exec("CREATE INDEX IF NOT EXISTS idx_local_vars_class ON local_vars(class_id)") catch {}; // migration guard: class_id column may be absent on older schemas
        self.execMigration("ALTER TABLE sem_tokens ADD COLUMN prev_blob BLOB"); // migration guard: column already exists on migrated schemas
        self.exec("CREATE INDEX IF NOT EXISTS idx_symbols_return_type ON symbols(return_type) WHERE return_type IS NOT NULL") catch {}; // migration
        // Phase 2: block param marker, composite indexes for query optimization
        self.execMigration("ALTER TABLE local_vars ADD COLUMN is_block_param INTEGER DEFAULT 0");
        self.exec("CREATE INDEX IF NOT EXISTS idx_symbols_name_file ON symbols(name, file_id)") catch {}; // migration
        self.exec("CREATE INDEX IF NOT EXISTS idx_params_symbol_pos ON params(symbol_id, position)") catch {}; // migration
        self.exec("CREATE INDEX IF NOT EXISTS idx_localvars_file_scope ON local_vars(file_id, scope_id)") catch {}; // migration
        // Phase 3: query-optimized composite indexes for symbol lookup and type resolution
        self.exec("CREATE INDEX IF NOT EXISTS idx_local_vars_file_line ON local_vars(file_id, line)") catch {}; // migration
        self.exec("CREATE INDEX IF NOT EXISTS idx_symbols_class_lookup ON symbols(kind, name) WHERE kind IN ('class','module','classdef')") catch {}; // migration
        try self.exec("INSERT OR REPLACE INTO meta(key,value) VALUES('schema_version','5')");
        const final_ver = self.getSchemaVersion() orelse 0;
        if (final_ver != 5) {
            std.fs.File.stderr().writeAll("refract: schema migration incomplete; run --reset-db\n") catch {};
        }
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

    fn execMigration(self: Db, sql: [*:0]const u8) void {
        self.exec(sql) catch {
            const errmsg = std.mem.span(c.sqlite3_errmsg(self.raw));
            if (std.mem.indexOf(u8, errmsg, "duplicate column name") != null) return;
            if (std.mem.indexOf(u8, errmsg, "already exists") != null) return;
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "refract: DB migration warning: {s}\n", .{errmsg}) catch "refract: DB migration warning\n";
            std.fs.File.stderr().writeAll(msg) catch {};
        };
    }

    pub fn checkpoint(self: Db) void {
        self.exec("PRAGMA wal_checkpoint(TRUNCATE)") catch {}; // maintenance
    }

    pub fn check_integrity(self: Db) DbError!void {
        const stmt = try self.prepare("PRAGMA quick_check");
        defer stmt.finalize();
        if (try stmt.step()) {
            if (!std.mem.eql(u8, stmt.column_text(0), "ok")) return DbError.Exec;
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

test "getSchemaVersion returns current version" {
    const db = try Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    const ver = db.getSchemaVersion() orelse 0;
    try std.testing.expectEqual(@as(i64, 5), ver);
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
