# Migrate from ruby-lsp

## TL;DR

1. Uninstall `ruby-lsp` from your Gemfile.
2. Install refract: `brew install refract-lsp/tap/refract` (macOS) or `curl -fsSL https://refract.dev/install.sh | sh` (Linux).
3. Point your editor at `refract --stdio`.
4. Open your workspace. Refract auto-indexes on first open (1–5 s for projects up to ~10k files; ~30 s for ~100k files).

## Parity matrix

| Feature                     | ruby-lsp | refract |
|-----------------------------|----------|---------|
| hover / def / refs / rename | ✅       | ✅      |
| document / workspace symbol | ✅       | ✅      |
| semantic tokens             | ✅       | ✅ (full + delta + range) |
| inlay hints                 | ✅       | ✅ (+ runtime: coverage, vernier) |
| code actions / refactor     | ✅       | ✅ (extract method/var, inline, more) |
| call hierarchy              | ✅       | ✅      |
| type hierarchy              | partial  | ✅      |
| linked editing              | ✅       | ✅      |
| folding ranges              | ✅       | ✅      |
| document highlights         | ✅       | ✅      |
| diagnostics: rubocop        | ✅       | ✅      |
| diagnostics: brakeman       | ❌       | ✅      |
| diagnostics: semgrep        | ❌       | ✅      |
| diagnostics: sorbet         | partial  | ✅ (native bridge) |
| diagnostics: steep          | ❌       | ✅ (native bridge) |
| inline AI completion        | ❌       | ✅ (BYOK, off by default) |
| Debug Adapter (DAP)         | ❌       | ✅ (`refract --dap`) |
| MCP server for agents       | ❌       | ✅ (33 tools) |
| Plugin SDK                  | partial  | ✅ (subprocess JSON-RPC) |

## Behavioral differences

- **Indexing model.** ruby-lsp builds an in-memory index every cold start. Refract persists to SQLite, so the second start is instant and survives editor restarts.
- **Gemfile awareness.** ruby-lsp re-indexes on `bundle install`. Refract watches `Gemfile.lock` + `.tool-versions` + `mise.toml` and re-hydrates only the affected gem indexes.
- **Type resolution.** ruby-lsp surfaces RBS only. Refract resolves Sorbet → Steep → type_oracle → RBS → literal in that order. Confidence ≥ 0.8 surfaces; below ≥ 0.5 emits diagnostics; below 0.5 stored only.

## Configuration mapping

| ruby-lsp setting               | refract equivalent                        |
|--------------------------------|-------------------------------------------|
| `rubyLsp.enabledFeatures`      | LSP capability negotiation (auto)         |
| `rubyLsp.formatter`            | `executeCommand: refract.recheckRubocop`  |
| `rubyLsp.experimentalFeaturesEnabled` | `experimental.refract.*` capability flags |
| custom indexer ignores         | `${workspace}/.refract/exclude.txt`       |
| disable per-cop diagnostic     | `${workspace}/.refract/disabled.txt`      |

## Gotchas

- **Bundler integration.** Refract probes `bundle exec ruby -e "puts $LOAD_PATH"` once per workspace. If `bundle install` hangs, refract will fall back to the system Ruby — check `refract --doctor` to see which Ruby was selected.
- **First open of a huge monorepo (100k+ files).** Wait for the initial index to finish before issuing heavy queries; `refract --workspace-info` reports progress.
- **Sorbet typed-true gating.** Refract only surfaces Sorbet results from `# typed: true | strict | strong` files at high confidence. False/ignore files contribute 50% confidence, stored but not displayed.

## Rollback

Refract keeps state in `.refract/` only. Removing the binary and the directory restores the previous setup. No registry entries, no global mutations.
