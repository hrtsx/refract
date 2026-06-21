# Changelog

## [0.1.0-rc1] - 2026-06-21

Release candidate on top of beta.1. Green across the lsp/mcp/edge suites on
Linux, Alpine (musl), and macOS.

### Architecture

- God-file teardown: the indexer, MCP server, DB layer, LSP server, and CLI
  split into focused modules (stdlib types, RBS parser, Rails DSL, resolution,
  semantic checks; per-domain MCP tool groups; schema DDL; server utilities).
  Behaviour-preserving — same tests, same wire output.

### MCP surface — curated to 30 tools

- **`diagnostics` fixed.** It read a `diagnostics` table that nothing ever wrote, so
  it always returned `[]`. Now computed on demand via the same engine the LSP uses
  (Prism parse diagnostics + semantic checks), so `refract/nil-receiver`,
  `refract/wrong-arity`, etc. actually reach agents. `explain_symbol`'s diagnostics
  section and the `find-bugs` prompt were fixed the same way; `workspace_health`
  dropped its always-zero diagnostic-count field.
- **Pruned 11 dead/redundant/niche tools** (41 → 30) to keep the surface lean:
  `diagnostic_summary` (dead table), `find_callers` (= `find_references` with
  `ref_kind`), `batch_resolve` (loop over `resolve_type`), `unused_association_chain`
  (= `find_unused` with `kind=association`), `coverage_gap_analyzer`, `find_similar`,
  `security_audit_summary`, `migration_chain_analyzer`, `dependency_tree_resolver`,
  `suggest_types`, `type_coverage`.
- Removed `route_map` (queried a never-populated symbol kind); `list_routes` is the
  working equivalent.
- `workspace_symbols` ranks by kind (classes/modules, then constants/defs) with
  capitalized names and exact matches first, backed by an FTS5 trigram index;
  substring search drops to low-single-digit ms on 10k-file workspaces.

### Constant resolution

- Nesting-aware constant resolution (schema v7): a constant reference resolves by
  Ruby's real lookup order — innermost lexical scope outward to top-level, then the
  enclosing class's ancestry (superclass + included modules). Same-named constants in
  different namespaces resolve to the correct declaration; `refs.def_id` is populated
  for constants, so references and rename are binding-exact (renaming `A::CONST` no
  longer touches `B::CONST`). New MCP tool `resolve_constant(name, nesting)` exposes
  the resolver to agents. `symbols.deprecated` flags `@deprecated` definitions.
- Agent-writable overlay graph (schema v6): `overlay_annotate`, `overlay_list`,
  `overlay_revert`, `overlay_promote` — branch-scoped, reversible, audited; derived
  facts stay immutable.

### Stability

- macOS CI flake eliminated. Subprocess-integration test groups ran four-wide in a
  single `zig build`, so the parallel Run steps spawned many short-lived `refract`
  sessions at once; on a contended runner the storm starved children past the test
  harness watchdog and truncated their stdout. CI now runs each test group
  sequentially, the harness child watchdog moved 15s → 60s (overridable via
  `REFRACT_TEST_WATCHDOG_MS`), and the `$/refract/__waitForIdle` drain loop is bounded.
- Cold-index persistence fix: routes and i18n keys front-loaded on first index.

## [0.1.0-beta.1] - 2026-05-24

Hardening on top of the alpha.1 surface. Green across the lsp/mcp/edge suites
on Linux, Alpine (musl), macOS, and the debug build, plus the valgrind
self-test.

### Navigation & types

- Go-to-definition resolves method parameters: each named parameter is mirrored
  into `local_vars`, so references in the body — including `case/in` arms —
  navigate to the declaration.
- Receiver-aware navigation for association, `delegate`, pattern-match binding,
  and `Struct` members.
- Route helper indexing: `member`/`collection` `:id`, namespace/scope
  separators, hash-rocket form, helper-name sanitization.
- `delegate(prefix:, to:)` parsing; ActiveRecord relation chains unwrap
  `.first`/`.last`/`.find`, `pluck` → `Array`; `&method(:foo)` resolves like
  `&:foo`.

### Reliability

- `$/refract/__waitForIdle` waits out any in-flight background reindex before
  returning, making `didChangeWatchedFiles → query` deterministic on every
  platform (was an intermittent macOS/debug miss).
- `didChange` diagnostics debounced off the query hot path; query handlers no
  longer drive synchronous index flushes.
- `callHierarchy/outgoingCalls` use-after-free fixed on musl (per-iteration
  def-statement arena); the Alpine CI skip is removed.
