# Refract Architecture

## Overview

Refract is a Ruby LSP server written in Zig. It uses SQLite as a durable symbol index and communicates over JSON-RPC 2.0 via stdio (LSP) or a separate stdio MCP server process.

```
                  ┌─────────────┐
   Editor         │  extension  │
   (VS Code etc)  └──────┬──────┘
                         │ JSON-RPC/stdio
                  ┌──────▼──────┐
                  │  LSP Server │  ◄─── main.zig entry point
                  │  (server.zig│
                  └──────┬──────┘
                         │ SQLite
                  ┌──────▼──────┐
                  │  Index DB   │  ~/.local/share/refract/<workspace>.db
                  └─────────────┘
```

---

## Threading Model

Three concurrent threads in the LSP server:

| Thread | Responsibility |
|--------|----------------|
| **Main** | JSON-RPC request dispatch; reads stdin, writes stdout |
| **Background indexer** (`BgCtx`) | Initial workspace scan + incremental reindex watch loop |
| **RuboCop worker** (`rubocopWorkerFn`) | Async RuboCop diagnostics queue |

**Locking:**
- `db_mutex` — guards all DB reads/writes (single SQLite connection, WAL mode)
- `open_docs_mu` — guards the in-memory open-document map
- `rubocop_queue_mu` — guards the pending RuboCop path set
- `incr_paths_mu` — guards the incremental reindex queue

**Safety pattern:** The background indexer parses files in parallel into per-worker in-memory SQLite DBs (no lock contention), then merges under `db_mutex` in a single transaction.

---

## Indexing Pipeline

```
scanWithNegations()          # filesystem scan, .gitignore-aware
    │
    ├─ filter open docs       # don't race with live edits
    ├─ filter deleted paths
    │
    ▼
reindex(db, paths, …)        # per-file pipeline
    │
    ├─ stat() mtime + content hash → skip unchanged files
    ├─ Prism parse            # Ruby AST via libprism
    ├─ visitor()              # AST walk, extracts:
    │   ├─ symbols (class, module, def, constant, …)
    │   ├─ params (with YARD @param type hints)
    │   ├─ local_vars (with type inference)
    │   ├─ refs (call sites)
    │   ├─ mixins (include/prepend/extend)
    │   ├─ routes, associations, validations, callbacks
    │   └─ semantic tokens
    └─ commit() to SQLite
```

### Incremental Reindex

After the initial workspace index, `BgCtx` enters a **200ms poll loop** watching `incr_paths` — a queue populated by `didChangeWatchedFiles` notifications. Each batch is reindexed under `db_mutex`.

---

## Type Inference

Types are resolved through a multi-source chain (highest confidence wins):

```
1. RBS signatures        (.rbs / .rbi files)         confidence = 90
2. YARD @return/@param   (doc comments)               confidence = 0  (but explicit)
3. Literal types         (String, Integer, Hash, …)  inferred from AST
4. Method chain          (up to 5 levels deep)        confidence decays with depth
5. Type narrowing        (if x, unless x.nil?, …)    scope-aware
```

Union types (`String | Integer`) are tracked. Generic element types (`Array[User]`) are extracted for receiver-aware completion.

**Confidence threshold:** Parameter types are shown in hover only if `confidence >= 50`.

---

## Database Schema (25 tables, key relationships)

```
files (id, path, mtime, content_hash, is_gem)
  │
  ├─ symbols (id, file_id, name, kind, line, col, end_line,
  │           return_type, doc, parent_name, visibility, value_snippet)
  │    └─ params (id, symbol_id, position, name, kind,
  │               type_hint, confidence, description)
  │
  ├─ local_vars (id, file_id, name, line, col, scope_id,
  │              type_hint, confidence, class_id, is_block_param)
  │
  ├─ refs (id, file_id, name, line, col, scope_id)
  ├─ mixins (class_id, module_name, kind)
  ├─ sem_tokens (file_id, blob, prev_blob)
  ├─ routes (file_id, http_method, path_pattern, helper_name, …)
  ├─ i18n_keys (key, value, locale, file_id)
  ├─ diagnostics (file_id, …)
  └─ meta (key, value)         ← schema_version, gemfile_lock_mtime, …
```

**Migrations:** New columns are added via `execMigration("ALTER TABLE … ADD COLUMN … DEFAULT …")` guards — idempotent, safe to run on existing databases.

**Schema version:** Currently `5`. A version mismatch (binary newer than DB) triggers automatic schema migration; a version mismatch (DB newer than binary) triggers a `--reset-db` prompt.

---

## LSP Request Dispatch

```
stdin → JSON-RPC frame (Content-Length header)
      → parseRequest()
      → isCancelled() check
      → route by method name:
            initialize         → handleInitialize()
            textDocument/*     → document_sync.zig, hover.zig,
                                  completion.zig, navigation.zig,
                                  editing.zig, rename.zig,
                                  code_actions.zig, diagnostics.zig,
                                  semantic_tokens.zig, symbols.zig
            workspace/*        → symbols.zig, server.zig
            $/cancelRequest    → markCancelled()
      → sendResponse() → stdout
```

**Rate limiting:** User-visible error notifications throttled to 1 per 30 seconds (`USER_ERROR_RATELIMIT_MS`). Work queue capped at 50,000 entries.

---

## Progress Reporting

Progress uses the LSP `window/workDoneProgress` protocol:

1. Server checks `client_caps_work_done_progress` (set from client capabilities in `initialize`)
2. Sends `window/workDoneProgress/create` with token `"refract_{id}"`
3. Sends `$/progress { kind: "begin" }` when indexing starts
4. Sends `$/progress { kind: "report", message, percentage }` every 25 files
5. Sends `$/progress { kind: "end" }` when indexing completes

The VS Code extension subscribes via `client.onNotification("$/progress", …)` and displays results in a status bar item.

---

## MCP Server

Refract includes a separate MCP (Model Context Protocol) server for AI agent integration. It uses the same SQLite database as the LSP server (read-only by default when LSP is running).

- **Protocol version:** 2025-06-18
- **Rate limit:** 100 requests/second
- **Response size limit:** 1 MiB per response

See [MCP_TOOLS.md](./MCP_TOOLS.md) for full tool documentation.

---

## Adding a New LSP Handler

1. Add the handler function in the appropriate `src/lsp/*.zig` module
2. Register it in `server.zig`'s dispatch table (the large `if/else if` chain in `handleMessage`)
3. Advertise the capability in `handleInitialize`'s response JSON (lines 2571+)
4. Add a test in `src/tests/protocol_test.zig`
5. Run `zig build test` to verify
