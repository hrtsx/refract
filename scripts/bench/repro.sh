#!/usr/bin/env bash
# One-command benchmark reproduction:
# 1. Fetch corpora (mastodon, discourse, synth-10k)
# 2. Build refract in release mode
# 3. Run realistic benchmark suite
# 4. Print results location
# Usage: ./scripts/bench/repro.sh
#        REFRACT_BIN=/path/to/binary ./scripts/bench/repro.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REFRACT_BIN="${REFRACT_BIN:-$REPO_ROOT/zig-out/bin/refract}"

echo "========================================"
echo "Refract benchmark reproduction"
echo "========================================"
echo

# 1. Fetch corpora
echo "Step 1: Fetching corpora..."
"$REPO_ROOT/scripts/bench/fetch-corpora.sh"
echo

# 2. Build refract in release mode
echo "Step 2: Building refract (ReleaseSafe)..."
GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo 'nogit')"
(cd "$REPO_ROOT" && zig build -Drelease -Dgit_sha="$GIT_SHA")
echo "✓ Built: $REFRACT_BIN"
echo

# 3. Run realistic benchmark suite
echo "Step 3: Running benchmark suite..."
(export REFRACT_BIN="$REFRACT_BIN"; cd "$REPO_ROOT" && scripts/bench/realistic_run.sh)
echo

# 4. Print results location
LATEST_RESULT=$(ls -td "$REPO_ROOT"/bench-results/realistic/*/ 2>/dev/null | head -1)
if [[ -n "$LATEST_RESULT" ]]; then
  echo "========================================"
  echo "Benchmark complete."
  echo "Results: $LATEST_RESULT"
  echo "========================================"
else
  echo "WARNING: Could not locate latest results directory" >&2
  exit 1
fi