- DB self-heal on corruption with a `$/refract/recovered` notification; cache
  key and MCP realpath free leaks closed.

### Security

- Plugin sandbox enforced via the `refract --sandbox-exec` trampoline (Linux
  seccomp + Landlock + setrlimit; macOS `sandbox_init` + setrlimit), manifest
  fail-closed on `allow_network` / `allow_fs_write`.
- MCP file arguments reject `../` traversal; `pathInWorkspace` prefix match
  tightened so `/workspace-evil` no longer matches `/workspace`.
- Secret-redaction module, plugin env-gating, elevated-capability refusal;
  `runTest` path-bounds and a 16 MiB `didChange` cap.

### Performance

- Pre-prepared def/completion SQL and pre-rendered hover/def/completion bodies;
  sort/dedup dropped from the per-query path; hot LRU 8 → 32.

### CLI & diagnostics

- `doctor` gains WAL/Bundler/TMPDIR/crash/plugin checks, explicit exit codes,
  and warns on unknown init keys; OTLP export redacts secrets.

### Benchmarks & accuracy

- Go-to-definition accuracy re-baselined on the 76-case user-code + 24-case
  stdlib fixture vs ruby-lsp 0.26.9 and solargraph 0.58.3; seven broken probes
  corrected and the suite re-run identically for all three servers.
- `docs/BENCHMARK.md`: the shipped binary is `--release=safe` and is the build
  benchmarked. ReleaseSafe keeps runtime safety checks (refract indexes
  arbitrary Ruby — malformed input panics cleanly instead of corrupting a
  long-lived server); ReleaseFast is within noise on the hot query paths.

### Tests & CI

- 27k-line `protocol_test.zig` split into per-area `src/tests/lsp/*` modules;
  the `test:lsp` aggregate step restored so `ci.yml`'s `[lsp, mcp, edge]` matrix
  drives it.
- `--mcp` test workspaces isolated from the inherited cwd.
- Added test-debug + valgrind matrix, a concurrency burst test, and fuzz/soak
  nightlies; soak corpus expanded to full Discourse + Mastodon.

## [0.1.0-alpha.1] - 2026-04-26

First public alpha. Intended for early testers + dogfooding. The plumbing
listed below is real and tested in CI, but the daily editor experience has
not yet been validated by hour-of-use sessions on production Rails apps.
Expect rough edges. File issues. The 0.1.0 final tag will follow after
alpha-tester feedback.

### Core LSP Protocol (LSP 3.17)

- `textDocument/completion` — dot, `::`, `@ivar`, `$gvar`, keyword argument, require-path, snippet insertion, `sortText`/`filterText`/`commitCharacters`, `completionItem/resolve`, substring/fuzzy matching, `isIncomplete` at 1 000 items
- `textDocument/hover` — symbol type, YARD docs (`@param`, `@return`, `@deprecated`, `@raise`, `@see`, `@overload`, `@yieldparam`, `@yieldreturn`, `@example`, `@note`, `@since`), constant values, association DSL lines, block-param labels, `**Parameters:**` section with type + description per param
- `textDocument/definition`, `declaration`, `typeDefinition`, `implementation`
- `textDocument/references` and `workspace/symbol` with exact → prefix → infix ranking and kind filter
- `textDocument/documentSymbol`
- `textDocument/rename` and `textDocument/prepareRename` — MRO-aware cross-file rename, follows inheritance and mixins
- `textDocument/semanticTokens` (full, delta, range) with UTF-16 column conversion
- `textDocument/inlayHints` — method return types, block parameter types
- `textDocument/publishDiagnostics` and `textDocument/diagnostic` (pull model)
- `textDocument/formatting` and `textDocument/rangeFormatting` via RuboCop
- `textDocument/codeAction` — RuboCop quickfix, `--autocorrect-all`
- `textDocument/codeLens` — method reference counts
- `textDocument/foldingRange`, `selectionRange`, `linkedEditingRange`, `documentHighlight`
- `textDocument/signatureHelp`
- `callHierarchy/incomingCalls` and `outgoingCalls`
- `typeHierarchy/supertypes` and `subtypes`
- `workspace/executeCommand` — `refract.restartIndexer`, `refract.forceReindex`, `refract.toggleGemIndex`, `refract.showReferences`, `refract.runTest`, `refract.debugTest`, `refract.recheckRubocop`, `refract.disableDiagnostic`
- `$/progress` live indexing notifications (begin / report every 25 files with current directory / end)
- JSON-RPC parse-error response (code −32700) on malformed input

