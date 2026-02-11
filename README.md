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

Use a generic LSP client extension (e.g. `vscode-glspc`) and add to `.vscode/settings.json`:

```json
{
  "languageserver": {
    "refract": {
      "command": "refract",
      "filetypes": ["ruby", "erb"]
    }
  }
}
```

## Emacs

With [eglot](https://github.com/joaotavora/eglot) (built-in since Emacs 29):

```elisp
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '(ruby-mode . ("refract"))))
```

Activate with `M-x eglot` in a Ruby buffer.

## Features

| Feature | Status |
|---------|--------|
| workspace/symbol | ✓ |
| textDocument/definition | ✓ |
| textDocument/declaration | ✓ |
| textDocument/implementation | ✓ |
| textDocument/typeDefinition | ✓ |
| textDocument/hover | ✓ |
| textDocument/documentSymbol | ✓ |
| textDocument/completion | ✓ |
| textDocument/references | ✓ |
| textDocument/signatureHelp | ✓ |
| textDocument/rename | ✓ |
| textDocument/inlayHint | ✓ |
| textDocument/semanticTokens | ✓ |
| textDocument/documentHighlight | ✓ |
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

## Database

refract stores one SQLite database per workspace at:

```
~/.local/share/refract/<hash>.db
```

To reset the index, run `refract --reset-db` and restart the server.

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
