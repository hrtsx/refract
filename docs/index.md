# Refract

Fast Ruby LSP, type-aware, debugger-equipped.

Refract is a Ruby language server for VS Code, Neovim, Emacs, JetBrains, Zed, Helix, Sublime Text, and Kate. It indexes your workspace into SQLite, hydrates types from RBS / Sorbet / Steep, and answers hover, definition, completion, references, rename, code-actions, and refactor requests in sub-millisecond p50 on most workloads.

## Why Refract

- **Latency**. p50 hover/def 0.13–0.21 ms on Mastodon vs ruby-lsp 0.86–1.21 ms (`docs/BENCHMARK.md`).
- **Memory**. 26–55 MB RSS vs ruby-lsp 100–155 MB / solargraph 355–1271 MB at the same workspace.
- **Cold start**. 16–57 ms vs ruby-lsp 488–520 ms.
- **Type bridges**. Native ingest of Sorbet (`srb tc --lsp`) and Steep (`steep langserver`) results into a unified type oracle, surfaced to hover/completion/diagnostics.
- **Debugger**. Built-in DAP front-end (`refract --dap`) proxies `rdbg` for breakpoint, step, and evaluate.
- **Extensible**. Subprocess plugin protocol — write extensions in any language. See [extensions/AUTHORING.md](extensions/AUTHORING.md).
- **Agent-native**. 33-tool MCP server for Claude / Codex / custom agents.

## 30-second start

```bash
brew install refract-lsp/tap/refract       # macOS
curl -fsSL https://refract.dev/install.sh | sh  # Linux
refract --doctor                           # self-check
```

Then point your editor at `refract --stdio`. Editor-specific configs live under `editors/` in the repo.

## Pages

- [Install](install.md) — package managers, manual binary, build from source.
- [Architecture](architecture.md) — what's in the SQLite schema, how the indexer pipelines, where types come from.
- [Benchmark](BENCHMARK.md) — head-to-head numbers vs ruby-lsp, solargraph, sorbet, steep.
- [LSP capabilities](lsp_capabilities.md) — full capability matrix and `experimental.refract.*` flags.
- [MCP tools](mcp_tools.md) — every tool, schema, and usage example.
- [Configure](configure/multi_ruby.md) — multi-Ruby/Bundler, AI providers, telemetry.
- [Migrate](migrate/from-ruby-lsp.md) — playbooks for switching from other Ruby tooling.
- [Extensions](extensions/AUTHORING.md) — write your own plugin.
