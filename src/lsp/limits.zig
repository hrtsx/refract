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
