# MCP Tools

Refract exposes 41 tools over the Model Context Protocol (MCP) when launched with `refract --mcp`. The server speaks the 2025-06-18 protocol revision over stdio.

Designed for LLM coding agents (Claude Code, Codex, custom): every tool grounds its output in the indexed workspace — no hallucinated symbols. Full parameter schemas are returned by `tools/list`.

## Code intelligence & types

| Tool | Purpose |
|---|---|
| `resolve_type` | Resolve the inferred type of a local variable at a source position |
| `class_summary` | Methods, constants, and mixins for a class or module |
| `method_signature` | Full signature and parameter types of a method |
| `explain_symbol` | Signature, callers, and diagnostics for a method in one call |
| `explain_type_chain` | How a variable's type was inferred (RBS, YARD, literal, chain) |
| `suggest_types` | Suggest YARD/RBS annotations for untyped methods in a file |
| `type_coverage` | Per-file percentage of methods with return types |
| `batch_resolve` | Resolve types at up to 20 positions in one call |

## Search

| Tool | Purpose |
|---|---|
| `workspace_symbols` | Search symbols across the workspace by name (FTS5 trigram) |
| `list_by_kind` | List all symbols of a kind (class, module, def, constant, …) |
| `get_file_overview` | Flat, line-ordered outline of one file |
| `find_unused` | Symbols with no recorded call sites (static dead-code) |
| `find_similar` | Methods with similar names (typo / naming checks) |

## Call graph & hierarchy

| Tool | Purpose |
|---|---|
| `find_callers` | Call sites of a method. Optional `ref_kind` filter |
| `find_implementations` | Classes that define a given method name |
| `find_references` | All recorded references to a symbol. Optional `ref_kind` |
| `type_hierarchy` | Ancestor chain and known descendants of a class |

## Source access

| Tool | Purpose |
|---|---|
| `get_symbol_source` | Source of a class method, scoped to indexed paths |
| `grep_source` | Literal text search across workspace files with context |

## Rails

| Tool | Purpose |
|---|---|
| `association_graph` | ActiveRecord associations (`has_many`, `belongs_to`, …) for a model |
| `route_map` | Route helpers with optional prefix filter |
| `list_routes` | Route helpers with controller and action details |
| `list_validations` | `validates` calls on a model |
| `list_callbacks` | ActiveRecord / ActionController callbacks on a model |
| `concern_usage` | Classes that include/prepend/extend a module or concern |
| `i18n_lookup` | Find i18n translation keys and their values |
| `unused_association_chain` | Unused ActiveRecord associations |
| `migration_chain_analyzer` | Rails migrations analysed for dependency hazards |
| `dependency_tree_resolver` | Transitive dependency DAG from `Gemfile.lock` |

## Diagnostics & quality

| Tool | Purpose |
|---|---|
| `diagnostics` | Parse and semantic diagnostics for a file |
| `diagnostic_summary` | Diagnostics filtered by file, severity, or code |
| `coverage_gap_analyzer` | Untested definitions, ranked by reference count |
| `security_audit_summary` | Aggregated security findings with severity scoring |

## Workspace

| Tool | Purpose |
|---|---|
| `workspace_health` | File counts, type coverage, diagnostic summary, schema version |
| `test_summary` | Discovered tests in a file with kind (rspec/minitest) and lines |

## Code actions

| Tool | Purpose |
|---|---|
| `refactor` | Apply `extract_method` / `extract_variable`; returns a `WorkspaceEdit` |
| `available_code_actions` | Code actions available at a location |

## Overlay (writable graph)

Branch-scoped, reversible, audited. The only writable graph surface — derived facts stay immutable.

| Tool | Purpose |
|---|---|
| `overlay_annotate` | Add a gated tweak (note/tag/concept/edge/type-override/diagnostic-suppress) |
| `overlay_list` | List live overlay tweaks for the project and branch |
| `overlay_revert` | Soft-delete an overlay tweak by id |
| `overlay_promote` | Promote branch-scoped tweaks to project-global |

## Conventions

- Tools accept `offset` for pagination and return `has_more: true|false`.
- Responses are bounded to 1 MiB; tools paginate on overflow.
- Path arguments accept `file:` URIs or absolute paths, normalised through `realpath` with workspace-root containment.
