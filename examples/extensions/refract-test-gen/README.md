# refract-test-gen

Reference plugin. Reads gaps from refract's `coverage_gap_analyzer` MCP tool and
emits RSpec stubs the user can paste into their suite.

## Install

Copy this directory under `~/.refract/extensions/`:

```bash
cp -r examples/extensions/refract-test-gen ~/.refract/extensions/test-gen
chmod +x ~/.refract/extensions/test-gen/bin/refract-plugin-test-gen
```

Restart refract. Verify discovery:

```bash
refract --doctor 2>&1 | grep -i plugin
```

## Usage

Drive from any LSP client that can send a custom request:

```jsonc
// LSP request → server → plugin
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "refract.test-gen.suggest",
  "params": {
    "gaps": [
      { "name": "calculate_discount", "parent_name": "Cart",
        "file": "lib/cart.rb", "line": 42 }
    ]
  }
}
```

Or pipe `coverage_gap_analyzer` output to it directly via MCP:

```bash
# 1. Get gaps from refract MCP
refract --mcp <<EOF | jq '.result.content[0].text' -r > gaps.json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"coverage_gap_analyzer","arguments":{}}}
EOF

# 2. Pass to test-gen
echo "..." | ~/.refract/extensions/test-gen/bin/refract-plugin-test-gen
```

## What it generates

For each gap the plugin produces an RSpec spec stub with a `pending` expectation
pointing at the file/line of the uncovered method. The output is intentionally
minimal — a starting point, not a finished suite.

## Sandbox

`allow_network: false`, `allow_fs_write: []`. Plugin only reads stdin and
writes stdout. Refract v0.1.0 does **not** yet enforce these flags at the OS
level (Linux seccomp arrives in 0.2.0); they describe intent for now.

## License

MIT, matches refract.
