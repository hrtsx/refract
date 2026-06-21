# MCP Tools

Refract exposes 30 tools over the Model Context Protocol (MCP) when launched with `refract --mcp`. The server speaks the 2025-06-18 protocol revision over stdio.

Designed for LLM coding agents (Claude Code, Codex, custom): every tool grounds its output in the indexed workspace — no hallucinated symbols. Full parameter schemas are returned by `tools/list`.

## Code intelligence & types

| Tool | Purpose |
|---|---|
| `resolve_type` | Resolve the inferred type of a local variable at a source position |
| `class_summary` | Methods, constants, and mixins for a class or module |
| `method_signature` | Full signature and parameter types of a method |
| `explain_symbol` | Signature, callers, and on-demand diagnostics for a method in one call |
| `explain_type_chain` | How a variable's type was inferred (RBS, YARD, literal, chain) |

## Search

| Tool | Purpose |
|---|---|
| `workspace_symbols` | Search symbols across the workspace by name (FTS5 trigram), ranked by kind |
| `list_by_kind` | List all symbols of a kind (class, module, def, constant, …) |
| `get_file_overview` | Flat, line-ordered outline of one file |
| `find_unused` | Symbols with no recorded call sites (static dead-code); `kind`-filterable |

## Call graph & hierarchy

| Tool | Purpose |
|---|---|
| `find_references` | All recorded references to a symbol. Optional `ref_kind` (e.g. `call`) — call-site lookup lives here |
| `find_implementations` | Classes that define a given method name |
| `resolve_constant` | Resolve a constant reference to its declaration via Ruby's lexical+ancestor lookup; disambiguates same-named constants across namespaces (`nesting`-aware) |
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
| `list_routes` | Route helpers with controller and action details |
| `list_validations` | `validates` calls on a model |
| `list_callbacks` | ActiveRecord / ActionController callbacks on a model |
| `concern_usage` | Classes that include/prepend/extend a module or concern |
| `i18n_lookup` | Find i18n translation keys and their values |

## Diagnostics & quality

| Tool | Purpose |
|---|---|
| `diagnostics` | Parse + semantic diagnostics (`refract/nil-receiver`, `refract/wrong-arity`, …) for a file, computed on demand |
| `workspace_health` | File counts, type coverage, unused-def count, schema version |
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
