#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
npm install
npm run test || { echo "FAIL: VSCode extension smoke test failed"; exit 1; }
echo "VSCode extension smoke OK"