### Ruby Language Coverage

- Classes, modules, methods, constants, instance/class/global variables
- Inheritance, mixins (`include`/`prepend`/`extend`) with MRO traversal up to 8 levels
- `private`/`protected`/`public` visibility including `private def foo` inline form
- `attr_reader`, `attr_writer`, `attr_accessor`
- Rails DSL: `scope`, `belongs_to`, `has_many`, `has_one`, `has_and_belongs_to_many`, `validates`, `before_action`, `after_action`, `delegate`, `define_method`, `module_function`
- ActiveRecord `enum` (symbol-array, keyword-hash-array, hash-integer, positional)
- `alias` and `alias_method`
- Operator-assign forms: `@ivar ||= x`, `FOO &&= x`, `@@cv ||= x`, `$gvar ||= x`
- `class << self` and `class << obj` singleton classes
- `method_missing` and `respond_to_missing?`
- Namespace resolution for constants (`Foo::BAR`) and qualified references
- `require` and `require_relative` go-to-definition, hover, and path completion inside string literals
- gitignore negation patterns (`!pattern`) honoured during indexing

### Type Inference

- RBS / RBI signatures (confidence 90), YARD `@return`/`@param`, literal types, method chain (up to 5 levels with confidence decay), type narrowing (`if x`, `unless x.nil?`)
- Union types (`String | Integer`), generic element types (`Array[User]`) for receiver-aware completion
- Stdlib return types: `Regexp`, `MatchData`, `File`/`IO`, `Time`/`Date`/`DateTime`, `Enumerator`, `Range`, `Pathname`, and universal `Object` methods
- ActiveSupport: `presence` returns receiver type, `try`/`try!` nullable
- Nil-aware hover — shows `| nil` for known nilable methods
- Block return types: `.tap` returns receiver, `.then` / `.yield_self` return block result, `.lazy.…force` collapses to Array element type, `.each_with_object([] | {})` returns the accumulator
- `&:symbol` to_proc shorthand: `[1,2].map(&:to_s)` propagates element type through the receiver chain
- `case/in` pattern matching: binds capture (`in Foo => bar`), hash destructure (`in {key: x}`), and array destructure (`in [a, *b]`) variables to their narrowed types in the `local_vars` table

### Rails & Templates

- Route helper completion and hover from `config/routes.rb`
- i18n translation key completion, hover, and YAML anchor support
- HAML / ERB template-aware context detection with correct attribute brace counting
- Association, validation, and callback indexing with inferred return types
- `has_many :through:` walks the intermediate model's association chain to surface the final target type
- `:source` alias on `has_many` / `has_one` overrides convention-based class inference (`has_many :comments, through: :posts, source: :replies` → `Reply`)
- `concerning :Name do … end` synthesizes a namespace stack so methods defined inside are scoped to the concern; `included do` / `extended do` blocks pull active-class context from `mixins`
- `attr_reader` / `attr_writer` / `attr_accessor` (+ `mattr_*` / `cattr_*` variants) index every symbol in a comma-separated list, not just the first

### Completion Quality

- Typed parameter signatures in detail: `(name: String, count: Integer) → Array`
- Deprecated symbols sorted to bottom (`@deprecated` detected from YARD)
- Exact-name matches floated above prefix matches within each tier
- Keyword snippets with multi-line `insertTextFormat: 2` bodies

### Hover Sugar

- Constant values displayed inline: `` `FOO` = `[:jpg, :png]` `` for arrays, hashes, ranges and all scalar literals; truncated values show `…`
- Association DSL rendered as fenced Ruby block: `has_many :posts, dependent: :destroy`
- `**Extends:**` section alongside `**Includes:**` in class/module hover
- Block parameters labeled `*(block param)*` instead of `*(local variable)*`

### MCP Server (39 tools)

Code intelligence (`resolve_type`, `class_summary`, `method_signature`, `explain_symbol`, `explain_type_chain`, `suggest_types`, `type_coverage`), symbol search (`workspace_symbols`, `list_by_kind`, `get_file_overview`, `find_unused`, `find_similar`), call graph (`find_callers`, `find_implementations`, `find_references`, `type_hierarchy`), source access (`get_symbol_source`, `grep_source`), Rails (`association_graph`, `route_map`, `i18n_lookup`, `list_validations`, `list_callbacks`, `concern_usage`), diagnostics (`diagnostics`, `diagnostic_summary`), workspace (`workspace_health`, `batch_resolve`), code actions (`refactor`, `available_code_actions`), testing (`test_summary`).

