# refract

A fast Ruby LSP server backed by SQLite. Single static binary, no Ruby runtime required.
Powered by [Prism](https://github.com/ruby/prism) 1.9.0.

```
   editor (VS Code, Neovim, Helix, Zed, Emacs, Sublime)
              │  LSP over stdio
              ▼
   refract  ── parses Ruby with Prism ── persists to per-project SQLite ── serves LSP queries
              │
              └─ also: refract --mcp  (35 tools for AI agents)
```

**Why pick refract**

- **Cold install in seconds** — `brew install`, no `gem install`, no `bundler`, no YARD doc generation
- **Rails 5.2–8.0 DSL coverage** — `has_many`, `has_one_attached`, `delegated_type`, `composed_of`, `attribute :x, :integer`, etc.
- **Type-aware** — RBS + Sorbet sigs + literal narrowing power completion, hover, inlay hints
- **Light type checking** — `refract/nil-receiver` and `refract/wrong-arity` ship in v0.1, confidence-gated
- **AI-native** — `refract --mcp` exposes 35 tools your agent can call directly
- **Single binary** — drop into Docker, CI, anywhere. No Ruby on the path.

See [`docs/COMPARISON.md`](docs/COMPARISON.md) for an honest comparison with Solargraph, Ruby LSP, and Sorbet, plus when to pick each.

## Install

**macOS (Homebrew):**

```sh
brew install hrtsx/refract/refract
```

**Linux / manual:**

```sh
OS=$(uname -s); ARCH=$(uname -m)
case "$OS" in Darwin) OS=macos ;; *) OS=linux ;; esac
case "$ARCH" in arm64) ARCH=aarch64 ;; esac
curl -L "https://github.com/hrtsx/refract/releases/latest/download/refract-${ARCH}-${OS}" \
  -o ~/.local/bin/refract && chmod +x ~/.local/bin/refract
```

## 30-second quick start

```sh
# 1. Install (linux/macos)
brew install hrtsx/refract/refract              # or: curl from Releases (see above)

# 2. Verify
refract --version
refract --doctor                                 # paste-able diagnostic report

# 3. Index a Rails app (first run)
cd ~/code/my-rails-app
refract --check                                  # bootstraps the index, exits 0

# 4. Open your editor — it's already wired (see Editor Setup below)
```

Need to file an issue? `refract --doctor | gh issue create --body-file -` produces a clean report.

## Editor Setup

### VS Code

Install the extension from the Marketplace, or from source:

```sh
cd editors/vscode && npm install && npm run build
```

See [`editors/vscode/README.md`](editors/vscode/README.md) for commands, settings, and troubleshooting.

### Neovim

Via [refract.nvim](https://github.com/hrtsx/refract.nvim) (handles binary download automatically):

```lua
-- lazy.nvim
{
  "hrtsx/refract.nvim",
  build = function() require("refract").install() end,
  ft = { "ruby", "eruby", "haml" },
  opts = {},
}
```

Or manually if the binary is already in `PATH`:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "ruby", "eruby", "haml" },
  callback = function()
    vim.lsp.start({
      name = "refract",
      cmd = { "refract" },
      root_dir = vim.fs.root(0, { "Gemfile", ".git" }),
      init_options = { logLevel = 2 },
    })
  end,
})
```

### Helix

```toml
[language-server.refract]
command = "refract"

