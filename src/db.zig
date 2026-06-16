const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

extern fn refract_bind_text(stmt: *c.sqlite3_stmt, col: c_int, ptr: [*]const u8, len: c_int) c_int;
extern fn refract_bind_blob(stmt: *c.sqlite3_stmt, col: c_int, ptr: ?*const anyopaque, len: c_int) c_int;

pub const CURRENT_SCHEMA: u32 = 13;

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
        const profiling = std.c.getenv("REFRACT_INIT_PROFILE") != null;
        const schema_start = if (profiling) std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() else 0;
        var needs_reindex = false;
        {
            var needs_reset = false;
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
                    std.debug.print("{s}", .{"refract: db reindex: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
                };
            }
            if (needs_reset) {
                std.debug.print("{s}", .{"refract: resetting DB (schema newer than binary)\n"});
                self.begin() catch |e| {
                    std.debug.print("{s}", .{"refract: db reset begin: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
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
                self.exec("DROP TABLE IF EXISTS type_oracle") catch {};
                self.exec("DROP TABLE IF EXISTS doc_blocks") catch {};
                self.exec("DROP TABLE IF EXISTS perf_metrics") catch {};
                self.exec("DROP TABLE IF EXISTS audit_log") catch {};
                self.exec("DROP TABLE IF EXISTS deprecations") catch {};
                self.exec("DROP TABLE IF EXISTS gem_versions") catch {};
                self.exec("DROP TABLE IF EXISTS worktree") catch {};
                self.exec("DROP TABLE IF EXISTS sorbet_results") catch {};
                self.exec("DROP TABLE IF EXISTS steep_results") catch {};
                self.exec("DROP TABLE IF EXISTS coverage_lines") catch {};
                self.exec("DROP TABLE IF EXISTS brakeman_findings") catch {};
                self.exec("DROP TABLE IF EXISTS semgrep_findings") catch {};
                self.exec("DROP TABLE IF EXISTS plugin_state") catch {};
                self.exec("DROP TABLE IF EXISTS runs") catch {};
                self.exec("DROP TABLE IF EXISTS symbols") catch {};
                self.exec("DROP TABLE IF EXISTS files") catch {};
                self.exec("DROP TABLE IF EXISTS meta") catch {};
                self.commit() catch |e| {
                    std.debug.print("{s}", .{"refract: db reset commit: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
                };
            }
        }
        try self.execLogged(
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
            \\  col     INTEGER NOT NULL,
            \\  kind    TEXT
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
        // Type-checker columns: call sites only — non-call refs leave these defaulted.
        self.execMigration("ALTER TABLE refs ADD COLUMN arg_count INTEGER DEFAULT 0");
        self.execMigration("ALTER TABLE refs ADD COLUMN receiver_type TEXT");
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
        self.exec("CREATE INDEX IF NOT EXISTS idx_i18n_keys_file ON i18n_keys(file_id)") catch {}; // per-file reindex DELETEs by file_id; without this they full-scan (O(n^2) index on i18n-heavy repos)
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
        self.exec("CREATE INDEX IF NOT EXISTS idx_routes_helper ON routes(helper_name)") catch {}; // migration: route-helper go-to-def looks up by helper_name
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
        self.exec("CREATE INDEX IF NOT EXISTS idx_refs_name_scope ON refs(name, scope_id)") catch {}; // cross-file references-by-scope (navigation.zig: WHERE name=? AND scope_id=?)
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
        self.exec("CREATE INDEX IF NOT EXISTS idx_local_vars_class_name ON local_vars(class_id, name)") catch {}; // migration: helps completion.zig:287 instance-variable lookup
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
        // Schema v13: trigram FTS over symbol names. workspace_symbols substring
        // search ('%q%') cannot use the B-tree name index (leading wildcard) and
        // full-scans the symbols table; trigram FTS makes it index-backed. External
        // content (no name copy); AFTER INSERT/DELETE triggers mirror every symbol
        // write — including per-file reindex DELETE/INSERT — so the index path needs
        // no changes. Queries < 3 chars (trigram floor) fall back to LIKE.
        self.exec("CREATE VIRTUAL TABLE IF NOT EXISTS symbols_fts USING fts5(name, content='symbols', content_rowid='id', tokenize='trigram')") catch {};
        self.exec(
            \\CREATE TRIGGER IF NOT EXISTS symbols_ai AFTER INSERT ON symbols BEGIN
            \\  INSERT INTO symbols_fts(rowid, name) VALUES (new.id, new.name);
            \\END
        ) catch {};
        self.exec(
            \\CREATE TRIGGER IF NOT EXISTS symbols_ad AFTER DELETE ON symbols BEGIN
            \\  INSERT INTO symbols_fts(symbols_fts, rowid, name) VALUES ('delete', old.id, old.name);
            \\END
        ) catch {};
        // Backfill once when migrating an existing index (stored schema < v13): the
        // forced reindex would eventually repopulate via triggers, but seed now so
        // substring search works before the next index pass completes.
        if (needs_reindex) self.exec("INSERT INTO symbols_fts(rowid, name) SELECT id, name FROM symbols") catch {};
        // Phase 4: YARD @param description text (text after [Type] in @param tags)
        self.execMigration("ALTER TABLE params ADD COLUMN description TEXT"); // migration guard: column already exists on migrated schemas
        // Schema v6: type_oracle, doc_blocks, perf_metrics, audit_log, deprecations, gem_versions, worktree
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS worktree (
            \\  id            INTEGER PRIMARY KEY,
            \\  workspace_uri TEXT NOT NULL UNIQUE,
            \\  root_path     TEXT NOT NULL,
            \\  gemfile_path  TEXT,
            \\  ruby_version  TEXT,
            \\  is_primary    INTEGER NOT NULL DEFAULT 0,
            \\  created_at    INTEGER NOT NULL DEFAULT 0
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_worktree_root ON worktree(root_path)") catch {};
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS type_oracle (
            \\  id          INTEGER PRIMARY KEY,
            \\  fqn         TEXT NOT NULL,
            \\  method_name TEXT,
            \\  param_pos   INTEGER NOT NULL DEFAULT -1,
            \\  type_str    TEXT NOT NULL,
            \\  source      TEXT NOT NULL,
            \\  confidence  INTEGER NOT NULL DEFAULT 100
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_type_oracle_fqn ON type_oracle(fqn)") catch {};
        self.exec("CREATE INDEX IF NOT EXISTS idx_type_oracle_lookup ON type_oracle(fqn, method_name, param_pos)") catch {};
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS doc_blocks (
            \\  id          INTEGER PRIMARY KEY,
            \\  symbol_id   INTEGER NOT NULL REFERENCES symbols(id) ON DELETE CASCADE,
            \\  kind        TEXT NOT NULL,
            \\  raw         TEXT NOT NULL,
            \\  rendered    TEXT,
            \\  params_json TEXT,
            \\  return_type TEXT,
            \\  return_desc TEXT
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_doc_blocks_symbol ON doc_blocks(symbol_id)") catch {};
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS perf_metrics (
            \\  id           INTEGER PRIMARY KEY,
            \\  method       TEXT NOT NULL,
            \\  p50_us       INTEGER NOT NULL,
            \\  p95_us       INTEGER NOT NULL,
            \\  count        INTEGER NOT NULL,
            \\  window_start INTEGER NOT NULL,
            \\  window_end   INTEGER NOT NULL
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_perf_metrics_method ON perf_metrics(method, window_end)") catch {};
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS audit_log (
            \\  id          INTEGER PRIMARY KEY,
            \\  ts_us       INTEGER NOT NULL,
            \\  tool_name   TEXT NOT NULL,
            \\  request_id  TEXT,
            \\  args_json   TEXT,
            \\  result_kind TEXT NOT NULL,
            \\  duration_us INTEGER NOT NULL DEFAULT 0
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_audit_log_ts ON audit_log(ts_us)") catch {};
        self.exec("CREATE INDEX IF NOT EXISTS idx_audit_log_tool ON audit_log(tool_name, ts_us)") catch {};
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS deprecations (
            \\  id           INTEGER PRIMARY KEY,
            \\  gem_name     TEXT NOT NULL,
            \\  version_spec TEXT NOT NULL,
            \\  symbol_fqn   TEXT,
            \\  message      TEXT NOT NULL,
            \\  replacement  TEXT,
            \\  cve_id       TEXT
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_deprecations_gem ON deprecations(gem_name)") catch {};
        self.exec("CREATE INDEX IF NOT EXISTS idx_deprecations_symbol ON deprecations(symbol_fqn)") catch {};
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS gem_versions (
            \\  id           INTEGER PRIMARY KEY,
            \\  workspace_id INTEGER REFERENCES worktree(id) ON DELETE CASCADE,
            \\  gem_name     TEXT NOT NULL,
            \\  version      TEXT NOT NULL,
            \\  loaded_at    INTEGER NOT NULL,
            \\  source       TEXT
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_gem_versions_ws_gem ON gem_versions(workspace_id, gem_name)") catch {};
        self.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_gem_versions_unique ON gem_versions(COALESCE(workspace_id,0), gem_name)") catch {};

        // Schema v7: type-bridge results, coverage, security/lint findings, plugin state, subprocess runs
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS runs (
            \\  run_id      INTEGER PRIMARY KEY,
            \\  kind        TEXT NOT NULL,
            \\  started_at  INTEGER NOT NULL,
            \\  ended_at    INTEGER,
            \\  exit_code   INTEGER,
            \\  stderr_tail TEXT
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_runs_kind_started ON runs(kind, started_at)") catch {};

        try self.exec(
            \\CREATE TABLE IF NOT EXISTS sorbet_results (
            \\  id           INTEGER PRIMARY KEY,
            \\  workspace_id INTEGER REFERENCES worktree(id) ON DELETE CASCADE,
            \\  symbol_id    INTEGER REFERENCES symbols(id) ON DELETE CASCADE,
            \\  fqn          TEXT,
            \\  kind         TEXT NOT NULL,
            \\  type_str     TEXT NOT NULL,
            \\  source       TEXT NOT NULL,
            \\  confidence   INTEGER NOT NULL DEFAULT 100,
            \\  run_id       INTEGER REFERENCES runs(run_id) ON DELETE SET NULL,
            \\  ts_us        INTEGER NOT NULL
            \\)
        );
        self.execMigration("ALTER TABLE sorbet_results ADD COLUMN workspace_id INTEGER REFERENCES worktree(id) ON DELETE CASCADE");
        self.exec("CREATE INDEX IF NOT EXISTS idx_sorbet_results_symbol ON sorbet_results(symbol_id)") catch {};
        self.exec("CREATE INDEX IF NOT EXISTS idx_sorbet_results_fqn ON sorbet_results(fqn)") catch {};
        self.exec("CREATE INDEX IF NOT EXISTS idx_sorbet_results_ws ON sorbet_results(workspace_id, fqn)") catch {};

        try self.exec(
            \\CREATE TABLE IF NOT EXISTS steep_results (
            \\  id           INTEGER PRIMARY KEY,
            \\  workspace_id INTEGER REFERENCES worktree(id) ON DELETE CASCADE,
            \\  symbol_id    INTEGER REFERENCES symbols(id) ON DELETE CASCADE,
            \\  fqn          TEXT,
            \\  kind         TEXT NOT NULL,
            \\  type_str     TEXT NOT NULL,
            \\  source       TEXT NOT NULL,
            \\  confidence   INTEGER NOT NULL DEFAULT 100,
            \\  run_id       INTEGER REFERENCES runs(run_id) ON DELETE SET NULL,
            \\  ts_us        INTEGER NOT NULL
            \\)
        );
        self.execMigration("ALTER TABLE steep_results ADD COLUMN workspace_id INTEGER REFERENCES worktree(id) ON DELETE CASCADE");
        self.exec("CREATE INDEX IF NOT EXISTS idx_steep_results_symbol ON steep_results(symbol_id)") catch {};
        self.exec("CREATE INDEX IF NOT EXISTS idx_steep_results_fqn ON steep_results(fqn)") catch {};
        self.exec("CREATE INDEX IF NOT EXISTS idx_steep_results_ws ON steep_results(workspace_id, fqn)") catch {};

        try self.exec(
            \\CREATE TABLE IF NOT EXISTS coverage_lines (
            \\  id           INTEGER PRIMARY KEY,
            \\  workspace_id INTEGER REFERENCES worktree(id) ON DELETE CASCADE,
            \\  file_id      INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            \\  line         INTEGER NOT NULL,
            \\  hits         INTEGER NOT NULL,
            \\  run_id       INTEGER REFERENCES runs(run_id) ON DELETE SET NULL,
            \\  ts_us        INTEGER NOT NULL
            \\)
        );
        self.execMigration("ALTER TABLE coverage_lines ADD COLUMN workspace_id INTEGER REFERENCES worktree(id) ON DELETE CASCADE");
        self.exec("CREATE INDEX IF NOT EXISTS idx_coverage_lines_file ON coverage_lines(file_id, line)") catch {};
        self.exec("CREATE INDEX IF NOT EXISTS idx_coverage_lines_ws ON coverage_lines(workspace_id, file_id)") catch {};

        try self.exec(
            \\CREATE TABLE IF NOT EXISTS brakeman_findings (
            \\  id          INTEGER PRIMARY KEY,
            \\  file_id     INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            \\  line        INTEGER NOT NULL,
            \\  code        TEXT NOT NULL,
            \\  severity    INTEGER NOT NULL,
            \\  message     TEXT NOT NULL,
            \\  fingerprint TEXT,
            \\  run_id      INTEGER REFERENCES runs(run_id) ON DELETE SET NULL,
            \\  ts_us       INTEGER NOT NULL
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_brakeman_file ON brakeman_findings(file_id)") catch {};
        self.exec("CREATE INDEX IF NOT EXISTS idx_brakeman_fingerprint ON brakeman_findings(fingerprint)") catch {};

        try self.exec(
            \\CREATE TABLE IF NOT EXISTS semgrep_findings (
            \\  id          INTEGER PRIMARY KEY,
            \\  file_id     INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            \\  line        INTEGER NOT NULL,
            \\  rule_id     TEXT NOT NULL,
            \\  severity    INTEGER NOT NULL,
            \\  message     TEXT NOT NULL,
            \\  fingerprint TEXT,
            \\  run_id      INTEGER REFERENCES runs(run_id) ON DELETE SET NULL,
            \\  ts_us       INTEGER NOT NULL
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_semgrep_file ON semgrep_findings(file_id)") catch {};
        self.exec("CREATE INDEX IF NOT EXISTS idx_semgrep_fingerprint ON semgrep_findings(fingerprint)") catch {};

        try self.exec(
            \\CREATE TABLE IF NOT EXISTS plugin_state (
            \\  id        INTEGER PRIMARY KEY,
            \\  plugin_id TEXT NOT NULL,
            \\  key       TEXT NOT NULL,
            \\  value     TEXT,
            \\  ts_us     INTEGER NOT NULL
            \\)
        );
        self.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_plugin_state_unique ON plugin_state(plugin_id, key)") catch {};

        // Schema v12: agent/user-writable OVERLAY layer. The only mutable graph
        // surface — derived tables stay source-immutable. Rows reference derived
        // symbols by fqn string (stable across reindex), never by symbols.id.
        // Keyed by (project_id, branch): branch IS NULL = project-global. History
        // model — no UNIQUE; reads take MAX(created_at) WHERE revoked_at IS NULL,
        // revert soft-deletes by setting revoked_at. Every row carries source
        // ('AGENT'|'USER'), confidence, and a required reason for audit.
        // NOTE: overlay_* are deliberately absent from the needs_reset DROP list
        // above — a newer-db/older-binary downgrade must never destroy tweaks.
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS overlay_nodes (
            \\  id          INTEGER PRIMARY KEY,
            \\  project_id  TEXT NOT NULL,
            \\  branch      TEXT,
            \\  fqn         TEXT NOT NULL,
            \\  kind        TEXT NOT NULL,
            \\  label       TEXT,
            \\  content     TEXT,
            \\  source      TEXT NOT NULL,
            \\  confidence  INTEGER NOT NULL DEFAULT 100,
            \\  reason      TEXT NOT NULL,
            \\  created_at  INTEGER NOT NULL,
            \\  revoked_at  INTEGER
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_overlay_nodes_scope ON overlay_nodes(project_id, branch)") catch {};
        self.exec("CREATE INDEX IF NOT EXISTS idx_overlay_nodes_fqn ON overlay_nodes(fqn)") catch {};
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS overlay_edges (
            \\  id          INTEGER PRIMARY KEY,
            \\  project_id  TEXT NOT NULL,
            \\  branch      TEXT,
            \\  from_fqn    TEXT NOT NULL,
            \\  to_fqn      TEXT NOT NULL,
            \\  kind        TEXT NOT NULL,
            \\  label       TEXT,
            \\  source      TEXT NOT NULL,
            \\  confidence  INTEGER NOT NULL DEFAULT 100,
            \\  reason      TEXT NOT NULL,
            \\  created_at  INTEGER NOT NULL,
            \\  revoked_at  INTEGER
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_overlay_edges_scope ON overlay_edges(project_id, branch)") catch {};
        self.exec("CREATE INDEX IF NOT EXISTS idx_overlay_edges_from ON overlay_edges(from_fqn)") catch {};
        self.exec("CREATE INDEX IF NOT EXISTS idx_overlay_edges_to ON overlay_edges(to_fqn)") catch {};
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS overlay_types (
            \\  id          INTEGER PRIMARY KEY,
            \\  project_id  TEXT NOT NULL,
            \\  branch      TEXT,
            \\  fqn         TEXT NOT NULL,
            \\  method_name TEXT,
            \\  param_pos   INTEGER NOT NULL DEFAULT -1,
            \\  type_str    TEXT NOT NULL,
            \\  source      TEXT NOT NULL,
            \\  confidence  INTEGER NOT NULL DEFAULT 100,
            \\  reason      TEXT NOT NULL,
            \\  created_at  INTEGER NOT NULL,
            \\  revoked_at  INTEGER
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_overlay_types_scope ON overlay_types(project_id, branch)") catch {};
        self.exec("CREATE INDEX IF NOT EXISTS idx_overlay_types_lookup ON overlay_types(project_id, fqn, method_name, param_pos)") catch {};
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS overlay_suppress (
            \\  id          INTEGER PRIMARY KEY,
            \\  project_id  TEXT NOT NULL,
            \\  branch      TEXT,
            \\  fqn         TEXT,
            \\  file_path   TEXT,
            \\  diag_code   TEXT NOT NULL,
            \\  line        INTEGER,
            \\  source      TEXT NOT NULL,
            \\  confidence  INTEGER NOT NULL DEFAULT 100,
            \\  reason      TEXT NOT NULL,
            \\  created_at  INTEGER NOT NULL,
            \\  revoked_at  INTEGER
            \\)
        );
        self.exec("CREATE INDEX IF NOT EXISTS idx_overlay_suppress_scope ON overlay_suppress(project_id, branch)") catch {};
        self.exec("CREATE INDEX IF NOT EXISTS idx_overlay_suppress_diag ON overlay_suppress(diag_code)") catch {};
        // Overlay-write audit trail: which fqn a tool call mutated.
        self.execMigration("ALTER TABLE audit_log ADD COLUMN affected_fqn TEXT");

        // Wave-3 unified type-resolution view. Merges sorbet_results,
        // steep_results, and type_oracle behind a single relation tagged with
        // `source` and `confidence`. The reader queries this view instead of
        // each table individually.
        self.exec("DROP VIEW IF EXISTS type_resolution") catch {};
        try self.exec(
            \\CREATE VIEW type_resolution AS
            \\SELECT workspace_id, fqn, NULL AS method_name, -1 AS param_pos,
            \\       type_str, 'sorbet' AS source, confidence, ts_us
            \\FROM sorbet_results
            \\UNION ALL
            \\SELECT workspace_id, fqn, NULL, -1, type_str, 'steep',
            \\       confidence, ts_us
            \\FROM steep_results
            \\UNION ALL
            \\SELECT NULL AS workspace_id, fqn, method_name, param_pos,
            \\       type_str, source, confidence, 0 AS ts_us
            \\FROM type_oracle
        );

        // Schema v8: refs.kind column for filtering by reference type
        self.execMigration("ALTER TABLE refs ADD COLUMN kind TEXT"); // migration guard: column already exists on migrated schemas

        // Schema v10: symbols.superclass records a class's resolved superclass for
        // ALL classes (parent_name only carried it for top-level ones). Lets the
        // ancestry walk follow real inheritance and recognise external/unindexed
        // bases (so a self-send into an inherited-from-a-gem method is not flagged).
        self.execMigration("ALTER TABLE symbols ADD COLUMN superclass TEXT"); // migration guard: column already exists on migrated schemas
        self.exec("CREATE INDEX IF NOT EXISTS idx_symbols_superclass ON symbols(superclass)") catch {};

        // Schema v11: refs.def_id links a method/constant ref to the symbols.id it
        // resolves to (populated by resolveRefsForFile). Lets references/rename query
        // a single binding instead of every same-named token. NULL = unresolved →
        // handlers fall back to name-global matching.
        self.execMigration("ALTER TABLE refs ADD COLUMN def_id INTEGER DEFAULT NULL");
        self.exec("CREATE INDEX IF NOT EXISTS idx_refs_def ON refs(def_id)") catch {}; // migration guard: def_id column may be absent on older schemas

        // Stamp the current schema version. Derived from CURRENT_SCHEMA so a bump
        // can't drift from a hardcoded literal (the v12->v13 trigger relies on it).
        var ver_buf: [96]u8 = undefined;
        const ver_sql = std.fmt.bufPrintZ(&ver_buf, "INSERT OR REPLACE INTO meta(key,value) VALUES('schema_version','{d}')", .{CURRENT_SCHEMA}) catch return DbError.Exec;
        try self.exec(ver_sql);
        const final_ver = self.getSchemaVersion() orelse 0;
        if (final_ver != @as(i64, CURRENT_SCHEMA)) {
            std.debug.print("{s}", .{"refract: schema migration incomplete; run --reset-db\n"});
        }
        if (profiling) {
            const schema_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() - schema_start;
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "refract_profile: init_schema={d}ms\n", .{schema_ms}) catch "";
            if (msg.len > 0) std.debug.print("{s}", .{msg});
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

    pub fn changes(self: Db) i64 {
        return c.sqlite3_changes(self.raw);
    }

    fn execMigration(self: Db, sql: [*:0]const u8) void {
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

test "schema v8 tables present" {
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

test "schema v8 runs/sorbet round-trip" {
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

test "schema v8 type_resolution view unifies bridge + oracle rows" {
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

test "schema v7 plugin_state unique key per plugin" {
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
