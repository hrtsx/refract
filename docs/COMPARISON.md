# Refract vs Other Ruby LSP Servers

Honest comparison with the three established Ruby LSPs as of 2026-04. Updated with each release.

## TL;DR

| | Refract | [Solargraph](https://solargraph.org/) | [Ruby LSP](https://github.com/Shopify/ruby-lsp) | [Sorbet](https://sorbet.org/) |
|---|---|---|---|---|
| **Distribution** | Single static binary | Ruby gem | Ruby gem | Ruby gem + native daemon |
| **Runtime deps** | None | Ruby + bundler | Ruby + bundler | Ruby + Sorbet runtime |
| **Cold install** | `brew install` (~5 s) | `gem install solargraph` + YARD doc gen (1-5 min) | `bundle add ruby-lsp` (1-2 min) | `bundle add sorbet` + `srb tt` (5-15 min) |
| **Index storage** | Per-project SQLite | YARD `.cache/` files | In-memory + index files | RBI files + cache |
| **Type system** | RBS + Sorbet sigs + literal narrowing (read-only) | YARD `@param`/`@return` + best-effort | RBS + literal narrowing | Full Sorbet types (RBI authoring) |
| **Type *checking*** | nil-receiver, wrong-arity (v0.1) | none | none | full static analysis |
| **Rails awareness** | DSL parser (5.2-8.0) + ActiveRecord schema | YARD plugin | DSL plugin (Shopify-maintained) | RBI generation via `tapioca` |
| **HAML/ERB** | Yes — context-aware | Limited | Yes | No |
| **MCP server** | Yes — 35 tools for AI agents | No | No | No |
| **Open-source** | MIT | MIT | MIT | Apache 2.0 |

## When to pick each

```
   ┌──────────────────────────────────────────────────────────────────┐
   │ Pick Refract if you want                                         │
   │ • Zero Ruby-runtime overhead (single binary)                     │
   │ • Fast install in CI / Docker                                    │
   │ • Rails 8.0 DSL coverage out of the box                          │
   │ • AI/LLM integration (35 MCP tools for your agent)               │
   │ • Lighter type checks without full Sorbet adoption               │
   ├──────────────────────────────────────────────────────────────────┤
   │ Pick Solargraph if you want                                      │
   │ • Mature, very stable, biggest gem ecosystem                     │
   │ • Custom plugins (large 3rd-party plugin community)              │
   │ • Heavy YARD doc culture matters                                 │
   ├──────────────────────────────────────────────────────────────────┤
   │ Pick Ruby LSP (Shopify) if you want                              │
   │ • Official Shopify maintenance + Rails plugin                    │
   │ • Strong RBS-first type story                                    │
   │ • Tight integration with the `tapioca` ecosystem                 │
   ├──────────────────────────────────────────────────────────────────┤
   │ Pick Sorbet if you want                                          │
   │ • Full static type safety (gradual typing in your code)          │
   │ • Production-grade type errors as compile-time guarantees        │
   │ • Willing to invest in RBI authoring + `srb` tooling             │
   └──────────────────────────────────────────────────────────────────┘
```

You can also run **Refract alongside Sorbet** — Refract provides fast LSP queries; Sorbet provides deep static analysis. They don't compete; they cover different bands.

## Cold-start benchmark (mid-size Rails app)

Mastodon (~4,000 Ruby files):

| Tool | Cold start (workspace ready for queries) | Peak RSS |
|------|------------------------------------------:|---------:|
| Refract | ~1m 50s (debug build) | ~90 MB |
| Solargraph | ~3-4 min (with YARD doc gen) | ~250 MB |
| Ruby LSP | ~30-60 s (no deep types) / 2-3 min (with addons) | ~150 MB |
| Sorbet | ~5-10 min first run (RBI gen) | varies |

Refract's debug build is benchmarked here. Release builds are 2-4× faster.

> Sources: Refract numbers from [`docs/PILOT_RESULTS.md`](PILOT_RESULTS.md); other tools from their docs and recent third-party comparisons. Hardware: 8-core x86_64 Linux.

## What Refract does NOT do (today)

- **Full static type checking** — only nil-receiver and wrong-arity, gated by ≥70 confidence. Sorbet is the right tool for full coverage.
- **YARD doc rendering of arbitrary tags** — supports `@param`, `@return`, `@deprecated`, `@example`, `@see`, `@overload`, `@yieldparam`, `@yieldreturn`, `@note`, `@since`, `@raise`. Not all 50+ YARD tags.
- **Custom plugins** — no plugin API yet. The MCP tools cover most agent-facing extension points.
- **Windows binary** — POSIX-only as of v0.1.0. Tracked for v0.2.
- **Cold-bootstrap on monorepos with 10k+ Ruby files** — completes but slow (~10-15 min release). See [`docs/PILOT_RESULTS.md`](PILOT_RESULTS.md) for the trajectory and v0.2 optimization plan.

## Architecture differences

```
   Solargraph / Ruby LSP / Sorbet
   ──────────────────────────────
   editor → Ruby gem → Ruby runtime → in-process index → response
                       ↑ subject to GVL, GC pauses, gem version conflicts

   Refract
   ───────
   editor → static binary (Zig) → SQLite per-project DB → response
                ↑ no Ruby runtime; queries are SQL; index survives restarts
```

Each tool's design optimizes different things. Refract's bet: **most LSP queries are point-lookups against an index, and SQL is a great query language for that.** The downside is initial index bootstrap cost; the upside is fast steady-state and a portable artifact.

## Editor extensions

| Editor | Repo |
|---|---|
| VS Code | [`editors/vscode/`](../editors/vscode/) in this repo |
| Neovim  | [`hrtsx/refract.vim`](https://github.com/hrtsx/refract.vim) |
| Zed     | [`hrtsx/zed-refract`](https://github.com/hrtsx/zed-refract) |
| Emacs   | [`editors/emacs/refract.el`](../editors/emacs/refract.el) in this repo |
| Helix / Sublime | configured via per-editor LSP settings (see main [README](../README.md#editor-setup)) |

Homebrew tap: [`hrtsx/homebrew-refract`](https://github.com/hrtsx/homebrew-refract) — `brew install hrtsx/refract/refract`.
