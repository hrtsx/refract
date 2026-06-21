const std = @import("std");
const db_mod = @import("../db.zig");
const Db = db_mod.Db;
const DbError = db_mod.DbError;
const CURRENT_SCHEMA = db_mod.CURRENT_SCHEMA;

pub fn init(self: Db) DbError!void {
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
    // Schema v6: trigram FTS over symbol names. workspace_symbols substring
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
    // Schema v2: type_oracle, perf_metrics, audit_log, worktree
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

    // Schema v3: type-bridge results, coverage, security/lint findings, plugin state, subprocess runs
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

    // Schema v6: agent/user-writable OVERLAY layer. The only mutable graph
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

    // Schema v4: refs.kind column for filtering by reference type
    self.execMigration("ALTER TABLE refs ADD COLUMN kind TEXT"); // migration guard: column already exists on migrated schemas

    // Schema v5: symbols.superclass records a class's resolved superclass for
    // ALL classes (parent_name only carried it for top-level ones). Lets the
    // ancestry walk follow real inheritance and recognise external/unindexed
    // bases (so a self-send into an inherited-from-a-gem method is not flagged).
    self.execMigration("ALTER TABLE symbols ADD COLUMN superclass TEXT"); // migration guard: column already exists on migrated schemas
    self.exec("CREATE INDEX IF NOT EXISTS idx_symbols_superclass ON symbols(superclass)") catch {};

    // Schema v5: refs.def_id links a method/constant ref to the symbols.id it
    // resolves to (populated by resolveRefsForFile). Lets references/rename query
    // a single binding instead of every same-named token. NULL = unresolved →
    // handlers fall back to name-global matching.
    self.execMigration("ALTER TABLE refs ADD COLUMN def_id INTEGER DEFAULT NULL");
    self.exec("CREATE INDEX IF NOT EXISTS idx_refs_def ON refs(def_id)") catch {}; // migration guard: def_id column may be absent on older schemas

    // Schema v7: refs.ref_ns records the enclosing lexical nesting at a constant
    // ref site (e.g. "A::B" for a bare `CONST` read inside module A; class B).
    // NULL at top level. Lets resolveConstantNested walk Ruby's real constant
    // lookup (current scope -> enclosing scopes -> ancestors -> top-level) instead
    // of name-global matching, so same-named constants in different namespaces
    // resolve to the correct binding. Old rows lack it -> the v<14 reindex repopulates.
    self.execMigration("ALTER TABLE refs ADD COLUMN ref_ns TEXT"); // migration guard: column already exists on migrated schemas
    self.exec("CREATE INDEX IF NOT EXISTS idx_refs_ns ON refs(ref_ns)") catch {}; // migration guard: ref_ns column may be absent on older schemas

    // Schema v7: symbols.deprecated flags a definition carrying a YARD @deprecated
    // tag (detected from its doc at index time). Surfaced in hover so agents/humans
    // see the warning without re-reading the doc. 0 = not deprecated.
    self.execMigration("ALTER TABLE symbols ADD COLUMN deprecated INTEGER DEFAULT 0"); // migration guard: column already exists on migrated schemas

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
