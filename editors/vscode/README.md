# Refract Ruby LSP

Zero-dependency Ruby language server for VS Code, powered by [Refract](https://github.com/hrtsx/refract).

## Requirements

- The `refract` binary must be in your `PATH`, or configured via `refract.path`
- Ruby project (Gemfile, `.rb` files, or Rakefile detected automatically)
- Optional: RuboCop in `PATH` or `bundle exec rubocop` for diagnostics

## Installation

1. Install the Refract binary:
   ```sh
   curl -fsSL https://github.com/hrtsx/refract/releases/latest/download/install.sh | sh
   ```
2. Install this extension from the VS Code Marketplace.
3. Open a Ruby project — the extension activates automatically.

## Features

- **Type-aware completions** — receiver type inference, route helpers, i18n keys, ENV keys, require paths
- **Hover** — types, YARD docs, parameter descriptions, `@example` blocks, `@deprecated` warnings
- **Go to definition / implementation / references** — MRO-aware, follows mixins
- **Rename** — safe cross-file rename that respects inheritance and mixins
- **Inlay hints** — return types and block parameter types
- **Diagnostics** — Prism parse errors + RuboCop (with debounce)
- **Code actions** — extract method/variable, RuboCop auto-fix
- **Rails** — routes, associations, validations, callbacks, i18n
- **HAML/ERB** — template-aware context detection
- **Progress indicator** — status bar shows live indexing progress

## Commands

Open the Command Palette (`Cmd+Shift+P`) and search for:

| Command | Description |
|---|---|
| `Refract: Restart Indexer` | Restart the background indexer without restarting the server |
| `Refract: Force Reindex Workspace` | Clear the index and re-index all files from scratch |
| `Refract: Toggle Gem Indexing` | Enable/disable gem indexing at runtime |
| `Refract: Re-check RuboCop` | Re-detect RuboCop in PATH (useful after installing RuboCop) |
| `Refract: Show References` | Show references for the symbol at the cursor |
| `Refract: Run Test` | Run the test at the cursor |

## Configuration

| Setting | Default | Description |
|---|---|---|
| `refract.path` | `"refract"` | Path to the refract binary |
| `refract.disableGemIndex` | `false` | Skip indexing gems from Gemfile |
| `refract.disableRubocop` | `false` | Disable RuboCop integration |
| `refract.maxFileSizeMb` | `8` | Maximum file size for indexing (MB) |
| `refract.maxWorkers` | `0` | Parallel indexer workers (0 = CPU count, max 8) |
| `refract.excludeDirs` | `[]` | Additional directories to exclude from indexing |
| `refract.logLevel` | `2` | Log verbosity: 1=error, 2=warn, 3=info, 4=debug |
| `refract.rubocopDebounceMs` | `1500` | Milliseconds to wait after a save before running RuboCop |

## Troubleshooting

**`'refract' not found` error on startup**
- Ensure the binary is installed and in your shell `PATH`
- Or set `refract.path` to the absolute path of the binary
- Click "Open Settings" in the error notification for quick access

**Completions or hover are slow on first open**
- The server indexes the workspace in the background on startup
- The status bar shows `⟳ Refract: indexing…` while in progress
- Hover and completions work immediately but may improve as indexing finishes

**RuboCop diagnostics not showing**
- Run `Refract: Re-check RuboCop` from the Command Palette
- Ensure `rubocop` or `bundle exec rubocop` is accessible from the project directory
- Check the Output panel (`Refract` channel) for error details

**Settings changed but not taking effect**
- Most settings require a window reload (the extension will prompt you)

**High memory usage on large monorepos**
- Increase `refract.excludeDirs` to skip generated or vendor directories
- Reduce `refract.maxFileSizeMb` to skip large auto-generated files
- Reduce `refract.maxWorkers` to limit parallel indexing
