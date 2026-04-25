# Changelog

## [0.1.0] - 2026-04-25

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
- `workspace/executeCommand` — `refract.restartIndexer`, `refract.forceReindex`, `refract.toggleGemIndex`, `refract.showReferences`, `refract.runTest`, `refract.recheckRubocop`
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

### Rails & Templates

- Route helper completion and hover from `config/routes.rb`
- i18n translation key completion, hover, and YAML anchor support
- HAML / ERB template-aware context detection with correct attribute brace counting
- Association, validation, and callback indexing with inferred return types

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

### MCP Server (35 tools)

Code intelligence (`resolve_type`, `class_summary`, `method_signature`, `explain_symbol`, `explain_type_chain`, `suggest_types`, `type_coverage`), symbol search (`workspace_symbols`, `list_by_kind`, `get_file_overview`, `find_unused`, `find_similar`), call graph (`find_callers`, `find_implementations`, `find_references`, `type_hierarchy`), source access (`get_symbol_source`, `grep_source`), Rails (`association_graph`, `route_map`, `i18n_lookup`, `list_validations`, `list_callbacks`, `concern_usage`), diagnostics (`diagnostics`, `diagnostic_summary`), workspace (`workspace_health`, `batch_resolve`), code actions (`refactor`, `available_code_actions`), testing (`test_summary`).

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

### VS Code Extension

- Status bar with live indexing progress (`⟳ Refract: indexing app/models…` → `✓ Refract`)
- All 6 commands in Command Palette: Restart Indexer, Force Reindex, Toggle Gem Indexing, Re-check RuboCop, Show References, Run Test
- "Open Settings" shortcut on binary-not-found error; "Show Output" on other startup failures

### CLI

`refract --version`, `--help`, `--verbose`, `--log-file FILE`, `--log-level N`, `--disable-rubocop`, `--db-path PATH`, `--print-db-path`, `--reset-db`, `--check`

### Infrastructure

- Per-project SQLite database: WAL mode, prepared-statement cache, auto schema migration
- Background indexer with live `$/progress` reporting every 25 files; cancellable scan; configurable parallelism
- Rate limiting: user-visible error notifications throttled to 1 per 30 s; work queue capped at 50 000 entries
- TMPDIR-aware temp file placement (macOS sandbox compatible)
- UTF-8 BOM stripping; UTF-16 position encoding for clients that require it
- Open-document cache (200 entries, LRU eviction) for unsaved-buffer diagnostics

---

*Minimum Zig: 0.16.0 · Schema: 5 · Prism 1.9.0 · Ruby 2.7 – 3.4*
