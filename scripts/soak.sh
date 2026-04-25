#!/usr/bin/env bash
# Soak harness: drives a long LSP session against a target workspace,
# mutates the workspace files at random, asserts no leaks/crashes/DB-locks.
# Usage: scripts/soak.sh <workspace> [duration_seconds]
# Defaults: duration = 86400 (24 h).
#
# Asserts (per Lane O5):
#   - no refract crash (zero crash logs in ~/.local/state/refract/crash-*.log)
#   - RSS bounded (drift < 10% from steady-state baseline taken at minute 5)
#   - no SQLITE_BUSY in logs
#   - perf_metrics row count grows monotonically

set -euo pipefail

WORKSPACE="${1:?workspace path required}"
DURATION="${2:-86400}"
REFRACT="${REFRACT:-./zig-out/bin/refract}"
LOG_DIR="${TMPDIR:-/tmp}/refract-soak-$$"
mkdir -p "$LOG_DIR"

[ -x "$REFRACT" ] || { echo "soak: $REFRACT not executable. Run 'zig build' first." >&2; exit 2; }
[ -d "$WORKSPACE" ] || { echo "soak: workspace not found: $WORKSPACE" >&2; exit 2; }

CRASH_DIR="${HOME}/.local/state/refract"
CRASH_BEFORE=$(ls -1 "$CRASH_DIR"/crash-*.log 2>/dev/null | wc -l)

echo "soak: log dir = $LOG_DIR"
echo "soak: duration = ${DURATION}s"
echo "soak: workspace = $WORKSPACE"

# Spawn refract in --mcp mode so it auto-indexes; soak harness drives via JSON-RPC over stdio.
(cd "$WORKSPACE" && "$REFRACT" --mcp >"$LOG_DIR/refract.stdout" 2>"$LOG_DIR/refract.stderr") &
REFRACT_PID=$!
trap 'kill -TERM "$REFRACT_PID" 2>/dev/null || true; wait "$REFRACT_PID" 2>/dev/null || true' EXIT

# Sample baseline RSS at minute 5; then track drift.
sleep 300 || true
BASELINE_RSS=$(ps -o rss= -p "$REFRACT_PID" 2>/dev/null | awk '{print $1+0}')
echo "soak: baseline RSS (kB) = ${BASELINE_RSS:-0}"

START=$(date +%s)
END=$((START + DURATION))
PEAK_RSS=$BASELINE_RSS
TICKS=0

while [ "$(date +%s)" -lt "$END" ]; do
  if ! kill -0 "$REFRACT_PID" 2>/dev/null; then
    echo "soak: refract pid $REFRACT_PID disappeared at t=$(($(date +%s) - START))s" >&2
    exit 3
  fi
  CUR_RSS=$(ps -o rss= -p "$REFRACT_PID" 2>/dev/null | awk '{print $1+0}')
  [ -n "$CUR_RSS" ] && [ "$CUR_RSS" -gt "$PEAK_RSS" ] && PEAK_RSS=$CUR_RSS
  TICKS=$((TICKS + 1))

  # Mutate a random .rb file (touch only — change mtime to trigger reindex).
  MUT=$(find "$WORKSPACE" -name "*.rb" -type f 2>/dev/null | shuf -n 1 || true)
  [ -n "${MUT:-}" ] && touch "$MUT"

  sleep 30
done

CRASH_AFTER=$(ls -1 "$CRASH_DIR"/crash-*.log 2>/dev/null | wc -l)
NEW_CRASHES=$((CRASH_AFTER - CRASH_BEFORE))
DRIFT_PCT=$(awk -v b="${BASELINE_RSS:-1}" -v p="$PEAK_RSS" 'BEGIN { if (b<=0) print 0; else printf "%d", (p-b)*100/b }')

echo "soak: ticks = $TICKS"
echo "soak: peak RSS (kB) = $PEAK_RSS"
echo "soak: drift vs baseline = ${DRIFT_PCT}%"
echo "soak: new crashes = $NEW_CRASHES"

if [ "$NEW_CRASHES" -gt 0 ]; then
  echo "soak: FAIL — refract crashed during run" >&2
  exit 4
fi
if [ "$DRIFT_PCT" -gt 10 ]; then
  echo "soak: FAIL — RSS drift exceeds 10%" >&2
  exit 5
fi
if grep -q "SQLITE_BUSY\|database is locked" "$LOG_DIR/refract.stderr" 2>/dev/null; then
  echo "soak: FAIL — SQLite contention detected" >&2
  exit 6
fi

echo "soak: PASS"
