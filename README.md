# refract

A fast Ruby LSP server backed by SQLite.

## Install

Download the latest binary:

```sh
OS=$(uname -s); ARCH=$(uname -m)
case "$OS" in Darwin) OS=macos ;; *) OS=linux ;; esac
case "$ARCH" in arm64) ARCH=aarch64 ;; esac
curl -L "https://github.com/fedhtrsx/refract/releases/latest/download/refract-${ARCH}-${OS}" \
  -o ~/.local/bin/refract && chmod +x ~/.local/bin/refract
```

## CLI

```sh
refract                        # start LSP server (stdin/stdout)
refract --mcp                  # start MCP server
refract --version              # print version and exit
refract --help                 # print usage and exit
refract --verbose              # enable verbose logging
refract --log-file F           # write logs to FILE
refract --log-level 1|2|3|4   # set log verbosity (1=error 2=warn 3=info 4=debug)
refract --disable-rubocop      # disable RuboCop at startup (skips PATH probe)
refract --db-path PATH         # override database file path (must be absolute)
refract --print-db-path        # print database path and exit
refract --reset-db             # delete database and exit
refract --check                # verify database integrity and exit (0=ok, 1=fail)
refract --stats                # print file and symbol counts and exit
```

`--stdio` is accepted and ignored (pass-through for editors that always add it).

## Build from source

Requires Zig 0.15.2+.

```sh
git clone --recurse-submodules https://github.com/fedhtrsx/refract
cd refract
zig build -Doptimize=ReleaseSafe
# binary at zig-out/bin/refract
```

## Neovim

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "ruby",
  callback = function()
    vim.lsp.start({
      name = "refract",
      cmd = { "refract" },
      root_dir = vim.fs.root(0, { "Gemfile", ".git" }),
    })
  end,
})
```

## Helix

```toml
[language-server.refract]
command = "refract"

[[language]]
name = "ruby"
language-servers = ["refract"]
```

## Zed

Add to `.zed/settings.json`:

```json
{
  "lsp": {
    "refract": {
      "command": "refract"
    }
  },
  "languages": {
    "Ruby": {
      "language_servers": ["refract"]
    }
  }
}
```

## VS Code

A dedicated extension is available in `editors/vscode/`. To install from source:

```sh
cd editors/vscode && npm install && npm run build
```

Or use a generic LSP client extension (e.g. `vscode-glspc`) with `.vscode/settings.json`:

```json
{
  "languageserver": {
    "refract": {
      "command": "refract",
      "filetypes": ["ruby", "erb", "haml", "slim"]
    }
  }
}
```

Settings (when using the dedicated extension):

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `refract.path` | string | `"refract"` | Path to refract binary |
| `refract.disableGemIndex` | bool | `false` | Skip gem indexing |
| `refract.disableRubocop` | bool | `false` | Disable RuboCop |
| `refract.maxFileSizeMb` | number | `5` | Max file size to index (MB) |
| `refract.maxWorkers` | number | `4` | Parallel indexing threads |
| `refract.excludeDirs` | string[] | `[]` | Directories to skip |
| `refract.logLevel` | string | `"info"` | Log verbosity |

## Emacs

With [eglot](https://github.com/joaotavora/eglot) (built-in since Emacs 29):

```elisp
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '(ruby-mode . ("refract"))))
```

Activate with `M-x eglot` in a Ruby buffer.

## Sublime Text

Install the [LSP](https://packagecontrol.io/packages/LSP) package, then add to
`Preferences > Package Settings > LSP > Settings`:

```json
{
  "clients": {
    "refract": {
      "enabled": true,
      "command": ["refract"],
      "selector": "source.ruby | text.html.ruby"
    }
  }
}
```

## Features

| Feature | Status |
|---------|--------|
| workspace/symbol | ✓ |
| textDocument/definition | ✓ |
| textDocument/declaration | ✓ |
| textDocument/implementation | ✓ |
| textDocument/typeDefinition | ✓ |
| textDocument/hover (with nil-aware detection) | ✓ |
| textDocument/documentSymbol | ✓ |
| textDocument/completion (type-aware, route helpers, i18n keys) | ✓ |
| textDocument/references | ✓ |
| textDocument/signatureHelp | ✓ |
| textDocument/rename | ✓ |
| textDocument/inlayHint (method types, block params) | ✓ |
| textDocument/semanticTokens | ✓ |
| textDocument/documentHighlight | ✓ |
| textDocument/documentLink (clickable requires) | ✓ |
| textDocument/formatting | ✓ (requires rubocop) |
| textDocument/rangeFormatting | ✓ (requires rubocop) |
| textDocument/codeAction | ✓ (requires rubocop) |
| textDocument/diagnostic (pull) | ✓ |
| textDocument/codeLens | ✓ |
| textDocument/foldingRange | ✓ |
| textDocument/selectionRange | ✓ |
| textDocument/linkedEditingRange | ✓ |
| callHierarchy/prepare + incomingCalls + outgoingCalls | ✓ |
| typeHierarchy/subtypes + supertypes | ✓ |
| HAML template support | ✓ |
| ERB template support | ✓ |
| File watch (create/change/delete) | ✓ |
| Background workspace indexing | ✓ |

## Configuration

Pass options via `initializationOptions` in your editor config:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `disableGemIndex` | bool | false | Skip indexing gems in Gemfile; native extensions (.so, .bundle) are skipped automatically |
| `disableRubocop` | bool | false | Disable rubocop entirely (formatting, diagnostics) |
| `maxFileSizeBytes` | number | 8388608 | Max file size to index in bytes; skipped files are logged as warnings |
| `maxFileSizeMb` | number | — | Max file size in MB (overrides `maxFileSizeBytes`) |
| `rubocopTimeoutSecs` | number | 30 | Rubocop subprocess timeout |
| `bundleExecTimeoutSecs` | number | 15 | `bundle exec` gem-scan timeout |
| `maxWorkers` | number | cpu count (max 8) | Parallel indexing threads; capped at min(cpu_count, value, 16) |
| `excludeDirs` | string[] | [] | Additional directory names to skip during workspace scan (adds to built-in skip list: `tmp`, `log`, `coverage`, `public`, `.bundle`, `node_modules`) |
| `logLevel` | number | 2 | 1=error 2=warn 3=info 4=debug |

**Neovim example:**

```lua
vim.lsp.start({
  name = "refract",
  cmd = { "refract" },
  root_dir = vim.fs.root(0, { "Gemfile", ".git" }),
  init_options = { disableGemIndex = true },
})
```

**Helix example:**

```toml
[language-server.refract]
command = "refract"

