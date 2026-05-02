#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
jq -e . < LSP-refract.sublime-settings > /dev/null || { echo "FAIL: LSP-refract.sublime-settings is not valid JSON"; exit 1; }
"$REFRACT_BIN" --version > /dev/null || { echo "FAIL: refract binary did not respond to --version"; exit 1; }
echo "Sublime LSP refract plugin smoke OK"
