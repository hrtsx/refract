# Editor integrations

| Editor | Canonical extension | Local fallback (in this repo) |
|---|---|---|
| **VS Code** | [`vscode/`](vscode/) here — published to Marketplace | (n/a — canonical lives here) |
| **Neovim** | [`hrtsx/refract.vim`](https://github.com/hrtsx/refract.vim) — separate plugin repo | [`neovim/init.lua`](neovim/init.lua) — minimal `lspconfig` snippet for users without a plugin manager |
| **Zed** | [`hrtsx/zed-refract`](https://github.com/hrtsx/zed-refract) — separate extension repo | (n/a — see manual `.zed/settings.json` snippet in main [README](../README.md#zed)) |
| **Emacs** | [`emacs/refract.el`](emacs/refract.el) here | (also see `eglot` snippet in main [README](../README.md#emacs)) |
| **Helix** | Built-in via `languages.toml` | (see main [README](../README.md#helix)) |
| **Sublime Text** | Built-in via [LSP package](https://lsp.sublimetext.io/) | (see main [README](../README.md#sublime-text)) |

## Build the VS Code extension locally

```sh
cd vscode
npm install
npm run build
# load in VS Code: Extensions panel → "..." menu → Install from VSIX
# or: open the dir in VS Code and press F5 to launch a dev host
```

## Notes

- **VS Code** sends `disableTypeChecker`, `typeCheckerSeverity`, and other settings via `initializationOptions`. They hot-reload on `workspace/didChangeConfiguration`.
- **Neovim** plugin lives in [`refract.vim`](https://github.com/hrtsx/refract.vim) for compatibility with plugin managers (lazy.nvim, packer, etc.). The local `neovim/init.lua` is a manual fallback for no-plugin-manager setups.
- **Zed** extension lives in [`zed-refract`](https://github.com/hrtsx/zed-refract). For users who'd rather not install the extension, the main README has a per-project `.zed/settings.json` snippet that wires Refract directly.
