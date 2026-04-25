# Plugin authoring guide

This guide walks you through building a refract plugin. Plugins are subprocesses (any language) that speak JSON-RPC over stdio. Refract proxies declared LSP/MCP methods through the plugin's process.

## 5-minute hello-world

```bash
mkdir -p .refract/extensions/hello/bin
cat > .refract/extensions/hello/refract-extension.json <<'JSON'
{
  "id": "hello",
  "version": "0.1.0",
  "entry": "bin/run",
  "capabilities": { "lsp_requests": ["refract.hello.echo"] },
  "timeouts": { "initialize_ms": 5000, "request_ms": 2000, "shutdown_ms": 1000 },
  "sandbox": { "allow_network": false, "allow_fs_write": [] }
}
JSON

cat > .refract/extensions/hello/bin/run <<'RB'
#!/usr/bin/env ruby
require "json"
$stdout.sync = true
loop do
  hdrs = {}
  while (l = $stdin.gets)
    l.chomp!("\r\n"); break if l.empty?
    k, v = l.split(": ", 2); hdrs[k.downcase] = v
  end
  body = $stdin.read(hdrs["content-length"].to_i)
  msg  = JSON.parse(body)
  case msg["method"]
  when "initialize"        then resp = { capabilities: { lsp_requests: ["refract.hello.echo"] } }
  when "refract.hello.echo" then resp = { echoed: msg.dig("params","value") }
  when "shutdown"          then resp = nil
  when "exit"              then exit
  else next
  end
  out = JSON.generate(jsonrpc: "2.0", id: msg["id"], result: resp)
  $stdout.write("Content-Length: #{out.bytesize}\r\n\r\n#{out}")
end
RB
chmod +x .refract/extensions/hello/bin/run
```

Restart your editor. Refract auto-discovers the plugin and registers `refract.hello.echo`. Send via your editor's LSP client or:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"refract.hello.echo","params":{"value":"world"}}' | refract --stdio
```

## Manifest

Manifest fields are documented in [PROTOCOL.md](PROTOCOL.md). At minimum: `id`, `version`, `entry`, `capabilities`.

## Lifecycle

1. Refract discovers your plugin at startup or on `workspace/didChangeConfiguration`.
2. Refract spawns `entry` as a subprocess with `cwd` = plugin dir, stdin/stdout = JSON-RPC pipe, stderr = captured to `${workspace}/.refract/plugins/<id>/stderr.log`.
3. Refract sends `initialize`. You respond within `timeouts.initialize_ms` with `capabilities`.
4. Refract proxies declared methods. Each request includes a fresh `id`; you must echo it in your response.
5. Refract sends `shutdown` then `exit` on workspace close. Comply within `timeouts.shutdown_ms` or refract sends `SIGTERM` then `SIGKILL`.

## Reliability gates

- **Crash-isolated.** Your plugin can crash without bringing down refract. After 3 crashes in 10 minutes the plugin is disabled for the session.
- **Cooldown.** A crashed plugin enters 60 s cooldown before respawn.
- **Capability namespacing.** Methods you declare must NOT collide with core LSP methods (`initialize`, `textDocument/definition`, etc.). Refract rejects manifests that try.
- **Sandbox.** Declared `sandbox.allow_network = false` is enforced via Linux net-namespace unshare. `allow_fs_write` is enforced via tmpfs overlay (Linux) or `sandbox-exec` profile (macOS).

## Testing

Refract ships an example plugin at `examples/extensions/hello/` plus a Zig integration test (`src/lsp/plugin_host.zig`) that round-trips `refract.hello.echo`. Use that as a template.

## Distribution

Plugins are distributed as plain directories. Recommended ways to install:

- `${workspace}/.refract/extensions/<id>/` — workspace-local.
- `${XDG_DATA_HOME}/refract/extensions/<id>/` — user-global (default `~/.local/share/refract/extensions/`).
- For Ruby plugins, ship a gem with a `post_install_message` that copies the plugin into the user-global path.
