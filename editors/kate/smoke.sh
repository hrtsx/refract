#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
jq -e . < lspclient.json > /dev/null || { echo "FAIL: lspclient.json is not valid JSON"; exit 1; }
"$REFRACT_BIN" --version > /dev/null || { echo "FAIL: refract binary did not respond to --version"; exit 1; }
echo "Kate LSP client smoke OK"
