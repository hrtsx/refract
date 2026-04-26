# Telemetry

Refract ships an OpenTelemetry exporter. **Disabled by default. No data leaves the box without explicit configuration.**

## Enable

Add to `.refractrc.json` at the workspace root:

```json
{
  "telemetry": {
    "enabled": true,
    "endpoint": "https://otel.example.com",
    "service_name": "refract"
  }
}
```

Or set the standard env var:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.example.com
export OTEL_SERVICE_NAME=refract
```

If the endpoint already ends with `/v1/metrics`, Refract uses it as-is. Otherwise the path is appended.

## What is sent

- Per-LSP-method latency histograms (p50, p95, p99 microseconds).
- Per-MCP-tool call counts and latencies.
- Index size (file count, symbol count).
- No source code, no file paths, no symbol names, no user identifiers.

## Bounded queue

At most 4 in-flight HTTP requests. New requests are dropped if the queue is full. No retries — telemetry is fire-and-forget.

## Crash dumps

Crash dumps are local-only. Refract writes them under `$XDG_STATE_HOME/refract/` (default `~/.local/state/refract/`) with mode `0o600`. View the most recent one with:

```bash
refract --last-crash
```

The crash dump format includes: panic message, stack trace, ring buffer of the last 100 LSP messages received. No source code is captured.

## Sentry / Glitchtip

Not built in. If you want crash dumps shipped to a remote service, configure a shell hook on `~/.local/state/refract/`:

```bash
# in your .bashrc
inotifywait -m ~/.local/state/refract/ -e create | while read; do
  cat ~/.local/state/refract/*.txt | curl -X POST https://sentry.example.com/ingest
done
```

## Opt out

To disable everything:

```json
{
  "telemetry": { "enabled": false }
}
```

Default. No action needed for the off case.
