#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
python3 -c "import tomllib; tomllib.load(open('extension.toml','rb'))" || { echo "FAIL: extension.toml is not valid TOML"; exit 1; }
"$REFRACT_BIN" --version > /dev/null || { echo "FAIL: refract binary did not respond to --version"; exit 1; }
echo "Zed extension smoke OK"