[language-server.refract.config]
disableGemIndex = true
```

**Zed example** (`.zed/settings.json`):

```json
{
  "lsp": {
    "refract": {
      "command": "refract",
      "initialization_options": {
        "disableGemIndex": false,
        "maxFileSizeBytes": 8388608
      }
    }
  }
}
```

**VS Code example** (`.vscode/settings.json`, requires generic LSP extension):

```json
{
  "languageserver": {
    "refract": {
      "command": "refract",
      "filetypes": ["ruby", "erb"],
      "initializationOptions": {
        "disableGemIndex": false,
        "maxFileSizeBytes": 8388608
      }
    }
  }
}
```

## RuboCop

refract auto-detects RuboCop at startup. When a `Gemfile.lock` is present in the workspace,
it probes `bundle exec rubocop` first before falling back to bare `rubocop` in PATH. This
means project-local RuboCop versions are used automatically with no configuration required.

To re-run the detection (e.g. after adding RuboCop to a project), use the
`refract.recheckRubocop` command from your editor's command palette.

Set `disableRubocop: true` in `initializationOptions` to disable RuboCop entirely.

## MCP Server

Start the MCP server with `refract --mcp`. The server exposes 28 tools, 3 compound tools, and 2 resources:

**Type & Symbol Resolution**

| Tool | Parameters | Description |
|------|-----------|-------------|
| `resolve_type` | `file`, `line`, `col?` | Resolve inferred type of a local variable at a source position |
| `class_summary` | `class_name` | Get methods, constants, and mixins for a class or module |
| `method_signature` | `class_name`, `method_name` | Get full signature and parameter types of a method |
| `explain_symbol` | `class_name`, `method_name` | Full picture: signature, callers, and diagnostics in one call |
| `batch_resolve` | `positions[]` | Resolve types at multiple source positions (max 20) |

**Navigation & Search**

| Tool | Parameters | Description |
|------|-----------|-------------|
| `workspace_symbols` | `query`, `kind?`, `offset?` | Search symbols across workspace by name |
| `find_callers` | `method_name`, `class_name?`, `offset?` | Find all call sites of a method |
| `find_implementations` | `method_name`, `offset?` | Find all classes that define a given method |
| `find_references` | `name`, `ref_kind?`, `offset?` | Find all recorded call-site references |
| `type_hierarchy` | `class_name` | Get ancestor chain and known descendants |
| `get_symbol_source` | `class_name`, `method_name` | Get source code of a class method |
| `grep_source` | `query`, `file_pattern?`, `context_lines?`, `use_regex?`, `offset?` | Search text across all workspace files |

**Rails Integration**

| Tool | Parameters | Description |
|------|-----------|-------------|
| `association_graph` | `class_name`, `offset?` | Get ActiveRecord associations for a class |
| `route_map` | `prefix?`, `offset?` | List all Rails route helpers |
| `list_routes` | `prefix?`, `offset?` | List route helpers with controller and action details |
| `i18n_lookup` | `query`, `offset?` | Find i18n translation keys and values |
| `list_validations` | `class_name` | List ActiveRecord validation calls |
| `list_callbacks` | `class_name`, `callback_type?`, `offset?` | List callbacks for a class |
| `concern_usage` | `module_name`, `offset?` | Find classes that include/prepend/extend a module |

**Diagnostics & Analysis**

| Tool | Parameters | Description |
|------|-----------|-------------|
| `diagnostics` | `file?`, `offset?` | Get parse and semantic diagnostics |
| `diagnostic_summary` | `file?`, `severity_filter?`, `code_filter?` | Diagnostics with filtering |
| `workspace_health` | — | File counts, type coverage, schema version |
| `find_unused` | `kind?`, `parent_name?` | Find symbols with no call sites (dead-code) |
| `list_by_kind` | `kind`, `name_filter?`, `offset?` | List all symbols of a given kind |
| `get_file_overview` | `file` | List all symbols in a file by line |
| `test_summary` | `file` | List discovered tests with kind and line numbers |

**Refactoring**

| Tool | Parameters | Description |
|------|-----------|-------------|
| `refactor` | `file`, `start_line`, `end_line`, `kind` | Extract method or variable |
| `available_code_actions` | `file`, `line`, `character?` | List available code actions at a location |

**Compound Tools** (multi-step, richer output)

| Tool | Parameters | Description |
|------|-----------|-------------|
| `class-overview` | `class_name` | Summarize purpose, public API, associations |
| `trace-callers` | `class_name`, `method_name` | Show all callers with usage patterns |
| `find-bugs` | `file` | List potential bugs and type mismatches |

**Resources**

| URI | Description |
|-----|-------------|
| `refract://workspace/summary` | File count, symbol count, schema version |
| `refract://class/{ClassName}` | All methods with types and docs for a class |

