# Migrate from RubyMine

RubyMine is the most feature-complete Ruby IDE today. Refract aims to match the *editing* experience while letting you keep your editor of choice (VS Code, Neovim, Zed, …) and pay 0 % of RubyMine's per-seat cost.

## What you keep with RubyMine + refract together

You don't have to choose. Install the [JetBrains plugin](../extensions/jetbrains.md) — it routes RubyMine's LSP traffic through refract. That gives you refract's perf + Sorbet/Steep bridges + DAP while keeping RubyMine's project view, VCS UI, debugger UI, and refactor wizards.

## Parity matrix (refract standalone, no RubyMine)

| Feature                          | RubyMine    | refract |
|----------------------------------|-------------|---------|
| hover / def / refs / rename      | ✅          | ✅ (faster) |
| Rails project view               | ✅ (deep)   | partial — via routes/i18n/ERB tools |
| Refactoring (extract method/var) | ✅          | ✅      |
| Refactoring (extract class, push down, pull up) | ✅ | partial — extract method/var ship today; class-level land mid-2026 |
| Debugger                         | ✅ (UI rich) | ✅ (DAP — UI depends on host editor) |
| RuboCop / brakeman / sorbet      | via plugins | ✅ native bridges |
| AI assistance                    | JetBrains AI | ✅ provider-agnostic, BYOK |
| Project diagrams (UML)           | ✅          | ❌ (out of scope) |
| Database tools                   | ✅          | ❌ (use a separate DB tool) |
| Profiler                         | ✅          | partial — vernier inlay (see Lane C) |
| Memory ceiling                   | 1–4 GB      | 26–55 MB |

## Migration path

1. **Install refract** alongside RubyMine. They do not conflict — refract owns its own SQLite per-workspace.
2. **Test on one project.** Open in RubyMine + a second editor with refract. Compare: hover speed, completion correctness, refactor results.
3. **Move debug workflows.** Refract's `--dap` mode mirrors RubyMine's debugger feature set: breakpoints, conditional breakpoints, step-in/out/over, variables, evaluate-on-hover.
4. **Re-create scratch tools.** RubyMine "scratch files" → just open `*.rb` in `/tmp/`. RubyMine "Run/Debug configurations" → use editor-specific launch.json (VS Code) / nvim-dap config / `~/.config/refract/runs.toml`.

## Rollback

Refract sits next to RubyMine, never inside it. Remove the binary; RubyMine resumes unaffected.
