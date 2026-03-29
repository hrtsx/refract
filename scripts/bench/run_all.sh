#!/usr/bin/env bash
# Run perf + accuracy harness against refract, solargraph, and ruby-lsp.
# Outputs JSON blocks to stdout. See docs/BENCHMARK.md for interpretation.
set -uo pipefail

CORPUS="${REFRACT_BENCH_CORPUS:-/tmp/refract-perf-corpus}"
REFRACT="${REFRACT:-$(pwd)/zig-out/bin/refract}"
DRIVER_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -x "$REFRACT" ]]; then
  echo "refract binary not executable at $REFRACT — build first with: zig build" >&2
  exit 2
fi
if [[ ! -d "$CORPUS" ]]; then
  echo "corpus missing at $CORPUS — generate first with: ./scripts/bench.sh" >&2
  exit 2
fi
for dep in solargraph ruby-lsp; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "missing $dep — install with: gem install $dep" >&2
    exit 2
  fi
done

# Ensure the benchmark fixtures exist in the corpus.
[[ -f "$CORPUS/bench_fixture.rb" ]] || cp "$DRIVER_DIR/fixtures/bench_fixture.rb" "$CORPUS/" 2>/dev/null
[[ -f "$CORPUS/accuracy_main.rb" ]] || cp "$DRIVER_DIR/fixtures/accuracy_main.rb" "$CORPUS/" 2>/dev/null
[[ -f "$CORPUS/accuracy_lib.rb"  ]] || cp "$DRIVER_DIR/fixtures/accuracy_lib.rb"  "$CORPUS/" 2>/dev/null

run_perf() {
  local name="$1"; shift
  echo "=== perf: $name ==="
  ROOT="$CORPUS" FIXTURE=bench_fixture.rb \
    timeout 300 ruby "$DRIVER_DIR/lsp_driver.rb" "$name" "$@"
  echo
}

run_accuracy() {
  local name="$1"; shift
  echo "=== accuracy: $name ==="
  ROOT="$CORPUS" \
    timeout 180 ruby "$DRIVER_DIR/lsp_accuracy.rb" "$name" "$@"
  echo
}

# Cold-cache reset for refract between runs
REFRACT_DB="$(cd "$CORPUS" && "$REFRACT" --print-db-path 2>/dev/null)"
[[ -n "$REFRACT_DB" ]] && rm -f "$REFRACT_DB" "$REFRACT_DB-wal" "$REFRACT_DB-shm" 2>/dev/null

run_perf refract    "$REFRACT" --disable-rubocop
run_perf solargraph solargraph stdio
run_perf ruby-lsp   ruby-lsp

REFRACT_DB="$(cd "$CORPUS" && "$REFRACT" --print-db-path 2>/dev/null)"
[[ -n "$REFRACT_DB" ]] && rm -f "$REFRACT_DB" "$REFRACT_DB-wal" "$REFRACT_DB-shm" 2>/dev/null

run_accuracy refract    "$REFRACT" --disable-rubocop
run_accuracy solargraph solargraph stdio
run_accuracy ruby-lsp   ruby-lsp
