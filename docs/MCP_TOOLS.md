# Refract MCP Tools

Refract exposes a Model Context Protocol (MCP) server with 35 tools (including 2 aliases) for AI agent integration. All tools communicate over stdio with JSON-RPC 2.0.

## Connection

```json
{
  "mcpServers": {
    "refract": {
      "command": "refract",
      "args": ["--mcp"]
    }
  }
}
```

---

## Code Intelligence

### `resolve_type`
Resolve the inferred type of a local variable at a source position.

**Input:** `file` (string, required), `line` (integer 1-based, required), `col` (integer 0-based, optional)

**Output:** Type string (e.g. `"String"`, `"Array[User]"`, `"String | Integer"`) or null if unknown.

---

### `class_summary`
Get methods, constants, and mixins for a class or module.

**Input:** `class_name` (string, required)

**Output:** `{ methods, class_methods, constants, mixins, parent }`

---

### `method_signature`
Get the full signature and parameter types of a method.

**Input:** `symbol` (string, preferred — `"Class#method"`), or legacy `class_name` + `method_name`

**Output:** `{ name, params: [{name, kind, type_hint}], return_type, doc, file, line }`

---

### `explain_symbol`
Get a full picture of a method: signature, callers, and diagnostics in one call.

**Input:** `symbol` (string, preferred), or legacy `class_name` + `method_name`

**Output:** Combined method_signature + callers + diagnostics

---

### `explain_type_chain`
Explain how a local variable's type was inferred — shows the chain from source (RBS, YARD, literal, chain).

**Input:** `file` (string, required), `line` (integer 1-based, required), `col` (integer 0-based, required)

**Output:** Inference chain with confidence scores and sources.

---

### `suggest_types`
Suggest YARD/RBS type annotations for untyped methods in a file.

**Input:** `file` (string, required), `limit` (integer, default 20)

**Output:** List of `{ method, suggested_return_type, confidence }` entries.

---

### `type_coverage`
Show type annotation coverage per file — percentage of methods with return types.

**Input:** `file` (string, optional — omit for workspace-wide), `min_coverage` (number 0-100, default 100)

**Output:** List of `{ file, coverage_pct, typed, total }` entries.

---

## Symbol Search

### `workspace_symbols` / `find_symbol` / `search_symbols`
Search symbols across the entire workspace by name.

**Input:** `query` (string, required), `kind` (string optional — `class`, `def`, `module`, `constant`), `offset` (integer, default 0)

**Output:** Paginated list of `{ name, kind, file, line, parent_name }`

---

### `list_by_kind`
List all symbols of a given kind.

**Input:** `kind` (string, required — `class`, `module`, `def`, `constant`, `association`, `route_helper`), `name_filter` (string, optional prefix), `offset` (integer, default 0)

**Output:** Paginated list of symbols.

---

### `get_file_overview`
List all symbols in a file ordered by line (flat, fast overview).

**Input:** `file` (string, required — absolute or relative to workspace root)

**Output:** `[{ name, kind, line, visibility, return_type }]`

---

### `find_unused`
Find symbols with no recorded call sites (static dead-code approximation).

**Input:** `kind` (string, default `"def"`), `parent_name` (string, optional class filter)

**Output:** List of potentially unused symbols. Note: conservative — dynamic dispatch may cause false positives.

---

### `find_similar`
Find methods with similar names (typo detection, naming consistency).

**Input:** `method_name` (string, required), `max_distance` (integer, default 2)

**Output:** List of `{ name, edit_distance, file, line }`

---

## Call Graph

### `find_callers`
Find all call sites of a method in the workspace.

**Input:** `symbol` (string, preferred — `"Class#method"`), or legacy `class_name` + `method_name`, `offset` (integer, default 0)

**Output:** Paginated list of `{ file, line, context_snippet }`

---

### `find_implementations`
Find all classes that define a given method name.

**Input:** `method_name` (string, required), `offset` (integer, default 0)

**Output:** Paginated list of `{ class_name, file, line }`

---

### `find_references`
Find all recorded call-site references to a method or symbol name.

