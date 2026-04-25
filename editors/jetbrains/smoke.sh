#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
xmllint --noout plugin.xml || { echo "FAIL: plugin.xml is not valid XML"; exit 1; }
"$REFRACT_BIN" --version > /dev/null || { echo "FAIL: refract binary did not respond to --version"; exit 1; }
echo "JetBrains plugin smoke OK"
