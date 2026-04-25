#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
nvim --headless -u init.lua -c "lua local n=0; for _ in pairs(vim.lsp.get_active_clients()) do n=n+1 end; if n<1 then vim.cmd('cq') end" -c 'qa' 2>/tmp/nvim-smoke.err || {
  echo "FAIL: Neovim LSP client did not start"
  cat /tmp/nvim-smoke.err || true
  exit 1
}
echo "Neovim LSP smoke OK"
