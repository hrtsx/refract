#!/usr/bin/env bash
# Performance gate: index a 1k-file synthetic Ruby corpus, assert wall < 8s, RSS < 300MB.
# Usage: ./scripts/bench.sh
#        REFRACT=./zig-out/bin/refract  ./scripts/bench.sh
#        BENCH_BUDGET_SEC=8 BENCH_BUDGET_MB=300 ./scripts/bench.sh
set -uo pipefail

CORPUS_DIR="${REFRACT_BENCH_CORPUS:-/tmp/refract-perf-corpus}"
REFRACT_BIN="${REFRACT:-$(pwd)/zig-out/bin/refract}"
BUDGET_SEC="${BENCH_BUDGET_SEC:-8}"
BUDGET_MB="${BENCH_BUDGET_MB:-300}"
N_FILES="${BENCH_N_FILES:-1000}"
N_RUNS="${BENCH_N_RUNS:-3}"

if [[ ! -x "$REFRACT_BIN" ]]; then
  echo "refract binary not executable at: $REFRACT_BIN" >&2
  echo "build first with: zig build" >&2
  exit 2
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "warning: bench uses GNU time (-v); macOS support is degraded" >&2
fi

generate_corpus() {
  local marker="$CORPUS_DIR/.generated-$N_FILES"
  if [[ -f "$marker" ]]; then
    return
  fi
  echo "generating $N_FILES synthetic Ruby files into $CORPUS_DIR ..." >&2
  rm -rf "$CORPUS_DIR"
  mkdir -p "$CORPUS_DIR"
  local i=0
  while (( i < N_FILES )); do
    local sub=$((i / 50))
    mkdir -p "$CORPUS_DIR/m$sub"
    cat > "$CORPUS_DIR/m$sub/file_$i.rb" <<EOF
module M$sub
  class File$i
    include Comparable
    attr_accessor :name, :value, :next_node

    def initialize(name = "f$i", value = $i)
      @name = name
      @value = value
    end

    def <=>(other)
      value <=> other.value
    end

    def double; value * 2; end
    def triple; value * 3; end
    def neighbors(others); others.select { |o| (o.value - value).abs < 10 }; end

    private

    def secret_$i
      "secret-#{name}-#{value}"
    end
  end

  module Helpers$i
    extend self
    def upcase(s); s.to_s.upcase; end
    def echo(*a); a; end
  end
end
EOF
    i=$((i + 1))
  done
  touch "$marker"
}

run_once() {
  local db_path="$1"
  rm -f "$db_path" "$db_path-wal" "$db_path-shm"
  local time_log
  time_log=$(mktemp)
  ( cd "$CORPUS_DIR" && \
    /usr/bin/time -v "$REFRACT_BIN" \
      --db-path "$db_path" \
      --index-only \
      --max-workers 8 \
      --disable-rubocop \
      > "$time_log" 2>&1 )
  local rc=$?
  if (( rc != 0 )); then
    echo "refract --index-only failed (rc=$rc):" >&2
    cat "$time_log" >&2
    rm -f "$time_log"
    return 1
  fi
  local wall_secs peak_rss_kb
  wall_secs=$(grep -E "Elapsed \(wall clock\) time" "$time_log" | awk -F': ' '{print $NF}' | tr -d ' ')
  peak_rss_kb=$(grep -E "Maximum resident set size" "$time_log" | awk '{print $NF}')

  # Wall clock format: H:MM:SS or M:SS.ss — convert to seconds (float)
  local wall_secs_f
  wall_secs_f=$(echo "$wall_secs" | awk -F: '{
    if (NF == 3) { print $1*3600 + $2*60 + $3 }
    else if (NF == 2) { print $1*60 + $2 }
    else { print $1 }
  }')

  local rss_mb=$((peak_rss_kb / 1024))
  printf "%s %s\n" "$wall_secs_f" "$rss_mb"
  rm -f "$time_log"
}

generate_corpus

echo "# Refract perf gate"
echo "binary:       $REFRACT_BIN"
echo "version:      $("$REFRACT_BIN" --version 2>/dev/null | head -1)"
echo "corpus:       $CORPUS_DIR (~$N_FILES files)"
echo "budget:       wall < ${BUDGET_SEC}s, peak RSS < ${BUDGET_MB} MB"
echo "runs:         $N_RUNS (best of)"
echo

best_wall=999999
best_rss=999999
for i in $(seq 1 "$N_RUNS"); do
  result=$(run_once "$CORPUS_DIR/run-$i.db") || exit 1
  wall=$(echo "$result" | awk '{print $1}')
  rss=$(echo "$result" | awk '{print $2}')
  printf "  run %d  wall=%ss  peak_rss=%s MB\n" "$i" "$wall" "$rss"
  if (( $(echo "$wall < $best_wall" | bc -l 2>/dev/null || echo 0) )); then
    best_wall="$wall"
  fi
  if (( rss < best_rss )); then
    best_rss=$rss
  fi
done
echo
echo "best wall:    ${best_wall}s   (budget ${BUDGET_SEC}s)"
echo "best RSS:     ${best_rss} MB  (budget ${BUDGET_MB} MB)"

fail=0
if (( $(echo "$best_wall > $BUDGET_SEC" | bc -l 2>/dev/null || echo 0) )); then
  echo "FAIL: wall budget exceeded" >&2
  fail=1
fi
if (( best_rss > BUDGET_MB )); then
  echo "FAIL: RSS budget exceeded" >&2
  fail=1
fi

exit $fail