[[language]]
name = "ruby"
language-servers = ["refract"]
```

### Zed

Either install the [Refract Zed extension](editors/zed/README.md), or wire it manually in `.zed/settings.json`:

```json
{
  "lsp": {
    "refract": { "binary": { "path": "refract" } }
  },
  "languages": {
    "Ruby": { "language_servers": ["refract"] }
  }
}
```

### Emacs

```elisp
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs '(ruby-mode . ("refract"))))
```

### Sublime Text

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

See [`docs/LSP_CAPABILITIES.md`](docs/LSP_CAPABILITIES.md) for the full per-editor capability matrix and `initializationOptions` examples.

## Configuration

All options are passed via `initializationOptions` and hot-reload via `workspace/didChangeConfiguration`.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `disableGemIndex` | bool | false | Skip indexing gems in Gemfile |
| `disableRubocop` | bool | false | Disable RuboCop entirely |
| `maxFileSizeMb` | number | 8 | Max file size to index (MB) |
| `rubocopTimeoutSecs` | number | 30 | RuboCop subprocess timeout |
| `rubocopDebounceMs` | number | 1500 | Delay after save before running RuboCop |
| `bundleExecTimeoutSecs` | number | 15 | `bundle exec` gem-scan timeout |
| `maxWorkers` | number | cpu count (max 8) | Parallel indexing threads |
| `extraExcludeDirs` | string[] | [] | Extra directories to skip during scan |
| `logLevel` | number | 2 | 1=error 2=warn 3=info 4=debug |

## CLI

```sh
refract                        # start LSP server (stdin/stdout)
refract --mcp                  # start MCP server
refract --version              # print version and exit
refract --help                 # print usage
refract --doctor               # paste-able diagnostic report (version, db state, last crash)
refract --last-crash           # print most recent crash log and exit
refract --log-file F           # write logs to file
refract --log-level N          # set verbosity (1–4)
refract --db-path PATH         # override database path
refract --print-db-path        # print database path and exit
refract --reset-db             # delete database and exit
refract --check                # verify database integrity (0=ok, 1=fail)
refract --stats                # print file and symbol counts
refract --workspace-info       # print workspace + symbol-kind breakdown
```

`--stdio` is accepted and ignored (pass-through for editors that always add it).

## Diagnostics

| Code | What it catches | Severity (default) |
|---|---|---|
| [`refract/nil-receiver`](docs/diagnostics/refract-nil-receiver.md) | Method call on a `NilClass` receiver (would raise `NoMethodError`) | warning |
| [`refract/wrong-arity`](docs/diagnostics/refract-wrong-arity.md) | Call passes more positional args than the method accepts | warning |
| RuboCop offenses | Anything RuboCop flags (when available) | per RuboCop config |

To suppress a diagnostic for the workspace, append it to `.refract/disabled.txt` — or use the "Disable refract/X for this workspace" code action. Severity overrides via `refract.typeCheckerSeverity` (`error` / `warning` / `info`).

## Features

| Feature | Status |
|---------|--------|
| textDocument/completion — type-aware, route helpers, i18n keys | ✓ |
| textDocument/hover — types, YARD docs, constant values, Rails DSL | ✓ |
| textDocument/definition, declaration, implementation, typeDefinition | ✓ |
| textDocument/references | ✓ |
| textDocument/rename — MRO-aware, cross-file | ✓ |
| textDocument/prepareRename | ✓ |
| textDocument/signatureHelp | ✓ |
| textDocument/documentSymbol, workspace/symbol | ✓ |
| textDocument/inlayHint — return types, block params | ✓ |
| textDocument/semanticTokens (full, delta, range) | ✓ |
| textDocument/documentHighlight | ✓ |
| textDocument/documentLink — clickable requires | ✓ |
| textDocument/formatting, rangeFormatting — via RuboCop | ✓ |
| textDocument/codeAction — refactoring + RuboCop quickfix | ✓ |
| textDocument/diagnostic (pull) + publishDiagnostics | ✓ |
| textDocument/codeLens — reference counts | ✓ |
| textDocument/foldingRange, selectionRange, linkedEditingRange | ✓ |
| callHierarchy/incomingCalls + outgoingCalls | ✓ |
| typeHierarchy/subtypes + supertypes | ✓ |
| HAML / ERB template support | ✓ |
| Background workspace indexing with live progress | ✓ |

## MCP Server

Start with `refract --mcp`. Exposes 35 tools for AI agent integration.

**Highest-value tools for Rails projects:**

| Tool | What it gives | Latency |
|------|--------------|---------|
| `workspace_symbols` | Ranked fuzzy symbol search | ~9 ms |
| `class_summary` | Full method roster with visibility and types | ~3 ms |
| `association_graph` | `has_many`/`has_one`/`belongs_to` with typed returns | ~1 ms |
| `explain_symbol` | Signature + callers + diagnostics in one call | ~2 ms |
| `find_references` | Call-site hits with surrounding context | ~8 ms |
| `workspace_health` | File counts, type coverage, schema version | ~15 ms |

See [`docs/MCP_TOOLS.md`](docs/MCP_TOOLS.md) for the full tool reference.

## RuboCop

refract auto-detects RuboCop at startup. When a `Gemfile.lock` is present it probes `bundle exec rubocop` first, then falls back to bare `rubocop` in PATH — project-local versions are used automatically.

To re-run detection after adding RuboCop, use the `Refract: Re-check RuboCop` command.  
Set `disableRubocop: true` to disable entirely.

## Gem Indexing

Indexes installed gems from `Gemfile.lock`; `rbs_collection.lock.yaml` for RBS type discovery. Toggle at runtime with `refract.toggleGemIndex`.

## Database

One SQLite database per workspace at `~/.local/share/refract/<hash>.db`.

```sh
refract --reset-db   # delete and rebuild on next start
refract --check      # verify integrity
```

**Schema mismatch** after a downgrade triggers an automatic reset — this is expected. Upgrade with the install command above.

## Build from source

Requires Zig 0.16.0+.

```sh
git clone --recurse-submodules https://github.com/hrtsx/refract
cd refract
zig build --release=safe
# binary at zig-out/bin/refract
```

## How it works

On `initialized`, refract scans the workspace for `.rb`, `.rbs`, `.rbi`, `.erb`, `.rake`, `.gemspec`, `.ru` files plus `Gemfile`/`Rakefile`, and indexes classes, modules, methods, constants, routes, associations, and i18n keys into a per-project SQLite database. All LSP requests are answered by querying that database. File saves update the index incrementally via `workspace/didChangeWatchedFiles`.

Supports Ruby 2.7 – 3.4 syntax (via Prism 1.9.0). Works with Rails, plain gems, Rack apps, scripts, and monorepos.
