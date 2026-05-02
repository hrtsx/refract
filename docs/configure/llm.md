# AI / LLM integration

Refract ships an LLM adapter for inline completions. **It is disabled by default** and sends nothing over the network unless you opt in.

## Enable

Add to `.refractrc.json` at the workspace root:

```json
{
  "llm": {
    "enabled": true,
    "provider": "anthropic",
    "model": "claude-3-5-sonnet-20241022",
    "endpoint": "https://api.anthropic.com/v1/messages",
    "auth_env_var": "ANTHROPIC_API_KEY",
    "timeout_ms": 200
  }
}
```

Supported providers: `anthropic`, `openai`, `ollama` (local). For Ollama, point `endpoint` at `http://localhost:11434/api/generate`; no auth needed.

## API keys

Refract reads the API key from the environment variable named in `auth_env_var`. The key is never written to disk or logs. If the variable is unset, the adapter logs an error and disables itself.

## Privacy

When enabled, Refract sends the **current file's prefix** (up to the cursor position) to the configured endpoint. No other workspace files, no Gemfile contents, no shell history. The request includes a stop sequence to prevent generation past the current line.

Set `"streaming": true` in the config to stream completions; default is single-shot.

## MCP server (for agents)

The MCP server is a separate concern. `refract --mcp` runs an agent-facing API that does not call any LLM itself — it only exposes workspace intelligence to whatever agent (Claude, Codex, etc.) connected. No data leaves the box unless the agent itself sends it.

## Disable

```json
{
  "llm": { "enabled": false }
}
```

Or simply omit the `llm` block.

## Cost control

- Hard timeout of 200 ms per request (configurable via `timeout_ms`).
- No retries on 4xx / 5xx — the request is dropped and inline completion falls back to refract's local heuristics.
- Set `"max_tokens": <n>` to cap completion length; default 64.
