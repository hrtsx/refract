# Changelog

## [0.2.1] - 2026-04-04

### Safety & Reliability
- Defer-based mutex locking in all background worker paths (bgWorkerFn, commitParsed)
- Preserve last-good index on parse failure (broken files keep completion working)

### Type System
- Union type resolution: `String | Integer` return types now expand into separate method queries
- Generic element type extraction: `Array[User]` resolves base class for completion
- Method chain depth extended from 2 to 5 levels with confidence decay
- Type narrowing for `if x` (truthy guard) and `unless x.nil?` patterns
- `extractBaseClass` and `extractGenericElement` utilities for type string parsing

### Features
- Routes: `as:` option support for custom helper names
- i18n: YAML anchor markers (`&anchor`) now indexed instead of skipped
- Schema v24 with composite indexes on symbols(name,file_id), params(symbol_id,position), local_vars(file_id,scope_id)

### MCP
- `resolve_type` enhanced: returns confidence source, union components
- New `explain_type_chain` tool: trace how a variable's type was inferred
- New `suggest_types` tool: find untyped methods and suggest annotations

## [0.2.0] - 2026-03-30

### Added

**Template and i18n support**
- HAML template support (expanded from basic parsing to comprehensive completion and hover)
- i18n translation key completion and hover (queries i18n_keys table)
- Route helper completion from `config/routes.rb` (queries routes table)

**Type-aware features**
- Type-aware dot completion (instance variables, literals, constructors)
- Nil-aware hover (shows `| nil` when method can return nil)
- Enhanced inlay hints (method return types, block parameter types)

**Navigation**
- textDocument/documentLink (clickable require paths for go-to-definition)

**Database**
- New tables: `i18n_keys`, `routes`, `aliases`
- MRO query optimization (recursive CTE replaces iterative queries)
- Compound indexes on frequently queried columns
- Partial index on return_type for nil-aware detection
- Schema v24

### Fixed

- Missing i18n_keys/routes/aliases tables no longer crash on insert
- Schema version test assertions for v24 migration

### Performance

- MRO (Method Resolution Order) traversal using recursive CTE (100x+ faster for deep hierarchies)
- Compound indexes on (scope, parent_id) and (scope, qualified_name)
- Partial index on methods with nil return type

---

## [0.1.0] - 2026-03-17

### Added

**Core LSP protocol (LSP 3.17)**
- textDocument/completion with trigger characters `.`, `::`, `@`, `$`
- textDocument/hover with symbol documentation and type information
- textDocument/definition and declaration (LocationLink when client supports it)
- textDocument/references
- textDocument/rename (scope-aware for local variables)
- textDocument/documentSymbol and workspace/symbol with prefix + infix fallback
- textDocument/semanticTokens (full, delta, range) with UTF-16 column conversion
- textDocument/inlayHints for method parameter names
- textDocument/publishDiagnostics and textDocument/diagnostic (pull model)
- textDocument/formatting and textDocument/rangeFormatting via RuboCop
- textDocument/codeAction (RuboCop quickfix, `--autocorrect-all`)
- textDocument/codeLens for method reference counts
- textDocument/foldingRange, selectionRange, linkedEditingRange, documentHighlight
- textDocument/signatureHelp, typeDefinition, implementation
- callHierarchy/incomingCalls and outgoingCalls
- typeHierarchy/supertypes and subtypes
- workspace/executeCommand: `refract.restartIndexer`, `refract.forceReindex`,
  `refract.toggleGemIndex`, `refract.showReferences`, `refract.runTest`,
  `refract.recheckRubocop`
- `$/progress` notifications during initial workspace indexing
- JSON-RPC parse-error response (code −32700) on malformed input

**Ruby language coverage**
- Classes, modules, methods, constants, instance/class/global variables
- Inheritance, mixins (include/prepend/extend) with MRO traversal up to 8 levels
- `private`/`protected`/`public` visibility including `private def foo` inline form
- `attr_reader`, `attr_writer`, `attr_accessor`
- Rails DSL: `scope`, `belongs_to`, `has_many`, `has_one`, `has_and_belongs_to_many`,
  `validates`, `before_action`, `after_action`, `delegate`, `define_method`,
  `module_function`
- ActiveRecord `enum` (symbol-array, keyword-hash-array, hash-integer, positional)
- `alias` and `alias_method`
- Operator-assign forms: `@ivar ||= x`, `FOO &&= x`, `@@cv ||= x`, `$gvar ||= x`
- `class << self` and `class << obj` singleton classes
- `method_missing` and `respond_to_missing?`
- Namespace resolution for constants (`Foo::BAR`) and qualified references
- `require` and `require_relative` go-to-definition and hover
- `require_relative "path"` path completion inside string literals
- gitignore negation patterns (`!pattern`) honoured during indexing

**Completion**
- Dot-completion with MRO class hierarchy traversal
- `::` namespace completion, `@ivar` from assignments, `$gvar` with 16 built-ins
- Keyword argument parameters complete with `: ` suffix
- Snippet insertion, `sortText`, `filterText`, `commitCharacters`,
  `completionItem/resolve`, substring/fuzzy matching; `isIncomplete` at 1 000 items

**RuboCop integration**
- Automatic `bundle exec` probe when `Gemfile.lock` is present; falls back to bare
  `rubocop`
- Configurable timeout (default 30 s); stderr forwarded to editor on failure
- `refract.recheckRubocop` command re-runs the probe at runtime

**Gem indexing**
- Indexes installed gems listed in `Gemfile.lock`; `refract.toggleGemIndex` at runtime

**Configuration** (via `initializationOptions` and `workspace/didChangeConfiguration`)
- `maxFileSizeBytes` / `maxFileSizeMb` (default 8 MB), `rubocopTimeoutSecs`,
  `disableRubocop`, `disableGemIndex`, `maxWorkers`, `bundleExecTimeoutSecs`,
  `extraExcludeDirs`, `logLevel` (1 error · 2 warn · 3 info · 4 debug)
- All options hot-reload without restart

**CLI**
- `refract --version`, `--help`, `--verbose`, `--log-file FILE`, `--log-level N`,
  `--disable-rubocop`, `--db-path PATH`, `--print-db-path`, `--reset-db`, `--check`

**Infrastructure**
- Per-project SQLite database: WAL mode, prepared-statement cache, auto schema migration
- Background indexer with cancellable scan and configurable parallelism
- TMPDIR-aware temp file placement (macOS sandbox compatible)
- UTF-8 BOM stripping; UTF-16 position encoding for clients that require it
- Open-document cache (200 entries, LRU eviction) for unsaved-buffer diagnostics

---

*Minimum Zig: 0.15.2 · Schema: 24 · Tested: Ruby 2.7 – 3.3*