**Input:** `name` (string, required), `ref_kind` (string optional, e.g. `"method_call"`), `offset` (integer, default 0)

**Output:** Paginated list of references.

---

### `type_hierarchy`
Get ancestor chain and known descendants of a class.

**Input:** `class_name` (string, required), `ancestors_offset` (integer, default 0), `descendants_offset` (integer, default 0)

**Output:** `{ ancestors: [...], descendants: [...] }`

---

## Source Access

### `get_symbol_source`
Get the source code of a class method.

**Input:** `class_name` (string, required), `method_name` (string, required)

**Output:** Raw source text of the method body.

---

### `grep_source`
Search for literal text across all workspace source files with surrounding context.

**Input:** `query` (string, required), `file_pattern` (string optional, e.g. `"models/*.rb"`), `context_lines` (integer 0-5, default 1), `use_regex` (boolean, default false), `offset` (integer, default 0)

**Output:** Paginated list of `{ file, line, match, context }`

---

## Rails

### `association_graph`
Get ActiveRecord associations (has_many, belongs_to, etc) for a class.

**Input:** `class_name` (string, required), `offset` (integer, default 0)

**Output:** `{ associations: [{kind, name, class_name, through, options}] }` — `through` is present only for `has_many :x, through: :y` associations.

---

### `route_map` / `list_routes`
List Rails route helpers. `route_map` returns name+path, `list_routes` includes controller+action details.

**Input:** `prefix` (string, optional filter), `offset` (integer, default 0)

**Output:** Paginated list of route entries.

---

### `i18n_lookup`
Find i18n translation keys and their values.

**Input:** `query` (string, required — key prefix or substring), `offset` (integer, default 0)

**Output:** Paginated list of `{ key, value, locale, file }`

---

### `list_validations`
List ActiveRecord validation calls for a class.

**Input:** `class_name` (string, required)

**Output:** `[{ kind, attribute, options }]`

---

### `list_callbacks`
List ActiveRecord/ActionController callbacks for a class.

**Input:** `class_name` (string, required), `callback_type` (string optional, e.g. `"before_save"`), `offset` (integer, default 0)

**Output:** Paginated list of `{ callback_type, method_name, options }`

---

### `concern_usage`
Find all classes that include/prepend/extend a given module or concern.

**Input:** `module_name` (string, required), `offset` (integer, default 0)

**Output:** Paginated list of `{ class_name, kind, file, line }`

---

## Diagnostics

### `diagnostics`
Get parse and semantic diagnostics for a file (or all open files).

**Input:** `file` (string, optional — omit for workspace-wide), `offset` (integer, default 0)

**Output:** `[{ file, line, col, severity, message, code }]`

---

### `diagnostic_summary`
Get diagnostics with optional filtering by file, severity, or code.

**Input:** `file` (string, optional), `severity_filter` (string — `"error"`, `"warning"`, `"info"`), `code_filter` (string — RuboCop cop code)

**Output:** Filtered diagnostic list with counts.

---

## Workspace

### `workspace_health`
Get workspace quality metrics: file counts, type coverage, diagnostic summary, schema version.

**Input:** none

**Output:** `{ file_count, symbol_count, type_coverage_pct, error_count, schema_version }`

---

### `batch_resolve`
Resolve types at multiple source positions in one call (max 20 positions).

**Input:** `positions` (array, required — each: `{ file, line, col? }`)

**Output:** `[{ file, line, type }]` in the same order as input.

---

## Code Actions

### `refactor`
Apply refactoring operations to source code.

**Input:** `file` (string, required), `start_line` (integer 0-based), `end_line` (integer 0-based), `kind` (string — `"extract_method"` or `"extract_variable"`)

**Output:** `{ edit: { file, line, text } }`

---

### `available_code_actions`
Get list of available code actions at a specific location.

**Input:** `file` (string, required), `line` (integer 0-based, required), `character` (integer 0-based, default 0)

**Output:** `[{ title, kind, command }]`

---

## Testing

### `test_summary`
List discovered tests in a file with their kind (rspec/minitest) and line numbers.

**Input:** `file` (string, required — absolute path to test file)

**Output:** `[{ name, kind, line }]`
