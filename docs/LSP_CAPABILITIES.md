# LSP Capabilities by Editor

Refract implements the Language Server Protocol. Editor support depends on both the LSP feature and the client's implementation of that feature.

## Capability Matrix

| Capability | VS Code | Neovim (nvim-lspconfig) | Helix | Zed | Emacs (eglot) | Sublime (LSP) |
|---|---|---|---|---|---|---|
| **Hover** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Go to Definition** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Go to Declaration** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Go to Implementation** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Go to Type Definition** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Find References** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Completions** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Signature Help** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Workspace Symbol** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Document Symbol** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Rename** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Prepare Rename** | ✓ | ✓ | ✓ | ✓ | partial | ✓ |
| **Code Actions** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Code Lens** | ✓ | ✓ | partial | partial | ✗ | partial |
| **Inlay Hints** | ✓ | ✓ | ✓ | ✓ | partial | partial |
| **Semantic Tokens** | ✓ | ✓ | ✓ | ✓ | ✗ | partial |
| **Diagnostics (pull)** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **RuboCop Diagnostics** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Formatting** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Range Formatting** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Document Highlight** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Document Link** | ✓ | ✓ | partial | partial | ✗ | ✓ |
| **Folding Ranges** | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ |
| **Selection Range** | ✓ | ✓ | ✓ | ✓ | partial | ✓ |
| **Linked Editing** | ✓ | partial | ✗ | ✗ | ✗ | ✗ |
| **Call Hierarchy** | ✓ | ✓ | ✓ | partial | partial | ✗ |
| **Type Hierarchy** | ✓ | ✓ | partial | partial | ✗ | ✗ |
| **Progress (indexing bar)** | ✓ | ✓ | ✓ | ✓ | ✓ | partial |
| **Work Done Progress** | ✓ | ✓ | ✓ | ✓ | ✓ | partial |

✓ = fully supported  partial = supported with limitations  ✗ = not supported by client

---

## Configuration Snippets

### VS Code

Install the Refract extension, then configure in `settings.json`:

```json
{
  "refract.path": "refract",
  "refract.maxWorkers": 4,
  "refract.disableRubocop": false,
  "refract.rubocopDebounceMs": 1500,
  "refract.excludeDirs": ["tmp", "log", "coverage"],
  "refract.logLevel": 2
}
```

### Neovim (nvim-lspconfig)

```lua
require('lspconfig').refract.setup({
  cmd = { "refract" },
  filetypes = { "ruby", "eruby", "haml", "slim" },
  root_dir = require('lspconfig.util').root_pattern("Gemfile", ".git"),
  init_options = {
    maxWorkers = 4,
    rubocopDebounceMs = 1500,
    logLevel = 2,
  },
})
```

### Helix (`languages.toml`)

```toml
[[language]]
name = "ruby"
language-servers = ["refract"]

[language-server.refract]
command = "refract"
```

### Zed (`settings.json`)

```json
{
  "lsp": {
    "refract": {
      "binary": {
        "path": "refract"
      },
      "initialization_options": {
        "maxWorkers": 4,
        "rubocopDebounceMs": 1500
      }
    }
  }
}
```

### Emacs (eglot, `init.el`)

```elisp
(add-to-list 'eglot-server-programs
  '(ruby-mode . ("refract")))
(add-hook 'ruby-mode-hook 'eglot-ensure)
```

### Sublime Text (LSP package, `LSP.sublime-settings`)

```json
{
  "clients": {
    "refract": {
      "command": ["refract"],
      "enabled": true,
      "selector": "source.ruby, text.html.ruby"
    }
  }
}
```

---

## Notes on Partial Support

- **Code Lens (Helix, Zed):** These editors render code lens but may not show all lens types (test counts, reference counts). The LSP server sends all lens types; display is client-dependent.
- **Inlay Hints (Emacs, Sublime):** Server sends inlay hints; client rendering depends on version and configuration.
- **Semantic Tokens (Emacs):** eglot does not render semantic tokens by default. Use `eglot-booster` or a Tree-sitter grammar instead.
- **Linked Editing (non-VS Code):** Most editors don't implement `textDocument/linkedEditingRange`. VS Code is the primary target for this feature.
- **Type Hierarchy (Helix, Zed):** Partially implemented in these editors — subtypes/supertypes are queryable but UI may be limited.
