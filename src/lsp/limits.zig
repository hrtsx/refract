// Single audit surface for all hardcoded resource caps in refract. New caps
// land here, not scattered as inline constants. The bench-scale + soak
// workflows assert against these so a drive-by raise in some other file shows
// up in CI before it ships.

/// Single LSP / DAP / MCP JSON-RPC message body size (Content-Length).
pub const MAX_MESSAGE_BYTES: usize = 16 * 1024 * 1024;

/// Maximum `didChange` text payload — mirrors MAX_MESSAGE_BYTES to keep
/// reasoning about transport bounds simple.
pub const MAX_DID_CHANGE_TEXT_BYTES: usize = 16 * 1024 * 1024;

/// Open-document cache (LRU). Beyond this, eldest entry is evicted.
pub const OPEN_DOC_CACHE_SIZE: usize = 200;

/// Background incremental indexer queue (per-server) and deleted-paths buffer.
pub const INCREMENTAL_QUEUE_CAP: usize = 10_000;
pub const DELETED_PATHS_BUFFER_CAP: usize = 10_000;

/// RuboCop result cache (path → mtime + diagnostics).
pub const RUBOCOP_MTIME_CACHE_SIZE: usize = 512;

/// Worker thread pool (indexer). Clamped to [1, MAX_WORKERS_HARD_CAP] in main.
pub const MAX_WORKERS_HARD_CAP: u32 = 16;

/// Default cold-index worker count. The parallel pool (indexPathsViaWorkers) is
/// used only by first-index passes (workspace cold-index, gem-index, rbs); the
/// incremental single-file reindex loop is separate and unaffected. N workers ×
/// (arena + in-mem SQLite) is the dominant term of the one-time first-index RSS
/// spike, so a lower default trades first-index wall-time for a smaller spike.
/// `--max-workers N` overrides this upward for users who want the old speed.
pub const DEFAULT_COLD_INDEX_WORKERS: usize = 4;

/// Cold-index RAM controls. Each parallel worker holds a parse arena plus a
/// per-worker in-memory SQLite; left unchecked their high-water is retained for
/// the worker's lifetime, so N workers × biggest-file footprint is the transient
/// peak RSS during a cold index. These bound that footprint without serializing
/// the workers (they stay parallel — only their retained capacity is trimmed).
///
/// Trim cadence, in files processed per worker: at each boundary the worker
/// frees its arena high-water, compacts its in-memory DB, and (on commit count)
/// checkpoints the shared WAL so it can't balloon to the full index size.
pub const RSS_TRIM_BATCH: usize = 64;

/// Per-worker arena high-water ceiling. Independent of the batch cadence: a
/// single pathological file that pushes the arena past this frees immediately.
/// N workers × this cap is the arena share of the cold-index transient peak.
pub const WORKER_ARENA_CAP_BYTES: usize = 2 * 1024 * 1024;

/// Conservative per-worker resident estimate (arena cap + in-mem DB + overhead)
/// used to derive a memory-aware worker count on constrained hosts. Only lowers
/// the pool below the CPU/`--max-workers` bound when available RAM is scarce.
pub const PER_WORKER_RAM_ESTIMATE_BYTES: usize = 24 * 1024 * 1024;

/// SQLite `mmap_size` on the writer connection. mmap-mapped DB pages count in
/// process RSS, so a 256 MB cap made the whole DB resident on symbol-dense repos
/// (a 180 MB index → 180 MB RSS on top of everything else). The LSP query path
/// runs on a separate read-only connection that never sets mmap (SQLite default
/// 0), so capping the writer's mmap trades only cold-index read locality, not
/// hot-query latency. 64 MB keeps the hot pages mapped while the OS page cache
/// (shared, reclaimable, not per-process anon RSS) backs the cold tail.
pub const DB_MMAP_SIZE_BYTES: usize = 16 * 1024 * 1024;

/// Default file-size budget for indexing; tunable via `maxFileSizeMb`.
pub const DEFAULT_MAX_FILE_SIZE_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_FILE_SIZE_BYTES_CEILING: usize = 2 * 1024 * 1024 * 1024;

/// `.refractrc.json` parse budget.
pub const MAX_CONFIG_BYTES: usize = 256 * 1024;

/// Lockfile / disabled-codes / per-file utility budgets.
pub const MAX_DISABLED_CODES_BYTES: usize = 256 * 1024;
pub const MAX_GEMFILE_LOCK_BYTES: usize = 1 * 1024 * 1024;

/// Server log file rolling ceiling.
pub const LOG_FILE_SIZE_LIMIT: usize = 10 * 1024 * 1024;

/// MCP per-file read budget (resource access).
pub const MCP_FILE_READ_LIMIT: usize = 8 * 1024 * 1024;

/// Secret-redactor per-value length cap (longer values aren't scanned).
pub const REDACT_MAX_VALUE_LEN: usize = 8 * 1024;

/// Audit-log sample buffer per LSP method (OTLP exporter).
pub const AUDIT_MAX_SAMPLES_PER_METHOD: usize = 4096;

/// Completion result list cap (per request). Beyond this, `isIncomplete=true`.
pub const COMPLETION_RESULT_CAP: usize = 200;

/// Definition response cap (per request). Defends the cold-SQL path against
/// pathological symbols with thousands of overloads.
pub const DEFINITION_RESULT_CAP: usize = 20;

/// Plugin manifest size cap (`refract-extension.json`).
pub const MAX_PLUGIN_MANIFEST_BYTES: usize = 256 * 1024;

/// Hot-index pre-rendered cache size (top-N most-referenced symbols).
pub const PRE_RENDER_TOP_N: usize = 1000;

/// Background work queue throttle. Beyond this, error notifications are
/// rate-limited to 1 per RATE_LIMIT_WINDOW_SEC.
pub const WORK_QUEUE_CAP: usize = 50_000;
pub const RATE_LIMIT_WINDOW_SEC: u64 = 30;

test "limits module compiles" {
    const std = @import("std");
    try std.testing.expect(MAX_MESSAGE_BYTES > 0);
}