Five agent-native additions (`coverage_gap_analyzer`, `security_audit_summary`, `migration_chain_analyzer`, `dependency_tree_resolver`, `unused_association_chain`) expose workspace intelligence specifically for LLM coding agents — test coverage holes, combined Brakeman+Semgrep risk score, Rails migration rollback hazards, `Gemfile.lock` dep tree, and N+1 association candidates.

`find_callers` / `find_references` accept a `ref_kind` filter — `call` · `assign` · `decl` · `super` · `yield` · `alias` — backed by the dedicated `refs.kind` column captured at index time.

### DAP Server

- `refract --dap` proxies to `rdbg` (Ruby `debug` gem). Wire-compatible with VS Code, nvim-dap, JetBrains LSP4IJ.
- Emits a DAP `output` event with `gem install debug` install hint before the failed `launch` response when `rdbg` is missing from `PATH` (or `RDBG_BIN` points at a missing binary), instead of dying silent with a generic error.
- Workspace path resolution + ENV propagation (chruby/rbenv/asdf) + heartbeat + `terminated` event on rdbg crash.

### RuboCop Integration

- Automatic `bundle exec` probe when `Gemfile.lock` present; falls back to bare `rubocop`
- Configurable debounce delay (`rubocopDebounceMs`, default 1 500 ms) — prevents rapid re-saves from spawning duplicate processes
- Configurable timeout (default 30 s); stderr forwarded to editor on failure
- `refract.recheckRubocop` command re-runs the probe at runtime

### Gem Indexing

- Indexes installed gems from `Gemfile.lock`; `rbs_collection.lock.yaml` for RBS type discovery
- `refract.toggleGemIndex` enables/disables at runtime

### Configuration

Via `initializationOptions` and `workspace/didChangeConfiguration` (all options hot-reload without restart):

`maxFileSizeMb` (default 8), `rubocopTimeoutSecs`, `rubocopDebounceMs`, `disableRubocop`, `disableGemIndex`, `maxWorkers`, `bundleExecTimeoutSecs`, `extraExcludeDirs`, `logLevel` (1 error · 2 warn · 3 info · 4 debug)

Per-project `.refractrc.json` adds: `disableTypeChecker`, `typeCheckerSeverity` (`error`/`warning`/`info`), `diagnosticsSuppressions` (codes to ignore), `indexBudget.fileSizeMb`, `indexBudget.excludeDirs`, and `typeCheckerConfidence: { surface: u8 }` (default `{ surface: 80 }`) — minimum confidence to surface a resolved type in completion/hover/inlay/navigation.

### Editor Integrations

Eight first-party integrations, each smoke-tested in CI:

- **VS Code** — TypeScript extension with live indexing status bar (`⟳ Refract: indexing app/models…` → `✓ Refract`), seven Command Palette entries (Restart Indexer, Force Reindex, Toggle Gem Indexing, Re-check RuboCop, Show References, Run Test, Run Doctor), debug adapter wiring, "Open Settings" shortcut on binary-not-found, "Show Output" on other startup failures. Smoke: `xvfb-run npm test` driving `@vscode/test-electron` to assert capabilities exchange.
- **Neovim** — `editors/neovim/init.lua` + `dap.lua`. Smoke: headless `nvim` attaches LSP, asserts ≥1 active client.
- **Helix** — config-only `language-server.refract`. Smoke: `hx --health ruby` confirms refract picked up.
- **Emacs** — eglot integration. Smoke: `emacs --batch` with `(eglot-ensure)` + assertion on `(eglot-current-server)`.
- **Zed** — `editors/zed/extension.toml`. Smoke: TOML parse + `refract --version`.
- **Sublime LSP** — `LSP-refract.sublime-settings`. Smoke: JSON validation + `refract --version`.
- **JetBrains** — `editors/jetbrains/plugin.xml` (LSP4IJ-compatible). Smoke: `xmllint --noout` + `refract --version`.
- **Kate** — `editors/kate/lspclient.json`. Smoke: JSON validation + `refract --version`.

### CLI

`refract --version`, `--help`, `--verbose`, `--log-file FILE`, `--log-level N`, `--disable-rubocop`, `--db-path PATH`, `--print-db-path`, `--reset-db`, `--check`, `--stats`, `--json`, `--max-workers N`, `--index-only`, `--dump-symbols`, `--workspace-info`, `--last-crash`, `--doctor`, `--repair`, `--dap`, `--mcp`, `--no-color`, `--warm-stdlib`, `--bench-sorbet PATH`, `--bench-steep PATH`, `--self-test`.

