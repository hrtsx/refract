# Architecture

Refract is a single static binary written in Zig that:

1. Scans a Ruby workspace.
2. Parses each file with [Prism](https://github.com/ruby/prism), a fast, vendored Ruby parser.
3. Writes symbols, references, params, mixins, routes, i18n keys, and diagnostics into a SQLite database (one DB per workspace, stored in `.refract/`).
4. Serves LSP, MCP, and DAP traffic over stdio.

## Components

```
                          ┌──────────────┐
                          │  refract bin │
                          └──────┬───────┘
                                 │
   ┌─────────────────┬───────────┼────────────┬─────────────────┐
   │                 │           │            │                 │
┌──┴────┐      ┌─────┴──┐   ┌────┴─────┐   ┌──┴──────┐    ┌─────┴────┐
│ LSP   │      │ MCP    │   │ DAP      │   │ Indexer │    │ Bridges  │
│server │      │server  │   │server    │   │+ Prism  │    │ Sorbet/  │
│       │      │        │   │+ rdbg    │   │+ RBS    │    │ Steep    │
└───┬───┘      └────┬───┘   └────┬─────┘   └────┬────┘    └────┬─────┘
    │               │            │              │              │
    └───────────────┴────────────┼──────────────┴──────────────┘
                                 │
                          ┌──────┴──────┐
                          │   SQLite    │
                          │  schema v13 │
                          └─────────────┘
```

## SQLite schema (v13)

Per-workspace database, WAL mode, mmap'd. Tables:

- `files`, `symbols`, `refs`, `params`, `local_vars` — core index.
- `symbols_fts` — FTS5 trigram index over `symbols.name` for substring search.
- `overlay_nodes`, `overlay_edges`, `overlay_types`, `overlay_suppress` — agent-writable overlay graph (branch-scoped, reversible).
- `mixins`, `routes`, `i18n_keys`, `diagnostics` — Rails / RSpec / framework-specific surfaces.
- `worktree`, `gem_versions` — workspace + dependency tracking.
- `type_oracle` — resolved types from any source.
- `sorbet_results`, `steep_results` — Sorbet / Steep responses with provenance.
- `coverage_lines` — SimpleCov hit counts.
- `brakeman_findings`, `semgrep_findings` — security / lint diagnostics.
- `perf_metrics`, `audit_log` — observability.
- `runs` — every subprocess invocation with start/end/exit-code/stderr-tail.
- `plugin_state` — opaque KV per extension.
- `meta` — schema version + migration state.

## Servers

- **LSP** (`refract --stdio`) — main mode. Capabilities advertised include `textDocument/{hover,definition,completion,references,rename,codeAction,inlineCompletion}`, `semanticTokens/full+delta`, `callHierarchy`, `typeHierarchy`, `documentLink`, `codeLens`, `inlayHint`. Capability flags `experimental.refract.{dap,plugins,inlineCompletion}` signal optional surfaces.
- **MCP** (`refract --mcp`) — exposes 41 tools for AI agents. Wire format: MCP 2025-06-18.
- **DAP** (`refract --dap`) — Debug Adapter Protocol front-end. Proxies `rdbg` after path/env resolution.

## Indexer pipeline

1. Workspace scan via inotify/kqueue (`indexer/scanner.zig`).
2. Per-file Prism parse → walks AST extracting symbols, refs, params, mixins, routes, i18n, diagnostics.
3. Hot index (`lsp/hot_index.zig`) — in-memory, lock-free symbol cache for sub-ms lookup; backed by SQLite for cold/large queries.
4. Background workers: rubocop subprocess, gem RBS hydration, sorbet/steep bridges, brakeman/semgrep ingestion.

## Type oracle

Resolution chain implemented in `lsp/type_resolver.zig`:

1. `sorbet_results` (confidence ≥ 80).
2. `steep_results` (confidence ≥ 80).
3. `type_oracle` (any).
4. `params.type_hint` (RBS).
5. `symbols.return_type` (Prism literal inference).

Confidence below thresholds is stored but not surfaced.

## Plugin host

Subprocess plugins discovered from `${workspace}/.refract/extensions/*/refract-extension.json` and `${XDG_DATA_HOME}/refract/extensions/`. Each plugin announces capabilities at `initialize`; refract proxies declared LSP methods through the handler registry. Crashes isolated; unhealthy plugins enter 60 s cooldown.

See [extensions/PROTOCOL.md](extensions/PROTOCOL.md).

## Observability

- `perf_metrics` — rolling 1-min p50/p95/count per LSP method.
- `audit_log` — per MCP-tool invocation with args (capped at 4 KB).
- Local crash logs at `~/.local/state/refract/crash-*.log` (last 100 LSP messages + version + git SHA).
- Optional OTLP/JSON exporter (`lsp/otlp_exporter.zig`), off by default. Telemetry is opt-in only; PII paths anonymized to `<workspace>/...` before send.
