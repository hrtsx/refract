# Install

Refract ships a single static binary. Platforms: Linux x86_64 + aarch64 (glibc and musl), macOS x86_64 + aarch64. **Windows is not supported in v0.1.0.**

## macOS — Homebrew

```bash
brew install hrtsx/refract/refract
refract --version
```

## Linux — curl

```bash
ARCH=$(uname -m | sed 's/amd64/x86_64/;s/arm64/aarch64/')
OS=linux
curl -fsSL "https://github.com/hrtsx/refract/releases/latest/download/refract-${ARCH}-${OS}" \
  -o ~/.local/bin/refract
chmod +x ~/.local/bin/refract
refract --version
```

Make sure `~/.local/bin` is on your `PATH`. If not, add it to your shell rc:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

## Build from source

```bash
git clone --recurse-submodules https://github.com/hrtsx/refract
cd refract
zig build -Drelease=true
install -m 0755 zig-out/bin/refract ~/.local/bin/refract
```

Requires Zig 0.16.0 exactly. Use [mise](https://mise.jdx.dev) or [asdf](https://asdf-vm.com) to pin the version. Build is fully offline after `zig fetch`; vendor sources for Prism and SQLite are checked into the repo.

## Verify

```bash
refract --self-test    # spawns LSP + MCP children, expects clean handshake
refract --doctor       # checklist: schema, RBS, rdbg, OTLP, Ruby env
```

Both should exit 0. Doctor warnings are non-fatal; fix advice is printed inline.

## Editor wiring

After install, point your editor at `refract --stdio`. Per-editor configs live under `editors/<name>/` in the repo. The LSP runs in workspace mode by default; no project-level configuration required.

## Uninstall

```bash
brew uninstall refract           # macOS
rm ~/.local/bin/refract          # Linux manual install
rm -rf ~/.local/share/refract    # index databases
```

Refract stores its per-workspace SQLite index under `$XDG_DATA_HOME/refract/` (default `~/.local/share/refract/`). Crash dumps under `$XDG_STATE_HOME/refract/` (default `~/.local/state/refract/`).
