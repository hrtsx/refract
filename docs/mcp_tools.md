# MCP Tools

Refract exposes 34 tools over the Model Context Protocol (MCP) when launched with `refract --mcp`. The server speaks the 2025-06-18 protocol revision over stdio.

Designed for LLM coding agents (Claude Code, Codex, custom): every tool grounds its output in the indexed workspace — no hallucinated symbols.

## Code intelligence

- `resolve_type` — resolve a symbol's type at a (file, line, col) position.
- `class_summary` — methods, constants, mixins, ancestors for a class or module.
- `method_signature` — full sig with param types + return type.
- `explain_symbol` — long-form explanation: type chain, sources, confidence.
- `explain_type_chain` — show each step of the resolver (RBS → Sorbet → Steep → oracle → literal).
- `suggest_types` — propose RBS sigs for an untyped method.
- `type_coverage` — per-file or workspace typed-symbol percentage.

## Search

- `workspace_symbols` — name prefix/substring search with kind filter.
- `list_by_kind` — list every class / module / def / constant / association / route_helper.
- `get_file_overview` — outline view of one file.
- `find_unused` — symbols with zero references.
- `find_similar` — fuzzy-name candidates.

## Call graph

- `find_callers` — who calls `method_name`. Optional `ref_kind` filter: `call`, `assign`, `decl`, `super`, `yield`, `alias`.
- `find_implementations` — concrete definitions of a method across the workspace.
- `find_references` — all reference sites for a symbol. Optional `ref_kind` filter.
- `type_hierarchy` — ancestors + descendants for a class.

## Source access

- `get_symbol_source` — raw method body from disk, scoped to indexed paths only.
- `grep_source` — workspace-scoped regex grep. Path-traversal guarded by `realpath`.

## Rails

- `association_graph` — `belongs_to` / `has_many` / `has_one` / `has_and_belongs_to_many` for a model, including `:through` and `:source` resolution.
- `route_map` — route helpers from `config/routes.rb`.
- `i18n_lookup` — find a translation key across `config/locales/`.
- `list_validations` — every `validates` call on a model.
- `list_callbacks` — `before_*` / `after_*` / `around_*` callbacks on a model.
- `concern_usage` — what models include a given concern.

## Diagnostics

- `diagnostics` — current diagnostics for a file or workspace.
- `diagnostic_summary` — counts by severity, source, code.

## Workspace

- `workspace_health` — total files, total symbols, type coverage, diagnostic counts, schema version.
- `batch_resolve` — resolve up to 20 positions in one call.

## Code actions

- `refactor` — extract method / extract variable / inline. Returns an LSP `WorkspaceEdit` (caller applies).
- `available_code_actions` — which actions apply at a given position.

## Testing

- `test_summary` — RSpec / Minitest / Cucumber file coverage and last-run results.

## Conventions

- All tools accept `offset` for pagination and return `has_more: true|false`.
- Responses are bounded to 1 MiB; tools paginate on overflow.
- Path arguments accept `file:` URIs or absolute paths and are normalised through `realpath` with workspace-root containment.
- Every parameter is documented in the schema returned by `tools/list`.
