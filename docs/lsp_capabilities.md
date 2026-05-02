# LSP Capabilities

Refract implements LSP 3.17 against the latest VS Code, Neovim, Helix, Emacs Eglot, Sublime LSP, Zed, JetBrains LSP4IJ, and Kate.

## Synchronisation

- `initialize` / `initialized` / `shutdown` / `exit`
- `textDocument/didOpen` · `didChange` (incremental) · `didSave` · `didClose`
- `workspace/didChangeWatchedFiles` · `didCreateFiles` · `didRenameFiles` · `didDeleteFiles`
- `$/cancelRequest`
- `$/progress` (live indexing progress every 25 files)
- `$/refract/__waitForIdle` (deterministic test sync; non-standard)

## Code intelligence

| Method | Notes |
|---|---|
| `textDocument/completion` | Dot, `::`, `@ivar`, `$gvar`, kwarg, require-path, snippets. `isIncomplete` at 1 000 items. `completionItem/resolve` for doc hydration. |
| `textDocument/hover` | Symbol type, YARD tags (`@param`, `@return`, `@deprecated`, `@raise`, `@see`, `@overload`, `@yieldparam`, `@yieldreturn`, `@example`, `@note`, `@since`), constant values, association DSL, block-param labels. |
| `textDocument/definition` · `declaration` · `typeDefinition` · `implementation` | All four shapes. Falls through stdlib RBS. |
| `textDocument/references` · `workspace/symbol` | Exact → prefix → infix ranking; `kind` filter. |
| `textDocument/documentSymbol` · `selectionRange` · `foldingRange` · `linkedEditingRange` · `documentHighlight` | All UTF-16-clean. |
| `textDocument/rename` · `prepareRename` | MRO-aware cross-file rename. Follows inheritance + mixins. |
| `textDocument/semanticTokens` (full / delta / range) | UTF-16 column conversion. |
| `textDocument/inlayHints` | Return types, block-param types. |
| `textDocument/publishDiagnostics` · `textDocument/diagnostic` | Pull + push. RuboCop + Brakeman + Semgrep + Refract's own type-aware diagnostics. |
| `textDocument/formatting` · `rangeFormatting` | RuboCop. |
| `textDocument/codeAction` | Quickfix, `--autocorrect-all`, extract, inline, etc. |
| `textDocument/codeLens` | Reference counts on every `def`. |
| `textDocument/signatureHelp` | Active parameter highlighting. |
| `callHierarchy/incomingCalls` · `outgoingCalls` | Backed by the `refs` table. |
| `typeHierarchy/supertypes` · `subtypes` | Backed by indexed `mixins` + inheritance. |
| `workspace/executeCommand` | See below. |

## Commands

`workspace/executeCommand` advertises these:

- `refract.restartIndexer`
- `refract.forceReindex`
- `refract.toggleGemIndex`
- `refract.showReferences`
- `refract.runTest`
- `refract.debugTest`
- `refract.recheckRubocop`
- `refract.disableDiagnostic`

## Error semantics

- Parse error → `-32700` (`-32700` per LSP 3.17).
- Unknown method → `MethodNotFound` (`-32601`).
- Malformed params → `InvalidParams` (`-32602`).
- Indexer not ready for a position-precise request → server falls back to a substring workspace-symbol response with `isIncomplete: true`.

## Configuration

See [Configure / Multi-Ruby](configure/multi_ruby.md) and [Configure / Telemetry](configure/telemetry.md). Workspace-level overrides live in `.refractrc.json` at the project root. Init options sent in the `initialize` request are merged on top.