`--doctor` walks upward from `/proc/self/exe` for vendor checks, so it stays accurate from any cwd. `--no-color` and `NO_COLOR` env both suppress ANSI. `--self-test` spawns LSP+MCP child handshakes and exits 0 on success — single command CI / install-verify smoke.

### Benchmarks

- Head-to-head matrix vs `ruby-lsp`, `solargraph`, `sorbet`, `steep` with reproducible JSON cells. See `docs/BENCHMARK.md`.
- One-command repro for third parties: `scripts/bench/fetch-corpora.sh` clones mastodon + discourse + generates a 10k synthetic corpus; `scripts/bench/repro.sh` runs the matrix end-to-end.
- `bench-on-pr.yml` posts a delta to PR comments AND uploads `head_results/` + `base_results/` JSONs as a 90-day artifact, so reviewers can audit individual cells.
- `perf-nightly.yml` runs daily at 06:00 UTC against discourse-lib + mastodon (micro + session). Opens a GitHub Discussion when hover/def/comp p50 regresses > 15 % vs the last 7-day median. 25-minute job timeout.

### Performance

- Synchronous hot-index warmup on `initialize` with a 200 ms budget; falls back to async on budget overflow. Eliminates cold-path penalty on the first hover/def request.
- Pre-prepared SQL cache: 10 hottest statements (hover-exact, hover-qualified, def-exact, refs-by-name, params, mixins, completion-prefix, completion-namespace, symbol-by-file) prepared at `Server.init` so no request pays prepare cost.
- Per-file LRU symbol cache (8 entries) backing hover + definition fast path; invalidated under `db_mutex` on every `didChange` to prevent stale reads.
- Cold-path SQL: exact `s.name = ?` (indexed) probed first; `LIKE '%::' || ?` qualified-suffix scan only runs on zero rows.
- `src/bench.zig` reports real `p50/p95/p99` (sorted-index, not avg/min/max). Bench harness prewarms once + reports best-of-5 + median to cut page-cache variance < 10 %.

### Infrastructure

- Per-project SQLite database: WAL mode, prepared-statement cache, auto schema migration
- Background indexer with live `$/progress` reporting every 25 files; cancellable scan; configurable parallelism
- Rate limiting: user-visible error notifications throttled to 1 per 30 s; work queue capped at 50 000 entries
- TMPDIR-aware temp file placement (macOS sandbox compatible)
- UTF-8 BOM stripping; UTF-16 position encoding for clients that require it
- Open-document cache (200 entries, LRU eviction) for unsaved-buffer diagnostics

### Release engineering

- All release binaries signed with [Sigstore cosign](https://www.sigstore.dev) via keyless OIDC; `.sig` + `.pem` published alongside each binary.
- CycloneDX SBOM (`refract-sbom.cdx.json`) attached to every release.
- Homebrew tap auto-bump on tag; Homebrew formula now ships v0.1.0 SHAs regenerated from release artifacts.

### Platform support

- **Linux x86_64 + aarch64** (glibc and musl) and **macOS x86_64 + aarch64**. Windows is not supported in 0.1.0; a Zig-0.16 windows-gnu path with full libc is on the 0.2.0 wishlist.

### Plugin sandboxing

Refract spawns LSP plugins through a trampoline (`refract --sandbox-exec`)
that installs an OS-level sandbox before `execve`-ing the plugin entry. The
filter is enforced on every spawn — there is no "unsandboxed" code path in
0.1.0.

- **Linux** — seccomp-bpf (network syscalls denied unless `sandbox.allow_network`
  is granted) + Landlock fs scope (≥5.13; writes restricted to `sandbox.allow_fs_write`
  paths) + `setrlimit` caps on CPU, AS, NOFILE.
- **macOS** — `sandbox_init` with a SBPL profile derived from the manifest
  capabilities + `setrlimit` caps.
- **Manifest gate** — 0.1.0 ships fail-closed: `allow_network: true` and any
  non-empty `allow_fs_write` are rejected at manifest validation. Loosening
  the gate is a 0.1.1 change; the trampoline already passes through the
  required flags.

### Deferred to 0.2.0

- Pre-rendered hover markdown for the top-1000 most-referenced symbols at warmup (would close the final per-query gap to ruby-lsp on micro workloads).
- Splat (`*args`) and double-splat (`**kwargs`) parameter-type propagation through method-call chains.

---

*Minimum Zig: 0.16.0 · Schema: 7 · Prism 1.9.0 · Ruby 2.7 – 3.4*
