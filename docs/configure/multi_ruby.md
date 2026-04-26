# Multi-Ruby

Refract detects which Ruby toolchain to use by checking, in order:

1. `.tool-versions` (asdf or mise) — line `ruby <ver>`
2. `.ruby-version` (chruby, rbenv)
3. `mise.toml` `[tools]` section — `ruby = "<ver>"`
4. `$RBENV_VERSION` env var
5. `$CHRUBY_VERSION` env var
6. Mise global install — first `ruby` directory under `$MISE_DATA_DIR` / `$XDG_DATA_HOME/mise` / `$HOME/.local/share/mise`
7. `ruby` on `PATH`

`refract --doctor` prints which manager was selected.

## Override

Set `RUBYBIN` to skip auto-detection:

```bash
export RUBYBIN=/opt/homebrew/opt/ruby@3.4/bin/ruby
refract --doctor
```

## Bundler

For projects with a `Gemfile`, Refract spawns RuboCop, Brakeman, Semgrep, Sorbet, Steep, and rdbg via `bundle exec`. Set `BUNDLE_GEMFILE` to override the path.

## Multiple Rubies per workspace

Refract caches per-workspace indexes by the hash of the workspace root. Switching Ruby versions does not invalidate the index — only changes to source files do. If you want to clear the cache after a Ruby upgrade:

```bash
refract --reset-db
```

## CI

In CI, prefer `RUBYBIN=$(which ruby)` plus `--disable-rubocop` if you don't want RuboCop spawning per file. The index is portable across machines as long as workspace paths match; we recommend caching `~/.local/share/refract/<hash>.db` keyed on `Gemfile.lock`.
