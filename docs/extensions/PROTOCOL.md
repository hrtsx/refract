# Refract Extension Protocol (v0.1)

Refract extensions run as **subprocess plugins** that speak JSON-RPC over stdio. They are language-agnostic (any executable that follows this protocol works), crash-isolated from the main refract process, and sandboxable through standard OS controls.

## Manifest

Each extension ships a `refract-extension.json` at its root.

```json
{
  "id": "dotenv-lookup",
  "version": "0.1.0",
  "entry": "bin/refract-plugin-dotenv",
  "description": "Hover over ENV[\"X\"] to see the resolved value",
  "capabilities": {
    "lsp_requests": ["textDocument/hover"],
    "lsp_notifications": ["textDocument/didOpen", "textDocument/didChange"],
    "mcp_tools": []
  },
  "timeouts": {
    "initialize_ms": 5000,
    "request_ms": 2000,
    "shutdown_ms": 1000
  },
  "sandbox": {
    "allow_network": false,
    "allow_fs_write": ["${workspace}/.refract/plugins/dotenv-lookup/"]
  }
}
```

### Required keys

- `id` — globally unique extension id (kebab-case).
- `version` — semver.
- `entry` — path to the executable, relative to the manifest.
- `capabilities.lsp_requests` / `lsp_notifications` / `mcp_tools` — declared methods. Plugins **cannot** declare core LSP methods (e.g., `initialize`, `textDocument/definition`) — refract owns those.

## Discovery

Refract scans the following locations on startup, in order:

1. `${workspace}/.refract/extensions/*/refract-extension.json`
2. `${XDG_DATA_HOME}/refract/extensions/*/refract-extension.json` (default `${HOME}/.local/share/refract/extensions/`)

Workspace plugins override user-global plugins of the same `id`.

## Lifecycle

```
refract                                       plugin
   |                                              |
   |-- spawn(entry) with stdin/stdout pipe ------>|
   |                                              |
   |-- initialize { workspace, refract_version }->|
   |<------------------- result { capabilities }--|
   |                                              |
   |-- {capability methods, proxied} ------------>|
   |<--------------------- responses --------------|
   |                                              |
   |-- shutdown -------------------------------->|
   |<------------------------------- result { } --|
   |-- exit (notification) --------------------->|
   |                                              | (process exits)
```

### `initialize` request

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "refract_version": "0.1.0",
    "workspace_root": "/abs/path/to/workspace",
    "config": { /* plugin-specific config from .refract/extensions/<id>/config.toml */ }
  }
}
```

The plugin must reply within `timeouts.initialize_ms` or it is marked **unhealthy** and not invoked further until refract restarts.

### Capability methods

For each `lsp_requests` entry, refract forwards the LSP request as-is (full JSON-RPC envelope including `id`). Plugin returns an LSP-shaped response. Refract validates the shape before relaying back to the editor.

For `lsp_notifications`, refract forwards the notification (no id, no response expected).

For `mcp_tools`, refract registers the tool in its `tools/list` response and routes `tools/call` invocations to the plugin.

### `shutdown` and `exit`

Same semantics as LSP. After `exit`, the process must terminate within `timeouts.shutdown_ms` or refract sends `SIGTERM` then `SIGKILL`.

## Health, crashes, and cooldown

- If the plugin process exits unexpectedly, refract surfaces an `info`-level LSP `window/showMessage` once and enters a **60-second cooldown** before attempting respawn.
- Three crashes in a 10-minute window mark the plugin **disabled** for the session.
- Plugin output to stderr is captured into `${workspace}/.refract/plugins/<id>/stderr.log` (truncated to last 64 KiB).

## Sandboxing

Refract enforces declared sandbox rules best-effort using the OS:

- `allow_network = false` — Linux: unshare net namespace; macOS: not enforced (best-effort warning).
- `allow_fs_write = [...]` — Linux: bind-mount `tmpfs` overlay restricting writes; macOS: best-effort via `sandbox-exec` profile.

A plugin that violates declared sandbox rules is killed immediately and entered into cooldown.

## Versioning

This document describes protocol **v0.1**. Refract advertises supported protocol versions in the `initialize` response under `capabilities.protocol_versions`. Plugins must respect the version they negotiate. Breaking changes bump the major version; additive changes the minor.

## Hello-world reference

See `examples/extensions/hello/` for a minimal plugin that registers `refract.hello.echo` and round-trips a string.