## Database

refract stores one SQLite database per workspace at:

```
~/.local/share/refract/<hash>.db
```

To reset the index, run `refract --reset-db` and restart the server.

## Troubleshooting

**Database schema mismatch**

If you see "resetting DB (schema newer than binary)", the database was auto-reset.
This is normal after a downgrade. To manually upgrade refract:

```sh
curl -L "https://github.com/fedhtrsx/refract/releases/latest/download/refract-$(uname -m | sed 's/arm64/aarch64/')-$(uname -s | sed 's/Darwin/macos/')" \
  -o ~/.local/bin/refract && chmod +x ~/.local/bin/refract
```

**Verify database integrity**

Run `refract --check` to verify the database is not corrupted:

```sh
refract --check  # exits 0 if OK, 1 if corrupted
```

**Reset the database**

If the index is stale or corrupted, reset it:

```sh
refract --reset-db  # deletes database, will rebuild on next startup
```

**View index statistics**

Check how many files and symbols are indexed:

```sh
refract --stats  # shows file count, symbol count, cache info
```

## How it works

On `initialized`, refract scans the workspace for `.rb`, `.rbs`, `.rbi`, `.erb`,
`.rake`, `.gemspec`, `.ru` files and `Gemfile`/`Rakefile`, and indexes
classes, modules, methods, and constants into a per-project SQLite database
stored in `~/.local/share/refract/`. Subsequent file saves update the index
incrementally. All LSP requests are answered by querying that database.

The first index run scans all workspace `.rb`, `.rbs`, `.rbi`, `.erb`, `.rake`, `.gemspec`,
`.ru` files, plus `Gemfile` and `Rakefile`, in the background,
reporting progress in the editor status bar. Subsequent starts are incremental — only changed
files are re-indexed.

refract works with any Ruby project — Rails, plain gems, Rack apps, scripts, or monorepos.
