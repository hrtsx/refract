# Changelog

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

*Minimum Zig: 0.15.2 · Schema: 23 · Tested: Ruby 2.7 – 3.3*
